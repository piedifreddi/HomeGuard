#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------
# install_wireguard.sh — Ubuntu 22.04/24.04
# Installa e configura PiVPN (WireGuard) in modalità non interattiva
# - Rete VPN: 10.8.0.0/24
# - Porta UDP: 51820
# - DNS: Pi-hole (10.8.0.1)
# - Firewall: UFW o nftables
# - Genera 1° peer (admin) + QR code
# ---------------------------------------------------------

WG_NET="${WG_NET:-10.8.0.0}"
WG_CIDR="${WG_CIDR:-10.8.0.0/24}"
WG_IFACE="${WG_IFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_DNS="${WG_DNS:-10.8.0.1}"
WG_PEER_NAME="${WG_PEER_NAME:-admin}"
WG_PKG_BRANCH="${WG_PKG_BRANCH:-master}"  # "master" o "testing"
HOST_IP=$(ip -4 route get 1.1.1.1 | awk '/src/ {print $7; exit}')
IFACE=$(ip -4 route get 1.1.1.1 | awk '/dev/ {print $5; exit}')

echo "=============================="
echo " [ PiVPN / WireGuard Installer - Ubuntu ]"
echo "=============================="
echo "[i] Interfaccia esterna: $IFACE  |  IP pubblico: $HOST_IP"
echo "[i] Rete VPN: $WG_CIDR  |  Porta: $WG_PORT  |  DNS: $WG_DNS"

# --- Check root ---
[ "$EUID" -eq 0 ] || { echo "❌ Esegui come root (sudo)."; exit 1; }

# --- Installa dipendenze base ---
echo "[+] Installo WireGuard e PiVPN"
apt-get update -y
apt-get install -y wireguard wireguard-tools qrencode curl git ufw

# --- Disabilita systemd-resolved sul wg0 (evita conflitti DNS) ---
if systemctl is-active systemd-resolved &>/dev/null; then
  sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/g' /etc/systemd/resolved.conf || true
  systemctl restart systemd-resolved || true
fi

# --- Installa PiVPN in modalità non interattiva ---
if ! command -v pivpn >/dev/null 2>&1; then
  echo "[+] Scarico ed eseguo PiVPN unattended"
  curl -L https://install.pivpn.io | bash /dev/stdin --unattended wireguard
else
  echo "[i] PiVPN già installato, salto."
fi

# --- Configurazione server WireGuard ---
CONF_DIR="/etc/wireguard"
CONF_FILE="$CONF_DIR/${WG_IFACE}.conf"
mkdir -p "$CONF_DIR"

if [ ! -f "$CONF_FILE" ]; then
  echo "[+] Creo configurazione server WireGuard ($CONF_FILE)"
  umask 077
  wg genkey | tee "$CONF_DIR/server_private.key" | wg pubkey > "$CONF_DIR/server_public.key"
  PRIV_KEY=$(cat "$CONF_DIR/server_private.key")
  PUB_KEY=$(cat "$CONF_DIR/server_public.key")

  cat > "$CONF_FILE" <<EOF
[Interface]
Address = ${WG_CIDR}
SaveConfig = true
ListenPort = ${WG_PORT}
PrivateKey = ${PRIV_KEY}
PostUp = ufw route allow in on ${WG_IFACE} out on ${IFACE}; \
         iptables -t nat -A POSTROUTING -s ${WG_NET}/24 -o ${IFACE} -j MASQUERADE
PostDown = ufw route delete allow in on ${WG_IFACE} out on ${IFACE}; \
           iptables -t nat -D POSTROUTING -s ${WG_NET}/24 -o ${IFACE} -j MASQUERADE
EOF
else
  echo "[i] Configurazione WireGuard già presente, lascio invariata."
fi

# --- Abilita IP forwarding ---
echo "[+] Abilito IP forwarding"
sed -i 's/^#\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sed -i 's/^#\?net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf
sysctl -p >/dev/null

# --- Firewall UFW / nftables ---
if command -v ufw >/dev/null 2>&1; then
  echo "[+] Configuro UFW per WireGuard"
  ufw allow ${WG_PORT}/udp || true
  ufw route allow in on ${WG_IFACE} out on ${IFACE} || true
  ufw allow in on ${WG_IFACE} || true
  ufw reload || true
else
  echo "[+] Aggiungo regole nftables per NAT"
  mkdir -p /etc/nftables.d
  cat > /etc/nftables.d/20-wireguard.nft <<EOF
table inet wireguard {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$IFACE" ip saddr ${WG_NET}/24 masquerade
  }
  chain input {
    type filter hook input priority 0;
    iifname "$WG_IFACE" accept
  }
}
EOF
  if ! grep -q '^include "/etc/nftables.d/\\*.nft";' /etc/nftables.conf 2>/dev/null; then
    echo 'include "/etc/nftables.d/*.nft";' >> /etc/nftables.conf
  fi
  systemctl enable nftables
  systemctl restart nftables
fi

# --- Abilita e avvia servizio WireGuard ---
echo "[+] Abilito servizio wg-quick@${WG_IFACE}"
systemctl enable wg-quick@${WG_IFACE}
systemctl start wg-quick@${WG_IFACE}

# --- Genera primo peer (client) ---
PEER_DIR="${CONF_DIR}/clients"
mkdir -p "$PEER_DIR"

if [ ! -f "${PEER_DIR}/${WG_PEER_NAME}.conf" ]; then
  echo "[+] Creo primo peer '${WG_PEER_NAME}'"
  wg genkey | tee "${PEER_DIR}/${WG_PEER_NAME}_private.key" | wg pubkey > "${PEER_DIR}/${WG_PEER_NAME}_public.key"

  CLIENT_PRIV=$(cat "${PEER_DIR}/${WG_PEER_NAME}_private.key")
  CLIENT_PUB=$(cat "${PEER_DIR}/${WG_PEER_NAME}_public.key")

  cat > "${PEER_DIR}/${WG_PEER_NAME}.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = 10.8.0.2/32
DNS = ${WG_DNS}

[Peer]
PublicKey = ${PUB_KEY}
Endpoint = ${HOST_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  echo "[+] Aggiungo peer a server config"
  wg set ${WG_IFACE} peer "${CLIENT_PUB}" allowed-ips 10.8.0.2/32
else
  echo "[i] Peer '${WG_PEER_NAME}' già presente."
fi

# --- Mostra QR code per il peer ---
if command -v qrencode >/dev/null 2>&1; then
  echo "[+] QR code per configurazione client '${WG_PEER_NAME}':"
  qrencode -t ansiutf8 < "${PEER_DIR}/${WG_PEER_NAME}.conf"
else
  echo "[i] qrencode non trovato, mostra solo percorso file:"
fi

echo "[i] Config client salvata in: ${PEER_DIR}/${WG_PEER_NAME}.conf"

# --- Test rapido handshake ---
echo "[+] Stato WireGuard:"
wg show ${WG_IFACE} || echo "⚠️ wg show fallito"

echo
echo "✅ WireGuard / PiVPN configurato."
echo "🔗 Peer '${WG_PEER_NAME}' pronto per l'uso."
echo "🔐 Config: ${PEER_DIR}/${WG_PEER_NAME}.conf"
echo
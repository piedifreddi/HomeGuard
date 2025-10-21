#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------
# install_pihole.sh — Ubuntu 22.04/24.04
# Installa Pi-hole in modalità unattended e lo instrada verso Unbound (127.0.0.1#5335).
# Limita l'esposizione DNS a loopback + LAN tramite UFW (se presente) o nftables.
# ---------------------------------------------------------

# ---- Parametri (override con env) ----
PIHOLE_PWD="${PIHOLE_PWD:-changeme}"   # password WebUI
LISTEN_ALL="${LISTEN_ALL:-1}"          # 1 = Pi-hole "single" (tutte le interfacce). Il firewall limiterà a LAN.
IPV4_CIDR="${IPV4_CIDR:-}"             # opzionale: es. 192.168.1.10/24. Se vuoto lo rilevo.
IFACE="${IFACE:-}"                     # opzionale: es. eth0. Se vuoto lo rilevo.

echo "=============================="
echo " [ Pi-hole Installer - Ubuntu ]"
echo "=============================="

apt-get update -y
apt-get install -y curl git jq iproute2 dnsutils

# ---- Rileva IFACE/IP se non forniti ----
if [ -z "$IFACE" ]; then
  IFACE=$(ip -4 route get 1.1.1.1 | awk '/dev/ {print $5; exit}')
fi
if [ -z "$IPV4_CIDR" ]; then
  IPV4_CIDR=$(ip -o -f inet addr show "$IFACE" | awk '{print $4; exit}')
fi
HOST_IP="${IPV4_CIDR%%/*}"
echo "[i] IFACE=$IFACE  IPV4_CIDR=$IPV4_CIDR  HOST_IP=$HOST_IP"

# ---- Gestione systemd-resolved (evita conflitto su :53) ----
if systemctl is-active systemd-resolved &>/dev/null; then
  echo "[+] Disabilito lo stub listener di systemd-resolved"
  sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/g' /etc/systemd/resolved.conf || true
  systemctl restart systemd-resolved || true

  # Assicura il resolv.conf non-stub
  if [ -L /etc/resolv.conf ]; then
    target=$(readlink -f /etc/resolv.conf)
    if [ "$target" = "/run/systemd/resolve/stub-resolv.conf" ]; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
      echo "[i] Puntato /etc/resolv.conf → /run/systemd/resolve/resolv.conf"
    fi
  fi
fi

# ---- Installazione Pi-hole unattended ----
export PIHOLE_SKIP_OS_CHECK=true
if ! command -v pihole >/dev/null 2>&1; then
  echo "[+] Installo Pi-hole (unattended)"
  curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
else
  echo "[i] Pi-hole già installato; procedo con la riconfigurazione."
fi

# ---- setupVars.conf (forza Unbound come upstream) ----
echo "[+] Configuro setupVars.conf"
mkdir -p /etc/pihole
# Pulisce chiavi che andremo a forzare
sed -i '/^DNSMASQ_LISTENING=/d; /^PIHOLE_INTERFACE=/d; /^IPV4_ADDRESS=/d; /^PIHOLE_DNS_1=/d; /^PIHOLE_DNS_2=/d; /^QUERY_LOGGING=/d; /^DNSSEC=/d' /etc/pihole/setupVars.conf 2>/dev/null || true

if [ "$LISTEN_ALL" = "1" ]; then
  DNSMASQ_LISTENING="single"   # Pi-hole ascolta su tutte le interfacce (ma il firewall limita)
else
  DNSMASQ_LISTENING="local"    # Solo loopback
fi

cat <<EOF >> /etc/pihole/setupVars.conf
PIHOLE_INTERFACE=${IFACE}
IPV4_ADDRESS=${IPV4_CIDR}
PIHOLE_DNS_1=127.0.0.1#5335
PIHOLE_DNS_2=
QUERY_LOGGING=true
DNSMASQ_LISTENING=${DNSMASQ_LISTENING}
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSSEC=false
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
BLOCKING_ENABLED=true
EOF

# ---- dnsmasq: inoltro a Unbound e no-resolv/no-poll ----
echo "[+] Scrivo /etc/dnsmasq.d/02-upstream.conf"
cat > /etc/dnsmasq.d/02-upstream.conf <<'EOF'
# Inoltra tutto a Unbound locale
server=127.0.0.1#5335
# Ignora /etc/resolv.conf e server DHCP
no-resolv
no-poll
EOF

# ---- Applica password WebUI ----
echo "[+] Imposto password WebUI"
pihole -a -p "$PIHOLE_PWD" >/dev/null

# ---- Riavvia servizi Pi-hole ----
echo "[+] Riavvio pihole-FTL"
systemctl enable pihole-FTL
systemctl restart pihole-FTL

# ---- Firewall: preferisci UFW se presente; fallback nftables ----
SUBNET=$(ip -o -f inet addr show "$IFACE" | awk '{print $4; exit}')
if command -v ufw >/dev/null 2>&1; then
  echo "[+] Configuro UFW per consentire DNS solo da LAN ($SUBNET)"
  ufw allow from "$SUBNET" to any port 53 proto tcp || true
  ufw allow from "$SUBNET" to any port 53 proto udp || true
  echo "[i] Se UFW è disabilitato, abilitalo con: sudo ufw enable"
else
  echo "[+] Configuro nftables (regole minime DNS)"
  mkdir -p /etc/nftables.d
  cat > /etc/nftables.d/10-pihole-dns.nft <<EOF
table inet pihole {
  set lan_ifaces { type ifname; elements = { ${IFACE} } }
  chain dns_in {
    type filter hook input priority 0;
    iif "lo" accept
    iifname @lan_ifaces tcp dport 53 accept
    iifname @lan_ifaces udp dport 53 accept
  }
}
EOF
  systemctl enable nftables >/dev/null 2>&1 || true
  if ! grep -q '^include "/etc/nftables.d/\\*.nft";' /etc/nftables.conf 2>/dev/null; then
    echo 'include "/etc/nftables.d/*.nft";' >> /etc/nftables.conf
  fi
  systemctl restart nftables || true
fi

# ---- Test funzionale ----
echo "[+] Test DNS via Pi-hole (porta 53)"
dig @127.0.0.1 -p 53 example.com +short || echo "⚠️ Test fallito (controlla pihole-FTL/unbound)."

echo
echo "Pi-hole instradato su Unbound (127.0.0.1#5335)."
echo "WebUI: http://${HOST_IP}/admin"
echo "Password: ${PIHOLE_PWD}"

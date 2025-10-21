#!/usr/bin/env bash
set -euo pipefail

echo "=============================="
echo " [ Unbound Installer - Ubuntu ]"
echo "=============================="

# --- Check root ---
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: You need to be root to run this script"
  exit 1
fi

# --- Verifica distro ---
#. /etc/os-release
#if [[ "$ID" != "ubuntu" && "$ID_LIKE" != *"ubuntu"* ]]; then
#  echo "⚠️  Distro non Ubuntu, script ottimizzato per Ubuntu."
#fi 

# --- 1) Managing systemd-resolved ---
if systemctl is-active systemd-resolved &>/dev/null; then
  echo "[+] Diabling stub listener systemd-resolved"
  sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/g' /etc/systemd/resolved.conf || true
  systemctl restart systemd-resolved || true

  # Make sure /etc/resolv.conf points to non-stub file
  if [ -L /etc/resolv.conf ]; then
    target=$(readlink -f /etc/resolv.conf)
    if [ "$target" = "/run/systemd/resolve/stub-resolv.conf" ]; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
      echo "[i] Pointing /etc/resolv.conf → /run/systemd/resolve/resolv.conf"
    fi
  fi
fi

# --- 2) Install base packets ---
echo "[+] Installing Unbound"
apt-get update -y
apt-get install -y unbound unbound-anchor curl dns-root-data ca-certificates
 
# --- 3) Update Root hints ---
mkdir -p /var/lib/unbound
cp /usr/share/dns/root.hints /var/lib/unbound/root.hints || true
echo "[+] Updating root hints from Internic"
curl -fsSL -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.root || true
chown unbound:unbound /var/lib/unbound/root.hints
chmod 644 /var/lib/unbound/root.hints

# --- 4) Main configuration ---
mkdir -p /etc/unbound/unbound.conf.d

CONF_FILE="/etc/unbound/unbound.conf.d/recursor.conf"

# if it doesn't exist
if [ ! -f "$CONF_FILE" ]; then
  echo "[+] Creating main configuration ($CONF_FILE)"
  cat > "$CONF_FILE" <<'EOF'
server:
  verbosity: 0
  interface: 127.0.0.1
  port: 5335
  do-ip4: yes
  do-ip6: yes
  do-udp: yes
  do-tcp: yes

  # Security
  root-hints: "/var/lib/unbound/root.hints"
  harden-glue: yes
  harden-dnssec-stripped: yes
  qname-minimisation: yes
  use-caps-for-id: no
  prefetch: yes
  cache-min-ttl: 3600
  cache-max-ttl: 86400
  edns-buffer-size: 1232

  # DNSSEC
  auto-trust-anchor-file: "/var/lib/unbound/root.key"
  trust-anchor-signaling: yes

  # Interfaces
  access-control: 127.0.0.0/8 allow
  access-control: ::1 allow
  access-control: 10.0.0.0/8 allow
  access-control: 192.168.0.0/16 allow
  access-control: 172.16.0.0/12 allow
EOF
else
  echo "[i] Configuration already existing: $CONF_FILE"
fi

#echo "[+] Updating trust anchor DNSSEC"
#install -d -o unbound -g unbound -m 755 /var/lib/unbound
#rm -f /var/lib/unbound/root.key
#if ! command -v unbound-anchor >/dev/null 2>&1; then
#  apt-get install -y unbound-anchor
#fi
#unbound-anchor -a /var/lib/unbound/root.key || true
#chown unbound:unbound /var/lib/unbound/root.key
#chmod 644 /var/lib/unbound/root.key

# --- 5) Update trust anchor (DNSSEC) ---
echo "[+] Aggiorno trust anchor DNSSEC (metodo Ubuntu compatibile)"

# Remove duplicate or corrupted file
rm -f /var/lib/unbound/root.key

# Usa l'helper di sistema Ubuntu per rigenerare la chiave
if [ -x /usr/libexec/unbound-helper ]; then
  /usr/libexec/unbound-helper root_trust_anchor_update || true
else
  echo "[!] Attenzione: unbound-helper non trovato, provo fallback manuale."
  if command -v unbound-anchor >/dev/null 2>&1; then
    unbound-anchor -a /var/lib/unbound/root.key || true
  else
    apt-get install -y unbound-anchor || true
    unbound-anchor -a /var/lib/unbound/root.key || true
  fi
fi

# Imposta i permessi corretti
chown unbound:unbound /var/lib/unbound/root.key 2>/dev/null || true
chmod 644 /var/lib/unbound/root.key 2>/dev/null || true

# --- 6) enable and start Unbound ---
echo "[+] Enable and start Unbound"
systemctl enable unbound
systemctl restart unbound

# --- 7) Testing ---
echo "[+] Test: recursive DNS resolution with Unbound"
if command -v dig >/dev/null 2>&1; then
  dig @127.0.0.1 -p 5335 www.google.com +short || echo "DNS test failed"
else
  apt-get install -y dnsutils >/dev/null 2>&1 || true
  dig @127.0.0.1 -p 5335 www.google.com +short || echo "DNS test failed"
fi

echo "[✓] Unbound installed and running on 127.0.0.1#5335"

#!/usr/bin/env bash
set -euo pipefail

echo "=============================="
echo " [ Unbound Installer - Ubuntu ]"
echo "=============================="

# --- Check permessi ---
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: You need to be root to run this script"
  exit 1
fi

# --- Verifica distro ---
. /etc/os-release
if [[ "$ID" != "ubuntu" && "$ID_LIKE" != *"ubuntu"* ]]; then
  echo "⚠️  Distro non Ubuntu, script ottimizzato per Ubuntu."
fi

# --- 1. Gestione systemd-resolved ---
if systemctl is-active systemd-resolved &>/dev/null; then
  echo "[+] Disabilito solo lo stub listener di systemd-resolved"
  sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/g' /etc/systemd/resolved.conf || true
  systemctl restart systemd-resolved || true

  # Assicura che /etc/resolv.conf punti al file non-stub
  if [ -L /etc/resolv.conf ]; then
    target=$(readlink -f /etc/resolv.conf)
    if [ "$target" = "/run/systemd/resolve/stub-resolv.conf" ]; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
      echo "[i] Puntato /etc/resolv.conf → /run/systemd/resolve/resolv.conf"
    fi
  fi
fi

# --- 2. Installa pacchetti base ---
echo "[+] Installo Unbound e dipendenze"
apt-get update -y
apt-get install -y unbound curl dns-root-data

# --- 3. Root hints aggiornati ---
mkdir -p /var/lib/unbound
cp /usr/share/dns/root.hints /var/lib/unbound/root.hints || true
echo "[+] Aggiorno root hints da Internic"
curl -fsSL -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.root || true
chown unbound:unbound /var/lib/unbound/root.hints
chmod 644 /var/lib/unbound/root.hints

# --- 4. Configurazione principale ---
mkdir -p /etc/unbound/unbound.conf.d

CONF_FILE="/etc/unbound/unbound.conf.d/recursor.conf"

# Solo se non esiste o se vogliamo rigenerarlo
if [ ! -f "$CONF_FILE" ]; then
  echo "[+] Creo configurazione di base ($CONF_FILE)"
  cat > "$CONF_FILE" <<'EOF'
server:
  verbosity: 0
  interface: 127.0.0.1
  port: 5335
  do-ip4: yes
  do-ip6: yes
  do-udp: yes
  do-tcp: yes

  # Sicurezza e performance
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

  # Interfacce
  access-control: 127.0.0.0/8 allow
  access-control: ::1 allow
  access-control: 10.0.0.0/8 allow
  access-control: 192.168.0.0/16 allow
  access-control: 172.16.0.0/12 allow
EOF
else
  echo "[i] Configurazione già presente, lascio invariato $CONF_FILE"
fi

# --- 5. Aggiorna trust anchor (DNSSEC) ---
echo "[+] Aggiorno trust anchor DNSSEC"
unbound-anchor -a /var/lib/unbound/root.key || true
chown unbound:unbound /var/lib/unbound/root.key
chmod 644 /var/lib/unbound/root.key

# --- 6. Abilita e avvia Unbound ---
echo "[+] Abilito e riavvio Unbound"
systemctl enable unbound
systemctl restart unbound

# --- 7. Test di funzionamento ---
echo "[+] Test: risoluzione DNS ricorsiva tramite Unbound"
if command -v dig >/dev/null 2>&1; then
  dig @127.0.0.1 -p 5335 www.google.com +short || echo "⚠️ Test DNS fallito"
else
  apt-get install -y dnsutils >/dev/null 2>&1 || true
  dig @127.0.0.1 -p 5335 www.google.com +short || echo "⚠️ Test DNS fallito"
fi

echo "✅ Unbound installato e funzionante su 127.0.0.1#5335"

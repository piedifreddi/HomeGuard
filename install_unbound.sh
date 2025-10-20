#!/bin/bash
set -e

echo "[+] Installing Unbound..."
sudo apt update
sudo apt install unbound

echo "[+] Fetching root hints..."
sudo curl -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.root

echo "[+] Configuring Unbound..."
sudo mkdir -p /etc/unbound/unbound.conf.d/
sudo tee /etc/unbound/unbound.conf.d/recursor.conf > /dev/null <<EOF
server:
  interface: 127.0.0.1
  port: 5335
  do-ip4: yes
  do-udp: yes
  do-tcp: yes
  root-hints: "/var/lib/unbound/root.hints"
  cache-min-ttl: 3600
  cache-max-ttl: 86400
  qname-minimisation: yes
  harden-dnssec-stripped: yes
  auto-trust-anchor-file: "/var/lib/unbound/root.key"
EOF

echo "[+] Enabling Unbound..."
sudo systemctl enable unbound
sudo systemctl restart unbound

echo "[+] Testing DNS recursion..."
dig @127.0.0.1 -p 5335 www.google.com +short || echo "Test failed"
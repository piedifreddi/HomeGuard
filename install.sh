#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT_DIR/installer/common.sh"

require_root
source /etc/os-release || true

ID_LIKE_LOWER="$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
ID_LOWER="$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')"

pick_family() {
  case "$ID_LOWER" in
    ubuntu|debian) echo "debian"; return ;;
    fedora|rhel|centos|rocky|almalinux) echo "rhel"; return ;;
    arch|manjaro) echo "arch"; return ;;
    *) ;;
  esac
  case "$ID_LIKE_LOWER" in
    *debian*) echo "debian";;
    *rhel*|*fedora*) echo "rhel";;
    *arch*) echo "arch";;
    *) echo "unknown";;
  esac
}

FAMILY="$(pick_family)"

case "$FAMILY" in
  debian)
    echo "[*] Distro detected: Debian/Ubuntu"
    bash "$ROOT_DIR/installer/ubuntu/install_unbound.sh"
    PIHOLE_PWD="${PIHOLE_PWD:-changeme}" \
      bash "$ROOT_DIR/installer/ubuntu/install_pihole.sh"
      bash "$ROOT_DIR/installer/ubuntu/install_wireguard.sh"
    ;;
  rhel)
    echo "[*] Distro detected: RHEL/Fedora (preview)"
    bash "$ROOT_DIR/installer/rhel/install_unbound.sh"
    PIHOLE_PWD="${PIHOLE_PWD:-changeme}" \
      bash "$ROOT_DIR/installer/rhel/install_pihole.sh"
      bash "$ROOT_DIR/installer/rhel/install_wireguard.sh"
    ;;
  arch)
    echo "[*] Distro detected: Arch/Manjaro (preview)"
    bash "$ROOT_DIR/installer/arch/install_unbound.sh"
    PIHOLE_PWD="${PIHOLE_PWD:-changeme}" \
      bash "$ROOT_DIR/installer/arch/install_pihole.sh"
      bash "$ROOT_DIR/installer/arch/install_wireguard.sh"
    ;;
  *)
    echo "Distro not recognized."
    exit 1
    ;;
esac

echo "Installation completed"

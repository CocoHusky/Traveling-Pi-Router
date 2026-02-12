#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$REPO_DIR/files"
CONFIG_DIR="/etc/travelrouter"
CONFIG_FILE="$CONFIG_DIR/config.env"
LINK_FILE="/etc/systemd/network/10-travelrouter.link"
NM_CONF="/etc/NetworkManager/conf.d/10-travelrouter-unmanaged.conf"
DHCPCD_CONF="/etc/dhcpcd.conf"
REBOOT_RECOMMENDED=0

log() { printf '[travelrouter-install] %s\n' "$*"; }
warn() { printf '[travelrouter-install] WARNING: %s\n' "$*" >&2; }
die() { printf '[travelrouter-install] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "Run as root: sudo ./install.sh"
  fi
}

check_ar9271() {
  if lsusb 2>/dev/null | grep -qiE '9271|Atheros.*AR9271|Qualcomm Atheros.*9271'; then
    log "Detected Qualcomm Atheros AR9271 via lsusb."
    return 0
  fi

  if lsmod | awk '{print $1}' | grep -qx 'ath9k_htc' && iw dev | grep -q '^Interface '; then
    log "ath9k_htc module loaded with wireless interface present."
    return 0
  fi

  die "AR9271 not detected. This installer ONLY supports Qualcomm Atheros AR9271 (ath9k_htc). Plug in the dongle and retry."
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Installing dependencies..."
  apt-get update -y
  apt-get install -y hostapd dnsmasq iptables-persistent netfilter-persistent wireless-tools iw usbutils
}

ensure_config() {
  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" <<'CFG'
SSID=TravelRouter
PASSPHRASE=changeme123
AP_IFACE_MAC=00:11:22:33:44:55
COUNTRY=US
WAN_IF=wlan0
LAN_IF=wlan1
LAN_CIDR=192.168.50.1/24
DHCP_START=192.168.50.20
DHCP_END=192.168.50.150
CFG
    log "Created $CONFIG_FILE with placeholders."
  else
    log "Keeping existing config at $CONFIG_FILE."
  fi
  chmod 600 "$CONFIG_FILE"
}

load_config() {
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${LAN_IF:=wlan1}"
  : "${AP_IFACE_MAC:=00:11:22:33:44:55}"
}

configure_link_file() {
  local rendered
  rendered="$(sed \
    -e "s|__AP_IFACE_MAC__|$AP_IFACE_MAC|g" \
    -e "s|__LAN_IF__|$LAN_IF|g" \
    "$FILES_DIR/10-travelrouter.link.template")"

  mkdir -p /etc/systemd/network
  if [[ -f "$LINK_FILE" ]] && cmp -s <(printf '%s\n' "$rendered") "$LINK_FILE"; then
    log "Link file already up to date: $LINK_FILE"
  else
    if [[ -f "$LINK_FILE" ]]; then
      cp -a "$LINK_FILE" "$LINK_FILE.bak.$(date +%s)"
    fi
    printf '%s\n' "$rendered" > "$LINK_FILE"
    log "Wrote $LINK_FILE"
  fi

  udevadm control --reload
  if ip -o link | awk -F': ' '{print $2}' | grep -qx "$LAN_IF"; then
    log "Interface name $LAN_IF already present; no rename reboot needed."
  else
    REBOOT_RECOMMENDED=1
    warn "If this is first install or MAC/name changed, reboot is recommended to apply stable naming."
  fi
}

configure_networkmanager() {
  if systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
    mkdir -p /etc/NetworkManager/conf.d
    cat > "$NM_CONF" <<EOFNM
[keyfile]
unmanaged-devices=interface-name:${LAN_IF}
EOFNM
    systemctl restart NetworkManager || warn "Failed to restart NetworkManager."
    log "Configured NetworkManager to leave $LAN_IF unmanaged."
  fi
}

configure_dhcpcd() {
  if [[ -f "$DHCPCD_CONF" ]]; then
    if ! grep -q "^denyinterfaces ${LAN_IF}$" "$DHCPCD_CONF"; then
      cp -a "$DHCPCD_CONF" "$DHCPCD_CONF.bak.$(date +%s)"
      printf '\n%s\n' "denyinterfaces ${LAN_IF}" >> "$DHCPCD_CONF"
      log "Added denyinterfaces ${LAN_IF} to $DHCPCD_CONF"
    else
      log "dhcpcd already denies ${LAN_IF}."
    fi
    systemctl restart dhcpcd || warn "Failed to restart dhcpcd."
  fi
}

install_files() {
  install -m 0755 "$FILES_DIR/travelrouter-start.sh" /usr/local/bin/travelrouter-start.sh
  install -m 0755 "$FILES_DIR/travelrouter-stop.sh" /usr/local/bin/travelrouter-stop.sh
  install -m 0644 "$FILES_DIR/travelrouter.service" /etc/systemd/system/travelrouter.service
  install -m 0644 "$FILES_DIR/hostapd.conf.template" /etc/travelrouter/hostapd.conf.template
  install -m 0644 "$FILES_DIR/dnsmasq.conf.template" /etc/travelrouter/dnsmasq.conf.template

  if [[ -f /etc/default/hostapd ]]; then
    if grep -q '^#\?DAEMON_CONF=' /etc/default/hostapd; then
      sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
    else
      printf '\nDAEMON_CONF="/etc/hostapd/hostapd.conf"\n' >> /etc/default/hostapd
    fi
  fi

  systemctl daemon-reload
}

main() {
  require_root
  check_ar9271
  install_packages
  ensure_config
  load_config
  configure_link_file
  configure_networkmanager
  configure_dhcpcd
  install_files

  log "Install complete."
  echo
  echo "Next steps:"
  echo "  1) Edit config: sudo nano /etc/travelrouter/config.env"
  echo "  2) Enable and start: sudo systemctl enable --now travelrouter"
  if [[ "$REBOOT_RECOMMENDED" -eq 1 ]]; then
    echo "  3) Reboot recommended to apply MAC-based interface naming: sudo reboot"
  fi
}

main "$@"

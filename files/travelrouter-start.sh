#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/travelrouter/config.env"
HOSTAPD_TEMPLATE="/etc/travelrouter/hostapd.conf.template"
DNSMASQ_TEMPLATE="/etc/travelrouter/dnsmasq.conf.template"

log() { printf '[travelrouter-start] %s\n' "$*"; }
warn() { printf '[travelrouter-start] WARNING: %s\n' "$*" >&2; }
die() { printf '[travelrouter-start] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Must run as root"
}

validate_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  : "${SSID:?SSID is required}"
  : "${PASSPHRASE:?PASSPHRASE is required}"
  : "${AP_IFACE_MAC:?AP_IFACE_MAC is required}"
  : "${COUNTRY:=US}"
  : "${WAN_IF:=wlan0}"
  : "${LAN_IF:=wlan1}"
  : "${LAN_CIDR:=192.168.50.1/24}"
  : "${DHCP_START:=192.168.50.20}"
  : "${DHCP_END:=192.168.50.150}"

  [[ -n "$SSID" ]] || die "SSID must be non-empty"
  [[ ${#PASSPHRASE} -ge 8 ]] || die "PASSPHRASE must be at least 8 characters"
  [[ "$AP_IFACE_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || die "AP_IFACE_MAC must be xx:xx:xx:xx:xx:xx"

  if ! lsmod | awk '{print $1}' | grep -qx 'ath9k_htc'; then
    die "ath9k_htc is not loaded. This setup supports AR9271 only."
  fi

  if ! iw dev | grep -q "Interface ${LAN_IF}"; then
    warn "LAN interface ${LAN_IF} not currently visible. Check MAC-based naming and reboot if needed."
  fi
}

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

generate_configs() {
  local router_ip
  router_ip="${LAN_CIDR%/*}"

  sed \
    -e "s|__LAN_IF__|$(escape_sed "$LAN_IF")|g" \
    -e "s|__SSID__|$(escape_sed "$SSID")|g" \
    -e "s|__PASSPHRASE__|$(escape_sed "$PASSPHRASE")|g" \
    -e "s|__COUNTRY__|$(escape_sed "$COUNTRY")|g" \
    "$HOSTAPD_TEMPLATE" > /etc/hostapd/hostapd.conf

  sed \
    -e "s|__LAN_IF__|$(escape_sed "$LAN_IF")|g" \
    -e "s|__DHCP_START__|$(escape_sed "$DHCP_START")|g" \
    -e "s|__DHCP_END__|$(escape_sed "$DHCP_END")|g" \
    -e "s|__ROUTER_IP__|$(escape_sed "$router_ip")|g" \
    "$DNSMASQ_TEMPLATE" > /etc/dnsmasq.conf
}


ensure_lan_unmanaged() {
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/10-travelrouter-unmanaged.conf <<EOFNM
[keyfile]
unmanaged-devices=interface-name:${LAN_IF}
EOFNM
    nmcli device set "$LAN_IF" managed no >/dev/null 2>&1 || true
    systemctl restart NetworkManager || warn "Failed to restart NetworkManager"
  fi

  if [[ -f /etc/dhcpcd.conf ]]; then
    if ! grep -q "^denyinterfaces ${LAN_IF}$" /etc/dhcpcd.conf; then
      printf '\n%s\n' "denyinterfaces ${LAN_IF}" >> /etc/dhcpcd.conf
    fi
    systemctl restart dhcpcd >/dev/null 2>&1 || true
  fi
}

setup_interface() {
  ip link set "$LAN_IF" up

  if ip -4 addr show dev "$LAN_IF" | grep -q "${LAN_CIDR%/*}"; then
    log "LAN address already set on ${LAN_IF}"
  else
    ip -4 addr flush dev "$LAN_IF"
    ip addr add "$LAN_CIDR" dev "$LAN_IF"
  fi
}

enable_forwarding() {
  local sysctl_file="/etc/sysctl.d/99-ipforward.conf"
  if [[ ! -f "$sysctl_file" ]] || ! grep -q '^net.ipv4.ip_forward=1$' "$sysctl_file"; then
    printf 'net.ipv4.ip_forward=1\n' > "$sysctl_file"
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

setup_iptables() {
  iptables -t nat -N TRAVELROUTER_NAT 2>/dev/null || true
  iptables -N TRAVELROUTER_FWD 2>/dev/null || true

  iptables -t nat -C POSTROUTING -j TRAVELROUTER_NAT 2>/dev/null || iptables -t nat -A POSTROUTING -j TRAVELROUTER_NAT
  iptables -C FORWARD -j TRAVELROUTER_FWD 2>/dev/null || iptables -A FORWARD -j TRAVELROUTER_FWD

  iptables -t nat -C TRAVELROUTER_NAT -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A TRAVELROUTER_NAT -o "$WAN_IF" -j MASQUERADE

  iptables -C TRAVELROUTER_FWD -i "$WAN_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A TRAVELROUTER_FWD -i "$WAN_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

  iptables -C TRAVELROUTER_FWD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
    iptables -A TRAVELROUTER_FWD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null || warn "Failed to persist iptables rules"
  else
    warn "netfilter-persistent not found; rules will not survive reboot"
  fi
}

start_services() {
  systemctl unmask hostapd 2>/dev/null || true
  systemctl unmask dnsmasq 2>/dev/null || true
  systemctl enable hostapd dnsmasq >/dev/null 2>&1 || true
  systemctl restart hostapd
  systemctl restart dnsmasq
}

main() {
  require_root
  validate_config
  ensure_lan_unmanaged
  setup_interface
  generate_configs
  enable_forwarding
  setup_iptables
  start_services
  log "Travel router started."
}

main "$@"

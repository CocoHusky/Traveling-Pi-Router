#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/travelrouter/config.env"

log() { printf '[travelrouter-stop] %s\n' "$*"; }

if [[ ${EUID} -ne 0 ]]; then
  echo "[travelrouter-stop] ERROR: Must run as root" >&2
  exit 1
fi

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
: "${WAN_IF:=wlan0}"
: "${LAN_IF:=wlan1}"

systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

iptables -t nat -D TRAVELROUTER_NAT -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
iptables -D TRAVELROUTER_FWD -i "$WAN_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -D TRAVELROUTER_FWD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true

iptables -t nat -D POSTROUTING -j TRAVELROUTER_NAT 2>/dev/null || true
iptables -D FORWARD -j TRAVELROUTER_FWD 2>/dev/null || true

iptables -t nat -F TRAVELROUTER_NAT 2>/dev/null || true
iptables -F TRAVELROUTER_FWD 2>/dev/null || true
iptables -t nat -X TRAVELROUTER_NAT 2>/dev/null || true
iptables -X TRAVELROUTER_FWD 2>/dev/null || true

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
fi

log "Travel router stopped."

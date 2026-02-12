#!/usr/bin/env bash
set -euo pipefail

log() { printf '[travelrouter-uninstall] %s\n' "$*"; }
warn() { printf '[travelrouter-uninstall] WARNING: %s\n' "$*" >&2; }
die() { printf '[travelrouter-uninstall] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  die "Run as root: sudo ./uninstall.sh"
fi

systemctl disable --now travelrouter 2>/dev/null || true
/usr/local/bin/travelrouter-stop.sh 2>/dev/null || true

rm -f /etc/systemd/system/travelrouter.service
rm -f /usr/local/bin/travelrouter-start.sh /usr/local/bin/travelrouter-stop.sh
rm -f /etc/systemd/network/10-travelrouter.link
rm -f /etc/NetworkManager/conf.d/10-travelrouter-unmanaged.conf

if [[ -f /etc/dhcpcd.conf ]]; then
  sed -i '/^denyinterfaces wlan1$/d' /etc/dhcpcd.conf || warn "Could not update dhcpcd.conf"
fi

systemctl daemon-reload
systemctl restart NetworkManager 2>/dev/null || true
systemctl restart dhcpcd 2>/dev/null || true

log "Travelrouter uninstalled."
log "Config retained at /etc/travelrouter/config.env"

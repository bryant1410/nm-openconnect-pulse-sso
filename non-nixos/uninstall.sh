#!/usr/bin/env bash
#
# Uninstaller for the non-NixOS install of nm-openconnect-pulse-sso.
# Reverses everything install.sh created. Best-effort: keeps going on errors.
#
#   sudo ./uninstall.sh
#
# Leaves alone: the per-user browser profile (~/.cache/pulse-browser-auth).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIBEXEC="/usr/libexec/nm-pulse-sso"
CONFIG_DIR="/etc/nm-pulse-sso"
NM_VPN_DIR="/usr/lib/NetworkManager/VPN"
DBUS_DIR="/etc/dbus-1/system.d"
CA_TRUST="/usr/local/share/ca-certificates/pulse-browser-auth-ca.crt"
SYSTEMD_DIR="/etc/systemd/system"
SLEEP_HOOK="/usr/lib/systemd/system-sleep/nm-pulse-sso-resume"
DISPATCHER="/etc/NetworkManager/dispatcher.d/90-vpn-reconnect"
VPNC_PC="/etc/vpnc/post-connect.d"
VPNC_RC="/etc/vpnc/reconnect.d"
SYSCTL_FILE="/etc/sysctl.d/99-nm-pulse-sso-rpfilter.conf"
TRUST_BIN="/usr/local/bin/pulse-browser-auth-trust"
NM_CONN_DIR="/etc/NetworkManager/system-connections"
HOSTS_BEGIN="# nm-pulse-sso BEGIN (managed by non-nixos/install.sh)"
HOSTS_END="# nm-pulse-sso END"

msg()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo ./uninstall.sh" >&2; exit 1; }

VPN_NAME="Pulse VPN"; PROXY_PORT="8443"
# shellcheck disable=SC1090
[ -f "$SCRIPT_DIR/config.env" ] && . "$SCRIPT_DIR/config.env"
TARGET_USER="${SUDO_USER:-}"

msg "Bringing down and removing the VPN connection(s)"
OURS="org.freedesktop.NetworkManager.pulse-sso"
NETPLAN_HIT=0
# Backend-agnostic removal via nmcli. The old code scanned only
# /etc/NetworkManager/system-connections/ keyfiles — but on netplan-backed
# systems (Ubuntu) NM stores our connection as /etc/netplan/90-NM-<uuid>.yaml
# and renders it to /run/NetworkManager/system-connections/netplan-NM-*. That
# keyfile scan never saw it, which is why "Pulse VPN" survived uninstall.
# Enumerating via nmcli catches every backend; we only ever match OUR
# service-type, so a coexisting stock nm-openconnect VPN is left untouched.
if command -v nmcli >/dev/null 2>&1; then
  while IFS= read -r cuuid; do
    [ -n "$cuuid" ] || continue
    [ "$(nmcli -g vpn.service-type connection show "$cuuid" 2>/dev/null)" = "$OURS" ] || continue
    cfn="$(nmcli -g GENERAL.FILENAME connection show "$cuuid" 2>/dev/null)"
    nmcli connection down   uuid "$cuuid" >/dev/null 2>&1 || true
    nmcli connection delete uuid "$cuuid" >/dev/null 2>&1 || true
    ok "removed connection $cuuid"
    case "$cfn" in
      *netplan*)
        NETPLAN_HIT=1
        # nmcli delete asks netplan to drop its yaml on integrated systems,
        # but remove the exact source too as a backstop.
        rm -f "/etc/netplan/90-NM-$cuuid.yaml"
        ;;
    esac
  done <<EOF
$(nmcli -t -f UUID,TYPE connection show 2>/dev/null | awk -F: '$2=="vpn"{print $1}')
EOF
fi
# Belt-and-suspenders: any leftover /etc keyfiles that reference our service-type.
if [ -d "$NM_CONN_DIR" ]; then
  grep -rl "service-type=$OURS" "$NM_CONN_DIR" 2>/dev/null \
    | while IFS= read -r f; do rm -f "$f"; done
  rm -f "$NM_CONN_DIR/.pulse-sso-uuid"
fi
if [ "$NETPLAN_HIT" = 1 ] && command -v netplan >/dev/null 2>&1; then
  netplan apply >/dev/null 2>&1 || true
fi
ok "connection(s) removed"

msg "Removing NAT redirect + reconnect services"
systemctl disable --now nm-pulse-sso-browser-auth-redirect.service >/dev/null 2>&1 || true
# Belt-and-suspenders: drop the redirect rule directly if it lingers.
iptables -t nat -D OUTPUT -d 127.0.0.1/32 -p tcp --dport 443 -j REDIRECT --to-ports "$PROXY_PORT" 2>/dev/null || true
rm -f "$SYSTEMD_DIR/nm-pulse-sso-browser-auth-redirect.service"
rm -f "$SYSTEMD_DIR/vpn-auto-reconnect.service"
rm -f "$SYSTEMD_DIR/vpn-reconnect.service"   # (in case an older install created it)
systemctl daemon-reload
ok "services removed"

msg "Removing recovery hooks"
rm -f "$SLEEP_HOOK" "$DISPATCHER" "$SYSCTL_FILE"
rm -f "$VPNC_PC/00-auto-reconnect-flag" "$VPNC_PC/add-default-route" \
      "$VPNC_PC/narrow-docker-route" "$VPNC_PC/flush-dns" \
      "$VPNC_RC/fix-default-route" "$VPNC_RC/narrow-docker-route" "$VPNC_RC/flush-dns"
rm -rf /run/vpn-auto-reconnect.d
rm -f /run/vpn-auto-reconnect /run/vpn-auto-reconnect.lock /run/vpn-last-connect /run/vpn-reconnect-last-kill
# Restore rp_filter to its captured pre-install value. (A previous version
# forced =1, which is STRICTER than Ubuntu's 2/loose default and dropped
# asymmetrically-routed VPN return traffic until the next reboot.)
if [ -f "$CONFIG_DIR/rp_filter.orig" ]; then
  RPF_ALL=""; RPF_DEFAULT=""
  . "$CONFIG_DIR/rp_filter.orig" 2>/dev/null || true
  [ -n "${RPF_ALL:-}" ]     && sysctl -w net.ipv4.conf.all.rp_filter="$RPF_ALL"         >/dev/null 2>&1 || true
  [ -n "${RPF_DEFAULT:-}" ] && sysctl -w net.ipv4.conf.default.rp_filter="$RPF_DEFAULT" >/dev/null 2>&1 || true
fi
# Reassert the OS-shipped sysctl config as the authoritative fallback
# (on Ubuntu this restores rp_filter=2 from /usr/lib/sysctl.d/).
sysctl --system >/dev/null 2>&1 || true
ok "recovery hooks removed"

msg "Reverting /etc/hosts override"
tmp_hosts="$(mktemp)"
sed "/^${HOSTS_BEGIN//\//\\/}$/,/^${HOSTS_END//\//\\/}$/d" /etc/hosts > "$tmp_hosts" && \
  install -m644 "$tmp_hosts" /etc/hosts
rm -f "$tmp_hosts"
ok "hosts block removed"

msg "Removing CA trust"
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && [ -x "$TRUST_BIN" ]; then
  sudo -u "$TARGET_USER" -H "$TRUST_BIN" uninstall >/dev/null 2>&1 || true
fi
rm -f "$TRUST_BIN" "$CA_TRUST"
update-ca-certificates --fresh >/dev/null 2>&1 || update-ca-certificates >/dev/null 2>&1 || true
ok "local CA removed from system + user trust"

msg "Removing plugin, policy, and code"
rm -f "$NM_VPN_DIR/nm-pulse-sso-service.name"
rm -f "$DBUS_DIR/nm-pulse-sso-service.conf"
rm -rf "$LIBEXEC" "$CONFIG_DIR"
ok "removed $LIBEXEC, $CONFIG_DIR, .name, D-Bus policy"

msg "Restarting NetworkManager"
systemctl reload dbus 2>/dev/null || true
systemctl restart NetworkManager 2>/dev/null || true
ok "done"

echo
echo "Uninstalled. The browser profile at ~/.cache/pulse-browser-auth was left in place;"
echo "remove it yourself if you want a fully clean slate."
if [ "$NETPLAN_HIT" = 1 ]; then
  echo
  warn "One or more connections were netplan-backed and have been removed."
  warn "If a 'Pulse VPN' reappears after reboot, something is re-rendering it"
  warn "(a file under /etc/netplan, or corporate config management). Check:"
  warn "    nmcli -f NAME,UUID,FILENAME connection show | grep -i pulse"
  warn "    ls -l /etc/netplan/90-NM-*.yaml"
fi

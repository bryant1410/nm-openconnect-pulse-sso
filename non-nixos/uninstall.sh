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

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo ./uninstall.sh" >&2; exit 1; }

VPN_NAME="Pulse VPN"; PROXY_PORT="8443"
# shellcheck disable=SC1090
[ -f "$SCRIPT_DIR/config.env" ] && . "$SCRIPT_DIR/config.env"
TARGET_USER="${SUDO_USER:-}"

msg "Bringing down and removing the VPN connection(s)"
# Enumerate every keyfile that references our service-type and down+delete+remove
# it, so ALL configured connections go regardless of what config.env now says.
if [ -d "$NM_CONN_DIR" ]; then
  grep -rl "service-type=org.freedesktop.NetworkManager.pulse-sso" "$NM_CONN_DIR" 2>/dev/null \
    | while IFS= read -r f; do
        cuuid="$(sed -n 's/^uuid=//p' "$f" | head -1)"
        cid="$(sed -n 's/^id=//p' "$f" | head -1)"
        if [ -n "$cuuid" ]; then
          nmcli connection down uuid "$cuuid"   >/dev/null 2>&1 || true
          nmcli connection delete uuid "$cuuid" >/dev/null 2>&1 || true
        elif [ -n "$cid" ]; then
          nmcli connection down "$cid"   >/dev/null 2>&1 || true
          nmcli connection delete "$cid" >/dev/null 2>&1 || true
        fi
        rm -f "$f"
      done
  rm -f "$NM_CONN_DIR/.pulse-sso-uuid"
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

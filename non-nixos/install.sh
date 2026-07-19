#!/usr/bin/env bash
#
# Installer for nm-openconnect-pulse-sso on non-NixOS systems (Ubuntu/Debian).
#
# Reproduces, on a standard FHS layout, what browser-auth/default.nix and
# module.nix do on NixOS for the "desktop browser + MITM proxy" backend, with
# the full auto-reconnect recovery layer.
#
# It does NOT modify any tracked file in this repo. It copies the runtime code
# into /usr/libexec and installs thin wrapper scripts that inject exactly the
# flags/env that Nix's wrapProgram would have injected.
#
# Usage:
#   1. edit config.env  (set GATEWAY)
#   2. sudo ./install.sh
#   3. nmcli connection up "Pulse VPN"
#
# Re-running is safe (idempotent). Set FORCE_PKI=1 to regenerate the local CA.

set -euo pipefail

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

LIBEXEC="/usr/libexec/nm-pulse-sso"
IMPL="$LIBEXEC/impl"
CONFIG_DIR="/etc/nm-pulse-sso"
PKI="$CONFIG_DIR/pki"
NM_VPN_DIR="/usr/lib/NetworkManager/VPN"
DBUS_DIR="/etc/dbus-1/system.d"
CA_TRUST="/usr/local/share/ca-certificates/pulse-browser-auth-ca.crt"
SYSTEMD_DIR="/etc/systemd/system"
SLEEP_HOOK_DIR="/usr/lib/systemd/system-sleep"
DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"
VPNC_PC="/etc/vpnc/post-connect.d"
VPNC_RC="/etc/vpnc/reconnect.d"
SYSCTL_FILE="/etc/sysctl.d/99-nm-pulse-sso-rpfilter.conf"
TRUST_BIN="/usr/local/bin/pulse-browser-auth-trust"
NM_CONN_DIR="/etc/NetworkManager/system-connections"
HOSTS_BEGIN="# nm-pulse-sso BEGIN (managed by non-nixos/install.sh)"
HOSTS_END="# nm-pulse-sso END"
SYS_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

msg()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Preconditions + config
# --------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo ./install.sh"

CONF="$SCRIPT_DIR/config.env"
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi
# GATEWAY may also be supplied via the environment (sudo GATEWAY=... ./install.sh).
if [ -z "${GATEWAY:-}" ]; then
  die "GATEWAY is not set.
  Copy the example and edit it (config.env is gitignored, so your gateway is never committed):
      cp \"$SCRIPT_DIR/config.env.example\" \"$SCRIPT_DIR/config.env\"
      \$EDITOR \"$SCRIPT_DIR/config.env\"
  ...or pass it inline:  sudo GATEWAY=https://vpn.example.com/saml ./install.sh"
fi
VPN_NAME="${VPN_NAME:-Pulse VPN}"
PROXY_PORT="${PROXY_PORT:-8443}"
ENABLE_DTLS="${ENABLE_DTLS:-true}"
VPN_MTU="${VPN_MTU:-1300}"
ENABLE_RECOVERY="${ENABLE_RECOVERY:-true}"

case "$VPN_NAME" in
  *[!A-Za-z0-9\ ._-]*) die "VPN_NAME contains unsupported characters; use letters, digits, space, . _ -" ;;
esac

# Gateway hostname: strip scheme, path, and port (mirrors module.nix gateway-hostname)
GATEWAY_HOST="${GATEWAY#*://}"; GATEWAY_HOST="${GATEWAY_HOST%%/*}"; GATEWAY_HOST="${GATEWAY_HOST%%:*}"
[ -n "$GATEWAY_HOST" ] || die "Could not parse a hostname from GATEWAY='$GATEWAY'"

# Locate vpnc-script (baked into the helper wrapper as VPNC_SCRIPT)
VPNC_SCRIPT_PATH=""
for c in /usr/share/vpnc-scripts/vpnc-script /etc/vpnc/vpnc-script "$(command -v vpnc-script 2>/dev/null || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { VPNC_SCRIPT_PATH="$c"; break; }
done
[ -n "$VPNC_SCRIPT_PATH" ] || die "vpnc-script not found (install the 'vpnc-scripts' package)"

CERTUTIL="$(command -v certutil || true)"
TARGET_USER="${SUDO_USER:-}"

msg "Configuration"
ok "gateway URL : $GATEWAY"
ok "gateway host: $GATEWAY_HOST"
ok "connection  : $VPN_NAME"
ok "proxy port  : $PROXY_PORT"
ok "DTLS        : $ENABLE_DTLS    MTU: ${VPN_MTU:-<server default>}    recovery: $ENABLE_RECOVERY"
ok "vpnc-script : $VPNC_SCRIPT_PATH"

# --------------------------------------------------------------------------
# Dependency check
# --------------------------------------------------------------------------
msg "Checking dependencies"
apt_pkgs=""
add_pkg() { case " $apt_pkgs " in *" $1 "*) ;; *) apt_pkgs="$apt_pkgs $1" ;; esac; }
need() { command -v "$1" >/dev/null 2>&1 || { warn "missing: $1"; add_pkg "$2"; }; }
need openconnect openconnect
need nmcli network-manager
need iptables iptables
need openssl openssl
need update-ca-certificates ca-certificates
[ -n "$CERTUTIL" ] || { warn "missing: certutil"; add_pkg libnss3-tools; }
[ -x "$VPNC_SCRIPT_PATH" ] || add_pkg vpnc-scripts
[ -x /usr/bin/python3 ] || { warn "missing: /usr/bin/python3"; add_pkg python3; }
if ! /usr/bin/python3 -c 'import gi, dbus' 2>/dev/null; then
  warn "missing: python3 'gi' and/or 'dbus' modules"
  add_pkg python3-gi; add_pkg python3-dbus
fi
if [ -n "$apt_pkgs" ]; then
  die "Install the missing dependencies first:
      sudo apt install$apt_pkgs"
fi
ok "all dependencies present"

# --------------------------------------------------------------------------
# Local CA + server cert for the MITM proxy (mirrors module.nix:26-48)
# --------------------------------------------------------------------------
msg "Local PKI ($PKI)"
install -d -m700 "$PKI"
if [ "${FORCE_PKI:-0}" = 1 ] || [ ! -s "$PKI/ca.crt" ] || [ ! -s "$PKI/server.crt" ]; then
  openssl genrsa -out "$PKI/ca.key" 2048 2>/dev/null
  openssl req -new -x509 -days 3650 -key "$PKI/ca.key" -out "$PKI/ca.crt" \
    -subj "/CN=Pulse Browser Auth Local CA" 2>/dev/null
  openssl genrsa -out "$PKI/server.key" 2048 2>/dev/null
  openssl req -new -key "$PKI/server.key" -out "$PKI/server.csr" \
    -subj "/CN=$GATEWAY_HOST" 2>/dev/null
  openssl x509 -req -days 3650 -in "$PKI/server.csr" \
    -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial -out "$PKI/server.crt" \
    -extfile <(printf 'subjectAltName=DNS:%s\n' "$GATEWAY_HOST") 2>/dev/null
  chmod 600 "$PKI"/*.key
  ok "generated CA + server cert (SAN=$GATEWAY_HOST)"
else
  ok "keeping existing CA/cert (FORCE_PKI=1 to regenerate)"
fi

# --------------------------------------------------------------------------
# Runtime code + wrappers (mirrors browser-auth/default.nix install+postFixup)
# --------------------------------------------------------------------------
msg "Runtime code ($LIBEXEC)"
install -d -m755 "$LIBEXEC" "$IMPL"
install -m755 "$REPO_DIR/vpn-service/nm-pulse-sso-service.py" "$IMPL/nm-pulse-sso-service.py"
install -m755 "$REPO_DIR/vpn-service/nm-pulse-sso-helper"     "$IMPL/nm-pulse-sso-helper"
install -m755 "$REPO_DIR/browser-auth/auth-dialog"           "$IMPL/pulse-sso-auth-dialog"
install -m644 "$REPO_DIR/browser-auth/proxy.py"              "$IMPL/proxy.py"
ok "copied service, helper, auth-dialog, proxy"

# Wrapper: D-Bus VPN service (root). Adds --helper-script; ensures PATH has openconnect.
cat > "$LIBEXEC/nm-pulse-sso-service" <<EOF
#!/bin/sh
export PATH="$SYS_PATH"
exec /usr/bin/python3 "$IMPL/nm-pulse-sso-service.py" \\
  --helper-script "$LIBEXEC/nm-pulse-sso-helper" \\
  "\$@"
EOF

# Wrapper: openconnect --script helper. Sets VPNC_SCRIPT + PATH.
# NAME MATTERS: the service derives the auth-dialog path from this filename
# (nm-pulse-sso-service.py: helper_script.replace("nm-pulse-sso-helper","pulse-sso-auth-dialog")).
cat > "$LIBEXEC/nm-pulse-sso-helper" <<EOF
#!/bin/sh
export PATH="$SYS_PATH"
export VPNC_SCRIPT="$VPNC_SCRIPT_PATH"
exec /usr/bin/python3 "$IMPL/nm-pulse-sso-helper" "\$@"
EOF

# Wrapper: auth-dialog. Bakes proxy binary + cert/key + port (service only re-supplies --proxy-port).
cat > "$LIBEXEC/pulse-sso-auth-dialog" <<EOF
#!/bin/sh
exec /usr/bin/python3 "$IMPL/pulse-sso-auth-dialog" \\
  --proxy-binary "$LIBEXEC/pulse-browser-proxy" \\
  --cert "$PKI/server.crt" \\
  --key "$PKI/server.key" \\
  --proxy-port "$PROXY_PORT" \\
  "\$@"
EOF

# Wrapper: the MITM proxy (pure stdlib).
cat > "$LIBEXEC/pulse-browser-proxy" <<EOF
#!/bin/sh
exec /usr/bin/python3 "$IMPL/proxy.py" "\$@"
EOF

chmod 755 "$LIBEXEC/nm-pulse-sso-service" "$LIBEXEC/nm-pulse-sso-helper" \
          "$LIBEXEC/pulse-sso-auth-dialog" "$LIBEXEC/pulse-browser-proxy"
ok "installed 4 wrappers"

# --------------------------------------------------------------------------
# NetworkManager plugin descriptor + D-Bus policy
# --------------------------------------------------------------------------
msg "NetworkManager plugin + D-Bus policy"
install -d -m755 "$NM_VPN_DIR"
sed -e "s#@SERVICE_BIN@#$LIBEXEC/nm-pulse-sso-service#g" \
    -e "s#@AUTH_DIALOG_BIN@#$LIBEXEC/pulse-sso-auth-dialog#g" \
    "$REPO_DIR/dbus/nm-pulse-sso-service.name.in" > "$NM_VPN_DIR/nm-pulse-sso-service.name"
chmod 644 "$NM_VPN_DIR/nm-pulse-sso-service.name"
install -Dm644 "$REPO_DIR/dbus/nm-pulse-sso-service.conf" "$DBUS_DIR/nm-pulse-sso-service.conf"
ok "installed .name descriptor and D-Bus policy"

# --------------------------------------------------------------------------
# Runtime config file read by the service (mirrors module.nix:679)
# --------------------------------------------------------------------------
msg "Service config ($CONFIG_DIR/config)"
{
  echo "# Managed by nm-openconnect-pulse-sso non-nixos installer - do not edit"
  echo "ENABLE_DTLS=$ENABLE_DTLS"
  echo "ENABLE_TCP_KEEPALIVE=false"
  echo "TCP_KEEPALIVE_INTERVAL=120"
  [ -n "$VPN_MTU" ] && echo "VPN_MTU=$VPN_MTU"
} > "$CONFIG_DIR/config"
chmod 644 "$CONFIG_DIR/config"
ok "wrote config"

# --------------------------------------------------------------------------
# CA trust: system store + per-user browser NSS DBs
# --------------------------------------------------------------------------
msg "CA trust"
install -Dm644 "$PKI/ca.crt" "$CA_TRUST"
update-ca-certificates >/dev/null 2>&1 || warn "update-ca-certificates reported an issue"
ok "added local CA to the system trust store"

# Per-user trust installer (Chrome/Chromium NSS + Firefox profiles)
sed -e "s#@CA_CERT@#$PKI/ca.crt#g" -e "s#@CERTUTIL@#$CERTUTIL#g" \
    "$REPO_DIR/browser-auth/trust-install.sh" > "$TRUST_BIN"
chmod 755 "$TRUST_BIN"
ok "installed $TRUST_BIN"

if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
  if sudo -u "$TARGET_USER" -H "$TRUST_BIN" install >/dev/null 2>&1; then
    ok "trusted local CA in $TARGET_USER's browser NSS DBs"
  else
    warn "could not auto-install browser trust for $TARGET_USER — run: pulse-browser-auth-trust install"
  fi
else
  warn "run this as your desktop user later:  pulse-browser-auth-trust install"
fi

# --------------------------------------------------------------------------
# /etc/hosts override: gateway host -> 127.0.0.1 (mirrors module.nix:644)
# --------------------------------------------------------------------------
msg "/etc/hosts override"
tmp_hosts="$(mktemp)"
sed "/^${HOSTS_BEGIN//\//\\/}$/,/^${HOSTS_END//\//\\/}$/d" /etc/hosts > "$tmp_hosts"
{
  echo "$HOSTS_BEGIN"
  echo "127.0.0.1 $GATEWAY_HOST"
  echo "$HOSTS_END"
} >> "$tmp_hosts"
install -m644 "$tmp_hosts" /etc/hosts
rm -f "$tmp_hosts"
ok "$GATEWAY_HOST -> 127.0.0.1"

# --------------------------------------------------------------------------
# Permanent NAT redirect 127.0.0.1:443 -> :PROXY_PORT (mirrors module.nix:655)
# --------------------------------------------------------------------------
msg "NAT redirect service (443 -> $PROXY_PORT)"
cat > "$SYSTEMD_DIR/nm-pulse-sso-browser-auth-redirect.service" <<EOF
[Unit]
Description=NAT redirect for nm-pulse-sso browser-auth proxy
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t nat -C OUTPUT -d 127.0.0.1/32 -p tcp --dport 443 -j REDIRECT --to-ports $PROXY_PORT 2>/dev/null || iptables -t nat -A OUTPUT -d 127.0.0.1/32 -p tcp --dport 443 -j REDIRECT --to-ports $PROXY_PORT'
ExecStop=/bin/sh -c 'iptables -t nat -D OUTPUT -d 127.0.0.1/32 -p tcp --dport 443 -j REDIRECT --to-ports $PROXY_PORT 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now nm-pulse-sso-browser-auth-redirect.service >/dev/null 2>&1 || \
  warn "could not start the NAT redirect service — check: systemctl status nm-pulse-sso-browser-auth-redirect"
ok "redirect active"

# --------------------------------------------------------------------------
# Recovery layer (mirrors module.nix enableRecovery)
# --------------------------------------------------------------------------
# Substitute Nix placeholders (@pkg@/bin/cmd -> cmd on PATH, @vpnName@ -> name),
# and inject an explicit PATH after the shebang so bare commands resolve.
subst_script() {  # src dst mode
  awk -v vpnname="$VPN_NAME" -v syspath="$SYS_PATH" '
    NR==1 { print; print "export PATH=" syspath; next }
    { gsub(/@[A-Za-z0-9_-]+@\/bin\//, ""); gsub(/@vpnName@/, vpnname); print }
  ' "$1" > "$2"
  chmod "$3" "$2"
}

if [ "$ENABLE_RECOVERY" = "true" ]; then
  msg "Recovery layer"

  subst_script "$REPO_DIR/scripts/vpn-reconnect.sh"      "$LIBEXEC/vpn-reconnect.sh"      755
  subst_script "$REPO_DIR/scripts/vpn-auto-reconnect.sh" "$LIBEXEC/vpn-auto-reconnect.sh" 755
  ok "installed reconnect scripts"

  # NetworkManager dispatcher (interface/connectivity changes)
  install -d -m755 "$DISPATCHER_DIR"
  subst_script "$REPO_DIR/scripts/nm-dispatcher.sh" "$DISPATCHER_DIR/90-vpn-reconnect" 755
  ok "installed NM dispatcher 90-vpn-reconnect"

  # vpnc hooks (run by vpnc-script from /etc/vpnc/{post-connect,reconnect}.d)
  install -d -m755 "$VPNC_PC" "$VPNC_RC"
  subst_script "$REPO_DIR/scripts/vpnc/post-connect-auto-reconnect-flag.sh" "$VPNC_PC/00-auto-reconnect-flag" 755
  subst_script "$REPO_DIR/scripts/vpnc/post-connect-default-route.sh"       "$VPNC_PC/add-default-route"       755
  subst_script "$REPO_DIR/scripts/vpnc/post-connect-narrow-docker.sh"       "$VPNC_PC/narrow-docker-route"     755
  subst_script "$REPO_DIR/scripts/vpnc/post-connect-flush-dns.sh"           "$VPNC_PC/flush-dns"               755
  subst_script "$REPO_DIR/scripts/vpnc/reconnect-default-route.sh"          "$VPNC_RC/fix-default-route"       755
  subst_script "$REPO_DIR/scripts/vpnc/reconnect-narrow-docker.sh"          "$VPNC_RC/narrow-docker-route"     755
  subst_script "$REPO_DIR/scripts/vpnc/reconnect-flush-dns.sh"              "$VPNC_RC/flush-dns"               755
  ok "installed vpnc hooks"

  # On-demand reconnect service (triggered by the dispatcher + the resume hook)
  cat > "$SYSTEMD_DIR/vpn-auto-reconnect.service" <<EOF
[Unit]
Description=Auto-reconnect VPN via nmcli
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$LIBEXEC/vpn-auto-reconnect.sh
TimeoutStartSec=120
EOF

  # Resume trigger. NixOS uses post-resume.target (not present on Ubuntu), so we
  # use the standard systemd-sleep hook mechanism instead.
  install -d -m755 "$SLEEP_HOOK_DIR"
  cat > "$SLEEP_HOOK_DIR/nm-pulse-sso-resume" <<EOF
#!/bin/sh
# systemd-sleep hook: after resume, kill stale openconnect and trigger reconnect.
case "\$1" in
  post)
    "$LIBEXEC/vpn-reconnect.sh" || true
    systemctl start --no-block vpn-auto-reconnect.service 2>/dev/null || true
    ;;
esac
EOF
  chmod 755 "$SLEEP_HOOK_DIR/nm-pulse-sso-resume"
  systemctl daemon-reload
  ok "installed vpn-auto-reconnect.service + resume sleep hook"

  # rp_filter=loose (NixOS checkReversePath="loose" equivalent)
  cat > "$SYSCTL_FILE" <<EOF
# Loose reverse-path filtering: required for reliable VPN reconnection
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
  sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported an issue"
  ok "set rp_filter=loose"
else
  msg "Recovery layer skipped (ENABLE_RECOVERY=$ENABLE_RECOVERY)"
  # flush-dns hooks are installed even without recovery on NixOS; keep parity.
  install -d -m755 "$VPNC_PC" "$VPNC_RC"
  subst_script "$REPO_DIR/scripts/vpnc/post-connect-flush-dns.sh" "$VPNC_PC/flush-dns" 755
  subst_script "$REPO_DIR/scripts/vpnc/reconnect-flush-dns.sh"    "$VPNC_RC/flush-dns" 755
fi

# --------------------------------------------------------------------------
# NetworkManager connection profile (keyfile; mirrors module.nix:531)
# --------------------------------------------------------------------------
msg "NetworkManager connection profile"
CONN_FILE="$NM_CONN_DIR/${VPN_NAME}.nmconnection"
CONN_UUID="$(cat "$NM_CONN_DIR/.pulse-sso-uuid" 2>/dev/null || true)"
if [ -z "$CONN_UUID" ]; then
  CONN_UUID="$(/usr/bin/python3 -c 'import uuid; print(uuid.uuid4())')"
  printf '%s' "$CONN_UUID" > "$NM_CONN_DIR/.pulse-sso-uuid" 2>/dev/null || true
fi
install -d -m755 "$NM_CONN_DIR"
cat > "$CONN_FILE" <<EOF
[connection]
id=$VPN_NAME
uuid=$CONN_UUID
type=vpn
autoconnect=false

[vpn]
service-type=org.freedesktop.NetworkManager.pulse-sso
gateway=$GATEWAY
persistent=true

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 "$CONN_FILE"
chown root:root "$CONN_FILE"
ok "wrote $CONN_FILE"

# --------------------------------------------------------------------------
# Activate
# --------------------------------------------------------------------------
msg "Activating"
systemctl reload dbus 2>/dev/null || systemctl reload dbus.service 2>/dev/null || true
systemctl restart NetworkManager
nmcli connection reload 2>/dev/null || true
ok "reloaded D-Bus policy and restarted NetworkManager"

echo
msg "Done."
cat <<EOF

Connect with:
    nmcli connection up "$VPN_NAME"
  (or pick "$VPN_NAME" from the GNOME/KDE network menu)

Your default browser will open the gateway for SSO. After you finish signing in,
the tab can be closed and the tunnel comes up.

Verify:
    nmcli connection show --active
    ip addr show tun0
    journalctl -u NetworkManager -f          # watch auth/connect live

If the browser shows a certificate warning, fully quit it and run (as your user):
    pulse-browser-auth-trust install

Uninstall:
    sudo $SCRIPT_DIR/uninstall.sh
EOF

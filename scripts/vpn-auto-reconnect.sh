#!/bin/sh
#
# External VPN auto-reconnect service
#
# Triggered by: vpn-reconnect (post-resume), nm-dispatcher (network change)
# Uses nmcli (same as a user would) — avoids all NM plugin state machine conflicts.
#
# Two flag schemes are supported (per-connection wins when present):
#   - Per-connection (multi-connection installs): /run/vpn-auto-reconnect.d/<uuid>
#     written by the D-Bus service on connect, removed on user disconnect.
#     Reconnect each flagged connection by UUID — brings back exactly what was
#     active before a suspend/roam.
#   - Legacy single flag (older/NixOS single-connection installs):
#     /run/vpn-auto-reconnect — reconnect the one connection named @vpnName@.

VPN_NAME="@vpnName@"
FLAG_DIR="/run/vpn-auto-reconnect.d"
LEGACY_FLAG="/run/vpn-auto-reconnect"
LOCK="/run/vpn-auto-reconnect.lock"

# Emit reconnect targets, one per line: "<kind> <ref>" (kind is uuid|id).
emit_targets() {
    if [ -d "$FLAG_DIR" ] && [ -n "$(ls -A "$FLAG_DIR" 2>/dev/null)" ]; then
        for f in "$FLAG_DIR"/*; do
            [ -e "$f" ] || continue
            echo "uuid ${f##*/}"
        done
    elif [ -f "$LEGACY_FLAG" ]; then
        echo "id $VPN_NAME"
    fi
}

# Is the target's flag still present? (user may disconnect during our wait)
flag_present() {  # kind ref
    case "$1" in
        uuid) [ -e "$FLAG_DIR/$2" ] ;;
        *)    [ -f "$LEGACY_FLAG" ] ;;
    esac
}

# VPN state for a target: prints activated|activating|"".
conn_state() {  # kind ref
    case "$1" in
        uuid) @networkmanager@/bin/nmcli -t -f UUID,TYPE,STATE connection show --active 2>/dev/null \
                | @gawk@/bin/awk -F: -v k="$2" '$1==k && $2=="vpn" {print $3}' ;;
        *)    @networkmanager@/bin/nmcli -t -f NAME,TYPE,STATE connection show --active 2>/dev/null \
                | @gawk@/bin/awk -F: -v k="$2" '$1==k && $2=="vpn" {print $3}' ;;
    esac
}

TARGETS_FILE=$(mktemp)
emit_targets > "$TARGETS_FILE"
if [ ! -s "$TARGETS_FILE" ]; then
    echo "Auto-reconnect not enabled (no flag), skipping"
    rm -f "$TARGETS_FILE"
    exit 0
fi

# Lock to prevent concurrent reconnect attempts
exec 200>"$LOCK"
@util-linux@/bin/flock -n 200 || { echo "Another reconnect attempt in progress"; rm -f "$TARGETS_FILE"; exit 0; }

# Kill any lingering openconnect processes (e.g., stale after resume).
# (install.sh rewrites the bare `-x openconnect` matches below to our --script
# helper path, so we never touch a coexisting official Pulse/AnyConnect tunnel.)
if @procps@/bin/pgrep -x openconnect >/dev/null 2>&1; then
    @procps@/bin/pkill -x openconnect 2>/dev/null || true
    sleep 2
    if @procps@/bin/pgrep -x openconnect >/dev/null 2>&1; then
        @procps@/bin/pkill -9 -x openconnect 2>/dev/null || true
        sleep 1
    fi
fi

# Wait for network connectivity (up to 20s)
# Track whether NM was already connected on first check (no wait needed).
nm_was_ready="no"
for i in $(@coreutils@/bin/seq 1 10); do
    if @networkmanager@/bin/nmcli -t -f STATE general status 2>/dev/null | grep -q "connected"; then
        if [ "$i" -eq 1 ]; then nm_was_ready="yes"; fi
        break
    fi
    echo "Waiting for network connectivity... ($i/10)"
    sleep 2
done

# Only pause to let NM settle if we had to wait for connectivity.
if [ "$nm_was_ready" != "yes" ]; then
    sleep 3
fi

# Verify a default route exists.  NM reports "connected" even when the
# default route is missing (e.g. after VPN teardown raced with an interface
# change).  Without a default route, every VPN connection attempt will fail
# immediately.  Fix by reapplying the active connection.
HAS_DEFAULT=$(@iproute2@/bin/ip route show default 2>/dev/null | head -1)
if [ -z "$HAS_DEFAULT" ]; then
    echo "No default route — attempting to repair"
    for dev in $(ls /sys/class/net/ | grep -v -E "^(lo|tun|tap|docker|br-|veth|tailscale)"); do
        if [ -f "/sys/class/net/$dev/carrier" ]; then
            CARRIER=$(cat "/sys/class/net/$dev/carrier" 2>/dev/null || echo "0")
            if [ "$CARRIER" = "1" ]; then
                @networkmanager@/bin/nmcli device reapply "$dev" 2>/dev/null || true
                sleep 1
                HAS_DEFAULT=$(@iproute2@/bin/ip route show default 2>/dev/null | head -1)
                if [ -z "$HAS_DEFAULT" ]; then
                    CONN=$(@networkmanager@/bin/nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${dev}$" | head -1 | cut -d: -f1)
                    if [ -n "$CONN" ]; then
                        echo "Reapply failed — bouncing $dev ($CONN)"
                        @networkmanager@/bin/nmcli connection down "$CONN" 2>/dev/null || true
                        sleep 1
                        @networkmanager@/bin/nmcli connection up "$CONN" 2>/dev/null || true
                        sleep 2
                    fi
                fi
                break
            fi
        fi
    done
fi

# Flush DNS caches (stale after resume)
@systemd@/bin/resolvectl flush-caches 2>/dev/null || true
@systemd@/bin/resolvectl reset-server-features 2>/dev/null || true

notify_all() {  # icon title body
    for uid in $(@systemd@/bin/loginctl list-users --no-legend | @gawk@/bin/awk '{print $1}'); do
        RUNTIME_DIR="/run/user/$uid"
        if [ -S "$RUNTIME_DIR/bus" ]; then
            @sudo@/bin/sudo -u "#$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
                @libnotify@/bin/notify-send -i "$1" "$2" "$3" 2>/dev/null || true
        fi
    done
}

# Reconnect each target that isn't already up, with per-attempt backoff.
# Typical usage keeps exactly one connection active, so this loop usually runs
# once; it also handles the multi-tunnel case without a hardcoded name.
# Read from a file (not a pipe) so the loop runs in this shell and connection
# names containing spaces survive intact.
overall_rc=0
while IFS=' ' read -r kind ref; do
    [ -n "$kind" ] || continue

    if [ "$kind" = "uuid" ]; then
        name=$(@networkmanager@/bin/nmcli -t -f UUID,NAME connection show 2>/dev/null \
                 | @gawk@/bin/awk -F: -v u="$ref" '$1==u {print $2; exit}')
        [ -n "$name" ] || name="$ref"
    else
        name="$ref"
    fi

    result="failed"
    for attempt in 1 2 3 4 5; do
        flag_present "$kind" "$ref" || { echo "[$name] flag removed — user disconnected, skipping"; result="skip"; break; }

        state=$(conn_state "$kind" "$ref")
        if [ "$state" = "activated" ]; then
            echo "[$name] already connected"
            result="ok"; break
        fi
        if [ "$state" = "activating" ]; then
            echo "[$name] already activating (auth dialog running), skipping duplicate attempt"
            result="ok"; break
        fi

        echo "[$name] reconnect attempt $attempt..."
        if @networkmanager@/bin/nmcli connection up "$kind" "$ref" 2>&1; then
            echo "[$name] reconnected successfully"
            notify_all network-vpn "VPN Reconnected" "$name auto-reconnected successfully"
            result="ok"; break
        fi

        DELAY=$((attempt * 3))
        echo "[$name] attempt $attempt failed, retrying in ${DELAY}s..."
        sleep "$DELAY"
    done

    if [ "$result" = "failed" ]; then
        echo "[$name] reconnect failed after 5 attempts"
        notify_all dialog-warning "VPN Reconnect Failed" "$name: auto-reconnect failed after 5 attempts. Please reconnect manually."
        overall_rc=1
    fi
done < "$TARGETS_FILE"
rm -f "$TARGETS_FILE"

exit "$overall_rc"

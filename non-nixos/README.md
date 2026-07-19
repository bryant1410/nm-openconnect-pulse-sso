# non-NixOS install (Ubuntu / Debian)

The main project targets NixOS. This directory installs the same thing on a
standard Debian/Ubuntu system with **systemd + NetworkManager**, using the
**desktop-browser + MITM-proxy** auth backend (`../browser-auth/`) and the full
auto-reconnect recovery layer.

It does **not** require Nix, and it does **not** modify any other file in the
repo. It copies the runtime code into `/usr/libexec/nm-pulse-sso/` and installs
thin wrapper scripts that supply the flags/env that Nix's `wrapProgram` would.

## Quick start

On any Ubuntu/Debian machine, from a clone of your fork:

```bash
cd nm-openconnect-pulse-sso/non-nixos
cp config.env.example config.env     # then set GATEWAY (full URL incl. realm path)
$EDITOR config.env
sudo ./install.sh                    # idempotent; prints any missing apt deps
nmcli connection up "Pulse VPN"      # your default browser opens for SSO
```

`install.sh` does not touch anything until you run it, and it can be re-run any
time after editing `config.env`. See [Install](#install) for details,
[Verify](#verify-run-these-yourself-after-installing) to confirm it worked, and
[Uninstall](#uninstall) to remove it.

## Why the browser backend

No compiling. It drives your **already-installed** Chrome/Firefox for the SSO
step (so Yubikey/WebAuthn, saved passwords, and extensions all just work). A
small pure-stdlib Python proxy on `127.0.0.1` captures the `DSID` cookie from
the gateway's `Set-Cookie` response.

The trade-off (vs. the NixOS default CEF backend) is that it's more invasive to
the host — see [Caveats](#caveats).

## Install

Works on any Ubuntu/Debian machine — clone your fork, configure, run:

```bash
git clone <your-fork-url>
cd nm-openconnect-pulse-sso/non-nixos

cp config.env.example config.env     # config.env is gitignored
$EDITOR config.env                   # set GATEWAY (required)

sudo ./install.sh
```

`install.sh` is idempotent — safe to re-run after editing `config.env`.
If dependencies are missing it prints the exact `apt install …` line and stops.

> **Privacy / fork safety.** `config.env` holds your real gateway URL and is
> gitignored — it is never committed. Keep `config.env.example` generic
> (`vpn.example.com`). You can also skip the file entirely:
> `sudo GATEWAY=https://vpn.example.com/saml ./install.sh`.

## Connect

```bash
nmcli connection up "Pulse VPN"      # or pick it from the GNOME/KDE network menu
```

Your default browser opens the gateway for SSO. When sign-in completes, the tab
can be closed and the tunnel comes up.

## Choosing the gateway realm (e.g. `emp` vs `emp-split`)

The realm is just the **path** of the gateway URL — nothing is hardcoded. Set
`GATEWAY` in `config.env` to the URL your VPN admin gives you, including the
realm path, e.g. `.../emp` (full tunnel) or `.../emp-split` (split tunnel).
Changing it only affects the stored connection; the hostname (used for
`/etc/hosts` and the local cert) is unchanged. Re-run `sudo ./install.sh` after
editing.

## What gets installed

| Area | Location |
|---|---|
| Runtime code + wrappers | `/usr/libexec/nm-pulse-sso/` |
| NM VPN plugin descriptor | `/usr/lib/NetworkManager/VPN/nm-pulse-sso-service.name` |
| D-Bus policy | `/etc/dbus-1/system.d/nm-pulse-sso-service.conf` |
| Service config | `/etc/nm-pulse-sso/config` |
| Local CA + server cert | `/etc/nm-pulse-sso/pki/` (root-only) |
| System CA trust | `/usr/local/share/ca-certificates/pulse-browser-auth-ca.crt` |
| Per-user browser trust | `pulse-browser-auth-trust` (Chrome NSS + Firefox profiles) |
| Gateway → loopback | `/etc/hosts` (managed block) |
| NAT 443 → proxy | `nm-pulse-sso-browser-auth-redirect.service` |
| NM connection | `/etc/NetworkManager/system-connections/<name>.nmconnection` |
| Recovery (if enabled) | `vpn-auto-reconnect.service`, a `system-sleep` resume hook, NM dispatcher `90-vpn-reconnect`, vpnc hooks in `/etc/vpnc/*.d/`, `rp_filter=loose` |

> On NixOS the resume trigger uses `post-resume.target`; that target does not
> exist on stock Ubuntu, so this installer uses a standard systemd
> [`system-sleep`](https://www.freedesktop.org/software/systemd/man/systemd-suspend.service.html)
> hook instead.

## Verify (run these yourself after installing)

```bash
nmcli -f vpn.service-type connection show "Pulse VPN"   # org.freedesktop.NetworkManager.pulse-sso
getent hosts <gateway-host>                             # -> 127.0.0.1
iptables -t nat -L OUTPUT -n | grep 8443                # permanent redirect present
certutil -L -d sql:$HOME/.pki/nssdb | grep "Pulse"     # local CA trusted for Chrome
journalctl -u NetworkManager -f                         # watch auth + connect live
# after connecting:
nmcli connection show --active
ip addr show tun0
```

## Troubleshooting

- **Browser shows a cert warning** on the gateway: fully quit the browser, then
  run (as your normal user, not root): `pulse-browser-auth-trust install`.
  Chrome caches NSS trust at process start, so it must be fully restarted.
- **No browser window appears**: the service launches it as your desktop user
  via `systemd-run --user`, which needs an active graphical session. Check
  `journalctl -u NetworkManager` for the auth-dialog launch line.
- **Missing dependencies on a fresh machine**: `install.sh` prints the
  `apt install …` line. Typical set:
  `sudo apt install openconnect vpnc-scripts network-manager libnss3-tools python3-gi python3-dbus`.
- **`iptables` on Ubuntu ≥ 22.04** is the nftables-backed shim; the NAT redirect
  rule works through it. Verify with `iptables -t nat -L OUTPUT -n`.
- **Non-Debian distro**: the CA-trust step assumes `update-ca-certificates` and
  `/usr/local/share/ca-certificates/`. On Fedora/RHEL adapt to `update-ca-trust`
  and `/etc/pki/ca-trust/source/anchors/`.

## Caveats

- A **local MITM CA** is trusted system-wide and in your browsers. Its key
  lives at `/etc/nm-pulse-sso/pki/ca.key` (root, `0600`). It can only mint certs
  for your one gateway host on loopback during auth. `FORCE_PKI=1 sudo ./install.sh`
  rotates it (re-run `pulse-browser-auth-trust install` afterward).
- `/etc/hosts` **permanently** points the gateway host at `127.0.0.1`, so you
  can't reach the gateway directly outside auth. The tunnel bypasses this via
  openconnect `--resolve` (set automatically from the proxy's DoH lookup).
- openconnect validates the gateway's **real** certificate against the system CA
  bundle (no pin), so the gateway must present a publicly-trusted cert.

## Uninstall

```bash
sudo ./uninstall.sh
```

Reverses everything (services, hosts entry, iptables rule, CA trust, NM
connection, code). It leaves your browser profile
(`~/.cache/pulse-browser-auth`) alone.

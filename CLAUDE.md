# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A set of idempotent bash scripts for deploying a WireGuard VPN on AWS Lightsail (Ubuntu 22.04). The VPN topology is:

- **Server** (Lightsail): WireGuard on UDP:51820, public IP
- **Raspberry Pi** (home): acts as a gateway/router for the home subnet (192.168.68.0/22), connects to the server
- **Mobile peers**: split-tunnel clients (VPN + home subnet via Pi), optionally using wstunnel to bypass UDP-blocking firewalls

## Script Execution Order

**Server-side** (run on Lightsail, all require `sudo`, all idempotent):

1. `scripts/wg-setup.sh` — installs WireGuard, generates keys, writes `/etc/wireguard/wg0.conf`, generates client configs and QR codes. Run this first on the Lightsail instance.
2. `scripts/wg-add-client.sh` — adds a single new peer interactively (hot-reload with `wg set`, no downtime). Requires step 1. For wstunnel mode, also requires steps 3 and 4.
3. `scripts/wstunnel-server-setup.sh` — installs wstunnel v10 binary, generates `/etc/wstunnel/secret` and `/etc/wstunnel/secret-env`, creates systemd unit listening on `ws://127.0.0.1:8080`. Optional; only needed if clients require wstunnel/TLS mode.
4. `scripts/caddy-setup.sh` — installs Caddy, generates self-signed EC P-256 cert at `/etc/caddy/tls/cert.pem`, writes Caddyfile. Must run after step 3. Caddy terminates TLS on TCP:443 and reverse-proxies to wstunnel.

**Client-side** (run on the Linux/WSL2 client machine):

5. `scripts/vpn-client.sh` — CLI wrapper to start/stop/status a wstunnel + WireGuard session. Reads `SERVER_IP`, `SECRET`, and `WG_CONF` from a config file (default: `./vpn.conf`). Requires `wstunnel` binary and `wireguard-tools` installed on the client.

## Architecture: wstunnel/TLS Mode

```
Client
  └─ wstunnel client → TLS:443
       └─ Caddy (TLS termination) → ws://127.0.0.1:8080
            └─ wstunnel server → UDP:51820
                 └─ WireGuard
```

Caddy is the sole TLS termination point. wstunnel runs on loopback only, no TLS, no public port. The shared secret is the URL path prefix; both Caddy and wstunnel (via `--restrict-http-upgrade-path-prefix`) verify it independently.

**Caddyfile note:** `{env.WSTUNNEL_SECRET}` is NOT expanded in Caddy path matchers at runtime. The secret is written as a literal value into the Caddyfile by `caddy-setup.sh` at generation time (unquoted heredoc, bash expands `${WSTUNNEL_SECRET}`). Re-run `caddy-setup.sh` after changing the secret.

## Key Files on the Server

| Path | Purpose |
|---|---|
| `/etc/wireguard/wg0.conf` | WireGuard server config — never enable `SaveConfig = true` |
| `/etc/wireguard/*_private.key`, `*_public.key`, `*_psk.key` | All WireGuard keys |
| `/root/wg-clients/` | Generated client `.conf` files and wstunnel packages — delete after distributing |
| `/etc/wstunnel/secret` | Raw secret (source of truth) |
| `/etc/wstunnel/secret-env` | `KEY=VALUE` format, consumed by both wstunnel and caddy systemd units via `EnvironmentFile` |
| `/etc/caddy/tls/cert.pem` | TLS cert — NOT included in client packages (cert pinning removed; wstunnel v10 has no `--tls-ca-certificate`) |
| `/etc/caddy/Caddyfile` | Caddy routing config |

## Important Conventions

- Peer metadata is stored as comments in `wg0.conf` (`# PeerName:`, `# PeerIP:`, `# PeerType:`). `wg-add-client.sh` uses these to build the peer list and find the next free IP.
- The VPN subnet is hardcoded to `/24` in `wg-add-client.sh` (constraint checked at runtime). Server always gets `.1`, Pi gets `.2`, mobile peers start at `.3`.
- wstunnel v10 removed `--tls-ca-certificate` — certificate pinning is not possible client-side. TLS is still active (encryption), but the client does not verify the server cert. Security relies on: TLS encryption + secret path (double-checked by Caddy and wstunnel) + WireGuard encryption/auth.
- `/etc/wstunnel/cert.pem` is an old path — no longer used. Current cert is at `/etc/caddy/tls/cert.pem`. Cert is NOT included in client packages (no functional use since pinning unavailable in v10).
- `vpn-client.sh` config file (`vpn.conf`) format: `SERVER_IP=`, `SECRET=`, `WG_CONF=` (one per line, KEY=VALUE). File contains the raw secret — add to `.gitignore`, never commit. Default path `./vpn.conf`, override with `--config <file>`.
- Regenerating the secret (`rm /etc/wstunnel/secret` + re-run step 3) invalidates all existing wstunnel clients.
- For gateway peers, routes are added to the kernel with `ip route replace` at peer-add time (no WireGuard restart needed).
- MTU: standard peers use 1420; wstunnel peers use 1300 to account for TLS + WebSocket overhead.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A set of idempotent bash scripts for deploying a WireGuard VPN on AWS Lightsail (Ubuntu 22.04). The VPN topology is:

- **Server** (Lightsail): WireGuard on UDP:51820, public IP
- **Raspberry Pi** (home): acts as a gateway/router for the home subnet (192.168.68.0/22), connects to the server
- **Mobile peers**: split-tunnel clients (VPN + home subnet via Pi), optionally using wstunnel to bypass UDP-blocking firewalls

## Script Execution Order

The scripts have mandatory ordering:

1. `scripts/wg-setup.sh` — installs WireGuard, generates keys, writes `/etc/wireguard/wg0.conf`, generates client configs and QR codes. Run this first on the Lightsail instance.
2. `scripts/wg-add-client.sh` — adds a single new peer interactively (hot-reload with `wg set`, no downtime). Requires step 1. For wstunnel mode, also requires steps 3 and 4.
3. `scripts/wg-tunnel-server-setup.sh` — installs wstunnel v10 binary, generates `/etc/wstunnel/secret` and `/etc/wstunnel/secret-env`, creates systemd unit listening on `ws://127.0.0.1:8080`. Optional; only needed if clients require wstunnel/TLS mode.
4. `scripts/caddy-setup.sh` — installs Caddy, generates self-signed EC P-256 cert at `/etc/caddy/tls/cert.pem`, writes Caddyfile. Must run after step 3. Caddy terminates TLS on TCP:443 and reverse-proxies to wstunnel.

All scripts require `sudo` and are idempotent.

## Architecture: wstunnel/TLS Mode

```
Client
  └─ wstunnel client → TLS:443
       └─ Caddy (TLS termination) → ws://127.0.0.1:8080
            └─ wstunnel server → UDP:51820
                 └─ WireGuard
```

Caddy is the sole TLS termination point. wstunnel runs on loopback only, no TLS, no public port. The shared secret is the URL path prefix; both Caddy (via `{env.WSTUNNEL_SECRET}`) and wstunnel (via `--restrict-http-upgrade-path-prefix`) verify it independently.

## Key Files on the Server

| Path | Purpose |
|---|---|
| `/etc/wireguard/wg0.conf` | WireGuard server config — never enable `SaveConfig = true` |
| `/etc/wireguard/*_private.key`, `*_public.key`, `*_psk.key` | All WireGuard keys |
| `/root/wg-clients/` | Generated client `.conf` files and wstunnel packages — delete after distributing |
| `/etc/wstunnel/secret` | Raw secret (source of truth) |
| `/etc/wstunnel/secret-env` | `KEY=VALUE` format, consumed by both wstunnel and caddy systemd units via `EnvironmentFile` |
| `/etc/caddy/tls/cert.pem` | TLS cert — the pinned cert included in every wstunnel client package |
| `/etc/caddy/Caddyfile` | Caddy routing config |

## Important Conventions

- Peer metadata is stored as comments in `wg0.conf` (`# PeerName:`, `# PeerIP:`, `# PeerType:`). `wg-add-client.sh` uses these to build the peer list and find the next free IP.
- The VPN subnet is hardcoded to `/24` in `wg-add-client.sh` (constraint checked at runtime). Server always gets `.1`, Pi gets `.2`, mobile peers start at `.3`.
- Certificate pinning uses the Caddy cert (`/etc/caddy/tls/cert.pem`), not `/etc/wstunnel/cert.pem` (old path — no longer used). If the cert is regenerated, all wstunnel client packages must be redistributed.
- Regenerating the secret (`rm /etc/wstunnel/secret` + re-run step 3) invalidates all existing wstunnel clients.
- For gateway peers, routes are added to the kernel with `ip route replace` at peer-add time (no WireGuard restart needed).
- MTU: standard peers use 1420; wstunnel peers use 1300 to account for TLS + WebSocket overhead.

# WireGuard VPN on AWS Lightsail

Idempotent bash scripts for deploying a self-hosted WireGuard VPN on an AWS Lightsail instance (Ubuntu 22.04). Supports standard UDP mode and a wstunnel/TLS mode that disguises WireGuard traffic as HTTPS to bypass UDP-blocking firewalls.

---

## Network topology

```
                          AWS Lightsail
                     ┌─────────────────────┐
                     │  WireGuard  :51820   │
Mobile peers ────────┤  wstunnel   :8080    │
                     │  Caddy      :443     │
                     └────────┬────────────┘
                              │ VPN (10.13.13.0/24)
                     ┌────────┴────────────┐
                     │  Raspberry Pi        │
                     │  10.13.13.2          │
                     │  gateway / router    │
                     └────────┬────────────┘
                              │
                     192.168.68.0/22  (home subnet)
```

| Node | VPN IP | Role |
|---|---|---|
| Lightsail server | 10.13.13.1 | WireGuard server, internet exit |
| Raspberry Pi | 10.13.13.2 | Home subnet gateway |
| Mobile peers | 10.13.13.3+ | Split-tunnel clients |

---

## Connection modes

**Standard** — WireGuard over UDP:51820. Default. Use this unless UDP is blocked.

**wstunnel/TLS** — WireGuard traffic wrapped inside a WebSocket tunnelled over TLS:443. Use this on networks that block or throttle UDP (corporate networks, some mobile carriers, hotel WiFi).

```
Client
  └─ wstunnel client → TLS:443
       └─ Caddy (TLS termination) → ws://127.0.0.1:8080
            └─ wstunnel server → UDP:51820
                 └─ WireGuard
```

Caddy is the sole TLS endpoint. wstunnel runs on loopback only. The shared secret acts as a URL path prefix; both Caddy and wstunnel verify it independently.

---

## Prerequisites

### AWS Lightsail instance
- Ubuntu 22.04
- Static public IP attached
- Firewall rules (Networking → IPv4 Firewall):
  - UDP 51820 — required for standard WireGuard
  - TCP 443 — required for wstunnel/TLS mode only

### Local machine
- SSH access to the Lightsail instance
- `scp` to transfer generated client configs

---

## Deployment

All scripts run on the **Lightsail server** as root (`sudo`). All scripts are idempotent.

### Step 1 — WireGuard server

```bash
git clone <repo> && cd <repo>
scp scripts/wg-setup.sh ubuntu@<SERVER_IP>:~/
ssh ubuntu@<SERVER_IP>

sudo bash wg-setup.sh
```

Before running, edit the top of the script to set:

| Variable | Description |
|---|---|
| `SERVER_PUBLIC_IP` | Leave empty for auto-detection, or set explicitly |
| `MOBILE_PEERS` | Number of mobile peer configs to pre-generate (1–10) |
| `HOME_SUBNET` | Your home network CIDR (default: `192.168.68.0/22`) |
| `PI_LOCAL_IP` | Raspberry Pi LAN IP (used in the next-steps instructions) |

The script will:
- Install WireGuard and qrencode
- Enable IP forwarding
- Generate keypairs for server, Pi, and all mobile peers
- Write `/etc/wireguard/wg0.conf`
- Start and enable `wg-quick@wg0`
- Generate client `.conf` files and print QR codes
- Write `/root/wg-clients/raspberry-pi.conf`

### Step 2 — Raspberry Pi client

Copy the generated config to the Pi and bring up the tunnel:

```bash
scp ubuntu@<SERVER_IP>:/root/wg-clients/raspberry-pi.conf pi@<PI_LAN_IP>:/tmp/

# On the Pi:
sudo mv /tmp/raspberry-pi.conf /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
sudo apt install wireguard iptables -y
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf && sudo sysctl -p
sudo systemctl enable --now wg-quick@wg0
```

### Step 3 — Mobile clients (standard mode)

Import `/root/wg-clients/mobile{1..N}.conf` into the WireGuard app, or scan the QR codes printed during step 1.

### Step 4 (optional) — wstunnel/TLS mode

Only needed if clients must bypass UDP-blocking firewalls.

#### 4a — Install wstunnel backend

```bash
sudo bash wstunnel-server-setup.sh
```

Downloads the latest wstunnel v10 binary from GitHub (SHA-256 verified), generates `/etc/wstunnel/secret`, and starts `wstunnel.service` listening on `ws://127.0.0.1:8080`.

#### 4b — Install Caddy frontend

```bash
sudo bash caddy-setup.sh
```

Installs Caddy from the official repository, generates a self-signed EC P-256 certificate at `/etc/caddy/tls/cert.pem`, writes the Caddyfile, and starts `caddy.service` on TCP:443.

### Step 5 — Add new peers at any time

```bash
sudo bash wg-add-client.sh
```

Interactive script. Hot-reloads the new peer into the running tunnel with `wg set` — no downtime for existing clients.

Peer types:
- **Mobile** — split-tunnel (VPN + home subnet), standard UDP or wstunnel/TLS
- **Gateway** — router for an additional local subnet (same pattern as the Pi)

For wstunnel/TLS peers, the script produces a `.tar.gz` package containing the WireGuard config, the Caddy certificate (for reference), and a README with start commands.

---

## Client setup

### Mobile — standard mode

1. Import `mobile{N}.conf` into the WireGuard app (file or QR code).
2. Connect. Split-tunnel is pre-configured: only VPN and home subnet traffic goes through the tunnel.

### Mobile — wstunnel/TLS mode

The package from `wg-add-client.sh` contains everything needed.

**Install wstunnel once** (Linux/WSL2 amd64 example):
```bash
WSTUNNEL_VER="10.x.x"   # check github.com/erebe/wstunnel/releases for latest
curl -L -o /tmp/wstunnel.tar.gz \
  "https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VER}/wstunnel_${WSTUNNEL_VER}_linux_amd64.tar.gz"
tar xzf /tmp/wstunnel.tar.gz -C /tmp/
sudo mv /tmp/wstunnel /usr/local/bin/wstunnel
```

Windows/macOS: download the binary from the [releases page](https://github.com/erebe/wstunnel/releases/latest).

**Start a VPN session (required order):**

```bash
# Terminal 1 — keep open
wstunnel client \
  --http-upgrade-path-prefix "<SECRET>" \
  --websocket-ping-frequency 30s \
  -L "udp://127.0.0.1:51821:127.0.0.1:51820?timeout_sec=0" \
  wss://<SERVER_IP>:443

# Terminal 2
sudo wg-quick up /path/to/<client>.conf
```

> **Note:** wstunnel v10 removed `--tls-ca-certificate`. TLS is active but the server cert is not verified client-side. Security relies on TLS encryption + secret path authentication + WireGuard double encryption.

The exact commands (with the correct secret) are in the `README.txt` inside the package.

**Shutdown:**
```bash
sudo wg-quick down /path/to/<client>.conf
# Ctrl+C in Terminal 1
```

### Gateway peer

```bash
scp /root/wg-clients/<name>.conf user@<GATEWAY_IP>:/tmp/
# On the gateway (same steps as Raspberry Pi setup above)
```

---

## Key files on the server

| Path | Purpose |
|---|---|
| `/etc/wireguard/wg0.conf` | WireGuard server config. Never enable `SaveConfig = true`. |
| `/etc/wireguard/*_private.key` | Private keys — never leave the server |
| `/etc/wireguard/*_public.key` | Public keys |
| `/etc/wireguard/*_psk.key` | Pre-shared keys (one per peer) |
| `/root/wg-clients/` | Generated client configs and packages — **delete after distributing** |
| `/etc/wstunnel/secret` | Raw shared secret (source of truth) |
| `/etc/wstunnel/secret-env` | `KEY=VALUE` env file consumed by both systemd units |
| `/etc/caddy/tls/cert.pem` | TLS cert included in every wstunnel client package (cert pinning not available in wstunnel v10+) |
| `/etc/caddy/Caddyfile` | Caddy routing config |

---

## Operational tasks

### Add a new peer
```bash
sudo bash wg-add-client.sh
```

### Check tunnel status
```bash
sudo wg show
systemctl status wg-quick@wg0
```

### Regenerate the wstunnel secret
This invalidates **all existing wstunnel clients** — they must receive new packages.
```bash
sudo rm /etc/wstunnel/secret
sudo bash wstunnel-server-setup.sh
sudo systemctl restart wstunnel caddy
# Re-run wg-add-client.sh for each wstunnel peer
```

### Regenerate the TLS certificate
```bash
sudo rm /etc/caddy/tls/cert.pem /etc/caddy/tls/key.pem
sudo bash caddy-setup.sh
```
Note: cert pinning is not supported in wstunnel v10+, so redistributing client packages is not required when the cert changes.

### Remove a peer
```bash
# Get the peer's public key
sudo wg show

# Remove from running tunnel (no downtime)
sudo wg set wg0 peer <PUBLIC_KEY> remove

# Remove the [Peer] block from wg0.conf
sudo nano /etc/wireguard/wg0.conf

# Remove key files
sudo rm /etc/wireguard/<name>_public.key /etc/wireguard/<name>_psk.key
```

---

## Troubleshooting

**Tunnel not starting**
```bash
journalctl -u wg-quick@wg0 -n 50
```

**wstunnel not connecting**
```bash
journalctl -u wstunnel -n 50
ss -tlnp | grep 8080   # should show 127.0.0.1:8080
```

**Caddy errors**
```bash
journalctl -u caddy -n 50
caddy validate --config /etc/caddy/Caddyfile
```

**TLS connection refused or cert error**
wstunnel v10 does not verify the server cert by default — TLS errors on the client are unlikely. If using `--tls-verify-certificate` (publicly trusted cert only), ensure the cert is valid and matches the server IP/hostname.

**404 from wstunnel path**
The secret in the wstunnel client command does not match `/etc/wstunnel/secret`. Re-generate the client package with `wg-add-client.sh`.

**Routing loop in wstunnel mode**
Do not set `AllowedIPs = 0.0.0.0/0` in the wstunnel peer config. The config generated by `wg-add-client.sh` uses split-tunnel — do not modify AllowedIPs.

**IP forwarding not working after reboot**
```bash
sysctl net.ipv4.ip_forward   # should be 1
cat /etc/sysctl.d/99-wireguard.conf
```

---

## Security notes

- Private keys never leave `/etc/wireguard/` on the server. Client configs in `/root/wg-clients/` contain **client** private keys — delete them after distributing.
- The wstunnel secret is injected via systemd `EnvironmentFile` and never appears in plaintext in logs or `systemctl status`.
- The wstunnel service runs as a dedicated system user (`wstunnel`) with a hardened systemd unit (no capabilities, filesystem isolation, syscall filtering).
- Caddy is the only process with a public port (TCP:443). wstunnel binds to loopback only.
- Do not enable `SaveConfig = true` in `wg0.conf` — it overwrites the file with the current runtime state, erasing the peer metadata comments (`# PeerName:`, `# PeerIP:`, `# PeerType:`) that `wg-add-client.sh` depends on.

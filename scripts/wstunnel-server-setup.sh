#!/usr/bin/env bash
# =============================================================================
# wstunnel-server-setup.sh — Install wstunnel v10 and generate the shared secret
#
# Usage:
#   chmod +x wstunnel-server-setup.sh
#   sudo ./wstunnel-server-setup.sh
#
# Prerequisites:
#   - WireGuard already installed and running on UDP:51820
#   - curl installed
#
# This script is idempotent: can be re-run without side effects.
# If wstunnel is already installed, it is updated only if the version differs.
#
# Note: TLS is handled by Caddy (caddy-setup.sh), not by this script.
# wstunnel runs as a local backend on ws://127.0.0.1:8080 without direct TLS.
# Run caddy-setup.sh after this script.
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}\n"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run with sudo: sudo ./wstunnel-server-setup.sh"

umask 077

# ── Configurable constants ────────────────────────────────────────────────────
WSTUNNEL_DIR="/etc/wstunnel"
WSTUNNEL_BIN="/usr/local/bin/wstunnel"
WSTUNNEL_SECRET_FILE="${WSTUNNEL_DIR}/secret"
# Env file read by wstunnel.service and caddy.service via EnvironmentFile.
# Generated here, consumed by caddy-setup.sh — single source of truth.
SECRET_ENV_FILE="${WSTUNNEL_DIR}/secret-env"
WSTUNNEL_INTERNAL_PORT=8080   # loopback port — TLS terminated by Caddy
WG_PORT=51820
SERVICE_FILE="/etc/systemd/system/wstunnel.service"

# =============================================================================
# Header
# =============================================================================

echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    wstunnel — Backend setup v10          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# Prerequisites
# =============================================================================

section "Prerequisites check"

command -v curl > /dev/null || error "curl not found. Install with: apt install curl"

if ! ss -ulnp | grep -q ":${WG_PORT}"; then
  warn "No process listening on UDP:${WG_PORT}."
  warn "Verify WireGuard is active: sudo systemctl status wg-quick@wg0"
  read -rp "$(echo -e "${YELLOW}Continue anyway? [y/N]:${NC} ")" force_continue
  [[ "${force_continue,,}" == "y" ]] || exit 0
fi

success "Prerequisites verified"

# =============================================================================
# Download wstunnel
# =============================================================================

section "wstunnel installation"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  WSTUNNEL_ARCH="amd64" ;;
  aarch64) WSTUNNEL_ARCH="arm64" ;;
  armv7l)  WSTUNNEL_ARCH="armv7" ;;
  *)       error "Unsupported architecture: ${ARCH}" ;;
esac

info "Architecture detected: ${ARCH} → ${WSTUNNEL_ARCH}"

info "Fetching latest version from GitHub..."
API_RESPONSE=$(curl -s --fail --connect-timeout 15 --max-time 30 \
  "https://api.github.com/repos/erebe/wstunnel/releases/latest" 2>/dev/null || true)

if [[ -z "$API_RESPONSE" ]]; then
  error "Cannot reach GitHub API. Check connectivity."
fi
if echo "$API_RESPONSE" | grep -qi '"rate limit"'; then
  error "GitHub API rate limit reached. Wait a few minutes and retry."
fi

WSTUNNEL_VERSION=$(echo "$API_RESPONSE" | grep -oP '"tag_name": "v\K[^"]+' || true)
[[ -z "$WSTUNNEL_VERSION" ]] && error "Cannot determine version from GitHub API."
info "Latest version available: v${WSTUNNEL_VERSION}"

INSTALL_WSTUNNEL=false
if command -v wstunnel > /dev/null 2>&1; then
  INSTALLED_VERSION=$(wstunnel --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
  if [[ "$INSTALLED_VERSION" == "$WSTUNNEL_VERSION" ]]; then
    success "wstunnel v${WSTUNNEL_VERSION} already installed — skipping download"
  else
    info "Installed version: ${INSTALLED_VERSION:-unknown} — updating to ${WSTUNNEL_VERSION}"
    INSTALL_WSTUNNEL=true
  fi
else
  INSTALL_WSTUNNEL=true
fi

if [[ "$INSTALL_WSTUNNEL" == "true" ]]; then
  TARBALL_NAME="wstunnel_${WSTUNNEL_VERSION}_linux_${WSTUNNEL_ARCH}.tar.gz"
  DOWNLOAD_URL="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/${TARBALL_NAME}"
  CHECKSUM_URL="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/checksums.txt"

  TMPDIR_WS=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_WS"' EXIT

  info "Downloading binary from: ${DOWNLOAD_URL}"
  curl -L --fail --connect-timeout 15 --max-time 300 \
    --retry 3 --retry-delay 5 \
    --progress-bar -o "${TMPDIR_WS}/wstunnel.tar.gz" "$DOWNLOAD_URL" \
    || error "Binary download failed. Check connectivity and: github.com/erebe/wstunnel/releases"

  info "Downloading checksum from GitHub..."
  curl -L --fail --connect-timeout 15 --max-time 30 \
    --retry 3 --retry-delay 5 \
    -s -o "${TMPDIR_WS}/checksums.txt" "$CHECKSUM_URL" \
    || error "Checksum download failed."

  info "Verifying SHA256 integrity..."
  EXPECTED=$(grep "$TARBALL_NAME" "${TMPDIR_WS}/checksums.txt" | awk '{print $1}')
  [[ -z "$EXPECTED" ]] && error "Checksum for ${TARBALL_NAME} not found in checksums file."
  ACTUAL=$(sha256sum "${TMPDIR_WS}/wstunnel.tar.gz" | awk '{print $1}')
  [[ "$EXPECTED" == "$ACTUAL" ]] || error "SHA256 mismatch — binary corrupted or compromised."
  success "SHA256 verified: ${ACTUAL:0:16}…"

  tar xzf "${TMPDIR_WS}/wstunnel.tar.gz" -C "${TMPDIR_WS}/"

  EXTRACTED_BIN="${TMPDIR_WS}/wstunnel"
  [[ ! -f "$EXTRACTED_BIN" ]] && error "Binary 'wstunnel' not found in archive."

  file "$EXTRACTED_BIN" | grep -q "ELF" \
    || error "Downloaded file does not appear to be a valid ELF executable."

  if systemctl is-active --quiet wstunnel 2>/dev/null; then
    info "Stopping wstunnel.service to update binary..."
    systemctl stop wstunnel
  fi

  install -m 755 "$EXTRACTED_BIN" "$WSTUNNEL_BIN"
  success "wstunnel v${WSTUNNEL_VERSION} installed to ${WSTUNNEL_BIN}"
fi

INSTALLED_VER=$(wstunnel --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
info "Active version: ${INSTALLED_VER}"

# =============================================================================
# Secret generation
# =============================================================================

section "Secret configuration"

# The secret is the shared source of truth between Caddy and wstunnel.
# Caddy reads it via {env.WSTUNNEL_SECRET} in the Caddyfile.
# wstunnel reads it via $WSTUNNEL_SECRET in ExecStart.
# Both use EnvironmentFile=${SECRET_ENV_FILE}.
#
# Not regenerated automatically — changing it invalidates all existing clients.

mkdir -p "$WSTUNNEL_DIR"
chmod 700 "$WSTUNNEL_DIR"

if [[ -f "$WSTUNNEL_SECRET_FILE" ]]; then
  success "Secret already present — keeping existing one"
  info "  (delete ${WSTUNNEL_SECRET_FILE} and re-run to regenerate)"
else
  # 32 bytes → 43 base64url characters without padding — URL-safe
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '=' > "$WSTUNNEL_SECRET_FILE"
  chmod 600 "$WSTUNNEL_SECRET_FILE"
  success "Secret generated: ${WSTUNNEL_SECRET_FILE}"
fi

WSTUNNEL_SECRET=$(cat "$WSTUNNEL_SECRET_FILE")
[[ -z "$WSTUNNEL_SECRET" ]] && error "Secret file is empty."
info "Secret (URL prefix): ${WSTUNNEL_SECRET:0:8}…"

# Generate secret-env — systemd EnvironmentFile format
printf 'WSTUNNEL_SECRET=%s\n' "$WSTUNNEL_SECRET" > "$SECRET_ENV_FILE"
chmod 640 "$SECRET_ENV_FILE"
success "secret-env generated: ${SECRET_ENV_FILE}"

# =============================================================================
# systemd configuration
# =============================================================================

section "systemd configuration"

# wstunnel runs as a local backend — it does not need to:
#   - read TLS cert/key (handled by Caddy)
#   - bind privileged ports (listens on 8080, not 443)
#   - setcap (CAP_NET_BIND_SERVICE not required for ports > 1024)
#
# The secret is injected via EnvironmentFile — it does not appear in plaintext
# in `systemctl status` or journald logs.

if ! id wstunnel > /dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin wstunnel
  success "System user 'wstunnel' created"
else
  info "User 'wstunnel' already exists"
fi

chown root:wstunnel "$WSTUNNEL_DIR"
chmod 750 "$WSTUNNEL_DIR"
chown root:wstunnel "$WSTUNNEL_SECRET_FILE" "$SECRET_ENV_FILE"
chmod 640 "$WSTUNNEL_SECRET_FILE" "$SECRET_ENV_FILE"

# Remove setcap if it was set by a previous version of this script
if command -v getcap > /dev/null 2>&1 && \
   getcap "$WSTUNNEL_BIN" 2>/dev/null | grep -q "cap_net_bind_service"; then
  setcap -r "$WSTUNNEL_BIN" \
    && info "CAP_NET_BIND_SERVICE removed (not needed for port ${WSTUNNEL_INTERNAL_PORT})" \
    || warn "Could not remove setcap — non-critical"
fi

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=wstunnel — WireGuard over WebSocket (local backend)
Documentation=https://github.com/erebe/wstunnel
After=network-online.target
Wants=network-online.target
# caddy-setup.sh adds a drop-in override with After=caddy.service

[Service]
Type=simple
User=wstunnel
Group=wstunnel

# Secret injected as environment variable — does not appear in plaintext in logs
EnvironmentFile=${SECRET_ENV_FILE}

# ws:// (no TLS) — encryption delegated to Caddy on the public side
# 127.0.0.1 — not exposed to the internet, loopback only
ExecStart=${WSTUNNEL_BIN} server \\
  --restrict-to      127.0.0.1:${WG_PORT} \\
  --restrict-http-upgrade-path-prefix \${WSTUNNEL_SECRET} \\
  ws://127.0.0.1:${WSTUNNEL_INTERNAL_PORT}

Restart=on-failure
RestartSec=5

# Filesystem isolation
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=${WSTUNNEL_DIR}
PrivateTmp=yes
PrivateDevices=yes

# Kernel protection
ProtectClock=yes
ProtectControlGroups=yes
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectProc=invisible

# Capabilities — none needed (port >1024, loopback only)
CapabilityBoundingSet=
AmbientCapabilities=

# Syscall hardening
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

if systemctl is-active --quiet wstunnel 2>/dev/null; then
  systemctl restart wstunnel
  success "wstunnel.service restarted"
else
  systemctl enable --now wstunnel
  success "wstunnel.service enabled and started"
fi

for i in {1..10}; do
  systemctl is-active --quiet wstunnel && break
  sleep 1
done
if systemctl is-active --quiet wstunnel; then
  success "wstunnel.service active on ws://127.0.0.1:${WSTUNNEL_INTERNAL_PORT}"
else
  error "wstunnel.service failed to start. Check: journalctl -u wstunnel -n 30"
fi

# =============================================================================
# Firewall
# =============================================================================

section "Firewall"

# wstunnel does not expose public ports — listens on loopback only.
# TCP:443 is handled by Caddy (caddy-setup.sh).
info "wstunnel listens on 127.0.0.1:${WSTUNNEL_INTERNAL_PORT} — no firewall rules needed"
info "Public TCP:443 will be handled by Caddy (caddy-setup.sh)"

# =============================================================================
# Connectivity check
# =============================================================================

section "Connectivity check"

info "Testing wstunnel on 127.0.0.1:${WSTUNNEL_INTERNAL_PORT}..."
if ss -tlnp | grep -q "127.0.0.1:${WSTUNNEL_INTERNAL_PORT}"; then
  success "wstunnel listening on ws://127.0.0.1:${WSTUNNEL_INTERNAL_PORT}"
else
  warn "wstunnel not listening — check: journalctl -u wstunnel -n 20"
fi

# =============================================================================
# Summary
# =============================================================================

section "Setup complete"

echo -e "  Binary        : ${BOLD}${WSTUNNEL_BIN}${NC} (v${INSTALLED_VER})"
echo -e "  Secret file   : ${BOLD}${WSTUNNEL_SECRET_FILE}${NC}"
echo -e "  Secret env    : ${BOLD}${SECRET_ENV_FILE}${NC}"
echo -e "  Service       : ${BOLD}wstunnel.service${NC} (systemd, auto-start)"
echo -e "  Listening     : ${BOLD}ws://127.0.0.1:${WSTUNNEL_INTERNAL_PORT}${NC} (loopback only)"
echo -e "  Destination   : ${BOLD}127.0.0.1:${WG_PORT}${NC} (WireGuard)"
echo ""
echo -e "${YELLOW}Required next step:${NC}"
echo "  Run caddy-setup.sh to install the front-end reverse proxy:"
echo "    sudo ./caddy-setup.sh"
echo ""
echo "  Caddy will handle:"
echo "    - TLS termination on TCP:443"
echo "    - Routing wstunnel traffic to /<secret>"
echo "    - Self-signed certificate generation (cert pinning not supported in wstunnel v10+)"
echo ""
echo -e "${GREEN}Service status:${NC}"
systemctl status wstunnel --no-pager -l | head -20

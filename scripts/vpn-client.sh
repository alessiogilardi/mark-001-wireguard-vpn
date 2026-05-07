#!/usr/bin/env bash
# =============================================================================
# vpn-client.sh — Start / stop / status for wstunnel + WireGuard VPN session
#
# Usage:
#   sudo bash vpn-client.sh start  [--config <file>]
#   sudo bash vpn-client.sh stop   [--config <file>]
#        bash vpn-client.sh status [--config <file>]
#
# Config file format (default: ./vpn.conf):
#   SERVER_IP=1.2.3.4
#   SECRET=your-shared-secret
#   WG_CONF=/path/to/client.conf
#
# Prerequisites (client machine):
#   - wstunnel v10+ installed (github.com/erebe/wstunnel/releases)
#   - wireguard-tools installed (apt install wireguard-tools)
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

# ── Constants ─────────────────────────────────────────────────────────────────
LOCAL_UDP_PORT=51821     # wstunnel listens here, WireGuard conf points here
WG_REMOTE_PORT=51820     # WireGuard port on the server
WSTUNNEL_SERVER_PORT=443
WSTUNNEL_PING="30s"
WSTUNNEL_BIND_TIMEOUT=5  # seconds to wait for wstunnel to bind the UDP port

DEFAULT_CONFIG="./vpn.conf"

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  echo ""
  echo -e "  ${BOLD}Usage:${NC}"
  echo "    sudo bash vpn-client.sh start  [--config <file>]"
  echo "    sudo bash vpn-client.sh stop   [--config <file>]"
  echo "         bash vpn-client.sh status [--config <file>]"
  echo ""
  echo -e "  ${BOLD}Config file${NC} (default: ${DEFAULT_CONFIG}):"
  echo "    SERVER_IP=1.2.3.4"
  echo "    SECRET=your-shared-secret"
  echo "    WG_CONF=/path/to/client.conf"
  echo ""
  exit 1
}

# ── Argument parsing ──────────────────────────────────────────────────────────
COMMAND=""
CONFIG_FILE="$DEFAULT_CONFIG"

while [[ $# -gt 0 ]]; do
  case "$1" in
    start|stop|status) COMMAND="$1"; shift ;;
    --config)
      [[ -z "${2:-}" ]] && error "--config requires a file path."
      CONFIG_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) error "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$COMMAND" ]] && { error "No command given."; usage; }

# ── Load config ───────────────────────────────────────────────────────────────
load_config() {
  [[ ! -f "$CONFIG_FILE" ]] && \
    error "Config file not found: ${CONFIG_FILE}\n\n  Create it:\n    echo 'SERVER_IP=1.2.3.4' > ${CONFIG_FILE}\n    echo 'SECRET=your-secret' >> ${CONFIG_FILE}\n    echo 'WG_CONF=/path/to/client.conf' >> ${CONFIG_FILE}"

  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  [[ -z "${SERVER_IP:-}" ]] && error "SERVER_IP missing in ${CONFIG_FILE}."
  [[ -z "${SECRET:-}"    ]] && error "SECRET missing in ${CONFIG_FILE}."
  [[ -z "${WG_CONF:-}"   ]] && error "WG_CONF missing in ${CONFIG_FILE}."

  [[ ! -f "$WG_CONF" ]] && error "WireGuard config not found: ${WG_CONF}"

  WG_IFACE=$(basename "$WG_CONF" .conf)
  PID_FILE="/tmp/wstunnel-vpn-${WG_IFACE}.pid"
  LOG_FILE="/tmp/wstunnel-vpn-${WG_IFACE}.log"
}

# ── Helper: is wstunnel running ───────────────────────────────────────────────
wstunnel_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# ── Helper: is WireGuard interface up ────────────────────────────────────────
wg_up() {
  ip link show dev "$WG_IFACE" > /dev/null 2>&1
}

# =============================================================================
# start
# =============================================================================

cmd_start() {
  [[ $EUID -ne 0 ]] && error "start requires root: sudo bash vpn-client.sh start"

  load_config

  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║    VPN — Start                           ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo ""
  info "Server     : ${SERVER_IP}:${WSTUNNEL_SERVER_PORT}"
  info "WireGuard  : ${WG_CONF} (interface: ${WG_IFACE})"
  echo ""

  # ── Prerequisite checks ───────────────────────────────────────────────────
  command -v wstunnel > /dev/null || \
    error "wstunnel not found.\n\n  Install: github.com/erebe/wstunnel/releases\n  sudo mv wstunnel /usr/local/bin/ && sudo chmod +x /usr/local/bin/wstunnel"

  command -v wg-quick > /dev/null || \
    error "wg-quick not found. Install: apt install wireguard-tools"

  if wstunnel_running; then
    warn "wstunnel already running (PID $(cat "$PID_FILE")). Stop first."
    exit 1
  fi

  if wg_up; then
    warn "WireGuard interface ${WG_IFACE} already up. Stop first."
    exit 1
  fi

  if ss -ulnp 2>/dev/null | grep -q ":${LOCAL_UDP_PORT}"; then
    error "UDP port ${LOCAL_UDP_PORT} already in use. Another instance running?"
  fi

  # ── Start wstunnel in background ──────────────────────────────────────────
  # setsid: detach from controlling terminal so wstunnel cannot write to /dev/tty.
  # Run as root (wstunnel is a network client, no elevated capabilities needed,
  # but sudo -u $SUDO_USER would use a restricted PATH that may not find the binary).
  info "Starting wstunnel → wss://${SERVER_IP}:${WSTUNNEL_SERVER_PORT}..."

  WSTUNNEL_BIN=$(command -v wstunnel) || \
    error "wstunnel not found in PATH. Install: github.com/erebe/wstunnel/releases\n  sudo mv wstunnel /usr/local/bin/ && sudo chmod +x /usr/local/bin/wstunnel"

  setsid "$WSTUNNEL_BIN" client \
    --http-upgrade-path-prefix "$SECRET" \
    --websocket-ping-frequency "$WSTUNNEL_PING" \
    -L "udp://127.0.0.1:${LOCAL_UDP_PORT}:127.0.0.1:${WG_REMOTE_PORT}?timeout_sec=0" \
    "wss://${SERVER_IP}:${WSTUNNEL_SERVER_PORT}" \
    > "$LOG_FILE" 2>&1 &

  WSTUNNEL_PID=$!
  echo "$WSTUNNEL_PID" > "$PID_FILE"

  # ── Wait for wstunnel to bind UDP port ────────────────────────────────────
  for i in $(seq 1 $WSTUNNEL_BIND_TIMEOUT); do
    if ss -ulnp 2>/dev/null | grep -q ":${LOCAL_UDP_PORT}"; then
      success "wstunnel listening on UDP 127.0.0.1:${LOCAL_UDP_PORT} (PID ${WSTUNNEL_PID})"
      break
    fi
    if ! kill -0 "$WSTUNNEL_PID" 2>/dev/null; then
      echo ""
      error "wstunnel exited immediately. Last log:\n$(tail -5 "$LOG_FILE" 2>/dev/null || true)"
    fi
    sleep 1
    [[ "$i" -eq $WSTUNNEL_BIND_TIMEOUT ]] && \
      error "wstunnel did not bind UDP:${LOCAL_UDP_PORT} within ${WSTUNNEL_BIND_TIMEOUT}s.\n  Log: ${LOG_FILE}\n$(tail -5 "$LOG_FILE" 2>/dev/null || true)"
  done

  # ── Bring up WireGuard ────────────────────────────────────────────────────
  # Capture wg-quick output to avoid carriage-return garbling in WSL terminals.
  info "Bringing up WireGuard (${WG_IFACE})..."
  WG_OUT=$(wg-quick up "$WG_CONF" 2>&1) || {
    warn "wg-quick failed — stopping wstunnel..."
    kill "$WSTUNNEL_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    error "WireGuard failed to start:\n${WG_OUT}"
  }

  success "WireGuard interface ${WG_IFACE} up"
  echo ""
  echo -e "${GREEN}VPN session active.${NC}"
  echo ""
  echo -e "  Stop with: ${BOLD}sudo bash vpn-client.sh stop --config ${CONFIG_FILE}${NC}"
  echo -e "  Log file : ${LOG_FILE}"
  echo ""
  wg show "$WG_IFACE" 2>/dev/null || true
}

# =============================================================================
# stop
# =============================================================================

cmd_stop() {
  [[ $EUID -ne 0 ]] && error "stop requires root: sudo bash vpn-client.sh stop"

  load_config

  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║    VPN — Stop                            ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo ""

  # ── Bring down WireGuard ──────────────────────────────────────────────────
  if wg_up; then
    info "Bringing down WireGuard (${WG_IFACE})..."
    WG_OUT=$(wg-quick down "$WG_CONF" 2>&1) || warn "wg-quick down failed (interface may already be down):\n${WG_OUT}"
    success "WireGuard down"
  else
    info "WireGuard interface ${WG_IFACE} already down."
  fi

  # ── Stop wstunnel ─────────────────────────────────────────────────────────
  if wstunnel_running; then
    WSTUNNEL_PID=$(cat "$PID_FILE")
    info "Stopping wstunnel (PID ${WSTUNNEL_PID})..."
    kill "$WSTUNNEL_PID" 2>/dev/null || true
    for i in $(seq 1 5); do
      kill -0 "$WSTUNNEL_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$WSTUNNEL_PID" 2>/dev/null; then
      kill -9 "$WSTUNNEL_PID" 2>/dev/null || true
      warn "wstunnel required SIGKILL."
    fi
    rm -f "$PID_FILE"
    success "wstunnel stopped"
  elif [[ -f "$PID_FILE" ]]; then
    info "PID file found but process already dead — cleaning up."
    rm -f "$PID_FILE"
  else
    info "wstunnel not running."
  fi

  echo ""
  echo -e "${GREEN}VPN session stopped.${NC}"
  echo ""
}

# =============================================================================
# status
# =============================================================================

cmd_status() {
  load_config

  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║    VPN — Status                          ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo ""

  # wstunnel
  if wstunnel_running; then
    WSTUNNEL_PID=$(cat "$PID_FILE")
    echo -e "  wstunnel   : ${GREEN}● running${NC} (PID ${WSTUNNEL_PID})"
  else
    echo -e "  wstunnel   : ${RED}○ stopped${NC}"
    [[ -f "$PID_FILE" ]] && echo -e "               ${YELLOW}stale PID file: ${PID_FILE}${NC}"
  fi

  # UDP port
  if ss -ulnp 2>/dev/null | grep -q ":${LOCAL_UDP_PORT}"; then
    echo -e "  UDP :${LOCAL_UDP_PORT} : ${GREEN}● bound${NC}"
  else
    echo -e "  UDP :${LOCAL_UDP_PORT} : ${RED}○ not bound${NC}"
  fi

  # WireGuard
  if wg_up; then
    echo -e "  WireGuard  : ${GREEN}● up${NC} (${WG_IFACE})"
  else
    echo -e "  WireGuard  : ${RED}○ down${NC} (${WG_IFACE})"
  fi

  echo ""

  if wg_up; then
    echo -e "${BOLD}wg show:${NC}"
    wg show "$WG_IFACE" 2>/dev/null || true
    echo ""
  fi

  # Log tail if wstunnel running
  if wstunnel_running && [[ -f "$LOG_FILE" ]]; then
    echo -e "${BOLD}wstunnel log (last 5 lines):${NC}"
    tail -5 "$LOG_FILE" | sed 's/^/  /'
    echo ""
  fi
}

# =============================================================================
# Dispatch
# =============================================================================

case "$COMMAND" in
  start)  cmd_start  ;;
  stop)   cmd_stop   ;;
  status) cmd_status ;;
esac

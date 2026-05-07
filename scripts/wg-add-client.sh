#!/usr/bin/env bash
# =============================================================================
# wg-add-client.sh — Adds a new WireGuard peer interactively
#
# Usage:
#   chmod +x wg-add-client.sh
#   sudo ./wg-add-client.sh
#
# Prerequisites: wg-setup.sh already run successfully
# For wstunnel mode: wstunnel-server-setup.sh and caddy-setup.sh already run
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
[[ $EUID -ne 0 ]] && error "Run with sudo: sudo ./wg-add-client.sh"

umask 077

# ── Configurable constants ────────────────────────────────────────────────────
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
OUTPUT_DIR="/root/wg-clients"

HOME_SUBNET="192.168.68.0/22"

WSTUNNEL_PORT=443
WSTUNNEL_MTU=1300
LOCAL_WSTUNNEL_PORT=51821

# wstunnel/Caddy infrastructure paths
WSTUNNEL_SECRET_FILE="/etc/wstunnel/secret"

# =============================================================================
# Preliminary checks
# =============================================================================

[[ ! -f "$WG_CONF" ]] && error "wg0.conf not found. Have you run wg-setup.sh?"
[[ ! -f "${WG_DIR}/server_public.key" ]] && error "Server keys not found in ${WG_DIR}."

if grep -qiE "^\s*SaveConfig\s*=\s*true" "$WG_CONF"; then
  warn "SaveConfig = true detected in ${WG_CONF}."
  read -rp "$(echo -e "${YELLOW}Disable it automatically now? [Y/n]:${NC} ")" fix_save
  if [[ "${fix_save,,}" == "y" || -z "$fix_save" ]]; then
    sed -i 's/^\s*SaveConfig\s*=\s*true/SaveConfig = false/i' "$WG_CONF"
    success "SaveConfig disabled in ${WG_CONF}."
  else
    error "Disable SaveConfig manually before proceeding."
  fi
fi

command -v curl > /dev/null || error "curl not installed."
command -v wg   > /dev/null || error "WireGuard not installed."

# ── Network values extracted from wg0.conf ────────────────────────────────────
WG_PORT=$(awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$WG_CONF")
VPN_SUBNET=$(awk -F= '/^[[:space:]]*Address[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$WG_CONF")

[[ -z "$WG_PORT" ]]    && error "ListenPort not found in ${WG_CONF}."
[[ -z "$VPN_SUBNET" ]] && error "Address not found in ${WG_CONF}."

VPN_SUBNET=$(echo "$VPN_SUBNET" | sed 's|\([0-9]*\.[0-9]*\.[0-9]*\)\.[0-9]*/\([0-9]*\)|\1.0/\2|')
VPN_PREFIX=$(echo "$VPN_SUBNET" | cut -d. -f1-3)

VPN_CIDR="${VPN_SUBNET##*/}"
if [[ "$VPN_CIDR" != "24" ]]; then
  error "VPN_SUBNET /${VPN_CIDR} — this script only supports /24."
fi

WG_IFACE=$(basename "$WG_CONF" .conf)

info "Configuration — Interface: ${WG_IFACE}, Port: ${WG_PORT}, VPN subnet: ${VPN_SUBNET}"

if command -v nft > /dev/null && ! command -v iptables-legacy > /dev/null 2>&1; then
  warn "System uses native nftables. Verify the iptables-nft layer: iptables --version"
fi

QRENCODE_AVAILABLE=true
if ! command -v qrencode > /dev/null; then
  warn "qrencode not installed — attempting installation..."
  if command -v apt-get > /dev/null; then
    apt-get install -y qrencode || { warn "qrencode installation failed."; QRENCODE_AVAILABLE=false; }
  elif command -v dnf > /dev/null; then
    dnf install -y qrencode || { warn "qrencode installation failed."; QRENCODE_AVAILABLE=false; }
  else
    warn "Install qrencode manually to generate QR codes."
    QRENCODE_AVAILABLE=false
  fi
  [[ "$QRENCODE_AVAILABLE" == true ]] && success "qrencode installed"
fi

mkdir -p "$OUTPUT_DIR"

# =============================================================================
# Utility functions
# =============================================================================

get_used_ips() {
  grep -E "^AllowedIPs" "$WG_CONF" \
    | grep -oE "${VPN_PREFIX}\.[0-9]{1,3}" \
    | sort -t. -k4 -n \
    | uniq \
    || true
}

next_available_ip() {
  local used
  used=$(get_used_ips)
  for i in $(seq 3 254); do
    local candidate="${VPN_PREFIX}.${i}"
    if ! echo "$used" | grep -q "^${candidate}$"; then
      echo "$candidate"
      return
    fi
  done
  error "VPN subnet exhausted."
}

name_exists() {
  [[ -f "${WG_DIR}/${1}_public.key" ]]
}

get_public_ip() {
  local ip=""
  local token
  token=$(curl -s --max-time 3 -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
  if [[ -n "$token" ]]; then
    ip=$(curl -s --max-time 3 \
      -H "X-aws-ec2-metadata-token: $token" \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)
  fi
  if [[ -z "$ip" ]]; then
    warn "IMDSv2 unavailable — trying IMDSv1 (may fail if IMDSv1 is disabled on this instance)."
    ip=$(curl -s --max-time 3 "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)
  fi
  [[ -z "$ip" ]] && ip=$(curl -s --max-time 5 "https://api.ipify.org" 2>/dev/null || true)
  echo "$ip"
}

# =============================================================================
# Welcome and current state summary
# =============================================================================

clear
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      WireGuard — Add client              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

SERVER_PUBLIC_IP=$(get_public_ip)
USED_IPS=$(get_used_ips | tr '\n' ' ')
NEXT_IP=$(next_available_ip)

echo -e "  Configured peers  :"
peer_names=$(grep -E "^# PeerName:" "$WG_CONF" | sed 's/^# PeerName: //' || true)
if [[ -z "$peer_names" ]]; then
  echo -e "    (none)"
else
  active_keys=""
  if ip link show dev "$WG_IFACE" > /dev/null 2>&1; then
    active_keys=$(wg show "$WG_IFACE" peers 2>/dev/null || true)
  fi
  while IFS= read -r peer_name; do
    pub_key_file="${WG_DIR}/${peer_name}_public.key"
    if [[ -f "$pub_key_file" ]]; then
      pub_key=$(cat "$pub_key_file")
      if echo "$active_keys" | grep -qF "$pub_key"; then
        status="${GREEN}●${NC}"
      else
        status="${YELLOW}○${NC}"
      fi
    else
      status="${BLUE}?${NC}"
    fi
    echo -e "    $(echo -e "$status") ${peer_name}"
  done <<< "$peer_names"
fi
echo -e "  VPN IPs in use    : ${USED_IPS:-none}"
echo -e "  Next available IP : ${BOLD}${NEXT_IP}${NC}"
echo ""

# =============================================================================
# Client type selection
# =============================================================================

section "Client type"
echo "  1) Mobile / Laptop  — accesses the home network and VPN"
echo "  2) Gateway          — acts as a router for another local network (like the Pi)"
echo ""

while true; do
  read -rp "$(echo -e "${YELLOW}Choose [1/2]:${NC} ")" CLIENT_TYPE
  case "$CLIENT_TYPE" in
    1) CLIENT_TYPE="mobile";  break ;;
    2) CLIENT_TYPE="gateway"; break ;;
    *) warn "Enter 1 or 2" ;;
  esac
done

# =============================================================================
# Connection mode (mobile clients only)
# =============================================================================

USE_WSTUNNEL=false
WSTUNNEL_CLIENT_OS="linux"

if [[ "$CLIENT_TYPE" == "mobile" ]]; then
  section "Connection mode"
  echo "  1) Standard     — UDP:${WG_PORT} (default, maximum compatibility)"
  echo "  2) wstunnel/TLS — TCP:${WSTUNNEL_PORT}, disguises WireGuard traffic as HTTPS"
  echo "                    Useful when UDP is blocked or filtered by a firewall"
  echo ""

  while true; do
    read -rp "$(echo -e "${YELLOW}Mode [1/2]:${NC} ")" conn_mode
    case "$conn_mode" in
      1) USE_WSTUNNEL=false; break ;;
      2) USE_WSTUNNEL=true;  break ;;
      *) warn "Enter 1 or 2" ;;
    esac
  done

  # ── Check wstunnel prerequisites ──────────────────────────────────────────
  if [[ "$USE_WSTUNNEL" == true ]]; then

    if [[ ! -f "$WSTUNNEL_SECRET_FILE" ]]; then
      error "Secret file not found: ${WSTUNNEL_SECRET_FILE}\n\n  Run first:\n    sudo ./wstunnel-server-setup.sh"
    fi

    WSTUNNEL_SECRET=$(cat "$WSTUNNEL_SECRET_FILE")
    [[ -z "$WSTUNNEL_SECRET" ]] && error "Secret file ${WSTUNNEL_SECRET_FILE} is empty."

    success "wstunnel/Caddy prerequisites verified"

    echo ""
    echo "  Client operating system:"
    echo "  1) Linux / WSL2   — PostUp/PostDown with iptables supported"
    echo "  2) Windows / macOS / iOS / Android — PostUp not supported"
    echo ""
    while true; do
      read -rp "$(echo -e "${YELLOW}Client OS [1/2]:${NC} ")" os_choice
      case "$os_choice" in
        1) WSTUNNEL_CLIENT_OS="linux";    break ;;
        2) WSTUNNEL_CLIENT_OS="nonlinux"; break ;;
        *) warn "Enter 1 or 2" ;;
      esac
    done
  fi
fi

# =============================================================================
# Client name
# =============================================================================

section "Client name"
echo "  Letters, numbers, and hyphens only. E.g.: laptop-mario, iphone-sara, office"
echo ""

while true; do
  read -rp "$(echo -e "${YELLOW}Client name:${NC} ")" CLIENT_NAME

  if [[ -z "$CLIENT_NAME" ]]; then
    warn "Name cannot be empty."
    continue
  fi
  if ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
    warn "Letters, numbers, and hyphens only."
    continue
  fi
  if name_exists "$CLIENT_NAME"; then
    warn "A client named '${CLIENT_NAME}' already exists."
    continue
  fi
  break
done

# =============================================================================
# VPN IP address
# =============================================================================

section "VPN IP address"
echo -e "  Next available IP: ${BOLD}${NEXT_IP}${NC}"
echo "  Press ENTER to accept it, or enter a custom one."
echo ""

while true; do
  read -rp "$(echo -e "${YELLOW}VPN IP [${NEXT_IP}]:${NC} ")" CLIENT_IP
  CLIENT_IP="${CLIENT_IP:-$NEXT_IP}"

  if ! [[ "$CLIENT_IP" =~ ^${VPN_PREFIX//./\.}\.([0-9]{1,3})$ ]]; then
    warn "Invalid format. Use an IP in the form ${VPN_PREFIX}.X"
    continue
  fi

  OCTET="${BASH_REMATCH[1]}"
  if [[ "$OCTET" -lt 2 || "$OCTET" -gt 254 ]]; then
    warn "Fourth octet must be between 2 and 254."
    continue
  fi

  if echo "$(get_used_ips)" | grep -q "^${CLIENT_IP}$"; then
    warn "IP ${CLIENT_IP} is already in use."
    continue
  fi
  break
done

# =============================================================================
# Gateway configuration
# =============================================================================

GATEWAY_SUBNET=""
GATEWAY_IFACE="eth0"
GATEWAY_REACH_HOME=false
GATEWAY_ALLOWED_IPS=""

if [[ "$CLIENT_TYPE" == "gateway" ]]; then
  section "Gateway configuration"
  echo "  Enter the subnet to make reachable via VPN. E.g.: 192.168.1.0/24"
  echo ""

  while true; do
    read -rp "$(echo -e "${YELLOW}Gateway local subnet:${NC} ")" GATEWAY_SUBNET
    if ! [[ "$GATEWAY_SUBNET" =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\/(([0-9]|[12][0-9]|3[0-2]))$ ]]; then
      warn "Invalid format. Use CIDR notation, e.g.: 192.168.1.0/24"
      continue
    fi
    [[ "$GATEWAY_SUBNET" == "$VPN_SUBNET" ]] && { warn "Conflicts with VPN_SUBNET."; continue; }
    [[ "$GATEWAY_SUBNET" == "$HOME_SUBNET" ]] && { warn "Conflicts with HOME_SUBNET."; continue; }
    break
  done

  echo ""
  read -rp "$(echo -e "${YELLOW}Gateway local network interface [eth0]:${NC} ")" GATEWAY_IFACE
  GATEWAY_IFACE="${GATEWAY_IFACE:-eth0}"

  echo ""
  GATEWAY_REACH_HOME=false
  while true; do
    read -rp "$(echo -e "${YELLOW}Should HOME_SUBNET (${HOME_SUBNET}) be reachable? [y/N]:${NC} ")" reach_home
    case "${reach_home,,}" in
      y|yes) GATEWAY_REACH_HOME=true;  break ;;
      n|no|"") GATEWAY_REACH_HOME=false; break ;;
      *) warn "Answer y or N" ;;
    esac
  done
fi

# =============================================================================
# DNS (mobile clients only)
# =============================================================================

CLIENT_DNS="1.1.1.1"
if [[ "$CLIENT_TYPE" == "mobile" ]]; then
  section "DNS"
  echo "  Default: 1.1.1.1 (Cloudflare). You can use your home router for local hostnames."
  echo ""
  read -rp "$(echo -e "${YELLOW}DNS [1.1.1.1]:${NC} ")" CLIENT_DNS
  CLIENT_DNS="${CLIENT_DNS:-1.1.1.1}"
fi

# =============================================================================
# Summary and confirmation
# =============================================================================

section "Summary"
echo -e "  Name          : ${BOLD}${CLIENT_NAME}${NC}"
echo -e "  Type          : ${BOLD}${CLIENT_TYPE}${NC}"
echo -e "  VPN IP        : ${BOLD}${CLIENT_IP}/32${NC}"

if [[ "$CLIENT_TYPE" == "mobile" ]]; then
  MODE=$([ "$USE_WSTUNNEL" == true ] \
    && echo "wstunnel/TLS via Caddy (TCP:${WSTUNNEL_PORT})" \
    || echo "Standard (UDP:${WG_PORT})")
  echo -e "  Mode          : ${BOLD}${MODE}${NC}"
  [[ "$USE_WSTUNNEL" == true ]] && \
    echo -e "  MTU           : ${BOLD}${WSTUNNEL_MTU}${NC}"
  echo -e "  AllowedIPs    : ${BOLD}${VPN_SUBNET}, ${HOME_SUBNET}${NC}"
  echo -e "  DNS           : ${BOLD}${CLIENT_DNS}${NC}"
else
  echo -e "  Local subnet  : ${BOLD}${GATEWAY_SUBNET}${NC}"
  echo -e "  Interface     : ${BOLD}${GATEWAY_IFACE}${NC}"
  echo -e "  Reaches home  : ${BOLD}$([ "$GATEWAY_REACH_HOME" == true ] && echo 'Yes' || echo 'No')${NC}"
fi

echo ""
read -rp "$(echo -e "${YELLOW}Confirm? [y/N]:${NC} ")" confirm
[[ "${confirm,,}" == "y" ]] || { info "Operation cancelled."; exit 0; }

# =============================================================================
# Key generation
# =============================================================================

section "Key generation"

CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)
CLIENT_PSK=$(wg genpsk)
SERVER_PUB=$(cat "${WG_DIR}/server_public.key")

echo "$CLIENT_PUB" > "${WG_DIR}/${CLIENT_NAME}_public.key"
CLIENT_PSK_FILE="${WG_DIR}/${CLIENT_NAME}_psk.key"
echo "$CLIENT_PSK" > "$CLIENT_PSK_FILE"
chmod 600 "$CLIENT_PSK_FILE"

success "Keys generated (client private key in RAM only)"

# =============================================================================
# Add peer to wg0.conf
# =============================================================================

section "Updating wg0.conf"

WG_CONF_BAK="${WG_CONF}.bak.$(date +%s)"
cp "$WG_CONF" "$WG_CONF_BAK"

[[ -s "$WG_CONF" ]] && \
  [[ "$(tail -c1 "$WG_CONF" | od -An -tx1 | tr -d ' ')" != "0a" ]] && \
  printf '\n' >> "$WG_CONF"

if [[ "$CLIENT_TYPE" == "mobile" ]]; then
  ALLOWED_IPS_SERVER="${CLIENT_IP}/32"
else
  if [[ "$GATEWAY_REACH_HOME" == true ]]; then
    ALLOWED_IPS_SERVER="${CLIENT_IP}/32, ${GATEWAY_SUBNET}"
    GATEWAY_ALLOWED_IPS="${VPN_SUBNET}, ${HOME_SUBNET}"
  else
    ALLOWED_IPS_SERVER="${CLIENT_IP}/32, ${GATEWAY_SUBNET}"
    GATEWAY_ALLOWED_IPS="${VPN_SUBNET}"
  fi
fi

cat >> "$WG_CONF" << EOF

# PeerName: ${CLIENT_NAME}
# PeerIP: ${CLIENT_IP}
# PeerType: ${CLIENT_TYPE}
[Peer]
PublicKey = ${CLIENT_PUB}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${ALLOWED_IPS_SERVER}
EOF

rm -f "$WG_CONF_BAK"
success "Peer added to wg0.conf"

# =============================================================================
# Hot-reload peer
# =============================================================================

section "Activating peer"

if ip link show dev "$WG_IFACE" > /dev/null 2>&1; then
  wg set "$WG_IFACE" peer "$CLIENT_PUB" \
    preshared-key <(echo "$CLIENT_PSK") \
    allowed-ips "$ALLOWED_IPS_SERVER"

  if [[ "$CLIENT_TYPE" == "gateway" && -n "$GATEWAY_SUBNET" ]]; then
    ip route replace "$GATEWAY_SUBNET" dev "$WG_IFACE"
    info "Kernel route updated: ${GATEWAY_SUBNET} → ${WG_IFACE}"
  fi

  success "Peer activated live — no disconnection for other clients"
else
  warn "Tunnel not active. Peer will be loaded on next WireGuard start."
fi

# =============================================================================
# Generate client .conf file
# =============================================================================

section "Generating client configuration"

SERVER_IP_FOR_ENDPOINT="${SERVER_PUBLIC_IP}"
[[ -z "$SERVER_IP_FOR_ENDPOINT" ]] && SERVER_IP_FOR_ENDPOINT=$(get_public_ip)
[[ -z "$SERVER_IP_FOR_ENDPOINT" ]] && error "Cannot determine public IP."

CONF_FILE="${OUTPUT_DIR}/${CLIENT_NAME}.conf"

if [[ "$CLIENT_TYPE" == "mobile" ]]; then

  if [[ "$USE_WSTUNNEL" == true ]]; then
    server_ip_prefix2=$(echo "$SERVER_IP_FOR_ENDPOINT" | cut -d. -f1-2)
    vpn_prefix2_check=$(echo "$VPN_SUBNET" | cut -d. -f1-2)
    home_prefix2_check=$(echo "$HOME_SUBNET" | cut -d. -f1-2)
    if [[ "$server_ip_prefix2" == "$vpn_prefix2_check" || \
          "$server_ip_prefix2" == "$home_prefix2_check" ]]; then
      warn "Server IP may be covered by AllowedIPs — check for routing loop."
    fi

    if [[ "$WSTUNNEL_CLIENT_OS" == "linux" ]]; then
      WSTUNNEL_POSTUP="PostUp   = iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -A OUTPUT -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
      WSTUNNEL_POSTDOWN="PostDown = iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; iptables -t mangle -D OUTPUT -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null"
      WSTUNNEL_MSS_COMMENT="# MSS clamping — prevents TCP fragmentation from TLS+WebSocket overhead."
    else
      WSTUNNEL_POSTUP="# PostUp not supported on this OS — MSS clamping must be configured server-side."
      WSTUNNEL_POSTDOWN=""
      WSTUNNEL_MSS_COMMENT="# NOTE: on Linux, MSS clamping is configured with iptables -t mangle TCPMSS --clamp-mss-to-pmtu"
    fi

    cat > "$CONF_FILE" << EOF
# wstunnel/TLS mode via Caddy — WireGuard traffic inside WebSocket over TLS
# BEFORE wg-quick up: start wstunnel with the command in the package README.
# WARNING: do not change AllowedIPs to 0.0.0.0/0 — infinite routing loop.

[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}/32
DNS = ${CLIENT_DNS}
MTU = ${WSTUNNEL_MTU}
${WSTUNNEL_MSS_COMMENT}
${WSTUNNEL_POSTUP}
${WSTUNNEL_POSTDOWN}

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${VPN_SUBNET}, ${HOME_SUBNET}
PersistentKeepalive = 25
Endpoint = 127.0.0.1:${LOCAL_WSTUNNEL_PORT}
EOF

  else
    cat > "$CONF_FILE" << EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}/32
DNS = ${CLIENT_DNS}
MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${VPN_SUBNET}, ${HOME_SUBNET}
PersistentKeepalive = 25
Endpoint = ${SERVER_IP_FOR_ENDPOINT}:${WG_PORT}
EOF
  fi

else
  cat > "$CONF_FILE" << EOF
# Copy to /etc/wireguard/wg0.conf on the gateway
[Interface]
Address = ${CLIENT_IP}/32
PrivateKey = ${CLIENT_PRIV}
MTU = 1420
PostUp = iptables -t filter -C FORWARD -i ${WG_IFACE} -j ACCEPT 2>/dev/null || iptables -t filter -A FORWARD -i ${WG_IFACE} -j ACCEPT
PostUp = iptables -t filter -C FORWARD -o ${WG_IFACE} -j ACCEPT 2>/dev/null || iptables -t filter -A FORWARD -o ${WG_IFACE} -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -o ${GATEWAY_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${GATEWAY_IFACE} -j MASQUERADE
PostDown = iptables -t filter -D FORWARD -i ${WG_IFACE} -j ACCEPT 2>/dev/null
PostDown = iptables -t filter -D FORWARD -o ${WG_IFACE} -j ACCEPT 2>/dev/null
PostDown = iptables -t nat -D POSTROUTING -o ${GATEWAY_IFACE} -j MASQUERADE 2>/dev/null

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${GATEWAY_ALLOWED_IPS}
PersistentKeepalive = 25
Endpoint = ${SERVER_IP_FOR_ENDPOINT}:${WG_PORT}
EOF
fi

success "Config file generated: ${CONF_FILE}"

# =============================================================================
# wstunnel package (.tar.gz with Caddy cert, conf, and README)
# =============================================================================

WSTUNNEL_PACKAGE=""

if [[ "$CLIENT_TYPE" == "mobile" && "$USE_WSTUNNEL" == true ]]; then
  section "Generating wstunnel package"

  PKG_TMPDIR=$(mktemp -d)
  trap 'rm -rf "$PKG_TMPDIR"' EXIT
  PKG_DIR="${PKG_TMPDIR}/${CLIENT_NAME}-wstunnel"
  mkdir -p "$PKG_DIR"

  # 1. WireGuard config file
  cp "$CONF_FILE" "${PKG_DIR}/${CLIENT_NAME}.conf"

  WSTUNNEL_LATEST_VER=$(curl -s --max-time 5 \
    "https://api.github.com/repos/erebe/wstunnel/releases/latest" \
    | grep -Eo '"tag_name": "v[^"]+"' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' || true)
  if [[ -z "$WSTUNNEL_LATEST_VER" ]]; then
    WSTUNNEL_LATEST_VER=$(wstunnel --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
    warn "GitHub API unreachable — using installed version ${WSTUNNEL_LATEST_VER:-unknown} in README (verify latest at github.com/erebe/wstunnel/releases)."
  fi

  cat > "${PKG_DIR}/README.txt" << README
==============================================================
  WireGuard via wstunnel — Client: ${CLIENT_NAME}
==============================================================

VPN IP     : ${CLIENT_IP}/32
Server     : ${SERVER_IP_FOR_ENDPOINT}:${WSTUNNEL_PORT}
Target OS  : ${WSTUNNEL_CLIENT_OS}

SERVER ARCHITECTURE
--------------------
  Internet → Caddy :443 (TLS) → wstunnel :8080 → WireGuard :${WG_PORT}
  The included certificate is Caddy's — it is the only TLS endpoint
  visible from the outside.

PACKAGE CONTENTS
-----------------
  ${CLIENT_NAME}.conf   — WireGuard configuration (contains private key!)
  README.txt            — this file

WSTUNNEL INSTALLATION (one-time)
----------------------------------
Linux / WSL2 (amd64):

  WSTUNNEL_VER="${WSTUNNEL_LATEST_VER}"
  curl -L -o /tmp/wstunnel.tar.gz \\
    "https://github.com/erebe/wstunnel/releases/download/v\${WSTUNNEL_VER}/wstunnel_\${WSTUNNEL_VER}_linux_amd64.tar.gz"
  tar xzf /tmp/wstunnel.tar.gz -C /tmp/
  chmod +x /tmp/wstunnel
  sudo mv /tmp/wstunnel /usr/local/bin/wstunnel
  wstunnel --version

Windows / macOS:
  Download from: https://github.com/erebe/wstunnel/releases/latest

STARTING A VPN SESSION (required order)
-----------------------------------------

STEP 1 — Terminal 1: start wstunnel (keep it open for the entire session)

  wstunnel client \\
    --http-upgrade-path-prefix "${WSTUNNEL_SECRET}" \\
    --websocket-ping-frequency 30s \\
    -L "udp://127.0.0.1:${LOCAL_WSTUNNEL_PORT}:127.0.0.1:${WG_PORT}?timeout_sec=0" \\
    wss://${SERVER_IP_FOR_ENDPOINT}:${WSTUNNEL_PORT}

  TLS NOTE: wstunnel v10 removed --tls-ca-certificate. Certificate verification is
  disabled by default — wstunnel connects to self-signed certs without error.
  TLS still encrypts the tunnel; WireGuard adds a second encryption layer on top.
  To enable standard cert verification (requires a publicly trusted cert), add:
    --tls-verify-certificate

STEP 2 — Terminal 2: bring up WireGuard

  sudo wg-quick up /path/to/${CLIENT_NAME}.conf

SHUTDOWN
---------
  sudo wg-quick down /path/to/${CLIENT_NAME}.conf
  Ctrl+C in Terminal 1  (or: pkill -f "wstunnel client")

VERIFICATION
-------------
  ss -ulnp | grep ${LOCAL_WSTUNNEL_PORT}   # wstunnel listening?
  sudo wg show                              # WireGuard session?
  ping ${VPN_PREFIX}.1                      # ping VPN server

MTU NOTE
---------
  MTU=${WSTUNNEL_MTU} — reduced from 1420 to account for TLS+WebSocket overhead.
  Other WireGuard peers are unaffected.

SECURITY
---------
  This package contains your WireGuard private key.
  Delete it after copying the files:
    rm -rf /path/to/${CLIENT_NAME}-wstunnel/

  The secret in the URL is equivalent to a password: do not share it.
  The server (Caddy) accepts connections ONLY from the path with the correct secret.
  wstunnel performs an independent second check (defence in depth).
  Security layers in place:
    1. TLS encryption (Caddy self-signed cert, unverified by client)
    2. Secret path authentication (Caddy + wstunnel double-check)
    3. WireGuard encryption + authentication (keys + PSK)
==============================================================
README

  WSTUNNEL_PACKAGE="${OUTPUT_DIR}/${CLIENT_NAME}-wstunnel.tar.gz"
  tar czf "$WSTUNNEL_PACKAGE" -C "$PKG_TMPDIR" "${CLIENT_NAME}-wstunnel/"
  chmod 600 "$WSTUNNEL_PACKAGE"

  success "Package generated: ${WSTUNNEL_PACKAGE}"
  info "Contents:"
  tar tzf "$WSTUNNEL_PACKAGE" | sed 's/^/    /'
fi

# =============================================================================
# QR code
# =============================================================================

echo ""
if [[ "$USE_WSTUNNEL" == true ]]; then
  info "QR code not generated — wstunnel mode requires a two-step setup."
elif [[ "$QRENCODE_AVAILABLE" == false ]]; then
  warn "QR code not generated — qrencode not available."
else
  echo -e "${BOLD}QR code — ${CLIENT_NAME} (${CLIENT_IP})${NC}"
  echo "────────────────────────────────────────────────────────"
  qrencode -t ansiutf8 -m 2 < "$CONF_FILE"
  echo "────────────────────────────────────────────────────────"
fi

# =============================================================================
# Final summary
# =============================================================================

section "Done"

echo -e "  Client ${BOLD}${CLIENT_NAME}${NC} added successfully."
echo ""
echo -e "  Config file : ${BOLD}${CONF_FILE}${NC}"
if [[ -n "$WSTUNNEL_PACKAGE" ]]; then
  echo -e "  Package     : ${BOLD}${WSTUNNEL_PACKAGE}${NC}"
  echo -e "               (conf + README.txt)"
fi
echo ""

if [[ "$CLIENT_TYPE" == "gateway" ]]; then
  echo -e "${YELLOW}Next steps on the remote gateway:${NC}"
  echo "  scp ${CONF_FILE} user@<GATEWAY_IP>:/tmp/"
  echo "  sudo mv /tmp/${CLIENT_NAME}.conf /etc/wireguard/wg0.conf"
  echo "  sudo chmod 600 /etc/wireguard/wg0.conf"
  echo "  sudo apt install wireguard iptables -y"
  echo "  echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf && sudo sysctl -p"
  echo "  sudo systemctl enable --now wg-quick@wg0"
  echo ""
fi

if [[ "$CLIENT_TYPE" == "mobile" && "$USE_WSTUNNEL" == true ]]; then
  echo -e "${BOLD}━━━  Next steps — wstunnel  ━━━${NC}"
  echo ""
  echo -e "  1. Transfer the package to the client:"
  echo -e "     ${BOLD}scp ${WSTUNNEL_PACKAGE} user@<CLIENT_IP>:~/${NC}"
  echo ""
  echo -e "  2. Extract and follow instructions:"
  echo -e "     ${BOLD}tar xzf ${CLIENT_NAME}-wstunnel.tar.gz${NC}"
  echo -e "     Follow ${BOLD}${CLIENT_NAME}-wstunnel/README.txt${NC}"
  echo ""
fi

echo ""
echo -e "${RED}Security: generated files contain private keys.${NC}"
echo -e "${RED}Delete after transferring:${NC}"
[[ -n "$WSTUNNEL_PACKAGE" ]] && echo -e "${RED}  rm ${WSTUNNEL_PACKAGE}${NC}"
echo -e "${RED}  rm ${CONF_FILE}${NC}"
echo ""

wg show "$WG_IFACE" 2>/dev/null || true

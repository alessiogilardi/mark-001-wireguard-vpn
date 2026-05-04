#!/usr/bin/env bash
# =============================================================================
# wg-setup.sh — WireGuard server setup on AWS Lightsail (Ubuntu 22.04)
#
# Usage:
#   chmod +x wg-setup.sh
#   sudo ./wg-setup.sh
#
# This script is idempotent: can be re-run safely.
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
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run with sudo: sudo ./wg-setup.sh"

# =============================================================================
# CONFIGURATION — edit these values before running the script
# =============================================================================

# Lightsail static public IP (required)
SERVER_PUBLIC_IP=""

# Number of mobile peers to generate (1-10)
MOBILE_PEERS=5

# VPN subnet
VPN_SUBNET="10.13.13.0/24"
SERVER_VPN_IP="10.13.13.1"
PI_VPN_IP="10.13.13.2"
MOBILE_VPN_START=3   # mobile peers start at 10.13.13.3

# Home network
HOME_SUBNET="192.168.68.0/22"
PI_LOCAL_IP="192.168.68.200"

# WireGuard port
WG_PORT=51820

# Working directories
WG_DIR="/etc/wireguard"
OUTPUT_DIR="/root/wg-clients"

# =============================================================================

# ── Configuration validation ──────────────────────────────────────────────────
section "Configuration validation"

if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  info "SERVER_PUBLIC_IP not set, attempting auto-detection via AWS metadata..."
  SERVER_PUBLIC_IP=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 || true)

  if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    info "AWS metadata unavailable, falling back to ipify.org..."
    SERVER_PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org || true)
  fi

  if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    error "Cannot detect public IP. Set SERVER_PUBLIC_IP in the script."
  fi
  success "Public IP detected: ${SERVER_PUBLIC_IP}"
fi

if ! [[ "$MOBILE_PEERS" =~ ^[1-9]$|^10$ ]]; then
  error "MOBILE_PEERS must be a number between 1 and 10"
fi

success "Configuration valid"
echo -e "  Server public IP   : ${BOLD}${SERVER_PUBLIC_IP}${NC}"
echo -e "  VPN subnet         : ${BOLD}${VPN_SUBNET}${NC}"
echo -e "  Home network       : ${BOLD}${HOME_SUBNET}${NC}"
echo -e "  Mobile peers       : ${BOLD}${MOBILE_PEERS}${NC}"

# ── Confirm before proceeding ─────────────────────────────────────────────────
echo ""
read -rp "$(echo -e "${YELLOW}Proceed with installation? [y/N]${NC} ")" confirm
[[ "${confirm,,}" == "y" ]] || { info "Operation cancelled."; exit 0; }

# =============================================================================
section "WireGuard installation"
# =============================================================================

apt-get update -qq
apt-get install -y wireguard wireguard-tools iptables qrencode > /dev/null
success "WireGuard installed"

# =============================================================================
section "IP forwarding"
# =============================================================================

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf > /dev/null
success "IP forwarding enabled (via /etc/sysctl.d/99-wireguard.conf)"

# =============================================================================
section "Key generation"
# =============================================================================

mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"
mkdir -p "$OUTPUT_DIR"

# Helper: generate keypair if it doesn't exist yet
gen_keypair() {
  local name="$1"
  local priv="${WG_DIR}/${name}_private.key"
  local pub="${WG_DIR}/${name}_public.key"
  local psk="${WG_DIR}/${name}_psk.key"

  if [[ ! -f "$priv" ]]; then
    wg genkey | tee "$priv" | wg pubkey > "$pub"
    wg genpsk > "$psk"
    chmod 600 "$priv" "$psk"
    info "Keys generated: ${name}"
  else
    warn "Keys already exist for ${name}, skipping"
  fi
}

# Server
gen_keypair "server"

# Raspberry Pi
gen_keypair "pi"

# Mobile peers
for i in $(seq 1 "$MOBILE_PEERS"); do
  gen_keypair "mobile${i}"
done

success "All keys are ready"

# =============================================================================
section "Server configuration (wg0.conf)"
# =============================================================================

# Detect main network interface (e.g. eth0, ens3, enX0...)
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
[[ -z "$DEFAULT_IFACE" ]] && error "Cannot detect main network interface"
info "Network interface detected: ${DEFAULT_IFACE}"

SERVER_PRIV=$(cat "${WG_DIR}/server_private.key")

# Build [Peer] blocks for the server config
PEER_BLOCKS=""

# Peer: Raspberry Pi
PI_PUB=$(cat "${WG_DIR}/pi_public.key")
PI_PSK=$(cat "${WG_DIR}/pi_psk.key")
PEER_BLOCKS+="
# ── Raspberry Pi ─────────────────────────────────────────
[Peer]
PublicKey = ${PI_PUB}
PresharedKey = ${PI_PSK}
AllowedIPs = ${PI_VPN_IP}/32, ${HOME_SUBNET}
"

# Mobile peers
for i in $(seq 1 "$MOBILE_PEERS"); do
  MOBILE_IP="10.13.13.$((MOBILE_VPN_START + i - 1))"
  MOBILE_PUB=$(cat "${WG_DIR}/mobile${i}_public.key")
  MOBILE_PSK=$(cat "${WG_DIR}/mobile${i}_psk.key")
  PEER_BLOCKS+="
# ── mobile${i} (${MOBILE_IP}) ──────────────────────────────────
[Peer]
PublicKey = ${MOBILE_PUB}
PresharedKey = ${MOBILE_PSK}
AllowedIPs = ${MOBILE_IP}/32
"
done

# Write wg0.conf (overwrites if exists)
cat > "${WG_DIR}/wg0.conf" << EOF
[Interface]
Address = ${SERVER_VPN_IP}/24
PrivateKey = ${SERVER_PRIV}
ListenPort = ${WG_PORT}
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
${PEER_BLOCKS}
EOF

chmod 600 "${WG_DIR}/wg0.conf"
success "wg0.conf written"

# =============================================================================
section "Starting WireGuard"
# =============================================================================

# If tunnel is already active, restart to apply new config
if systemctl is-active --quiet wg-quick@wg0; then
  warn "Tunnel already active — restarting to apply new configuration"
  systemctl restart wg-quick@wg0
else
  systemctl enable --now wg-quick@wg0
fi

sleep 2

if systemctl is-active --quiet wg-quick@wg0; then
  success "WireGuard tunnel active"
else
  error "Tunnel failed to start. Check: journalctl -u wg-quick@wg0"
fi

# =============================================================================
section "Generating client configurations"
# =============================================================================

SERVER_PUB=$(cat "${WG_DIR}/server_public.key")

# ── Raspberry Pi ──────────────────────────────────────────────────────────────
PI_PRIV=$(cat "${WG_DIR}/pi_private.key")
PI_PSK=$(cat "${WG_DIR}/pi_psk.key")

echo ""
warn "Raspberry Pi network interface"
echo "  On Debian 12 the ethernet interface may be named 'eth0', 'end0', or similar."
echo "  Verify on the Pi with: ip a"
echo ""
read -rp "$(echo -e "${YELLOW}  Pi ethernet interface name [eth0]:${NC} ")" PI_IFACE
PI_IFACE="${PI_IFACE:-eth0}"
info "Pi interface set to: ${PI_IFACE}"

cat > "${OUTPUT_DIR}/raspberry-pi.conf" << EOF
# Copy to /etc/wireguard/wg0.conf on the Raspberry Pi
[Interface]
Address = ${PI_VPN_IP}/32
PrivateKey = ${PI_PRIV}
MTU = 1420
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${PI_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${PI_IFACE} -j MASQUERADE

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PI_PSK}
AllowedIPs = ${VPN_SUBNET}
PersistentKeepalive = 25
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
EOF

success "Pi config: ${OUTPUT_DIR}/raspberry-pi.conf"

# ── Mobile peers ──────────────────────────────────────────────────────────────
echo ""
warn "DNS for mobile peers (split-tunnel)"
echo "  Mobile peers use split-tunnel: only VPN and home network traffic"
echo "  goes through the tunnel. The DNS chosen here applies only to that traffic."
echo ""
echo "  Common options:"
echo "    1.1.1.1          → Cloudflare (default, resolves public names only)"
echo "    ${PI_LOCAL_IP}  → Pi-Hole or home DNS (resolves local hostnames too)"
echo "  Leave empty for default (1.1.1.1), enter '-' to omit the DNS directive entirely."
echo ""
read -rp "$(echo -e "${YELLOW}  DNS for mobile peers [1.1.1.1]:${NC} ")" MOBILE_DNS_INPUT
if [[ -z "$MOBILE_DNS_INPUT" ]]; then
  MOBILE_DNS="1.1.1.1"
  MOBILE_DNS_LINE="DNS = 1.1.1.1"
  info "DNS set to default: 1.1.1.1"
elif [[ "$MOBILE_DNS_INPUT" == "-" ]]; then
  MOBILE_DNS=""
  MOBILE_DNS_LINE=""
  info "DNS directive omitted — devices will use their carrier DNS."
else
  MOBILE_DNS="$MOBILE_DNS_INPUT"
  MOBILE_DNS_LINE="DNS = ${MOBILE_DNS}"
  info "DNS set to: ${MOBILE_DNS}"
fi
for i in $(seq 1 "$MOBILE_PEERS"); do
  MOBILE_IP="10.13.13.$((MOBILE_VPN_START + i - 1))"
  MOBILE_PRIV=$(cat "${WG_DIR}/mobile${i}_private.key")
  MOBILE_PSK=$(cat "${WG_DIR}/mobile${i}_psk.key")
  CONF_FILE="${OUTPUT_DIR}/mobile${i}.conf"

  cat > "$CONF_FILE" << EOF
[Interface]
PrivateKey = ${MOBILE_PRIV}
Address = ${MOBILE_IP}/32
MTU = 1420
${MOBILE_DNS_LINE}

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${MOBILE_PSK}
AllowedIPs = ${VPN_SUBNET}, ${HOME_SUBNET}
PersistentKeepalive = 25
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
EOF

  success "mobile${i} config: ${CONF_FILE}"

  echo ""
  echo -e "${BOLD}QR code — mobile${i} (${MOBILE_IP})${NC}"
  echo "────────────────────────────────────────"
  qrencode -t ansiutf8 < "$CONF_FILE"
  echo "────────────────────────────────────────"
done

# =============================================================================
section "Final instructions"
# =============================================================================

echo ""
echo -e "${BOLD}WireGuard server configured successfully.${NC}"
echo ""
echo -e "  Tunnel status   : ${GREEN}$(systemctl is-active wg-quick@wg0)${NC}"
echo -e "  Server VPN IP   : ${BOLD}${SERVER_VPN_IP}${NC}"
echo -e "  Port            : ${BOLD}${WG_PORT}/udp${NC}"
echo ""
echo -e "${BOLD}Client files generated in: ${OUTPUT_DIR}/${NC}"
ls -1 "$OUTPUT_DIR"
echo ""
echo -e "${YELLOW}⚠️  AWS Lightsail firewall:${NC}"
echo "  This script configures iptables on the OS, but Lightsail has a separate cloud firewall."
echo "  Before connecting clients, manually open the port in the AWS console:"
echo "  → Lightsail → instance → Networking → Add rule: UDP ${WG_PORT} (from any IP)"
echo ""
echo -e "${YELLOW}⚠️  UFW (if enabled):${NC}"
echo "  If ufw is enabled on this instance, add the rule:"
echo "    sudo ufw allow ${WG_PORT}/udp"
echo "  Verify with: sudo ufw status"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Copy raspberry-pi.conf to the Pi:"
echo "       scp ${OUTPUT_DIR}/raspberry-pi.conf pi@${PI_LOCAL_IP}:/tmp/"
echo "     then on the Pi:"
echo "       sudo mv /tmp/raspberry-pi.conf /etc/wireguard/wg0.conf"
echo "       sudo chmod 600 /etc/wireguard/wg0.conf"
echo "       sudo apt install wireguard iptables -y"
echo "       echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf && sudo sysctl -p"
echo "       sudo systemctl enable --now wg-quick@wg0"
echo ""
echo "  2. Import mobile*.conf files into WireGuard clients"
echo "     or scan the QR codes shown above."
echo ""
echo -e "${RED}Security: files in ${OUTPUT_DIR}/ contain private keys.${NC}"
echo -e "${RED}Delete them after configuring all devices:${NC}"
echo -e "${RED}  rm -rf ${OUTPUT_DIR}/${NC}"
echo ""

# Show WireGuard status
wg show

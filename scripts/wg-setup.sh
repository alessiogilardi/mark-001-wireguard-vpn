#!/usr/bin/env bash
# =============================================================================
# wg-setup.sh — Setup WireGuard server su AWS Lightsail (Ubuntu 22.04)
#
# Uso:
#   chmod +x wg-setup.sh
#   sudo ./wg-setup.sh
#
# Lo script è idempotente: può essere rieseguito senza danni.
# =============================================================================

set -euo pipefail

# ── Colori ────────────────────────────────────────────────────────────────────
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

# ── Controllo root ────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Eseguire con sudo: sudo ./wg-setup.sh"

# =============================================================================
# CONFIGURAZIONE — modifica questi valori prima di eseguire lo script
# =============================================================================

# IP pubblico statico di Lightsail (obbligatorio)
SERVER_PUBLIC_IP=""

# Numero di peer mobili da generare (1-10)
MOBILE_PEERS=5

# Subnet VPN
VPN_SUBNET="10.13.13.0/24"
SERVER_VPN_IP="10.13.13.1"
PI_VPN_IP="10.13.13.2"
MOBILE_VPN_START=3   # i peer mobili partiranno da 10.13.13.3

# Rete di casa
HOME_SUBNET="192.168.68.0/22"
PI_LOCAL_IP="192.168.68.200"

# Porta WireGuard
WG_PORT=51820

# Directory di lavoro
WG_DIR="/etc/wireguard"
OUTPUT_DIR="/root/wg-clients"

# =============================================================================

# ── Validazione configurazione ────────────────────────────────────────────────
section "Validazione configurazione"

if [[ -z "$SERVER_PUBLIC_IP" ]]; then
  info "SERVER_PUBLIC_IP non impostato, tento auto-rilevamento tramite metadati AWS..."
  SERVER_PUBLIC_IP=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 || true)

  if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    info "Metadati AWS non disponibili, fallback su ipify.org..."
    SERVER_PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org || true)
  fi

  if [[ -z "$SERVER_PUBLIC_IP" ]]; then
    error "Impossibile rilevare l'IP pubblico. Impostare SERVER_PUBLIC_IP nello script."
  fi
  success "IP pubblico rilevato: ${SERVER_PUBLIC_IP}"
fi

if ! [[ "$MOBILE_PEERS" =~ ^[1-9]$|^10$ ]]; then
  error "MOBILE_PEERS deve essere un numero tra 1 e 10"
fi

success "Configurazione valida"
echo -e "  Server IP pubblico : ${BOLD}${SERVER_PUBLIC_IP}${NC}"
echo -e "  VPN subnet         : ${BOLD}${VPN_SUBNET}${NC}"
echo -e "  Rete di casa       : ${BOLD}${HOME_SUBNET}${NC}"
echo -e "  Peer mobili        : ${BOLD}${MOBILE_PEERS}${NC}"

# ── Conferma prima di procedere ───────────────────────────────────────────────
echo ""
read -rp "$(echo -e "${YELLOW}Procedere con l'installazione? [y/N]${NC} ")" confirm
[[ "${confirm,,}" == "y" ]] || { info "Operazione annullata."; exit 0; }

# =============================================================================
section "Installazione WireGuard"
# =============================================================================

apt-get update -qq
apt-get install -y wireguard wireguard-tools iptables qrencode > /dev/null
success "WireGuard installato"

# =============================================================================
section "IP forwarding"
# =============================================================================

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf > /dev/null
success "IP forwarding abilitato (via /etc/sysctl.d/99-wireguard.conf)"

# =============================================================================
section "Generazione chiavi"
# =============================================================================

mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"
mkdir -p "$OUTPUT_DIR"

# Funzione helper: genera keypair se non esiste già
gen_keypair() {
  local name="$1"
  local priv="${WG_DIR}/${name}_private.key"
  local pub="${WG_DIR}/${name}_public.key"
  local psk="${WG_DIR}/${name}_psk.key"

  if [[ ! -f "$priv" ]]; then
    wg genkey | tee "$priv" | wg pubkey > "$pub"
    wg genpsk > "$psk"
    chmod 600 "$priv" "$psk"
    info "Chiavi generate: ${name}"
  else
    warn "Chiavi già esistenti per ${name}, salto generazione"
  fi
}

# Server
gen_keypair "server"

# Raspberry Pi
gen_keypair "pi"

# Peer mobili
for i in $(seq 1 "$MOBILE_PEERS"); do
  gen_keypair "mobile${i}"
done

success "Tutte le chiavi sono pronte"

# =============================================================================
section "Configurazione server (wg0.conf)"
# =============================================================================

# Rileva interfaccia di rete principale (es. eth0, ens3, enX0...)
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
[[ -z "$DEFAULT_IFACE" ]] && error "Impossibile rilevare l'interfaccia di rete principale"
info "Interfaccia di rete rilevata: ${DEFAULT_IFACE}"

SERVER_PRIV=$(cat "${WG_DIR}/server_private.key")

# Costruisce i blocchi [Peer] per il server
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

# Peer: mobili
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

# Scrive wg0.conf (sovrascrive se già esiste)
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
success "wg0.conf scritto"

# =============================================================================
section "Avvio WireGuard"
# =============================================================================

# Se il tunnel è già attivo, lo riavvia per applicare la nuova config
if systemctl is-active --quiet wg-quick@wg0; then
  warn "Tunnel già attivo — riavvio per applicare la nuova configurazione"
  systemctl restart wg-quick@wg0
else
  systemctl enable --now wg-quick@wg0
fi

sleep 2

if systemctl is-active --quiet wg-quick@wg0; then
  success "Tunnel WireGuard attivo"
else
  error "Il tunnel non si è avviato. Controlla: journalctl -u wg-quick@wg0"
fi

# =============================================================================
section "Generazione configurazioni client"
# =============================================================================

SERVER_PUB=$(cat "${WG_DIR}/server_public.key")

# ── Raspberry Pi ──────────────────────────────────────────────────────────────
PI_PRIV=$(cat "${WG_DIR}/pi_private.key")
PI_PSK=$(cat "${WG_DIR}/pi_psk.key")

echo ""
warn "Interfaccia di rete del Raspberry Pi"
echo "  Su Debian 12 l'interfaccia ethernet potrebbe chiamarsi 'eth0', 'end0' o altro."
echo "  Puoi verificarlo sul Pi con: ip a"
echo ""
read -rp "$(echo -e "${YELLOW}  Nome interfaccia ethernet del Pi [eth0]:${NC} ")" PI_IFACE
PI_IFACE="${PI_IFACE:-eth0}"
info "Interfaccia Pi impostata a: ${PI_IFACE}"

cat > "${OUTPUT_DIR}/raspberry-pi.conf" << EOF
# Copiare in /etc/wireguard/wg0.conf sul Raspberry Pi
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

success "Configurazione Pi: ${OUTPUT_DIR}/raspberry-pi.conf"

# ── Peer mobili ───────────────────────────────────────────────────────────────
echo ""
warn "DNS per i peer mobili (split-tunnel)"
echo "  I peer mobili usano uno split-tunnel: solo il traffico VPN e rete di casa"
echo "  passa nel tunnel. Il DNS scelto qui viene usato solo per quel traffico."
echo ""
echo "  Opzioni comuni:"
echo "    1.1.1.1          → Cloudflare (default, risolve solo nomi pubblici)"
echo "    ${PI_LOCAL_IP}  → Pi-Hole o DNS di casa (risolve anche hostname locali)"
echo "  Lascia vuoto per il default (1.1.1.1), inserisci '-' per omettere del tutto la direttiva DNS."
echo ""
read -rp "$(echo -e "${YELLOW}  DNS per i peer mobili [1.1.1.1]:${NC} ")" MOBILE_DNS_INPUT
if [[ -z "$MOBILE_DNS_INPUT" ]]; then
  MOBILE_DNS="1.1.1.1"
  MOBILE_DNS_LINE="DNS = 1.1.1.1"
  info "DNS impostato al default: 1.1.1.1"
elif [[ "$MOBILE_DNS_INPUT" == "-" ]]; then
  MOBILE_DNS=""
  MOBILE_DNS_LINE=""
  info "Direttiva DNS omessa — i device useranno il DNS del proprio operatore."
else
  MOBILE_DNS="$MOBILE_DNS_INPUT"
  MOBILE_DNS_LINE="DNS = ${MOBILE_DNS}"
  info "DNS impostato a: ${MOBILE_DNS}"
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

  success "Configurazione mobile${i}: ${CONF_FILE}"

  echo ""
  echo -e "${BOLD}QR code — mobile${i} (${MOBILE_IP})${NC}"
  echo "────────────────────────────────────────"
  qrencode -t ansiutf8 < "$CONF_FILE"
  echo "────────────────────────────────────────"
done

# =============================================================================
section "Istruzioni finali"
# =============================================================================

echo ""
echo -e "${BOLD}Server WireGuard configurato con successo.${NC}"
echo ""
echo -e "  Stato tunnel    : ${GREEN}$(systemctl is-active wg-quick@wg0)${NC}"
echo -e "  IP VPN server   : ${BOLD}${SERVER_VPN_IP}${NC}"
echo -e "  Porta           : ${BOLD}${WG_PORT}/udp${NC}"
echo ""
echo -e "${BOLD}File client generati in: ${OUTPUT_DIR}/${NC}"
ls -1 "$OUTPUT_DIR"
echo ""
echo -e "${YELLOW}⚠️  Firewall AWS Lightsail:${NC}"
echo "  Lo script configura iptables sull'OS, ma Lightsail ha un firewall cloud separato."
echo "  Prima di collegare i client, apri manualmente la porta nella console AWS:"
echo "  → Lightsail → istanza → Networking → Add rule: UDP ${WG_PORT} (da qualsiasi IP)"
echo ""
echo -e "${YELLOW}⚠️  UFW (se abilitato):${NC}"
echo "  Se hai attivato ufw su questa istanza, aggiungi la regola:"
echo "    sudo ufw allow ${WG_PORT}/udp"
echo "  Verifica con: sudo ufw status"
echo ""
echo -e "${YELLOW}Prossimi passi:${NC}"
echo "  1. Copia raspberry-pi.conf sul Pi:"
echo "       scp ${OUTPUT_DIR}/raspberry-pi.conf pi@${PI_LOCAL_IP}:/tmp/"
echo "     poi sul Pi:"
echo "       sudo mv /tmp/raspberry-pi.conf /etc/wireguard/wg0.conf"
echo "       sudo chmod 600 /etc/wireguard/wg0.conf"
echo "       sudo apt install wireguard iptables -y"
echo "       echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf && sudo sysctl -p"
echo "       sudo systemctl enable --now wg-quick@wg0"
echo ""
echo "  2. Importa i file mobile*.conf nei client WireGuard"
echo "     oppure scansiona i QR code mostrati sopra."
echo ""
echo -e "${RED}Sicurezza: i file in ${OUTPUT_DIR}/ contengono chiavi private.${NC}"
echo -e "${RED}Eliminarli dopo aver configurato tutti i device:${NC}"
echo -e "${RED}  rm -rf ${OUTPUT_DIR}/${NC}"
echo ""

# Mostra stato wg
wg show

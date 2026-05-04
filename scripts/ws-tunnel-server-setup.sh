#!/usr/bin/env bash
# =============================================================================
# wstunnel-server-setup.sh — Installa wstunnel v10 e genera il secret condiviso
#
# Uso:
#   chmod +x wstunnel-server-setup.sh
#   sudo ./wstunnel-server-setup.sh
#
# Prerequisiti:
#   - WireGuard già installato e funzionante su UDP:51820
#   - curl installato
#
# Questo script è idempotente: può essere rieseguito senza effetti collaterali.
# Se wstunnel è già installato, viene aggiornato solo se la versione è diversa.
#
# Nota: il TLS è gestito da Caddy (caddy-setup.sh), non da questo script.
# wstunnel gira come backend locale su ws://127.0.0.1:8080 senza TLS diretto.
# Eseguire caddy-setup.sh dopo questo script.
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
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}\n"; }

# ── Controllo root ────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Eseguire con sudo: sudo ./wstunnel-server-setup.sh"

umask 077

# ── Costanti configurabili ────────────────────────────────────────────────────
WSTUNNEL_DIR="/etc/wstunnel"
WSTUNNEL_BIN="/usr/local/bin/wstunnel"
WSTUNNEL_SECRET_FILE="${WSTUNNEL_DIR}/secret"
# File env letto da wstunnel.service e caddy.service via EnvironmentFile.
# Generato qui, consumato da caddy-setup.sh — unica fonte di verità.
SECRET_ENV_FILE="${WSTUNNEL_DIR}/secret-env"
WSTUNNEL_INTERNAL_PORT=8080   # porta loopback — TLS terminato da Caddy
WG_PORT=51820
SERVICE_FILE="/etc/systemd/system/wstunnel.service"

# =============================================================================
# Intestazione
# =============================================================================

clear
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    wstunnel — Setup backend v10          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# Prerequisiti
# =============================================================================

section "Verifica prerequisiti"

command -v curl > /dev/null || error "curl non trovato. Installa con: apt install curl"

if ! ss -ulnp | grep -q ":${WG_PORT}"; then
  warn "Nessun processo in ascolto su UDP:${WG_PORT}."
  warn "Verifica che WireGuard sia attivo: sudo systemctl status wg-quick@wg0"
  read -rp "$(echo -e "${YELLOW}Continuare comunque? [y/N]:${NC} ")" force_continue
  [[ "${force_continue,,}" == "y" ]] || exit 0
fi

success "Prerequisiti verificati"

# =============================================================================
# Download wstunnel
# =============================================================================

section "Installazione wstunnel"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  WSTUNNEL_ARCH="amd64" ;;
  aarch64) WSTUNNEL_ARCH="arm64" ;;
  armv7l)  WSTUNNEL_ARCH="armv7" ;;
  *)       error "Architettura non supportata: ${ARCH}" ;;
esac

info "Architettura rilevata: ${ARCH} → ${WSTUNNEL_ARCH}"

WSTUNNEL_VERSION=$(curl -s \
  "https://api.github.com/repos/erebe/wstunnel/releases/latest" \
  | grep -oP '"tag_name": "v\K[^"]+' || true)

[[ -z "$WSTUNNEL_VERSION" ]] && error "Impossibile recuperare la versione più recente da GitHub."
info "Ultima versione disponibile: v${WSTUNNEL_VERSION}"

INSTALL_WSTUNNEL=false
if command -v wstunnel > /dev/null 2>&1; then
  INSTALLED_VERSION=$(wstunnel --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
  if [[ "$INSTALLED_VERSION" == "$WSTUNNEL_VERSION" ]]; then
    success "wstunnel v${WSTUNNEL_VERSION} già installato — skip download"
  else
    info "Versione installata: ${INSTALLED_VERSION:-sconosciuta} — aggiornamento a ${WSTUNNEL_VERSION}"
    INSTALL_WSTUNNEL=true
  fi
else
  INSTALL_WSTUNNEL=true
fi

if [[ "$INSTALL_WSTUNNEL" == "true" ]]; then
  DOWNLOAD_URL="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/wstunnel_${WSTUNNEL_VERSION}_linux_${WSTUNNEL_ARCH}.tar.gz"
  TMPDIR_WS=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_WS"' EXIT

  info "Download da: ${DOWNLOAD_URL}"
  curl -L --progress-bar -o "${TMPDIR_WS}/wstunnel.tar.gz" "$DOWNLOAD_URL" \
    || error "Download fallito. Verifica la connettività e la versione su github.com/erebe/wstunnel/releases"

  tar xzf "${TMPDIR_WS}/wstunnel.tar.gz" -C "${TMPDIR_WS}/"

  EXTRACTED_BIN="${TMPDIR_WS}/wstunnel"
  [[ ! -f "$EXTRACTED_BIN" ]] && error "Binario 'wstunnel' non trovato nell'archivio."

  file "$EXTRACTED_BIN" | grep -q "ELF" \
    || error "Il file scaricato non sembra un eseguibile ELF valido."

  if systemctl is-active --quiet wstunnel 2>/dev/null; then
    info "Fermo wstunnel.service per aggiornamento binario..."
    systemctl stop wstunnel
  fi

  install -m 755 "$EXTRACTED_BIN" "$WSTUNNEL_BIN"
  success "wstunnel v${WSTUNNEL_VERSION} installato in ${WSTUNNEL_BIN}"
fi

INSTALLED_VER=$(wstunnel --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
info "Versione attiva: ${INSTALLED_VER}"

# =============================================================================
# Generazione secret e secret-env
# =============================================================================

section "Configurazione secret"

# Il secret è la fonte di verità condivisa tra Caddy e wstunnel.
# Caddy lo legge via {env.WSTUNNEL_SECRET} nel Caddyfile.
# wstunnel lo legge via $WSTUNNEL_SECRET nell'ExecStart.
# Entrambi usano EnvironmentFile=${SECRET_ENV_FILE}.
#
# Non viene rigenerato automaticamente — cambiarlo invalida tutti i client esistenti.

mkdir -p "$WSTUNNEL_DIR"
chmod 700 "$WSTUNNEL_DIR"

if [[ -f "$WSTUNNEL_SECRET_FILE" ]]; then
  success "Secret già presente — conservo quello esistente"
  info "  (elimina ${WSTUNNEL_SECRET_FILE} e riesegui per rigenerarlo)"
else
  # 32 byte → 43 caratteri base64url senza padding — URL-safe
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '=' > "$WSTUNNEL_SECRET_FILE"
  chmod 600 "$WSTUNNEL_SECRET_FILE"
  success "Secret generato: ${WSTUNNEL_SECRET_FILE}"
fi

WSTUNNEL_SECRET=$(cat "$WSTUNNEL_SECRET_FILE")
[[ -z "$WSTUNNEL_SECRET" ]] && error "Il file secret è vuoto."
info "Secret (prefisso URL): ${WSTUNNEL_SECRET:0:8}…"

# Genera secret-env — formato EnvironmentFile systemd
printf 'WSTUNNEL_SECRET=%s\n' "$WSTUNNEL_SECRET" > "$SECRET_ENV_FILE"
chmod 640 "$SECRET_ENV_FILE"
success "secret-env generato: ${SECRET_ENV_FILE}"

# =============================================================================
# Configurazione systemd
# =============================================================================

section "Configurazione systemd"

# wstunnel gira come backend locale — non ha bisogno di:
#   - leggere cert/key TLS (gestiti da Caddy)
#   - aprire porte privilegiate (ascolta su 8080, non su 443)
#   - setcap (CAP_NET_BIND_SERVICE non serve per porte > 1024)
#
# Il secret viene iniettato tramite EnvironmentFile — non appare in chiaro
# in `systemctl status` né nei log di journald.

if ! id wstunnel > /dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin wstunnel
  success "Utente di sistema 'wstunnel' creato"
else
  info "Utente 'wstunnel' già presente"
fi

chown root:wstunnel "$WSTUNNEL_DIR"
chmod 750 "$WSTUNNEL_DIR"
chown root:wstunnel "$WSTUNNEL_SECRET_FILE" "$SECRET_ENV_FILE"
chmod 640 "$WSTUNNEL_SECRET_FILE" "$SECRET_ENV_FILE"

# Rimuovi setcap se era stato impostato da una versione precedente dello script
if command -v getcap > /dev/null 2>&1 && \
   getcap "$WSTUNNEL_BIN" 2>/dev/null | grep -q "cap_net_bind_service"; then
  setcap -r "$WSTUNNEL_BIN" \
    && info "CAP_NET_BIND_SERVICE rimosso (non necessario per porta ${WSTUNNEL_INTERNAL_PORT})" \
    || warn "Impossibile rimuovere setcap — non critico"
fi

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=wstunnel — WireGuard over WebSocket (backend locale)
Documentation=https://github.com/erebe/wstunnel
After=network-online.target
Wants=network-online.target
# caddy-setup.sh aggiunge un drop-in override con After=caddy.service

[Service]
Type=simple
User=wstunnel
Group=wstunnel

# Secret iniettato come variabile d'ambiente — non appare in chiaro nei log
EnvironmentFile=${SECRET_ENV_FILE}

# ws:// (no TLS) — la cifratura è delegata a Caddy sul fronte pubblico
# 127.0.0.1 — non esposto su internet, solo loopback
ExecStart=${WSTUNNEL_BIN} server \\
  --restrict-to      127.0.0.1:${WG_PORT} \\
  --restrict-http-upgrade-path-prefix \${WSTUNNEL_SECRET} \\
  ws://127.0.0.1:${WSTUNNEL_INTERNAL_PORT}

Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=${WSTUNNEL_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

if systemctl is-active --quiet wstunnel 2>/dev/null; then
  systemctl restart wstunnel
  success "wstunnel.service riavviato"
else
  systemctl enable --now wstunnel
  success "wstunnel.service abilitato e avviato"
fi

sleep 2
if systemctl is-active --quiet wstunnel; then
  success "wstunnel.service attivo su ws://127.0.0.1:${WSTUNNEL_INTERNAL_PORT}"
else
  error "wstunnel.service non è partito. Controlla: journalctl -u wstunnel -n 30"
fi

# =============================================================================
# Firewall
# =============================================================================

section "Firewall"

# wstunnel non espone porte pubbliche — ascolta solo su loopback.
# La porta TCP:443 è gestita da Caddy (caddy-setup.sh).
info "wstunnel ascolta su 127.0.0.1:${WSTUNNEL_INTERNAL_PORT} — nessuna regola firewall necessaria"
info "La porta TCP:443 pubblica verrà gestita da Caddy (caddy-setup.sh)"

# =============================================================================
# Verifica connettività
# =============================================================================

section "Verifica connettività"

info "Test wstunnel su 127.0.0.1:${WSTUNNEL_INTERNAL_PORT}..."
if ss -tlnp | grep -q "127.0.0.1:${WSTUNNEL_INTERNAL_PORT}"; then
  success "wstunnel in ascolto su ws://127.0.0.1:${WSTUNNEL_INTERNAL_PORT}"
else
  warn "wstunnel non in ascolto — verifica: journalctl -u wstunnel -n 20"
fi

# =============================================================================
# Riepilogo finale
# =============================================================================

section "Setup completato"

echo -e "  Binario       : ${BOLD}${WSTUNNEL_BIN}${NC} (v${INSTALLED_VER})"
echo -e "  Secret file   : ${BOLD}${WSTUNNEL_SECRET_FILE}${NC}"
echo -e "  Secret env    : ${BOLD}${SECRET_ENV_FILE}${NC}"
echo -e "  Servizio      : ${BOLD}wstunnel.service${NC} (systemd, avvio automatico)"
echo -e "  Ascolto       : ${BOLD}ws://127.0.0.1:${WSTUNNEL_INTERNAL_PORT}${NC} (solo loopback)"
echo -e "  Destinazione  : ${BOLD}127.0.0.1:${WG_PORT}${NC} (WireGuard)"
echo ""
echo -e "${YELLOW}Prossimo passo obbligatorio:${NC}"
echo "  Esegui caddy-setup.sh per installare il reverse proxy front-end:"
echo "    sudo ./caddy-setup.sh"
echo ""
echo "  Caddy si occuperà di:"
echo "    - TLS termination su TCP:443"
echo "    - Routing del traffico wstunnel sul path /<secret>"
echo "    - Generazione del certificato per il certificate pinning client"
echo ""
echo -e "${GREEN}Stato servizio:${NC}"
systemctl status wstunnel --no-pager -l | head -20

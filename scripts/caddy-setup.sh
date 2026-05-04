#!/usr/bin/env bash
# =============================================================================
# caddy-setup.sh — Installa Caddy come front-end TLS e reverse proxy
#
# Uso:
#   chmod +x caddy-setup.sh
#   sudo ./caddy-setup.sh
#
# Prerequisiti:
#   - wstunnel-server-setup.sh già eseguito (genera /etc/wstunnel/secret-env)
#   - curl, openssl, apt installati
#   - Porta TCP:443 aperta nel pannello Lightsail (Networking → IPv4 Firewall)
#
# Architettura:
#   Internet → Caddy :443 (TLS termination)
#     ├── path /<secret>/*  → ws://127.0.0.1:8080  (wstunnel → WireGuard)
#     └── path /*           → http://127.0.0.1:9000 (servizi web personali)
#
# Certificato:
#   Self-signed RSA-4096 generato in /etc/caddy/tls/
#   I client wstunnel usano certificate pinning su questo file.
#   wg-add-client.sh lo legge da /etc/caddy/tls/cert.pem per includerlo
#   nel pacchetto client.
#
# Migrazione futura a Let's Encrypt:
#   Sostituire il blocco tls nel Caddyfile con il path del certificato ACME
#   e ridistribuire i pacchetti client con il nuovo cert.pem.
#
# Questo script è idempotente.
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
[[ $EUID -ne 0 ]] && error "Eseguire con sudo: sudo ./caddy-setup.sh"

umask 077

# ── Costanti configurabili ────────────────────────────────────────────────────
CADDY_TLS_DIR="/etc/caddy/tls"
CADDY_CERT="${CADDY_TLS_DIR}/cert.pem"
CADDY_KEY="${CADDY_TLS_DIR}/key.pem"
CADDYFILE="/etc/caddy/Caddyfile"

# Fonte di verità del secret — generata da wstunnel-server-setup.sh
SECRET_ENV_FILE="/etc/wstunnel/secret-env"

PUBLIC_PORT=443
WSTUNNEL_BACKEND="127.0.0.1:8080"

# Backend placeholder per servizi web personali.
# Sostituire con la porta del proprio applicativo (Homer, Filebrowser, ecc.)
WEBAPP_BACKEND="127.0.0.1:9000"

CERT_DAYS=825
SERVICE_OVERRIDE_DIR="/etc/systemd/system/caddy.service.d"

# =============================================================================
# Intestazione
# =============================================================================

clear
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    Caddy — Setup reverse proxy TLS       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# Prerequisiti
# =============================================================================

section "Verifica prerequisiti"

command -v curl    > /dev/null || error "curl non trovato."
command -v openssl > /dev/null || error "openssl non trovato."

if [[ ! -f "$SECRET_ENV_FILE" ]]; then
  error "File non trovato: ${SECRET_ENV_FILE}\n\n  Esegui prima:\n    sudo ./wstunnel-server-setup.sh"
fi

# shellcheck source=/dev/null
source "$SECRET_ENV_FILE"
[[ -z "${WSTUNNEL_SECRET:-}" ]] && \
  error "WSTUNNEL_SECRET vuoto in ${SECRET_ENV_FILE}."

success "Secret caricato: ${WSTUNNEL_SECRET:0:8}…"

if ! ss -tlnp | grep -q "${WSTUNNEL_BACKEND}"; then
  warn "wstunnel non in ascolto su ${WSTUNNEL_BACKEND}."
  warn "Assicurati che wstunnel.service sia attivo: sudo systemctl status wstunnel"
  read -rp "$(echo -e "${YELLOW}Continuare comunque? [y/N]:${NC} ")" force_continue
  [[ "${force_continue,,}" == "y" ]] || exit 0
fi

success "Prerequisiti verificati"

# =============================================================================
# Rilevamento IP pubblico
# =============================================================================

section "Rilevamento IP pubblico"

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
    echo -e "${YELLOW}[WARN]${NC}  IMDSv2 non disponibile — fallback su IMDSv1 (deprecato da AWS)." >&2
    ip=$(curl -s --max-time 3 \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)
  fi
  [[ -z "$ip" ]] && ip=$(curl -s --max-time 5 "https://api.ipify.org" 2>/dev/null || true)
  echo "$ip"
}

SERVER_IP=$(get_public_ip)
[[ -z "$SERVER_IP" ]] && error "Impossibile determinare l'IP pubblico."
success "IP pubblico: ${SERVER_IP}"

# =============================================================================
# Installazione Caddy
# =============================================================================

section "Installazione Caddy"

# Repository ufficiale Caddy — il pacchetto Ubuntu apt è obsoleto.
if command -v caddy > /dev/null 2>&1; then
  CADDY_INSTALLED_VER=$(caddy version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || true)
  info "Caddy già installato: ${CADDY_INSTALLED_VER}"
else
  info "Installazione Caddy dal repository ufficiale..."
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl \
    > /dev/null 2>&1

  curl -s "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" \
    | gpg --batch --yes --dearmor \
    -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

  curl -s "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt" \
    > /etc/apt/sources.list.d/caddy-stable.list

  apt-get update -qq
  apt-get install -y caddy

  CADDY_INSTALLED_VER=$(caddy version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || true)
  success "Caddy ${CADDY_INSTALLED_VER} installato"
fi

# =============================================================================
# Certificato TLS self-signed
# =============================================================================

section "Certificato TLS"

mkdir -p "$CADDY_TLS_DIR"
chmod 700 "$CADDY_TLS_DIR"

REGEN_CERT=false

if [[ -f "$CADDY_CERT" && -f "$CADDY_KEY" ]]; then
  # checkend 2592000 = 30 giorni in secondi
  if ! openssl x509 -in "$CADDY_CERT" -noout -checkend 2592000 > /dev/null 2>&1; then
    warn "Certificato scade entro 30 giorni — rigenero."
    REGEN_CERT=true
  else
    CERT_CN=$(openssl x509 -in "$CADDY_CERT" -noout -subject 2>/dev/null \
      | grep -oP 'CN\s*=\s*\K[^\s,/]+' || echo "sconosciuto")
    CERT_EXPIRY=$(openssl x509 -in "$CADDY_CERT" -noout -enddate 2>/dev/null \
      | cut -d= -f2 || true)
    success "Certificato valido (CN=${CERT_CN}, scade: ${CERT_EXPIRY})"

    if [[ "$CERT_CN" != "$SERVER_IP" ]]; then
      warn "CN certificato (${CERT_CN}) ≠ IP attuale (${SERVER_IP})."
      read -rp "$(echo -e "${YELLOW}Rigenerare? [y/N]:${NC} ")" regen
      [[ "${regen,,}" == "y" ]] && REGEN_CERT=true
    fi
  fi
else
  REGEN_CERT=true
fi

if [[ "$REGEN_CERT" == true ]]; then
  info "Generazione certificato self-signed RSA-4096 (CN=${SERVER_IP})..."

  # subjectAltName=IP: obbligatorio per OpenSSL 3+ e Go (wstunnel è scritto in Rust
  # ma usa rustls che verifica SAN). Senza SAN il certificate pinning fallisce
  # sui client moderni anche con --tls-ca-certificate.
  openssl req -x509 \
    -newkey ec \
    -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$CADDY_KEY" \
    -out    "$CADDY_CERT" \
    -days   "$CERT_DAYS" \
    -noenc \
    -subj   "/CN=${SERVER_IP}" \
    -addext "subjectAltName=IP:${SERVER_IP}" \
    2>/dev/null

  chmod 600 "$CADDY_KEY"
  chmod 644 "$CADDY_CERT"
  success "Certificato generato: ${CADDY_CERT}"

  CERT_EXPIRY=$(openssl x509 -in "$CADDY_CERT" -noout -enddate 2>/dev/null \
    | cut -d= -f2 || true)
  info "Scadenza: ${CERT_EXPIRY}"

  warn "⚠  Certificato rigenerato — tutti i client wstunnel con certificate pinning"
  warn "   devono ricevere il nuovo pacchetto. Riesegui wg-add-client.sh per ognuno."
fi

openssl x509 -in "$CADDY_CERT" -noout -subject -enddate 2>/dev/null | sed 's/^/  /'

# ── Permessi: caddy deve leggere cert e key ───────────────────────────────────
chown root:caddy "$CADDY_TLS_DIR" "$CADDY_CERT" "$CADDY_KEY"
chmod 750 "$CADDY_TLS_DIR"
chmod 640 "$CADDY_KEY"
chmod 644 "$CADDY_CERT"

success "Permessi TLS configurati (gruppo caddy)"

# =============================================================================
# Override systemd: EnvironmentFile per WSTUNNEL_SECRET
# =============================================================================

section "Override systemd"

# Aggiungi 'caddy' al gruppo 'wstunnel' per leggere secret-env
if id caddy > /dev/null 2>&1 && id wstunnel > /dev/null 2>&1; then
  usermod -aG wstunnel caddy
  success "Utente 'caddy' aggiunto al gruppo 'wstunnel'"
elif ! id wstunnel > /dev/null 2>&1; then
  warn "Gruppo 'wstunnel' non trovato — esegui prima wstunnel-server-setup.sh"
fi

mkdir -p "$SERVICE_OVERRIDE_DIR"

# Drop-in override — non modifica il service ufficiale (resistente agli aggiornamenti)
cat > "${SERVICE_OVERRIDE_DIR}/env.conf" << EOF
[Service]
# Inietta WSTUNNEL_SECRET nel processo Caddy per il Caddyfile ({env.WSTUNNEL_SECRET})
EnvironmentFile=${SECRET_ENV_FILE}
EOF

success "Override scritto: ${SERVICE_OVERRIDE_DIR}/env.conf"

# =============================================================================
# Caddyfile
# =============================================================================

section "Scrittura Caddyfile"

if [[ -f "$CADDYFILE" ]]; then
  BACKUP="${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$CADDYFILE" "$BACKUP"
  info "Backup: ${BACKUP}"
fi

# Nota: il Caddyfile usa single-quote heredoc ('CADDYEOF') per evitare che
# bash espanda ${ } — le variabili Caddy come {env.WSTUNNEL_SECRET} devono
# arrivare letterali al file e vengono espanse da Caddy a runtime.
cat > "$CADDYFILE" << 'CADDYEOF'
# =============================================================================
# Caddyfile — Reverse proxy TLS per wstunnel + servizi web
#
# WSTUNNEL_SECRET è iniettato da systemd via EnvironmentFile.
# Non modificare manualmente il valore del secret qui — è letto da
# /etc/wstunnel/secret-env che è la fonte di verità centralizzata.
#
# Per aggiornare il secret:
#   1. rm /etc/wstunnel/secret && sudo ./wstunnel-server-setup.sh
#   2. sudo systemctl restart wstunnel caddy
#   3. Ridistribuire i pacchetti client (wg-add-client.sh)
# =============================================================================

:443 {
    # TLS con certificato self-signed.
    # Fonte di verità per il certificate pinning dei client wstunnel.
    tls /etc/caddy/tls/cert.pem /etc/caddy/tls/key.pem {
        protocols tls1.3
    }

    # ── Routing wstunnel ─────────────────────────────────────────────────────
    # Match: path che inizia con /<secret>/
    # Il path viene passato intatto a wstunnel — wstunnel verifica internamente
    # il prefisso con --restrict-http-upgrade-path-prefix (secondo controllo).
    handle /{env.WSTUNNEL_SECRET}/* {
        reverse_proxy 127.0.0.1:8080 {
            # Disabilita il buffering della response — obbligatorio per WebSocket.
            # Senza questo Caddy accumula i dati prima di inviarli, interrompendo
            # il flusso bidirezionale del tunnel WireGuard.
            flush_interval -1

            # Propaga gli header di upgrade WebSocket al backend
            header_up Connection {http.request.header.Connection}
            header_up Upgrade {http.request.header.Upgrade}

            # Forza HTTP/1.1 verso il backend — WebSocket non è compatibile con HTTP/2
            transport http {
                versions h1
            }
        }
    }

    # ── Routing servizi web personali (fallback) ─────────────────────────────
    # Tutto ciò che non contiene il secret nel path va ai tuoi applicativi.
    # 502 Bad Gateway se :9000 non è in uso — comportamento corretto e atteso.
    handle /* {
        reverse_proxy 127.0.0.1:9000
    }
}
CADDYEOF

success "Caddyfile scritto: ${CADDYFILE}"

info "Validazione Caddyfile..."
if caddy validate --config "$CADDYFILE" > /dev/null 2>&1; then
  success "Caddyfile valido"
else
  error "Caddyfile non valido:\n$(caddy validate --config "$CADDYFILE" 2>&1)"
fi

# =============================================================================
# Firewall
# =============================================================================

section "Firewall"

if command -v ufw > /dev/null && ufw status | grep -q "Status: active"; then
  if ! ufw status | grep -q "${PUBLIC_PORT}/tcp"; then
    ufw allow "${PUBLIC_PORT}/tcp" comment "Caddy HTTPS"
    success "Regola ufw aggiunta: TCP:${PUBLIC_PORT}"
  else
    success "Regola ufw TCP:${PUBLIC_PORT} già presente"
  fi
else
  warn "ufw non attivo — gestione firewall manuale richiesta"
fi

echo ""
warn "Ricorda: apri TCP:${PUBLIC_PORT} nel pannello Lightsail se non già fatto:"
warn "  Istanza → Networking → IPv4 Firewall → Add rule → TCP ${PUBLIC_PORT}"

# =============================================================================
# Avvio Caddy
# =============================================================================

section "Avvio servizio Caddy"

systemctl daemon-reload

if systemctl is-active --quiet caddy 2>/dev/null; then
  systemctl reload caddy 2>/dev/null || systemctl restart caddy
  success "caddy.service ricaricato"
else
  systemctl enable --now caddy
  success "caddy.service abilitato e avviato"
fi

for i in {1..10}; do
  systemctl is-active --quiet caddy && break
  sleep 1
done
if systemctl is-active --quiet caddy; then
  success "caddy.service attivo"
else
  error "caddy.service non partito.\n  Controlla: journalctl -u caddy -n 30"
fi

# =============================================================================
# Verifica end-to-end
# =============================================================================

section "Verifica connettività"

# Test 1: Caddy risponde su :443
info "Test TLS locale su 127.0.0.1:${PUBLIC_PORT}..."
TLS_RESULT=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
  "https://127.0.0.1:${PUBLIC_PORT}" 2>/dev/null || true)

if [[ "$TLS_RESULT" =~ ^[0-9]+$ ]]; then
  success "Caddy risponde su :${PUBLIC_PORT} (HTTP ${TLS_RESULT})"
else
  warn "Nessuna risposta — verifica: journalctl -u caddy -n 20"
fi

# Test 2: path secret → wstunnel (atteso 400 o 101, non 404)
info "Test routing /${WSTUNNEL_SECRET:0:8}…/ → wstunnel..."
SECRET_RESULT=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
  "https://127.0.0.1:${PUBLIC_PORT}/${WSTUNNEL_SECRET}/" 2>/dev/null || true)

case "$SECRET_RESULT" in
  101|400|200) success "Routing secret → wstunnel OK (HTTP ${SECRET_RESULT})" ;;
  404)         warn    "404 ricevuto — verifica path nel Caddyfile e secret." ;;
  *)           info    "Routing secret: HTTP ${SECRET_RESULT}" ;;
esac

# Test 3: path senza secret → fallback (502 atteso se :9000 non è in uso)
info "Test routing / → webapp backend..."
FALLBACK_RESULT=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
  "https://127.0.0.1:${PUBLIC_PORT}/" 2>/dev/null || true)

case "$FALLBACK_RESULT" in
  502) success "Routing fallback OK (502 — nessun servizio su :9000, atteso)" ;;
  *)   success "Routing fallback: HTTP ${FALLBACK_RESULT}" ;;
esac

# =============================================================================
# Riepilogo
# =============================================================================

section "Setup Caddy completato"

echo -e "  Versione     : ${BOLD}$(caddy version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1)${NC}"
echo -e "  Certificato  : ${BOLD}${CADDY_CERT}${NC}"
echo -e "                 ↑ unica fonte per certificate pinning client"
echo -e "  Chiave TLS   : ${BOLD}${CADDY_KEY}${NC}"
echo -e "  Caddyfile    : ${BOLD}${CADDYFILE}${NC}"
echo -e "  Porta        : ${BOLD}TCP:${PUBLIC_PORT}${NC}"
echo ""
echo -e "  Routing:"
echo -e "    /${WSTUNNEL_SECRET:0:8}…/* → ${BOLD}ws://${WSTUNNEL_BACKEND}${NC} (wstunnel)"
echo -e "    /*            → ${BOLD}http://${WEBAPP_BACKEND}${NC} (webapp — 502 se non attivo)"
echo ""
echo -e "  ${YELLOW}wg-add-client.sh${NC} leggerà il certificato da ${BOLD}${CADDY_CERT}${NC}"
echo ""
echo -e "${GREEN}Stato servizi:${NC}"
systemctl status caddy wstunnel --no-pager -l | head -25

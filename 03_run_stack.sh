#!/bin/bash
# ===================================================================================
# L.I.S.A — 03_run_stack.sh
# Build, démarrage séquentiel, health checks adaptatifs, pull modèle Ollama
# ===================================================================================

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RESET="\033[0m"

info()    { echo -e "${BLUE}[INFO]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; }
success() { echo -e "${GREEN}[OK]${RESET} $1"; }
section() { echo -e "\n${CYAN}━━━ $1 ━━━${RESET}"; }

STACK_DIR="$HOME/ai-stack"
CONF_FILE="$STACK_DIR/lisa.conf"
STATE_FILE="$STACK_DIR/.lisa_state"
LOG_FILE="$STACK_DIR/lisa_install.log"

exec >> "$LOG_FILE" 2>&1

[ ! -f "$CONF_FILE" ] && { error "lisa.conf introuvable."; exit 1; }
source "$CONF_FILE"

CURRENT_STATE=$(cat "$STATE_FILE" 2>/dev/null)
if [ "$CURRENT_STATE" = "STACK_DONE" ]; then
    info "Stack déjà démarrée. Vérification de l'état..."
    # On retombe sur les health checks uniquement
fi

# --- Helpers ---
_get_pass() { openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$(cat "$STACK_DIR/.lisa_pass.key")" -in "$STACK_DIR/.lisa_pass.gpg" 2>/dev/null; }
_sudo() { echo "$(_get_pass)" | sudo -S "$@" 2>/dev/null; }

(while [ -f "$STACK_DIR/.lisa_pass.key" ]; do _sudo -v &>/dev/null; sleep 240; done) &
SUDO_KA_PID=$!

# Anti-veille
INHIBIT_PID=""
if command -v systemd-inhibit &>/dev/null; then
    systemd-inhibit --what=sleep:idle --who="LISA Build" \
        --why="Build Docker en cours" --mode=block sleep infinity &
    INHIBIT_PID=$!
fi

# Trap
# ===================================================================================
# TRAP — nettoyage centralisé sur échec ou interruption
# ===================================================================================
_trap_cleanup() {
    local EXIT_CODE=$?
    [ "$EXIT_CODE" -eq 0 ] && return
    echo ""
    echo -e "\033[1;31m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;31m  L.I.S.A. — Interruption détectée\033[0m"
    echo -e "\033[1;31m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    # Arrêt keepalive et inhibit
    [ -f "$STACK_DIR/.sudo_keepalive.pid" ] && kill "$(cat $STACK_DIR/.sudo_keepalive.pid)" 2>/dev/null
    kill "$INHIBIT_PID" 2>/dev/null || true
    # Lancement nettoyage centralisé
    if [ -f "$STACK_DIR/lisa_cleanup.sh" ]; then
        bash "$STACK_DIR/lisa_cleanup.sh" "échec ou interruption"
    else
        rm -f "$STACK_DIR/.lisa_pass.gpg" "$STACK_DIR/.lisa_pass.key" "$STACK_DIR/.env.plain"
        rm -rf "$STACK_DIR"
    fi
    exit 1
}
trap '_trap_cleanup' EXIT
trap 'exit 1' INT TERM

cd "$STACK_DIR" || { error "Impossible d'accéder à $STACK_DIR"; exit 1; }

# ===================================================================================
# DÉLAI ADAPTATIF selon ressources
# ===================================================================================
wait_for_resources() {
    local SERVICE="$1"
    local MAX_WAIT="${2:-120}"
    local INTERVAL=5

    info "Attente stabilisation ressources avant lancement de $SERVICE..."
    local ELAPSED=0
    while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
        # Lecture CPU usage (1s sample)
        CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | tr -d '%id,' 2>/dev/null || echo "50")
        MEM_FREE_PCT=$(free | awk '/^Mem:/{printf "%.0f", $4/$2*100}')

        if [ "${CPU_IDLE:-50}" -gt 20 ] && [ "${MEM_FREE_PCT:-50}" -gt 15 ]; then
            success "Ressources disponibles (CPU idle: ${CPU_IDLE}%, RAM libre: ${MEM_FREE_PCT}%)."
            return 0
        fi
        info "  CPU chargé ou RAM faible — attente ${INTERVAL}s... (${ELAPSED}/${MAX_WAIT}s)"
        sleep "$INTERVAL"
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    warn "Délai d'attente dépassé — lancement de $SERVICE quand même."
}

# Délai de base selon profil RAM
case "$RAM_PROFILE" in
    low)    BASE_WAIT=90  ;;
    medium) BASE_WAIT=60  ;;
    high)   BASE_WAIT=30  ;;
    *)      BASE_WAIT=60  ;;
esac

# ===================================================================================
# HEALTH CHECK avec retry
# ===================================================================================
health_check() {
    local NAME="$1"
    local URL="$2"
    local MAX_RETRIES="${3:-20}"
    local WAIT="${4:-10}"

    info "Health check $NAME (max ${MAX_RETRIES} tentatives, intervalle ${WAIT}s)..."
    for (( i=1; i<=MAX_RETRIES; i++ )); do
        if curl -sf "$URL" >/dev/null 2>&1; then
            success "$NAME opérationnel (tentative $i/$MAX_RETRIES)"
            return 0
        fi
        info "  $NAME pas encore prêt ($i/$MAX_RETRIES)..."
        sleep "$WAIT"
    done
    warn "$NAME non joignable après $((MAX_RETRIES * WAIT))s."
    return 1
}

# ===================================================================================
# BUILD
# ===================================================================================
section "Build des containers"

info "Lancement du build (peut prendre plusieurs minutes)..."
info "Whisper.cpp compile from source — soyez patient."

docker compose build \
    --build-arg PLATFORM="$PLATFORM" \
    2>&1 | tee -a "$LOG_FILE" || {
    error "Build échoué."
    exit 1
}
success "Build terminé."

# ===================================================================================
# DÉMARRAGE SÉQUENTIEL
# ===================================================================================
section "Démarrage des services"

# 1. LLM en premier — le plus gourmand
info "Démarrage du LLM (Ollama)..."
docker compose up -d llm
wait_for_resources "LLM" "$BASE_WAIT"
health_check "LLM" "http://localhost:11434/api/tags" 20 "$((BASE_WAIT / 4))"
LLM_OK=$?

# Pull du modèle
if [ "$LLM_OK" -eq 0 ] && [ -n "$LLM_MODEL_LOCAL" ]; then
    section "Téléchargement du modèle $LLM_MODEL_LOCAL"
    info "Pull du modèle Ollama : $LLM_MODEL_LOCAL (peut prendre plusieurs minutes selon la connexion)..."
    docker exec lisa_llm ollama pull "$LLM_MODEL_LOCAL" 2>&1 | tee -a "$LOG_FILE"
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
        success "Modèle $LLM_MODEL_LOCAL téléchargé."
    else
        warn "Pull du modèle échoué — à relancer manuellement : docker exec lisa_llm ollama pull $LLM_MODEL_LOCAL"
    fi
fi

# 2. STT
wait_for_resources "STT" "$BASE_WAIT"
info "Démarrage STT (Whisper)..."
docker compose up -d stt
# STT compile at startup — délai plus long
health_check "STT" "http://localhost:8080/" 24 15

# 3. TTS
wait_for_resources "TTS" 30
info "Démarrage TTS (Piper)..."
docker compose up -d tts

# 4. RAG si activé
if [ "$RAG_ENABLED" = "true" ] && [ "$RAG_PROVIDER" = "local" ]; then
    wait_for_resources "RAG" 30
    info "Démarrage RAG (Qdrant)..."
    docker compose up -d rag
    health_check "RAG" "http://localhost:6333/healthz" 10 5
fi

# 5. SearXNG si activé
if [ "$WEB_SEARCH_ENABLED" = "true" ]; then
    info "Démarrage SearXNG..."
    docker compose up -d search
fi

# 6. API en dernier (dépend de LLM via healthcheck compose)
wait_for_resources "API" 30
info "Démarrage API orchestrateur..."
docker compose up -d api
health_check "API" "http://localhost:8001/status" 15 8
API_OK=$?

# ===================================================================================
# RÉSEAU (Caddy + DuckDNS si exposition internet)
# ===================================================================================
if [ "$EXPOSE_INTERNET" = "true" ]; then
    section "Configuration réseau"
    bash "$STACK_DIR/04_network.sh"
fi

# ===================================================================================
# RÉCAP FINAL
# ===================================================================================
section "État de la stack L.I.S.A."

echo ""
echo -e "${CYAN}┌─────────────────────────────────────────────────┐${RESET}"
echo -e "${CYAN}│         L.I.S.A. — Stack opérationnelle         │${RESET}"
echo -e "${CYAN}├─────────────────────────────────────────────────┤${RESET}"

docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null | tail -n +2 | while read LINE; do
    NAME=$(echo "$LINE" | awk '{print $1}')
    STATUS=$(echo "$LINE" | awk '{print $2}')
    if echo "$STATUS" | grep -q "Up\|running"; then
        echo -e "${CYAN}│${RESET}  ${GREEN}●${RESET} $LINE"
    else
        echo -e "${CYAN}│${RESET}  ${RED}●${RESET} $LINE"
    fi
done

echo -e "${CYAN}├─────────────────────────────────────────────────┤${RESET}"
echo -e "${CYAN}│${RESET}  API locale   : ${BLUE}http://localhost:8001${RESET}"
echo -e "${CYAN}│${RESET}  Docs API     : ${BLUE}http://localhost:8001/docs${RESET}"
echo -e "${CYAN}│${RESET}  Status HUD   : ${BLUE}http://localhost:8001/status${RESET}"

if [ "$EXPOSE_INTERNET" = "true" ] && [ -n "$DOMAIN" ]; then
    if [ "$DOMAIN_TYPE" = "duckdns" ]; then
        echo -e "${CYAN}│${RESET}  API externe  : ${BLUE}https://lisa-api-${DUCKDNS_SUFFIX}.duckdns.org${RESET}"
    else
        echo -e "${CYAN}│${RESET}  API externe  : ${BLUE}https://api.${DOMAIN}${RESET}"
    fi
fi

echo -e "${CYAN}│${RESET}  Modèle LLM   : ${GREEN}$LLM_MODEL_LOCAL${RESET}"
echo -e "${CYAN}│${RESET}  Web search   : $([ "$WEB_SEARCH_DEFAULT" = "true" ] && echo "${GREEN}activée${RESET}" || echo "${YELLOW}désactivée${RESET}")"
echo -e "${CYAN}│${RESET}  Config       : $CONF_FILE"
echo -e "${CYAN}│${RESET}  Logs         : $LOG_FILE"
echo -e "${CYAN}└─────────────────────────────────────────────────┘${RESET}"
echo ""

# ===================================================================================
# NETTOYAGE FINAL DES SECRETS ÉPHÉMÈRES
# ===================================================================================
section "Nettoyage des secrets éphémères"

rm -f "$STACK_DIR/.lisa_pass.gpg" "$STACK_DIR/.lisa_pass.key" "$STACK_DIR/.env.plain"
kill "$SUDO_KA_PID" 2>/dev/null
kill "$INHIBIT_PID" 2>/dev/null

success "Secrets éphémères supprimés."
success "Mise en veille débloquée."

echo "STACK_DONE" > "$STATE_FILE"
success "Installation L.I.S.A. terminée."

#!/bin/bash
# ===================================================================================
# L.I.S.A — 01_config.sh
# Affichage profil machine + questions utilisateur — full terminal
# ===================================================================================

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
MAGENTA="\033[1;35m"
RESET="\033[0m"

info()    { echo -e "${BLUE}[INFO]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; }
section() {
    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}  $1${RESET}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

STACK_DIR="$HOME/ai-stack"
CONF_FILE="$STACK_DIR/lisa.conf"
STATE_FILE="$STACK_DIR/.lisa_state"
PASS_ENC="$STACK_DIR/.lisa_pass.gpg"
PASS_KEY="$STACK_DIR/.lisa_pass.key"
LOG_FILE="$STACK_DIR/lisa_install.log"

[ ! -f "$CONF_FILE" ] && { error "lisa.conf introuvable." ; exit 1; }
source "$CONF_FILE"

# ===================================================================================
# TRAP
# ===================================================================================
SUDO_KEEPALIVE_PID=""
_trap_cleanup() {
    local EXIT_CODE=$?
    [ "$EXIT_CODE" -eq 0 ] && return
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    [ -f "$STACK_DIR/lisa_cleanup.sh" ] && \
        bash "$STACK_DIR/lisa_cleanup.sh" "interruption 01_config" || \
        rm -rf "$STACK_DIR"
    exit 1
}
trap '_trap_cleanup' EXIT
trap 'exit 1' INT TERM

# ===================================================================================
# HELPERS TERMINAL
# ===================================================================================
_get_pass() {
    openssl enc -d -aes-256-cbc -pbkdf2 \
        -pass pass:"$(cat "$PASS_KEY")" -in "$PASS_ENC" 2>/dev/null
}

_yesno() {
    # $1 = titre, $2 = question
    echo ""
    echo -e "${CYAN}  $1${RESET}"
    echo ""
    # Afficher chaque ligne de la question
    while IFS= read -r LINE; do
        echo -e "  $LINE"
    done <<< "$2"
    echo ""
    echo -ne "${YELLOW}  [?]${RESET} Votre choix [O/n] : "
    read -r R
    echo ""
    [[ ! "$R" =~ ^[Nn]$ ]] && return 0 || return 1
}

_password() {
    # $1=titre $2=label $3=varname
    echo -ne "${YELLOW}  [?]${RESET} $2 : "
    read -r -s REPLY_PASS
    echo ""
    printf -v "$3" '%s' "$REPLY_PASS"
    unset REPLY_PASS
}

_input() {
    # $1=titre $2=label $3=varname
    echo -ne "${YELLOW}  [?]${RESET} $2 : "
    read -r REPLY_INPUT
    printf -v "$3" '%s' "$REPLY_INPUT"
    unset REPLY_INPUT
}

# Keepalive sudo en arrière-plan
(while [ -f "$PASS_KEY" ]; do
    echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1
    sleep 240
done) </dev/null &
SUDO_KEEPALIVE_PID=$!

# ===================================================================================
# AFFICHAGE PROFIL MACHINE
# ===================================================================================
section "Votre machine"

case "$RAM_PROFILE" in
    low)    PROFIL_LABEL="Léger" ;;
    medium) PROFIL_LABEL="Standard" ;;
    high)   PROFIL_LABEL="Élevé" ;;
esac

echo -e "  Profil détecté : ${GREEN}$PROFIL_LABEL${RESET}"
echo ""
echo -e "    ${BLUE}•${RESET} CPU  : $CPU_CORES cœurs"
echo -e "    ${BLUE}•${RESET} RAM  : $RAM_GB GB"
echo -e "    ${BLUE}•${RESET} GPU  : $GPU_LABEL"
echo ""
echo -e "  ${CYAN}L.I.S.A. sera configurée automatiquement${RESET}"
echo -e "  ${CYAN}avec les modèles adaptés à votre machine.${RESET}"
echo -e "  ${YELLOW}Aucun remplacement de modèle possible ou conseillé.${RESET}"
echo ""
echo -ne "  Appuyez sur Entrée pour continuer..." ; read -r
echo ""

# ===================================================================================
# CLÉS API EXTERNES
# ===================================================================================
LLM_API_KEY="" ; LLM_PROVIDER="local" ; LLM_MODE="1"
STT_API_KEY="" ; STT_PROVIDER="local" ; STT_MODE="1"
TTS_API_KEY="" ; TTS_PROVIDER="local" ; TTS_MODE="1"
declare -A EXTRA_KEYS

if _yesno "Services en ligne" \
"Avez-vous des comptes chez des services d'IA en ligne ?
(OpenAI, Anthropic, Mistral, ElevenLabs...)

Si oui, L.I.S.A. pourra les utiliser en complément
pour des réponses de meilleure qualité ou une voix
plus naturelle. Vous pourrez en ajouter via le HUD."; then

    if _yesno "Cerveau IA — service en ligne" \
"Connecter un service en ligne pour le cerveau de L.I.S.A. ?
(OpenAI, Anthropic, Mistral, Groq...)
L.I.S.A. utilisera d'abord votre machine, ce service en secours."; then
        LLM_MODE="3"
        LLM_PROVIDER=$(bash "$STACK_DIR/00_provider_select.sh" "llm")
        _password "Clé API LLM" "Collez votre clé API $LLM_PROVIDER" LLM_API_KEY
    fi

    if _yesno "Voix — service en ligne" \
"Utiliser un service en ligne pour la voix de L.I.S.A. ?
(ElevenLabs, OpenAI TTS...)
Par défaut : voix locale, gratuite et privée."; then
        TTS_MODE="2"
        TTS_PROVIDER=$(bash "$STACK_DIR/00_provider_select.sh" "tts")
        _password "Clé API TTS" "Collez votre clé API $TTS_PROVIDER" TTS_API_KEY
    fi

    if _yesno "Reconnaissance vocale — service en ligne" \
"Utiliser un service en ligne pour reconnaître votre voix ?
(OpenAI Whisper API, Deepgram...)
Par défaut : reconnaissance locale, votre voix reste chez vous."; then
        STT_MODE="2"
        STT_PROVIDER=$(bash "$STACK_DIR/00_provider_select.sh" "stt")
        _password "Clé API STT" "Collez votre clé API $STT_PROVIDER" STT_API_KEY
    fi

    if _yesno "Widgets HUD — services supplémentaires" \
"Configurer des clés API pour les widgets du HUD ?
(Météo, Domotique, Notifications, Calendrier...)
Vous pourrez en ajouter d'autres via le HUD."; then
        for CAT in meteo domotique notifications calendrier; do
            case "$CAT" in
                meteo)         CAT_LABEL="Météo" ;;
                domotique)     CAT_LABEL="Domotique (Home Assistant, Jeedom...)" ;;
                notifications) CAT_LABEL="Notifications (Telegram, Discord...)" ;;
                calendrier)    CAT_LABEL="Calendrier (Google, Microsoft...)" ;;
            esac
            if _yesno "Widget — $CAT_LABEL" "Avez-vous une clé API pour : $CAT_LABEL ?"; then
                PROV=$(bash "$STACK_DIR/00_provider_select.sh" "$CAT")
                KEY_VAR=""
                _password "Clé API $CAT_LABEL" "Collez votre clé API $PROV" KEY_VAR
                EXTRA_KEYS["${CAT}__${PROV}"]="$KEY_VAR"
                unset KEY_VAR
            fi
        done
    fi
fi

# ===================================================================================
# RECHERCHE WEB
# ===================================================================================
WEB_SEARCH_ENABLED="true"
WEB_SEARCH_DEFAULT="false"

if _yesno "Recherche web" \
"Activer la recherche web par défaut au démarrage ?

L.I.S.A. pourra chercher sur internet pour compléter ses réponses.
La recherche est toujours installée — vous choisissez
si elle est active par défaut.
Modifiable à tout moment via le HUD."; then
    WEB_SEARCH_DEFAULT="true"
fi

# ===================================================================================
# MÉMOIRE DOCUMENTAIRE — selon profil RAM
# ===================================================================================
RAG_PROVIDER="local"
RAG_API_KEY=""

case "$RAM_PROFILE" in
    low)
        RAG_ENABLED="false"
        RAG_DEFAULT="false"
        echo ""
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "  ${YELLOW}  Mémoire documentaire — non activée${RESET}"
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo ""
        echo -e "  Votre machine (profil léger) n'a pas assez de ressources"
        echo -e "  pour la mémoire documentaire de façon confortable."
        echo -e "  Elle permet à L.I.S.A. de lire et retenir des documents."
        echo -e "  ${CYAN}Vous pourrez l'activer via le HUD si vous le souhaitez.${RESET}"
        echo ""
        ;;
    medium|high)
        RAG_ENABLED="true"
        RAG_DEFAULT="true"
        ;;
esac

# ===================================================================================
# ÉCRITURE DANS lisa.conf
# ===================================================================================
cat >> "$CONF_FILE" << EOF

# Choix utilisateur
LLM_MODE="$LLM_MODE"
LLM_PROVIDER="$LLM_PROVIDER"
STT_MODE="$STT_MODE"
STT_PROVIDER="$STT_PROVIDER"
TTS_MODE="$TTS_MODE"
TTS_PROVIDER="$TTS_PROVIDER"
RAG_ENABLED="$RAG_ENABLED"
RAG_PROVIDER="$RAG_PROVIDER"
RAG_DEFAULT="$RAG_DEFAULT"
WEB_SEARCH_ENABLED="$WEB_SEARCH_ENABLED"
WEB_SEARCH_DEFAULT="$WEB_SEARCH_DEFAULT"
EOF

# Écriture .env.plain (chiffré par 02_config.sh)
{
    echo "LLM_API_KEY=$LLM_API_KEY"
    echo "STT_API_KEY=$STT_API_KEY"
    echo "TTS_API_KEY=$TTS_API_KEY"
    echo "RAG_API_KEY=$RAG_API_KEY"
    for KEY in "${!EXTRA_KEYS[@]}"; do
        SAFE=$(echo "$KEY" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')
        echo "${SAFE}=${EXTRA_KEYS[$KEY]}"
    done
} > "$STACK_DIR/.env.plain"
chmod 600 "$STACK_DIR/.env.plain"

echo "CHOICES_DONE" > "$STATE_FILE"
kill "$SUDO_KEEPALIVE_PID" 2>/dev/null

exec bash "$STACK_DIR/02_config.sh"

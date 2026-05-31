#!/bin/bash
# ===================================================================================
# L.I.S.A — 01_config.sh
# Affichage profil machine + 4 questions utilisateur
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
success() { echo -e "${GREEN}[OK]${RESET} $1"; }
section() {
    echo -e "\n${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}  $1${RESET}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

STACK_DIR="$HOME/ai-stack"
CONF_FILE="$STACK_DIR/lisa.conf"
STATE_FILE="$STACK_DIR/.lisa_state"
PASS_ENC="$STACK_DIR/.lisa_pass.gpg"
PASS_KEY="$STACK_DIR/.lisa_pass.key"
LOG_FILE="$STACK_DIR/lisa_install.log"

exec >> "$LOG_FILE" 2>&1

[ ! -f "$CONF_FILE" ] && { error "lisa.conf introuvable. Lancez d'abord 00_config.sh"; exit 1; }
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
        bash "$STACK_DIR/lisa_cleanup.sh" "interruption configuration" || \
        rm -rf "$STACK_DIR"
    exit 1
}
trap '_trap_cleanup' EXIT
trap 'exit 1' INT TERM

# ===================================================================================
# DÉTECTION WHIPTAIL
# ===================================================================================
USE_WHIPTAIL=false
command -v whiptail &>/dev/null && [ -t 1 ] && USE_WHIPTAIL=true

_msg() {
    $USE_WHIPTAIL && whiptail --title "$1" --msgbox "$2" 14 65 || {
        section "$1" ; echo -e "$2" ; echo ""
    }
}
_yesno() {
    if $USE_WHIPTAIL; then
        whiptail --title "$1" --yesno "$2" 12 65 ; return $?
    else
        echo -ne "${YELLOW}[?]${RESET} $2 [O/n] : " ; read -r R
        [[ ! "$R" =~ ^[Nn]$ ]] && return 0 || return 1
    fi
}
_input() {
    # _input "Titre" "Message" VARNAME
    if $USE_WHIPTAIL; then
        local VAL
        VAL=$(whiptail --title "$1" --inputbox "$2" 10 65 3>&1 1>&2 2>&3)
        eval "$3=\"$VAL\""
    else
        echo -ne "${YELLOW}[?]${RESET} $2 : " ; read -r R
        eval "$3=\"$R\""
    fi
}
_password() {
    if $USE_WHIPTAIL; then
        local VAL
        VAL=$(whiptail --title "$1" --passwordbox "$2" 10 65 3>&1 1>&2 2>&3)
        eval "$3=\"$VAL\""
    else
        echo -ne "${YELLOW}[?]${RESET} $2 : " ; read -r -s R ; echo ""
        eval "$3=\"$R\""
    fi
}
_menu() {
    # _menu "Titre" "Message" VARNAME item1 desc1 item2 desc2 ...
    local TITLE="$1" MSG="$2" VARNAME="$3"
    shift 3
    if $USE_WHIPTAIL; then
        local ITEMS=("$@")
        local CHOICE
        CHOICE=$(whiptail --title "$TITLE" --menu "$MSG" 18 65 6 "${ITEMS[@]}" 3>&1 1>&2 2>&3)
        eval "$VARNAME=\"$CHOICE\""
    else
        echo -e "${CYAN}$MSG${RESET}"
        local i=1
        while [ $# -gt 0 ]; do
            echo -e "  ${GREEN}[$1]${RESET} $2"
            shift 2
        done
        echo -ne "${YELLOW}[?]${RESET} Votre choix : " ; read -r R
        eval "$VARNAME=\"$R\""
    fi
}

# Keepalive sudo
_get_pass() {
    openssl enc -d -aes-256-cbc -pbkdf2 \
        -pass pass:"$(cat "$PASS_KEY")" -in "$PASS_ENC" 2>/dev/null
}
(while [ -f "$PASS_KEY" ]; do
    echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1
    sleep 240
done) </dev/null &
SUDO_KEEPALIVE_PID=$!

# ===================================================================================
# AFFICHAGE PROFIL MACHINE
# ===================================================================================
case "$RAM_PROFILE" in
    low)    PROFIL_LABEL="Léger" ;;
    medium) PROFIL_LABEL="Standard" ;;
    high)   PROFIL_LABEL="Élevé" ;;
esac

PROFIL_MSG="Profil détecté : $PROFIL_LABEL

  CPU  : $CPU_CORES cœurs
  RAM  : $RAM_GB GB
  GPU  : $GPU_LABEL

L.I.S.A. sera configurée automatiquement
avec les modèles adaptés à votre machine.
Aucun remplacement de modèle possible
ou conseillé."

_msg "Votre machine" "$PROFIL_MSG"

# ===================================================================================
# QUESTION 1 — CLÉS API EXTERNES
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
plus naturelle.

Vous pouvez aussi en ajouter plus tard via le HUD."; then

    # LLM externe
    if _yesno "Cerveau IA — service en ligne" \
"Voulez-vous connecter un service en ligne
pour le cerveau de L.I.S.A. ?

Exemples : OpenAI (ChatGPT), Anthropic (Claude),
Mistral, Groq...

L.I.S.A. utilisera d'abord votre machine,
et ce service en secours si besoin."; then
        LLM_MODE="3"
        LLM_PROVIDER=$(bash "$STACK_DIR/00_provider_select.sh" "llm")
        _password "Clé API — $LLM_PROVIDER" \
            "Collez votre clé API $LLM_PROVIDER" LLM_API_KEY
    fi

    # TTS externe
    if _yesno "Voix — service en ligne" \
"Voulez-vous utiliser un service en ligne
pour la voix de L.I.S.A. ?

Exemples : ElevenLabs, OpenAI TTS...
Les voix en ligne sont souvent plus naturelles.

Par défaut L.I.S.A. parle via votre machine
(gratuit, privé)."; then
        TTS_MODE="2"
        TTS_PROVIDER=$(bash "$STACK_DIR/00_provider_select.sh" "tts")
        _password "Clé API — $TTS_PROVIDER" \
            "Collez votre clé API $TTS_PROVIDER" TTS_API_KEY
    fi

    # STT externe
    if _yesno "Reconnaissance vocale — service en ligne" \
"Voulez-vous utiliser un service en ligne
pour reconnaître votre voix ?

Exemples : OpenAI Whisper API, Deepgram...

Par défaut L.I.S.A. utilise votre machine
(gratuit, votre voix ne quitte pas votre réseau)."; then
        STT_MODE="2"
        STT_PROVIDER=$(bash "$STACK_DIR/00_provider_select.sh" "stt")
        _password "Clé API — $STT_PROVIDER" \
            "Collez votre clé API $STT_PROVIDER" STT_API_KEY
    fi

    # Clés widgets HUD
    if _yesno "Widgets — services supplémentaires" \
"Voulez-vous configurer des clés API pour
les widgets du HUD L.I.S.A. ?

Exemples :
  • Météo (OpenWeatherMap, Météo France)
  • Domotique (Home Assistant, Jeedom)
  • Notifications (Telegram, Discord)
  • Calendrier (Google, Microsoft)

Vous pourrez en ajouter d'autres via le HUD."; then

        for CAT in meteo domotique notifications calendrier; do
            case "$CAT" in
                meteo)         CAT_LABEL="Météo" ;;
                domotique)     CAT_LABEL="Domotique (Home Assistant, Jeedom...)" ;;
                notifications) CAT_LABEL="Notifications (Telegram, Discord...)" ;;
                calendrier)    CAT_LABEL="Calendrier (Google, Microsoft...)" ;;
            esac
            if _yesno "Widget — $CAT_LABEL" \
"Avez-vous une clé API pour : $CAT_LABEL ?"; then
                PROV=$(bash "$STACK_DIR/00_provider_select.sh" "$CAT")
                KEY_VAR=""
                _password "Clé API — $PROV" "Collez votre clé API $PROV" KEY_VAR
                EXTRA_KEYS["${CAT}__${PROV}"]="$KEY_VAR"
            fi
        done
    fi
fi

# ===================================================================================
# QUESTION 2 — RECHERCHE WEB PAR DÉFAUT
# ===================================================================================
WEB_SEARCH_ENABLED="true"
WEB_SEARCH_DEFAULT="false"

if _yesno "Recherche web" \
"Autoriser L.I.S.A. à chercher sur internet
pour compléter ses réponses ?

La recherche web est toujours installée.
Vous pouvez choisir si elle est active
par défaut au démarrage.

Vous pourrez l'activer ou la désactiver
à tout moment via le bouton dédié du HUD."; then
    WEB_SEARCH_DEFAULT="true"
fi


# ===================================================================================
# MÉMOIRE DOCUMENTAIRE — automatique selon profil
# ===================================================================================
RAG_PROVIDER="local"
RAG_API_KEY=""

case "$RAM_PROFILE" in
    low)
        RAG_ENABLED="false"
        RAG_DEFAULT="false"
        _msg "Mémoire documentaire" \
"La mémoire documentaire n'est pas activée
sur votre machine (profil léger).

Elle permet à L.I.S.A. de lire des documents
(PDF, textes) et de s'en souvenir.

Elle nécessite plus de ressources que votre
machine n'en dispose confortablement.

Vous pourrez l'activer via le HUD si vous
le souhaitez, au risque de ralentir L.I.S.A."
        ;;
    medium|high)
        RAG_ENABLED="true"
        RAG_DEFAULT="true"
        ;;
esac


# ===================================================================================
# ÉCRITURE DES CHOIX DANS lisa.conf
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

# Écriture .env.plain (secrets — sera chiffré par 02_config.sh)
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

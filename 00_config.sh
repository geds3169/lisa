#!/bin/bash
# ===================================================================================
# L.I.S.A — Local Intelligent System Assistant
# 00_config.sh — Détection système, sudo, chiffrement AES-256, bootstrap terminal
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

mkdir -p "$STACK_DIR"

# ===================================================================================
# TRAP
# ===================================================================================
SUDO_KEEPALIVE_PID=""

_trap_cleanup() {
    local EXIT_CODE=$?
    [ "$EXIT_CODE" -eq 0 ] && return
    echo ""
    echo -e "\033[1;31m  L.I.S.A. — Interruption détectée — nettoyage...\033[0m"
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    if [ -f "$STACK_DIR/lisa_cleanup.sh" ]; then
        bash "$STACK_DIR/lisa_cleanup.sh" "interruption"
    else
        rm -f "$PASS_ENC" "$PASS_KEY" "$STACK_DIR/.env.plain" "$STACK_DIR/.env.key"
        rm -rf "$STACK_DIR"
    fi
    exit 1
}
trap '_trap_cleanup' EXIT
trap 'exit 1' INT TERM

# ===================================================================================
# MODE RECONFIGURE
# ===================================================================================
if [[ "$1" == "--reconfigure" ]]; then
    warn "Reconfiguration — la configuration existante sera remplacée."
    echo -ne "${YELLOW}[?]${RESET} Confirmer ? [o/N] : " ; read -r RECONF
    [[ ! "$RECONF" =~ ^[Oo]$ ]] && { info "Annulé." ; exit 0; }
    rm -f "$CONF_FILE" "$STACK_DIR/.env.gpg" "$STACK_DIR/.env.plain" "$STACK_DIR/.env.key"
    sed -i '/LISA_AUTO_RESUME\|LISA_SUDO_RESUME/,/^fi$/d' "$HOME/.bashrc" 2>/dev/null
fi

# ===================================================================================
# HELPERS
# ===================================================================================
_msg() {
    echo ""
    echo -e "${CYAN}  ┌─────────────────────────────────────────────────┐${RESET}"
    printf "${CYAN}  │  %-47s│${RESET}\n" "$1"
    echo -e "${CYAN}  ├─────────────────────────────────────────────────┤${RESET}"
    while IFS= read -r LINE; do
        printf "${CYAN}  │${RESET}  %-47s${CYAN}│${RESET}\n" "$LINE"
    done <<< "$2"
    echo -e "${CYAN}  └─────────────────────────────────────────────────┘${RESET}"
    echo ""
    echo -ne "  Appuyez sur Entrée pour continuer..." ; read -r
    echo ""
}

_yesno() {
    echo ""
    echo -e "${CYAN}  $1${RESET}"
    echo -e "  $2"
    echo ""
    echo -ne "${YELLOW}  [?]${RESET} Votre choix [O/n] : " ; read -r R
    echo ""
    [[ ! "$R" =~ ^[Nn]$ ]] && return 0 || return 1
}

_password() {
    echo -ne "${YELLOW}  [?]${RESET} $2 : "
    read -r -s REPLY_PASS
    echo ""
    eval "$3=\$REPLY_PASS"
    unset REPLY_PASS
}

_input() {
    echo -ne "${YELLOW}  [?]${RESET} $2 : "
    read -r REPLY_INPUT
    eval "$3=\$REPLY_INPUT"
    unset REPLY_INPUT
}

_bar() {
    local PCT=$1
    local FILLED=$(( PCT * 30 / 100 ))
    local EMPTY=$(( 30 - FILLED ))
    local B=""
    for ((i=0; i<FILLED; i++)); do B+="#"; done
    for ((i=0; i<EMPTY; i++)); do B+="-"; done
    printf "[%s]" "$B"
}

_run() {
    local LABEL="$1"
    local TOTAL="${2:-1}"
    local STEP="${3:-1}"
    local PCT=$(( STEP * 100 / TOTAL ))
    local BAR
    BAR=$(_bar "$PCT")
    printf "  [ >> ]  %-40s  %3d%%  %s\n" "$LABEL" "$PCT" "$BAR"
    local PASS
    PASS=$(_get_pass)
    echo "$PASS" | sudo -S "${@:4}" >> "$LOG_FILE" 2>&1
    local RC=$?
    unset PASS
    if [ $RC -eq 0 ]; then
        printf "  [ OK ]  %-40s  %3d%%  %s\n\n" "$LABEL" "$PCT" "$BAR"
    else
        printf "  [FAIL]  %-40s  %3d%%  %s\n\n" "$LABEL" "$PCT" "$BAR"
        error "Echec : $LABEL"
        error "Détails : $LOG_FILE"
        exit 1
    fi
}

# ===================================================================================
# DÉTECTION ARCHITECTURE
# ===================================================================================
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)        PLATFORM="linux/amd64" ; ARCH_LABEL="x86_64 (AMD64)" ;;
    aarch64|arm64) PLATFORM="linux/arm64" ; ARCH_LABEL="ARM64" ;;
    *)
        error "Architecture $ARCH non supportée. x86_64 et ARM64 uniquement."
        exit 1 ;;
esac

[[ "$(uname -s)" != "Linux" ]] && { error "L.I.S.A. requiert Linux." ; exit 1; }

OS_NAME="Inconnue"
[ -f /etc/os-release ] && . /etc/os-release && OS_NAME="$PRETTY_NAME"

# Vérification openssl
if ! command -v openssl &>/dev/null; then
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${RED}  Outil manquant : openssl${RESET}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  openssl est nécessaire pour protéger vos données."
    echo -e "  Installez-le avec cette commande :"
    echo ""
    echo -e "  ${GREEN}sudo apt-get update && sudo apt-get install -y openssl${RESET}"
    echo ""
    echo -e "  Puis relancez : ${GREEN}bash install.sh${RESET}"
    echo ""
    exit 1
fi

# ===================================================================================
# DÉTECTION RESSOURCES
# ===================================================================================
CPU_CORES=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$((RAM_KB / 1024 / 1024))
DISK_FREE=$(df -BG "$HOME" | awk 'NR==2{print $4}' | tr -d 'G')

if [ "$RAM_GB" -lt 4 ]; then
    error "RAM insuffisante : ${RAM_GB}GB. Minimum requis : 4GB." ; exit 1
fi

if   [ "$RAM_GB" -lt 8  ]; then RAM_PROFILE="low"    ; LLM_MODEL_LOCAL="phi3"
elif [ "$RAM_GB" -lt 16 ]; then RAM_PROFILE="medium"  ; LLM_MODEL_LOCAL="llama3.2"
else                             RAM_PROFILE="high"    ; LLM_MODEL_LOCAL="llama3.1:8b"
fi

GPU_TYPE="none" ; GPU_LABEL="Aucun — mode CPU"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    GPU_LABEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    GPU_TYPE="nvidia"
elif lspci 2>/dev/null | grep -qi "amd\|radeon"; then
    GPU_LABEL="AMD GPU (CPU fallback)" ; GPU_TYPE="amd"
fi

[ "$DISK_FREE" -lt 20 ] && warn "Espace disque faible (${DISK_FREE}GB). Minimum recommandé : 20GB."

# ===================================================================================
# MOT DE PASSE SYSTÈME
# ===================================================================================
section "Authentification"

echo -e "  L.I.S.A. a besoin de votre mot de passe pour :"
echo -e "    ${BLUE}•${RESET} Installer Docker et les outils système"
echo -e "    ${BLUE}•${RESET} Configurer le pare-feu"
echo -e "    ${BLUE}•${RESET} Vous ajouter au groupe Docker"
echo ""
echo -e "  ${YELLOW}Votre mot de passe est chiffré localement et supprimé${RESET}"
echo -e "  ${YELLOW}automatiquement à la fin de l'installation.${RESET}"
echo ""

EPHEMERAL_KEY=$(openssl rand -hex 32)
echo "$EPHEMERAL_KEY" > "$PASS_KEY"
chmod 600 "$PASS_KEY"

_get_pass() {
    openssl enc -d -aes-256-cbc -pbkdf2 \
        -pass pass:"$(cat "$PASS_KEY")" -in "$PASS_ENC" 2>/dev/null
}

while true; do
    _password "Authentification" "Votre mot de passe de session Linux" SYS_PASS
    echo "$SYS_PASS" | openssl enc -aes-256-cbc -pbkdf2 \
        -pass pass:"$EPHEMERAL_KEY" -out "$PASS_ENC" 2>/dev/null
    chmod 600 "$PASS_ENC"
    unset SYS_PASS
    if echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1; then
        echo -e "  ${GREEN}[ OK ]${RESET}  Authentification validée\n"
        break
    else
        echo -e "  ${RED}  Mot de passe incorrect, réessayez.${RESET}\n"
        rm -f "$PASS_ENC"
    fi
done

# ===================================================================================
# DÉPENDANCES BOOTSTRAP
# ===================================================================================
section "Préparation de L.I.S.A."

PKGS_ALL=(tmux jq curl)
PKGS_LABELS=(
    "tmux — gestionnaire de sessions terminal"
    "jq   — traitement JSON"
    "curl — téléchargements"
)

echo -e "  Vérification des outils nécessaires :\n"
PKGS_TO_INSTALL=()
for i in "${!PKGS_ALL[@]}"; do
    PKG="${PKGS_ALL[$i]}"
    LABEL="${PKGS_LABELS[$i]}"
    if command -v "$PKG" &>/dev/null; then
        printf "    ${GREEN}[ OK ]${RESET}  %-44s ${GREEN}déjà présent${RESET}\n\n" "$LABEL"
    else
        printf "    ${YELLOW}[----]${RESET}  %-44s ${YELLOW}à installer${RESET}\n\n" "$LABEL"
        PKGS_TO_INSTALL+=("$PKG")
    fi
done

echo -e "  ${MAGENTA}────────────────────────────────────────────────────${RESET}\n"

TOTAL_STEPS=$(( ${#PKGS_TO_INSTALL[@]} + 2 ))
STEP=0

STEP=$((STEP + 1))
_run "Nettoyage du cache APT" "$TOTAL_STEPS" "$STEP" \
    apt-get clean -qq

STEP=$((STEP + 1))
_run "Mise à jour des sources de paquets" "$TOTAL_STEPS" "$STEP" \
    apt-get update -qq

for PKG in "${PKGS_TO_INSTALL[@]}"; do
    STEP=$((STEP + 1))
    _run "Installation de $PKG" "$TOTAL_STEPS" "$STEP" \
        apt-get install -y "$PKG" -qq
done

# ===================================================================================
# VÉRIFICATION ET AJOUT SUDOERS
# ===================================================================================
if ! echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1; then
    _msg "Droits administrateur requis" \
"Votre compte ($USER) n'a pas les droits admin.
L.I.S.A. va tenter de vous ajouter.
Le mot de passe root est nécessaire."

    _password "Compte root" "Mot de passe root" ROOT_PASS

    if echo "$ROOT_PASS" | su -c "usermod -aG sudo $USER && echo OK" root 2>/dev/null | grep -q "OK"; then
        unset ROOT_PASS
        echo "SUDO_ADDED" > "$STATE_FILE"

        if ! grep -q "LISA_SUDO_RESUME" "$HOME/.bashrc" 2>/dev/null; then
            cat >> "$HOME/.bashrc" << 'BASHRC'

# LISA_SUDO_RESUME
if [ -f "$HOME/ai-stack/.lisa_state" ]; then
    _LS=$(cat "$HOME/ai-stack/.lisa_state")
    if [ "$_LS" = "SUDO_ADDED" ]; then
        echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo -e "\033[1;36m  L.I.S.A. — Reprise de l'installation\033[0m"
        echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        sed -i '/LISA_SUDO_RESUME/,/^fi$/d' "$HOME/.bashrc"
        bash "$HOME/ai-stack/00_config.sh"
    fi
fi
BASHRC
        fi

        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${GREEN}  ✓ Compte ajouté aux administrateurs.${RESET}"
        echo -e "${YELLOW}  → Reconnectez-vous avec : ${GREEN}$USER${RESET}"
        echo -e "${YELLOW}  → L'installation reprendra automatiquement.${RESET}"
        echo -e "${RED}  La session se ferme dans 10 secondes...${RESET}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        sleep 10
        rm -f "$PASS_ENC" "$PASS_KEY"
        kill -HUP "$PPID" 2>/dev/null || logout 2>/dev/null || exit 0
    else
        unset ROOT_PASS
        rm -f "$PASS_ENC" "$PASS_KEY"
        _msg "Erreur" \
"Impossible d'ajouter $USER aux admins.
Demandez à votre admin d'exécuter :
  sudo usermod -aG sudo $USER
Puis relancez L.I.S.A."
        exit 1
    fi
fi

# Keepalive sudo
(while [ -f "$PASS_KEY" ]; do
    echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1
    sleep 240
done) </dev/null &
SUDO_KEEPALIVE_PID=$!
echo "$SUDO_KEEPALIVE_PID" > "$STACK_DIR/.sudo_keepalive.pid"

# ===================================================================================
# CLÉ DE CHIFFREMENT OPENSSL
# ===================================================================================
ENV_KEY_FILE="$STACK_DIR/.env.key"
if [ ! -f "$ENV_KEY_FILE" ]; then
    openssl rand -hex 32 > "$ENV_KEY_FILE"
    chmod 600 "$ENV_KEY_FILE"
fi

# ===================================================================================
# ÉCRITURE PARTIELLE lisa.conf
# ===================================================================================
cat > "$CONF_FILE" << EOF
# L.I.S.A. — Configuration générée le $(date '+%Y-%m-%d %H:%M:%S')
# Pour reconfigurer : bash $STACK_DIR/00_config.sh --reconfigure

LISA_VERSION="1.0.0"
ARCH="$ARCH"
ARCH_LABEL="$ARCH_LABEL"
PLATFORM="$PLATFORM"
OS_NAME="$OS_NAME"
RAM_PROFILE="$RAM_PROFILE"
RAM_GB="$RAM_GB"
CPU_CORES="$CPU_CORES"
GPU_TYPE="$GPU_TYPE"
GPU_LABEL="$GPU_LABEL"
LLM_MODEL_LOCAL="$LLM_MODEL_LOCAL"
ENV_KEY_FILE="$STACK_DIR/.env.key"
EOF

echo "SYSTEM_DONE" > "$STATE_FILE"
kill "$SUDO_KEEPALIVE_PID" 2>/dev/null

exec bash "$STACK_DIR/01_config.sh"

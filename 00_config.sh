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

mkdir -p "$STACK_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ===================================================================================
# MODE RECONFIGURE
# ===================================================================================
if [[ "$1" == "--reconfigure" ]]; then
    warn "Mode reconfiguration — la configuration existante sera remplacée."
    echo -ne "${YELLOW}[?]${RESET} Confirmer ? [o/N] : " ; read -r RECONF
    [[ ! "$RECONF" =~ ^[Oo]$ ]] && { info "Annulé." ; exit 0; }
    rm -f "$CONF_FILE" "$STACK_DIR/.env.gpg" "$STACK_DIR/.env.plain"
    sed -i '/LISA_AUTO_RESUME\|LISA_SUDO_RESUME/,/^fi$/d' "$HOME/.bashrc" 2>/dev/null
fi

# ===================================================================================
# TRAP — nettoyage centralisé
# ===================================================================================
INHIBIT_PID=""
SUDO_KEEPALIVE_PID=""

_trap_cleanup() {
    local EXIT_CODE=$?
    [ "$EXIT_CODE" -eq 0 ] && return
    echo ""
    echo -e "\033[1;31m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;31m  L.I.S.A. — Interruption détectée\033[0m"
    echo -e "\033[1;31m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    [ -n "$INHIBIT_PID" ] && kill "$INHIBIT_PID" 2>/dev/null
    if [ -f "$STACK_DIR/lisa_cleanup.sh" ]; then
        bash "$STACK_DIR/lisa_cleanup.sh" "interruption configuration"
    else
        rm -f "$PASS_ENC" "$PASS_KEY" "$STACK_DIR/.env.plain"
        rm -rf "$STACK_DIR"
    fi
    exit 1
}
trap '_trap_cleanup' EXIT
trap 'exit 1' INT TERM

# ===================================================================================
# ===================================================================================
# HELPERS AFFICHAGE TERMINAL
# ===================================================================================

# Boîte message texte
_msg() {
    echo ""
    echo -e "${CYAN}  ┌─────────────────────────────────────────────────┐${RESET}"
    echo -e "${CYAN}  │  $1${RESET}"
    echo -e "${CYAN}  ├─────────────────────────────────────────────────┤${RESET}"
    while IFS= read -r LINE; do
        printf "${CYAN}  │${RESET}  %-47s${CYAN}│${RESET}
" "$LINE"
    done <<< "$2"
    echo -e "${CYAN}  └─────────────────────────────────────────────────┘${RESET}"
    echo ""
    echo -ne "  Appuyez sur Entrée pour continuer..." ; read -r
    echo ""
}

# Question oui/non
_yesno() {
    echo ""
    echo -e "${CYAN}  $1${RESET}"
    echo -e "  $2"
    echo ""
    echo -ne "${YELLOW}  [?]${RESET} Votre choix [O/n] : " ; read -r R
    echo ""
    [[ ! "$R" =~ ^[Nn]$ ]] && return 0 || return 1
}

# Saisie mot de passe
_password() {
    echo -ne "${YELLOW}  [?]${RESET} $2 : " ; read -r -s R ; echo ""
    eval "$3="$R""
}

# Saisie texte
_input() {
    echo -ne "${YELLOW}  [?]${RESET} $2 : " ; read -r R
    eval "$3="$R""
}

# Info box
_info_box() {
    echo -e "${CYAN}  $1${RESET}"
    echo -e "  $2"
    echo ""
}
_section() {
    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}  $1${RESET}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

_bar() {
    local PCT=$1
    local FILLED=$(( PCT * 40 / 100 ))
    local EMPTY=$(( 40 - FILLED ))
    local B=""
    for ((i=0; i<FILLED; i++)); do B+="█"; done
    for ((i=0; i<EMPTY; i++)); do B+="░"; done
    echo "$B"
}

_ok()   { printf "  ${GREEN}[ OK ]${RESET}  %s

" "$1"; }
_skip() { printf "  ${CYAN}[SKIP]${RESET}  %s

" "$1"; }
_fail() {
    printf "  ${RED}[FAIL]${RESET}  %s

" "$1"
    echo ""
    error "Erreur fatale : $2"
    error "Consultez $LOG_FILE pour les détails."
    exit 1
}

_run() {
    # _run "Label affiché" "commande" [TOTAL] [STEP]
    local LABEL="$1"
    local CMD="$2"
    local TOTAL="${3:-1}"
    local STEP="${4:-1}"
    local PCT=$(( STEP * 100 / TOTAL ))
    local BAR=$(_bar "$PCT")

    printf "  ${BLUE}[ .. ]${RESET}  %-45s ${BLUE}%3d%%${RESET}  %s" "$LABEL" "$PCT" "$BAR"
    
    if eval "$CMD" >> "$LOG_FILE" 2>&1; then
        printf "
  ${GREEN}[ OK ]${RESET}  %-45s ${BLUE}%3d%%${RESET}  %s

" "$LABEL" "$PCT" "$BAR"
        return 0
    else
        printf "
  ${RED}[FAIL]${RESET}  %-45s ${BLUE}%3d%%${RESET}  %s

" "$LABEL" "$PCT" "$BAR"
        error "Échec : $LABEL"
        error "Consultez $LOG_FILE pour les détails."
        exit 1
    fi
}

# ===================================================================================
# DÉPENDANCES BOOTSTRAP
# ===================================================================================
_section "Préparation de L.I.S.A."

PKGS_TO_INSTALL=()
for PKG in tmux jq curl whiptail; do
    command -v "$PKG" &>/dev/null || PKGS_TO_INSTALL+=("$PKG")
done

echo -e "  Outils système nécessaires :"
for PKG in tmux jq curl whiptail; do
    if command -v "$PKG" &>/dev/null; then
        printf "    ${CYAN}•${RESET} %-12s ${GREEN}déjà présent${RESET}
" "$PKG"
    else
        printf "    ${CYAN}•${RESET} %-12s à installer
" "$PKG"
    fi
done
echo ""
echo -e "  ${MAGENTA}────────────────────────────────────────────────────${RESET}"
echo ""

TOTAL_STEPS=$(( ${#PKGS_TO_INSTALL[@]} + 2 ))
STEP=0

# Nettoyage cache
STEP=$((STEP + 1))
_run "Nettoyage du cache APT"     "echo '$(_get_pass)' | sudo -S apt-get clean -qq 2>/dev/null"     "$TOTAL_STEPS" "$STEP"

# Mise à jour sources
STEP=$((STEP + 1))
_run "Mise à jour des sources de paquets"     "echo '$(_get_pass)' | sudo -S apt-get update -qq"     "$TOTAL_STEPS" "$STEP"

# Installation paquets manquants
for PKG in "${PKGS_TO_INSTALL[@]}"; do
    STEP=$((STEP + 1))
    _run "Installation de $PKG"         "echo '$(_get_pass)' | sudo -S apt-get install -y $PKG -qq"         "$TOTAL_STEPS" "$STEP"
done

# VÉRIFICATION ET AJOUT SUDOERS
# ===================================================================================
if ! echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1; then
    _msg "Droits administrateur requis" \
"Votre compte ($USER) n'a pas les droits administrateur.

L.I.S.A. va tenter de vous ajouter automatiquement.
Le mot de passe du compte root est nécessaire."

    ROOT_PASS=""
    _password "Compte root" "Mot de passe root" ROOT_PASS

    if echo "$ROOT_PASS" | su -c "usermod -aG sudo $USER && echo OK" root 2>/dev/null | grep -q "OK"; then
        unset ROOT_PASS
        echo "SUDO_ADDED" > "$STATE_FILE"

        # Reprise automatique après reconnexion
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
"Impossible d'ajouter $USER aux administrateurs.

Demandez à votre administrateur d'exécuter :
  sudo usermod -aG sudo $USER

Puis relancez L.I.S.A."
        exit 1
    fi
fi

# Keepalive sudo (stdin redirigé pour ne pas capturer les saisies)
(while [ -f "$PASS_KEY" ]; do
    echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1
    sleep 240
done) </dev/null &
SUDO_KEEPALIVE_PID=$!
echo "$SUDO_KEEPALIVE_PID" > "$STACK_DIR/.sudo_keepalive.pid"

# ===================================================================================
# CLÉ DE CHIFFREMENT OPENSSL (AES-256 — sans dépendance GPG)
# ===================================================================================
# Génération d'une clé symétrique dédiée au chiffrement du .env
# Stockée séparément du .env — transparente pour l'utilisateur
ENV_KEY_FILE="$STACK_DIR/.env.key"
if [ ! -f "$ENV_KEY_FILE" ]; then
    openssl rand -hex 32 > "$ENV_KEY_FILE"
    chmod 600 "$ENV_KEY_FILE"
fi
ENV_KEY=$(cat "$ENV_KEY_FILE")


# ===================================================================================
# ÉCRITURE PARTIELLE lisa.conf (section système)
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

# Passage au script suivant
exec bash "$STACK_DIR/01_config.sh"

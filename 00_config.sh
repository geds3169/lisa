#!/bin/bash
# ===================================================================================
# L.I.S.A — Local Intelligent System Assistant
# 00_config.sh — Détection système, sudo, chiffrement AES-256, bootstrap whiptail
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
# DÉTECTION WHIPTAIL
# ===================================================================================
USE_WHIPTAIL=false
if command -v whiptail &>/dev/null && [ -t 1 ]; then
    USE_WHIPTAIL=true
fi

# Helpers UI — whiptail ou fallback texte
_msg() {
    # _msg "Titre" "Message"
    if $USE_WHIPTAIL; then
        whiptail --title "$1" --msgbox "$2" 12 60
    else
        echo "" ; echo -e "${CYAN}$1${RESET}" ; echo -e "$2" ; echo ""
    fi
}

_yesno() {
    # _yesno "Titre" "Question" → retourne 0=oui 1=non
    if $USE_WHIPTAIL; then
        whiptail --title "$1" --yesno "$2" 10 60
        return $?
    else
        echo -ne "${YELLOW}[?]${RESET} $2 [O/n] : " ; read -r R
        [[ ! "$R" =~ ^[Nn]$ ]] && return 0 || return 1
    fi
}

_password() {
    # _password "Titre" "Message" VARNAME
    if $USE_WHIPTAIL; then
        local VAL
        VAL=$(whiptail --title "$1" --passwordbox "$2" 10 60 3>&1 1>&2 2>&3)
        eval "$3=\"$VAL\""
    else
        echo -ne "${YELLOW}[?]${RESET} $2 : " ; read -r -s R ; echo ""
        eval "$3=\"$R\""
    fi
}

_info_box() {
    # _info_box "Titre" "Contenu"
    if $USE_WHIPTAIL; then
        whiptail --title "$1" --infobox "$2" 10 60
        sleep 2
    else
        section "$1"
        echo -e "$2"
    fi
}

# ===================================================================================
# BANNER (fallback texte uniquement)
# ===================================================================================
if ! $USE_WHIPTAIL; then
    clear
    echo -e "${CYAN}"
    cat <<'BANNER'
  _      _____ _____  _
 | |    |_   _/ ____|/ \
 | |      | | | (___/  /\
 | |      | |  \___ \ / /\
 | |____ _| |_ ____) / /__\
 |______|_____|_____/______\

  Local Intelligent System Assistant
BANNER
    echo -e "${RESET}"
fi

# ===================================================================================
# VÉRIFICATION ARCHITECTURE
# ===================================================================================
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        PLATFORM="linux/amd64" ; ARCH_LABEL="x86_64 (AMD64)"
        ;;
    aarch64|arm64)
        PLATFORM="linux/arm64" ; ARCH_LABEL="ARM64"
        ;;
    *)
        _msg "Erreur" "Architecture $ARCH non supportée.\nL.I.S.A. requiert x86_64 ou ARM64."
        exit 1
        ;;
esac

# ===================================================================================
# VÉRIFICATION OS
# ===================================================================================
if [[ "$(uname -s)" != "Linux" ]]; then
    _msg "Erreur" "L.I.S.A. Stack requiert Linux.\nLe HUD sera multiplateforme via Tauri."
    exit 1
fi

OS_NAME="Inconnue"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$PRETTY_NAME"
fi

# ===================================================================================
# DÉTECTION RESSOURCES
# ===================================================================================
CPU_CORES=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$((RAM_KB / 1024 / 1024))
DISK_FREE=$(df -BG "$HOME" | awk 'NR==2{print $4}' | tr -d 'G')

# RAM insuffisante
if [ "$RAM_GB" -lt 4 ]; then
    _msg "Ressources insuffisantes" \
"RAM détectée : ${RAM_GB} GB
Minimum requis : 4 GB

L.I.S.A. ne peut pas être installée sur cette machine."
    exit 1
fi

# Profil automatique
if [ "$RAM_GB" -lt 8 ]; then
    RAM_PROFILE="low"
elif [ "$RAM_GB" -lt 16 ]; then
    RAM_PROFILE="medium"
else
    RAM_PROFILE="high"
fi

# Modèle LLM automatique selon profil
case "$RAM_PROFILE" in
    low)    LLM_MODEL_LOCAL="phi3" ;;
    medium) LLM_MODEL_LOCAL="llama3.2" ;;
    high)   LLM_MODEL_LOCAL="llama3.1:8b" ;;
esac

# GPU
GPU_TYPE="none"
GPU_LABEL="Aucun — mode CPU"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    GPU_LABEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    GPU_TYPE="nvidia"
elif lspci 2>/dev/null | grep -qi "amd\|radeon"; then
    GPU_LABEL="AMD GPU (CPU fallback)"
    GPU_TYPE="amd"
fi

# Avertissement disque
[ "$DISK_FREE" -lt 20 ] && \
    _msg "Avertissement" "Espace disque faible : ${DISK_FREE} GB libres.\nMinimum recommandé : 20 GB."

# ===================================================================================
# MOT DE PASSE SYSTÈME
# ===================================================================================
_msg "Authentification requise" \
"L.I.S.A. a besoin de votre mot de passe pour :

  • Installer Docker et les outils système
  • Configurer le pare-feu
  • Vous ajouter au groupe Docker

Votre mot de passe est chiffré localement
et supprimé automatiquement à la fin
de l'installation."

EPHEMERAL_KEY=$(openssl rand -hex 32)
echo "$EPHEMERAL_KEY" > "$PASS_KEY"
chmod 600 "$PASS_KEY"

SYS_PASS=""
while true; do
    _password "Authentification" "Votre mot de passe de session Linux" SYS_PASS
    echo "$SYS_PASS" | openssl enc -aes-256-cbc -pbkdf2 \
        -pass pass:"$EPHEMERAL_KEY" -out "$PASS_ENC" 2>/dev/null
    chmod 600 "$PASS_ENC"
    unset SYS_PASS

    _get_pass() {
        openssl enc -d -aes-256-cbc -pbkdf2 \
            -pass pass:"$(cat "$PASS_KEY")" -in "$PASS_ENC" 2>/dev/null
    }

    if echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1; then
        break
    else
        _msg "Mot de passe incorrect" \
"Le mot de passe saisi est incorrect.
Veuillez réessayer."
        rm -f "$PASS_ENC"
    fi
done

# ===================================================================================
# DÉPENDANCES BOOTSTRAP (après authentification — sudo disponible)
# ===================================================================================
_info_box "Préparation" "Installation des outils nécessaires...\nCela ne prendra que quelques secondes."

# Mise à jour de la liste des paquets
echo "$(_get_pass)" | sudo -S apt-get update -qq 2>/dev/null

for PKG in tmux jq curl whiptail; do
    if ! command -v "$PKG" &>/dev/null; then
        echo "$(_get_pass)" | sudo -S apt-get install -y "$PKG" -qq 2>/dev/null             || warn "Impossible d'installer $PKG"
    fi
done
# Activer whiptail maintenant qu'il est installé — réaffiche tout en graphique
if command -v whiptail &>/dev/null && [ -t 1 ]; then
    USE_WHIPTAIL=true
    clear
fi

# ===================================================================================
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

        if $USE_WHIPTAIL; then
            whiptail --title "Reconnexion nécessaire" --msgbox \
"Votre compte a été ajouté aux administrateurs.

Linux doit fermer votre session pour appliquer
ce changement.

L.I.S.A. reprendra automatiquement dès votre
reconnexion avec le compte : $USER

La session va se fermer dans 10 secondes..." 16 60
        else
            echo ""
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
            echo -e "${GREEN}  ✓ Compte ajouté aux administrateurs.${RESET}"
            echo -e "${YELLOW}  → Reconnectez-vous avec : ${GREEN}$USER${RESET}"
            echo -e "${YELLOW}  → L'installation reprendra automatiquement.${RESET}"
            echo -e "${RED}  La session se ferme dans 10 secondes...${RESET}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        fi

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

# Keepalive sudo
(while [ -f "$PASS_KEY" ]; do
    echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1
    sleep 240
done) &
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

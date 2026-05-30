#!/bin/bash
# ===================================================================================
# L.I.S.A — Local Intelligent System Assistant
# install.sh — Point d'entrée unique, à télécharger manuellement depuis la release
# Usage : bash install.sh
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

REPO_URL="https://raw.githubusercontent.com/geds3169/lisa/main"
STACK_DIR="$HOME/ai-stack"
SCRIPTS=(
    "00_config.sh"
    "00_provider_select.sh"
    "01_precheck_install.sh"
    "02_stack_files.sh"
    "03_run_stack.sh"
    "04_network.sh"
    "providers.json"
)

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
  Installateur — v1.0.0
BANNER
echo -e "${RESET}"

# --- Vérification Linux ---
if [[ "$(uname -s)" != "Linux" ]]; then
    error "L.I.S.A. Stack requiert Linux. Le HUD sera multiplateforme via Tauri."
    exit 1
fi

# --- Vérification architecture ---
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
    error "Architecture $ARCH non supportée. x86_64 et ARM64 uniquement."
    exit 1
fi

# --- Dépendances minimales pour bootstrap ---
for DEP in curl git; do
    if ! command -v "$DEP" &>/dev/null; then
        info "$DEP manquant, installation..."
        sudo apt-get update -qq && sudo apt-get install -y "$DEP" || {
            error "Impossible d'installer $DEP. Vérifiez votre connexion."
            exit 1
        }
    fi
done

# --- Création du dossier stack ---
mkdir -p "$STACK_DIR"
info "Dossier cible : $STACK_DIR"

# --- Téléchargement des scripts ---
info "Téléchargement des scripts L.I.S.A. depuis GitHub..."
DOWNLOAD_ERRORS=0

for SCRIPT in "${SCRIPTS[@]}"; do
    TARGET="$STACK_DIR/$SCRIPT"
    URL="$REPO_URL/$SCRIPT"
    if curl -fsSL "$URL" -o "$TARGET" 2>/dev/null; then
        success "  $SCRIPT"
    else
        error "  Échec téléchargement : $SCRIPT"
        DOWNLOAD_ERRORS=$((DOWNLOAD_ERRORS + 1))
    fi
done

if [ "$DOWNLOAD_ERRORS" -gt 0 ]; then
    error "$DOWNLOAD_ERRORS fichier(s) non téléchargé(s). Vérifiez votre connexion et réessayez."
    rm -rf "$STACK_DIR"
    exit 1
fi

# --- Application des droits d'exécution ---
for SCRIPT in "${SCRIPTS[@]}"; do
    [[ "$SCRIPT" == *.json ]] && continue
    chmod +x "$STACK_DIR/$SCRIPT"
done
success "Droits d'exécution appliqués."

# --- Vérification intégrité basique ---
for SCRIPT in "${SCRIPTS[@]}"; do
    [[ "$SCRIPT" == *.json ]] && continue
    if [ ! -s "$STACK_DIR/$SCRIPT" ]; then
        error "Fichier vide ou absent : $SCRIPT"
        rm -rf "$STACK_DIR"
        exit 1
    fi
done
success "Intégrité des fichiers vérifiée."

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  Scripts L.I.S.A. prêts dans $STACK_DIR${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
info "Lancement de la configuration..."
sleep 1

exec bash "$STACK_DIR/00_config.sh"

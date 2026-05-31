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
    "01_config.sh"
    "02_config.sh"
    "00_provider_select.sh"
    "01_precheck_install.sh"
    "02_stack_files.sh"
    "03_run_stack.sh"
    "04_network.sh"
    "lisa_cleanup.sh"
    "providers.json"
)

# ===================================================================================
# TRAP — nettoyage si install.sh est tué ou échoue avant de passer la main
# ===================================================================================
_trap_install() {
    echo ""
    warn "Installation interrompue avant le lancement de la configuration."
    rm -rf "$STACK_DIR"
    # Suppression de install.sh depuis tous les emplacements probables
    rm -f "$(realpath "$0" 2>/dev/null)"           "$(pwd)/install.sh" "$HOME/install.sh"           "$HOME/Téléchargements/install.sh" "$HOME/Downloads/install.sh"
    error "Répertoire $STACK_DIR supprimé. Aucune trace laissée."
    exit 1
}
trap '_trap_install' INT TERM ERR

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

# ===================================================================================
# DÉTECTION D'UNE INSTALLATION PRÉCÉDENTE
# ===================================================================================
if [ -d "$STACK_DIR" ]; then
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}  Une installation L.I.S.A. précédente a été détectée.${RESET}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    PREV_STATE=$(cat "$STACK_DIR/.lisa_state" 2>/dev/null || echo "inconnue")
    info "État de la précédente installation : $PREV_STATE"
    echo ""

    echo -e "  ${GREEN}[1]${RESET} Nettoyer et recommencer depuis le début"
    echo -e "  ${GREEN}[2]${RESET} Reprendre là où l'installation s'était arrêtée"
    echo -e "  ${GREEN}[3]${RESET} Annuler"
    echo ""
    echo -ne "${YELLOW}[?]${RESET} Votre choix [1/2/3] : "
    read -r PREV_CHOICE

    case "$PREV_CHOICE" in
        1)
            info "Nettoyage de l'installation précédente..."
            if [ -f "$STACK_DIR/lisa_cleanup.sh" ]; then
                bash "$STACK_DIR/lisa_cleanup.sh" "nettoyage avant réinstallation"
            else
                rm -rf "$STACK_DIR"
            fi
            success "Nettoyage terminé. Démarrage d'une nouvelle installation."
            ;;
        2)
            info "Reprise de l'installation en cours..."
            RESUME_STATE=$(cat "$STACK_DIR/.lisa_state" 2>/dev/null)
            case "$RESUME_STATE" in
                "CONFIG_DONE"|"SUDO_ADDED")
                    exec bash "$STACK_DIR/01_precheck_install.sh" ;;
                "PRECHECK_DONE")
                    exec bash "$STACK_DIR/02_stack_files.sh" ;;
                "FILES_DONE")
                    exec bash "$STACK_DIR/03_run_stack.sh" ;;
                "NETWORK_DONE"|"STACK_DONE")
                    info "L'installation semble déjà complète (état: $RESUME_STATE)."
                    echo -ne "${YELLOW}[?]${RESET} Relancer quand même ? [o/N] : "
                    read -r FORCE
                    [[ "$FORCE" =~ ^[Oo]$ ]] && exec bash "$STACK_DIR/00_config.sh" || exit 0
                    ;;
                *)
                    info "État non reconnu — reprise depuis le début de la configuration."
                    exec bash "$STACK_DIR/00_config.sh"
                    ;;
            esac
            ;;
        3|*)
            info "Annulé."
            exit 0
            ;;
    esac
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

# Enregistrer le chemin de install.sh pour suppression par lisa_cleanup.sh
echo "$(realpath "$0" 2>/dev/null || echo "$(pwd)/install.sh")" > "$STACK_DIR/.install_sh_path"

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

# Désactiver le trap avant de passer la main (le cleanup est géré par 00_config.sh+)
trap - INT TERM ERR
exec bash "$STACK_DIR/00_config.sh"

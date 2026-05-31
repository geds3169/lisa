#!/bin/bash
# ===================================================================================
# L.I.S.A — lisa_cleanup.sh
# Nettoyage centralisé — appelé par tous les scripts en cas d'échec ou d'interruption
# Usage : bash lisa_cleanup.sh [raison]
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

RAISON="${1:-interruption}"
STACK_DIR="$HOME/ai-stack"
SNAPSHOT_FILE="$STACK_DIR/.docker_snapshot"
PASS_ENC="$STACK_DIR/.lisa_pass.gpg"
PASS_KEY="$STACK_DIR/.lisa_pass.key"
INSTALL_SH="$(pwd)/install.sh"
LOG_FILE="$STACK_DIR/lisa_install.log"

echo ""
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${RED}  L.I.S.A. — Nettoyage en cours (${RAISON})${RESET}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# ===================================================================================
# 1. SUPPRESSION DES SECRETS ÉPHÉMÈRES
# ===================================================================================
info "Suppression des secrets éphémères..."
rm -f "$PASS_ENC" "$PASS_KEY" "$STACK_DIR/.env.plain" "$STACK_DIR/.env.key"
success "Secrets supprimés."

# ===================================================================================
# 2. ARRÊT ET SUPPRESSION DES CONTAINERS L.I.S.A.
# ===================================================================================
if command -v docker &>/dev/null; then
    info "Arrêt des containers L.I.S.A...."

    # Arrêt via compose si le fichier existe
    if [ -f "$STACK_DIR/docker-compose.yml" ]; then
        docker compose -f "$STACK_DIR/docker-compose.yml" down --remove-orphans 2>/dev/null \
            && success "Stack Docker arrêtée." \
            || warn "Impossible d'arrêter via compose — tentative manuelle..."
    fi

    # Suppression des containers estampillés lisa
    LISA_CONTAINERS=$(docker ps -a --filter "label=lisa.stack=true" --format "{{.Names}}" 2>/dev/null)
    if [ -n "$LISA_CONTAINERS" ]; then
        echo "$LISA_CONTAINERS" | xargs docker rm -f 2>/dev/null
        success "Containers L.I.S.A. supprimés : $(echo $LISA_CONTAINERS | tr '\n' ' ')"
    else
        info "Aucun container L.I.S.A. à supprimer."
    fi

    # Suppression des images estampillées lisa
    LISA_IMAGES=$(docker images --filter "label=lisa.stack=true" -q 2>/dev/null)
    if [ -n "$LISA_IMAGES" ]; then
        echo "$LISA_IMAGES" | xargs docker rmi -f 2>/dev/null
        success "Images L.I.S.A. supprimées."
    else
        info "Aucune image L.I.S.A. à supprimer."
    fi

    # Suppression des images construites par le build (par nom)
    for IMG in lisa/api lisa/llm lisa/stt lisa/tts lisa/rag; do
        if docker image inspect "$IMG:latest" &>/dev/null 2>&1; then
            docker rmi -f "$IMG:latest" 2>/dev/null
            info "Image $IMG supprimée."
        fi
    done

    # Nettoyage des volumes L.I.S.A. (pas les volumes existants avant installation)
    if [ -f "$SNAPSHOT_FILE" ]; then
        source "$SNAPSHOT_FILE"
        EXISTING_VOLUMES=$(echo "$VOLUMES" | tr ',' '\n')
        LISA_VOLUMES=$(docker volume ls --format "{{.Name}}" 2>/dev/null | grep -E "^(ollama_data|qdrant_data|searxng_data|caddy_data|caddy_config)$")
        for VOL in $LISA_VOLUMES; do
            if ! echo "$EXISTING_VOLUMES" | grep -q "^${VOL}$"; then
                docker volume rm "$VOL" 2>/dev/null && info "Volume $VOL supprimé."
            fi
        done
    else
        # Pas de snapshot — on supprime uniquement les volumes L.I.S.A. connus
        for VOL in ollama_data qdrant_data searxng_data caddy_data caddy_config; do
            docker volume rm "$VOL" 2>/dev/null && info "Volume $VOL supprimé." || true
        done
    fi

    # Suppression du réseau Docker L.I.S.A.
    docker network rm lisa_internal lisa_external 2>/dev/null && info "Réseaux L.I.S.A. supprimés." || true

    success "Environnement Docker nettoyé."

    # ===================================================================================
    # 3. AFFICHAGE DU SNAPSHOT (info pour l'utilisateur)
    # ===================================================================================
    if [ -f "$SNAPSHOT_FILE" ]; then
        source "$SNAPSHOT_FILE"
        echo ""
        info "Votre environnement Docker avant L.I.S.A. :"
        [ -n "$IMAGES" ]     && info "  Images     : $IMAGES"
        [ -n "$CONTAINERS" ] && info "  Containers : $CONTAINERS"
        [ -n "$VOLUMES" ]    && info "  Volumes    : $VOLUMES"
        warn "Les containers existants ont été préservés."
    fi
fi

# ===================================================================================
# 4. SUPPRESSION DU RÉPERTOIRE AI-STACK
# ===================================================================================
info "Suppression du répertoire d'installation..."

# Conserver le log pour diagnostic si échec
if [ -f "$LOG_FILE" ]; then
    LOG_BACKUP="$HOME/lisa_install_$(date '+%Y%m%d_%H%M%S').log"
    cp "$LOG_FILE" "$LOG_BACKUP"
    info "Log conservé : $LOG_BACKUP"
fi

rm -rf "$STACK_DIR"
success "Répertoire $STACK_DIR supprimé."

# ===================================================================================
# 5. SUPPRESSION DE install.sh
# ===================================================================================
# Lire le chemin exact enregistré au lancement
INSTALL_SH_PATH=""
[ -f "$STACK_DIR/.install_sh_path" ] && INSTALL_SH_PATH=$(cat "$STACK_DIR/.install_sh_path")

# Supprimer depuis le chemin enregistré ET les emplacements probables
for CANDIDATE in \
    "$INSTALL_SH_PATH" \
    "$(pwd)/install.sh" \
    "$HOME/install.sh" \
    "$HOME/Téléchargements/install.sh" \
    "$HOME/Downloads/install.sh"; do
    if [ -n "$CANDIDATE" ] && [ -f "$CANDIDATE" ]; then
        rm -f "$CANDIDATE"
        info "install.sh supprimé : $CANDIDATE"
    fi
done

# ===================================================================================
# 6. NETTOYAGE .BASHRC (entrées L.I.S.A.)
# ===================================================================================
if grep -q "LISA_AUTO_RESUME\|LISA_SUDO_RESUME" "$HOME/.bashrc" 2>/dev/null; then
    sed -i '/LISA_AUTO_RESUME/,/^fi$/d' "$HOME/.bashrc" 2>/dev/null
    sed -i '/LISA_SUDO_RESUME/,/^fi$/d' "$HOME/.bashrc" 2>/dev/null
    info "Entrées L.I.S.A. supprimées de ~/.bashrc"
fi

# ===================================================================================
# 7. ARRÊT DES PROCESSUS EN ARRIÈRE-PLAN
# ===================================================================================
# Keepalive sudo
if [ -f "$STACK_DIR/.sudo_keepalive.pid" ]; then
    KA_PID=$(cat "$STACK_DIR/.sudo_keepalive.pid" 2>/dev/null)
    kill "$KA_PID" 2>/dev/null && info "Keepalive sudo arrêté."
fi

# systemd-inhibit
pkill -f "systemd-inhibit.*LISA" 2>/dev/null || true

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Nettoyage terminé.${RESET}"
echo -e "${YELLOW}  Pour relancer L.I.S.A. :${RESET}"
echo -e "${YELLOW}  ${BLUE}curl -fsSL https://raw.githubusercontent.com/geds3169/lisa/main/install.sh -o install.sh && bash install.sh${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

echo "CLEANED" > /tmp/.lisa_cleaned 2>/dev/null || true
exit 0

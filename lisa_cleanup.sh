#!/bin/bash
# ===================================================================================
# L.I.S.A — lisa_cleanup.sh
# Nettoyage basé sur le fichier de trace ~/.lisa_trace
# Appelé par tous les scripts en cas d'échec ou d'interruption
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
TRACE_FILE="$HOME/.lisa_trace"
STACK_DIR="$HOME/ai-stack"
LOG_FILE="$STACK_DIR/lisa_install.log"

echo ""
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${RED}  L.I.S.A. — Nettoyage (${RAISON})${RESET}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# Docker peut ne pas être dans le PATH courant
DOCKER_BIN=$(which docker 2>/dev/null)
[ -z "$DOCKER_BIN" ] && DOCKER_BIN=$(find /usr/bin /usr/local/bin -name "docker" 2>/dev/null | head -1)

if [ ! -f "$TRACE_FILE" ]; then
    warn "Fichier de trace absent — nettoyage minimal."
    rm -f "$STACK_DIR/.lisa_pass.gpg" "$STACK_DIR/.lisa_pass.key" \
          "$STACK_DIR/.env.plain" "$STACK_DIR/.env.key"
    rm -rf "$STACK_DIR"
    sed -i '/LISA_AUTO_RESUME/,/^fi$/d' "$HOME/.bashrc" 2>/dev/null
    sed -i '/LISA_SUDO_RESUME/,/^fi$/d' "$HOME/.bashrc" 2>/dev/null
    find "$HOME" -maxdepth 3 -name "install.sh" 2>/dev/null | xargs rm -f 2>/dev/null
    echo ""
    echo -e "${YELLOW}Nettoyage minimal terminé.${RESET}"
    exit 0
fi

# Sauvegarder le log IMMÉDIATEMENT dans le home — avant tout nettoyage
LOG_BACKUP=""
if [ -f "$LOG_FILE" ]; then
    LOG_BACKUP="$HOME/lisa_install_$(date '+%Y%m%d_%H%M%S').log"
    cp "$LOG_FILE" "$LOG_BACKUP"
    info "Log conservé : $LOG_BACKUP"
fi

# Arrêter la stack Docker si elle tourne
if [ -f "$STACK_DIR/docker-compose.yml" ] && [ -n "$DOCKER_BIN" ]; then
    "$DOCKER_BIN" compose -f "$STACK_DIR/docker-compose.yml" down --remove-orphans 2>/dev/null
fi

# ===================================================================================
# LECTURE DU FICHIER DE TRACE ET NETTOYAGE
# ===================================================================================
info "Lecture du fichier de trace..."

# Traiter en ordre inverse pour supprimer les éléments dans le bon ordre
tac "$TRACE_FILE" 2>/dev/null | while IFS='|' read -r TYPE VALUE; do
    [ -z "$TYPE" ] || [ -z "$VALUE" ] && continue

    case "$TYPE" in
        file)
            if [ -f "$VALUE" ]; then
                rm -f "$VALUE"
                info "  Fichier supprimé   : $VALUE"
            fi
            ;;
        dir)
            if [ -d "$VALUE" ]; then
                rm -rf "$VALUE"
                info "  Dossier supprimé   : $VALUE"
            fi
            ;;
        docker_container)
            if [ -n "$DOCKER_BIN" ]; then
                "$DOCKER_BIN" rm -f "$VALUE" 2>/dev/null && \
                    info "  Container supprimé : $VALUE"
            fi
            ;;
        docker_image)
            if [ -n "$DOCKER_BIN" ]; then
                "$DOCKER_BIN" rmi -f "$VALUE" 2>/dev/null && \
                    info "  Image supprimée    : $VALUE"
            fi
            ;;
        docker_volume)
            if [ -n "$DOCKER_BIN" ]; then
                "$DOCKER_BIN" volume rm "$VALUE" 2>/dev/null && \
                    info "  Volume supprimé    : $VALUE"
            fi
            ;;
        docker_group)
            # On ne retire pas l'utilisateur du groupe docker — trop risqué
            info "  Groupe docker      : conservé (suppression manuelle si souhaité)"
            ;;
        apt)
            # On ne désinstalle pas les paquets apt — trop risqué
            info "  Paquet apt         : $VALUE conservé"
            ;;
        apt_source)
            if [ -f "$VALUE" ]; then
                rm -f "$VALUE"
                info "  Source APT supprimée : $VALUE"
            fi
            ;;
        bashrc)
            sed -i "/${VALUE}/,/^fi$/d" "$HOME/.bashrc" 2>/dev/null
            info "  .bashrc nettoyé    : $VALUE"
            ;;
    esac
done

# Supprimer le répertoire ai-stack s'il reste
[ -d "$STACK_DIR" ] && rm -rf "$STACK_DIR" && info "  Dossier supprimé   : $STACK_DIR"

# Supprimer install.sh dans tous les emplacements
for CANDIDATE in \
    "$HOME/install.sh" \
    "$HOME/Bureau/install.sh" \
    "$HOME/Desktop/install.sh" \
    "$HOME/Téléchargements/install.sh" \
    "$HOME/Downloads/install.sh" \
    "/tmp/install.sh"; do
    if [ -f "$CANDIDATE" ]; then
        rm -f "$CANDIDATE"
        info "  install.sh supprimé : $CANDIDATE"
    fi
done
find "$HOME" -maxdepth 3 -name "install.sh" 2>/dev/null | xargs rm -f 2>/dev/null

# Arrêter les processus en arrière-plan
[ -f "$STACK_DIR/.sudo_keepalive.pid" ] && \
    kill "$(cat "$STACK_DIR/.sudo_keepalive.pid")" 2>/dev/null
pkill -f "systemd-inhibit.*LISA" 2>/dev/null || true

# Supprimer uniquement le fichier de trace
# Le log backup ($LOG_BACKUP) est intentionnellement conservé
rm -f "$TRACE_FILE"
success "Fichier de trace supprimé."

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${YELLOW}  Nettoyage terminé.${RESET}"
echo ""
if [ -n "$LOG_BACKUP" ] && [ -f "$LOG_BACKUP" ]; then
    echo -e "${CYAN}  Un log de diagnostic a été conservé :${RESET}"
    echo -e "${BLUE}  $LOG_BACKUP${RESET}"
    echo -e "${CYAN}  Consultez-le pour comprendre l'erreur :${RESET}"
    echo -e "${GREEN}  cat $LOG_BACKUP${RESET}"
    echo ""
    echo -e "${CYAN}  Pour le supprimer ensuite :${RESET}"
    echo -e "${GREEN}  rm $LOG_BACKUP${RESET}"
    echo ""
fi
echo -e "${YELLOW}  Pour relancer L.I.S.A. :${RESET}"
echo -e "${GREEN}  curl -fsSL https://raw.githubusercontent.com/geds3169/lisa/main/install.sh -o install.sh && bash install.sh${RESET}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

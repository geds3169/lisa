#!/bin/bash
# ===================================================================================
# L.I.S.A — 01_precheck_install.sh
# Prérequis, Docker, groupe, pare-feu, snapshot environnement, anti-veille
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
PASS_ENC="$STACK_DIR/.lisa_pass.gpg"
PASS_KEY="$STACK_DIR/.lisa_pass.key"
SNAPSHOT_FILE="$STACK_DIR/.docker_snapshot"
LOG_FILE="$STACK_DIR/lisa_install.log"

exec >> "$LOG_FILE" 2>&1

# ===================================================================================
# VÉRIFICATIONS PRÉALABLES
# ===================================================================================

# Vérifier que la config existe
if [ ! -f "$CONF_FILE" ]; then
    error "lisa.conf introuvable. Lancez d'abord : bash $STACK_DIR/00_config.sh"
    exit 1
fi
source "$CONF_FILE"

# Vérifier état
CURRENT_STATE=$(cat "$STATE_FILE" 2>/dev/null)
if [ "$CURRENT_STATE" = "PRECHECK_DONE" ] || [ "$CURRENT_STATE" = "FILES_DONE" ] || [ "$CURRENT_STATE" = "NETWORK_DONE" ] || [ "$CURRENT_STATE" = "STACK_DONE" ]; then
    info "Étape precheck déjà complétée (état: $CURRENT_STATE). Passage à l'étape suivante."
    exec bash "$STACK_DIR/02_stack_files.sh"
fi

# ===================================================================================
# HELPER MOT DE PASSE
# ===================================================================================
_get_pass() {
    openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$(cat "$PASS_KEY")" -in "$PASS_ENC" 2>/dev/null
}
_sudo() { echo "$(_get_pass)" | sudo -S "$@" 2>/dev/null; }

# Keepalive sudo
(while [ -f "$PASS_KEY" ]; do
    _sudo -v &>/dev/null
    sleep 240
done) &
SUDO_KEEPALIVE_PID=$!
echo "$SUDO_KEEPALIVE_PID" > "$STACK_DIR/.sudo_keepalive.pid"

# ===================================================================================
# TRAP NETTOYAGE
# ===================================================================================
cleanup_on_failure() {
    EXIT_CODE=$?
    [ "$EXIT_CODE" -eq 0 ] && return

    error "Échec détecté — lancement du nettoyage..."
    warn "Suppression des secrets éphémères..."
    rm -f "$PASS_ENC" "$PASS_KEY"
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    kill "$INHIBIT_PID" 2>/dev/null

    # Restauration snapshot Docker
    if [ -f "$SNAPSHOT_FILE" ]; then
        warn "Restauration de l'environnement Docker initial..."
        bash "$STACK_DIR/.docker_restore.sh" 2>/dev/null || true
    fi

    # Nettoyage stack L.I.S.A. uniquement (pas Docker lui-même)
    if command -v docker &>/dev/null; then
        docker compose -f "$STACK_DIR/docker-compose.yml" down --remove-orphans 2>/dev/null || true
        # Supprimer uniquement les images créées par L.I.S.A.
        docker images --filter "label=lisa.stack=true" -q | xargs docker rmi -f 2>/dev/null || true
    fi

    echo ""
    error "L.I.S.A. n'a pas pu être installée."
    warn "Votre environnement Docker a été restauré à son état initial."
    warn "Consultez $LOG_FILE pour les détails."
    echo "FAILED" > "$STATE_FILE"
    exit 1
}
trap cleanup_on_failure EXIT
trap 'exit 1' INT TERM

# ===================================================================================
# ANTI-VEILLE
# ===================================================================================
section "Blocage de la mise en veille"

INHIBIT_PID=""
if command -v systemd-inhibit &>/dev/null; then
    systemd-inhibit --what=sleep:idle --who="LISA Installer" \
        --why="Installation en cours" --mode=block \
        sleep infinity &
    INHIBIT_PID=$!
    success "Mise en veille bloquée (systemd-inhibit PID: $INHIBIT_PID)"
else
    # Fallback : xdg-screensaver ou setterm
    command -v xdg-screensaver &>/dev/null && xdg-screensaver reset 2>/dev/null
    setterm -blank 0 2>/dev/null || true
    warn "systemd-inhibit absent — tentative de blocage veille alternative."
fi

# ===================================================================================
# SNAPSHOT DOCKER INITIAL
# ===================================================================================
section "Inventaire Docker existant"

if command -v docker &>/dev/null; then
    info "Sauvegarde de l'environnement Docker existant..."
    {
        echo "# Snapshot Docker avant installation L.I.S.A. — $(date)"
        echo "IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' | tr '\n' ',' | sed 's/,$//')"
        echo "CONTAINERS=$(docker ps -a --format '{{.Names}}' | tr '\n' ',' | sed 's/,$//')"
        echo "VOLUMES=$(docker volume ls --format '{{.Name}}' | tr '\n' ',' | sed 's/,$//')"
        echo "NETWORKS=$(docker network ls --format '{{.Name}}' | tr '\n' ',' | sed 's/,$//')"
    } > "$SNAPSHOT_FILE"

    # Script de restauration
    cat > "$STACK_DIR/.docker_restore.sh" << 'RESTORE'
#!/bin/bash
# Restauration snapshot Docker pré-installation L.I.S.A.
source "$HOME/ai-stack/.docker_snapshot"
echo "Environnement Docker au moment de l'installation L.I.S.A. :"
echo "Images    : $IMAGES"
echo "Containers: $CONTAINERS"
echo "Volumes   : $VOLUMES"
echo "Note : la restauration automatique des containers supprimés n'est pas possible."
echo "Référez-vous à cette liste pour recréer manuellement si nécessaire."
RESTORE
    chmod +x "$STACK_DIR/.docker_restore.sh"
    success "Snapshot Docker sauvegardé."
else
    info "Docker absent — pas de snapshot à effectuer."
fi

# ===================================================================================
# INSTALLATION DOCKER
# ===================================================================================
section "Installation Docker"

DOCKER_WAS_PRESENT=false
if command -v docker &>/dev/null; then
    DOCKER_WAS_PRESENT=true
    DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
    success "Docker présent : $DOCKER_VERSION"

    # Vérifier si c'est bien Docker v2 (plugin compose)
    if docker compose version &>/dev/null 2>&1; then
        success "Docker Compose v2 (plugin) disponible."
    else
        warn "Docker Compose v2 absent — installation du plugin..."
        _sudo apt-get install -y docker-compose-plugin -qq && success "Plugin Docker Compose v2 installé."
    fi
else
    info "Installation de Docker (méthode officielle)..."
    _sudo apt-get update -qq
    _sudo apt-get install -y ca-certificates curl gnupg -qq

    _sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        _sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    _sudo chmod a+r /etc/apt/keyrings/docker.gpg

    DISTRO_ID=$(. /etc/os-release && echo "$ID")
    DISTRO_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DISTRO_ID} ${DISTRO_CODENAME} stable" | \
        _sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    _sudo apt-get update -qq
    _sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin -qq
    success "Docker et Docker Compose v2 installés."
fi

# ===================================================================================
# GROUPE DOCKER
# ===================================================================================
section "Groupe Docker"

if groups "$USER" | grep -q "\bdocker\b"; then
    success "Utilisateur $USER déjà dans le groupe docker."
else
    info "Ajout de $USER au groupe docker..."
    _sudo usermod -aG docker "$USER"
    success "Utilisateur ajouté au groupe docker."

    echo "DOCKER_GROUP_ADDED" > "$STATE_FILE"
    warn "Le groupe docker sera actif à la prochaine session."
    info "Une nouvelle session va s'ouvrir automatiquement pour appliquer le groupe."
    info "L'installation reprendra automatiquement."

    # Nettoyage keepalive avant exec
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    kill "$INHIBIT_PID" 2>/dev/null

    # Reprise via newgrp pour recharger le groupe sans quitter la session
    exec sg docker -c "bash $STACK_DIR/01_precheck_install.sh"
fi

# ===================================================================================
# PARE-FEU (UFW)
# ===================================================================================
section "Configuration du pare-feu"

if ! command -v ufw &>/dev/null; then
    info "Installation de UFW..."
    _sudo apt-get install -y ufw -qq
fi

# Règles de base
_sudo ufw --force reset > /dev/null 2>&1
_sudo ufw default deny incoming > /dev/null 2>&1
_sudo ufw default allow outgoing > /dev/null 2>&1
_sudo ufw allow ssh > /dev/null 2>&1

# Ports L.I.S.A. — uniquement l'API et Caddy sont exposés
_sudo ufw allow 80/tcp  > /dev/null 2>&1   # Caddy HTTP
_sudo ufw allow 443/tcp > /dev/null 2>&1   # Caddy HTTPS

# Ports internes Docker (accessibles uniquement en local via le réseau interne)
# Ollama (11434), API (8000), STT, TTS, RAG, SearXNG : non exposés sur le host

if [[ "$EXPOSE_INTERNET" == "true" ]]; then
    info "Ports 80 et 443 ouverts pour l'accès externe via Caddy."
else
    # Mode local uniquement : on ouvre l'API sur loopback
    _sudo ufw allow from 127.0.0.1 to any port 8001 > /dev/null 2>&1
    info "Mode local — API accessible uniquement sur 127.0.0.1:8001"
fi

_sudo ufw --force enable > /dev/null 2>&1
success "Pare-feu UFW configuré."
_sudo ufw status verbose 2>/dev/null | grep -E "Status|ALLOW|DENY" | while read LINE; do info "  $LINE"; done

# ===================================================================================
# MARQUEUR D'ÉTAT
# ===================================================================================
echo "PRECHECK_DONE" > "$STATE_FILE"
success "Étape precheck terminée."

# Suppression des secrets éphémères de mot de passe
# (ils ne sont plus nécessaires, Docker est installé et configuré)
# On les garde pour 02 et 03 qui ont encore besoin de sudo
# Ils seront supprimés en fin de 03

kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
kill "$INHIBIT_PID" 2>/dev/null

info "Passage à la création de la stack..."
sleep 1
exec bash "$STACK_DIR/02_stack_files.sh"

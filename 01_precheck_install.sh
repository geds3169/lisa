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

# Log sans rediriger stdout
_log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE" 2>/dev/null; }

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
TRACE_FILE="$HOME/.lisa_trace"
_trace() { grep -qxF "${1}|${2}" "$TRACE_FILE" 2>/dev/null || echo "${1}|${2}" >> "$TRACE_FILE"; }

# Keepalive sudo
(while [ -f "$PASS_KEY" ]; do
    _sudo -v &>/dev/null
    sleep 240
done) </dev/null &
SUDO_KEEPALIVE_PID=$!
echo "$SUDO_KEEPALIVE_PID" > "$STACK_DIR/.sudo_keepalive.pid"

# ===================================================================================
# TRAP NETTOYAGE
# ===================================================================================
# ===================================================================================
# TRAP — nettoyage centralisé sur échec ou interruption
# ===================================================================================
_trap_cleanup() {
    local EXIT_CODE=$?
    [ "$EXIT_CODE" -eq 0 ] && return
    echo ""
    echo -e "\033[1;31m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;31m  L.I.S.A. — Interruption détectée\033[0m"
    echo -e "\033[1;31m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    # Arrêt keepalive et inhibit
    [ -f "$STACK_DIR/.sudo_keepalive.pid" ] && kill "$(cat $STACK_DIR/.sudo_keepalive.pid)" 2>/dev/null
    kill "$INHIBIT_PID" 2>/dev/null || true
    # Lancement nettoyage centralisé
    if [ -f "$STACK_DIR/lisa_cleanup.sh" ]; then
        bash "$STACK_DIR/lisa_cleanup.sh" "échec ou interruption"
    else
        rm -f "$STACK_DIR/.lisa_pass.gpg" "$STACK_DIR/.lisa_pass.key" "$STACK_DIR/.env.plain"
        rm -rf "$STACK_DIR"
    fi
    exit 1
}
trap '_trap_cleanup' EXIT
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
    _trace "file" "$SNAPSHOT_FILE"
    _trace "file" "$STACK_DIR/.docker_restore.sh"

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
    DISTRO_ID=$(. /etc/os-release && echo "$ID")
    DISTRO_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")

    # Debian Trixie (13) — docker.io depuis les repos Debian officiels
    if [ "$DISTRO_ID" = "debian" ] && [ "$DISTRO_CODENAME" = "trixie" ]; then
        info "Debian Trixie détecté — installation via repos Debian officiels..."
        _sudo apt-get install -y docker.io docker-compose docker-buildx -qq
        _trace "apt" "docker.io"
        _trace "apt" "docker-compose"
        _trace "apt" "docker-buildx"
    else
        # Méthode officielle Docker pour Ubuntu et Debian stable
        info "Installation de Docker (méthode officielle)..."
        _sudo apt-get install -y ca-certificates curl gnupg -qq

        echo "$(_get_pass)" | sudo -S rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null
        echo "$(_get_pass)" | sudo -S rm -f /etc/apt/keyrings/docker.gpg 2>/dev/null

        _sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" -o /tmp/docker.gpg 2>/dev/null
        echo "$(_get_pass)" | sudo -S gpg --yes --dearmor             -o /etc/apt/keyrings/docker.gpg < /tmp/docker.gpg 2>/dev/null
        rm -f /tmp/docker.gpg
        _trace "file" "/etc/apt/sources.list.d/docker.list"
        _trace "file" "/etc/apt/keyrings/docker.gpg"
        _sudo chmod a+r /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} ${DISTRO_CODENAME} stable" |             _sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        _sudo apt-get update -qq
        _sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin -qq
        _trace "apt" "docker-ce"
        _trace "apt" "docker-ce-cli"
        _trace "apt" "containerd.io"
        _trace "apt" "docker-compose-plugin"
    fi

    if ! command -v docker &>/dev/null; then
        error "Installation Docker échouée — docker introuvable après installation."
        error "Vérifiez votre connexion internet et relancez L.I.S.A."
        exit 1
    fi
    success "Docker installé : $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"

# Démarrer Docker dans tous les cas (installé maintenant ou déjà présent)
_sudo systemctl enable docker 2>/dev/null || true
_sudo systemctl start docker 2>/dev/null || true

# Attendre que le groupe docker soit créé (max 15s)
info "Démarrage du service Docker..."
for i in $(seq 1 15); do
    getent group docker &>/dev/null && break
    sleep 1
done
getent group docker &>/dev/null && success "Service Docker actif." ||     warn "Groupe docker non détecté — poursuite quand même."

# ===================================================================================
# GROUPE DOCKER
# ===================================================================================
section "Groupe Docker"

# Si on revient ici après DOCKER_GROUP_ADDED, passer directement à la suite
CURRENT_STATE=$(cat "$STATE_FILE" 2>/dev/null)
if [ "$CURRENT_STATE" = "DOCKER_GROUP_ADDED" ]; then
    info "Groupe docker déjà configuré — passage à la suite."
    # Mettre à jour l'état pour ne plus reboucler
    echo "DOCKER_DONE" > "$STATE_FILE"
fi

if getent group docker | grep -qw "$USER" || [ "$CURRENT_STATE" = "DOCKER_GROUP_ADDED" ]; then
    success "Utilisateur $USER dans le groupe docker."
else
    info "Ajout de $USER au groupe docker..."
    _sudo usermod -aG docker "$USER"
    success "Utilisateur ajouté au groupe docker."
    _trace "docker_group" "$USER"

    echo "DOCKER_GROUP_ADDED" > "$STATE_FILE"

    echo ""
    echo -e "\033[1;32m  ✓ Groupe Docker configuré.\033[0m"
    echo -e "\033[1;36m  Rechargement du groupe en cours...\033[0m"
    echo ""

    # Recharger le groupe docker via sg (plus fiable que newgrp avec heredoc)
    exec sg docker -c "bash \"$STACK_DIR/01_precheck_install.sh\""
fi

# ===================================================================================
# PARE-FEU
# ===================================================================================
section "Configuration du pare-feu"

# Ports nécessaires selon le mode
LISA_API_PORT=8001
PORTS_NEEDED=()
if [ "$EXPOSE_INTERNET" = "true" ]; then
    PORTS_NEEDED=(80 443)
else
    PORTS_NEEDED=($LISA_API_PORT)
fi

# Détecter le pare-feu actif — timeouts pour éviter les blocages
FW_TYPE="none"
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(timeout 3 bash -c "echo '$(_get_pass)' | sudo -S ufw status 2>/dev/null" 2>/dev/null)
    echo "$UFW_STATUS" | grep -q "Status: active" && FW_TYPE="ufw"
fi
if [ "$FW_TYPE" = "none" ] && command -v firewall-cmd &>/dev/null; then
    FWCMD_STATUS=$(timeout 3 bash -c "echo '$(_get_pass)' | sudo -S firewall-cmd --state 2>/dev/null" 2>/dev/null)
    echo "$FWCMD_STATUS" | grep -q "running" && FW_TYPE="firewalld"
fi
if [ "$FW_TYPE" = "none" ]; then
    # Vérifier iptables sans le charger
    timeout 3 bash -c "echo '$(_get_pass)' | sudo -S iptables -n -L INPUT --line-numbers 2>/dev/null"         | grep -q "Chain INPUT" && FW_TYPE="iptables"
fi

info "Pare-feu détecté : ${FW_TYPE}"

# Vérifier les conflits de ports
_port_in_use() {
    local PORT=$1
    ss -tlnp 2>/dev/null | grep -q ":${PORT} " ||     _sudo lsof -i ":${PORT}" &>/dev/null 2>&1
}

_ask_alt_port() {
    local PORT=$1
    local ALT_PORT=""
    echo ""
    warn "  Le port $PORT est déjà utilisé sur cette machine."
    echo -ne "${YELLOW}  [?]${RESET} Port alternatif pour L.I.S.A. (laisser vide pour $PORT) : "
    read -r ALT_PORT
    echo "${ALT_PORT:-$PORT}"
}

# Vérifier conflits et proposer alternatives
for PORT in "${PORTS_NEEDED[@]}"; do
    if _port_in_use "$PORT"; then
        NEW_PORT=$(_ask_alt_port "$PORT")
        if [ "$PORT" = "80" ];   then HTTP_PORT=$NEW_PORT;  else HTTP_PORT=80;  fi
        if [ "$PORT" = "443" ];  then HTTPS_PORT=$NEW_PORT; else HTTPS_PORT=443; fi
        if [ "$PORT" = "$LISA_API_PORT" ]; then LISA_API_PORT=$NEW_PORT; fi
    fi
done
HTTP_PORT=${HTTP_PORT:-80}
HTTPS_PORT=${HTTPS_PORT:-443}

# Sauvegarder les ports dans lisa.conf
echo "LISA_API_PORT="$LISA_API_PORT"" >> "$CONF_FILE"
echo "HTTP_PORT="$HTTP_PORT""         >> "$CONF_FILE"
echo "HTTPS_PORT="$HTTPS_PORT""       >> "$CONF_FILE"
echo "FW_TYPE=\"$FW_TYPE\""             >> "$CONF_FILE"

# Snapshot de l'état du pare-feu AVANT modification
FW_SNAPSHOT="$STACK_DIR/.firewall_snapshot"
info "Sauvegarde de l'état du pare-feu..."
case "$FW_TYPE" in
    ufw)
        _sudo ufw status numbered > "$FW_SNAPSHOT" 2>/dev/null
        _trace "firewall_snapshot" "$FW_SNAPSHOT"
        ;;
    firewalld)
        _sudo firewall-cmd --list-all > "$FW_SNAPSHOT" 2>/dev/null
        _trace "firewall_snapshot" "$FW_SNAPSHOT"
        ;;
    iptables)
        _sudo iptables-save > "$FW_SNAPSHOT" 2>/dev/null
        _trace "firewall_snapshot" "$FW_SNAPSHOT"
        ;;
esac
[ -f "$FW_SNAPSHOT" ] && success "Snapshot pare-feu sauvegardé."

# Appliquer les règles selon le pare-feu détecté
case "$FW_TYPE" in
    ufw)
        # Ajouter uniquement les règles L.I.S.A. sans reset
        if [ "$EXPOSE_INTERNET" = "true" ]; then
            _sudo ufw allow ${HTTP_PORT}/tcp  > /dev/null 2>&1
            _sudo ufw allow ${HTTPS_PORT}/tcp > /dev/null 2>&1
            success "UFW : ports $HTTP_PORT et $HTTPS_PORT ouverts."
        else
            _sudo ufw allow from 127.0.0.1 to any port $LISA_API_PORT > /dev/null 2>&1
            success "UFW : API accessible sur 127.0.0.1:$LISA_API_PORT"
        fi
        ;;
    firewalld)
        if [ "$EXPOSE_INTERNET" = "true" ]; then
            _sudo firewall-cmd --permanent --add-port=${HTTP_PORT}/tcp  > /dev/null 2>&1
            _sudo firewall-cmd --permanent --add-port=${HTTPS_PORT}/tcp > /dev/null 2>&1
            _sudo firewall-cmd --reload > /dev/null 2>&1
            success "firewalld : ports $HTTP_PORT et $HTTPS_PORT ouverts."
        else
            _sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=127.0.0.1 port port=$LISA_API_PORT protocol=tcp accept" > /dev/null 2>&1
            _sudo firewall-cmd --reload > /dev/null 2>&1
            success "firewalld : API accessible sur 127.0.0.1:$LISA_API_PORT"
        fi
        ;;
    iptables)
        if [ "$EXPOSE_INTERNET" = "true" ]; then
            _sudo iptables -A INPUT -p tcp --dport $HTTP_PORT  -j ACCEPT 2>/dev/null
            _sudo iptables -A INPUT -p tcp --dport $HTTPS_PORT -j ACCEPT 2>/dev/null
            success "iptables : ports $HTTP_PORT et $HTTPS_PORT ouverts."
        else
            _sudo iptables -A INPUT -p tcp -s 127.0.0.1 --dport $LISA_API_PORT -j ACCEPT 2>/dev/null
            success "iptables : API accessible sur 127.0.0.1:$LISA_API_PORT"
        fi
        ;;
    none)
        # Aucun pare-feu — installer UFW minimal
        info "Aucun pare-feu actif — installation de UFW..."
        _sudo apt-get install -y ufw -qq
        _sudo ufw default deny incoming  > /dev/null 2>&1
        _sudo ufw default allow outgoing > /dev/null 2>&1
        _sudo ufw allow ssh              > /dev/null 2>&1
        if [ "$EXPOSE_INTERNET" = "true" ]; then
            _sudo ufw allow ${HTTP_PORT}/tcp  > /dev/null 2>&1
            _sudo ufw allow ${HTTPS_PORT}/tcp > /dev/null 2>&1
        else
            _sudo ufw allow from 127.0.0.1 to any port $LISA_API_PORT > /dev/null 2>&1
        fi
        _sudo ufw --force enable > /dev/null 2>&1
        success "UFW installé et configuré."
        ;;
esac

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

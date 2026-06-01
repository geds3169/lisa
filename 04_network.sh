#!/bin/bash
# ===================================================================================
# L.I.S.A — 04_network.sh
# Caddy (domaine unique + chemins), DuckDNS DDNS, Authelia
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
LOG_FILE="$STACK_DIR/lisa_install.log"

[ ! -f "$CONF_FILE" ] && { error "lisa.conf introuvable."; exit 1; }
source "$CONF_FILE"

_get_pass() {
    openssl enc -d -aes-256-cbc -pbkdf2 \
        -pass pass:"$(cat "$STACK_DIR/.lisa_pass.key")" \
        -in "$STACK_DIR/.lisa_pass.gpg" 2>/dev/null
}

# Récupération token DuckDNS depuis .env.gpg
DUCKDNS_TOKEN=""
ENV_KEY=$(cat "$STACK_DIR/.env.key" 2>/dev/null)
if [ -f "$STACK_DIR/.env.gpg" ] && [ -n "$ENV_KEY" ]; then
    DUCKDNS_TOKEN=$(openssl enc -d -aes-256-cbc -pbkdf2 \
        -pass pass:"$ENV_KEY" -in "$STACK_DIR/.env.gpg" 2>/dev/null \
        | grep "^DUCKDNS_TOKEN=" | cut -d'=' -f2-)
fi

AUTHELIA_PASS=""
if [ -f "$STACK_DIR/.env.gpg" ] && [ -n "$ENV_KEY" ]; then
    AUTHELIA_PASS=$(openssl enc -d -aes-256-cbc -pbkdf2 \
        -pass pass:"$ENV_KEY" -in "$STACK_DIR/.env.gpg" 2>/dev/null \
        | grep "^AUTHELIA_PASS=" | cut -d'=' -f2-)
fi

# ===================================================================================
# GÉNÉRATION CADDYFILE — domaine unique, services par chemin
# ===================================================================================
section "Génération du Caddyfile"

mkdir -p "$STACK_DIR/caddy"

AUTHELIA_SNIPPET=""
if [ "$AUTHELIA_ENABLED" = "true" ]; then
    AUTHELIA_SNIPPET="
    forward_auth authelia:9091 {
        uri /api/verify?rd=https://${LISA_DOMAIN}
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }"
fi

cat > "$STACK_DIR/caddy/Caddyfile" << CADDYEOF
# L.I.S.A. Caddyfile — généré le $(date '+%Y-%m-%d %H:%M:%S')
# Domaine unique : ${LISA_DOMAIN}
# Services accessibles par chemin

{
    admin off
    $([ "$DOMAIN_TYPE" = "duckdns" ] && echo "# DuckDNS DNS challenge géré par le container ddns")
}

${LISA_DOMAIN} {
    $([ "$DOMAIN_TYPE" = "duckdns" ] && echo "tls {
        dns duckdns $DUCKDNS_TOKEN
    }")

    ${AUTHELIA_SNIPPET}

    # API principale
    handle /api* {
        uri strip_prefix /api
        reverse_proxy lisa_api:8000
    }

    # LLM (Ollama)
    handle /llm* {
        uri strip_prefix /llm
        reverse_proxy lisa_llm:11434
    }

    # STT (Whisper)
    handle /stt* {
        uri strip_prefix /stt
        reverse_proxy lisa_stt:8080
    }

    # TTS (Piper)
    handle /tts* {
        uri strip_prefix /tts
        reverse_proxy lisa_tts:5500
    }

    # RAG (Qdrant)
    handle /rag* {
        uri strip_prefix /rag
        reverse_proxy lisa_rag:6333
    }

    # Search (SearXNG)
    handle /search* {
        uri strip_prefix /search
        reverse_proxy lisa_search:8888
    }

    # Racine → API
    handle {
        reverse_proxy lisa_api:8000
    }

    log {
        output file /var/log/caddy/lisa.log
    }
}
CADDYEOF

success "Caddyfile généré (domaine unique : $LISA_DOMAIN)"

# ===================================================================================
# AUTHELIA
# ===================================================================================
if [ "$AUTHELIA_ENABLED" = "true" ]; then
    section "Configuration Authelia"

    AUTHELIA_PASS_HASH=$(docker run --rm authelia/authelia:latest \
        authelia crypto hash generate argon2 \
        --password "$AUTHELIA_PASS" 2>/dev/null | grep "Digest:" | awk '{print $2}')

    mkdir -p "$STACK_DIR/authelia"

    cat > "$STACK_DIR/authelia/configuration.yml" << AUTHELIAEOF
---
theme: dark
jwt_secret: $(openssl rand -hex 32)
default_redirection_url: https://${LISA_DOMAIN}

server:
  host: 0.0.0.0
  port: 9091

log:
  level: info

totp:
  issuer: lisa.local

authentication_backend:
  file:
    path: /config/users_database.yml

access_control:
  default_policy: deny
  rules:
    - domain: "${LISA_DOMAIN}"
      policy: one_factor

session:
  name: lisa_session
  secret: $(openssl rand -hex 32)
  expiration: 3600
  inactivity: 300
  domain: ${DOMAIN}

storage:
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notification.txt
AUTHELIAEOF

    cat > "$STACK_DIR/authelia/users_database.yml" << USERSEOF
---
users:
  ${AUTHELIA_USER:-admin}:
    displayname: "${AUTHELIA_USER:-Admin} L.I.S.A."
    password: "${AUTHELIA_PASS_HASH}"
    email: ${AUTHELIA_USER:-admin}@localhost
    groups:
      - admins
USERSEOF

    success "Authelia configurée (utilisateur : ${AUTHELIA_USER:-admin})"
fi

# ===================================================================================
# DDNS DUCKDNS
# ===================================================================================
if [ "$DOMAIN_TYPE" = "duckdns" ] && [ -n "$DUCKDNS_TOKEN" ]; then
    section "Configuration DuckDNS DDNS"

    # Extraire le nom sans .duckdns.org
    DUCK_NAME="${LISA_DOMAIN%.duckdns.org}"

    # Ajouter le service DDNS au compose
    cat >> "$STACK_DIR/docker-compose.yml" << DDNSEOF

  ddns:
    image: lscr.io/linuxserver/duckdns:latest
    container_name: lisa_ddns
    networks:
      - lisa_external
    environment:
      - SUBDOMAINS=${DUCK_NAME}
      - TOKEN=${DUCKDNS_TOKEN}
      - LOG_FILE=true
    restart: unless-stopped
    mem_limit: 64m
DDNSEOF

    docker compose -f "$STACK_DIR/docker-compose.yml" up -d ddns 2>/dev/null
    success "Container DDNS DuckDNS démarré ($DUCK_NAME.duckdns.org)"

    # Première mise à jour immédiate
    PUBLIC_IP=$(curl -s https://ifconfig.me 2>/dev/null)
    TEST=$(curl -s "https://www.duckdns.org/update?domains=${DUCK_NAME}&token=${DUCKDNS_TOKEN}&ip=${PUBLIC_IP}")
    [ "$TEST" = "OK" ] \
        && success "IP publique ($PUBLIC_IP) mise à jour sur DuckDNS." \
        || warn "Mise à jour DuckDNS : $TEST"

    # Message si convention non suivie
    if [ "$NAMING_CONVENTION" = "false" ]; then
        echo ""
        warn "Vous n'avez pas suivi la convention de nommage recommandée."
        warn "En cas d'échec réseau, cela pourrait en être la cause."
        warn "Convention recommandée : lisa-XXXX.duckdns.org"
    fi
fi

# ===================================================================================
# DÉMARRAGE CADDY ET AUTHELIA
# ===================================================================================
section "Démarrage reverse proxy"

cd "$STACK_DIR"

[ "$AUTHELIA_ENABLED" = "true" ] && {
    info "Démarrage Authelia..."
    docker compose up -d authelia
    sleep 5
}

info "Démarrage Caddy..."
docker compose up -d caddy

for i in $(seq 1 12); do
    if curl -sk "https://${LISA_DOMAIN}" >/dev/null 2>&1 || \
       curl -s "http://${LISA_DOMAIN}" >/dev/null 2>&1; then
        success "Caddy opérationnel."
        break
    fi
    info "  Caddy démarrage ($i/12)..."
    sleep 5
done

# ===================================================================================
# RÉCAP RÉSEAU
# ===================================================================================
echo ""
echo -e "${CYAN}━━━ Accès L.I.S.A. depuis internet ━━━${RESET}"
echo -e "  ${GREEN}Accès principal :${RESET} ${BLUE}https://${LISA_DOMAIN}${RESET}"
echo -e "  ${GREEN}API             :${RESET} ${BLUE}https://${LISA_DOMAIN}/api${RESET}"
echo -e "  ${GREEN}Cerveau IA      :${RESET} ${BLUE}https://${LISA_DOMAIN}/llm${RESET}"
echo -e "  ${GREEN}Voix entrée     :${RESET} ${BLUE}https://${LISA_DOMAIN}/stt${RESET}"
echo -e "  ${GREEN}Voix sortie     :${RESET} ${BLUE}https://${LISA_DOMAIN}/tts${RESET}"
echo -e "  ${GREEN}Mémoire         :${RESET} ${BLUE}https://${LISA_DOMAIN}/rag${RESET}"
echo -e "  ${GREEN}Recherche web   :${RESET} ${BLUE}https://${LISA_DOMAIN}/search${RESET}"
[ "$AUTHELIA_ENABLED" = "true" ] && \
    echo -e "\n  ${YELLOW}Authentification requise — utilisateur : ${AUTHELIA_USER:-admin}${RESET}"
[ "$DOMAIN_TYPE" = "duckdns" ] && \
    warn "DuckDNS : la propagation DNS peut prendre quelques minutes."
[ "$NAMING_CONVENTION" = "false" ] && \
    warn "Convention non suivie — en cas d'échec, reconfigurer avec la nomenclature recommandée."

echo "NETWORK_DONE" > "$STATE_FILE"
success "Configuration réseau terminée."

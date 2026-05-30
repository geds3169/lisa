#!/bin/bash
# ===================================================================================
# L.I.S.A — 04_network.sh
# Caddy (reverse proxy + TLS auto), DuckDNS DDNS, Authelia
# Appelé par 03_run_stack.sh si EXPOSE_INTERNET=true
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

exec >> "$LOG_FILE" 2>&1

[ ! -f "$CONF_FILE" ] && { error "lisa.conf introuvable."; exit 1; }
source "$CONF_FILE"

# --- Décryptage token DuckDNS si besoin ---
_get_pass() { openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$(cat "$STACK_DIR/.lisa_pass.key")" -in "$STACK_DIR/.lisa_pass.gpg" 2>/dev/null; }
_sudo() { echo "$(_get_pass)" | sudo -S "$@" 2>/dev/null; }

# Récupération token DuckDNS depuis .env.gpg
DUCKDNS_TOKEN=""
if [ -f "$STACK_DIR/.env.gpg" ] && [ -n "$GPG_KEY_ID" ]; then
    DUCKDNS_TOKEN=$(gpg --batch --quiet -d "$STACK_DIR/.env.gpg" 2>/dev/null | grep "^DUCKDNS_TOKEN=" | cut -d'=' -f2-)
fi

# ===================================================================================
# GÉNÉRATION CADDYFILE
# ===================================================================================
section "Génération du Caddyfile"

_get_domain() {
    local SVC="$1"
    if [ "$DOMAIN_TYPE" = "duckdns" ]; then
        echo "lisa-${SVC}-${DUCKDNS_SUFFIX}.duckdns.org"
    elif [ "$DOMAIN_TYPE" = "custom" ]; then
        echo "${SVC}.${DOMAIN}"
    else
        echo "localhost"
    fi
}

AUTHELIA_SNIPPET=""
if [ "$AUTHELIA_ENABLED" = "true" ]; then
    AUTHELIA_SNIPPET='
    forward_auth authelia:9091 {
        uri /api/verify?rd=https://auth.'"$([ "$DOMAIN_TYPE" = "duckdns" ] && echo "lisa-api-${DUCKDNS_SUFFIX}.duckdns.org" || echo "${DOMAIN}")"'
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }'
fi

{
cat << CADDYEOF
# L.I.S.A. Caddyfile — généré le $(date '+%Y-%m-%d %H:%M:%S')
# Modifiable manuellement puis : docker compose restart caddy

{
    email lisa@localhost
    admin off
}

# API principale
$(_get_domain "api") {
    tls {
        $([ "$DOMAIN_TYPE" = "duckdns" ] && echo "dns duckdns $DUCKDNS_TOKEN" || echo "")
    }
    ${AUTHELIA_SNIPPET}
    reverse_proxy lisa_api:8000
    log {
        output file /var/log/caddy/api.log
    }
}

# LLM (Ollama) — accès restreint
$(_get_domain "llm") {
    tls {
        $([ "$DOMAIN_TYPE" = "duckdns" ] && echo "dns duckdns $DUCKDNS_TOKEN" || echo "")
    }
    ${AUTHELIA_SNIPPET}
    reverse_proxy lisa_llm:11434
}

# STT
$(_get_domain "stt") {
    tls {
        $([ "$DOMAIN_TYPE" = "duckdns" ] && echo "dns duckdns $DUCKDNS_TOKEN" || echo "")
    }
    ${AUTHELIA_SNIPPET}
    reverse_proxy lisa_stt:8080
}

# TTS
$(_get_domain "tts") {
    tls {
        $([ "$DOMAIN_TYPE" = "duckdns" ] && echo "dns duckdns $DUCKDNS_TOKEN" || echo "")
    }
    ${AUTHELIA_SNIPPET}
    reverse_proxy lisa_tts:5500
}

CADDYEOF

# RAG conditionnel
if [ "$RAG_ENABLED" = "true" ]; then
cat << RAGEOF

# RAG (Qdrant)
$(_get_domain "rag") {
    tls {
        $([ "$DOMAIN_TYPE" = "duckdns" ] && echo "dns duckdns $DUCKDNS_TOKEN" || echo "")
    }
    ${AUTHELIA_SNIPPET}
    reverse_proxy lisa_rag:6333
}
RAGEOF
fi

# SearXNG conditionnel
if [ "$WEB_SEARCH_ENABLED" = "true" ]; then
cat << SEARCHEOF

# Search (SearXNG)
$(_get_domain "search") {
    tls {
        $([ "$DOMAIN_TYPE" = "duckdns" ] && echo "dns duckdns $DUCKDNS_TOKEN" || echo "")
    }
    ${AUTHELIA_SNIPPET}
    reverse_proxy lisa_search:8888
}
SEARCHEOF
fi

} > "$STACK_DIR/caddy/Caddyfile"

success "Caddyfile généré."

# ===================================================================================
# CONFIGURATION AUTHELIA
# ===================================================================================
if [ "$AUTHELIA_ENABLED" = "true" ]; then
    section "Configuration Authelia"

    AUTHELIA_PASS=$(gpg --batch --quiet -d "$STACK_DIR/.env.gpg" 2>/dev/null | grep "^AUTHELIA_PASS=" | cut -d'=' -f2-)
    AUTHELIA_PASS_HASH=$(docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "$AUTHELIA_PASS" 2>/dev/null | grep "Digest:" | awk '{print $2}')

    mkdir -p "$STACK_DIR/authelia"

    cat > "$STACK_DIR/authelia/configuration.yml" << AUTHELIAEOF
---
theme: dark
jwt_secret: $(openssl rand -hex 32)
default_redirection_url: https://$(_get_domain "api")

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
    - domain:
        - "$(_get_domain "api")"
        - "$(_get_domain "llm")"
        - "$(_get_domain "stt")"
        - "$(_get_domain "tts")"
        $([ "$RAG_ENABLED" = "true" ] && echo "- \"$(_get_domain 'rag')\"")
        $([ "$WEB_SEARCH_ENABLED" = "true" ] && echo "- \"$(_get_domain 'search')\"")
      policy: one_factor

session:
  name: lisa_session
  secret: $(openssl rand -hex 32)
  expiration: 3600
  inactivity: 300
  domain: $DOMAIN

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
# DDNS DUCKDNS — container de mise à jour automatique
# ===================================================================================
if [ "$DOMAIN_TYPE" = "duckdns" ] && [ -n "$DUCKDNS_TOKEN" ]; then
    section "Configuration DuckDNS DDNS"

    # Liste des sous-domaines à mettre à jour
    DUCK_DOMAINS=""
    for SVC in api llm stt tts; do
        DUCK_DOMAINS="${DUCK_DOMAINS}lisa-${SVC}-${DUCKDNS_SUFFIX},"
    done
    [ "$RAG_ENABLED" = "true" ] && DUCK_DOMAINS="${DUCK_DOMAINS}lisa-rag-${DUCKDNS_SUFFIX},"
    [ "$WEB_SEARCH_ENABLED" = "true" ] && DUCK_DOMAINS="${DUCK_DOMAINS}lisa-search-${DUCKDNS_SUFFIX},"
    DUCK_DOMAINS="${DUCK_DOMAINS%,}"  # supprimer la virgule finale

    # Ajout du service DDNS au compose existant
    cat >> "$STACK_DIR/docker-compose.yml" << DDNSEOF

  ddns:
    image: lscr.io/linuxserver/duckdns:latest
    container_name: lisa_ddns
    networks:
      - lisa_external
    environment:
      - SUBDOMAINS=${DUCK_DOMAINS}
      - TOKEN=${DUCKDNS_TOKEN}
      - LOG_FILE=true
    restart: unless-stopped
    mem_limit: 64m
DDNSEOF

    # Démarrage du container DDNS
    docker compose up -d ddns
    success "Container DDNS DuckDNS démarré."
    info "Sous-domaines mis à jour : $DUCK_DOMAINS"

    # Première mise à jour immédiate
    PUBLIC_IP=$(curl -s https://ifconfig.me 2>/dev/null)
    UPDATE_RESULT=$(curl -s "https://www.duckdns.org/update?domains=${DUCK_DOMAINS}&token=${DUCKDNS_TOKEN}&ip=${PUBLIC_IP}")
    if [ "$UPDATE_RESULT" = "OK" ]; then
        success "IP publique ($PUBLIC_IP) mise à jour sur DuckDNS."
    else
        warn "Mise à jour DuckDNS initiale : $UPDATE_RESULT"
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

# Health check Caddy
for i in $(seq 1 12); do
    if curl -sk "https://localhost" >/dev/null 2>&1 || curl -s "http://localhost" >/dev/null 2>&1; then
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
echo -e "${CYAN}━━━ Accès externes L.I.S.A. ━━━${RESET}"
for SVC in api llm stt tts; do
    DOM=$(_get_domain "$SVC")
    echo -e "  ${GREEN}$SVC${RESET} → ${BLUE}https://$DOM${RESET}"
done
[ "$RAG_ENABLED" = "true" ] && echo -e "  ${GREEN}rag${RESET}    → ${BLUE}https://$(_get_domain 'rag')${RESET}"
[ "$WEB_SEARCH_ENABLED" = "true" ] && echo -e "  ${GREEN}search${RESET} → ${BLUE}https://$(_get_domain 'search')${RESET}"
[ "$AUTHELIA_ENABLED" = "true" ] && echo -e "\n  ${YELLOW}Authentification requise — utilisateur : ${AUTHELIA_USER:-admin}${RESET}"

if [ "$DOMAIN_TYPE" = "duckdns" ]; then
    echo ""
    warn "DuckDNS : la propagation DNS peut prendre quelques minutes."
    warn "Si les adresses ne répondent pas immédiatement, attendez 5 minutes."
fi

echo "NETWORK_DONE" > "$STATE_FILE"
success "Configuration réseau terminée."

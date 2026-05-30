#!/bin/bash
# ===================================================================================
# L.I.S.A — Local Intelligent System Assistant
# 00_config.sh — Configuration interactive, détection système, secrets GPG
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
ask() { echo -ne "${YELLOW}[?]${RESET} $1 "; }

STACK_DIR="$HOME/ai-stack"
CONF_FILE="$STACK_DIR/lisa.conf"
ENV_PLAIN="$STACK_DIR/.env.plain"
ENV_ENC="$STACK_DIR/.env.gpg"
PASS_ENC="$STACK_DIR/.lisa_pass.gpg"
PASS_KEY="$STACK_DIR/.lisa_pass.key"
STATE_FILE="$STACK_DIR/.lisa_state"
LOG_FILE="$STACK_DIR/lisa_install.log"

mkdir -p "$STACK_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ===================================================================================
# MODE RECONFIGURE
# ===================================================================================
if [[ "$1" == "--reconfigure" ]]; then
    warn "Mode reconfiguration — les secrets existants seront remplacés."
    ask "Confirmer la reconfiguration ? [o/N] :" ; read -r RECONF
    [[ ! "$RECONF" =~ ^[Oo]$ ]] && { info "Annulé." ; exit 0; }
    rm -f "$CONF_FILE" "$ENV_ENC" "$ENV_PLAIN"
    sed -i '/^LISA_/d' "$HOME/.bashrc" 2>/dev/null
fi

# ===================================================================================
# TRAP — nettoyage sur interruption ou erreur fatale
# ===================================================================================
cleanup_on_exit() {
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -ne 0 ]; then
        warn "Interruption détectée — suppression des fichiers sensibles..."
        rm -f "$ENV_PLAIN" "$PASS_ENC" "$PASS_KEY"
        # Suppression du marqueur pour forcer relance propre
        rm -f "$STATE_FILE"
        error "Installation interrompue. Aucun secret conservé."
    fi
}
trap cleanup_on_exit EXIT
trap 'exit 1' INT TERM

# ===================================================================================
# BANNER
# ===================================================================================
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
  Stack IA locale — Configuration
BANNER
echo -e "${RESET}"
info "Durée estimée : 5 à 10 minutes selon vos choix."
echo ""
sleep 1

# ===================================================================================
# VÉRIFICATION ARCHITECTURE
# ===================================================================================
section "Détection de l'architecture"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        PLATFORM="linux/amd64"
        ARCH_LABEL="x86_64 (AMD64)"
        success "Architecture : $ARCH_LABEL — support complet."
        ;;
    aarch64|arm64)
        PLATFORM="linux/arm64"
        ARCH_LABEL="ARM64"
        warn "Architecture : $ARCH_LABEL — support actif, RAM minimum 8GB recommandée."
        ;;
    *)
        error "Architecture $ARCH non supportée. x86_64 et ARM64 uniquement."
        exit 1
        ;;
esac

# ===================================================================================
# VÉRIFICATION OS
# ===================================================================================
section "Système d'exploitation"

if [[ "$(uname -s)" != "Linux" ]]; then
    error "Linux requis. Le HUD L.I.S.A. (Tauri) sera multiplateforme, pas la stack."
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    info "OS : $PRETTY_NAME"
    case "$ID" in
        ubuntu|debian|linuxmint|pop) success "Distribution supportée." ;;
        *) warn "Distribution $ID non testée. L'installation peut fonctionner." ;;
    esac
fi

# ===================================================================================
# RESSOURCES
# ===================================================================================
section "Ressources disponibles"

CPU_CORES=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$((RAM_KB / 1024 / 1024))
DISK_FREE=$(df -BG "$HOME" | awk 'NR==2{print $4}' | tr -d 'G')

info "CPU    : $CPU_CORES cœurs"
info "RAM    : ${RAM_GB} GB"
info "Disque : ${DISK_FREE} GB libres"

if [ "$RAM_GB" -lt 4 ]; then
    error "RAM insuffisante : ${RAM_GB}GB. Minimum requis : 4GB."
    exit 1
elif [ "$RAM_GB" -lt 8 ]; then
    warn "RAM limitée — profil léger activé."
    RAM_PROFILE="low"
elif [ "$RAM_GB" -lt 16 ]; then
    info "Profil RAM moyen — configuration standard."
    RAM_PROFILE="medium"
else
    success "Profil RAM élevé — configuration complète."
    RAM_PROFILE="high"
fi

[ "$DISK_FREE" -lt 20 ] && warn "Espace disque faible (${DISK_FREE}GB). Minimum recommandé : 20GB."

# Détection GPU
GPU_TYPE="none"
GPU_LABEL="Aucun GPU — mode CPU"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    GPU_LABEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    GPU_TYPE="nvidia"
    success "GPU NVIDIA : $GPU_LABEL"
elif lspci 2>/dev/null | grep -qi "amd\|radeon"; then
    GPU_LABEL="AMD GPU (ROCm non auto-configuré — CPU fallback)"
    GPU_TYPE="amd"
    info "$GPU_LABEL"
else
    info "$GPU_LABEL"
fi

# ===================================================================================
# DÉPENDANCES BOOTSTRAP
# ===================================================================================
section "Installation des dépendances"

for PKG in tmux jq gnupg2 curl; do
    if ! command -v "$PKG" &>/dev/null; then
        info "$PKG manquant, installation..."
        sudo apt-get install -y "$PKG" -qq && success "$PKG installé." || warn "Échec installation $PKG."
    else
        success "$PKG présent."
    fi
done

# ===================================================================================
# MOT DE PASSE SYSTÈME (chiffré, supprimé à la fin)
# ===================================================================================
section "Authentification système"

echo -e "${YELLOW}L.I.S.A. a besoin de votre mot de passe pour :${RESET}"
echo -e "  - Installer les paquets système"
echo -e "  - Configurer Docker et les groupes"
echo -e "  - Configurer le pare-feu"
echo -e "${YELLOW}Ce mot de passe sera chiffré localement et supprimé automatiquement${RESET}"
echo -e "${YELLOW}dès la fin de l'installation ou en cas d'interruption.${RESET}"
echo ""

# Génération d'une clé symétrique éphémère
EPHEMERAL_KEY=$(openssl rand -hex 32)
echo "$EPHEMERAL_KEY" > "$PASS_KEY"
chmod 600 "$PASS_KEY"

ask "Mot de passe sudo :" ; read -r -s SYS_PASS ; echo ""

# Chiffrement du mot de passe avec la clé éphémère
echo "$SYS_PASS" | openssl enc -aes-256-cbc -pbkdf2 -pass pass:"$EPHEMERAL_KEY" -out "$PASS_ENC"
chmod 600 "$PASS_ENC"
unset SYS_PASS

# Vérification que le mot de passe est correct
_get_pass() {
    openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$(cat "$PASS_KEY")" -in "$PASS_ENC" 2>/dev/null
}

if ! echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1; then
    error "Mot de passe incorrect."
    exit 1
fi
success "Authentification validée."

# Keepalive sudo en arrière-plan (toutes les 4 min)
(while true; do
    echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1
    sleep 240
done) &
SUDO_KEEPALIVE_PID=$!
echo "$SUDO_KEEPALIVE_PID" > "$STACK_DIR/.sudo_keepalive.pid"

# ===================================================================================
# GPG POUR CHIFFREMENT DU .ENV
# ===================================================================================
section "Configuration GPG"

GPG_KEY_ID=""
EXISTING_KEY=$(gpg --list-secret-keys --keyid-format LONG 2>/dev/null | grep "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)

if [ -n "$EXISTING_KEY" ]; then
    success "Clé GPG existante : $EXISTING_KEY"
    ask "Utiliser cette clé pour chiffrer les secrets L.I.S.A. ? [O/n] :" ; read -r USE_EXISTING
    [[ ! "$USE_EXISTING" =~ ^[Nn]$ ]] && GPG_KEY_ID="$EXISTING_KEY"
fi

if [ -z "$GPG_KEY_ID" ]; then
    info "Génération d'une clé GPG L.I.S.A. (Ed25519, 2 ans)..."
    gpg --batch --gen-key <<EOF 2>/dev/null
Key-Type: EDDSA
Key-Curve: Ed25519
Subkey-Type: ECDH
Subkey-Curve: Curve25519
Name-Real: LISA Stack
Name-Email: lisa@localhost
Expire-Date: 2y
%no-protection
%commit
EOF
    GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format LONG "lisa@localhost" 2>/dev/null | grep "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)
    success "Clé GPG générée : $GPG_KEY_ID"
fi

# ===================================================================================
# RÉSEAU ET EXPOSITION INTERNET
# ===================================================================================
section "Configuration réseau"

ask "Exposer L.I.S.A. sur internet ? [o/N] :" ; read -r EXPOSE_INTERNET
EXPOSE_INTERNET=${EXPOSE_INTERNET:-N}

DOMAIN_TYPE="none" ; DOMAIN="" ; DUCKDNS_TOKEN="" ; DUCKDNS_SUFFIX=""
AUTHELIA_ENABLED="false" ; AUTHELIA_USER="" ; AUTHELIA_PASS=""

if [[ "$EXPOSE_INTERNET" =~ ^[Oo]$ ]]; then
    echo ""
    echo -e "${CYAN}Type de domaine :${RESET}"
    echo -e "  ${GREEN}[1]${RESET} Domaine personnel existant"
    echo -e "  ${GREEN}[2]${RESET} Sous-domaine DuckDNS gratuit (recommandé si pas de domaine)"
    echo -e "  ${GREEN}[3]${RESET} IP publique directe (certificat auto-signé)"
    ask "Choix [1/2/3] :" ; read -r DNS_CHOICE

    case "$DNS_CHOICE" in
        1)
            DOMAIN_TYPE="custom"
            ask "Nom de domaine (ex: mondomaine.fr) :" ; read -r DOMAIN
            DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's|^https\?://||')
            info "Sous-domaines qui seront créés :"
            for SVC in llm stt tts rag api search; do
                echo -e "  ${CYAN}${SVC}.${DOMAIN}${RESET}"
            done
            warn "Pointez vos DNS vers l'IP publique de cette machine avant de continuer."
            warn "Si vous avez un certificat existant, consultez le README pour l'ajouter."
            ;;
        2)
            DOMAIN_TYPE="duckdns"
            echo ""
            echo -e "${CYAN}Configuration DuckDNS :${RESET}"
            echo -e "${YELLOW}1. Créez un compte sur ${BLUE}https://www.duckdns.org${RESET}"
            echo -e "${YELLOW}2. Créez 6 sous-domaines avec un suffixe numérique unique :${RESET}"
            for SVC in llm stt tts rag api search; do
                echo -e "   ${CYAN}lisa-${SVC}-XXXX.duckdns.org${RESET}"
            done
            echo -e "${YELLOW}   Conseil : choisissez un suffixe à 4 chiffres non devinable (ex: 4827)${RESET}"
            echo -e "${YELLOW}   Si le sous-domaine est déjà pris, essayez une autre combinaison.${RESET}"
            echo -e "${YELLOW}3. Récupérez votre token sur le tableau de bord DuckDNS.${RESET}"
            echo ""
            ask "Appuyez sur Entrée une fois vos sous-domaines créés..." ; read -r

            ask "Votre token DuckDNS :" ; read -r -s DUCKDNS_TOKEN ; echo ""
            ask "Votre suffixe numérique (ex: 4827) :" ; read -r DUCKDNS_SUFFIX

            # Validation token
            TEST_RESULT=$(curl -s "https://www.duckdns.org/update?domains=lisa-api-${DUCKDNS_SUFFIX}&token=${DUCKDNS_TOKEN}&ip=")
            if [[ "$TEST_RESULT" == "OK" ]]; then
                success "Token DuckDNS validé."
            else
                warn "Validation DuckDNS impossible (réseau ?). Le token sera utilisé tel quel."
            fi
            DOMAIN="duckdns.org"
            ;;
        3)
            DOMAIN_TYPE="ip"
            PUBLIC_IP=$(curl -s https://ifconfig.me 2>/dev/null || echo "inconnue")
            info "IP publique : $PUBLIC_IP"
            warn "Caddy générera un certificat auto-signé. Les navigateurs afficheront un avertissement."
            DOMAIN="$PUBLIC_IP"
            ;;
        *)
            warn "Choix invalide — exposition internet désactivée."
            EXPOSE_INTERNET="N"
            ;;
    esac

    if [[ "$EXPOSE_INTERNET" =~ ^[Oo]$ ]]; then
        echo ""
        ask "Activer l'authentification Authelia (accès protégé par login) ? [O/n] :" ; read -r ENABLE_AUTH
        if [[ ! "$ENABLE_AUTH" =~ ^[Nn]$ ]]; then
            AUTHELIA_ENABLED="true"
            ask "Nom d'utilisateur admin :" ; read -r AUTHELIA_USER
            ask "Mot de passe admin :" ; read -r -s AUTHELIA_PASS ; echo ""
            success "Authelia activée."
        fi
    fi
fi

# ===================================================================================
# LLM
# ===================================================================================
section "Modèle LLM"

echo -e "${CYAN}Mode LLM :${RESET}"
echo -e "  ${GREEN}[1]${RESET} Local via Ollama (recommandé — 100% privé)"
echo -e "  ${GREEN}[2]${RESET} API externe"
echo -e "  ${GREEN}[3]${RESET} Les deux (local par défaut, API en fallback)"
ask "Choix [1/2/3] :" ; read -r LLM_MODE ; LLM_MODE=${LLM_MODE:-1}

LLM_API_KEY="" ; LLM_PROVIDER="local" ; LLM_MODEL_LOCAL=""

if [[ "$LLM_MODE" =~ ^[13]$ ]]; then
    echo ""
    info "Modèles disponibles pour votre profil RAM (${RAM_GB}GB — profil $RAM_PROFILE) :"
    case "$RAM_PROFILE" in
        low)
            echo -e "  ${GREEN}[1]${RESET} phi3     (3.8B — recommandé <8GB)"
            echo -e "  ${GREEN}[2]${RESET} tinyllama (1.1B — très léger)"
            ask "Choix [1/2] :" ; read -r MC
            LLM_MODEL_LOCAL=$([ "$MC" = "2" ] && echo "tinyllama" || echo "phi3")
            ;;
        medium)
            echo -e "  ${GREEN}[1]${RESET} llama3.2  (3B — bon équilibre)"
            echo -e "  ${GREEN}[2]${RESET} mistral   (7B — qualité supérieure)"
            echo -e "  ${GREEN}[3]${RESET} phi3      (3.8B — léger)"
            ask "Choix [1/2/3] :" ; read -r MC
            case "$MC" in 2) LLM_MODEL_LOCAL="mistral" ;; 3) LLM_MODEL_LOCAL="phi3" ;; *) LLM_MODEL_LOCAL="llama3.2" ;; esac
            ;;
        high)
            echo -e "  ${GREEN}[1]${RESET} llama3.1:8b  (8B — haute qualité)"
            echo -e "  ${GREEN}[2]${RESET} mistral      (7B)"
            echo -e "  ${GREEN}[3]${RESET} mixtral      (47B — nécessite 32GB+)"
            echo -e "  ${GREEN}[4]${RESET} llama3.2     (3B — rapide)"
            ask "Choix [1/2/3/4] :" ; read -r MC
            case "$MC" in 2) LLM_MODEL_LOCAL="mistral" ;; 3) LLM_MODEL_LOCAL="mixtral" ;; 4) LLM_MODEL_LOCAL="llama3.2" ;; *) LLM_MODEL_LOCAL="llama3.1:8b" ;; esac
            ;;
    esac
    success "Modèle local : $LLM_MODEL_LOCAL"
fi

if [[ "$LLM_MODE" =~ ^[23]$ ]]; then
    LLM_PROVIDER=$(bash "$STACK_DIR/00_provider_select.sh" "llm")
    ask "Clé API $LLM_PROVIDER :" ; read -r -s LLM_API_KEY ; echo ""
fi

# ===================================================================================
# STT
# ===================================================================================
section "Speech-to-Text (STT)"

echo -e "  ${GREEN}[1]${RESET} Local via Whisper.cpp (recommandé — aucune donnée envoyée)"
echo -e "  ${GREEN}[2]${RESET} API externe"
ask "Choix [1/2] :" ; read -r STT_MODE ; STT_MODE=${STT_MODE:-1}

STT_API_KEY="" ; STT_PROVIDER="local"
if [[ "$STT_MODE" == "2" ]]; then
    STT_PROVIDER=$(bash "$STACK_DIR/00_provider_select.sh" "stt")
    ask "Clé API $STT_PROVIDER :" ; read -r -s STT_API_KEY ; echo ""
fi

# ===================================================================================
# TTS
# ===================================================================================
section "Text-to-Speech (TTS)"

echo -e "  ${GREEN}[1]${RESET} Local via Piper (recommandé — aucune donnée envoyée)"
echo -e "  ${GREEN}[2]${RESET} API externe"
ask "Choix [1/2] :" ; read -r TTS_MODE ; TTS_MODE=${TTS_MODE:-1}

TTS_API_KEY="" ; TTS_PROVIDER="local"
if [[ "$TTS_MODE" == "2" ]]; then
    TTS_PROVIDER=$(bash "$STACK_DIR/00_provider_select.sh" "tts")
    ask "Clé API $TTS_PROVIDER :" ; read -r -s TTS_API_KEY ; echo ""
fi

# ===================================================================================
# RAG
# ===================================================================================
section "RAG — Base de connaissances (Qdrant)"

ask "Activer le RAG ? [O/n] :" ; read -r ENABLE_RAG ; ENABLE_RAG=${ENABLE_RAG:-O}
RAG_ENABLED="false" ; RAG_API_KEY="" ; RAG_PROVIDER="local"

if [[ "$ENABLE_RAG" =~ ^[Oo]$ ]]; then
    RAG_ENABLED="true"
    echo -e "  ${GREEN}[1]${RESET} Local via Qdrant (gratuit — recommandé)"
    echo -e "  ${GREEN}[2]${RESET} Service cloud externe"
    ask "Choix [1/2] :" ; read -r RAG_MODE ; RAG_MODE=${RAG_MODE:-1}
    if [[ "$RAG_MODE" == "2" ]]; then
        RAG_PROVIDER=$(bash "$STACK_DIR/00_provider_select.sh" "rag")
        ask "Clé API $RAG_PROVIDER :" ; read -r -s RAG_API_KEY ; echo ""
    fi
    success "RAG activé."
fi

# ===================================================================================
# RECHERCHE WEB (SearXNG)
# ===================================================================================
section "Recherche web (SearXNG)"

ask "Activer la recherche internet ? [o/N] :" ; read -r ENABLE_SEARCH ; ENABLE_SEARCH=${ENABLE_SEARCH:-N}
WEB_SEARCH_ENABLED="false" ; WEB_SEARCH_DEFAULT="false"

if [[ "$ENABLE_SEARCH" =~ ^[Oo]$ ]]; then
    WEB_SEARCH_ENABLED="true"
    ask "Recherche active par défaut au démarrage ? [o/N] :" ; read -r SD ; SD=${SD:-N}
    [[ "$SD" =~ ^[Oo]$ ]] && WEB_SEARCH_DEFAULT="true"
    success "SearXNG activé — contrôlable via HUD (POST /config)."
fi

# ===================================================================================
# CLÉS API SUPPLÉMENTAIRES (widgets HUD)
# ===================================================================================
section "Services supplémentaires — widgets HUD"

ask "Configurer des clés API pour les widgets HUD ? [o/N] :" ; read -r EXTRA_APIS
declare -A EXTRA_KEYS

if [[ "$EXTRA_APIS" =~ ^[Oo]$ ]]; then
    while true; do
        echo ""
        echo -e "${CYAN}Catégories :${RESET}"
        echo -e "  ${GREEN}[1]${RESET} Météo   ${GREEN}[2]${RESET} Domotique   ${GREEN}[3]${RESET} Calendrier"
        echo -e "  ${GREEN}[4]${RESET} Notifications   ${GREEN}[5]${RESET} Recherche web   ${GREEN}[0]${RESET} Terminer"
        ask "Catégorie [0-5] :" ; read -r CAT_CHOICE
        [ "$CAT_CHOICE" = "0" ] && break
        case "$CAT_CHOICE" in
            1) CAT="meteo" ;; 2) CAT="domotique" ;; 3) CAT="calendrier" ;;
            4) CAT="notifications" ;; 5) CAT="search" ;;
            *) warn "Choix invalide." ; continue ;;
        esac
        PROV=$(bash "$STACK_DIR/00_provider_select.sh" "$CAT")
        ask "Clé API pour $PROV :" ; read -r -s EXTRA_KEY ; echo ""
        EXTRA_KEYS["${CAT}__${PROV}"]="$EXTRA_KEY"
        success "Clé enregistrée : $PROV"
    done
fi

# ===================================================================================
# ÉCRITURE lisa.conf
# ===================================================================================
section "Écriture de la configuration"

EXPOSE_BOOL="false"
[[ "$EXPOSE_INTERNET" =~ ^[Oo]$ ]] && EXPOSE_BOOL="true"

cat > "$CONF_FILE" << EOF
# ===================================================================================
# L.I.S.A. — Configuration générée le $(date '+%Y-%m-%d %H:%M:%S')
# Pour reconfigurer : bash $STACK_DIR/00_config.sh --reconfigure
# Fichier de clés API widgets : $STACK_DIR/.env.gpg (chiffré GPG)
# ===================================================================================

LISA_VERSION="1.0.0"
ARCH="$ARCH"
ARCH_LABEL="$ARCH_LABEL"
PLATFORM="$PLATFORM"
RAM_PROFILE="$RAM_PROFILE"
RAM_GB="$RAM_GB"
CPU_CORES="$CPU_CORES"
GPU_TYPE="$GPU_TYPE"
GPU_LABEL="$GPU_LABEL"

EXPOSE_INTERNET="$EXPOSE_BOOL"
DOMAIN_TYPE="$DOMAIN_TYPE"
DOMAIN="$DOMAIN"
DUCKDNS_SUFFIX="$DUCKDNS_SUFFIX"
AUTHELIA_ENABLED="$AUTHELIA_ENABLED"
AUTHELIA_USER="$AUTHELIA_USER"

LLM_MODE="$LLM_MODE"
LLM_MODEL_LOCAL="$LLM_MODEL_LOCAL"
LLM_PROVIDER="$LLM_PROVIDER"

STT_MODE="$STT_MODE"
STT_PROVIDER="$STT_PROVIDER"

TTS_MODE="$TTS_MODE"
TTS_PROVIDER="$TTS_PROVIDER"

RAG_ENABLED="$RAG_ENABLED"
RAG_PROVIDER="$RAG_PROVIDER"

WEB_SEARCH_ENABLED="$WEB_SEARCH_ENABLED"
WEB_SEARCH_DEFAULT="$WEB_SEARCH_DEFAULT"

GPG_KEY_ID="$GPG_KEY_ID"

# HUD — fichier de clés API à modifier via HUD ou manuellement après déchiffrement
# Emplacement : $STACK_DIR/.env.gpg
# Déchiffrement : gpg -d $STACK_DIR/.env.gpg > /tmp/env_edit && nano /tmp/env_edit
# Rechiffrement : gpg -e -r $GPG_KEY_ID /tmp/env_edit && mv /tmp/env_edit.gpg $STACK_DIR/.env.gpg
EOF

success "lisa.conf écrit."

# --- Écriture .env.plain (avant chiffrement) ---
{
    echo "LLM_API_KEY=$LLM_API_KEY"
    echo "STT_API_KEY=$STT_API_KEY"
    echo "TTS_API_KEY=$TTS_API_KEY"
    echo "RAG_API_KEY=$RAG_API_KEY"
    echo "DUCKDNS_TOKEN=$DUCKDNS_TOKEN"
    echo "AUTHELIA_PASS=$AUTHELIA_PASS"
    for KEY in "${!EXTRA_KEYS[@]}"; do
        SAFE_KEY=$(echo "$KEY" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')
        echo "${SAFE_KEY}=${EXTRA_KEYS[$KEY]}"
    done
} > "$ENV_PLAIN"
chmod 600 "$ENV_PLAIN"

# --- Chiffrement GPG ---
if [ -n "$GPG_KEY_ID" ]; then
    gpg --yes --batch --recipient "$GPG_KEY_ID" --output "$ENV_ENC" --encrypt "$ENV_PLAIN" && {
        rm -f "$ENV_PLAIN"
        success ".env chiffré GPG ($GPG_KEY_ID)"
    } || warn "Chiffrement GPG échoué — .env reste en clair temporairement."
else
    warn "Pas de clé GPG — .env en clair. Configurez GPG après installation."
fi

# ===================================================================================
# MARQUEUR D'ÉTAT
# ===================================================================================
echo "CONFIG_DONE" > "$STATE_FILE"
success "État : CONFIG_DONE"

# Nettoyage keepalive (sera relancé par 01)
kill "$SUDO_KEEPALIVE_PID" 2>/dev/null

# Entrée dans .bashrc pour reprise après groupe docker
if ! grep -q "LISA_AUTO_RESUME" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" << 'BASHRC'

# LISA_AUTO_RESUME — reprise automatique après ajout groupe docker
if [ -f "$HOME/ai-stack/.lisa_state" ]; then
    LISA_STATE=$(cat "$HOME/ai-stack/.lisa_state")
    if [ "$LISA_STATE" = "DOCKER_GROUP_ADDED" ]; then
        echo ""
        echo -e "\033[1;36m[L.I.S.A]\033[0m Reprise de l'installation (groupe docker appliqué)..."
        echo ""
        # Supprimer le marqueur de reprise pour éviter boucle
        sed -i '/LISA_AUTO_RESUME/,/^fi$/d' "$HOME/.bashrc"
        bash "$HOME/ai-stack/01_precheck_install.sh"
    fi
fi
BASHRC
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  Configuration terminée. Lancement de l'installation...${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
sleep 1

# Lancement dans tmux si terminal interactif
if [ -t 1 ] && command -v tmux &>/dev/null && [ -z "$TMUX" ]; then
    exec tmux new-session -s lisa_install "bash $STACK_DIR/01_precheck_install.sh; echo 'Appuyez sur Entrée pour fermer...'; read"
else
    exec bash "$STACK_DIR/01_precheck_install.sh"
fi

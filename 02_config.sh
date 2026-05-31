#!/bin/bash
# ===================================================================================
# L.I.S.A — 02_config.sh
# Réseau + récapitulatif + écriture lisa.conf + lancement installation
# full terminal, pas de whiptail
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
    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}  $1${RESET}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

STACK_DIR="$HOME/ai-stack"
CONF_FILE="$STACK_DIR/lisa.conf"
STATE_FILE="$STACK_DIR/.lisa_state"
ENV_PLAIN="$STACK_DIR/.env.plain"
ENV_ENC="$STACK_DIR/.env.gpg"
PASS_ENC="$STACK_DIR/.lisa_pass.gpg"
PASS_KEY="$STACK_DIR/.lisa_pass.key"
LOG_FILE="$STACK_DIR/lisa_install.log"

[ ! -f "$CONF_FILE" ] && { error "lisa.conf introuvable." ; exit 1; }
source "$CONF_FILE"

# ===================================================================================
# TRAP
# ===================================================================================
SUDO_KEEPALIVE_PID=""
_trap_cleanup() {
    local EXIT_CODE=$?
    [ "$EXIT_CODE" -eq 0 ] && return
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    [ -f "$STACK_DIR/lisa_cleanup.sh" ] && \
        bash "$STACK_DIR/lisa_cleanup.sh" "interruption 02_config" || \
        rm -rf "$STACK_DIR"
    exit 1
}
trap '_trap_cleanup' EXIT
trap 'exit 1' INT TERM

# ===================================================================================
# HELPERS TERMINAL
# ===================================================================================
_get_pass() {
    openssl enc -d -aes-256-cbc -pbkdf2 \
        -pass pass:"$(cat "$PASS_KEY")" -in "$PASS_ENC" 2>/dev/null
}

_yesno() {
    echo ""
    echo -e "${CYAN}  $1${RESET}"
    echo ""
    while IFS= read -r LINE; do echo -e "  $LINE"; done <<< "$2"
    echo ""
    echo -ne "${YELLOW}  [?]${RESET} Votre choix [O/n] : "
    read -r R ; echo ""
    [[ ! "$R" =~ ^[Nn]$ ]] && return 0 || return 1
}

_input() {
    echo -ne "${YELLOW}  [?]${RESET} $2 : "
    read -r REPLY_INPUT
    printf -v "$3" '%s' "$REPLY_INPUT"
    unset REPLY_INPUT
}

_password() {
    echo -ne "${YELLOW}  [?]${RESET} $2 : "
    read -r -s REPLY_PASS ; echo ""
    printf -v "$3" '%s' "$REPLY_PASS"
    unset REPLY_PASS
}

_menu() {
    local VARNAME="$3"
    shift 3
    local ITEMS=("$@")
    local i=0
    while [ $i -lt ${#ITEMS[@]} ]; do
        echo -e "  ${GREEN}[${ITEMS[$i]}]${RESET} ${ITEMS[$((i+1))]}"
        i=$((i+2))
    done
    echo ""
    echo -ne "${YELLOW}  [?]${RESET} Votre choix : "
    read -r R ; echo ""
    printf -v "$VARNAME" '%s' "$R"
}

# Keepalive sudo
(while [ -f "$PASS_KEY" ]; do
    echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1
    sleep 240
done) </dev/null &
SUDO_KEEPALIVE_PID=$!

# ===================================================================================
# RÉSEAU
# ===================================================================================
section "Accès à L.I.S.A. depuis internet"

EXPOSE_INTERNET="false"
DOMAIN_TYPE="none"
DOMAIN=""
DUCKDNS_TOKEN=""
AUTHELIA_ENABLED="false"
AUTHELIA_USER=""
AUTHELIA_PASS=""

# Sous-domaines — variables directes (pas de tableau associatif dans sous-fonction)
SUBDOMAIN_API="" ; SUBDOMAIN_LLM="" ; SUBDOMAIN_STT=""
SUBDOMAIN_TTS="" ; SUBDOMAIN_RAG="" ; SUBDOMAIN_SEARCH=""

SERVICES=(api llm stt tts rag search)
SVC_LABELS=("API principale" "Cerveau IA" "Reconnaissance vocale" "Synthèse vocale" "Mémoire documentaire" "Recherche web")

echo -e "  Par défaut, L.I.S.A. est accessible uniquement sur votre réseau local."
echo -e "  Vous pouvez l'exposer sur internet pour y accéder depuis n'importe où."
echo ""

if _yesno "Accès depuis internet" \
"Rendre L.I.S.A. accessible depuis internet ?
Si non, elle restera accessible uniquement chez vous."; then

    EXPOSE_INTERNET="true"
    PUBLIC_IP=$(curl -s https://ifconfig.me 2>/dev/null || echo "inconnue")

    echo -e "  Comment souhaitez-vous accéder à L.I.S.A. depuis internet ?"
    echo ""
    _menu "" "" DNS_CHOICE \
        "1" "J'ai un nom de domaine (ex: mondomaine.fr)" \
        "2" "Adresses gratuites DuckDNS (*.duckdns.org)" \
        "3" "Autre fournisseur DNS (Cloudflare, OVH...)" \
        "4" "Via mon adresse IP publique directement"

    # Fonction de saisie des sous-domaines (sans tableau associatif)
    _saisir_subdomain() {
        local IDX="$1"    # index dans SERVICES
        local SUFFIX="$2" # .mondomaine.fr ou .duckdns.org
        local MODE="$3"   # custom ou duckdns
        local SVC="${SERVICES[$IDX]}"
        local LABEL="${SVC_LABELS[$IDX]}"
        local DEFAULT="lisa-${SVC}"
        [ "$MODE" = "duckdns" ] && DEFAULT="lisa-${SVC}-4827"
        local INPUT=""

        while true; do
            echo -ne "${YELLOW}  [?]${RESET} ${CYAN}${LABEL}${RESET} (ex: ${GREEN}${DEFAULT}${RESET})${SUFFIX} : "
            read -r INPUT
            INPUT=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]' \
                | sed "s|${SUFFIX}||g" | sed 's|^[[:space:]]*||;s|[[:space:]]*$||')

            if [ -z "$INPUT" ] || [[ "$INPUT" == *"XXXX"* ]]; then
                warn "  Saisissez un nom valide (sans ${SUFFIX} et sans XXXX)."
                continue
            fi

            # Validation DuckDNS
            if [ "$MODE" = "duckdns" ] && [ -n "$DUCKDNS_TOKEN" ]; then
                local TEST
                TEST=$(curl -s "https://www.duckdns.org/update?domains=${INPUT}&token=${DUCKDNS_TOKEN}&ip=" 2>/dev/null)
                if [[ "$TEST" != "OK" ]]; then
                    warn "  '${INPUT}.duckdns.org' non trouvé sur DuckDNS."
                    echo -ne "${YELLOW}  [?]${RESET} Corriger ? [O/n] : " ; read -r C ; echo ""
                    [[ ! "$C" =~ ^[Nn]$ ]] && continue
                fi
            fi

            # Stocker dans la variable globale correspondante
            case "$SVC" in
                api)    SUBDOMAIN_API="${INPUT}${SUFFIX}" ;;
                llm)    SUBDOMAIN_LLM="${INPUT}${SUFFIX}" ;;
                stt)    SUBDOMAIN_STT="${INPUT}${SUFFIX}" ;;
                tts)    SUBDOMAIN_TTS="${INPUT}${SUFFIX}" ;;
                rag)    SUBDOMAIN_RAG="${INPUT}${SUFFIX}" ;;
                search) SUBDOMAIN_SEARCH="${INPUT}${SUFFIX}" ;;
            esac
            echo -e "    ${BLUE}→ ${INPUT}${SUFFIX}${RESET}\n"
            break
        done
    }

    _saisir_tous_subdomains() {
        local SUFFIX="$1"
        local MODE="$2"
        local CONFIRMED=false
        while ! $CONFIRMED; do
            echo ""
            echo -e "  ${CYAN}Renseignez le nom de chaque adresse (partie AVANT ${GREEN}${SUFFIX}${CYAN}) :${RESET}"
            echo ""
            for IDX in "${!SERVICES[@]}"; do
                _saisir_subdomain "$IDX" "$SUFFIX" "$MODE"
            done

            # Récapitulatif
            echo ""
            echo -e "  ${CYAN}━━━ Vos adresses L.I.S.A. ━━━${RESET}"
            echo -e "    ${BLUE}API    :${RESET} $SUBDOMAIN_API"
            echo -e "    ${BLUE}LLM    :${RESET} $SUBDOMAIN_LLM"
            echo -e "    ${BLUE}STT    :${RESET} $SUBDOMAIN_STT"
            echo -e "    ${BLUE}TTS    :${RESET} $SUBDOMAIN_TTS"
            echo -e "    ${BLUE}RAG    :${RESET} $SUBDOMAIN_RAG"
            echo -e "    ${BLUE}Search :${RESET} $SUBDOMAIN_SEARCH"
            echo ""

            if _yesno "Vérification" "Ces adresses sont-elles correctes ?"; then
                CONFIRMED=true
            else
                SUBDOMAIN_API="" ; SUBDOMAIN_LLM="" ; SUBDOMAIN_STT=""
                SUBDOMAIN_TTS="" ; SUBDOMAIN_RAG="" ; SUBDOMAIN_SEARCH=""
            fi
        done
    }

    case "$DNS_CHOICE" in
        1|3)
            [ "$DNS_CHOICE" = "1" ] && TITLE="Domaine personnel" || TITLE="Fournisseur DNS"
            _input "$TITLE" "Votre nom de domaine (ex: mondomaine.fr)" DOMAIN
            DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's|^https\?://||')
            DOMAIN_TYPE="custom"
            echo ""
            warn "  Vous devrez créer chez votre registrar un enregistrement A :"
            echo -e "  ${GREEN}[sous-domaine].${DOMAIN}${RESET}  →  ${GREEN}A${RESET}  →  ${GREEN}${PUBLIC_IP}${RESET}"
            warn "  La propagation DNS peut prendre jusqu'à 24h."
            echo ""
            _saisir_tous_subdomains ".$DOMAIN" "custom"
            echo -ne "  Appuyez sur Entrée une fois vos DNS créés..." ; read -r ; echo ""
            ;;

        2)
            DOMAIN_TYPE="duckdns"
            DOMAIN="duckdns.org"
            echo ""
            echo -e "  ${CYAN}DuckDNS — adresses gratuites en *.duckdns.org${RESET}"
            echo ""
            echo -e "  ${BLUE}Étape 1${RESET} — Allez sur ${BLUE}https://www.duckdns.org${RESET}"
            echo -e "           Connectez-vous avec votre compte Google."
            echo ""
            echo -e "  ${BLUE}Étape 2${RESET} — Créez ${GREEN}${#SERVICES[@]} sous-domaines${RESET}, un par service."
            echo -e "           Exemple : ${GREEN}lisa-api-4827${RESET}.duckdns.org"
            echo -e "           Remplacez 4827 par vos propres chiffres."
            echo -e "           Si le nom est pris, essayez d'autres chiffres."
            echo ""
            echo -e "  ${BLUE}Étape 3${RESET} — Copiez votre ${GREEN}token${RESET} depuis le tableau de bord."
            echo ""
            command -v xdg-open &>/dev/null && xdg-open "https://www.duckdns.org" &>/dev/null &
            echo -ne "  Appuyez sur Entrée une fois vos sous-domaines créés..." ; read -r ; echo ""

            # Saisie token avec confirmation
            while true; do
                _password "Token DuckDNS" "Collez votre token DuckDNS" DUCKDNS_TOKEN
                TOKEN_LEN=${#DUCKDNS_TOKEN}
                TOKEN_PREVIEW="${DUCKDNS_TOKEN:0:8}****-****-${DUCKDNS_TOKEN: -4}"
                echo ""
                echo -e "  Token saisi : ${CYAN}${TOKEN_PREVIEW}${RESET} (${TOKEN_LEN} caractères)"
                if _yesno "Vérification token" "C'est correct ?"; then
                    break
                fi
            done

            _saisir_tous_subdomains ".duckdns.org" "duckdns"
            ;;

        4)
            DOMAIN_TYPE="ip"
            DOMAIN="$PUBLIC_IP"
            SUBDOMAIN_API="$PUBLIC_IP" ; SUBDOMAIN_LLM="$PUBLIC_IP"
            SUBDOMAIN_STT="$PUBLIC_IP" ; SUBDOMAIN_TTS="$PUBLIC_IP"
            SUBDOMAIN_RAG="$PUBLIC_IP" ; SUBDOMAIN_SEARCH="$PUBLIC_IP"
            warn "  Accès par IP — les navigateurs afficheront un avertissement de sécurité."
            ;;

        *)
            EXPOSE_INTERNET="false"
            ;;
    esac

    # Authelia
    if [ "$EXPOSE_INTERNET" = "true" ]; then
        echo ""
        echo -e "  ${CYAN}Protection par mot de passe${RESET}"
        echo -e "  Recommandé si L.I.S.A. est accessible depuis internet."
        echo ""
        if _yesno "Protection" "Activer la protection par mot de passe ?"; then
            AUTHELIA_ENABLED="true"
            _input "Utilisateur" "Nom d'utilisateur" AUTHELIA_USER
            while true; do
                AUTHELIA_PASS="" ; AUTHELIA_PASS2=""
                _password "Mot de passe" "Choisissez un mot de passe" AUTHELIA_PASS
                _password "Confirmation" "Confirmez votre mot de passe" AUTHELIA_PASS2
                if [ "$AUTHELIA_PASS" = "$AUTHELIA_PASS2" ] && [ -n "$AUTHELIA_PASS" ]; then
                    unset AUTHELIA_PASS2
                    success "  Protection activée — utilisateur : $AUTHELIA_USER"
                    break
                fi
                warn "  Les mots de passe ne correspondent pas ou sont vides."
            done
        fi
    fi
fi

# ===================================================================================
# RÉCAPITULATIF GLOBAL
# ===================================================================================
section "Récapitulatif de votre configuration"

CONFIRMED=false
while ! $CONFIRMED; do

    echo -e "  ${CYAN}Votre machine${RESET}"
    case "$RAM_PROFILE" in
        low)    echo -e "    Profil  : ${GREEN}Léger${RESET} (${RAM_GB}GB RAM)" ;;
        medium) echo -e "    Profil  : ${GREEN}Standard${RESET} (${RAM_GB}GB RAM)" ;;
        high)   echo -e "    Profil  : ${GREEN}Élevé${RESET} (${RAM_GB}GB RAM)" ;;
    esac
    echo -e "    Modèle  : ${GREEN}$LLM_MODEL_LOCAL${RESET}"
    echo ""
    echo -e "  ${CYAN}Services en ligne${RESET}"
    [ "$LLM_MODE" = "3" ]   && echo -e "    IA      : ${GREEN}$LLM_PROVIDER${RESET}"   || echo -e "    IA      : local uniquement"
    [ "$STT_MODE" = "2" ]   && echo -e "    Voix IN : ${GREEN}$STT_PROVIDER${RESET}"   || echo -e "    Voix IN : local"
    [ "$TTS_MODE" = "2" ]   && echo -e "    Voix OUT: ${GREEN}$TTS_PROVIDER${RESET}"   || echo -e "    Voix OUT: local"
    echo ""
    echo -e "  ${CYAN}Fonctionnalités${RESET}"
    [ "$WEB_SEARCH_DEFAULT" = "true" ] \
        && echo -e "    Recherche web   : ${GREEN}active par défaut${RESET}" \
        || echo -e "    Recherche web   : installée, inactive"
    [ "$RAG_ENABLED" = "true" ] \
        && echo -e "    Mémoire docs    : ${GREEN}active${RESET}" \
        || echo -e "    Mémoire docs    : ${YELLOW}désactivée (profil léger)${RESET}"
    echo ""
    echo -e "  ${CYAN}Réseau${RESET}"
    if [ "$EXPOSE_INTERNET" = "true" ]; then
        echo -e "    Accès internet  : ${GREEN}oui${RESET}"
        [ -n "$SUBDOMAIN_API" ] && echo -e "    API             : ${BLUE}$SUBDOMAIN_API${RESET}"
        [ "$AUTHELIA_ENABLED" = "true" ] \
            && echo -e "    Protection      : ${GREEN}oui ($AUTHELIA_USER)${RESET}" \
            || echo -e "    Protection      : non"
    else
        echo -e "    Accès internet  : local uniquement"
    fi
    echo ""
    echo -e "  ${MAGENTA}────────────────────────────────────────────────────${RESET}"
    echo ""

    echo -e "  ${GREEN}[0]${RESET} Tout est correct — lancer l'installation"
    echo -e "  ${YELLOW}[1]${RESET} Modifier les services en ligne"
    echo -e "  ${YELLOW}[2]${RESET} Modifier la recherche web"
    echo -e "  ${YELLOW}[3]${RESET} Modifier l'accès internet"
    echo -e "  ${YELLOW}[4]${RESET} Modifier la protection par mot de passe"
    echo ""
    echo -ne "${YELLOW}  [?]${RESET} Votre choix [0-4] : " ; read -r RECAP_CHOICE ; echo ""

    case "$RECAP_CHOICE" in
        0) CONFIRMED=true ;;
        1) exec bash "$STACK_DIR/01_config.sh" ;;
        2)
            if _yesno "Recherche web" "Activer la recherche web par défaut ?"; then
                WEB_SEARCH_DEFAULT="true"
            else
                WEB_SEARCH_DEFAULT="false"
            fi
            ;;
        3)
            EXPOSE_INTERNET="false" ; DOMAIN_TYPE="none" ; DOMAIN=""
            DUCKDNS_TOKEN="" ; AUTHELIA_ENABLED="false"
            SUBDOMAIN_API="" ; SUBDOMAIN_LLM="" ; SUBDOMAIN_STT=""
            SUBDOMAIN_TTS="" ; SUBDOMAIN_RAG="" ; SUBDOMAIN_SEARCH=""
            exec bash "$STACK_DIR/02_config.sh"
            ;;
        4)
            if [ "$EXPOSE_INTERNET" = "true" ]; then
                if _yesno "Protection" "Activer la protection par mot de passe ?"; then
                    AUTHELIA_ENABLED="true"
                    _input "Utilisateur" "Nom d'utilisateur" AUTHELIA_USER
                    while true; do
                        _password "Mot de passe" "Mot de passe" AUTHELIA_PASS
                        _password "Confirmation" "Confirmez" AUTHELIA_PASS2
                        [ "$AUTHELIA_PASS" = "$AUTHELIA_PASS2" ] && [ -n "$AUTHELIA_PASS" ] && { unset AUTHELIA_PASS2; break; }
                        warn "  Mots de passe incorrects."
                    done
                else
                    AUTHELIA_ENABLED="false"
                fi
            else
                warn "  La protection n'est utile que si L.I.S.A. est accessible depuis internet."
            fi
            ;;
        *) warn "  Choix invalide." ;;
    esac
done

# ===================================================================================
# ÉCRITURE FINALE lisa.conf
# ===================================================================================
cat >> "$CONF_FILE" << EOF

# Réseau
EXPOSE_INTERNET="$EXPOSE_INTERNET"
DOMAIN_TYPE="$DOMAIN_TYPE"
DOMAIN="$DOMAIN"
DUCKDNS_TOKEN_SET="$([ -n "$DUCKDNS_TOKEN" ] && echo true || echo false)"
AUTHELIA_ENABLED="$AUTHELIA_ENABLED"
AUTHELIA_USER="${AUTHELIA_USER:-}"
SUBDOMAIN_API="$SUBDOMAIN_API"
SUBDOMAIN_LLM="$SUBDOMAIN_LLM"
SUBDOMAIN_STT="$SUBDOMAIN_STT"
SUBDOMAIN_TTS="$SUBDOMAIN_TTS"
SUBDOMAIN_RAG="$SUBDOMAIN_RAG"
SUBDOMAIN_SEARCH="$SUBDOMAIN_SEARCH"

# Secrets : $STACK_DIR/.env.gpg (AES-256)
# Déchiffrement : openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:\$(cat $STACK_DIR/.env.key) -in $STACK_DIR/.env.gpg
EOF

# Ajout secrets réseau
{
    echo "DUCKDNS_TOKEN=${DUCKDNS_TOKEN}"
    echo "AUTHELIA_PASS=${AUTHELIA_PASS:-}"
} >> "$ENV_PLAIN"

# Chiffrement AES-256
ENV_KEY=$(cat "$STACK_DIR/.env.key" 2>/dev/null)
if [ -n "$ENV_KEY" ]; then
    openssl enc -aes-256-cbc -pbkdf2 \
        -pass pass:"$ENV_KEY" \
        -in "$ENV_PLAIN" -out "$ENV_ENC" 2>/dev/null && {
        rm -f "$ENV_PLAIN"
        success "Secrets chiffrés (AES-256)"
    } || warn "Chiffrement échoué — .env reste en clair."
else
    warn "Clé de chiffrement absente — .env en clair."
fi

# ===================================================================================
# MARQUEUR + REPRISE DOCKER GROUP
# ===================================================================================
echo "CONFIG_DONE" > "$STATE_FILE"

if ! grep -q "LISA_AUTO_RESUME" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" << 'BASHRC'

# LISA_AUTO_RESUME
if [ -f "$HOME/ai-stack/.lisa_state" ]; then
    _LS=$(cat "$HOME/ai-stack/.lisa_state")
    if [ "$_LS" = "DOCKER_GROUP_ADDED" ]; then
        echo -e "\033[1;36m[L.I.S.A]\033[0m Reprise (groupe docker appliqué)..."
        sed -i '/LISA_AUTO_RESUME/,/^fi$/d' "$HOME/.bashrc"
        bash "$HOME/ai-stack/01_precheck_install.sh"
    fi
fi
BASHRC
fi

kill "$SUDO_KEEPALIVE_PID" 2>/dev/null

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}  Configuration terminée.${RESET}"
echo -e "${GREEN}  L'installation va démarrer.${RESET}"
echo -e "${GREEN}  Durée estimée : 10 à 30 minutes.${RESET}"
echo -e "${GREEN}  Ne fermez pas ce terminal.${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -ne "  Appuyez sur Entrée pour lancer l'installation..." ; read -r ; echo ""

exec bash "$STACK_DIR/01_precheck_install.sh"

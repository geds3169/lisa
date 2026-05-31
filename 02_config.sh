#!/bin/bash
# ===================================================================================
# L.I.S.A — 02_config.sh
# Réseau + récapitulatif + écriture lisa.conf + lancement installation
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

STACK_DIR="$HOME/ai-stack"
CONF_FILE="$STACK_DIR/lisa.conf"
STATE_FILE="$STACK_DIR/.lisa_state"
ENV_PLAIN="$STACK_DIR/.env.plain"
ENV_ENC="$STACK_DIR/.env.gpg"
PASS_ENC="$STACK_DIR/.lisa_pass.gpg"
PASS_KEY="$STACK_DIR/.lisa_pass.key"
LOG_FILE="$STACK_DIR/lisa_install.log"

exec >> "$LOG_FILE" 2>&1

[ ! -f "$CONF_FILE" ] && { error "lisa.conf introuvable."; exit 1; }
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
        bash "$STACK_DIR/lisa_cleanup.sh" "interruption configuration réseau" || \
        rm -rf "$STACK_DIR"
    exit 1
}
trap '_trap_cleanup' EXIT
trap 'exit 1' INT TERM

# ===================================================================================
# DÉTECTION WHIPTAIL
# ===================================================================================
USE_WHIPTAIL=false
command -v whiptail &>/dev/null && [ -t 1 ] && USE_WHIPTAIL=true

_msg() {
    $USE_WHIPTAIL && whiptail --title "$1" --msgbox "$2" 16 65 || {
        section "$1" ; echo -e "$2" ; echo ""
    }
}
_yesno() {
    if $USE_WHIPTAIL; then
        whiptail --title "$1" --yesno "$2" 14 65 ; return $?
    else
        echo -ne "${YELLOW}[?]${RESET} $2 [O/n] : " ; read -r R
        [[ ! "$R" =~ ^[Nn]$ ]] && return 0 || return 1
    fi
}
_input() {
    if $USE_WHIPTAIL; then
        local VAL
        VAL=$(whiptail --title "$1" --inputbox "$2" 10 65 3>&1 1>&2 2>&3)
        eval "$3=\"$VAL\""
    else
        echo -ne "${YELLOW}[?]${RESET} $2 : " ; read -r R
        eval "$3=\"$R\""
    fi
}
_password() {
    if $USE_WHIPTAIL; then
        local VAL
        VAL=$(whiptail --title "$1" --passwordbox "$2" 10 65 3>&1 1>&2 2>&3)
        eval "$3=\"$VAL\""
    else
        echo -ne "${YELLOW}[?]${RESET} $2 : " ; read -r -s R ; echo ""
        eval "$3=\"$R\""
    fi
}
_menu() {
    local TITLE="$1" MSG="$2" VARNAME="$3"
    shift 3
    if $USE_WHIPTAIL; then
        local CHOICE
        CHOICE=$(whiptail --title "$TITLE" --menu "$MSG" 18 65 6 "$@" 3>&1 1>&2 2>&3)
        eval "$VARNAME=\"$CHOICE\""
    else
        echo -e "${CYAN}$MSG${RESET}"
        local ITEMS=("$@")
        local i=0
        while [ $i -lt ${#ITEMS[@]} ]; do
            echo -e "  ${GREEN}[${ITEMS[$i]}]${RESET} ${ITEMS[$((i+1))]}"
            i=$((i+2))
        done
        echo -ne "${YELLOW}[?]${RESET} Votre choix : " ; read -r R
        eval "$VARNAME=\"$R\""
    fi
}

# Keepalive sudo
_get_pass() {
    openssl enc -d -aes-256-cbc -pbkdf2 \
        -pass pass:"$(cat "$PASS_KEY")" -in "$PASS_ENC" 2>/dev/null
}
(while [ -f "$PASS_KEY" ]; do
    echo "$(_get_pass)" | sudo -S -v &>/dev/null 2>&1
    sleep 240
done) &
SUDO_KEEPALIVE_PID=$!

# ===================================================================================
# RÉSEAU
# ===================================================================================
EXPOSE_INTERNET="false"
DOMAIN_TYPE="none"
DOMAIN=""
DUCKDNS_TOKEN=""
AUTHELIA_ENABLED="false"
AUTHELIA_USER=""
AUTHELIA_PASS=""
declare -A SVC_SUBDOMAINS
SERVICES=(api llm stt tts rag search)
SVC_LABELS=("API principale" "Cerveau IA" "Reconnaissance vocale" "Synthèse vocale" "Mémoire documentaire" "Recherche web")

SUBDOMAIN_API="" ; SUBDOMAIN_LLM="" ; SUBDOMAIN_STT=""
SUBDOMAIN_TTS="" ; SUBDOMAIN_RAG="" ; SUBDOMAIN_SEARCH=""

if _yesno "Accès depuis internet" \
"Voulez-vous accéder à L.I.S.A.
depuis internet ?

Par défaut, L.I.S.A. est accessible uniquement
sur votre réseau local (chez vous).

Si vous activez cette option, vous pourrez
y accéder depuis n'importe où avec un navigateur
ou le HUD L.I.S.A."; then

    EXPOSE_INTERNET="true"
    PUBLIC_IP=$(curl -s https://ifconfig.me 2>/dev/null || echo "inconnue")

    DNS_CHOICE=""
    _menu "Type d'accès internet" \
"Comment souhaitez-vous accéder à L.I.S.A.
depuis internet ?" DNS_CHOICE \
"1" "J'ai un nom de domaine (ex: mondomaine.fr)" \
"2" "Adresses gratuites DuckDNS (*.duckdns.org)" \
"3" "Autre fournisseur DNS (Cloudflare, OVH...)" \
"4" "Via mon adresse IP publique directement"

    # ---------------------------------------------------------------
    _saisie_sous_domaines() {
        local SUFFIX="$1"
        local MODE="$2"
        local CONFIRMED=false

        while ! $CONFIRMED; do
            for i in "${!SERVICES[@]}"; do
                local SVC="${SERVICES[$i]}"
                local LABEL="${SVC_LABELS[$i]}"
                local DEFAULT="lisa-${SVC}"
                [ "$MODE" = "duckdns" ] && DEFAULT="lisa-${SVC}-4827"
                local INPUT=""

                while true; do
                    _input "Sous-domaine — $LABEL" \
                        "Nom pour $LABEL
(partie avant $SUFFIX)
Exemple : ${DEFAULT}" INPUT

                    INPUT=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]' \
                        | sed "s|${SUFFIX}||g" | sed 's|^[[:space:]]*||;s|[[:space:]]*$||')

                    if [ -z "$INPUT" ] || [[ "$INPUT" == *"XXXX"* ]]; then
                        _msg "Nom invalide" "Saisissez un nom valide sans $SUFFIX."
                        continue
                    fi

                    SVC_SUBDOMAINS[$SVC]="${INPUT}${SUFFIX}"

                    # Validation DuckDNS
                    if [ "$MODE" = "duckdns" ] && [ -n "$DUCKDNS_TOKEN" ]; then
                        local TEST
                        TEST=$(curl -s "https://www.duckdns.org/update?domains=${INPUT}&token=${DUCKDNS_TOKEN}&ip=" 2>/dev/null)
                        if [[ "$TEST" != "OK" ]]; then
                            if _yesno "Sous-domaine introuvable" \
"Le sous-domaine '${INPUT}.duckdns.org'
n'a pas été trouvé sur DuckDNS.

Voulez-vous le corriger ?"; then
                                continue
                            fi
                        fi
                    fi
                    break
                done
            done

            # Récapitulatif sous-domaines
            local RECAP="Vos adresses L.I.S.A. :\n\n"
            for SVC in "${SERVICES[@]}"; do
                RECAP+="  ${SVC_SUBDOMAINS[$SVC]}\n"
            done
            RECAP+="\nCes adresses sont-elles correctes ?"

            if _yesno "Vérification des adresses" "$RECAP"; then
                CONFIRMED=true
            fi
        done
    }
    # ---------------------------------------------------------------

    case "$DNS_CHOICE" in
        1|3)
            [ "$DNS_CHOICE" = "1" ] && DNS_TITLE="Domaine personnel" || DNS_TITLE="Fournisseur DNS"
            _input "$DNS_TITLE" \
                "Votre nom de domaine (ex: mondomaine.fr)" DOMAIN
            DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's|^https\?://||')
            DOMAIN_TYPE="custom"

            _msg "Enregistrements DNS à créer" \
"Vous devrez créer chez votre fournisseur DNS
un enregistrement de type A pour chaque adresse :

  [nom-choisi].$DOMAIN  →  A  →  $PUBLIC_IP

La propagation DNS peut prendre jusqu'à 24h."

            _saisie_sous_domaines ".$DOMAIN" "custom"
            ;;

        2)
            DOMAIN_TYPE="duckdns"
            DOMAIN="duckdns.org"

            _msg "DuckDNS — étapes à suivre" \
"DuckDNS est un service gratuit d'adresses internet.

Étape 1 — Allez sur https://www.duckdns.org
          Connectez-vous avec votre compte Google.

Étape 2 — Créez ${#SERVICES[@]} sous-domaines,
          un par service L.I.S.A.
          Exemple : lisa-api-4827.duckdns.org
          Choisissez un nombre à la place de 4827.
          Si le nom est pris, essayez un autre nombre.

Étape 3 — Copiez votre token affiché en haut
          du tableau de bord DuckDNS."

            # Ouvrir DuckDNS dans le navigateur si possible
            command -v xdg-open &>/dev/null && \
                xdg-open "https://www.duckdns.org" &>/dev/null & true

            # Token avec vérification
            while true; do
                _password "Token DuckDNS" \
                    "Collez votre token DuckDNS
(visible en haut du tableau de bord)" DUCKDNS_TOKEN

                TOKEN_LEN=${#DUCKDNS_TOKEN}
                TOKEN_PREVIEW="${DUCKDNS_TOKEN:0:8}****-****-${DUCKDNS_TOKEN: -4}"

                if _yesno "Vérification du token" \
"Token saisi :
  $TOKEN_PREVIEW
  ($TOKEN_LEN caractères)

Est-ce correct ?"; then
                    break
                fi
            done

            _saisie_sous_domaines ".duckdns.org" "duckdns"
            ;;

        4)
            DOMAIN_TYPE="ip"
            DOMAIN="$PUBLIC_IP"
            for SVC in "${SERVICES[@]}"; do
                SVC_SUBDOMAINS[$SVC]="$PUBLIC_IP"
            done
            _msg "Accès par IP" \
"L.I.S.A. sera accessible via votre IP publique :
$PUBLIC_IP

Les navigateurs afficheront un avertissement
de sécurité que vous devrez accepter."
            ;;

        *)
            EXPOSE_INTERNET="false"
            ;;
    esac

    SUBDOMAIN_API="${SVC_SUBDOMAINS[api]:-}"
    SUBDOMAIN_LLM="${SVC_SUBDOMAINS[llm]:-}"
    SUBDOMAIN_STT="${SVC_SUBDOMAINS[stt]:-}"
    SUBDOMAIN_TTS="${SVC_SUBDOMAINS[tts]:-}"
    SUBDOMAIN_RAG="${SVC_SUBDOMAINS[rag]:-}"
    SUBDOMAIN_SEARCH="${SVC_SUBDOMAINS[search]:-}"

    # Authelia
    if _yesno "Protection par mot de passe" \
"Voulez-vous protéger l'accès à L.I.S.A.
par un mot de passe ?

Recommandé si L.I.S.A. est accessible
depuis internet.

Sans protection, n'importe qui connaissant
votre adresse peut accéder à votre IA."; then

        AUTHELIA_ENABLED="true"
        _input "Compte administrateur" \
            "Choisissez un nom d'utilisateur" AUTHELIA_USER

        while true; do
            AUTHELIA_PASS="" ; AUTHELIA_PASS2=""
            _password "Mot de passe" "Choisissez un mot de passe" AUTHELIA_PASS
            _password "Confirmation" "Confirmez votre mot de passe" AUTHELIA_PASS2
            if [ "$AUTHELIA_PASS" = "$AUTHELIA_PASS2" ] && [ -n "$AUTHELIA_PASS" ]; then
                break
            else
                _msg "Erreur" "Les mots de passe ne correspondent pas\nou sont vides. Recommencez."
            fi
        done
        unset AUTHELIA_PASS2
    fi
fi

# ===================================================================================
# RÉCAPITULATIF GLOBAL
# ===================================================================================
_build_recap() {
    local R=""
    case "$RAM_PROFILE" in
        low)    R+="Profil machine   : Léger (${RAM_GB}GB RAM)\n" ;;
        medium) R+="Profil machine   : Standard (${RAM_GB}GB RAM)\n" ;;
        high)   R+="Profil machine   : Élevé (${RAM_GB}GB RAM)\n" ;;
    esac
    R+="Modèle IA        : $LLM_MODEL_LOCAL\n"
    R+="\n"
    [ "$LLM_MODE" = "3" ]   && R+="Service IA ext.  : $LLM_PROVIDER\n" || R+="Service IA ext.  : Non\n"
    [ "$STT_MODE" = "2" ]   && R+="Voix entrée ext. : $STT_PROVIDER\n" || R+="Voix entrée ext. : Non\n"
    [ "$TTS_MODE" = "2" ]   && R+="Voix sortie ext. : $TTS_PROVIDER\n" || R+="Voix sortie ext. : Non\n"
    R+="\n"
    [ "$WEB_SEARCH_DEFAULT" = "true" ] && R+="Recherche web    : Active par défaut\n" || R+="Recherche web    : Installée, inactive\n"
    [ "$RAG_ENABLED" = "true" ]        && R+="Mémoire docs     : Active\n" || R+="Mémoire docs     : Désactivée (profil léger)\n"
    R+="\n"
    if [ "$EXPOSE_INTERNET" = "true" ]; then
        R+="Accès internet   : Oui\n"
        [ -n "$SUBDOMAIN_API" ] && R+="  API : $SUBDOMAIN_API\n"
        [ "$AUTHELIA_ENABLED" = "true" ] && R+="Protection login : Oui ($AUTHELIA_USER)\n" || R+="Protection login : Non\n"
    else
        R+="Accès internet   : Non (local uniquement)\n"
    fi
    echo -e "$R"
}

CONFIRMED=false
while ! $CONFIRMED; do
    RECAP=$(_build_recap)

    if _yesno "Récapitulatif — Votre configuration L.I.S.A." \
"$RECAP
Tout est correct ?
Oui → lancer l'installation
Non → modifier un paramètre"; then
        CONFIRMED=true
    else
        # Menu de correction
        FIX_CHOICE=""
        _menu "Que souhaitez-vous modifier ?" "" FIX_CHOICE \
            "1" "Services en ligne (clés API)" \
            "2" "Recherche web" \
            "3" "Accès internet" \
            "4" "Protection par mot de passe"

        case "$FIX_CHOICE" in
            1) exec bash "$STACK_DIR/01_config.sh" ;;
            2)
                if _yesno "Recherche web" \
"Activer la recherche web par défaut ?"; then
                    WEB_SEARCH_DEFAULT="true"
                else
                    WEB_SEARCH_DEFAULT="false"
                fi
                ;;
            3)
                # Réinitialiser réseau et relancer la section
                EXPOSE_INTERNET="false" ; DOMAIN_TYPE="none" ; DOMAIN=""
                DUCKDNS_TOKEN="" ; AUTHELIA_ENABLED="false"
                SUBDOMAIN_API="" ; SUBDOMAIN_LLM="" ; SUBDOMAIN_STT=""
                SUBDOMAIN_TTS="" ; SUBDOMAIN_RAG="" ; SUBDOMAIN_SEARCH=""
                exec bash "$STACK_DIR/02_config.sh"
                ;;
            4)
                if [ "$EXPOSE_INTERNET" = "true" ]; then
                    if _yesno "Protection par mot de passe" \
"Activer la protection par mot de passe ?"; then
                        AUTHELIA_ENABLED="true"
                        _input "Utilisateur" "Nom d'utilisateur" AUTHELIA_USER
                        while true; do
                            _password "Mot de passe" "Mot de passe" AUTHELIA_PASS
                            _password "Confirmation" "Confirmez" AUTHELIA_PASS2
                            [ "$AUTHELIA_PASS" = "$AUTHELIA_PASS2" ] && [ -n "$AUTHELIA_PASS" ] && break
                            _msg "Erreur" "Mots de passe incorrects."
                        done
                    else
                        AUTHELIA_ENABLED="false"
                    fi
                else
                    _msg "Information" "La protection par mot de passe\nn'est utile que si L.I.S.A.\nest accessible depuis internet."
                fi
                ;;
        esac
    fi
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

# Fichier secrets  : $STACK_DIR/.env.gpg (chiffré AES-256)
# Déchiffrement    : openssl enc -d -aes-256-cbc -pbkdf2 \
#                    -pass pass:$(cat $STACK_DIR/.env.key) \
#                    -in $STACK_DIR/.env.gpg > /tmp/env && nano /tmp/env
EOF

# Ajout secrets réseau au .env.plain
{
    echo "DUCKDNS_TOKEN=${DUCKDNS_TOKEN}"
    echo "AUTHELIA_PASS=${AUTHELIA_PASS:-}"
} >> "$ENV_PLAIN"

# Chiffrement AES-256 via openssl
ENV_KEY_FILE="$STACK_DIR/.env.key"
ENV_KEY=$(cat "$ENV_KEY_FILE" 2>/dev/null)
if [ -n "$ENV_KEY" ]; then
    openssl enc -aes-256-cbc -pbkdf2 \
        -pass pass:"$ENV_KEY" \
        -in "$ENV_PLAIN" -out "$ENV_ENC" 2>/dev/null && {
        rm -f "$ENV_PLAIN"
        success ".env chiffré (AES-256)"
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

_msg "Configuration terminée" \
"La configuration est complète.

L'installation de L.I.S.A. va démarrer.
Durée estimée : 10 à 30 minutes selon
votre connexion et votre machine.

Ne fermez pas ce terminal."

# Lancement dans tmux si disponible
if [ -t 1 ] && command -v tmux &>/dev/null && [ -z "$TMUX" ]; then
    exec tmux new-session -s lisa_install \
        "bash $STACK_DIR/01_precheck_install.sh; echo 'Appuyez sur Entrée...'; read"
else
    exec bash "$STACK_DIR/01_precheck_install.sh"
fi

#!/bin/bash
# ===================================================================================
# L.I.S.A — 00_provider_select.sh
# Sélection interactive d'un fournisseur API avec fuzzy matching
# Usage : bash 00_provider_select.sh <categorie>
# Retourne : l'id du fournisseur sélectionné (stdout)
# ===================================================================================

STACK_DIR="$HOME/ai-stack"
PROVIDERS_FILE="$STACK_DIR/providers.json"

YELLOW="\033[1;33m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RED="\033[1;31m"
RESET="\033[0m"

CATEGORY="${1:-llm}"

# --- Vérification jq ---
if ! command -v jq &>/dev/null; then
    sudo apt-get install -y jq -qq
fi

if [ ! -f "$PROVIDERS_FILE" ]; then
    echo -e "${RED}[ERROR]${RESET} providers.json introuvable : $PROVIDERS_FILE" >&2
    echo "unknown"
    exit 1
fi

# --- Charger la liste pour la catégorie ---
PROVIDER_IDS=$(jq -r ".${CATEGORY}[].id" "$PROVIDERS_FILE" 2>/dev/null)
PROVIDER_NAMES=$(jq -r ".${CATEGORY}[].name" "$PROVIDERS_FILE" 2>/dev/null)

if [ -z "$PROVIDER_IDS" ]; then
    echo -e "${YELLOW}[WARN]${RESET} Catégorie '$CATEGORY' introuvable dans providers.json." >&2
    echo -e "${YELLOW}[?]${RESET} Entrez manuellement le nom du fournisseur :" >&2
    read -r MANUAL_INPUT
    echo "$MANUAL_INPUT"
    exit 0
fi

# --- Affichage de la liste numérotée ---
echo -e "\n${CYAN}Fournisseurs disponibles — $CATEGORY :${RESET}" >&2
INDEX=1
declare -a ID_LIST
declare -a NAME_LIST

while IFS= read -r NAME; do
    ID=$(jq -r ".${CATEGORY}[$((INDEX-1))].id" "$PROVIDERS_FILE")
    URL=$(jq -r ".${CATEGORY}[$((INDEX-1))].url" "$PROVIDERS_FILE")
    echo -e "  ${GREEN}[$INDEX]${RESET} $NAME" >&2
    [ -n "$URL" ] && [ "$URL" != "null" ] && echo -e "       ${BLUE}→ $URL${RESET}" >&2
    ID_LIST+=("$ID")
    NAME_LIST+=("$NAME")
    INDEX=$((INDEX + 1))
done <<< "$PROVIDER_NAMES"

LAST=$((INDEX - 1))
echo -e "  ${GREEN}[$INDEX]${RESET} Autre (saisie libre)" >&2
echo "" >&2

# --- Saisie utilisateur ---
while true; do
    echo -ne "${YELLOW}[?]${RESET} Numéro ou nom du fournisseur : " >&2
    read -r INPUT

    # Choix par numéro
    if [[ "$INPUT" =~ ^[0-9]+$ ]]; then
        if [ "$INPUT" -ge 1 ] && [ "$INPUT" -le "$LAST" ]; then
            SELECTED_ID="${ID_LIST[$((INPUT-1))]}"
            SELECTED_NAME="${NAME_LIST[$((INPUT-1))]}"
            echo -e "${GREEN}[OK]${RESET} Fournisseur sélectionné : $SELECTED_NAME" >&2
            echo "$SELECTED_ID"
            exit 0
        elif [ "$INPUT" -eq "$INDEX" ]; then
            echo -ne "${YELLOW}[?]${RESET} Nom du fournisseur : " >&2
            read -r CUSTOM
            echo "$CUSTOM"
            exit 0
        else
            echo -e "${RED}[!]${RESET} Numéro invalide." >&2
            continue
        fi
    fi

    # Fuzzy match sur les noms et aliases
    INPUT_LOWER=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]')
    BEST_ID=""
    BEST_NAME=""
    BEST_SCORE=0

    TOTAL=$(jq ".${CATEGORY} | length" "$PROVIDERS_FILE")
    for (( i=0; i<TOTAL; i++ )); do
        NAME_RAW=$(jq -r ".${CATEGORY}[$i].name" "$PROVIDERS_FILE" | tr '[:upper:]' '[:lower:]')
        ID_RAW=$(jq -r ".${CATEGORY}[$i].id" "$PROVIDERS_FILE")
        ALIASES=$(jq -r ".${CATEGORY}[$i].aliases[]" "$PROVIDERS_FILE" 2>/dev/null | tr '[:upper:]' '[:lower:]')

        # Correspondance exacte sur nom ou alias
        if [[ "$INPUT_LOWER" == "$NAME_RAW" ]]; then
            BEST_ID="$ID_RAW"
            BEST_NAME=$(jq -r ".${CATEGORY}[$i].name" "$PROVIDERS_FILE")
            BEST_SCORE=100
            break
        fi

        while IFS= read -r ALIAS; do
            if [[ "$INPUT_LOWER" == "$ALIAS" ]]; then
                BEST_ID="$ID_RAW"
                BEST_NAME=$(jq -r ".${CATEGORY}[$i].name" "$PROVIDERS_FILE")
                BEST_SCORE=100
                break 2
            fi
        done <<< "$ALIASES"

        # Correspondance partielle (contient)
        if [[ "$NAME_RAW" == *"$INPUT_LOWER"* ]] || [[ "$INPUT_LOWER" == *"$NAME_RAW"* ]]; then
            if [ "$BEST_SCORE" -lt 80 ]; then
                BEST_ID="$ID_RAW"
                BEST_NAME=$(jq -r ".${CATEGORY}[$i].name" "$PROVIDERS_FILE")
                BEST_SCORE=80
            fi
        fi

        # Correspondance partielle sur aliases
        while IFS= read -r ALIAS; do
            if [[ "$ALIAS" == *"$INPUT_LOWER"* ]] || [[ "$INPUT_LOWER" == *"$ALIAS"* ]]; then
                if [ "$BEST_SCORE" -lt 70 ]; then
                    BEST_ID="$ID_RAW"
                    BEST_NAME=$(jq -r ".${CATEGORY}[$i].name" "$PROVIDERS_FILE")
                    BEST_SCORE=70
                fi
            fi
        done <<< "$ALIASES"
    done

    if [ "$BEST_SCORE" -ge 70 ] && [ -n "$BEST_ID" ]; then
        echo -ne "${YELLOW}[?]${RESET} Voulez-vous dire \"$BEST_NAME\" ? [O/n] : " >&2
        read -r CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Nn]$ ]]; then
            echo -e "${GREEN}[OK]${RESET} Fournisseur sélectionné : $BEST_NAME" >&2
            echo "$BEST_ID"
            exit 0
        fi
    else
        echo -e "${YELLOW}[?]${RESET} Fournisseur non reconnu. Enregistrement tel quel : \"$INPUT\"" >&2
        echo -ne "${YELLOW}[?]${RESET} Confirmer ? [O/n] : " >&2
        read -r CONFIRM2
        if [[ ! "$CONFIRM2" =~ ^[Nn]$ ]]; then
            echo "$INPUT"
            exit 0
        fi
    fi
done

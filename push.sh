#!/bin/bash
# ===================================================================================
# push.sh — Met à jour le repo GitHub depuis le dossier courant
# Usage : bash push.sh
# ===================================================================================

GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RESET="\033[0m"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

if [ ! -d ".git" ]; then
    echo -e "${RED}[ERREUR]${RESET} Ce dossier n'est pas un repo git."
    exit 1
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${CYAN}  L.I.S.A. — Push GitHub${RESET}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# Afficher les fichiers modifiés
echo -e "${YELLOW}Fichiers modifiés :${RESET}"
git status --short
echo ""

# Demander le message de commit
if [ -n "$1" ]; then
    MSG="$1"
else
    echo -ne "${YELLOW}[?]${RESET} Message de commit : "
    read -r MSG
    [ -z "$MSG" ] && MSG="mise à jour L.I.S.A."
fi

echo ""
git add .
git commit -m "$MSG" && \
    git push && \
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" && \
    echo -e "${GREEN}  Push réussi — $MSG${RESET}" && \
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}" || \
    echo -e "${RED}[ERREUR]${RESET} Push échoué."

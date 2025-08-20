#!/usr/bin/env bash
set -euo pipefail

# --- Kleuren ---
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
RESET="\033[0m"

info() { echo -e "${YELLOW}→${RESET} $*"; }
ok()   { echo -e "${GREEN}✔${RESET} $*"; }
err()  { echo -e "${RED}✖${RESET} $*"; }

# --- API key vragen (of uit env halen) ---
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  info "OpenRouter API key is nodig (format: sk-or-...)"
  read -rp "Voer je OpenRouter API key in: " OPENROUTER_API_KEY
  if [[ ! "$OPENROUTER_API_KEY" =~ ^sk-or- ]]; then
    err "Ongeldige API key. Zorg dat deze begint met 'sk-or-'."
    exit 1
  fi
  export OPENROUTER_API_KEY
  ok "API key ontvangen"
else
  ok "API key gevonden in environment"
fi

# --- Hoofdscript ophalen en uitvoeren ---
info "Start installatie in home directory..."
curl -fsSL https://raw.githubusercontent.com/Omaha2002/remote-ai-ssh/main/remote_install_user_home.sh | bash

#!/usr/bin/env bash
set -euo pipefail

# ========== Kleuren ==========
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RESET="\033[0m"

info()  { echo -e "${CYAN}→${RESET} $*"; }
ok()    { echo -e "${GREEN}✔${RESET} $*"; }
warn()  { echo -e "${YELLOW}!${RESET} $*"; }
err()   { echo -e "${RED}✖${RESET} $*" >&2; }

# ========== Directories ==========
PREFIX="$HOME/.local"
BIN="$PREFIX/bin"
CONFIG="$HOME/.config"

mkdir -p "$BIN" "$CONFIG"

# ========== API Key ==========
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo
  echo "OpenRouter API key is nodig (format: sk-or-...)"
  read -rp "Voer je OpenRouter API key in: " OPENROUTER_API_KEY
  if [[ ! "$OPENROUTER_API_KEY" =~ ^sk-or- ]]; then
    err "Ongeldige API key."
    exit 1
  fi
fi
ok "API key ontvangen"

# ========== PATH ==========
if [[ ":$PATH:" != *":$BIN:"* ]]; then
  export PATH="$BIN:$PATH"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi

# ========== Fish installeren ==========
info "Fish shell installeren…"
if ! command -v fish >/dev/null 2>&1; then
  if command -v apt >/dev/null 2>&1; then
    sudo apt update -y
    sudo apt install -y fish
  else
    warn "apt niet gevonden; sla fish installatie over."
  fi
else
  ok "Fish al aanwezig"
fi

# ========== Zellij installeren ==========
info "Zellij installeren…"
if ! command -v zellij >/dev/null 2>&1; then
  ZELLIJ_URL="https://github.com/zellij-org/zellij/releases/latest/download/zellij-x86_64-unknown-linux-musl.tar.gz"
  curl -fsSL "$ZELLIJ_URL" | tar -xz -C /tmp
  mv /tmp/zellij "$BIN/"
  chmod +x "$BIN/zellij"
  ok "Zellij geïnstalleerd in $BIN/zellij"
else
  ok "Zellij al aanwezig: $(zellij --version)"
fi

# ========== Starship installeren ==========
info "Starship installeren…"
if ! command -v starship >/dev/null 2>&1; then
  curl -fsSL https://starship.rs/install.sh | bash -s -- -b "$BIN" -y
  ok "Starship geïnstalleerd: $("$BIN/starship" --version)"
else
  ok "Starship al aanwezig: $(starship --version)"
fi

# ========== aichat installeren ==========
info "aichat installeren…"
if ! command -v aichat >/dev/null 2>&1; then
  AICHAT_URL="https://github.com/sigoden/aichat/releases/latest/download/aichat-x86_64-unknown-linux-musl.tar.gz"
  if curl -fsSL "$AICHAT_URL" | tar -xz -C /tmp; then
    mv /tmp/aichat "$BIN/"
    chmod +x "$BIN/aichat"
    ok "aichat geïnstalleerd in $BIN/aichat"
  else
    warn "Kon aichat niet installeren. Installeer later handmatig."
  fi
else
  ok "aichat al aanwezig: $(aichat --version || true)"
fi

# ========== Config: Starship ==========
info "Starship config schrijven…"
mkdir -p "$CONFIG"
cat > "$CONFIG/starship.toml" <<'TOML'
# Minimal starship config
add_newline = false

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
vicmd_symbol = "[❮](bold yellow)"
TOML
ok "Starship config geschreven naar $CONFIG/starship.toml"

# ========== Config: Fish ==========
info "Fish config schrijven…"
mkdir -p "$CONFIG/fish"
cat > "$CONFIG/fish/config.fish" <<'FISH'
if status is-interactive
  starship init fish | source
end

# AI wrapper (Enter hook)
function fish_postexec --on-event fish_postexec
  if test -s /tmp/fish_last_stderr.log
    set cmd (cat /tmp/fish_last_cmd.log)
    set err (cat /tmp/fish_last_stderr.log)
    echo "AI suggestie voor: $cmd"
    aichat -m openai/gpt-4o-mini "Foutmelding: $err\nGeef een suggestie om dit te fixen."
  end
end

function fish_preexec --on-event fish_preexec
  echo $argv > /tmp/fish_last_cmd.log
end

function fish_handle_error --on-event fish_posterror
  echo $argv > /tmp/fish_last_stderr.log
end
FISH
ok "Fish config geschreven naar $CONFIG/fish/config.fish"

# ========== Config: aichat ==========
info "aichat configureren…"
mkdir -p "$CONFIG/aichat"
cat > "$CONFIG/aichat/config.yaml" <<YAML
default:
  adapter: openai
  api_base: https://openrouter.ai/api/v1
  api_key: $OPENROUTER_API_KEY
  model: openai/gpt-4o-mini
YAML
ok "aichat config geschreven naar $CONFIG/aichat/config.yaml"

# ========== Config: Zellij Layout ==========
info "Zellij layouts plaatsen…"
mkdir -p "$CONFIG/zellij/layouts"
cat > "$CONFIG/zellij/layouts/copilot.kdl" <<'KDL'
layout {
  pane {
    command "fish"
  }
  pane split_direction="horizontal" {
    pane {
      command "tail"
      args "-f" "/tmp/fish_last_stderr.log"
    }
  }
}
KDL
ok "Zellij layout geschreven naar $CONFIG/zellij/layouts/copilot.kdl"

# ========== Bash wrapper ==========
info "Bash AI-wrapper toevoegen…"
cat >> "$HOME/.bashrc" <<'BASH'
# AI wrapper function
r() {
  "$@" 2> >(tee /tmp/last_stderr.log >&2)
  if [ -s /tmp/last_stderr.log ]; then
    echo "AI suggestie voor: $*"
    aichat -m openai/gpt-4o-mini "Foutmelding: $(cat /tmp/last_stderr.log)\nGeef een suggestie om dit te fixen."
  fi
}
BASH
ok "Bash wrapper toegevoegd"

# ========== Eind ==========
echo
ok "KLAAR! Alles geïnstalleerd in $HOME/.local/bin"

echo
echo "Volgende stappen:"
echo "1) Herlaad je shell:  exec \$SHELL -l"
echo "2) Start copilot:    zellij --layout copilot"
echo "3) In Bash:          r <commando>"
echo "4) In Fish:          gebruik gewoon Enter, AI helpt bij fouten."

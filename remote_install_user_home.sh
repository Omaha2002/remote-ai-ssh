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

# --- Check of API key is gezet ---
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  err "Geen OpenRouter API key gevonden. Start via install.sh of geef de key mee als env var."
  exit 1
fi

BASE="$HOME/.local"
mkdir -p "$BASE/bin" "$HOME/.config" "$HOME/.config/fish/functions" "$HOME/.config/zellij/layouts" "$HOME/.config/aichat"

info "Installatie in HOME-directory starten…"

# --- Starship installeren ---
info "Starship installeren in $BASE/bin…"
curl -fsSL https://starship.rs/install.sh | sh -s -- -b "$BASE/bin" -y
ok "Starship geïnstalleerd: $("$BASE/bin/starship" --version)"

# --- Starship config ---
cat > "$HOME/.config/starship.toml" <<'TOML'
# Minimal starship config
add_newline = true

[time]
disabled = true
TOML
ok "Starship config geschreven: $HOME/.config/starship.toml"

# --- Fish configuratie ---
cat > "$HOME/.config/fish/config.fish" <<'FISH'
if status is-interactive
  # Starship
  starship init fish | source
end

# AI functie (via aichat)
function ai
    aichat $argv
end
FISH
ok "Fish config geplaatst: $HOME/.config/fish/config.fish"

# --- Zellij layouts ---
cat > "$HOME/.config/zellij/layouts/copilot.kdl" <<'KDL'
layout {
  pane {
    command "fish"
  }
  pane split_direction="horizontal" {
    pane { command "tail" args="-f" args="/tmp/fish_last_stderr.log" }
  }
}
KDL
ok "Zellij layouts geplaatst: copilot"

# --- aichat config ---
cat > "$HOME/.config/aichat/config.yaml" <<YAML
default_provider: openrouter
providers:
  - name: openrouter
    api_base: https://openrouter.ai/api/v1
    api_key: "$OPENROUTER_API_KEY"
YAML
ok "aichat config geschreven: $HOME/.config/aichat/config.yaml"

# --- AI wrapper (bash) ---
cat > "$HOME/.local/bin/r" <<'BASH'
#!/usr/bin/env bash
# Run a command and if it fails, ask AI for help
LOG="/tmp/fish_last_stderr.log"
"$@" 2> >(tee "$LOG" >&2)
STATUS=$?
if [ $STATUS -ne 0 ]; then
  echo "✖ Command faalde. AI suggesties volgen:" >&2
  aichat "Ik voerde dit commando uit en kreeg de foutmelding:\n\n$@\n\n$(cat "$LOG")\n\nHoe los ik dit op?"
fi
exit $STATUS
BASH
chmod +x "$HOME/.local/bin/r"
ok "AI-wrapper geplaatst: gebruik 'r <commando>' voor suggesties"

ok "KLAAR! Alles is in je HOME-directory geïnstalleerd."

echo -e "\nVolgende stappen:"
echo "1) Voeg $BASE/bin aan je PATH toe, bv. in ~/.bashrc of ~/.zshrc:"
echo "     export PATH=\"\$HOME/.local/bin:\$PATH\""
echo "2) Start een nieuwe shell: exec \$SHELL -l"
echo "3) Start Zellij copilot:  zellij --layout copilot"
echo "4) Test AI: ai 'Geef 3 fish alias-ideeën'"
echo "5) Of gebruik wrapper: r ls /not_existing_dir"

#!/usr/bin/env bash
set -euo pipefail

# ========== UI helpers ==========
GREEN="\033[1;32m"; RED="\033[1;31m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"
info(){ echo -e "${CYAN}→${RESET} $*"; }
ok(){   echo -e "${GREEN}✔${RESET} $*"; }
warn(){ echo -e "${YELLOW}!${RESET} $*"; }
die(){  echo -e "${RED}✖${RESET} $*" >&2; exit 1; }

# ========== Vars ==========
HOME_DIR="$HOME"
LOCAL_BIN="$HOME_DIR/.local/bin"
CONFIG_DIR="$HOME_DIR/.config"
FISH_DIR="$CONFIG_DIR/fish"
FISH_CONFD="$FISH_DIR/conf.d"
ZELLIJ_DIR="$CONFIG_DIR/zellij/layouts"
AICHAT_DIR="$CONFIG_DIR/aichat"
ERRLOG="/tmp/fish_last_stderr.log"

mkdir -p "$LOCAL_BIN" "$FISH_CONFD" "$ZELLIJ_DIR" "$AICHAT_DIR"

# ========== PATH ensure (bash/sh) ==========
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME_DIR/.profile" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.profile"
fi
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME_DIR/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"
fi
export PATH="$LOCAL_BIN:$PATH"

# ========== OpenRouter API Key ==========
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo
  echo -e "${CYAN}OpenRouter API key is nodig (format: sk-or-...)${RESET}"
  read -r -p "Voer je OpenRouter API key in: " OPENROUTER_API_KEY
fi
[[ -z "$OPENROUTER_API_KEY" || ! "$OPENROUTER_API_KEY" =~ ^sk-or- ]] && die "Ongeldige of lege API key."

ok "API key ontvangen"

# ========== Starship ==========
install_starship() {
  if command -v starship >/dev/null 2>&1; then
    ok "Starship aanwezig: $(starship --version | head -n1)"
    return
  fi
  info "Starship installeren in $LOCAL_BIN…"
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y --bin-dir "$LOCAL_BIN"
  ok "Starship geïnstalleerd: $("$LOCAL_BIN/starship" --version | head -n1)"
  # Bash init
  grep -q 'starship init bash' "$HOME_DIR/.bashrc" 2>/dev/null || \
    printf '\n# Starship prompt\neval "$(starship init bash)"\n' >> "$HOME_DIR/.bashrc"
}
install_starship

# ========== Zellij (release binary; géén Snap) ==========
install_zellij() {
  if command -v zellij >/dev/null 2>&1; then
    ok "Zellij aanwezig: $(zellij --version 2>/dev/null | head -n1)"
    return
  fi
  local arch trip
  arch="$(uname -m)"
  case "$arch" in
    x86_64) trip="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) trip="aarch64-unknown-linux-gnu" ;;
    *) die "Onbekende architectuur voor Zellij: $arch" ;;
  esac
  info "Zellij downloaden (standalone, $trip)…"
  tmpd="$(mktemp -d)"
  curl -fsSL "https://github.com/zellij-org/zellij/releases/latest/download/zellij-${trip}.tar.gz" | tar -xz -C "$tmpd"
  mv "$tmpd/zellij" "$LOCAL_BIN/zellij"
  chmod +x "$LOCAL_BIN/zellij"
  rm -rf "$tmpd"
  ok "Zellij geïnstalleerd: $("$LOCAL_BIN/zellij" --version | head -n1)"
}
install_zellij

# ========== Rust + aichat (user-space) ==========
install_aichat() {
  if command -v aichat >/dev/null 2>&1; then
    ok "aichat aanwezig: $(aichat --version | head -n1)"
    return
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    info "rustup/cargo (user-space) installeren…"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # shellenv
    if [ -f "$HOME_DIR/.cargo/env" ]; then
      grep -q 'source "$HOME/.cargo/env"' "$HOME_DIR/.profile" 2>/dev/null || \
        echo 'source "$HOME/.cargo/env"' >> "$HOME_DIR/.profile"
      # shellcheck disable=SC1090
      source "$HOME_DIR/.cargo/env"
    fi
  fi
  info "aichat via cargo installeren…"
  cargo install aichat --locked
  ln -sf "$HOME_DIR/.cargo/bin/aichat" "$LOCAL_BIN/aichat"
  ok "aichat geïnstalleerd: $("$HOME_DIR/.cargo/bin/aichat" --version | head -n1)"
}
install_aichat || warn "Kon aichat niet automatisch installeren; je kunt later 'cargo install aichat' draaien."

# ========== Starship config ==========
info "Starship config schrijven…"
cat > "$CONFIG_DIR/starship.toml" <<'TOML'
add_newline = false
format = "$all$fill$time$line_break$character"

[time]
disabled = false
format = "[$time]($style) "
time_format = "%H:%M"

[git_branch]
truncation_length = 24

[cmd_duration]
min_time = 500
show_notifications = false
TOML
ok "Starship config: $CONFIG_DIR/starship.toml"

# ========== Fish config + AI-copilot hook ==========
info "Fish config + AI-copilot hook plaatsen…"
mkdir -p "$FISH_DIR"
cat > "$FISH_DIR/config.fish" <<'FISH'
# Prompt
if type -q starship
  starship init fish | source
end

# fzf keybindings (als aanwezig)
if type -q fzf
  function fish_user_key_bindings
    fzf --fish | source
  end
end

# Ubuntu aliasen
if type -q batcat
  alias bat="batcat"
end
if type -q fdfind
  alias fd="fdfind"
end
FISH

# AI-copilot: Enter = AI-aware, Alt+Enter = normaal
cat > "$FISH_CONFD/ai_copilot.fish" <<'FISH'
function __ai_handle_failure
    set -l lastcmd "$argv"
    set -l errlog (command tail -n 120 /tmp/fish_last_stderr.log ^/dev/null)
    if test -n "$errlog"
        echo -e "\n❌ Commando faalde: $lastcmd\n→ AI suggestie:"
        if type -q aichat
            echo $errlog | aichat "Het commando '$lastcmd' faalde. Analyseer de fout en geef concrete stappen om te fixen. Toon commando's."
        else
            echo "(aichat niet gevonden) Installeer aichat voor automatische suggesties."
        end
    else
        echo -e "\n❌ Commando faalde: $lastcmd (geen stderr opgevangen)"
    end
end

function accept_line_with_ai
    set -l cmd (commandline -b)
    if test -z (string trim -- $cmd)
        commandline -f execute
        return
    end
    commandline -r ""
    : > /tmp/fish_last_stderr.log
    eval $cmd 2>>/tmp/fish_last_stderr.log
    set -l st $status
    if test $st -ne 0
        __ai_handle_failure $cmd
    end
end

# Enter met AI, Alt+Enter normaal
bind \r accept_line_with_ai
bind \e\r 'commandline -f execute'
FISH
ok "Fish AI-hook actief"

# Als fish bestaat, zorg dat ~/.local/bin beschikbaar is (universele var)
if command -v fish >/dev/null 2>&1; then
  fish -lc 'set -q fish_user_paths[1]; or set -Ux fish_user_paths $HOME/.local/bin $fish_user_paths' >/dev/null 2>&1 || true
fi

# ========== Zellij layout: top = shell, bottom = stderr-log ==========
info "Zellij layout (verticale 2-pane) schrijven…"
SHELL_CMD="fish"; command -v fish >/dev/null 2>&1 || SHELL_CMD="bash"
cat > "$ZELLIJ_DIR/copilot.kdl" <<KDL
layout {
  pane split_direction="vertical" {
    pane command="${SHELL_CMD}"
    pane command="bash" {
      args "-lc" "touch ${ERRLOG}; tail -f ${ERRLOG}"
    }
  }
}
KDL
ok "Zellij layout geplaatst: $ZELLIJ_DIR/copilot.kdl"

# ========== aichat config ==========
info "aichat configureren…"
cat > "$AICHAT_DIR/config.yaml" <<YAML
model: openrouter:openrouter/auto
clients:
  - type: openai-compatible
    name: openrouter
    api_base: https://openrouter.ai/api/v1
    api_key: ${OPENROUTER_API_KEY}
YAML
ok "aichat config: $AICHAT_DIR/config.yaml"

# ========== Bash wrapper 'r' ==========
info "Bash AI-wrapper 'r' toevoegen…"
cat > "$LOCAL_BIN/r" <<'BASH'
#!/usr/bin/env bash
LOG="/tmp/fish_last_stderr.log"
: > "$LOG"
"$@" 2>>"$LOG"
status=$?
if [ $status -ne 0 ]; then
  if command -v aichat >/dev/null 2>&1; then
    echo "❌ Commando faalde: $*"
    tail -n 120 "$LOG" | aichat "Het commando '$*' faalde (exit $status). Analyseer de fout en geef concrete stappen om te fixen. Toon commando's."
  else
    echo "❌ Commando faalde (exit $status). Installeer 'aichat' voor automatische hulp."
  fi
fi
exit $status
BASH
chmod +x "$LOCAL_BIN/r"
ok "Bash wrapper klaar: gebruik 'r <commando>'"

# ========== Klaar ==========
echo
ok "KLAAR! Alles is in je HOME-directory geïnstalleerd."
echo
echo "Volgende stappen:"
echo "  1) Herlaad je shell:  ${CYAN}exec \$SHELL -l${RESET}"
echo "  2) Start Zellij:      ${CYAN}zellij --layout copilot${RESET}"
echo "     - Boven: interactieve ${CYAN}${SHELL_CMD}${RESET} (AI-hook)"
echo "     - Onder: live stderr: ${CYAN}${ERRLOG}${RESET}"
echo "  3) In bash kun je ook: ${CYAN}r <commando>${RESET}  (AI-suggesties bij fouten)"
echo "  4) In Fish: Enter = AI-aware; Alt+Enter = normaal uitvoeren."

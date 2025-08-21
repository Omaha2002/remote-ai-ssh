#!/usr/bin/env bash
set -euo pipefail

# ========== UI helpers (ANSI colors) ==========
GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[1;36m'; RESET=$'\033[0m'
info(){ printf '%b→%b %s\n' "$CYAN" "$RESET" "$*"; }
ok(){   printf '%b✔%b %s\n' "$GREEN" "$RESET" "$*"; }
warn(){ printf '%b!%b %s\n' "$YELLOW" "$RESET" "$*"; }
die(){  printf '%b✖%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ========== Vars & dirs ==========
HOME_DIR="$HOME"
LOCAL_BIN="$HOME_DIR/.local/bin"
CONFIG_DIR="$HOME_DIR/.config"
FISH_DIR="$CONFIG_DIR/fish"
FISH_CONFD="$FISH_DIR/conf.d"
ZELLIJ_DIR="$CONFIG_DIR/zellij/layouts"
AICHAT_DIR="$CONFIG_DIR/aichat"
ERRLOG="/tmp/fish_last_stderr.log"
AILOG="/tmp/ai_suggestions.log"

mkdir -p "$LOCAL_BIN" "$FISH_CONFD" "$ZELLIJ_DIR" "$AICHAT_DIR"

# Ensure PATH (current & future sessions)
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME_DIR/.profile" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.profile"
end 2>/dev/null || true
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME_DIR/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"
fi
export PATH="$LOCAL_BIN:$PATH"

# ========== OpenRouter API Key ==========
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  printf '%sOpenRouter API key is needed (format: sk-or-...)%s\n' "$CYAN" "$RESET"
  read -r -p "Enter your OpenRouter API key: " OPENROUTER_API_KEY
fi
[[ -z "$OPENROUTER_API_KEY" || ! "$OPENROUTER_API_KEY" =~ ^sk-or- ]] && die "Invalid or empty API key."
ok "API key received"

# ========== Starship ==========
install_starship() {
  if command -v starship >/dev/null 2>&1; then
    ok "Starship present: $(starship --version | head -n1)"
    return
  fi
  info "Installing Starship in $LOCAL_BIN…"
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y --bin-dir "$LOCAL_BIN"
  ok "Starship installed: $("$LOCAL_BIN/starship" --version | head -n1)"
  grep -q 'starship init bash' "$HOME_DIR/.bashrc" 2>/dev/null || \
    printf '\n# Starship prompt\neval "$(starship init bash)"\n' >> "$HOME_DIR/.bashrc"
}
install_starship

# ========== Zellij (release binary; no Snap) ==========
install_zellij() {
  if command -v zellij >/dev/null 2>&1; then
    ok "Zellij present: $(zellij --version 2>/dev/null | head -n1)"
    return
  fi
  local arch trip
  arch="$(uname -m)"
  case "$arch" in
    x86_64) trip="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) trip="aarch64-unknown-linux-gnu" ;;
    *) die "Unsupported architecture for Zellij: $arch" ;;
  esac
  info "Downloading Zellij (standalone, $trip)…"
  tmpd="$(mktemp -d)"
  curl -fsSL "https://github.com/zellij-org/zellij/releases/latest/download/zellij-${trip}.tar.gz" | tar -xz -C "$tmpd"
  mv "$tmpd/zellij" "$LOCAL_BIN/zellij"
  chmod +x "$LOCAL_BIN/zellij"
  rm -rf "$tmpd"
  ok "Zellij installed: $("$LOCAL_BIN/zellij" --version | head -n1)"
}
install_zellij

# ========== Rust + aichat (user-space) ==========
install_aichat() {
  if command -v aichat >/dev/null 2>&1; then
    ok "aichat present: $(aichat --version | head -n1)"
    return
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    info "Installing rustup/cargo (user-space)…"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    if [ -f "$HOME_DIR/.cargo/env" ]; then
      grep -q 'source "$HOME/.cargo/env"' "$HOME_DIR/.profile" 2>/dev/null || \
        echo 'source "$HOME/.cargo/env"' >> "$HOME_DIR/.profile"
      # shellcheck disable=SC1090
      source "$HOME_DIR/.cargo/env"
    fi
  fi
  info "Installing aichat via cargo…"
  cargo install aichat --locked
  ln -sf "$HOME_DIR/.cargo/bin/aichat" "$LOCAL_BIN/aichat"
  ok "aichat installed: $("$HOME_DIR/.cargo/bin/aichat" --version | head -n1)"
}
install_aichat || warn "Could not auto-install aichat; run 'cargo install aichat' later."

# ========== Starship config ==========
info "Writing Starship config…"
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

# ========== Fish config + AI-copilot (TTY auto-fix & prompt repaint) ==========
info "Placing Fish config + AI-copilot hook…"
mkdir -p "$FISH_DIR"
cat > "$FISH_DIR/config.fish" <<'FISH'
# Prompt
if type -q starship
  starship init fish | source
end

# Auto-fix TTY (re-enable echo if disabled)
if status is-interactive
  if type -q stty
    if test -t 1
      set -l s (stty -a 2>/dev/null)
      if string match -q '*-echo*' -- $s
        stty sane
      end
    end
  end
end

# fzf keybindings (if present)
if type -q fzf
  function fish_user_key_bindings
    fzf --fish | source
  end
end

# Ubuntu aliases
if type -q batcat
  alias bat="batcat"
end
if type -q fdfind
  alias fd="fdfind"
end
FISH

# AI-copilot: Enter = AI-aware, Alt+Enter = normal; AI output -> /tmp/ai_suggestions.log
cat > "$FISH_CONFD/ai_copilot.fish" <<'FISH'
set -g __ai_log "/tmp/ai_suggestions.log"

function __ai_append
    set -l msg "$argv"
    set -l ts (date "+%Y-%m-%d %H:%M:%S")
    echo -e "\n=== [$ts] $msg ===" >> $__ai_log
end

function __ai_handle_failure
    set -l lastcmd "$argv"
    set -l errlog (command tail -n 60 /tmp/fish_last_stderr.log ^/dev/null)
    if test -n "$errlog"
        __ai_append "Command: $lastcmd"
        if type -q aichat
            # concise instruction: ≤3 lines, commands only
            echo $errlog | aichat "Fix the failure of '$lastcmd'. Reply concisely (<=3 lines) with commands only." >> $__ai_log
        else
            echo "(aichat not found) Install aichat for automatic suggestions." >> $__ai_log
        end
    end
end

function accept_line_with_ai
    set -l cmd (commandline -b)
    if test -z (string trim -- $cmd)
        commandline -f execute
        return
    end
    commandline -r ""                       # clear input
    : > /tmp/fish_last_stderr.log
    eval $cmd 2>>/tmp/fish_last_stderr.log  # run & capture stderr
    set -l st $status
    if test $st -ne 0
        __ai_handle_failure $cmd
    end
    commandline -f repaint                  # show prompt immediately
end

# Enter with AI; Alt+Enter without AI
bind \r accept_line_with_ai
bind \e\r 'commandline -f execute'
FISH
ok "Fish AI hook active (prompt repaint, AI -> $AILOG)"

# Ensure Fish sees ~/.local/bin (universal var)
if command -v fish >/dev/null 2>&1; then
  fish -lc 'set -q fish_user_paths[1]; or set -Ux fish_user_paths $HOME/.local/bin $fish_user_paths' >/dev/null 2>&1 || true
fi

# ========== Zellij layout: left/top shell, left/bottom stderr, right AI log ==========
info "Writing Zellij layout (3 panes)…"
SHELL_CMD="fish"; command -v fish >/dev/null 2>&1 || SHELL_CMD="bash"
cat > "$ZELLIJ_DIR/copilot.kdl" <<KDL
layout {
  pane split_direction="horizontal" {
    pane split_direction="vertical" {
      pane command="${SHELL_CMD}"
      pane command="bash" {
        args "-lc" "touch ${ERRLOG}; tail -f ${ERRLOG}"
      }
    }
    pane command="bash" {
      args "-lc" "touch ${AILOG}; tail -f ${AILOG}"
    }
  }
}
KDL
ok "Zellij layout placed: $ZELLIJ_DIR/copilot.kdl"

# ========== aichat config (Qwen3 Coder via OpenRouter) ==========
info "Configuring aichat (model: Qwen3 Coder)…"
OPENROUTER_MODEL="${OPENROUTER_MODEL:-qwen/qwen3-coder}"
cat > "$AICHAT_DIR/config.yaml" <<YAML
model: openrouter:${OPENROUTER_MODEL}
clients:
  - type: openai-compatible
    name: openrouter
    api_base: https://openrouter.ai/api/v1
    api_key: ${OPENROUTER_API_KEY}
YAML
ok "aichat config: $AICHAT_DIR/config.yaml"

# ========== Bash wrapper 'r' (AI -> /tmp/ai_suggestions.log) ==========
info "Adding Bash AI wrapper 'r'…"
cat > "$LOCAL_BIN/r" <<'BASH'
#!/usr/bin/env bash
LOG="/tmp/fish_last_stderr.log"
AILOG="/tmp/ai_suggestions.log"
: > "$LOG"
"$@" 2>>"$LOG"
status=$?
if [ $status -ne 0 ]; then
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  {
    echo
    echo "=== [$ts] Command: $* ==="
    if command -v aichat >/dev/null 2>&1; then
      tail -n 60 "$LOG" | aichat "Fix the failure of '$*'. Reply concisely (<=3 lines) with commands only."
    else
      echo "(aichat not found) Install aichat for automatic suggestions."
    fi
  } >> "$AILOG"
fi
exit $status
BASH
chmod +x "$LOCAL_BIN/r"
ok "Bash wrapper ready: use 'r <command>' (AI -> $AILOG)"

# ========== Done ==========
printf '\n%sDONE! Everything installed in your HOME directory.%s\n\n' "$GREEN" "$RESET"
printf 'Next steps:\n'
printf '  1) Reload your shell:  %sexec $SHELL -l%s\n' "$CYAN" "$RESET"
printf '  2) Start Zellij:       %szellij --layout copilot%s\n' "$CYAN" "$RESET"
printf '     - Left/Top: interactive %s%s%s (AI hook)\n' "$CYAN" "$SHELL_CMD" "$RESET"
printf '     - Left/Bottom: live stderr: %s%s%s\n' "$CYAN" "$ERRLOG" "$RESET"
printf '     - Right: AI suggestions:   %s%s%s\n' "$CYAN" "$AILOG" "$RESET"
printf '  3) In bash you can also: %sr <command>%s  (AI suggestions on failure)\n' "$CYAN" "$RESET"
printf '  4) In Fish: Enter = AI-aware; Alt+Enter = normal execute.\n'

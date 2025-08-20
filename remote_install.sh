#!/usr/bin/env bash
set -euo pipefail

# ===== UI helpers =====
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
die(){ echo "${RED}✖ $*${RST}" >&2; exit 1; }
ok(){  echo "${GRN}✔ $*${RST}"; }
info(){ echo "${BLU}→ $*${RST}"; }
warn(){ echo "${YLW}! $*${RST}"; }

# ===== Vars & dirs =====
OS="$(uname -s || echo)"
ARCH="$(uname -m || echo)"
HOME_DIR="${HOME}"
LOCAL_BIN="$HOME_DIR/.local/bin"
CONFIG_DIR="$HOME_DIR/.config"
AICHAT_DIR="$CONFIG_DIR/aichat"
FISH_CONF_DIR="$CONFIG_DIR/fish"
FISH_CONFD_DIR="$FISH_CONF_DIR/conf.d"
ZELLIJ_LAYOUT_DIR="$CONFIG_DIR/zellij/layouts"
ERRLOG="/tmp/fish_last_stderr.log"

mkdir -p "$LOCAL_BIN" "$AICHAT_DIR" "$FISH_CONFD_DIR" "$ZELLIJ_LAYOUT_DIR"

# ===== PATH ensure =====
ensure_path() {
  if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME_DIR/.profile" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.profile"
  fi
  if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME_DIR/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"
  fi
  export PATH="$LOCAL_BIN:$PATH"
}
ensure_path

# ===== Vraag om OpenRouter API key =====
echo
echo "${BLU}OpenRouter API key is nodig (format: sk-or-...)${RST}"
read -r -s -p "Voer je OpenRouter API key in: " OPENROUTER_API_KEY
echo
[[ -z "${OPENROUTER_API_KEY}" ]] && die "Geen API key opgegeven."
ok "API key ontvangen"

# ===== Detect arch helpers =====
detect_zellij_triplet(){
  case "$ARCH" in
    x86_64) echo "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    *) echo ""; return 1 ;;
  esac
}

# ===== Install: Starship (user-space) =====
install_starship(){
  if command -v starship >/dev/null 2>&1; then
    ok "Starship aanwezig: $(starship --version | head -n1)"
    return 0
  fi
  info "Starship installeren in $LOCAL_BIN…"
  mkdir -p "$LOCAL_BIN"
  if curl -fsSL https://starship.rs/install.sh | sh -s -- -y --bin-dir "$LOCAL_BIN"; then
    ok "Starship geïnstalleerd: $("$LOCAL_BIN/starship" --version | head -n1)"
    # Init voor bash automatisch toevoegen
    if ! grep -q 'starship init bash' "$HOME_DIR/.bashrc" 2>/dev/null; then
      printf '\n# Starship prompt\neval "$(starship init bash)"\n' >> "$HOME_DIR/.bashrc"
    end
  else
    die "Starship-installatie mislukt"
  fi
}

# ===== Install: Zellij (release binary → ~/.local/bin) =====
install_zellij(){
  if command -v zellij >/dev/null 2>&1; then
    ok "Zellij aanwezig: $(zellij --version 2>/dev/null | head -n1)"
    return 0
  fi
  [[ "$OS" != "Linux" ]] && die "Zellij-installatie verwacht Linux (remote host)."

  local triplet; triplet="$(detect_zellij_triplet || true)"
  [[ -z "${triplet:-}" ]] && die "Onbekende CPU-architectuur ($ARCH) voor Zellij."

  local url="https://github.com/zellij-org/zellij/releases/latest/download/zellij-${triplet}.tar.gz"
  info "Zellij downloaden: $url"
  tmpdir="$(mktemp -d)"
  if curl -fsSL "$url" | tar -xz -C "$tmpdir"; then
    mv "$tmpdir/zellij" "$LOCAL_BIN/zellij"
    chmod +x "$LOCAL_BIN/zellij"
    rm -rf "$tmpdir"
    ok "Zellij geïnstalleerd: $("$LOCAL_BIN/zellij" --version | head -n1)"
  else
    die "Zellij-installatie mislukt (download)."
  fi
}

# ===== Install: Rust + aichat (user-space) =====
install_aichat(){
  if command -v aichat >/dev/null 2>&1; then
    ok "aichat aanwezig: $(aichat --version | head -n1)"
    return 0
  fi
  # Rust toolchain
  if ! command -v cargo >/dev/null 2>&1; then
    info "rustup (user-space) installeren…"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    if [ -f "$HOME_DIR/.cargo/env" ]; then
      grep -q 'source "$HOME/.cargo/env"' "$HOME_DIR/.profile" 2>/dev/null || echo 'source "$HOME/.cargo/env"' >> "$HOME_DIR/.profile"
      # shellcheck disable=SC1090
      source "$HOME_DIR/.cargo/env"
    else
      warn "Kon ~/.cargo/env niet vinden; zorg dat cargo op PATH staat."
    fi
  fi
  if command -v cargo >/dev/null 2>&1; then
    info "aichat via cargo installeren (user-space)…"
    cargo install aichat --locked
    ln -sf "$HOME_DIR/.cargo/bin/aichat" "$LOCAL_BIN/aichat"
    ok "aichat geïnstalleerd: $("$HOME_DIR/.cargo/bin/aichat" --version | head -n1)"
  else
    warn "Cargo ontbreekt; kon aichat niet installeren. Je kunt later 'cargo install aichat' draaien."
  fi
}

# ===== Config: Starship TOML =====
write_starship(){
  info "Starship configureren…"
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
  ok "Starship config geschreven: $CONFIG_DIR/starship.toml"
}

# ===== Config: Fish (basis + AI-copilot hook) =====
write_fish_configs(){
  info "Fish configuratie voorbereiden…"
  cat > "$FISH_CONF_DIR/config.fish" <<'FISH'
# Prompt
if type -q starship
  starship init fish | source
end

# fzf keybindings
if type -q fzf
  function fish_user_key_bindings
    fzf --fish | source
  end
end

# Aliases (Ubuntu bat/batcat, fd-find)
if type -q batcat
  alias bat="batcat"
end
if type -q fdfind
  alias fd="fdfind"
end
FISH

  # AI-copilot hook (Enter = AI-aware; Alt+Enter = normaal)
  cat > "$FISH_CONFD_DIR/ai_copilot.fish" <<'FISH'
function __ai_handle_failure
    set -l lastcmd "$argv"
    set -l errlog (command tail -n 120 /tmp/fish_last_stderr.log ^/dev/null)
    if test -n "$errlog"
        echo -e "\n❌ Commando faalde: $lastcmd\n→ AI suggestie:"
        if type -q aichat
            echo $errlog | aichat "Het commando '$lastcmd' faalde. Analyseer de fout en geef concrete stappen om te fixen. Toon commando's."
        else
            echo "(aichat niet gevonden) Installeer aichat om automatische suggesties te krijgen."
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

bind \r accept_line_with_ai
bind \e\r 'commandline -f execute'
FISH
  ok "Fish config + AI-copilot hook geplaatst onder $FISH_CONF_DIR"
}

# ===== Zellij layouts =====
write_zellij_layouts(){
  info "Zellij layouts schrijven…"
  # generieke dev-layout
  cat > "$ZELLIJ_LAYOUT_DIR/dev.kdl" <<'KDL'
layout {
  pane size=1 borderless=true {
    plugin location="zellij:tab-bar"
  }
  pane split_direction="vertical" {
    pane
    pane split_direction="horizontal" {
      pane
      pane
    }
  }
}
KDL

  # copilot-layout: shell links, errorlog rechts
  local shell_cmd="bash"
  if command -v fish >/dev/null 2>&1; then shell_cmd="fish"; fi

  cat > "$ZELLIJ_LAYOUT_DIR/copilot.kdl" <<KDL
layout {
  pane command="${shell_cmd}"
  pane command="bash" {
    args "-lc" "touch ${ERRLOG}; tail -f ${ERRLOG}"
  }
}
KDL
  ok "Zellij layouts geplaatst: dev, copilot"
}

# ===== aichat config =====
write_aichat_config(){
  info "aichat configureren met OpenRouter key…"
  cat > "$AICHAT_DIR/config.yaml" <<YAML
model: openrouter:openrouter/auto
clients:
  - type: openai-compatible
    name: openrouter
    api_base: https://openrouter.ai/api/v1
    api_key: ${OPENROUTER_API_KEY}
YAML
  ok "aichat config geschreven: $AICHAT_DIR/config.yaml"
}

# ===== AI wrapper voor bash =====
write_ai_wrapper(){
  info "AI-wrapper plaatsen (aiwrap + bash functie 'r')…"
  cat > "$LOCAL_BIN/aiwrap" <<'SH'
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
SH
  chmod +x "$LOCAL_BIN/aiwrap"

  if ! grep -q "^r\(\)" "$HOME_DIR/.bashrc" 2>/dev/null; then
    cat >> "$HOME_DIR/.bashrc" <<'BASHF'
# Run with AI: r <command>
r() { aiwrap "$@"; }
BASHF
  fi
  ok "AI-wrapper klaar: gebruik 'r <cmd>' in bash; of gebruik Fish-Enter hook."
}

# ===== RUN =====
echo
info "Installatie in HOME-directory starten…"
install_starship
install_zellij
install_aichat || true
write_starship
write_fish_configs
write_zellij_layouts
write_aichat_config
write_ai_wrapper

echo
ok "KLAAR! Alles is in je HOME-directory geïnstalleerd."
echo
echo "Volgende stappen:"
echo "1) Laad je shell opnieuw: ${BLU}exec \$SHELL -l${RST}  (of log opnieuw in)"
echo "2) Start Zellij copilot:  ${BLU}zellij --layout copilot${RST}"
echo "   - Links: je shell (${BLU}fish${RST} als aanwezig, anders ${BLU}bash${RST})"
echo "   - Rechts: live foutenlog (${ERRLOG})"
echo "3) In bash kun je ook: ${BLU}r <commando>${RST}  (AI-suggesties bij fouten)"
echo "4) In Fish is Enter AI-aware; Alt+Enter voert zonder AI-hook uit."
echo
if command -v aichat >/dev/null 2>&1; then
  ok "aichat werkt. Test: ${BLU}aichat 'Waarom start nginx niet?'${RST}"
else
  warn "aichat kon niet automatisch geïnstalleerd worden. Na 'cargo install aichat' werkt het meteen zonder dit script opnieuw te draaien."
fi

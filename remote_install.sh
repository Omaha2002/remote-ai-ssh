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
LOCAL_BIN="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config"
AICHAT_DIR="$CONFIG_DIR/aichat"
FISH_CONF_DIR="$CONFIG_DIR/fish"
FISH_CONFD_DIR="$FISH_CONF_DIR/conf.d"
ZELLIJ_LAYOUT_DIR="$CONFIG_DIR/zellij/layouts"
ERRLOG="/tmp/fish_last_stderr.log"   # gebruiken we ook in bash

mkdir -p "$LOCAL_BIN" "$AICHAT_DIR" "$FISH_CONFD_DIR" "$ZELLIJ_LAYOUT_DIR"

# ===== PATH ensure =====
# Bash/sh login shells
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.profile" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"
fi
# Bash interactieve shells
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$LOCAL_BIN:$PATH"

# ===== Vraag om OpenRouter API key =====
echo
echo "${BLU}OpenRouter API key is nodig (format: sk-or-...)${RST}"
read -r -s -p "Voer je OpenRouter API key in: " OPENROUTER_API_KEY
echo
[[ -z "${OPENROUTER_API_KEY}" ]] && die "Geen API key opgegeven."
ok "API key ontvangen"

# ===== Detect arch helper =====
detect_zellij_triplet(){
  case "$ARCH" in
    x86_64) echo "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    *) echo ""; return 1 ;;
  esac
}
detect_aichat_triplet(){
  # aichat heeft doorgaans linux-x86_64 en linux-aarch64 archiven
  case "$ARCH" in
    x86_64) echo "linux-x86_64" ;;
    aarch64|arm64) echo "linux-aarch64" ;;
    *) echo ""; return 1 ;;
  esac
}

# ===== Install: Starship (naar ~/.local/bin) =====
install_starship(){
  if command -v starship >/dev/null 2>&1; then
    ok "Starship aanwezig: $(starship --version | head -n1)"
    return 0
  fi
  info "Starship installeren in $LOCAL_BIN…"
  mkdir -p "$LOCAL_BIN"
  if curl -fsSL https://starship.rs/install.sh | sh -s -- -y --bin-dir "$LOCAL_BIN"; then
    ok "Starship geïnstalleerd: $("$LOCAL_BIN/starship" --version | head -n1)"
    return 0
  fi
  die "Starship-installatie mislukt"
}

# ===== Install: Zellij (release binary naar ~/.local/bin) =====
install_zellij(){
  if command -v zellij >/dev/null 2>&1; then
    ok "Zellij aanwezig: $(zellij --version 2>/dev/null | head -n1)"
    return 0
  fi
  [[ "$OS" != "Linux" ]] && die "Zellij-installatie: verwacht Linux (remote host)."

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
    return 0
  fi
  die "Zellij-installatie mislukt (download)."
}

# ===== Install: aichat (release binary → ~/.local/bin), fallback op brew als aanwezig =====
install_aichat(){
  if command -v aichat >/dev/null 2>&1; then
    ok "aichat aanwezig: $(aichat --version | head -n1)"
    return 0
  fi

  local atrip; atrip="$(detect_aichat_triplet || true)"
  if [[ -n "$atrip" ]]; then
    # Probeer bekende release-naamgeving
    # Veelvoorkomende naam: aichat-${atrip}.tar.gz  (probeer ook .zip als fallback)
    info "aichat release-binary proberen te downloaden (triplet: $atrip)…"
    tmpdir="$(mktemp -d)"
    # Probeer tar.gz
    if curl -fsSL "https://github.com/sigoden/aichat/releases/latest/download/aichat-${atrip}.tar.gz" -o "$tmpdir/aichat.tgz"; then
      tar -xzf "$tmpdir/aichat.tgz" -C "$tmpdir" || true
    else
      # Probeer zip
      if curl -fsSL "https://github.com/sigoden/aichat/releases/latest/download/aichat-${atrip}.zip" -o "$tmpdir/aichat.zip"; then
        (cd "$tmpdir" && unzip -q aichat.zip) || true
      fi
    fi

    if [[ -f "$tmpdir/aichat" ]]; then
      mv "$tmpdir/aichat" "$LOCAL_BIN/aichat"
      chmod +x "$LOCAL_BIN/aichat"
      rm -rf "$tmpdir"
      ok "aichat geïnstalleerd: $("$LOCAL_BIN/aichat" --version | head -n1)"
      return 0
    else
      warn "Kon aichat release-binary niet plaatsen (andere bestandsnaamstructuur?)."
      rm -rf "$tmpdir"
    fi
  fi

  # Fallback op brew als die er al is (user-space brew kan bestaan)
  if command -v brew >/dev/null 2>&1; then
    info "aichat via Homebrew proberen…"
    if brew install aichat; then
      ok "aichat geïnstalleerd (brew)."
      return 0
    fi
  fi

  warn "aichat niet geïnstalleerd. Je kunt het later handmatig installeren."
  return 1
}

# ===== Config: Starship TOML (overschrijven; single-quoted heredoc zodat $time blijft) =====
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

# ===== Config: Fish (basis + AI-copilot hook, als fish aanwezig is) =====
write_fish_configs(){
  # Basis fish config altijd klaarzetten; hook werkt wanneer fish gebruikt wordt
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
  # kies fish als beschikbaar, anders bash
  if command -v fish >/dev/null 2>&1; then
    SHELL_CMD="fish"
  else
    SHELL_CMD="bash"
  fi

  cat > "$ZELLIJ_LAYOUT_DIR/copilot.kdl" <<KDL
layout {
  pane command="${SHELL_CMD}"
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

# ===== AI wrapper voor bash & fish gebruikers =====
# Gebruik: r <commando ...>  (captured stderr; bij fout → aichat suggestie)
write_ai_wrapper(){
  info "AI-wrapper plaatsen (aiwrap + bash functie 'r')…"
  cat > "$LOCAL_BIN/aiwrap" <<'SH'
#!/usr/bin/env bash
# aiwrap: run a command, capture stderr to /tmp/fish_last_stderr.log,
# on non-zero exit call aichat to suggest a fix.
LOG="/tmp/fish_last_stderr.log"
: > "$LOG"
# Execute command
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

  # Bash helper-functie
  if ! grep -q "^r\(\)" "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<'BASHF'
# Run with AI: r <command>
r() {
  aiwrap "$@"
}
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
  warn "aichat kon niet automatisch geïnstalleerd worden. Installeer later handmatig en herstart je shell."
fi

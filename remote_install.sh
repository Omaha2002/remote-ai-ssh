#!/usr/bin/env bash
set -euo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
die(){ echo "${RED}✖ $*${RST}" >&2; exit 1; }
ok(){  echo "${GRN}✔ $*${RST}"; }
info(){ echo "${BLU}→ $*${RST}"; }
warn(){ echo "${YLW}! $*${RST}"; }

# --- Checks ---
[[ "$(id -u)" -ne 0 ]] && SUDO='sudo' || SUDO=''
if ! command -v apt >/dev/null 2>&1; then
  die "Dit script is bedoeld voor Ubuntu/Debian (apt vereist)."
fi

# --- Helpers ---
detect_arch() {
  case "$(uname -m)" in
    x86_64) echo "x86_64-unknown-linux-musl" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    *) echo ""; return 1 ;;
  esac
}

install_zellij() {
  if command -v zellij >/dev/null 2>&1; then
    ok "Zellij al aanwezig: $(zellij --version 2>/dev/null | head -n1)"
    return 0
  fi

  info "Probeer Zellij via apt…"
  if $SUDO apt install -y zellij >/dev/null 2>&1; then
    ok "Zellij geïnstalleerd via apt"
    return 0
  fi

  warn "Zellij niet in apt, probeer Snap…"
  if command -v snap >/dev/null 2>&1; then
    if $SUDO snap install zellij --classic; then
      ok "Zellij geïnstalleerd via snap"
      return 0
    else
      warn "Snap-installatie van Zellij faalde"
    fi
  else
    warn "Snap ontbreekt op dit systeem"
  fi

  info "Val terug op officiële release binary (GitHub)…"
  arch="$(detect_arch || true)"
  if [[ -z "${arch:-}" ]]; then
    die "Onbekende CPU-architectuur voor Zellij binary. Installeer via cargo: 'sudo apt install -y cargo && cargo install --locked zellij'"
  fi

  tmpdir="$(mktemp -d)"
  url="https://github.com/zellij-org/zellij/releases/latest/download/zellij-${arch}.tar.gz"
  info "Download: $url"
  if curl -fsSL "$url" | tar -xz -C "$tmpdir"; then
    $SUDO mv "$tmpdir/zellij" /usr/local/bin/
    $SUDO chmod +x /usr/local/bin/zellij
    rm -rf "$tmpdir"
    ok "Zellij geïnstalleerd via binary"
    return 0
  fi

  die "Zellij-installatie mislukt (apt/snap/binary). Probeer desnoods: 'sudo apt install -y cargo && cargo install --locked zellij'"
}

install_starship() {
  if command -v starship >/dev/null 2>&1; then
    ok "Starship aanwezig: $(starship --version | head -n1)"; return 0
  fi
  info "Starship installeren…"
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y
  ok "Starship: $(starship --version | head -n1)"
}

install_aichat_optional() {
  if command -v aichat >/dev/null 2>&1; then
    ok "aichat aanwezig: $(aichat --version | head -n1)"; return 0
  fi

  # Probeer Linuxbrew (lichtgewicht fallback)
  if command -v brew >/dev/null 2>&1; then
    info "aichat via Homebrew installeren…"
    brew install aichat && { ok "aichat geïnstalleerd (brew)"; return 0; }
    warn "aichat via brew faalde"
  else
    warn "Homebrew ontbreekt; probeer Linuxbrew installeren (non-interactief)…"
    NONINTERACTIVE=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
      warn "Brew-installatie faalde; sla aichat over."
      return 1
    }
    # shellenv
    if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
      echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$HOME/.profile"
      brew install aichat && { ok "aichat geïnstalleerd (brew)"; return 0; }
    fi
  fi

  warn "aichat niet geïnstalleerd; je kunt het later handmatig installeren (brew of release)."
  return 1
}

# --- Update & packages (core tools uit apt) ---
info "Pakketindex bijwerken…"
$SUDO apt update -y
info "Packages installeren (fish, ripgrep, fd-find, fzf, bat, git, curl, ca-certificates)…"
$SUDO apt install -y fish ripgrep fd-find fzf bat git curl ca-certificates

# Zellij (met fallback strategie)
install_zellij

# Starship
install_starship

# aichat (optioneel, met fallback)
install_aichat_optional || true

# --- Config paths ---
mkdir -p "$HOME/.config/fish/conf.d" \
         "$HOME/.config/zellij/layouts" \
         "$HOME/.config/aichat"

# --- Starship config (overschrijven, veilig heredoc) ---
cat > "$HOME/.config/starship.toml" <<'TOML'
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
ok "Starship config geplaatst"

# --- Fish config incl. AI-copilot hook ---
# bat heet 'batcat' op Ubuntu; alias leggen
BAT_BIN="$(command -v batcat || true)"
cat > "$HOME/.config/fish/config.fish" <<FISH
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
alias bat="command ${BAT_BIN:-bat} 2>/dev/null; or command bat"
alias fd="fdfind"

# AI Copilot hook: Enter -> run met stderr-log; Alt+Enter -> normaal
function __ai_handle_failure
    set -l lastcmd "\$argv"
    set -l errlog (command tail -n 120 /tmp/fish_last_stderr.log ^/dev/null)
    if test -n "\$errlog"
        echo -e "\n❌ Commando faalde: \$lastcmd\n→ AI suggestie:"
        if type -q aichat
            echo \$errlog | aichat "Het commando '\$lastcmd' faalde. Analyseer de fout en geef concrete stappen om te fixen. Toon commando's."
        else
            echo "(aichat niet gevonden) Suggestie: installeer aichat of plak foutmelding lokaal in 'ai'."
        end
    else
        echo -e "\n❌ Commando faalde: \$lastcmd (geen stderr opgevangen)"
    end
end

function accept_line_with_ai
    set -l cmd (commandline -b)
    if test -z (string trim -- \$cmd)
        commandline -f execute
        return
    end
    commandline -r ""
    : > /tmp/fish_last_stderr.log
    eval \$cmd 2>>/tmp/fish_last_stderr.log
    set -l st \$status
    if test \$st -ne 0
        __ai_handle_failure \$cmd
    end
end

bind \r accept_line_with_ai
bind \e\r 'commandline -f execute'
FISH
ok "Fish config + AI-copilot geplaatst"

# --- Zellij layouts (dev en copilot) ---
cat > "$HOME/.config/zellij/layouts/dev.kdl" <<'KDL'
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

cat > "$HOME/.config/zellij/layouts/copilot.kdl" <<'KDL'
layout {
  pane command="fish"
  pane command="bash" {
    args "-lc" "touch /tmp/fish_last_stderr.log; tail -f /tmp/fish_last_stderr.log"
  }
}
KDL
ok "Zellij layouts geplaatst"

# --- aichat configureren (OpenRouter) ---
if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  cat > "$HOME/.config/aichat/config.yaml" <<YAML
model: openrouter:openrouter/auto
clients:
  - type: openai-compatible
    name: openrouter
    api_base: https://openrouter.ai/api/v1
    api_key: ${OPENROUTER_API_KEY}
YAML
  ok "aichat config geschreven met OPENROUTER_API_KEY uit env"
else
  warn "OPENROUTER_API_KEY niet gezet; aichat werkt pas na het zetten van deze variabele of het aanpassen van ~/.config/aichat/config.yaml"
fi

# --- Einde ---
echo
ok "Installatie afgerond!"
echo "Start Fish:      ${BLU}fish${RST}"
echo "Start Copilot:   ${BLU}zellij --layout copilot${RST}"
echo

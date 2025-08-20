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

# --- Update & packages (core tools uit apt) ---
info "Pakketindex bijwerken…"
$SUDO apt update -y
info "Packages installeren (fish, zellij, ripgrep, fd-find, fzf, bat, git, curl)…"
$SUDO apt install -y fish zellij ripgrep fd-find fzf bat git curl ca-certificates

# bat heet 'batcat' op Ubuntu; maak alias aan straks in fish
BAT_BIN="$(command -v batcat || true)"

# --- Starship (officiële installer) ---
if ! command -v starship >/dev/null 2>&1; then
  info "Starship installeren…"
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y
fi
ok "Starship: $(starship --version | head -n1)"

# --- (Optioneel) Linuxbrew voor aichat (met fallback) ---
install_aichat() {
  if command -v aichat >/dev/null 2>&1; then
    ok "aichat al aanwezig: $(aichat --version | head -n1)"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    info "aichat via Homebrew installeren…"
    brew install aichat || return 1
    ok "aichat geïnstalleerd (brew)"
    return 0
  fi

  warn "Linuxbrew ontbreekt; installeren (dit kan even duren)…"
  NONINTERACTIVE=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
    warn "Brew installatie faalde; sla aichat-installatie over."
    return 1
  }
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" || true
  echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$HOME/.profile"
  info "aichat via Homebrew installeren…"
  brew install aichat || { warn "aichat installatie via brew faalde."; return 1; }
  ok "aichat geïnstalleerd (brew)"
  return 0
}
install_aichat || true

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

# --- Fish config (AI-copilot hook + handige aliases) ---
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
            echo "(aichat niet gevonden) Suggestie: installeer aichat of plak foutmelding in 'ai' lokaal."
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

# --- Default shell wisselen? (vraag niet; laat aan gebruiker) ---
info "Installatie afgerond. Start fish met: ${BLU}fish${RST}  (of stel in als default met: chsh -s \$(command -v fish))"

echo
ok "Klaar! Tips:"
echo "• Start Zellij copilot: ${BLU}zellij --layout copilot${RST}"
echo "• AI-hook: druk Enter om te runnen met logging; Alt+Enter voor 'gewoon' uitvoeren."
echo "• aichat testen: ${BLU}aichat 'Controleer waarom nginx niet start'${RST}  (zet eerst OPENROUTER_API_KEY als die nog niet stond)"

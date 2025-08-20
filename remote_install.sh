# Probeer eerst via apt
if ! command -v zellij >/dev/null 2>&1; then
  if $SUDO apt install -y zellij 2>/dev/null; then
    ok "Zellij geïnstalleerd via apt"
  else
    warn "Zellij niet in apt, probeer Snap…"
    if command -v snap >/dev/null 2>&1; then
      $SUDO snap install zellij --classic
    else
      info "Snap ontbreekt, haal binary van GitHub…"
      curl -L https://github.com/zellij-org/zellij/releases/latest/download/zellij-x86_64-unknown-linux-musl.tar.gz \
        | tar -xz -C /tmp
      $SUDO mv /tmp/zellij /usr/local/bin/
    fi
  fi
fi

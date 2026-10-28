#!/usr/bin/env bash
#
# setup-shell.sh <machine>
#
# Installs zsh + Oh My Zsh in an OrbStack VM and makes zsh the default login
# shell. Adds ~/.local/bin to PATH in .zshrc so the claude CLI resolves in zsh
# sessions (zsh does not read ~/.profile, where the base image puts it).
# Idempotent; usable on its own to add Oh My Zsh to an existing machine.
#
set -euo pipefail

err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

NAME="${1:-}"
[ -n "$NAME" ] || err "usage: $0 <machine>"
command -v orb >/dev/null || err "orb (OrbStack) not found on PATH"
orb info "$NAME" >/dev/null 2>&1 || err "no OrbStack machine named '$NAME'"

VM_USER="$(orb run -m "$NAME" whoami | tr -d '[:space:]')"
[ -n "$VM_USER" ] || err "could not determine VM user"

info "Installing zsh..."
orb run -m "$NAME" -u root bash -s <<'EOF'
set -e
if ! command -v zsh >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq zsh >/dev/null
fi
EOF

info "Installing Oh My Zsh (unattended)..."
orb run -m "$NAME" bash -lc '
  if [ -d "$HOME/.oh-my-zsh" ]; then
    echo "   Oh My Zsh already installed"
  else
    RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  fi
  # zsh does not read ~/.profile, so re-add the user bin dir (claude lives here).
  # Match only an ACTIVE export line — the OMZ template ships a commented example.
  if ! grep -qE "^[[:space:]]*export PATH=.*\.local/bin" "$HOME/.zshrc" 2>/dev/null; then
    printf "\n# Local user bin (claude, etc.)\nexport PATH=\"\$HOME/.local/bin:\$PATH\"\n" >> "$HOME/.zshrc"
  fi
  # nvm installs its loader snippet into the bash profile; zsh needs its own.
  if ! grep -q "NVM_DIR" "$HOME/.zshrc" 2>/dev/null; then
    {
      printf "\n# nvm (Node version manager)\n"
      printf "export NVM_DIR=\"\$HOME/.nvm\"\n"
      printf "[ -s \"\$NVM_DIR/nvm.sh\" ] && \\\\. \"\$NVM_DIR/nvm.sh\"\n"
      printf "[ -s \"\$NVM_DIR/bash_completion\" ] && \\\\. \"\$NVM_DIR/bash_completion\"\n"
    } >> "$HOME/.zshrc"
  fi
'

info "Setting zsh as the default login shell for $VM_USER..."
orb run -m "$NAME" -u root bash -c "chsh -s \"\$(command -v zsh)\" \"$VM_USER\""

info "zsh + Oh My Zsh set up on '$NAME'."

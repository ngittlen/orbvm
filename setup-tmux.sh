#!/usr/bin/env bash
#
# setup-tmux.sh <machine>
#
# Installs tmux in an OrbStack VM and pushes the shared ~/.tmux.conf from this
# repo (tmux.conf). tmux keeps your shell, Claude, and dev servers alive on the
# VM when the SSH/Tailscale connection drops — reattach later with `tmux attach`.
#
# The repo's tmux.conf is the source of truth: this (re)writes the VM's copy
# every run, so editing tmux.conf here and re-running pushes the change. A
# running tmux server is reloaded in place.
# Idempotent; usable on its own to (re)apply the config to an existing machine.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/tmux.conf"

err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

NAME="${1:-}"
[ -n "$NAME" ] || err "usage: $0 <machine>"
command -v orb >/dev/null || err "orb (OrbStack) not found on PATH"
orb info "$NAME" >/dev/null 2>&1 || err "no OrbStack machine named '$NAME'"
[ -f "$CONF" ] || err "tmux config not found: $CONF"

info "Installing tmux..."
orb run -m "$NAME" -u root bash -s <<'EOF'
set -e
if ! command -v tmux >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq tmux >/dev/null
fi
EOF

info "Writing ~/.tmux.conf..."
orb run -m "$NAME" bash -lc 'cat > "$HOME/.tmux.conf"' < "$CONF"
# Reload the config in a running server (no-op if none is running).
orb run -m "$NAME" bash -lc 'tmux source-file "$HOME/.tmux.conf" 2>/dev/null || true'

info "tmux set up on '$NAME'."

#!/usr/bin/env bash
#
# apply-claude-config.sh <machine>
#
# Installs the shared ~/.claude configuration (settings, status line, guard hook,
# CLAUDE.md) and the typescript-lsp + svelte plugins into an OrbStack VM. Safe to
# re-run, and usable on its own to update an existing machine's Claude config.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG="$SCRIPT_DIR/claude-config"

err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

NAME="${1:-}"
[ -n "$NAME" ] || err "usage: $0 <machine>"
command -v orb >/dev/null || err "orb (OrbStack) not found on PATH"
orb info "$NAME" >/dev/null 2>&1 || err "no OrbStack machine named '$NAME'"
[ -d "$CFG" ] || err "config directory not found: $CFG"

info "Ensuring jq is installed (the guard hook and status line need it)..."
orb run -m "$NAME" -u root bash -s <<'EOF'
set -e
if ! command -v jq >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq jq >/dev/null
fi
EOF

info "Writing ~/.claude configuration..."
orb run -m "$NAME" bash -lc 'mkdir -p ~/.claude/hooks'
orb run -m "$NAME" bash -lc 'cat > ~/.claude/settings.json'         < "$CFG/settings.json"
orb run -m "$NAME" bash -lc 'cat > ~/.claude/statusline-command.sh' < "$CFG/statusline-command.sh"
orb run -m "$NAME" bash -lc 'cat > ~/.claude/hooks/guard.sh'        < "$CFG/hooks/guard.sh"
orb run -m "$NAME" bash -lc 'cat > ~/.claude/CLAUDE.md'             < "$CFG/CLAUDE.md"
# Make hooks executable and resolve the status-line path to this VM's home.
orb run -m "$NAME" bash -lc 'chmod +x ~/.claude/hooks/guard.sh ~/.claude/statusline-command.sh; sed -i "s#__HOME__#$HOME#g" ~/.claude/settings.json'

info "Installing Claude plugins (typescript-lsp, svelte)..."
orb run -m "$NAME" bash -lc '
  CLAUDE="$HOME/.local/bin/claude"
  [ -x "$CLAUDE" ] || CLAUDE="$(command -v claude || true)"
  if [ -z "$CLAUDE" ]; then echo "   claude CLI not found in VM; skipping plugins"; exit 0; fi
  # Official marketplace is not pre-registered on a headless VM; add it explicitly.
  "$CLAUDE" plugin marketplace add anthropics/claude-plugins-official || true
  "$CLAUDE" plugin marketplace add sveltejs/ai-tools || true
  "$CLAUDE" plugin marketplace add ngittlen/claude-skills || true
  "$CLAUDE" plugin install typescript-lsp@claude-plugins-official || true
  "$CLAUDE" plugin install svelte@svelte || true
  "$CLAUDE" plugin install nate@claude-skills || true
  echo "   --- plugins ---"
  "$CLAUDE" plugin list || true
'

info "Claude config applied to '$NAME'."

#!/usr/bin/env bash
#
# create-vm.sh <vm-name> [distro]
#
# Creates an OrbStack Linux VM, joins it to your Tailscale tailnet as its own
# node (with Tailscale SSH), and preinstalls Node + git + Claude Code + zsh.
# Serve test sites privately over HTTPS with the `tsweb` helper (installed below).
#
# The early steps (create VM, join Tailscale) are fatal — without them there is
# no usable machine. The later provisioning steps are resilient: a failure is
# recorded and the run continues, so the VM is provisioned as far as possible and
# the final summary (and the dashboard log) names exactly which step failed.
#
# Prereqs (one-time):
#   1. A reusable + ephemeral Tailscale auth key in ~/.config/orbvm/authkey
#      (chmod 600) or exported as TS_AUTHKEY. Generate at:
#      https://login.tailscale.com/admin/settings/keys
#   2. HTTPS certificates enabled for your tailnet (admin console -> DNS).
#
set -euo pipefail

DEFAULT_DISTRO="ubuntu:noble"
AUTHKEY_FILE="${HOME}/.config/orbvm/authkey"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# Annotate a fatal failure in the early (set -e) section with its line + command
# so the dashboard log says what actually broke, not just "exited with code 1".
trap 'rc=$?; printf "\033[31m✗ create-vm.sh aborted (exit %s) at line %s:\033[0m %s\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Resilient step runner for the provisioning phases. Records failures instead of
# aborting, so one broken step does not leave the rest undone.
FAILED=()
phase() {
  local label="$1"; shift
  info "$label"
  "$@" && return 0 || local rc=$?
  printf '\033[31m✗ step failed:\033[0m %s (exit %s)\n' "$label" "${rc:-1}" >&2
  FAILED+=("$label")
  return 0
}

# --- args -------------------------------------------------------------------
NAME="${1:-}"
DISTRO="${2:-$DEFAULT_DISTRO}"
[ -n "$NAME" ] || err "usage: $0 <vm-name> [distro]   (e.g. $0 devbox ubuntu:noble)"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || err "vm name must be lowercase letters, digits and dashes"

# --- prereqs ----------------------------------------------------------------
command -v orb       >/dev/null || err "orb (OrbStack) not found on PATH"
command -v tailscale >/dev/null || err "tailscale CLI not found on host"

KEY="${TS_AUTHKEY:-}"
if [ -z "$KEY" ] && [ -f "$AUTHKEY_FILE" ]; then
  KEY="$(tr -d '[:space:]' < "$AUTHKEY_FILE")"
fi
[ -n "$KEY" ] || err "no Tailscale auth key found.
  Set TS_AUTHKEY or write a key to $AUTHKEY_FILE (chmod 600).
  Generate a reusable + ephemeral key: https://login.tailscale.com/admin/settings/keys"

# Discover the tailnet MagicDNS suffix (e.g. tail1234.ts.net) for the final URL.
TSNET="$(tailscale status --json 2>/dev/null \
  | sed -n 's/.*"MagicDNSSuffix": *"\([^"]*\)".*/\1/p' | head -1)"
TSNET="${TSNET:-your-tailnet.ts.net}"

# Refuse to clobber an existing machine.
if orb info "$NAME" >/dev/null 2>&1; then
  err "a machine named '$NAME' already exists. Run ./delete-vm.sh $NAME first, or pick another name."
fi

# --- create (fatal) ---------------------------------------------------------
info "Creating OrbStack VM '$NAME' ($DISTRO)..."
orb create "$DISTRO" "$NAME"

VM_USER="$(orb run -m "$NAME" whoami | tr -d '[:space:]')"
VM_URL="https://${NAME}.${TSNET}/"

# --- Tailscale (fatal) ------------------------------------------------------
info "Installing Tailscale in the VM..."
orb run -m "$NAME" -u root bash -s <<'EOF'
set -e
curl -fsSL https://tailscale.com/install.sh | sh
EOF

info "Joining the tailnet (Tailscale SSH enabled)..."
# Pass the key and names through the VM environment (ORBENV) rather than on the
# command line, so the key never shows up in the VM process list.
TS_AUTHKEY_VM="$KEY" VM_NAME="$NAME" VM_OPERATOR="$VM_USER" VM_URL_ENV="$VM_URL" \
ORBENV="TS_AUTHKEY_VM:VM_NAME:VM_OPERATOR:VM_URL_ENV" \
orb run -m "$NAME" -u root bash -s <<'EOF'
set -e
flags="--authkey=${TS_AUTHKEY_VM} --ssh --hostname=${VM_NAME}"
if [ -e /dev/net/tun ]; then
  tailscale up $flags || tailscale up $flags --tun=userspace-networking
else
  # No TUN device available in this VM; use userspace networking.
  # Tailscale SSH and `tailscale serve` both still work in this mode.
  tailscale up $flags --tun=userspace-networking
fi
# Let the default user drive `tailscale serve` without sudo.
tailscale set --operator="${VM_OPERATOR}" || true
# Record the preview base URL for the tsweb helper.
printf '%s\n' "${VM_URL_ENV}" > /etc/orbvm-url
EOF

# --- provisioning phases (resilient) ----------------------------------------
# Each step below is a single command; a failure is recorded and the run keeps
# going. The matching standalone script (named in the summary) can re-run any
# failed step against the existing VM.

step_tooling() {
  orb run -m "$NAME" -u root bash -s <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git build-essential ca-certificates python3 jq >/dev/null
EOF
}

# Node via nvm, installed per-user. nvm's shell snippet is appended to the
# profile, but Ubuntu's ~/.bashrc returns early for non-interactive shells, so
# every provisioning step that needs node sources nvm explicitly (as here).
# setup-shell.sh adds the same snippet to ~/.zshrc for interactive SSH sessions.
step_node() {
  orb run -m "$NAME" bash -lc '
    set -e
    export NVM_DIR="$HOME/.nvm"
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    fi
    . "$NVM_DIR/nvm.sh"
    nvm install --lts
    nvm alias default "lts/*"
    node --version
  '
}

step_claude() {
  orb run -m "$NAME" bash -lc '
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    curl -fsSL https://claude.ai/install.sh | bash || npm install -g @anthropic-ai/claude-code
  '
}

phase "Installing git and build tools"           step_tooling
phase "Installing Node (LTS) via nvm"            step_node
phase "Installing Claude Code"                   step_claude
phase "Applying Claude config + plugins"         "$SCRIPT_DIR/apply-claude-config.sh" "$NAME"
phase "Setting up zsh + Oh My Zsh"               "$SCRIPT_DIR/setup-shell.sh" "$NAME"
phase "Setting up tmux"                          "$SCRIPT_DIR/setup-tmux.sh" "$NAME"
phase "Setting the git identity"                 "$SCRIPT_DIR/setup-git.sh" "$NAME"
phase "Installing the GitHub CLI"                "$SCRIPT_DIR/setup-github.sh" "$NAME"
phase "Installing the tsweb preview helper"      "$SCRIPT_DIR/setup-tsweb.sh" "$NAME"

# --- summary ----------------------------------------------------------------
trap - ERR   # the explicit exit below is not an error to annotate

if [ "${#FAILED[@]}" -eq 0 ]; then
  head="$(printf '\033[32m✓\033[0m') VM '$NAME' is ready and on your tailnet."
else
  head="$(printf '\033[31m⚠\033[0m') VM '$NAME' is reachable, but ${#FAILED[@]} step(s) FAILED:
$(printf '     - %s\n' "${FAILED[@]}")
   Re-run the matching script against '$NAME' to finish (see README)."
fi

cat <<EOF

$head

SSH from any tailnet device (Tailscale SSH, no keys to manage):
    ssh ${VM_USER}@${NAME}.${TSNET}

Or locally on this Mac:
    orb -m ${NAME}            # open a shell in the VM

Run Claude in the VM (log in once on first run):
    ssh ${VM_USER}@${NAME}.${TSNET}
    claude

Authorize GitHub for pushing (interactive, once per VM):
    gh auth login            # GitHub.com > HTTPS > "Login with a web browser"

Serve a test site from inside the VM:
    tsweb 3000               # -> ${VM_URL}

Tear it all down:
    ./delete-vm.sh ${NAME}
EOF

# Non-zero exit when any step failed, so the dashboard flags it (and its log,
# now shown in the UI, lists the failed step and the error above it).
[ "${#FAILED[@]}" -eq 0 ] || exit 1

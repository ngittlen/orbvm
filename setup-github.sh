#!/usr/bin/env bash
#
# setup-github.sh <machine>
#
# Installs the GitHub CLI (gh) in an OrbStack VM. Authentication is interactive
# and left to you: after this runs, SSH into the VM and run `gh auth login`
# (pick "Login with a web browser" for the headless device-code flow, and let it
# configure git for pushes). No credentials are stored by this script.
# Idempotent; usable on its own to add gh to an existing machine.
#
set -euo pipefail

err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

NAME="${1:-}"
[ -n "$NAME" ] || err "usage: $0 <machine>"
command -v orb >/dev/null || err "orb (OrbStack) not found on PATH"
orb info "$NAME" >/dev/null 2>&1 || err "no OrbStack machine named '$NAME'"

info "Installing the GitHub CLI (gh)..."
orb run -m "$NAME" -u root bash -s <<'EOF'
set -e
if command -v gh >/dev/null 2>&1; then
  echo "   gh already installed ($(gh --version | head -1))"
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget >/dev/null
mkdir -p -m 755 /etc/apt/keyrings
wget -nv -O /etc/apt/keyrings/githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update -qq
apt-get install -y -qq gh >/dev/null
echo "   installed $(gh --version | head -1)"
EOF

info "gh is installed on '$NAME'. Finish by authenticating interactively:"
cat <<'EOS'
   ssh <you>@<machine>.<tailnet>.ts.net
   gh auth login
     # choose: GitHub.com > HTTPS > "Login with a web browser"
     # enter the one-time code at https://github.com/login/device
     # answer "Yes" to "Authenticate Git with your GitHub credentials?"
EOS

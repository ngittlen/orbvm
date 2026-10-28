#!/usr/bin/env bash
#
# setup-git.sh <machine>
#
# Sets the global git identity in an OrbStack VM. Edit the two values below to
# change the identity used for commits on new machines. Idempotent; usable on
# its own to set the identity on an existing machine.
#
set -euo pipefail

GIT_USER_NAME="Nate Gittlen"
GIT_USER_EMAIL="nathaniel.gittlen@gmail.com"

err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

NAME="${1:-}"
[ -n "$NAME" ] || err "usage: $0 <machine>"
command -v orb >/dev/null || err "orb (OrbStack) not found on PATH"
orb info "$NAME" >/dev/null 2>&1 || err "no OrbStack machine named '$NAME'"

info "Setting git identity: $GIT_USER_NAME <$GIT_USER_EMAIL>"
# Pass values through the VM environment to avoid quoting issues.
GIT_N="$GIT_USER_NAME" GIT_E="$GIT_USER_EMAIL" ORBENV="GIT_N:GIT_E" \
orb run -m "$NAME" bash -lc '
  git config --global user.name  "$GIT_N"
  git config --global user.email "$GIT_E"
  echo "   name:  $(git config --global user.name)"
  echo "   email: $(git config --global user.email)"
'

info "Git identity set on '$NAME'."

#!/usr/bin/env bash
#
# delete-vm.sh <vm-name>
#
# Logs the VM out of Tailscale (dropping its tailnet node) and deletes the
# OrbStack machine. All data in the VM is permanently lost.
#
set -euo pipefail

err() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

NAME="${1:-}"
[ -n "$NAME" ] || err "usage: $0 <vm-name>"
command -v orb >/dev/null || err "orb (OrbStack) not found on PATH"

if ! orb info "$NAME" >/dev/null 2>&1; then
  echo "No OrbStack machine named '$NAME'. Nothing to do."
  exit 0
fi

printf '\033[36m==>\033[0m Logging '\''%s'\'' out of Tailscale...\n' "$NAME"
orb run -m "$NAME" -u root tailscale logout >/dev/null 2>&1 || true

printf '\033[36m==>\033[0m Deleting OrbStack machine '\''%s'\''...\n' "$NAME"
orb delete -f "$NAME"

echo "Done. (The ephemeral tailnet node disappears shortly after logout.)"

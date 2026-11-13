#!/usr/bin/env bash
#
# update-tailscale.sh [machine ...]
#
# Updates Tailscale to the latest release inside OrbStack VMs by re-running the
# official installer (idempotent; upgrades the apt package in place). Prints the
# version before and after for each machine.
#
# With no arguments, updates every *running* VM (stopped VMs are skipped so this
# never auto-starts a workload). Pass one or more machine names to target them
# explicitly (a named-but-stopped machine is started by `orb run` as usual).
#
set -euo pipefail

err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mskip:\033[0m %s\n' "$*"; }

command -v orb >/dev/null || err "orb (OrbStack) not found on PATH"

# Build the target list: explicit args, or all running machines.
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
  for n in "${TARGETS[@]}"; do
    orb info "$n" >/dev/null 2>&1 || err "no OrbStack machine named '$n'"
  done
else
  command -v python3 >/dev/null || err "python3 needed to enumerate running VMs"
  mapfile -t TARGETS < <(orb list --format json \
    | python3 -c "import sys,json;[print(m['name']) for m in json.load(sys.stdin) if m.get('state')=='running']")
  [ "${#TARGETS[@]}" -gt 0 ] && info "Updating all running VMs: ${TARGETS[*]}"
fi
[ "${#TARGETS[@]}" -gt 0 ] || err "no machines to update"

# Upgrade one machine: capture old version, re-run installer, capture new.
update_one() {
  local name="$1"
  info "[$name] updating Tailscale..."
  orb run -m "$name" -u root bash -s <<'EOF'
set -e
old="$(tailscale version 2>/dev/null | head -n1 || echo 'not installed')"
curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
new="$(tailscale version 2>/dev/null | head -n1 || echo '?')"
if [ "$old" = "$new" ]; then
  printf '    already current: %s\n' "$new"
else
  printf '    %s -> %s\n' "$old" "$new"
fi
EOF
}

rc=0
for name in "${TARGETS[@]}"; do
  if ! update_one "$name"; then
    warn "[$name] update failed"
    rc=1
  fi
done

[ "$rc" -eq 0 ] && info "Tailscale update complete." || err "one or more machines failed to update"

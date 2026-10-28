#!/usr/bin/env bash
#
# setup-tsweb.sh <machine>
#
# Installs the `tsweb` helper into an OrbStack VM. Inside the VM, `tsweb <port>`
# exposes a local port on your tailnet over HTTPS via `tailscale serve`.
# Idempotent; usable on its own to (re)install the helper on a machine.
#
set -euo pipefail

err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

NAME="${1:-}"
[ -n "$NAME" ] || err "usage: $0 <machine>"
command -v orb >/dev/null || err "orb (OrbStack) not found on PATH"
orb info "$NAME" >/dev/null 2>&1 || err "no OrbStack machine named '$NAME'"

info "Installing the 'tsweb' preview helper..."
orb run -m "$NAME" -u root bash -s <<'EOF'
set -e
cat > /usr/local/bin/tsweb <<'SH'
#!/usr/bin/env bash
# tsweb <port> -- expose a local port on your tailnet over HTTPS (private).
set -euo pipefail
port="${1:-}"
[ -n "$port" ] || { echo "usage: tsweb <port>   (e.g. tsweb 3000)"; exit 1; }
tailscale serve --bg --https=443 "http://localhost:${port}" >/dev/null \
  || sudo tailscale serve --bg --https=443 "http://localhost:${port}" >/dev/null
base="$(cat /etc/orbvm-url 2>/dev/null || echo "https://$(hostname)/")"
echo "Serving localhost:${port} at ${base}"
echo "Stop with: tailscale serve --https=443 off"
SH
chmod +x /usr/local/bin/tsweb
EOF

info "tsweb installed on '$NAME'."

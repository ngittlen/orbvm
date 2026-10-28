#!/usr/bin/env bash
#
# start-dashboard.sh — run the VM dashboard and expose it on your tailnet.
#
# Starts the local Node server (localhost only) and puts it behind
# `tailscale serve` so it's reachable at https://<this-mac>.<tailnet>.ts.net/
# from your devices only. Ctrl-C stops the server and tears down the serve.
#
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

PORT="${PORT:-8099}"
command -v node >/dev/null || { echo "node not found on PATH"; exit 1; }
command -v orb  >/dev/null || { echo "orb (OrbStack) not found on PATH"; exit 1; }

echo "==> Starting dashboard server on http://localhost:$PORT"
PORT="$PORT" node dashboard/server.js &
SERVER_PID=$!

cleanup(){
  tailscale serve --https=443 off >/dev/null 2>&1 || true
  kill "$SERVER_PID" >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

sleep 1
echo "==> Exposing on your tailnet via tailscale serve (HTTPS, tailnet-only)"
if ! tailscale serve --bg --https=443 "http://localhost:$PORT" >/dev/null 2>&1; then
  sudo tailscale serve --bg --https=443 "http://localhost:$PORT" || {
    echo "   (tailscale serve failed — the dashboard is still up locally at http://localhost:$PORT)"; }
fi

HOST="$(tailscale status --json 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null || true)"
echo
[ -n "$HOST" ] && echo "   Dashboard:  https://$HOST/   (reachable from any device on your tailnet)"
echo "   Local:      http://localhost:$PORT/"
echo
echo "Press Ctrl-C to stop."
wait "$SERVER_PID"

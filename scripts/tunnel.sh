#!/usr/bin/env bash
# Put the hub behind a Cloudflare tunnel so phones get a real HTTPS URL (no certificate warning)
# and the console is reachable from anywhere.
#
#   scripts/tunnel.sh setup swarm.example.com   once: create the tunnel, DNS record and config
#   scripts/tunnel.sh run                       start the tunnel and the hub together
#   scripts/tunnel.sh quick                     no domain needed: a throwaway trycloudflare URL
#
# `setup` needs `cloudflared tunnel login` first (browser sign-in, picks the domain).
# The hostname is remembered in .env as SWARM_TUNNEL_HOSTNAME.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=swarm-sight
CONFIG="$HOME/.cloudflared/config.yml"
PORT="${SWARM_PORT:-8000}"
hostname_from_env() { grep -E '^SWARM_TUNNEL_HOSTNAME=' .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"''; }

case "${1:-run}" in
  setup)
    HOST="${2:?usage: scripts/tunnel.sh setup swarm.example.com}"
    [ -f "$HOME/.cloudflared/cert.pem" ] || { echo "Run 'cloudflared tunnel login' first (browser sign-in)."; exit 1; }
    cloudflared tunnel list | grep -q " $NAME " || cloudflared tunnel create "$NAME"
    ID=$(cloudflared tunnel list --output json | python3 -c "import json,sys;print(next(t['id'] for t in json.load(sys.stdin) if t['name']=='$NAME'))")
    cloudflared tunnel route dns --overwrite-dns "$NAME" "$HOST"
    mkdir -p "$HOME/.cloudflared"
    cat > "$CONFIG" <<YAML
tunnel: $NAME
credentials-file: $HOME/.cloudflared/$ID.json
ingress:
  - hostname: $HOST
    service: http://localhost:$PORT
  - service: http_status:404
YAML
    grep -v '^SWARM_TUNNEL_HOSTNAME=' .env > .env.tmp 2>/dev/null || true
    mv .env.tmp .env 2>/dev/null || true
    echo "SWARM_TUNNEL_HOSTNAME=$HOST" >> .env
    echo "Tunnel $NAME → https://$HOST (config: $CONFIG)"
    echo "Next: scripts/tunnel.sh run   (and protect /console with Cloudflare Access: see docs/tunnel.md)"
    ;;
  run)
    HOST="$(hostname_from_env)"
    [ -n "$HOST" ] || { echo "No SWARM_TUNNEL_HOSTNAME in .env — run: scripts/tunnel.sh setup <hostname>"; exit 1; }
    cloudflared tunnel run "$NAME" & TUNNEL=$!
    trap 'kill $TUNNEL 2>/dev/null || true' EXIT
    sleep 3
    echo "Phones join: https://$HOST/   Console: https://$HOST/console"
    uv run python -m swarm.hub --port "$PORT" --public-url "https://$HOST"
    ;;
  quick)
    LOG=$(mktemp)
    cloudflared tunnel --url "http://localhost:$PORT" > "$LOG" 2>&1 & TUNNEL=$!
    trap 'kill $TUNNEL 2>/dev/null || true' EXIT
    for _ in $(seq 40); do
      HOST=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG" | head -1) && [ -n "$HOST" ] && break
      sleep 1
    done
    [ -n "${HOST:-}" ] || { echo "Tunnel did not start:"; tail -5 "$LOG"; exit 1; }
    echo "Phones join: $HOST/   Console: $HOST/console   (this URL changes every run)"
    uv run python -m swarm.hub --port "$PORT" --public-url "$HOST"
    ;;
  *) echo "usage: $0 setup <hostname> | run | quick"; exit 1 ;;
esac

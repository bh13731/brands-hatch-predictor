#!/bin/bash
# Keeps the predictor API + cloudflared tunnel alive, and publishes the
# current tunnel URL into the GitHub Pages site (api-config.json).
set -u
BASE="/home/node/.openclaw/workspace/brands-hatch-predictor"
PORT=8790
LOG="$BASE/server/run.log"
CF=/tmp/cloudflared

log(){ echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# 1. API server
if ! pgrep -f "server/server.py" >/dev/null; then
  cd "$BASE/server"
  PORT=$PORT PREDICTOR_ADMIN_KEY="$(cat "$BASE/server/.admin_key")" \
    nohup python3 server.py >> "$LOG" 2>&1 &
  log "started API server pid $!"
  sleep 1
fi

# 2. Tunnel
if ! pgrep -f "cloudflared.*$PORT" >/dev/null; then
  [ -x "$CF" ] || { curl -sL -o "$CF" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x "$CF"; }
  nohup "$CF" tunnel --url "http://127.0.0.1:$PORT" --no-autoupdate > "$BASE/server/tunnel.log" 2>&1 &
  log "started cloudflared pid $!"
  # wait for URL
  for i in $(seq 1 30); do
    URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$BASE/server/tunnel.log" | head -1)
    [ -n "${URL:-}" ] && break
    sleep 2
  done
else
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$BASE/server/tunnel.log" | head -1)
fi

[ -z "${URL:-}" ] && { log "ERROR: no tunnel URL"; exit 1; }

# 3. Verify tunnel serves the API
ok=$(curl -s --max-time 10 "$URL/api/health" | grep -c '"ok"' || true)
if [ "$ok" = "0" ]; then
  log "tunnel $URL unhealthy; killing cloudflared for restart next run"
  pkill -f "cloudflared.*$PORT"
  exit 1
fi

# 4. Publish URL to the site if changed
CUR=$(cat "$BASE/site/api-config.json" 2>/dev/null || echo '')
NEW="{\"api\": \"$URL\"}"
if [ "$CUR" != "$NEW" ]; then
  echo "$NEW" > "$BASE/site/api-config.json"
  cd "$BASE"
  git add site/api-config.json && git commit -qm "update tunnel URL" && git push -q origin main
  log "published new tunnel URL $URL"
fi

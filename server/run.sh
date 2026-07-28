#!/bin/bash
# Keepalive: predictor API + tailscaled + funnel. Safe to run repeatedly (cron).
set -u
W="/home/node/.openclaw/workspace"
BASE="$W/brands-hatch-predictor"
TS="$W/bin/tailscale"
LOG="$BASE/server/run.log"
log(){ echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# 1. API server on 127.0.0.1:8790
if ! curl -s --max-time 3 http://127.0.0.1:8790/api/health | grep -q '"ok"'; then
  pgrep -f 'brands-hatch-predictor/server/server.py' | xargs -r kill 2>/dev/null
  cd "$BASE/server"
  PORT=8790 PREDICTOR_ADMIN_KEY="$(cat "$BASE/server/.admin_key")" \
    setsid nohup python3 server.py >> "$LOG" 2>&1 < /dev/null &
  log "restarted API server"
  sleep 1
fi

# 2. tailscaled
if ! "$TS" status >/dev/null 2>&1; then
  setsid "$W/opt/tailscale/tailscaled" --tun=userspace-networking \
    --state="$W/var/tailscale/tailscaled.state" \
    --socket="$W/var/tailscale/tailscaled.sock" \
    --statedir="$W/var/tailscale" > /tmp/tailscaled.log 2>&1 < /dev/null &
  log "restarted tailscaled"
  sleep 8
fi

# 3. funnel on :8443 -> 8790 (root stays tailnet-only)
if ! "$TS" serve status 2>/dev/null | grep -q 'ts.net (Funnel on)'; then
  "$TS" funnel --bg --https=443 http://127.0.0.1:8790 >/dev/null 2>&1
  log "re-enabled funnel :443"
fi
# autodev UI stays tailnet-only on :10000
if ! "$TS" serve status 2>/dev/null | grep -q ':10000 (tailnet only)'; then
  "$TS" serve --bg --https=10000 http://127.0.0.1:3456 >/dev/null 2>&1
  log "re-enabled tailnet serve :10000 (autodev UI)"
fi

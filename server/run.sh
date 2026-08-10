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

# 4. Publish state snapshot to GitHub Pages (same-origin fallback when the
#    funnel is unreachable from a visitor's network). Only commit real changes:
#    strip the volatile server_time field before comparing.
SNAP="$BASE/docs/state-snapshot.json"
if curl -s --max-time 5 http://127.0.0.1:8790/api/state \
     | python3 -c 'import json,sys; s=json.load(sys.stdin); s.pop("server_time",None); print(json.dumps(s,indent=1))' \
     > "$SNAP.tmp" 2>/dev/null && [ -s "$SNAP.tmp" ]; then
  if ! cmp -s "$SNAP.tmp" "$SNAP" 2>/dev/null; then
    mv "$SNAP.tmp" "$SNAP"
    if git -C "$BASE" diff --quiet -- docs/state-snapshot.json 2>/dev/null && ! git -C "$BASE" ls-files --error-unmatch docs/state-snapshot.json >/dev/null 2>&1; then
      : # new file, fall through to add
    fi
    git -C "$BASE" add docs/state-snapshot.json >/dev/null 2>&1
    if ! git -C "$BASE" diff --cached --quiet 2>/dev/null; then
      git -C "$BASE" commit -q -m "snapshot: state $(date -u +%FT%TZ)" >/dev/null 2>&1
      git -C "$BASE" push -q origin HEAD >/dev/null 2>&1 && log "pushed state snapshot" || log "snapshot push FAILED (kept local commit)"
    fi
  else
    rm -f "$SNAP.tmp"
  fi
else
  rm -f "$SNAP.tmp" 2>/dev/null
  log "snapshot fetch failed (API down?)"
fi

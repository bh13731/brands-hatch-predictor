#!/bin/bash
# Starts an ssh reverse tunnel via localhost.run and records the URL.
BASE="/home/node/.openclaw/workspace/brands-hatch-predictor"
LOGF="$BASE/server/tunnel.log"
: > "$LOGF"
nohup ssh -T -o StrictHostKeyChecking=no -o ServerAliveInterval=30 \
  -R 80:localhost:8790 nokey@localhost.run >> "$LOGF" 2>&1 &
echo $! > "$BASE/server/tunnel.pid"
for i in $(seq 1 20); do
  URL=$(grep -aoE 'https://[a-z0-9]+\.lhr\.life' "$LOGF" | tail -1)
  [ -n "$URL" ] && break
  sleep 2
done
echo "$URL"

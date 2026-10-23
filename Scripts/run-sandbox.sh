#!/bin/bash
# Run a trial build beside the installed app without touching its data.
#
# The app has no fixed port; what two copies would fight over is the data root under
# ~/Library/Application Support/Eureka: the SQLite ledger, the events spool, the relay
# binary in bin/, the plans staging dir, and the launch-time hook / update checks.
# This script gives the trial copy its own root:
#   - a `.backup` copy of the database (the live one keeps running untouched),
#   - a private spool / bin dir (EUREKA_SPOOL_DIR is the whole root, not just events/),
#   - a copy of the plans staging dir (mtimes preserved),
#   - EUREKA_SANDBOX=1, which skips Sparkle and the installed-hook refresh.
# Live hook events keep flowing to the installed app only, so the trial copy shows the
# copied history but no live island activity — that is intended.
#
# Usage: Scripts/run-sandbox.sh [path/to/app]      (default: dist/lulu-lumei-dock.app)
#        Scripts/run-sandbox.sh --stop             (quit the trial copy)
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="${EUREKA_SANDBOX_ROOT:-$HOME/Library/Application Support/Eureka-sandbox}"
LIVE="$HOME/Library/Application Support/Eureka"
PIDFILE="$ROOT/sandbox.pid"

if [ "${1:-}" = "--stop" ]; then
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" && echo "stopped sandbox pid $(cat "$PIDFILE")"
  else
    echo "no sandbox copy running"
  fi
  rm -f "$PIDFILE"
  exit 0
fi

APP="${1:-dist/lulu-lumei-dock.app}"
BIN="$APP/Contents/MacOS/eureka"
[ -x "$BIN" ] || { echo "no app binary at $BIN (run make app first)"; exit 1; }
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "a sandbox copy is already running (pid $(cat "$PIDFILE")); use --stop first"; exit 1
fi

mkdir -p "$ROOT/plans"
# Fresh snapshot of the ledger every launch so the trial copy sees today's data.
sqlite3 "$LIVE/eureka.sqlite" ".backup '$ROOT/eureka.sqlite'"
rm -f "$ROOT/eureka.sqlite-wal" "$ROOT/eureka.sqlite-shm"
# Plans staging keeps real mtimes (status / recency depend on them); the rest are caches
# and user assets that are nicer to have than to rebuild.
[ -d "$LIVE/plans" ] && cp -Rp "$LIVE/plans/." "$ROOT/plans/"
for item in mascots summaries mcp-probe-cache.json pricing-catalog-cache.json pricing.json context-windows.json; do
  [ -e "$LIVE/$item" ] && [ ! -e "$ROOT/$item" ] && cp -Rp "$LIVE/$item" "$ROOT/$item"
done

LOG="$ROOT/sandbox.log"
EUREKA_SANDBOX=1 \
EUREKA_DB_PATH="$ROOT/eureka.sqlite" \
EUREKA_SPOOL_DIR="$ROOT" \
EUREKA_PLANS_STAGING="$ROOT/plans" \
nohup "$BIN" > "$LOG" 2>&1 &
echo $! > "$PIDFILE"
echo "sandbox copy started: pid $(cat "$PIDFILE")"
echo "  app:  $APP"
echo "  data: $ROOT"
echo "  log:  $LOG"
echo "stop with: Scripts/run-sandbox.sh --stop"

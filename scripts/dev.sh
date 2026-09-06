#!/usr/bin/env bash
# One-command dev loop: build the helper and native TUI, start an isolated
# daemon, open its session picker, and stop that daemon when the TUI exits.
# STATE_DIR can select persistent development state; otherwise each invocation
# gets a fresh directory under build. SESSION is an optional saved session ID,
# never a database path. Listing alone creates or resumes no session.
# Interactive — run it from a real terminal.
#
#   scripts/dev.sh            # server + TUI, torn down together
#   scripts/dev.sh --smoke    # boot, probe v2 control, verify clean SIGTERM
#   scripts/dev.sh --shipment-smoke
#                             # the same smoke through bin/loomd and
#                             # Gleam's exported Erlang shipment
#
# The server runs --best-effort because a dev kernel usually cannot give
# the helper its full jail; run `make selftest` to see what yours enforces.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SMOKE=0
SHIPMENT=0
case "${1-}" in
  "") ;;
  --smoke) SMOKE=1 ;;
  --shipment-smoke) SMOKE=1; SHIPMENT=1 ;;
  *) echo "usage: scripts/dev.sh [--smoke | --shipment-smoke]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "dev.sh: too many arguments" >&2; exit 2; }

make binaries
if [ "$SHIPMENT" = 1 ]; then
  make server-shipment
else
  ( cd packages/client && gleam build --warnings-as-errors )
fi

mkdir -p "$ROOT/build"
DEV_ROOT="$(mktemp -d "$ROOT/build/dev.XXXXXX")"
STATE_DIR="${STATE_DIR:-$DEV_ROOT/state}"
WORKSPACE="${WORKSPACE:-$DEV_ROOT/work}"
mkdir -p "$WORKSPACE"
WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"
case "$STATE_DIR" in
  /*) ;;
  *) STATE_DIR="$ROOT/$STATE_DIR" ;;
esac

# The log announces the selected port, never a per-session identity or token.
# The interactive client authenticates through the private endpoint itself.
# Smoke supplies an offline configuration even if the developer has providers
# configured; its empty catalogue must not trigger any session assembly.
LOG="$DEV_ROOT/daemon.log"
DAEMON_ARGS=(--state-dir "$STATE_DIR" --bind 127.0.0.1:0
  --helper "$ROOT/bin/loom-exec" --best-effort)
CONFIG="${CONFIG:-}"
if [ "$SMOKE" = 1 ]; then CONFIG="$ROOT/scripts/release-smoke.toml"; fi
if [ -n "$CONFIG" ]; then
  case "$CONFIG" in
    /*) ;;
    *) CONFIG="$ROOT/$CONFIG" ;;
  esac
  DAEMON_ARGS+=(--config "$CONFIG")
fi

if [ "$SHIPMENT" = 1 ]; then
  "$ROOT/bin/loomd" "${DAEMON_ARGS[@]}" >"$LOG" 2>&1 &
else
  # Use the generated Gleam runner after compiling, just as the shipment does.
  # Both routes exec BEAM directly, so the captured PID owns the daemon and
  # SIGTERM reaches its handler without a gleam wrapper or platform setsid.
  erl -pa "$ROOT"/packages/client/build/dev/erlang/*/ebin \
    -noshell -eval 'client@@main:run(client)' \
    -extra "${DAEMON_ARGS[@]}" >"$LOG" 2>&1 &
fi
SERVER_PID=$!

teardown() {
  kill -TERM "$SERVER_PID" 2>/dev/null || true

  # The log supplies the aggregate drain verdict; wait supplies the original
  # native exit status. Neither a stop request nor a timeout is clean teardown.
  CLOSED=0
  STOPPED=0
  for _ in $(seq 1 50); do
    if grep -q '"event":"daemon.stopped"' "$LOG" 2>/dev/null; then
      CLOSED=1
    fi
    SERVER_STATE="$(ps -o stat= -p "$SERVER_PID" 2>/dev/null || true)"
    case "$SERVER_STATE" in
      ""|Z*) STOPPED=1 ;;
    esac
    [ "$CLOSED" = 1 ] && [ "$STOPPED" = 1 ] && break
    sleep 0.2
  done
  if [ "$STOPPED" != 1 ]; then
    # A broken SIGTERM path is precisely what this smoke protects. Bound the
    # reaping wait so that regression reports here instead of consuming the
    # job's outer timeout without an actionable failure.
    kill -KILL "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    echo "dev.sh: the server did not stop within 10 seconds of SIGTERM:" >&2
    tail -60 "$LOG" >&2
    return 1
  fi
  SERVER_STATUS=0
  wait "$SERVER_PID" 2>/dev/null || SERVER_STATUS=$?
  if [ "$CLOSED" != 1 ] || [ "$SERVER_STATUS" != 0 ]; then
    echo "dev.sh: the server did not close cleanly (status $SERVER_STATUS):" >&2
    tail -60 "$LOG" >&2
    return 1
  fi
}
trap teardown EXIT

LINE=""
for _ in $(seq 1 300); do
  LINE="$(grep -m1 'listening on ws://' "$LOG" || true)"
  [ -n "$LINE" ] && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "dev.sh: the server died during startup:" >&2
    tail -60 "$LOG" >&2
    exit 1
  fi
  sleep 0.2
done
if [ -z "$LINE" ]; then
  echo "dev.sh: the server never announced its port:" >&2
  tail -60 "$LOG" >&2
  exit 1
fi

PORT="$(printf '%s\n' "$LINE" | sed -n 's|.*ws://[^:]*:\([0-9]*\)/v2/control.*|\1|p')"
[ -n "$PORT" ] || { echo "dev.sh: invalid daemon startup address" >&2; exit 1; }
echo "dev.sh: daemon up — state $STATE_DIR, port $PORT, log $LOG"

if [ "$SMOKE" = 1 ]; then
  # Boot proof without a terminal: the legacy route is absent, control
  # requires authentication, and catalogue restoration starts no runtime.
  # Authenticated hello/session scenarios belong to the fuller release probe.
  HEALTH_STATUS="$(curl --connect-timeout 2 --max-time 5 -s -o /dev/null \
    -w '%{http_code}' "http://127.0.0.1:$PORT/healthz")"
  [ "$HEALTH_STATUS" = 404 ] || {
    echo "dev.sh: expected removed healthz route to return 404, got $HEALTH_STATUS" >&2; exit 1; }
  WS_STATUS="$(curl --connect-timeout 2 --max-time 5 -s -o /dev/null \
    -w '%{http_code}' "http://127.0.0.1:$PORT/v2/control")"
  if [ "$WS_STATUS" != 401 ]; then
    echo "dev.sh: expected 401 from an unauthenticated ws upgrade, got $WS_STATUS" >&2
    exit 1
  fi
  [ -s "$STATE_DIR/catalogue.db" ] || {
    echo "dev.sh: daemon created no catalogue" >&2; exit 1; }
  if grep -q '"event":"server.tools"' "$LOG"; then
    echo "dev.sh: daemon boot unexpectedly assembled a session" >&2; exit 1
  fi
  if ! teardown; then
    trap - EXIT
    exit 1
  fi
  trap - EXIT
  if [ "$SHIPMENT" = 1 ]; then
    echo "dev.sh: shipment smoke ok — legacy healthz 404, control 401, no session opens, clean close"
  else
    echo "dev.sh: smoke ok — legacy healthz 404, control 401, no session opens, clean close"
  fi
  exit 0
fi

# The terminal discovers and authenticates this daemon through its endpoint.
# Enter/New explicitly admits a session; opening the picker causes no effects.
TUI_ARGS=(--state-dir "$STATE_DIR" --workspace "$WORKSPACE")
if [ -n "$CONFIG" ]; then TUI_ARGS+=(--config "$CONFIG"); fi
if [ -n "${SESSION:-}" ]; then TUI_ARGS+=(--session "$SESSION"); fi
./bin/loom "${TUI_ARGS[@]}"

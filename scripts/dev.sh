#!/usr/bin/env bash
# One-command dev loop: build the helper and native TUI, start the server on
# a scratch session (or $SESSION) in the background, wait for its startup
# line, attach the TUI, and tear the server down when the TUI exits.
# Interactive — run it from a real terminal.
#
#   scripts/dev.sh            # server + TUI, torn down together
#   scripts/dev.sh --smoke    # non-interactive: boot, probe /healthz and
#                             # the ws route, verify a clean SIGTERM close
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
  --smoke) SMOKE=1 ;;
  --shipment-smoke) SMOKE=1; SHIPMENT=1 ;;
esac

make binaries
[ "$SHIPMENT" = 1 ] && make server-shipment

SESSION="${SESSION:-$ROOT/build/dev/session.db}"
WORKSPACE="${WORKSPACE:-$ROOT/build/dev/work}"
mkdir -p "$(dirname "$SESSION")" "$WORKSPACE"

# The server's stdout is the contract here: one startup line carrying the
# session id, the bound port, and the token file. Everything below reads
# that line rather than guessing.
LOG="$(mktemp -t loom-dev-server.XXXXXX.log)"
if [ "$SHIPMENT" = 1 ]; then
  # loomd and the shipment entrypoint both exec their child, so this PID
  # is the BEAM itself. Avoid setsid here because macOS does not ship it.
  "$ROOT/bin/loomd" \
    --session "$SESSION" --workspace "$WORKSPACE" \
    --helper "$ROOT/bin/loom-exec" --best-effort >"$LOG" 2>&1 &
  SERVER_PID=$!
  SERVER_TARGET="$SERVER_PID"
else
  # setsid puts the development server in its own process group: `gleam run`
  # wraps the BEAM and does not forward signals, so teardown targets the group.
  setsid bash -c "cd packages/client && exec gleam run -m client/serve -- \
      --session '$SESSION' --workspace '$WORKSPACE' \
      --helper '$ROOT/bin/loom-exec' --best-effort" >"$LOG" 2>&1 &
  SERVER_PID=$!
  SERVER_TARGET="-$SERVER_PID"
fi

teardown() {
  kill -TERM -- "$SERVER_TARGET" 2>/dev/null || true
  # Give the server's SIGTERM handler time to close the runtime and
  # release the session lease before we stop waiting on it. The witness is
  # the `server.stopped` structured log line, emitted once the listener is
  # closed and the lease released; it replaced a plain `loomd:
  # closed` println when the server's logging became structured (5abe62f),
  # and this script kept grepping for a line nothing printed any more.
  CLOSED=0
  STOPPED=0
  for _ in $(seq 1 50); do
    if grep -q '"event":"server.stopped"' "$LOG" 2>/dev/null; then
      CLOSED=1
    fi
    if [ "$SHIPMENT" = 1 ]; then
      SERVER_STATE="$(ps -o stat= -p "$SERVER_PID" 2>/dev/null || true)"
      case "$SERVER_STATE" in
        ""|Z*) STOPPED=1 ;;
      esac
    elif ! ps -ax -o pgid= -o stat= 2>/dev/null \
      | awk -v group="$SERVER_PID" \
        '$1 == group && $2 !~ /^Z/ { live = 1 } END { exit !live }'; then
      STOPPED=1
    fi
    [ "$CLOSED" = 1 ] && [ "$STOPPED" = 1 ] && break
    sleep 0.2
  done
  if [ "$STOPPED" != 1 ]; then
    # A broken SIGTERM path is precisely what this smoke protects. Bound the
    # reaping wait so that regression reports here instead of consuming the
    # job's outer timeout without an actionable failure.
    kill -KILL -- "$SERVER_TARGET" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    echo "dev.sh: the server did not stop within 10 seconds of SIGTERM:" >&2
    cat "$LOG" >&2
    return 1
  fi
  SERVER_STATUS=0
  wait "$SERVER_PID" 2>/dev/null || SERVER_STATUS=$?
  if [ "$CLOSED" != 1 ] || [ "$SERVER_STATUS" != 0 ]; then
    echo "dev.sh: the server did not close cleanly (status $SERVER_STATUS):" >&2
    cat "$LOG" >&2
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
    cat "$LOG" >&2
    exit 1
  fi
  sleep 0.2
done
if [ -z "$LINE" ]; then
  echo "dev.sh: the server never announced its port:" >&2
  cat "$LOG" >&2
  exit 1
fi

PORT="$(printf '%s\n' "$LINE" | sed -n 's|.*ws://[^:]*:\([0-9]*\)/v1/ws.*|\1|p')"
SESSION_ID="$(printf '%s\n' "$LINE" | sed -n 's|^loomd: session \([^ ]*\) .*|\1|p')"
TOKEN_FILE="$(printf '%s\n' "$LINE" | sed -n 's|.*(token file \(.*\))$|\1|p')"
echo "dev.sh: server up — session $SESSION_ID, port $PORT, log $LOG"

if [ "$SMOKE" = 1 ]; then
  # Boot proof without a terminal: health answers, the ws route is live
  # (an unauthenticated upgrade is turned away, not absent), and SIGTERM
  # produces the clean close line.
  curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null
  WS_STATUS="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/ws")"
  if [ "$WS_STATUS" != 401 ]; then
    echo "dev.sh: expected 401 from an unauthenticated ws upgrade, got $WS_STATUS" >&2
    exit 1
  fi
  if ! teardown; then
    trap - EXIT
    exit 1
  fi
  trap - EXIT
  if ! grep -q '"event":"server.stopped"' "$LOG"; then
    echo "dev.sh: the server did not close cleanly on SIGTERM:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  if [ "$SHIPMENT" = 1 ]; then
    echo "dev.sh: shipment smoke ok — healthz 200, ws 401 without a token, clean close"
  else
    echo "dev.sh: smoke ok — healthz 200, ws 401 without a token, clean close"
  fi
  exit 0
fi

# Hand the terminal to the TUI; the EXIT trap stops the server afterwards.
./bin/loom --addr "ws://127.0.0.1:$PORT/v1/ws" \
  --session "$SESSION_ID" --token "$(cat "$TOKEN_FILE")"

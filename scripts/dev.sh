#!/usr/bin/env bash
# One-command dev loop: build the helper and the TUI, start the server on
# a scratch session (or $SESSION) in the background, wait for its startup
# line, attach the TUI, and tear the server down when the TUI exits.
# Interactive — run it from a real terminal.
#
#   scripts/dev.sh            # server + TUI, torn down together
#   scripts/dev.sh --smoke    # non-interactive: boot, probe /healthz and
#                             # the ws route, verify a clean SIGTERM close
#
# The server runs --best-effort because a dev kernel usually cannot give
# the helper its full jail; run `make selftest` to see what yours enforces.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SMOKE=0
[ "${1-}" = "--smoke" ] && SMOKE=1

make binaries

SESSION="${SESSION:-$ROOT/build/dev/session.db}"
WORKSPACE="${WORKSPACE:-$ROOT/build/dev/work}"
mkdir -p "$(dirname "$SESSION")" "$WORKSPACE"

# The server's stdout is the contract here: one startup line carrying the
# session id, the bound port, and the token file. Everything below reads
# that line rather than guessing.
LOG="$(mktemp -t loom-dev-server.XXXXXX.log)"
# setsid puts the server in its own process group: `gleam run` wraps the
# BEAM in a child process and does not forward signals to it, so the
# teardown must signal the group, not the wrapper.
setsid bash -c "cd packages/client && exec gleam run -m client/serve -- \
    --session '$SESSION' --workspace '$WORKSPACE' \
    --helper '$ROOT/bin/loom-exec' --best-effort" >"$LOG" 2>&1 &
SERVER_PID=$!

teardown() {
  kill -TERM -- "-$SERVER_PID" 2>/dev/null || true
  # Give the server's SIGTERM handler time to close the runtime and
  # release the session lease before we stop waiting on it. The witness is
  # the `server.stopped` structured log line, emitted once the listener is
  # closed and the lease released; it replaced a plain `loom-server:
  # closed` println when the server's logging became structured (5abe62f),
  # and this script kept grepping for a line nothing printed any more.
  for _ in $(seq 1 50); do
    grep -q '"event":"server.stopped"' "$LOG" 2>/dev/null && break
    sleep 0.2
  done
  wait "$SERVER_PID" 2>/dev/null || true
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
SESSION_ID="$(printf '%s\n' "$LINE" | sed -n 's|^loom-server: session \([^ ]*\) .*|\1|p')"
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
  teardown
  trap - EXIT
  if ! grep -q '"event":"server.stopped"' "$LOG"; then
    echo "dev.sh: the server did not close cleanly on SIGTERM:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  echo "dev.sh: smoke ok — healthz 200, ws 401 without a token, clean close"
  exit 0
fi

# Hand the terminal to the TUI; the EXIT trap stops the server afterwards.
./bin/loom-tui --addr "ws://127.0.0.1:$PORT/v1/ws" \
  --session "$SESSION_ID" --token "$(cat "$TOKEN_FILE")"

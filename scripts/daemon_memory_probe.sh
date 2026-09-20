#!/bin/sh
# Three-cut BEAM memory census of a release daemon across session admission.
#
# Diagnostic tooling. It boots the built release by hand rather than through
# bin/loomd, because the only difference it needs is a distribution name: the
# launcher deliberately ships no vm.args and no cookie, and ERL_FLAGS would be
# inherited by every emulator the daemon itself spawns (code mode runs one),
# where a duplicate node name is a boot failure. Nothing is added to the server.
#
# Cuts: daemon listening, sessions admitted, the same sessions after an idle
# wait. Each records ps RSS, macOS footprint, and the BEAM accounting that
# scripts/mem_report.erl collects over distribution.
#
# Usage: scripts/daemon_memory_probe.sh <config.toml> <output-file> [idle-seconds]
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CONFIG=${1:?usage: daemon_memory_probe.sh <config.toml> <output-file> [idle-seconds]}
OUT=${2:?usage: daemon_memory_probe.sh <config.toml> <output-file> [idle-seconds]}
IDLE=${3:-60}

# Both the daemon and the probe run with their own working directory, so the
# configuration has to be named absolutely or one of them resolves it wrongly.
CONFIG=$(CDPATH= cd -- "$(dirname -- "$CONFIG")" && pwd -P)/$(basename -- "$CONFIG")
case $OUT in /*) ;; *) OUT="$PWD/$OUT" ;; esac

REL="$REPO/build/release/loom"
SUPPORT="$REPO/build/release/smoke-support"
[ -x "$REL/bin/loomd" ] || { echo "no release at $REL; run make release" >&2; exit 1; }
[ -f "$SUPPORT/client@release_probe_test.beam" ] || {
  echo "no smoke probe at $SUPPORT; run make release" >&2; exit 1; }

ERTS=$(cd "$REL" && ls -d erts-* | head -1 | sed 's/^erts-//')
VERSION=$(cd "$REL/releases" && ls -d */ | grep -v start_erl | head -1 | tr -d /)

# A fresh state root under the repository. Code mode refuses a capability
# socket under /tmp, so neither the state nor the workspace may live there.
#
# The daemon also gets its own HOME. Without that it reads the operator's
# ~/.claude, installs their imported hooks and extensions, and so builds a
# different tool registry from the one a bare host would — which is the term
# a memory census is usually here to weigh.
PROFILE="$REPO/build/loom-memory-profile.$$"
rm -rf "$PROFILE"
mkdir -p "$PROFILE/state" "$PROFILE/work" "$PROFILE/home"
LOG="$PROFILE/server.log"

# Long names over loopback rather than -sname. A short name is resolved
# through the host's own hostname, which on macOS can answer with an address
# the machine does not listen on, and the probe then cannot reach a daemon
# that is running perfectly well.
NODE="loommem$$@127.0.0.1"
COOKIE=loommemprobe
PROBE_EBIN="$PROFILE/probe-ebin"
mkdir -p "$PROBE_EBIN"
"$REL/erts-$ERTS/bin/erlc" -o "$PROBE_EBIN" "$REPO/scripts/mem_report.erl" "$REPO/scripts/mem_dig.erl" >/dev/null

: > "$OUT"

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill -TERM "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# The launcher's own invocation, plus a distribution name and the allocation
# tags a carrier census would need. The census itself does not run: `instrument`
# lives in OTP's `tools` application and a release does not carry it. The flag
# stays so that a run against a non-release build can ask.
(
  cd "$PROFILE/work" &&
  HOME="$PROFILE/home" exec "$REL/erts-$ERTS/bin/erl" \
    -boot "$REL/releases/$VERSION/no_dot_erlang" \
    -pa "$REL"/lib/*/ebin \
    -name "$NODE" -setcookie "$COOKIE" \
    +Muatags true \
    -noshell \
    -eval 'client@@main:run(client)' \
    -extra --state-dir "$PROFILE/state" --config "$CONFIG" --best-effort
) >"$LOG" 2>&1 &
SERVER_PID=$!

i=0
while [ "$i" -lt 300 ]; do
  grep -q 'listening on ws://' "$LOG" && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "daemon died:" >&2; tail -40 "$LOG" >&2; exit 1; }
  sleep 0.2
  i=$((i + 1))
done
grep -q 'listening on ws://' "$LOG" || { echo "daemon never listened:" >&2; tail -40 "$LOG" >&2; exit 1; }

census() {
  {
    echo "=================================================================="
    echo "## $1"
    date -u '+%Y-%m-%dT%H:%M:%SZ'
    ps -o pid=,rss=,vsz= -p "$SERVER_PID"
    footprint -p "$SERVER_PID" 2>/dev/null | grep -Ei 'TOTAL|VM_ALLOCATE|MALLOC' | head -12 || true
  } >>"$OUT"
  "$REL/erts-$ERTS/bin/erl" -boot "$REL/bin/no_dot_erlang" \
    -name "memprobe$$c$CENSUS@127.0.0.1" -setcookie "$COOKIE" \
    -pa "$PROBE_EBIN" -noshell -run mem_report main "$NODE" "$1" "${2:-observe}" \
    >>"$OUT" 2>&1 || true
  CENSUS=$((CENSUS + 1))
}
CENSUS=0

census "listening, no session"

# The release's own control-plane acceptance: it admits two sessions over the
# production websocket, then stops the first, leaving one resident.
(
  cd "$PROFILE/work" && env -i HOME="$PROFILE/home" PATH=/usr/bin:/bin \
    "$REL/erts-$ERTS/bin/erl" \
    -boot "$REL/bin/no_dot_erlang" -pa "$REL"/lib/*/ebin "$SUPPORT" \
    -noshell -eval 'application:ensure_all_started(client), client@release_probe_test:main(), erlang:halt(0, [{flush, true}]).' \
    -extra "$PROFILE/state" "$PROFILE/work" "$CONFIG"
) >"$PROFILE/probe.log" 2>&1 || {
  echo "session admission probe failed:" >&2; tail -40 "$PROFILE/probe.log" >&2; exit 1; }

census "two sessions admitted, one stopped"

sleep "$IDLE"
census "after ${IDLE}s idle"

# A full collection removes collectable garbage before the last cut. A step
# that survives can still include retained heap capacity; inspect terms before
# attributing the whole step to reachable state.
census "after a forced full collection" collect

# The walk itself allocates on the target node, so it runs after every cut
# rather than between two of them: a census taken behind it measures the probe.
if [ "${DIG:-0}" = 1 ]; then
  {
    echo "=================================================================="
    echo "## heaviest process states (taken after every cut)"
  } >>"$OUT"
  "$REL/erts-$ERTS/bin/erl" -boot "$REL/bin/no_dot_erlang" \
    -name "memdig$$@127.0.0.1" -setcookie "$COOKIE" -pa "$PROBE_EBIN" -noshell \
    -run mem_dig main "$NODE" >>"$OUT" 2>&1 || true
fi

echo "profile root: $PROFILE" >>"$OUT"
echo "wrote $OUT"

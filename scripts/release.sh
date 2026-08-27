#!/usr/bin/env bash
# Build a self-contained OTP release of the Loom server into
# build/release/loom — the BEAM runtime system included, so the machine
# that runs it needs no Erlang installed.
#
#   scripts/release.sh          # build the release tree
#   scripts/release.sh --smoke  # boot the built release and prove it serves
#
# Why a relx release rather than the erlang-shipment `make server-shipment`
# produces: a shipment is compiled BEAM files and nothing else, so it needs
# an OTP installation on the host. `include_erts` copies the runtime system
# in beside them. There is no Gleam-native way to ask for that, so the
# release is assembled by rebar3/relx over Gleam's own shipment output,
# which is the only artifact in the tree that already carries every
# dependency's `ebin` and `priv` in one place.
#
# This targets the host and only the host. `esqlite3_nif.so` is native code
# and the copied ERTS is this machine's, so a release is per-platform by
# construction; see docs/distribution.md.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

STRIP_ERTS="${DIST_STRIP_ERTS:-1}"

REL_ROOT="$ROOT/build/release"
REL="$REL_ROOT/loom"
WORK="$REL_ROOT/work"
SMOKE=0
[ "${1-}" = "--smoke" ] && SMOKE=1

# ------------------------------------------------------------ preflight
# The smoke deliberately skips all of this. Its whole claim is that the
# built release runs on a machine with no Erlang and no Gleam, so a
# preflight demanding either would undercut what it is there to prove.

if [ "$SMOKE" = 0 ]; then
  missing=""
  need() { command -v "$1" >/dev/null 2>&1 || missing="$missing  $1 — $2\n"; }
  need gleam  "exports the client package as an erlang shipment (>= 1.11)"
  need rebar3 "assembles the OTP release and copies ERTS into it"
  need erl    "the runtime system that gets copied in (OTP >= 27)"
  need go     "builds the loom-exec sandbox helper (>= 1.24)"
  if [ "$STRIP_ERTS" = 1 ]; then
    need strip "strips the copied ERTS binaries (DIST_STRIP_ERTS=0 to skip)"
  fi
  if [ -n "$missing" ]; then
    printf 'release.sh: cannot build a release, these are not on PATH:\n' >&2
    printf '%b' "$missing" >&2
    exit 1
  fi
fi

# Go cross-compiles happily; the release does not. Refusing here is better
# than shipping a tree whose ERTS and NIF are for the build host while its
# name claims otherwise.
if [ "$SMOKE" = 0 ]; then
  host_os="$(go env GOHOSTOS)"
  host_arch="$(go env GOHOSTARCH)"
  if [ "${GOOS:-$host_os}" != "$host_os" ] || [ "${GOARCH:-$host_arch}" != "$host_arch" ]; then
    echo "release.sh: GOOS/GOARCH ask for ${GOOS:-$host_os}/${GOARCH:-$host_arch}, but a" >&2
    echo "  release carries this host's ERTS and this host's esqlite NIF. Build the" >&2
    echo "  release on the target platform; see docs/distribution.md." >&2
    exit 1
  fi

  VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' packages/client/gleam.toml | head -1)"
  [ -n "$VERSION" ] || { echo "release.sh: no version in packages/client/gleam.toml" >&2; exit 1; }
  ERTS_VSN="$(erl -noshell -eval 'io:format("~s",[erlang:system_info(version)]),halt().')"
fi

# ------------------------------------------------------------ smoke only

if [ "$SMOKE" = 1 ]; then
  [ -x "$REL/bin/loom" ] || {
    echo "release.sh: no release at $REL — run \`make release\` first" >&2; exit 1; }
  command -v curl >/dev/null || { echo "release.sh: --smoke needs curl" >&2; exit 1; }

  SESSION="$REL_ROOT/smoke/session.db"
  WORKSPACE="$REL_ROOT/smoke/work"
  rm -rf "$REL_ROOT/smoke"; mkdir -p "$(dirname "$SESSION")" "$WORKSPACE"
  LOG="$REL_ROOT/smoke/server.log"

  # The release is run the way a downloaded one is: from a directory that
  # is not the repository, with nothing of Loom's on PATH, so a helper
  # found by accident cannot make the run look better than it is.
  ( cd "$WORKSPACE" && env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
      "$REL/bin/loom" --session "$SESSION" --workspace "$WORKSPACE" \
      --best-effort ) >"$LOG" 2>&1 &
  SERVER_PID=$!
  trap 'kill -TERM "$SERVER_PID" 2>/dev/null || true' EXIT

  LINE=""
  for _ in $(seq 1 150); do
    LINE="$(grep -m1 'listening on ws://' "$LOG" || true)"
    if [ -n "$LINE" ]; then break; fi
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "release.sh: the release died during startup:" >&2; tail -40 "$LOG" >&2; exit 1; }
    sleep 0.2
  done
  [ -n "$LINE" ] || { echo "release.sh: the release never announced its port:" >&2; tail -40 "$LOG" >&2; exit 1; }

  PORT="$(printf '%s\n' "$LINE" | sed -n 's|.*ws://[^:]*:\([0-9]*\)/v1/ws.*|\1|p')"
  curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null
  WS="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/ws")"
  [ "$WS" = 401 ] || { echo "release.sh: expected 401 from an unauthenticated ws upgrade, got $WS" >&2; exit 1; }
  # The session file proves the esqlite NIF loaded and wrote: it is the
  # one piece of native code in the release that is not the emulator.
  [ -s "$SESSION" ] || { echo "release.sh: no session file was written — did the NIF load?" >&2; exit 1; }

  # `server.stopped` is the structured log line the shutdown path emits
  # after the listener is closed and the session lease released, so it is
  # the witness that SIGTERM took the graceful route rather than killing a
  # server mid-lease.
  kill -TERM "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if grep -q '"event":"server.stopped"' "$LOG"; then break; fi
    sleep 0.2
  done
  wait "$SERVER_PID" 2>/dev/null || true
  trap - EXIT
  grep -q '"event":"server.stopped"' "$LOG" || {
    echo "release.sh: the release did not close cleanly on SIGTERM:" >&2; tail -40 "$LOG" >&2; exit 1; }

  echo "release.sh: smoke ok — no erl on PATH, healthz 200, ws 401 without a token,"
  echo "            session written by the bundled NIF, clean close on SIGTERM"
  exit 0
fi

# ------------------------------------------------------------ the build

echo "==> exporting the erlang shipment"
( cd packages/client && gleam export erlang-shipment >/dev/null )

rm -rf "$REL" "$WORK"
mkdir -p "$WORK/libs"
cp -R packages/client/build/erlang-shipment/. "$WORK/libs/"
rm -f "$WORK/libs/entrypoint.sh" "$WORK/libs/entrypoint.ps1"

# relx reads app directories out of lib_dirs and works out the release's
# application closure itself, which is why the OTP applications the Gleam
# packages depend on (crypto, ssl, inets, …) arrive without being listed.
# `debug_info, strip` drops the Dbgi chunk from every beam; nothing in the
# shipped server decompiles itself.
cat > "$WORK/rebar.config" <<EOF
%% Generated by scripts/release.sh. Edit the script, not this file.
{erl_opts, []}.
{deps, []}.
{project_app_dirs, []}.
{relx, [
  {release, {loom, "$VERSION"}, [client]},
  {lib_dirs, ["libs"]},
  {include_erts, true},
  {include_src, false},
  {dev_mode, false},
  {debug_info, strip}
]}.
EOF

echo "==> assembling the release (rebar3 relx)"
( cd "$WORK" && rebar3 release >/dev/null )
mkdir -p "$REL_ROOT"
mv "$WORK/_build/default/rel/loom" "$REL"
rm -rf "$WORK"

# relx's own launcher is a daemon supervisor: it starts a *distributed*
# node from releases/*/vm.args, which relx generates with `-sname loom
# -setcookie loom`, and offers ping/rpc/remsh over it. A guessable cookie
# on a node that accepts remote calls is precisely the thing the design's
# two-channel doctrine says must never be the default, and Loom has no
# control plane for it to serve. So the artifact does not carry it, and
# neither does it carry the vm.args and sys.config that only that script
# reads — a config file nothing loads is a trap for whoever edits it.
rm -f "$REL"/bin/* \
      "$REL/releases/$VERSION/vm.args" \
      "$REL/releases/$VERSION/sys.config"

# The ERTS binaries arrive with their full symbol tables; beam.smp alone is
# 53 MB of which about 42 MB is symbols and DWARF the emulator never reads.
# Erlang crash dumps and stack traces come from the BEAM's own tables, not
# from ELF, so this costs a C-level backtrace under gdb and nothing else.
if [ "$STRIP_ERTS" = 1 ]; then
  echo "==> stripping the copied ERTS"
  find "$REL/erts-$ERTS_VSN/bin" -type f -exec sh -c '
    file -b "$1" | grep -q "ELF.*not stripped" && strip -s "$1"' _ {} \; || true
fi

# The launcher. It is the shipment entrypoint's invocation with two
# changes: `erl` is the bundled one rather than whatever is on PATH, and
# the boot script is `no_dot_erlang`, so a `~/.erlang` nobody audited does
# not get evaluated inside the harness VM on the way up.
#
# It also names the helper beside it, because the server's own ladder is
# `--helper`, then PATH, then ./bin, and an unpacked release is usually
# neither. The injection is skipped when the caller passed `--helper`, so
# an operator pointing at a packaged or separately audited helper still
# wins; see docs/distribution.md for why the helper ships as a file beside
# the release rather than embedded in it.
cat > "$REL/bin/loom" <<EOF
#!/bin/sh
# Generated by scripts/release.sh. The Loom session server.
set -eu
here=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd -P)
root=\$(dirname "\$here")

helper=""
for arg in "\$@"; do
  [ "\$arg" = "--helper" ] && helper=given
done
[ -n "\$helper" ] || set -- --helper "\$here/loom-exec" "\$@"

exec "\$root/erts-$ERTS_VSN/bin/erl" \\
  -boot "\$root/releases/$VERSION/no_dot_erlang" \\
  -pa "\$root"/lib/*/ebin \\
  -noshell \\
  -eval 'client@@main:run(client)' \\
  -extra "\$@"
EOF
chmod +x "$REL/bin/loom"

echo "==> building the sandbox helper"
scripts/go-build.sh "$ROOT/packages/sandbox" ./cmd/loom-exec "$REL/bin/loom-exec"

# A manifest an operator can check the unpacked tree against, and the
# reason the helper's digest is quotable at all: it is a file on disk from
# the moment the tarball is unpacked, not something conjured at runtime.
# macOS ships `shasum` and not `sha256sum`, and its `sort` has no `-z`, so
# the pipeline avoids both rather than working only on the one platform a
# release has so far been built on.
SHA256=sha256sum
command -v sha256sum >/dev/null 2>&1 || SHA256="shasum -a 256"
( cd "$REL" && find . -type f -perm -u+x \
    | LC_ALL=C sort | tr '\n' '\0' | xargs -0 $SHA256 > SHA256SUMS )

echo
echo "release: $REL"
# One `du` per path: GNU du skips a directory it has already descended
# into, so a single call with the tree and its own subdirectories reports
# the tree and nothing else.
for p in "$REL" "$REL/erts-$ERTS_VSN" "$REL/lib" "$REL/bin/loom-exec"; do
  du -sh "$p" | sed 's/^/  /'
done
echo "  helper sha256: $($SHA256 "$REL/bin/loom-exec" | cut -c1-16)…"
echo "run it with: $REL/bin/loom --session <path.db> --workspace <dir>"

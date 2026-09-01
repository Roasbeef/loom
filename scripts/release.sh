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

# DIST_STRIP_ERTS covers every third-party binary the release copies in:
# the ERTS ones and the bundled `gleam`. DIST_CODEMODE=0 builds the lean
# 29 MB release with no code mode in it, for a deploy that will never
# write a program; see docs/distribution.md for why bundling is the
# default.
STRIP_ERTS="${DIST_STRIP_ERTS:-1}"
CODEMODE="${DIST_CODEMODE:-1}"
SEED="$ROOT/build/codemode-seed"

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
  need gleam  "exports the client package as an erlang shipment (>= 1.18)"
  need rebar3 "assembles the OTP release and copies ERTS into it"
  need erl    "the runtime system that gets copied in (OTP >= 29)"
  need go     "builds the loom-exec sandbox helper (>= 1.24)"
  if [ "$STRIP_ERTS" = 1 ]; then
    need strip "strips the copied ERTS binaries (DIST_STRIP_ERTS=0 to skip)"
  fi
  if [ -n "$missing" ]; then
    printf 'release.sh: cannot build a release, these are not on PATH:\n' >&2
    printf '%b' "$missing" >&2
    exit 1
  fi

  # The seed is the one prerequisite the release cannot produce for
  # itself: preparing it is the only step in this tree allowed the
  # network, and quietly building a release without it would ship the
  # artifact this whole arrangement exists to stop shipping — one where
  # code mode silently is not there.
  if [ "$CODEMODE" = 1 ] && [ ! -d "$SEED" ]; then
    echo "release.sh: no code-mode build seed at $SEED." >&2
    echo "  Run \`make codemode-seed\` (it needs the network, once), or build a" >&2
    echo "  release without code mode with DIST_CODEMODE=0." >&2
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
  [ -x "$REL/bin/loomd" ] || {
    echo "release.sh: no release at $REL — run \`make release\` first" >&2; exit 1; }
  command -v curl >/dev/null || { echo "release.sh: --smoke needs curl" >&2; exit 1; }

  # The smoke has no `erl` on PATH to ask for a version — that is the
  # whole point of it — so the ERTS version is read off the tree.
  SMOKE_ERTS="$(cd "$REL" && ls -d erts-* 2>/dev/null | head -1 | sed 's/^erts-//')"
  [ -n "$SMOKE_ERTS" ] || {
    echo "release.sh: no erts-* in $REL — that is not a release" >&2; exit 1; }

  SESSION="$REL_ROOT/smoke/session.db"
  WORKSPACE="$REL_ROOT/smoke/work"
  rm -rf "$REL_ROOT/smoke"; mkdir -p "$(dirname "$SESSION")" "$WORKSPACE"
  LOG="$REL_ROOT/smoke/server.log"

  # The release is run the way a downloaded one is: from a directory that
  # is not the repository, with nothing of Loom's on PATH, so a helper
  # found by accident cannot make the run look better than it is.
  ( cd "$WORKSPACE" && env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
      "$REL/bin/loomd" --session "$SESSION" --workspace "$WORKSPACE" \
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

  # #101. The launcher no longer injects `--helper`; this proves the
  # server finds the shipped one without it. It is not a test of the
  # ladder's *order* — OTP's erl script prepends $ROOTDIR/bin to PATH, so
  # the PATH rung would answer with the same file — and the order is
  # tested where it can be, in client/install_test. What this witnesses
  # is that the injection is gone and nothing needed it, which is the
  # whole of what #101 asked for.
  # `pwd -P` because code:root_dir() is what the emulator physically
  # resolved, and $REL is only as physical as the path make was run from.
  REL_PHYS="$(cd "$REL" && pwd -P)"
  grep -q "\"helper\":\"$REL_PHYS/bin/loom-exec\"" "$LOG" || {
    echo "release.sh: the release did not find the helper beside itself:" >&2
    grep -m1 server.listening "$LOG" >&2 || tail -40 "$LOG" >&2
    exit 1; }

  # #102. `server.tools` is the registry this boot actually built. Code
  # mode registers only when discover() found a compiler, an emulator and
  # a seed it verified — so this line failing is the whole bug, and
  # asserting on anything softer would let it back in. The seed is the
  # rung with teeth here: `share/codemode-seed` is not an executable, so
  # no PATH mechanism can substitute for it, and dropping the bundled
  # rung from serve.seed_ladder fails exactly this check.
  TOOLS="$(grep -m1 '"event":"server.tools"' "$LOG" || true)"
  [ -n "$TOOLS" ] || {
    echo "release.sh: the release logged no server.tools line:" >&2
    tail -40 "$LOG" >&2; exit 1; }
  if [ -d "$REL/share/codemode-seed" ]; then
    case "$TOOLS" in
      *code_mode*) ;;
      *) echo "release.sh: the release bundles code mode but registered no" >&2
         echo "  code_mode tool. The reason it gave was:" >&2
         grep -m1 codemode.unavailable "$LOG" | sed 's/^/    /' >&2 || true
         exit 1 ;;
    esac
  else
    case "$TOOLS" in
      *code_mode*) echo "release.sh: a release built with DIST_CODEMODE=0 registered code_mode" >&2
                   exit 1 ;;
      *) ;;
    esac
  fi

  # `server.stopped` is the structured log line the shutdown path emits
  # after the listener is closed and the session lease released, so it is
  # the witness that SIGTERM took the graceful route rather than killing a
  # server mid-lease.
  kill -TERM "$SERVER_PID" 2>/dev/null || true
  CLOSED=0
  STOPPED=0
  for _ in $(seq 1 50); do
    if grep -q '"event":"server.stopped"' "$LOG"; then CLOSED=1; fi
    SERVER_STATE="$(ps -o stat= -p "$SERVER_PID" 2>/dev/null || true)"
    case "$SERVER_STATE" in
      ""|Z*) STOPPED=1 ;;
    esac
    [ "$CLOSED" = 1 ] && [ "$STOPPED" = 1 ] && break
    sleep 0.2
  done
  if [ "$STOPPED" != 1 ]; then
    # A broken SIGTERM path must fail this smoke promptly rather than leave the
    # caller blocked until its outer CI timeout.
    kill -KILL "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    trap - EXIT
    echo "release.sh: the release did not stop within 10 seconds of SIGTERM:" >&2
    tail -40 "$LOG" >&2
    exit 1
  fi
  SERVER_STATUS=0
  wait "$SERVER_PID" 2>/dev/null || SERVER_STATUS=$?
  trap - EXIT
  if [ "$CLOSED" != 1 ] || [ "$SERVER_STATUS" != 0 ]; then
    echo "release.sh: the release did not close cleanly (status $SERVER_STATUS):" >&2
    tail -40 "$LOG" >&2
    exit 1
  fi

  # Registration says the release found a compiler, an emulator and a
  # seed it verified. It does not say they *work* together, and the two
  # ways they might not are both packaging faults rather than code ones:
  # the bundled gleam is stripped, and the bundled ERTS is a release's
  # ERTS rather than an installation's. So the smoke does what a code-mode
  # build does — clone the seed, compile it offline with nothing but the
  # release's own bin on PATH — because a tool that registers and then
  # cannot compile is the same bug wearing a different hat.
  if [ -d "$REL/share/codemode-seed" ]; then
    PROBE="$REL_ROOT/smoke/seed"
    cp -R "$REL/share/codemode-seed" "$PROBE"
    rm -rf "$PROBE/build/dev/erlang/loom_codemode_program"
    if unshare -rn true 2>/dev/null; then
      ( cd "$PROBE" && env -i HOME="${HOME:-/tmp}" \
          PATH="$REL/bin:$REL/erts-$SMOKE_ERTS/bin:/usr/bin:/bin" \
          unshare -rn gleam build --warnings-as-errors ) \
          >"$REL_ROOT/smoke/build.log" 2>&1 || {
        echo "release.sh: the bundled toolchain could not build the bundled seed:" >&2
        sed 's/^/    /' "$REL_ROOT/smoke/build.log" >&2
        exit 1; }
      echo "release.sh: bundled toolchain builds the bundled seed offline"
    else
      echo "release.sh: bundled-toolchain build NOT verified here (this kernel" \
           "refuses an unprivileged network namespace); make e2e-codemode" \
           "still exercises the pipeline"
    fi
  fi

  # And the other half of #101's ordering claim: an explicit --helper
  # must still outrank the one beside the binary, because that flag is
  # how an operator points at a helper they audited themselves. A ladder
  # that had merely gained a rung too high would boot fine here; one that
  # honours the flag refuses, naming the path it was given.
  REFUSAL="$REL_ROOT/smoke/refusal.log"
  if ( cd "$WORKSPACE" && env -i HOME="${HOME:-/tmp}" PATH=/usr/bin:/bin \
         "$REL/bin/loomd" --session "$REL_ROOT/smoke/nope.db" \
         --workspace "$WORKSPACE" --best-effort \
         --helper /nonexistent/loom-exec ) >"$REFUSAL" 2>&1; then
    echo "release.sh: --helper /nonexistent/loom-exec was ignored — the flag" >&2
    echo "  no longer outranks the helper beside the binary." >&2
    exit 1
  fi
  grep -q '/nonexistent/loom-exec' "$REFUSAL" || {
    echo "release.sh: the refusal did not name the helper it was given:" >&2
    cat "$REFUSAL" >&2; exit 1; }

  echo "release.sh: smoke ok — no erl on PATH, healthz 200, ws 401 without a token,"
  echo "            session written by the bundled NIF, clean close on SIGTERM,"
  echo "            the helper found beside the binary with no --helper injected,"
  echo "            and an explicit --helper still winning"
  if [ -d "$REL/share/codemode-seed" ]; then
    echo "            plus code_mode registered from the bundled toolchain"
  else
    echo "            plus no code_mode, as a DIST_CODEMODE=0 release should"
  fi
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
#
# `compiler` is listed only for a code-mode bundle, and it is not the
# harness that wants it: `gleam build` compiles Erlang through an
# `escript`, an escript is compiled at load time by `compile:forms/1`,
# and that lives in the `compiler` application — which nothing in the
# server's own closure pulls in, so the bundled toolchain would boot and
# then fail `undef` on its first module. 3.1 MB of the release, and no
# part of it is reachable from the harness: it is loaded by the emulator
# the *build jail* runs, not by this VM.
APPS="client"
[ "$CODEMODE" = 1 ] && APPS="client, compiler"
cat > "$WORK/rebar.config" <<EOF
%% Generated by scripts/release.sh. Edit the script, not this file.
{erl_opts, []}.
{deps, []}.
{project_app_dirs, []}.
{relx, [
  {release, {loom, "$VERSION"}, [$APPS]},
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
#
# `*.boot` is spared, and that is not tidiness. relx puts the standard
# no_dot_erlang.boot and start_clean.boot in bin/ because that is where
# $ROOTDIR/bin/*.boot lives in every OTP installation, and `escript`
# boots the emulator with `-boot no_dot_erlang` resolved against exactly
# that path. Deleting them left a release whose own escript, and
# therefore its erlc, could not start — invisible until something other
# than the launcher tried to boot the bundled ERTS, because the launcher
# names its boot file absolutely. `gleam build` shells out to escript, so
# code mode in a release is the thing that tried.
find "$REL/bin" -maxdepth 1 -type f ! -name '*.boot' -delete
rm -f "$REL/releases/$VERSION/vm.args" \
      "$REL/releases/$VERSION/sys.config"

# Say so rather than discovering it in a jail later: a release whose ERTS
# cannot boot plainly is one where every part of code mode past `gleam`
# fails with a bootfile error nobody will connect to packaging.
[ -f "$REL/bin/no_dot_erlang.boot" ] || {
  echo "release.sh: relx left no bin/no_dot_erlang.boot; the bundled escript" >&2
  echo "  cannot boot without it. See the comment above this check." >&2
  exit 1; }

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
# It used to inject `--helper "$here/loom-exec"` as well, because the
# server's ladder was `--helper`, then PATH, then ./bin and an unpacked
# release is neither. That block is gone: the ladder now asks
# `code:root_dir()` — the release root, resolved by the emulator itself —
# before it asks PATH, so the shipped helper is found however this
# release is invoked, and found *ahead of* any stray loom-exec on PATH.
# Papering over the ladder here would have been the same defect in a new
# place; see #101 and packages/client/src/client/install.gleam.
cat > "$REL/bin/loomd" <<EOF
#!/bin/sh
# Generated by scripts/release.sh. The Loom session server.
set -eu
here=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd -P)
root=\$(dirname "\$here")

exec "\$root/erts-$ERTS_VSN/bin/erl" \\
  -boot "\$root/releases/$VERSION/no_dot_erlang" \\
  -pa "\$root"/lib/*/ebin \\
  -noshell \\
  -eval 'client@@main:run(client)' \\
  -extra "\$@"
EOF
chmod +x "$REL/bin/loomd"
# Relx generates a server launcher named after the internal release. The
# product-facing `loom` name belongs to the separately packaged client.
rm -f "$REL/bin/loom"

echo "==> building the sandbox helper"
scripts/go-build.sh "$ROOT/packages/sandbox" ./cmd/loom-exec "$REL/bin/loom-exec"

# Code mode: the compiler and the pre-resolved package cache a hermetic
# build is cloned from. The release already carried the third thing
# `discover` asks for — `erts-*/bin/erl` — and the server now finds all
# three from `code:root_dir()` rather than from PATH, so these two files
# are the whole of what was actually missing.
#
# Both land where client/install looks: bin/gleam and share/codemode-seed.
# The seed is copied rather than symlinked because the tarball has to
# carry it, and `codemode/build` clones it per execution anyway, so it is
# read-only from the server's point of view.
if [ "$CODEMODE" = 1 ]; then
  echo "==> bundling code mode (gleam + the build seed)"
  cp "$(command -v gleam)" "$REL/bin/gleam"
  chmod +x "$REL/bin/gleam"
  # The upstream gleam release is not stripped; everything else in this
  # tree is. Measured on the 1.18.1 linux-x86_64 binary: 29,168,608 ->
  # 22,826,152 bytes, 21.7% off, and it still builds — `make
  # release-smoke` compiles nothing, so `make e2e-codemode` is what
  # proves that second half.
  if [ "$STRIP_ERTS" = 1 ]; then
    strip -s "$REL/bin/gleam" 2>/dev/null || true
  fi
  mkdir -p "$REL/share"
  cp -R "$SEED" "$REL/share/codemode-seed"
fi

# A manifest an operator can check the unpacked tree against, and the
# reason the helper's digest is quotable at all: it is a file on disk from
# the moment the tarball is unpacked, not something conjured at runtime.
# macOS ships `shasum` and not `sha256sum`, and its `sort` has no `-z`, so
# the pipeline avoids both rather than working only on the one platform a
# release has so far been built on.
#
# Every executable file, *and* everything under share/. The second half
# is not thoroughness for its own sake: the build seed holds
# `vendor/cap` and `vendor/core`, the prelude that is compiled into every
# satellite a code-mode program ever runs as. A tampered seed is
# arbitrary code inside every jailed node, and "executables only" would
# have left the one part of the tarball that becomes code without being
# one outside the manifest. `sort -u` because an executable under share/
# would otherwise be listed twice.
SHA256=sha256sum
command -v sha256sum >/dev/null 2>&1 || SHA256="shasum -a 256"
( cd "$REL" && { find . -type f -perm -u+x; \
                 if [ -d share ]; then find ./share -type f; fi; } \
    | LC_ALL=C sort -u | tr '\n' '\0' | xargs -0 $SHA256 > SHA256SUMS )

echo
echo "release: $REL"
# One `du` per path: GNU du skips a directory it has already descended
# into, so a single call with the tree and its own subdirectories reports
# the tree and nothing else.
sizes="$REL $REL/erts-$ERTS_VSN $REL/lib $REL/bin/loom-exec"
[ "$CODEMODE" = 1 ] && sizes="$sizes $REL/bin/gleam $REL/share/codemode-seed"
for p in $sizes; do
  du -sh "$p" | sed 's/^/  /'
done
echo "  helper sha256: $($SHA256 "$REL/bin/loom-exec" | cut -c1-16)…"
echo "run it with: $REL/bin/loomd --session <path.db> --workspace <dir>"

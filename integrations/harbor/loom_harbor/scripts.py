"""The shell the adapter runs inside the task container.

Each script is a constant, not a template. Everything that varies reaches it
through environment variables, which the adapter sets and shell-quotes
nowhere, so there is no string in a script that a model name, a path or an
instruction could break out of. That also lets the tests execute the very
text that ships, against stub binaries, with no container.

All three scripts write their narration to standard error. The run script's
standard output is reserved for exactly one thing, the JSON report that
`loom run` printed, because the adapter parses it.
"""

from __future__ import annotations

import shlex

# Exit statuses the run script adds to `loom run`'s own (0, 1, 2, 3, 124). They
# sit above anything `loom run` returns so that the two cannot be confused.
EXIT_PREREQUISITE = 40
EXIT_DAEMON_NOT_READY = 41
EXIT_NO_REPORT = 43

INSTALL_SCRIPT = r"""
set -euo pipefail

fail() { echo "loom-harbor install: $*" >&2; exit 1; }

PREFIX="${LOOM_PREFIX:?LOOM_PREFIX is required}"
BASE_URL="${LOOM_BASE_URL:-}"
SERVER_TARBALL="${LOOM_SERVER_TARBALL:-}"
CLIENT_TARBALL="${LOOM_CLIENT_TARBALL:-}"
# Optional pins. SHA256SUMS comes from the same origin as the archives, so on
# its own it detects corruption and truncation, not a malicious release. A pin
# supplied out of band (the digest of SHA256SUMS, or of each archive) is what
# turns the check into a provenance check.
SUMS_PIN="${LOOM_SUMS_SHA256:-}"
SERVER_PIN="${LOOM_SERVER_SHA256:-}"
CLIENT_PIN="${LOOM_CLIENT_SHA256:-}"

platform="${LOOM_PLATFORM:-}"
if [ -z "$platform" ]; then
  case "$(uname -s)" in
    Linux) os=linux ;;
    *) fail "unsupported operating system $(uname -s); the task container must be Linux" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) fail "unsupported architecture $(uname -m); Loom releases are built per platform" ;;
  esac
  platform="$os-$arch"
fi

fetch() {
  case "$1" in
    https://*|file://*) ;;
    http://*) fail "refusing to fetch $1 over plain http; a release source must be https (or a file:// mirror)" ;;
    *) fail "refusing to fetch $1; a release source must be an https or file URL" ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https,file' --proto-redir '=https' --retry 3 --retry-delay 2 --connect-timeout 20 -o "$2" "$1" \
      || fail "could not download $1 (is a $platform release published at that address, and is the network open?)"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --https-only -O "$2" "$1" || fail "could not download $1"
  else
    fail "neither curl nor wget is installed in the container"
  fi
}

mkdir -p "$PREFIX" || fail "cannot create $PREFIX (the install runs as root)"
work="$(mktemp -d "$PREFIX/.work.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Decide what to install and what its digests must be.
if [ -n "$SERVER_TARBALL" ] || [ -n "$CLIENT_TARBALL" ]; then
  [ -f "$SERVER_TARBALL" ] || fail "LOOM_SERVER_TARBALL ($SERVER_TARBALL) is not a file"
  [ -f "$CLIENT_TARBALL" ] || fail "LOOM_CLIENT_TARBALL ($CLIENT_TARBALL) is not a file"
  server_file="$SERVER_TARBALL"
  client_file="$CLIENT_TARBALL"
  server_sha="$(sha256sum "$server_file" | cut -d' ' -f1)"
  client_sha="$(sha256sum "$client_file" | cut -d' ' -f1)"
  # With no pin the digests above are computed from the files themselves, so
  # they prove nothing about where the files came from; say so.
  if [ -z "$SERVER_PIN" ] || [ -z "$CLIENT_PIN" ]; then
    echo "loom-harbor install: local archives are not verified against any expected digest (set server_sha256 and client_sha256 to pin them)" >&2
  fi
  [ -z "$SERVER_PIN" ] || [ "$SERVER_PIN" = "$server_sha" ] || fail "digest mismatch for the server archive: pinned $SERVER_PIN, got $server_sha"
  [ -z "$CLIENT_PIN" ] || [ "$CLIENT_PIN" = "$client_sha" ] || fail "digest mismatch for the client archive: pinned $CLIENT_PIN, got $client_sha"
  server_name="$(basename "$server_file")"
  client_name="$(basename "$client_file")"
  source_label="local:$server_name,$client_name"
else
  [ -n "$BASE_URL" ] || fail "no release source: set a release, a release base URL or both tarballs"
  fetch "$BASE_URL/SHA256SUMS" "$work/SHA256SUMS"
  if [ -n "$SUMS_PIN" ]; then
    actual_sums="$(sha256sum "$work/SHA256SUMS" | cut -d' ' -f1)"
    [ "$actual_sums" = "$SUMS_PIN" ] || fail "digest mismatch for SHA256SUMS: pinned $SUMS_PIN, got $actual_sums"
  fi
  # The server is loomd-<version>-<platform>; the client is loom-<version>-<platform>.
  # `loom-slim-` and `loomd-` are excluded by requiring a digit after the stem.
  names() { awk '{print $2}' "$work/SHA256SUMS" | grep -E "$1" || true; }
  server_name="$(names "^loomd-[0-9][^/ ]*-${platform}\\.tar\\.gz\$")"
  client_name="$(names "^loom-[0-9][^/ ]*-${platform}\\.tar\\.gz\$")"
  [ -n "$server_name" ] && [ "$(printf '%s\n' "$server_name" | wc -l)" -eq 1 ] \
    || fail "$BASE_URL/SHA256SUMS lists no single server archive for $platform"
  [ -n "$client_name" ] && [ "$(printf '%s\n' "$client_name" | wc -l)" -eq 1 ] \
    || fail "$BASE_URL/SHA256SUMS lists no single client archive for $platform"
  server_sha="$(awk -v n="$server_name" '$2 == n {print $1}' "$work/SHA256SUMS")"
  client_sha="$(awk -v n="$client_name" '$2 == n {print $1}' "$work/SHA256SUMS")"
  server_file="$work/$server_name"
  client_file="$work/$client_name"
  source_label="$BASE_URL:$server_name,$client_name"
fi

# The two archives must be one release: loomd-<version>-<platform> and
# loom-<version>-<platform> share a version. Names that do not follow the
# pattern (a renamed local archive) cannot be checked and are not.
case "$server_name" in loomd-*-"$platform".tar.gz)
  case "$client_name" in loom-*-"$platform".tar.gz)
    server_version="${server_name#loomd-}"; server_version="${server_version%-"$platform".tar.gz}"
    client_version="${client_name#loom-}"; client_version="${client_version%-"$platform".tar.gz}"
    [ "$server_version" = "$client_version" ] \
      || fail "the server archive is version $server_version but the client archive is $client_version"
    ;;
  esac
  ;;
esac

# Already installed at exactly these digests: nothing to do. The marker holds
# the digests, so a different release replaces the tree and the same one does not.
want="$platform $server_sha $client_sha"
if [ -f "$PREFIX/.installed" ] && [ "$(cat "$PREFIX/.installed")" = "$want" ] \
   && [ -x "$PREFIX/server/bin/loomd" ] && [ -x "$PREFIX/client/bin/loom" ]; then
  echo "loom-harbor install: already installed at $PREFIX ($source_label)" >&2
  exit 0
fi

if [ -z "$SERVER_TARBALL" ]; then
  fetch "$BASE_URL/$server_name" "$server_file"
  fetch "$BASE_URL/$client_name" "$client_file"
fi

verify() {
  actual="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$actual" = "$2" ] || fail "digest mismatch for $(basename "$1"): expected $2, got $actual"
}
verify "$server_file" "$server_sha"
verify "$client_file" "$client_sha"

stage="$work/stage"
mkdir -p "$stage/server" "$stage/client"
# This runs as root on an archive from the network: do not take ownership or
# modes from it (GNU tar; busybox tar spells the first as -o and has no second).
tar_safe=""
if tar --version 2>/dev/null | grep -q GNU; then
  tar_safe="--no-same-owner --no-same-permissions"
else
  tar_safe="-o"  # busybox: do not restore the archive's ownership
fi
# shellcheck disable=SC2086
tar -xzf "$server_file" -C "$stage/server" --strip-components=1 $tar_safe \
  || fail "could not unpack the server archive"
# shellcheck disable=SC2086
tar -xzf "$client_file" -C "$stage/client" --strip-components=1 $tar_safe \
  || fail "could not unpack the client archive"
for required in server/bin/loomd server/bin/loom-exec client/bin/loom; do
  [ -x "$stage/$required" ] || fail "the release has no executable $required"
done

# Both trees move together, after both unpacked, so a failure above leaves
# any earlier installation intact.
rm -rf "$PREFIX/server" "$PREFIX/client"
mv "$stage/server" "$PREFIX/server"
mv "$stage/client" "$PREFIX/client"
chmod -R a+rX "$PREFIX"
printf '%s\n' "$want" > "$PREFIX/.installed"

# The release is self-contained, so this fails only when the container cannot
# run it at all (a musl libc, a missing 64-bit loader), which is worth saying now.
if ! version="$(timeout 120 "$PREFIX/client/bin/loom" version 2>&1)"; then
  fail "the installed client does not run in this container: $version"
fi
echo "loom-harbor install: installed $source_label" >&2
echo "$version" >&2
"""

# Shared by the run and collect scripts. Everything the daemon and `loom run`
# write that the adapter later wants lives under $OUT, inside the private state
# directory, and not under /logs/agent: the daemon's state is where a session
# keeps its history, and /logs/agent is what Harbor uploads. The adapter fetches
# files from here itself and scrubs the API key from them first.
#
# A process id is only a name for a process while the process is the same one.
# The pidfile therefore carries the process's start time (field 22 of
# /proc/<pid>/stat), and a stop signals nothing whose start time differs.
_HELPERS = r"""
start_time() { awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null; }
# A zombie still answers kill -0 and still has a start time, but it has stopped.
proc_state() { awk '{ sub(/^.*\) /, ""); print $1 }' "/proc/$1/stat" 2>/dev/null; }
running() { [ "$(start_time "$1")" = "$2" ] && [ "$(proc_state "$1")" != Z ]; }

stop_daemon() {
  [ -f "$OUT/loomd.pid" ] || return 0
  read -r pid started < "$OUT/loomd.pid" || true
  if [ -n "${pid:-}" ] && running "$pid" "${started:-x}"; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      running "$pid" "$started" || break
      sleep 0.5
    done
    if running "$pid" "$started"; then
      kill -KILL "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        running "$pid" "$started" || break
        sleep 0.25
      done
    fi
  fi
  rm -f "$OUT/loomd.pid"
}

wipe_key_file() {
  [ -n "${LOOM_KEY_FILE:-}" ] || return 0
  # The file belongs to the agent user but sits in a root-owned directory, so
  # it can be emptied even where it cannot be unlinked.
  : > "$LOOM_KEY_FILE" 2>/dev/null || true
  rm -f "$LOOM_KEY_FILE" 2>/dev/null || true
}
"""

RUN_SCRIPT = (
    r"""
set -uo pipefail

fail() { echo "loom-harbor run: $1" >&2; exit "${2:-40}"; }

PREFIX="${LOOM_PREFIX:?LOOM_PREFIX is required}"
STATE="${LOOM_STATE_DIR:-${HOME:?HOME must be set for the agent user}/.loom-harbor}"
OUT="$STATE/harbor-out"
CONFIG="${LOOM_CONFIG:?LOOM_CONFIG is required}"
PROMPT_FILE="${LOOM_PROMPT_FILE:?LOOM_PROMPT_FILE is required}"
TIMEOUT="${LOOM_RUN_TIMEOUT_SEC:?LOOM_RUN_TIMEOUT_SEC is required}"
JAIL_FLAG="${LOOM_JAIL_FLAG:-}"
KEY_NAME="${LOOM_KEY_NAME:?LOOM_KEY_NAME is required}"
# Whatever put the key in this script's environment (Harbor adds an agent's
# extra_env to every exec), it must not reach `loom run` or anything but loomd,
# which is given it explicitly below.
unset "$KEY_NAME"
"""
    + _HELPERS
    + r"""
: "${HOME:?HOME must be set for the agent user; the Loom launcher refuses to start without it}"
LOOMD="$PREFIX/server/bin/loomd"
LOOM="$PREFIX/client/bin/loom"
[ -x "$LOOMD" ] || fail "$LOOMD is missing; the install step did not run" 40
[ -x "$LOOM" ] || fail "$LOOM is missing; the install step did not run" 40
[ -r "$CONFIG" ] || fail "cannot read the catalogue $CONFIG" 40
[ -r "$PROMPT_FILE" ] || fail "cannot read the instruction $PROMPT_FILE" 40

# The API key arrives as a file, not in this script's environment or on any
# command line (Harbor passes exec environment as `-e KEY=VALUE` arguments, which
# any process on the host can read). It is held in a shell variable that is
# never exported, handed to the daemon alone, and the file is emptied at once.
KEYVAL=""
if [ -n "${LOOM_KEY_FILE:-}" ] && [ -s "$LOOM_KEY_FILE" ]; then
  KEYVAL="$(cat "$LOOM_KEY_FILE")"
fi
wipe_key_file
[ -n "$KEYVAL" ] || fail "no API key was provided in $KEY_NAME" 40

mkdir -p "$STATE" "$OUT" || fail "cannot create $STATE" 40
chmod 700 "$STATE" 2>/dev/null || true
rm -f "$OUT/loomd.pid" "$OUT/loom-run.json" "$OUT/loom-run.stderr.txt" "$OUT/loom-run.exit"
WORKSPACE="$(pwd -P)"

# The daemon starts from its own state directory, never from the workspace, with
# the key as the only credential it is given. It is not given the instruction
# file's name or the key's file. $JAIL_FLAG is deliberately unquoted so an empty
# value contributes no argument.
#
# A readiness check on the file alone would pass on a record left by an earlier
# daemon, and `loom run` would then start a daemon of its own without the
# posture flag. The record names the process that wrote it
# (host/endpoint.encode writes "pid"), so only this launch's pid counts.
(
  cd "$STATE" && export "$KEY_NAME=$KEYVAL" && exec env -u LOOM_PROMPT_FILE -u LOOM_KEY_FILE -u LOOM_KEY_NAME     "$LOOMD" --state-dir "$STATE" --config "$CONFIG" $JAIL_FLAG
) >"$OUT/loomd.log" 2>&1 </dev/null &
DAEMON_PID=$!
KEYVAL=""
echo "$DAEMON_PID $(start_time "$DAEMON_PID")" > "$OUT/loomd.pid"

ready() {
  [ -f "$STATE/daemon.endpoint" ] \
    && grep -Eq '"status" *: *"ready"' "$STATE/daemon.endpoint" 2>/dev/null \
    && grep -Eq "\"pid\" *: *$DAEMON_PID[^0-9]" "$STATE/daemon.endpoint" 2>/dev/null
}
waited=0
until ready; do
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    fail "loomd exited before it was ready (log: $OUT/loomd.log)" 41
  fi
  waited=$((waited + 1))
  if [ "$waited" -gt 240 ]; then
    stop_daemon
    fail "loomd was not ready after 120 seconds (log: $OUT/loomd.log)" 41
  fi
  sleep 0.5
done

# `loom run` reuses the daemon that owns this state directory, so the posture
# flag given to loomd above is the one the session runs under. Loom enforces
# --timeout itself; the outer `timeout -k` is the backstop that keeps a wedged
# client from outliving the exec Harbor is waiting on.
RUNNER=""
if command -v timeout >/dev/null 2>&1; then RUNNER="timeout -k 30 $((TIMEOUT + 90))"; fi
# shellcheck disable=SC2086
$RUNNER "$LOOM" run --server "$LOOMD" --state-dir "$STATE" --config "$CONFIG"   --workspace "$WORKSPACE" --timeout "$TIMEOUT" -p "$(cat "$PROMPT_FILE")"   >"$OUT/loom-run.json" 2>"$OUT/loom-run.stderr.txt" </dev/null
RC=$?
printf '%s\n' "$RC" > "$OUT/loom-run.exit"

stop_daemon

case "$RC" in
  0|1|124)
    if [ -s "$OUT/loom-run.json" ]; then
      cat "$OUT/loom-run.json"
      exit 0
    fi
    fail "loom run exited $RC but printed no report" 43
    ;;
  *)
    echo "loom-harbor run: loom run exited $RC (2 bad arguments, 3 no daemon)" >&2
    exit "$RC"
    ;;
esac
"""
)

# The second pass, run after the first whether it finished or Harbor cut it off.
# Order matters: the daemon is stopped first, with a KILL fallback, because a
# SQLite file copied while its writer lives can be torn. Only then does it list
# what the adapter should fetch, one `LOOM_FILE <path>` line each on stdout.
COLLECT_SCRIPT = (
    r"""
set -uo pipefail
STATE="${LOOM_STATE_DIR:-${HOME:-/root}/.loom-harbor}"
OUT="$STATE/harbor-out"
"""
    + _HELPERS
    + r"""
wipe_key_file
stop_daemon
for f in "$OUT"/loom-run.json "$OUT"/loom-run.stderr.txt "$OUT"/loom-run.exit "$OUT"/loomd.log \
         "$STATE"/daemon.log "$STATE"/sessions/*.db "$STATE"/sessions/*.db-wal; do
  [ -f "$f" ] && printf 'LOOM_FILE %s\n' "$f"
done
exit 0
"""
)

# Whether bubblewrap, the namespace layer of Loom's jail, can work for this user
# in this container. The helper decides "degraded" by whether `bwrap` is on its
# PATH, not by whether it works, so a bwrap that exists but is refused a user
# namespace (Docker's default) does not degrade the jail, it breaks every tool
# call. Prints the state (absent, usable or unusable) and then the path the
# probe resolved, so that a later step acts on that file and not on whatever a
# different user's PATH would find. The probe asks for the namespaces the
# helper's own argv asks for.
BWRAP_PROBE = r"""
if ! path="$(command -v bwrap 2>/dev/null)"; then echo absent; echo; exit 0; fi
if bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user --unshare-pid \
     --unshare-net true >/dev/null 2>&1; then
  echo usable
else
  echo unusable
fi
echo "$path"
"""

# Moves an unusable bwrap out of the helper's reach, so that it reports itself
# degraded (honestly: no namespace layer) and runs the in-process layers
# instead of failing every call. Runs as root on the probed path; the adapter
# restores it before the verifier runs.
BWRAP_DISABLE = r"""
set -eu
path="${LOOM_BWRAP_PATH:?LOOM_BWRAP_PATH is required}"
case "$path" in /*/bwrap) ;; *) echo "loom-harbor: refusing to move $path" >&2; exit 1 ;; esac
[ -f "$path" ] || { echo "loom-harbor: $path is not a file" >&2; exit 1; }
mv "$path" "$path.disabled-by-loom-harbor"
echo "loom-harbor: moved the unusable $path aside" >&2
"""

BWRAP_RESTORE = r"""
set -eu
path="${LOOM_BWRAP_PATH:?LOOM_BWRAP_PATH is required}"
case "$path" in /*/bwrap) ;; *) echo "loom-harbor: refusing to restore $path" >&2; exit 1 ;; esac
if [ -e "$path.disabled-by-loom-harbor" ] && [ ! -e "$path" ]; then
  mv "$path.disabled-by-loom-harbor" "$path"
  echo "loom-harbor: restored $path" >&2
fi
"""


def bash_command(script: str) -> str:
    """Wrap a script so Harbor's `set -o pipefail; <command>` runs it as bash.

    Harbor prefixes every command with `set -o pipefail;`, which a plain
    POSIX shell would reject, and a multi-line script must reach bash as one
    argument. Quoting the whole text is therefore the only transformation
    applied to a script.
    """
    return f"bash -c {shlex.quote(script)}"

#!/usr/bin/env bash
# Verify that the shipped launchers describe themselves without starting a
# terminal or daemon, and keep their two standard output channels separate.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/loom-cli-help.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

run_help() {
  local binary="$1"
  local expected="$2"
  shift
  shift
  local stdout="$scratch/$binary.stdout"
  local stderr="$scratch/$binary.stderr"
  local task_home="$scratch/$binary.home"

  if ! HOME="$task_home" "$root/bin/$binary" "$@" >"$stdout" 2>"$stderr"; then
    echo "cli_help_test: $binary $* exited nonzero" >&2
    cat "$stderr" >&2
    exit 1
  fi
  if [ ! -s "$stdout" ]; then
    echo "cli_help_test: $binary $* wrote no stdout" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" "$stdout"; then
    echo "cli_help_test: $binary $* omitted $expected" >&2
    cat "$stdout" >&2
    exit 1
  fi
  if [ -s "$stderr" ]; then
    echo "cli_help_test: $binary $* wrote stderr" >&2
    cat "$stderr" >&2
    exit 1
  fi
  if LC_ALL=C grep -q $'\033' "$stdout"; then
    echo "cli_help_test: $binary $* wrote a terminal escape sequence" >&2
    exit 1
  fi
  if [ -e "$task_home/.loom" ]; then
    echo "cli_help_test: $binary $* created daemon state" >&2
    exit 1
  fi
}

run_failure() {
  local binary="$1"
  shift
  local stdout="$scratch/$binary.failure.stdout"
  local stderr="$scratch/$binary.failure.stderr"
  local task_home="$scratch/$binary.failure.home"

  if HOME="$task_home" "$root/bin/$binary" "$@" >"$stdout" 2>"$stderr"; then
    echo "cli_help_test: $binary $* unexpectedly succeeded" >&2
    exit 1
  fi
  if [ -s "$stdout" ]; then
    echo "cli_help_test: $binary $* wrote stdout" >&2
    cat "$stdout" >&2
    exit 1
  fi
  if [ ! -s "$stderr" ]; then
    echo "cli_help_test: $binary $* wrote no stderr" >&2
    exit 1
  fi
  if LC_ALL=C grep -q $'\033' "$stderr"; then
    echo "cli_help_test: $binary $* wrote a terminal escape sequence" >&2
    exit 1
  fi
  if [ -e "$task_home/.loom" ]; then
    echo "cli_help_test: $binary $* created daemon state" >&2
    exit 1
  fi
}

for binary in loom loomd; do
  run_help "$binary" "usage: $binary" --help
  run_help "$binary" "usage: $binary" -h
  run_help "$binary" "usage: $binary" help
done

for flag in \
  --state-dir --bind --capacity --owner-name --read-scope --network --helper \
  --config --codemode-seed --codemode-seams --best-effort --full-enforcement
do
  if ! grep -Fq -- "$flag" "$scratch/loomd.stdout"; then
    echo "cli_help_test: loomd help does not list $flag" >&2
    exit 1
  fi
done

# Version reporting must remain usable with no terminal, server or state home.
run_help loom "usage: loom version" version --help
run_help loom "usage: loom version" help version
LOOM_SERVER="$scratch/no-loomd" run_help loom "commit $(git -C "$root" rev-parse HEAD)" version
cp "$scratch/loom.stdout" "$scratch/loom-version.stdout"
run_help loom "platform $("$root/scripts/platform.sh")" --version
cmp "$scratch/loom-version.stdout" "$scratch/loom.stdout"
run_failure loom version --profile
run_failure loom --version --profile
run_failure loom version --record "$scratch/version-recording.jsonl"
[ ! -e "$scratch/version-recording.jsonl" ]

# The launcher's own flags, which are not the daemon's. `--tools` in
# particular chooses one session's tool roster and never reaches a daemon's
# argument list, so it must be documented by `loom` and by nothing else.
for flag in --workspace --session --server --state-dir --config --tools
do
  if ! grep -Fq -- "$flag" "$scratch/loom.stdout"; then
    echo "cli_help_test: loom help does not list $flag" >&2
    exit 1
  fi
done
if grep -Fq -- "--tools" "$scratch/loomd.stdout"; then
  echo "cli_help_test: loomd help lists the per-session --tools flag" >&2
  exit 1
fi

run_help loom "usage: loom replay" replay --help
run_help loom "usage: loom replay" replay -h
run_help loom "usage: loom replay" help replay
run_help loom "usage: loom sessions" sessions --help
run_help loom "usage: loom sessions" sessions -h
run_help loom "usage: loom sessions" help sessions
run_help loom "usage: loom ext" ext --help
cp "$scratch/loom.stdout" "$scratch/loom-ext.stdout"
LOOM_SERVER="$scratch/no-loomd" run_help loom "usage: loom ext" ext --help
cmp "$scratch/loom-ext.stdout" "$scratch/loom.stdout"
run_help loom "usage: loom ext" ext -h
run_help loom "usage: loom ext" help ext
run_help loomd "usage: loomd access" access --help
run_help loomd "usage: loomd access" access -h
run_help loomd "usage: loomd access" help access
run_help loomd "usage: loom ext" ext --help
cmp "$scratch/loom-ext.stdout" "$scratch/loomd.stdout"
run_help loomd "usage: loom ext" ext -h
run_help loomd "usage: loom ext" help ext
# The `--help` and `-h` flags win wherever they appear in argv: flags
# before them describe the launch rather than failing as unknown options,
# and no recording, state directory, or replay output is created on the
# way out.
run_help loom "usage: loom replay" replay some-recording.jsonl --help
run_help loom "usage: loom sessions" sessions rm some-session --help
run_help loom "usage: loom" --demo --help
run_help loom "usage: loom" --record "$scratch/rec.jsonl" --help
[ ! -e "$scratch/rec.jsonl" ] || {
  echo "cli_help_test: loom --record ... --help created a recording" >&2
  exit 1
}
run_help loomd "usage: loomd" --state-dir "$scratch/statedir" --help
run_help loomd "usage: loomd access" --capacity 8 access --help

# The bare word `help` is a plausible value, not a flag: it must reach
# the subcommand untouched. `loom ext` is a pipe to the server, so with
# no server installed the words arrive at the launcher error rather than
# being answered locally; a recording named `help` reaches the replay
# loader, which reports the missing file.
out="$scratch/passthrough.stdout"
err="$scratch/passthrough.stderr"
if LOOM_SERVER="$scratch/no-loomd" "$root/bin/loom" ext verify help >"$out" 2>"$err"; then
  echo "cli_help_test: loom ext verify help unexpectedly succeeded" >&2
  exit 1
fi
if grep -Fq "usage: loom ext" "$out" "$err"; then
  echo "cli_help_test: loom ext verify help was answered as help" >&2
  exit 1
fi
grep -Fq "loom ext:" "$err" || {
  echo "cli_help_test: loom ext verify help did not reach the launcher error" >&2
  cat "$err" >&2
  exit 1
}
if "$root/bin/loom" replay help >"$out" 2>"$err"; then
  echo "cli_help_test: loom replay help unexpectedly succeeded" >&2
  exit 1
fi
if grep -Fq "usage: loom replay" "$out" "$err"; then
  echo "cli_help_test: loom replay help was answered as help" >&2
  exit 1
fi

run_failure loom --workspace

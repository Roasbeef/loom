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
run_failure loom --workspace

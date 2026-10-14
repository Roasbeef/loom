#!/usr/bin/env bash
# Run against an already-built broker and helper; never rebuild shared artifacts.
set -euo pipefail
root="${1:?usage: helper_idle_perf.sh ROOT BASELINE_EXEC_BEAM [ROUND] [production|accelerated]}"
baseline="${2:?baseline broker@exec.beam required}"
round="${3:-1}"
mode="${4:-accelerated}"
case "$mode" in production|accelerated) ;; *) exit 2 ;; esac
out="$(mktemp -d "${TMPDIR:-/tmp}/loom-helper-idle-perf.XXXXXX")"
trap 'rm -rf "$out"' EXIT
erlc -Werror -o "$out" "$root/scripts/helper_idle_perf.erl"
paths=()
for path in "$root"/packages/broker/build/dev/erlang/*/ebin; do paths+=("$path"); done
ERL_CRASH_DUMP="$out/erl_crash.dump" erl +S 1:1 -noshell -pa "$out" "${paths[@]}" -s helper_idle_perf main -extra "$root" "$baseline" "$round" "$mode"

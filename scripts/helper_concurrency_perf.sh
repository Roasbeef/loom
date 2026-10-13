#!/usr/bin/env bash
# Compare whole already-built roots in fresh VMs; never mix wire versions.
set -euo pipefail
runner_root="${1:?usage: helper_concurrency_perf.sh RUNNER_ROOT BASELINE_ROOT CANDIDATE_ROOT [ROUND]}"
baseline_root="${2:?baseline root required}"
candidate_root="${3:?candidate root required}"
round="${4:-1}"
out="$(mktemp -d "${TMPDIR:-/tmp}/loom-helper-concurrency-perf.XXXXXX")"
trap 'rm -rf "$out"' EXIT
erlc -Werror -o "$out" "$runner_root/scripts/helper_concurrency_perf.erl"
versions=(baseline candidate)
if (( round % 2 == 0 )); then versions=(candidate baseline); fi
for version in "${versions[@]}"; do
  root="$baseline_root"
  if [[ "$version" == candidate ]]; then root="$candidate_root"; fi
  paths=()
  for path in "$root"/packages/broker/build/dev/erlang/*/ebin; do paths+=("$path"); done
  ERL_CRASH_DUMP="$out/erl_crash.dump" erl +S 1:1 -noshell -pa "$out" "${paths[@]}" \
    -s helper_concurrency_perf main -extra "$root" "$version" "$round"
done

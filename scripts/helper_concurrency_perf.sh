#!/usr/bin/env bash
# Compare whole already-built roots in fresh VMs; never mix wire versions.
set -euo pipefail
runner_root="${1:?usage: helper_concurrency_perf.sh RUNNER_ROOT BASELINE_ROOT CANDIDATE_ROOT [ROUND] [PREOPTIMIZATION_ROOT] [all|baseline|preoptimization|candidate]}"
baseline_root="${2:?baseline root required}"
candidate_root="${3:?candidate root required}"
round="${4:-1}"
preoptimization_root="${5:-}"
selection="${6:-all}"
out="$(mktemp -d "${TMPDIR:-/tmp}/loom-helper-concurrency-perf.XXXXXX")"
trap 'rm -rf "$out"' EXIT
erlc -Werror -o "$out" "$runner_root/scripts/helper_concurrency_perf.erl"
versions=(baseline candidate)
if [[ -n "$preoptimization_root" ]]; then
  case "$(( (round - 1) % 3 ))" in
    0) versions=(baseline preoptimization candidate) ;;
    1) versions=(preoptimization candidate baseline) ;;
    2) versions=(candidate baseline preoptimization) ;;
  esac
elif (( round % 2 == 0 )); then
  versions=(candidate baseline)
fi
case "$selection" in
  all) ;;
  baseline|candidate) versions=("$selection") ;;
  preoptimization) test -n "$preoptimization_root"; versions=("$selection") ;;
  *) exit 2 ;;
esac
for version in "${versions[@]}"; do
  root="$baseline_root"
  if [[ "$version" == candidate ]]; then root="$candidate_root"; fi
  if [[ "$version" == preoptimization ]]; then root="$preoptimization_root"; fi
  printf "HOST version=%s round=%s platform=%s\n" "$version" "$round" "$(uname -sm)"
  uptime
  go version
  go version "$root/packages/sandbox/loom-exec"
  shasum -a 256 "$root/packages/sandbox/loom-exec" \
    "$root/packages/broker/build/dev/erlang/broker/ebin/broker@exec.beam"
  paths=()
  for path in "$root"/packages/broker/build/dev/erlang/*/ebin; do paths+=("$path"); done
  ERL_CRASH_DUMP="$out/erl_crash.dump" erl +S 1:1 -noshell -pa "$out" "${paths[@]}" \
    -s helper_concurrency_perf main -extra "$root" "$version" "$round"
done

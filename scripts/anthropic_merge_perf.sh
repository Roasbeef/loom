#!/usr/bin/env bash
# Build provider tests first; compare with the unchanged saved adapter BEAM.
set -euo pipefail
checkout="$(cd "${1:?built checkout required}" && pwd)"
baseline="${2:?baseline provider@adapter@anthropic.beam required}"
provider="$checkout/packages/provider"
out="$provider/build/anthropic_merge_perf/ebin"
mkdir -p "$out"
erlc -o "$out" "$checkout/scripts/anthropic_merge_perf.erl"
paths=()
for dir in "$provider"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
cd "$provider"
ANTHROPIC_MERGE_BASELINE="$baseline" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'anthropic_merge_perf:main([os:getenv("ANTHROPIC_MERGE_BASELINE")]).'

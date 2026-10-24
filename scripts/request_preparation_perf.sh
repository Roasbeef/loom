#!/usr/bin/env bash
# Build harness tests first; save the two unchanged baseline BEAMs before edits.
set -euo pipefail
checkout="$(cd "${1:?built checkout required}" && pwd)"
baseline="$(cd "${2:?baseline BEAM directory required}" && pwd)"
harness="$checkout/packages/harness"
out="$harness/build/request_preparation_perf/ebin"
mkdir -p "$out"
erlc -o "$out" "$checkout/scripts/request_preparation_perf.erl"
paths=()
for dir in "$harness"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
cd "$harness"
REQUEST_PREPARATION_BASELINE="$baseline" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'request_preparation_perf:main([os:getenv("REQUEST_PREPARATION_BASELINE")]).'

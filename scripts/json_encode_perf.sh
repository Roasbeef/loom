#!/usr/bin/env bash
# Build core before saving its baseline BEAM, then build the candidate.
# The saved BEAM and candidate must use the same OTP, Gleam and dependencies.
set -euo pipefail
checkout="$(cd "${1:?a built checkout is required}" && pwd)"
baseline="${2:?the baseline core@json.beam path is required}"
core="$checkout/packages/core"
here="$(cd "$(dirname "$0")" && pwd)"
out="$core/build/json_encode_perf/ebin"
mkdir -p "$out"
erlc -o "$out" "$here/json_encode_perf.erl"
paths=()
for dir in "$core"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
JSON_ENCODE_BASELINE="$baseline" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'json_encode_perf:main([os:getenv("JSON_ENCODE_BASELINE")]).'

#!/usr/bin/env bash
# Measure JSON encode/decode work in an isolated one-scheduler fixture VM.
# Usage: bash scripts/json_perf.sh <built-checkout> <label>
# Build packages/core with the same compiler in each checkout first.
set -euo pipefail
checkout="$(cd "${1:?a built checkout is required}" && pwd)"
label="${2:?a comparison label is required}"
core="$checkout/packages/core"
here="$(cd "$(dirname "$0")" && pwd)"
out="$core/build/json_perf/ebin"
mkdir -p "$out"
erlc -o "$out" "$here/json_perf.erl"
paths=()
for dir in "$core"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
JSON_PERF_LABEL="$label" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'json_perf:main([os:getenv("JSON_PERF_LABEL")]).'

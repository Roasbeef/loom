#!/usr/bin/env bash
# Decode fixed synthetic inputs in a fresh single-scheduler VM.
# Build core first; baseline/candidate artifacts must use the same toolchain.
set -euo pipefail
checkout="$(cd "${1:?a built checkout is required}" && pwd)"
label="${2:?a comparison label is required}"
core="$checkout/packages/core"
here="$(cd "$(dirname "$0")" && pwd)"
out="$core/build/json_decode_perf/ebin"
mkdir -p "$out"
erlc -o "$out" "$here/json_decode_perf.erl"
paths=()
for dir in "$core"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
JSON_DECODE_PERF_MODE="${3:-benchmark}" JSON_DECODE_PERF_LABEL="$label" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'json_decode_perf:main([os:getenv("JSON_DECODE_PERF_LABEL"), os:getenv("JSON_DECODE_PERF_MODE")]).'

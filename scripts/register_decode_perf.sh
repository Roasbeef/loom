#!/usr/bin/env bash
# Build storage first; compare its candidate with an exact saved baseline BEAM.
set -euo pipefail
checkout="$(cd "${1:?built checkout required}" && pwd)"
baseline="${2:?baseline storage@sqlite.beam required}"
storage="$checkout/packages/storage"
out="$storage/build/register_decode_perf/ebin"
mkdir -p "$out"
erlc -o "$out" "$checkout/scripts/register_decode_perf.erl"
paths=()
for dir in "$storage"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
cd "$storage"
REGISTER_DECODE_BASELINE="$baseline" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'register_decode_perf:main([os:getenv("REGISTER_DECODE_BASELINE")]).'

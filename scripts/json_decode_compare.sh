#!/usr/bin/env bash
# Compare a built parser with a saved baseline BEAM in one disposable VM.
# Both artifacts must use the same compiler, OTP and dependency versions.
set -euo pipefail
checkout="$(cd "${1:?a built checkout is required}" && pwd)"
baseline="${2:?the baseline core@json.beam path is required}"
expect="no"
if [[ "${3:-}" == --expect-improved ]]; then
  expect="yes"
elif [[ -n "${3:-}" ]]; then
  echo "json_decode_compare: unknown option $3" >&2
  exit 2
fi
core="$checkout/packages/core"
here="$(cd "$(dirname "$0")" && pwd)"
out="$core/build/json_decode_perf/ebin"
mkdir -p "$out"
erlc -o "$out" "$here/json_decode_perf.erl"
paths=()
for dir in "$core"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
JSON_DECODE_BASELINE="$baseline" JSON_DECODE_EXPECT_IMPROVED="$expect" exec erl -noshell \
  +S 1:1 +SDcpu 1 +SDio 1 "${paths[@]}" -pa "$out" \
  -eval 'json_decode_perf:main([os:getenv("JSON_DECODE_BASELINE"), "compare"]).'

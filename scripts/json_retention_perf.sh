#!/usr/bin/env bash
# Measure backing binaries in disposable synthetic owners after full GC.
set -euo pipefail
checkout="$(cd "${1:?a built checkout is required}" && pwd)"
label="${2:?a comparison label is required}"
core="$checkout/packages/core"
here="$(cd "$(dirname "$0")" && pwd)"
out="$core/build/json_retention_perf/ebin"
mkdir -p "$out"
provider="${3:-$checkout/packages/provider}"
erlc -I "$provider/build/dev/erlang/provider/include" -o "$out" "$here/json_retention_perf.erl"
paths=()
for dir in "$provider"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
for dir in "$core"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
JSON_RETENTION_LABEL="$label" JSON_RETENTION_EXPECTATION="${4:-observe}" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'json_retention_perf:main([os:getenv("JSON_RETENTION_LABEL"), os:getenv("JSON_RETENTION_EXPECTATION")]).'

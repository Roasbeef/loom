#!/usr/bin/env bash
# Measure repeated operator-page renders with the real Lustre diff cache.
# Usage: bash scripts/web_view_perf.sh <built-checkout> <label>
# Build packages/web_view with gleam build first, including its test fixtures.
# Compare checkouts built with the same compiler, alternating before and after.
set -euo pipefail

checkout="$(cd "${1:?a built checkout is required}" && pwd)"
label="${2:?a comparison label is required}"
web="$checkout/packages/web_view"
here="$(cd "$(dirname "$0")" && pwd)"
out="$web/build/web_view_perf/ebin"
mkdir -p "$out"
erlc -o "$out" "$here/web_view_perf.erl"

paths=()
for dir in "$web"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
WEB_VIEW_PERF_LABEL="$label" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'web_view_perf:main([os:getenv("WEB_VIEW_PERF_LABEL")]).'

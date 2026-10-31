#!/usr/bin/env bash
# Compare current storage code with saved baseline BEAMs in one disposable VM.
set -euo pipefail
checkout="$(cd "${1:?usage: catalogue_perf.sh CHECKOUT BASELINE_DIR | CHECKOUT --save-baseline DIR}" && pwd)"
shift
storage="$checkout/packages/storage"
beam="$storage/build/dev/erlang/storage/ebin"
if [[ "${1:-}" == --save-baseline ]]; then
  baseline="${2:?baseline output directory required}"
  git -C "$checkout" diff --quiet HEAD -- packages/storage/src || {
    echo "catalogue_perf: baseline storage source differs from HEAD" >&2
    exit 2
  }
  mkdir -p "$baseline"
  for module in storage@catalogue storage@domain storage@sql; do
    cp "$beam/$module.beam" "$baseline/$module.beam"
  done
  git -C "$checkout" rev-parse HEAD > "$baseline/revision"
  shasum -a 256 "$baseline"/*.beam > "$baseline/SHA256SUMS"
  exit 0
fi
baseline="$(cd "${1:?saved baseline directory required}" && pwd)"
expect="no"
if [[ "${2:-}" == --expect-improved ]]; then
  expect="yes"
elif [[ -n "${2:-}" ]]; then
  echo "catalogue_perf: unknown option $2" >&2
  exit 2
fi
out="$storage/build/catalogue_perf/ebin"
mkdir -p "$out"
erlc -o "$out" "$checkout/scripts/catalogue_perf.erl"
paths=()
for dir in "$storage"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
cd "$storage"
CATALOGUE_PERF_BASELINE="$baseline" CATALOGUE_PERF_EXPECT_IMPROVED="$expect" exec erl -noshell +S 1:1 +SDcpu 1 +SDio 1 \
  "${paths[@]}" -pa "$out" \
  -eval 'catalogue_perf:main([os:getenv("CATALOGUE_PERF_BASELINE")]).'

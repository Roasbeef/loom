#!/usr/bin/env bash
# Build runtime first, then replay polling against an exact saved codec BEAM.
set -euo pipefail
checkout="$(cd "${1:?built checkout required}" && pwd)"
baseline="$(cd "${2:?baseline BEAM directory required}" && pwd)"
check="${3:-report}"
case "$check" in report|--expect-improved) ;; *) echo "expected report or --expect-improved" >&2; exit 2;; esac
package="$checkout/packages/runtime"
out="$package/build/strand_poll_replay/ebin"
mkdir -p "$out"
run_dir="$(mktemp -d "$package/build/strand_poll_replay/run.XXXXXX")"
includes=()
paths=()
for dir in "$package"/build/dev/erlang/*; do
  includes+=(-I "$dir/include")
  paths+=(-pa "$dir/ebin")
done
erlc "${includes[@]}" -o "$out" "$checkout/scripts/strand_poll_replay.erl"
cd "$package"
STRAND_POLL_BASELINE="$baseline" STRAND_POLL_RUN_DIR="$run_dir" STRAND_POLL_CHECK="$check" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'strand_poll_replay:main([os:getenv("STRAND_POLL_BASELINE"),os:getenv("STRAND_POLL_CHECK")]).'

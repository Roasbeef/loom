#!/usr/bin/env bash
# Compare a saved runtime BEAM with the current compiled runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
export THRESHOLD_BASELINE="$(cd "$(dirname "${1:?baseline BEAM required}")" && pwd)/$(basename "$1")"
export THRESHOLD_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$THRESHOLD_FIXTURE"' EXIT
includes=()
paths=()
for dir in packages/runtime/build/dev/erlang/*; do
  includes+=(-I "$dir/include")
  paths+=(-pa "$dir/ebin")
done
erlc "${includes[@]}" -o "$THRESHOLD_FIXTURE" scripts/checkpoint_threshold_replay.erl
erl -noshell +S 1:1 +SDcpu 1 +SDio 1 "${paths[@]}" -pa "$THRESHOLD_FIXTURE" \
  -eval 'checkpoint_threshold_replay:main().'

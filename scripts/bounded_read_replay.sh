#!/usr/bin/env bash
# Run against saved baseline BEAMs and a built candidate in a disposable VM.
set -euo pipefail
cd "$(dirname "$0")/.."
export REPLAY_BASELINE="$(cd "${1:?baseline BEAM directory required}" && pwd)"
export REPLAY_FIXTURES="$(mktemp -d)"
trap 'rm -rf "$REPLAY_FIXTURES"' EXIT
erlc -o "$REPLAY_FIXTURES" scripts/bounded_read_replay.erl
paths=()
for dir in packages/client/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
erl -noshell +S 1:1 +SDcpu 1 +SDio 1 "${paths[@]}" -pa "$REPLAY_FIXTURES" \
  -eval 'bounded_read_replay:main().'

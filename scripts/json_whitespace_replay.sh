#!/usr/bin/env bash
# Compare saved and current parser BEAMs in one disposable, non-distributed VM.
set -euo pipefail
checkout="$(cd "${1:?built checkout required}" && pwd)"
baseline="${2:?baseline core@json.beam required}"
check="${3:-report}"
case "$check" in report|--expect-improved) ;; *) exit 2;; esac
core="$checkout/packages/core"
out="$core/build/json_whitespace_replay/ebin"
mkdir -p "$out"
erlc +debug_info -o "$out" "$checkout/scripts/json_decode_perf.erl" "$checkout/scripts/json_whitespace_replay.erl"
paths=()
for dir in "$core"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
JSON_WHITESPACE_BASELINE="$baseline" JSON_WHITESPACE_CHECK="$check" exec erl -noshell \
  +S 1:1 +SDcpu 1 +SDio 1 "${paths[@]}" -pa "$out" \
  -eval 'json_whitespace_replay:main([os:getenv("JSON_WHITESPACE_BASELINE"),os:getenv("JSON_WHITESPACE_CHECK")]).'

#!/usr/bin/env bash
# Build json_codec and storage first. All aliases and mutants stay in this VM.
set -euo pipefail
checkout="$(cd "${1:?built checkout required}" && pwd)"
baseline="$(cd "${2:?saved baseline directory required}" && pwd)"
mode="${3:---expect-improved}"
case "$mode" in --expect-improved|--noop) ;; *) exit 2 ;; esac
cd "$checkout"
out="$checkout/packages/storage/build/platform_json_replay"
mkdir -p "$out"
erlc +debug_info -o "$out" scripts/platform_json_replay.erl scripts/json_decode_perf.erl scripts/json_whitespace_replay.erl
paths=()
for dir in packages/storage/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
fixture_dir="$(mktemp -d "$out/fixtures.XXXXXX")"
trap 'rmdir "$fixture_dir"' EXIT
PLATFORM_JSON_FIXTURE_DIRECTORY="$fixture_dir" PLATFORM_JSON_BASELINE="$baseline" PLATFORM_JSON_MODE="$mode" erl -noshell \
  +S 1:1 +SDcpu 1 +SDio 1 "${paths[@]}" -pa "$out" \
  -eval 'platform_json_replay:main(os:getenv("PLATFORM_JSON_BASELINE"),os:getenv("PLATFORM_JSON_MODE")).'

#!/usr/bin/env bash
# Measure a fixed held summary in a fresh single-scheduler VM.
# Build runtime first; this uses its committed test fixture and synthetic DB.
set -euo pipefail
checkout="$(cd "${1:?a built checkout is required}" && pwd)"
label="${2:?a comparison label is required}"
mode="${3:-cpu}"
case "$mode" in cpu|allocation) ;; *) echo 'mode must be cpu or allocation' >&2; exit 2;; esac
here="$(cd "$(dirname "$0")" && pwd)"
package="$checkout/packages/runtime"
out="$package/build/poll_reload_perf/ebin"
mkdir -p "$out"
erlc -I "$package/build/dev/erlang/runtime/include" -o "$out" "$here/poll_reload_perf.erl"
paths=()
for dir in "$package"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
cd "$package"
POLL_RELOAD_PERF_LABEL="$label" POLL_RELOAD_PERF_MODE="$mode" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'poll_reload_perf:main([os:getenv("POLL_RELOAD_PERF_LABEL"), os:getenv("POLL_RELOAD_PERF_MODE")]).'

#!/usr/bin/env bash
# Measure real SQLite-backed idle gateway pulls in a disposable single-scheduler VM.
# Usage: scripts/gateway_read_perf.sh <built-checkout> <label> [fixture-beam]
# The same test fixture BEAM is used with both production revisions.
set -euo pipefail
checkout="$(cd "${1:?built checkout required}" && pwd)"
label="${2:?comparison label required}"
here="$(cd "$(dirname "$0")" && pwd)"
package="$checkout/packages/client"
fixture="${3:-$here/../packages/client/build/dev/erlang/client/ebin/client@gateway_read_fixture.beam}"
out="$package/build/gateway_read_perf/ebin"
mkdir -p "$out"
cp "$fixture" "$out/client@gateway_read_fixture.beam"
erlc -o "$out" "$here/gateway_read_perf.erl"
paths=()
for dir in "$package"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done
cd "$package"
GATEWAY_READ_PERF_LABEL="$label" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval 'gateway_read_perf:main([os:getenv("GATEWAY_READ_PERF_LABEL")]).'

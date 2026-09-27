#!/usr/bin/env bash
# CPU and memory measurements of the terminal's update loop, for comparing
# two revisions side by side.
#
# Usage: scripts/tui_perf.sh <checkout> <label> <scenario> [args...]
#
# <checkout> is a repository root whose packages/tui has been built with
# `gleam build` (which compiles packages/tui/dev). Scenarios, all described
# in scripts/tui_perf.erl:
#
#   events                 key, idle tick, and tick/key with 64 frames waiting
#   burst <frames>         a burst drained tick by tick, per frame
#   backlog <frames> <0|3> [live]
#                          a mailbox backlog while 0 or 3 jobs run
#   session <frames>       process and model memory after a long reply
#   replay <frames>        a synthesized recording through the virtual terminal
#   profile <tick|key>     words by function for one 64-frame event
#
# Each run is one fresh VM on one scheduler. To compare revisions, add a git
# worktree per revision (not under /tmp), build each, and alternate the runs:
# before, after, before, after. Wall time moves with the machine's load;
# reductions and words do not.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  sed -n '5,18p' "$0"
  exit 2
fi

checkout="$(cd "$1" && pwd)"
shift
tui="$checkout/packages/tui"
here="$(cd "$(dirname "$0")" && pwd)"
out="$tui/build/tui_perf/ebin"
mkdir -p "$out"
erlc -o "$out" "$here/tui_perf.erl"

paths=()
for dir in "$tui"/build/dev/erlang/*/ebin; do paths+=(-pa "$dir"); done

args=""
for arg in "$@"; do args="$args,\"$arg\""; done

TUI_PERF_TUI="$tui" exec erl -noshell +S 1:1 "${paths[@]}" -pa "$out" \
  -eval "tui_perf:main([${args#,}])."

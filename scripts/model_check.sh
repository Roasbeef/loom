#!/usr/bin/env bash
# model_check.sh — compile and check every P protocol model.
#
# Usage: scripts/model_check.sh   (MODEL_SCHEDULES, MODEL_PROBE_SCHEDULES)
#
# Each directory under protocol/models with a .pproj is a P project. Its
# README says how it is run; this script runs the same commands for every
# test case the project declares, so a case added to the model is checked
# without an edit here.
#
# Two kinds of test case, told apart by name. A case named `tcProbe*` is
# a reachability probe: it asserts that a situation never happens, and the
# checker failing it is the evidence that the model reaches the situation.
# A probe that passes means the model has become vacuous there, so this
# script requires every probe to fail and every other case to pass. `p
# check` exits non-zero exactly when it finds a bug, which is what both
# readings rest on.
#
# The schedule counts are smaller than the README's 30,000 because this is
# a gate run on every model change, not the recorded result. The default
# of 1,000 schedules takes about six seconds a case. Every probe in the
# tree finds its witness within 230 schedules, so 2,000 leaves a margin.
#
# The P 3.0 dotnet tool must be on PATH or in ~/.dotnet/tools. The model
# check is not part of `make check` or CI, which do not install it; this
# gate is run by `make check-affected` when a model changes.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
schedules="${MODEL_SCHEDULES:-1000}"
probe_schedules="${MODEL_PROBE_SCHEDULES:-2000}"
PATH="$PATH:$HOME/.dotnet/tools:$HOME/.dotnet"
command -v p >/dev/null || {
	echo "model_check: the P tool is not installed (dotnet tool install --global P)" >&2
	exit 2
}

failed=0
for project in "$root"/protocol/models/*/*.pproj; do
	model="$(dirname "$project")"
	echo "==> $(basename "$model")"
	(cd "$model" && p compile >/dev/null) || {
		echo "   FAIL compile" >&2
		exit 1
	}
	cases="$(sed -n 's/^test \([A-Za-z0-9_]*\).*/\1/p' "$model"/PTst/*.p)"
	for case in $cases; do
		case $case in
		tcProbe*)
			if (cd "$model" && p check -tc "$case" -s "$probe_schedules" >/dev/null 2>&1); then
				echo "   FAIL $case: the probe found no witness, so the model no longer reaches it"
				failed=1
			else
				echo "   ok   $case (witness found)"
			fi
			;;
		*)
			if (cd "$model" && p check -tc "$case" -s "$schedules" >/dev/null 2>&1); then
				echo "   ok   $case ($schedules schedules)"
			else
				echo "   FAIL $case: see $model/PCheckerOutput/BugFinding"
				failed=1
			fi
			;;
		esac
	done
done
exit "$failed"

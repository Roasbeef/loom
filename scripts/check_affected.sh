#!/usr/bin/env bash
# check_affected.sh — run the gates a change can affect, and no others.
#
# Usage: scripts/check_affected.sh [base]   (default: origin/main)
#
# scripts/affected.py decides the gates from the diff between the merge
# base of <base> and the working tree, and prints them as a preparation
# step and lanes; this script runs them and reports each. It runs no test
# itself: a lane is `make <static gates>`, `make model-check`, the helper's
# `--self-test`, or `scripts/check.sh <packages>`, which is the body of
# `make check-<pkg>` and `make check`. When the selector chooses the full
# check, the one package lane is `scripts/check.sh` with no arguments,
# which is exactly `make check`.
#
# Order. The static lane runs first and alone. `make lint` builds and runs
# packages/lint, and a `lint` package lane would compile the same tree at
# the same moment; two compilers writing one build directory is the
# collision scripts/signoff.sh avoids with its serial preparation. The
# static lane is about ten seconds, so running it first costs little and
# reports formatting and doc-graph failures before any suite starts.
#
# Preparation follows, serially, with the targets scripts/signoff.sh's
# preparation uses, narrowed to what the selected lanes need
# (scripts/affected.py, prep): `binaries` for the helper and the tui
# shipment, `codemode-seed` when a code-mode suite is selected, and
# `server-shipment` (bin/loomd) when `client` or `tui` is. Several suites
# feature-detect those prerequisites and print SKIP without them, so
# without the preparation they would pass having run nothing.
#
# The remaining lanes then run concurrently. Their package grouping is the
# signoff's (scripts/affected.py, LANES), so no two lanes compile the same
# package tree, and packages that the signoff runs concurrently are the
# only ones run concurrently here. The environment is the signoff's:
# LOOM_BOOTSTRAP_E2E_SERVER names bin/loomd for the shipped fixtures and
# the tui's real-server test, and LOOM_TEST_PROVIDER_KEY is the fixture key.
#
# The skip census runs last over every lane's log, as the signoff's does,
# and an undeclared skip fails the run. The census also fails on a
# declaration in .github/declared-skips that matched no skip, which is
# right for the signoff, where every suite ran; here most suites did not
# run, so the census is handed only the declarations whose marker appears
# on a SKIP line in these logs. An undeclared skip is judged exactly as
# the signoff judges it.
#
# What this does not run: the bootstrap fixtures under shell sabotage
# (scripts/e2e_client_bootstrap.sh), the simulation soaks, the release and
# update verification, and the enforcement expectations. Those stay in
# the signoff, and the selector says when a change still needs it.
#
# Exit status. Every lane runs to completion even after one fails, so one
# run reports everything wrong. The script then exits with the status of
# the first failure in the order static, lanes as listed, skip census, or
# zero. A failed preparation stops the run with its own status.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
base="${1:-origin/main}"
retry=.github/scripts/hex_retry.sh

python3 scripts/affected.py --base "$base" || exit $?
plan="$(python3 scripts/affected.py --base "$base" --format lanes)" || exit $?

logs="$root/build/affected"
rm -rf "$logs"
mkdir -p "$logs"
started=$(date +%s)
status=0

export LOOM_BOOTSTRAP_E2E_SERVER="$root/bin/loomd"
export LOOM_TEST_PROVIDER_KEY="loom-provider-fixture-key"

prep=""
names=()
commands=()
while read -r name words; do
	if [ "$name" = prep ]; then
		prep=$words
	else
		names+=("$name")
		commands+=("$words")
	fi
done <<<"$plan"

# One step's command words, run under the Hex retry wrapper the signoff
# uses, since every step may invoke gleam. The words are make targets,
# package names and a fixed helper path from the selector, so splitting
# them on spaces is exact.
run_step() {
	local words
	read -r -a words <<<"$1"
	"$retry" "${words[@]}"
}

report() {
	local name=$1 code=$2
	if [ "$code" -eq 0 ]; then
		printf '   ok   %-12s %s\n' "$name" "$(tail -n 1 "$logs/$name.log")"
	else
		printf '   FAIL %-12s exit %s, see %s\n' "$name" "$code" "$logs/$name.log"
		[ "$status" -ne 0 ] || status=$code
	fi
}

echo "== static"
run_step "${commands[0]}" >"$logs/${names[0]}.log" 2>&1
report "${names[0]}" $?

if [ -n "$prep" ]; then
	echo "== prep: $prep"
	prep_started=$(date +%s)
	run_step "$prep" >"$logs/prep.log" 2>&1
	code=$?
	if [ "$code" -ne 0 ]; then
		echo "   FAIL prep         exit $code, see $logs/prep.log"
		exit "$code"
	fi
	echo "   ok   prep         $(( $(date +%s) - prep_started ))s"
fi

if [ "${#names[@]}" -gt 1 ]; then
	echo "== lanes: ${names[*]:1} (logs under $logs)"
	pids=()
	for i in $(seq 1 $(( ${#names[@]} - 1 ))); do
		run_step "${commands[$i]}" >"$logs/${names[$i]}.log" 2>&1 &
		pids[$i]=$!
	done
	for i in $(seq 1 $(( ${#names[@]} - 1 ))); do
		wait "${pids[$i]}"
		report "${names[$i]}" $?
	done
fi

# The declarations that this run's logs exercised, for the census.
echo "== skip census"
declared="$logs/declared-skips"
: >"$declared"
while IFS='|' read -r kind want marker why; do
	case ${kind:-} in "" | \#*) continue ;; esac

	# Read the whole stream so a match cannot SIGPIPE its producer under pipefail.
	if grep -ah 'SKIP' "$logs"/*.log | grep -F -- "$marker" >/dev/null; then
		printf '%s|%s|%s|%s\n' "$kind" "$want" "$marker" "$why" >>"$declared"
	fi
done <.github/declared-skips
LOOM_DECLARED_SKIPS="$declared" .github/scripts/skip_census.sh check-affected \
	"$logs"/*.log >"$logs/census.out" 2>&1
code=$?
if [ "$code" -eq 0 ]; then
	echo "   ok   census       no undeclared skip"
else
	sed 's/^/   /' "$logs/census.out"
	echo "   FAIL census       exit $code, see $logs/census.out"
	[ "$status" -ne 0 ] || status=$code
fi

elapsed=$(( $(date +%s) - started ))
echo "== check-affected against $base: $([ "$status" -eq 0 ] && echo GREEN || echo RED) in ${elapsed}s"
exit "$status"

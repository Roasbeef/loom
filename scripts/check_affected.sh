#!/usr/bin/env bash
# check_affected.sh — run the gates a change can affect, and no others.
#
# Usage: scripts/check_affected.sh [base]   (default: origin/main)
#
# scripts/affected.py decides the gates from the diff between the merge
# base of <base> and the working tree, and prints them as lanes; this
# script runs the lanes and reports each. It runs no test itself: a lane
# is `make <static gates>`, `make model-check`, `make selftest`, or
# `scripts/check.sh <packages>`, which is the body of `make check-<pkg>`
# and `make check`. When the selector chooses the full check, the one
# package lane is `scripts/check.sh` with no arguments, which is exactly
# `make check`.
#
# Order. The static lane runs first and alone. `make lint` builds and runs
# packages/lint, and a `lint` package lane would compile the same tree at
# the same moment; two compilers writing one build directory is the
# collision scripts/signoff.sh avoids with its serial preparation. The
# static lane is about ten seconds, so running it first costs little and
# reports formatting and doc-graph failures before any suite starts. The
# remaining lanes then run concurrently. Their package grouping is the
# signoff's (scripts/affected.py, LANES), so no two lanes compile the same
# package tree, and packages that the signoff runs concurrently are the
# only ones run concurrently here.
#
# `make binaries` runs once before the package lanes, as the prerequisite
# `make check-<pkg>` would have run: the real-helper suites run the helper
# it builds and never compile one themselves. A change that selects only
# static gates skips it.
#
# What this does not run: the bootstrap and shipped-daemon fixtures, the
# simulation soaks, the release and update verification, the skip census,
# and the enforcement expectations. Those stay in the signoff, and the
# selector says when a change still needs it.
#
# Exit status. Every lane runs to completion even after one fails, so one
# run reports everything wrong. The script then exits with the status of
# the first failed lane in the order the lanes are listed, or zero.
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

names=()
commands=()
while read -r name words; do
	names+=("$name")
	commands+=("$words")
done <<<"$plan"

# One lane's command words, run under the Hex retry wrapper the signoff
# uses, since every lane may invoke gleam. The words are gate and package
# names from the selector, so splitting them on spaces is exact.
run_lane() {
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
run_lane "${commands[0]}" >"$logs/${names[0]}.log" 2>&1
report "${names[0]}" $?

if [ "${#names[@]}" -gt 1 ]; then
	if printf '%s\n' "${commands[@]:1}" | grep -q 'scripts/check.sh'; then
		echo "== binaries"
		"$retry" make binaries >"$logs/binaries.log" 2>&1
		code=$?
		if [ "$code" -ne 0 ]; then
			echo "   FAIL binaries    exit $code, see $logs/binaries.log"
			exit "$code"
		fi
	fi
	echo "== lanes: ${names[*]:1} (logs under $logs)"
	pids=()
	for i in $(seq 1 $(( ${#names[@]} - 1 ))); do
		run_lane "${commands[$i]}" >"$logs/${names[$i]}.log" 2>&1 &
		pids[$i]=$!
	done
	for i in $(seq 1 $(( ${#names[@]} - 1 ))); do
		wait "${pids[$i]}"
		report "${names[$i]}" $?
	done
fi

elapsed=$(( $(date +%s) - started ))
echo "== check-affected against $base: $([ "$status" -eq 0 ] && echo GREEN || echo RED) in ${elapsed}s"
exit "$status"

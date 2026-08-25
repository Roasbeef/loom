#!/usr/bin/env bash
# skip_census.sh — refuse to let a suite that did not run read as a pass.
#
# Usage: skip_census.sh <label> <log-file>...
#
# Several of Loom's heaviest suites are feature-detected: the jailed
# end-to-end prints `SKIP jailed_end_to_end: go toolchain not on PATH` and
# returns, the code-mode suites print `SKIP code_mode_end_to_end: ...`
# when the build seed is missing, and the Go jail integration tests call
# `t.Skip` when the kernel has no Landlock. Every one of those still exits
# zero. On a laptop that is a courtesy. In CI it is precisely how four
# milestones were accepted while partial: the suite that would have caught
# it never ran, and nothing said so.
#
# So CI installs the prerequisites first and then insists the suites
# actually ran. A skip reaching this script means either the environment
# regressed or a prerequisite step was dropped — both worth a red run.
set -euo pipefail

if [ "$#" -lt 2 ]; then
	echo "usage: $0 <label> <log-file>..." >&2
	exit 2
fi

label=$1
shift

emit() {
	printf '%s\n' "$*"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
	fi
}

found=$(mktemp)
trap 'rm -f "$found"' EXIT

for log in "$@"; do
	[ -r "$log" ] || { echo "no log at $log" >&2; exit 2; }
	# Gleam suites print `SKIP <test>: <reason>` through io.println, which
	# lands mid-line among gleeunit's progress dots, so match anywhere on
	# the line and strip what precedes it. `go test -v` prints its own
	# `--- SKIP: TestName` with the reason on the following line.
	grep -ao 'SKIP [^:]*: .*' "$log" 2>/dev/null >>"$found" || true
	grep -a -- '--- SKIP' "$log" 2>/dev/null >>"$found" || true
done

if [ ! -s "$found" ]; then
	emit ""
	emit "### Skip census — ${label}: clean"
	emit ""
	emit "No suite reported a skip. Everything that was supposed to run, ran."
	exit 0
fi

emit ""
emit "### Skip census — ${label}: **$(wc -l <"$found" | tr -d ' ') skipped**"
emit ""
emit '```'
sort -u "$found" | while IFS= read -r line; do emit "$line"; done
emit '```'
emit ""
emit "A skipped suite proves nothing. Each line above is a prerequisite this"
emit "runner did not have — install it, or the job is claiming coverage it"
emit "does not have."

echo "" >&2
echo "skip census FAILED for ${label}: a feature-detected suite did not run." >&2
sort -u "$found" >&2
exit 1

#!/usr/bin/env bash
# enforcement_report.sh — hold a self-test run to the declared expectations.
#
# Usage: enforcement_report.sh <selftest-output> <expectations-file> <label>
#
# `loom-exec --self-test` never fails a run for a layer the machine cannot
# provide; it prints SKIPPED and a reason. On a laptop that is honest. In
# CI it would mean a job that enforced nothing looks exactly like a job
# that enforced everything, which is the substitution the sandbox's own
# doc calls out: "a green self-test in a neutered container cannot be
# mistaken for a verified sandbox". This script is the CI half of that
# rule — it compares what the run actually enforced against
# `.github/enforcement-expectations` and fails when they disagree.
#
# It exits nonzero on: a required probe that did not enforce, a probe that
# outright FAILED, a known-gap probe that has started enforcing (the file
# is now stale), a probe present on one side and not the other, and an
# unsupported-platform run (where nothing was attempted at all).
set -euo pipefail

if [ "$#" -ne 3 ]; then
	echo "usage: $0 <selftest-output> <expectations-file> <label>" >&2
	exit 2
fi

output=$1
expectations=$2
label=$3

[ -r "$output" ] || { echo "no self-test output at $output" >&2; exit 2; }
[ -r "$expectations" ] || { echo "no expectations at $expectations" >&2; exit 2; }

# Everything this script says goes to the log and, when GitHub gives us
# one, to the job summary as well — so the enforcement matrix is on the
# run's front page rather than buried in a fold of scrollback.
emit() {
	printf '%s\n' "$*"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
	fi
}

emit_file() {
	cat "$1"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		cat "$1" >>"$GITHUB_STEP_SUMMARY"
	fi
}

fail=0

emit ""
emit "### Sandbox enforcement — ${label}"
emit ""

# A platform with no jail at all is not a set of skips; nothing was even
# attempted. Say so and stop — comparing probe by probe would imply the
# probes ran.
if grep -q 'RESULT: UNSUPPORTED PLATFORM' "$output"; then
	emit "\`loom-exec\` has no jail for this platform: **nothing was attempted**."
	emit ""
	emit '```'
	emit_file "$output"
	emit '```'
	echo "FAIL(${label}): unsupported platform — no confinement was applied or probed" >&2
	exit 1
fi

# --- what the run says -----------------------------------------------------
# The report's shape is fixed by internal/selftest: two spaces, the
# verdict, then the probe name; SKIPPED and FAILED carry "(reason)".
run_status=$(mktemp)
trap 'rm -f "$run_status"' EXIT
awk '
	# Reasons nest their own parentheses ("(protected-path masking needs
	# bwrap (Landlock has no deny rules))"), so take everything from the
	# first " (" to the closing paren at end of line, not the innermost.
	function split_reason(rest,   reason) {
		reason = ""
		if (match(rest, / \(.*\)$/)) {
			reason = substr(rest, RSTART + 2, RLENGTH - 3)
			rest = substr(rest, 1, RSTART - 1)
		}
		return rest "|" reason
	}
	/^  ENFORCED  / { print "ENFORCED|" substr($0, 13) "|"; next }
	/^  SKIPPED   / { print "SKIPPED|" split_reason(substr($0, 13)); next }
	/^  FAILED    / { print "FAILED|" split_reason(substr($0, 13)); next }
' "$output" >"$run_status"

if [ ! -s "$run_status" ]; then
	echo "FAIL(${label}): no probe lines in $output — did the self-test run?" >&2
	sed -n '1,60p' "$output" >&2
	exit 1
fi

status_of() { awk -F'|' -v n="$1" '$2 == n { print $1 }' "$run_status"; }
reason_of() { awk -F'|' -v n="$1" '$2 == n { print $3 }' "$run_status"; }

emit "| probe | expected | run | detail |"
emit "| --- | --- | --- | --- |"

# --- every expectation, against the run ------------------------------------
while IFS='|' read -r want probe why || [ -n "${want:-}" ]; do
	case ${want:-} in "" | \#*) continue ;; esac
	got=$(status_of "$probe")
	detail=$(reason_of "$probe")
	if [ -z "$got" ]; then
		emit "| \`${probe}\` | ${want} | **ABSENT** | not in the self-test output |"
		echo "FAIL(${label}): expectations name a probe the run does not: ${probe}" >&2
		fail=1
		continue
	fi
	case "$want:$got" in
	required:ENFORCED)
		emit "| \`${probe}\` | required | ENFORCED | |"
		;;
	required:*)
		emit "| \`${probe}\` | required | **${got}** | ${detail} |"
		echo "FAIL(${label}): required layer not enforced: ${probe} (${got}: ${detail})" >&2
		fail=1
		;;
	known-gap:SKIPPED)
		emit "| \`${probe}\` | known gap | skipped | ${detail} |"
		emit "| | | | _declared reason:_ ${why} |"
		;;
	known-gap:ENFORCED)
		emit "| \`${probe}\` | known gap | **ENFORCED** | the gap is over |"
		echo "FAIL(${label}): ${probe} now enforces; promote it to 'required' in ${expectations}" >&2
		fail=1
		;;
	known-gap:*)
		emit "| \`${probe}\` | known gap | **${got}** | ${detail} |"
		echo "FAIL(${label}): ${probe} failed rather than skipped: ${detail}" >&2
		fail=1
		;;
	*)
		emit "| \`${probe}\` | **${want}?** | ${got} | unknown expectation keyword |"
		echo "FAIL(${label}): unknown keyword '${want}' in ${expectations}" >&2
		fail=1
		;;
	esac
done <"$expectations"

# --- and every probe, against the expectations ------------------------------
while IFS='|' read -r got probe detail; do
	if ! awk -F'|' -v n="$probe" '
		/^[[:space:]]*(#|$)/ { next }
		$2 == n { found = 1 } END { exit !found }' "$expectations"; then
		emit "| \`${probe}\` | **UNDECLARED** | ${got} | ${detail} |"
		echo "FAIL(${label}): the self-test grew a probe nobody declared: ${probe}" >&2
		echo "  add it to ${expectations} as 'required|${probe}'" >&2
		fail=1
	fi
done <"$run_status"

enforced=$(grep -c '^ENFORCED|' "$run_status" || true)
skipped=$(grep -c '^SKIPPED|' "$run_status" || true)
failed=$(grep -c '^FAILED|' "$run_status" || true)
emit ""
emit "**${enforced} enforced, ${skipped} skipped, ${failed} failed** — a skipped layer was *not* verified here."
emit ""
emit "<details><summary>full self-test report — ${label}</summary>"
emit ""
emit '```'
emit_file "$output"
emit '```'
emit ""
emit "</details>"

if [ "$fail" -ne 0 ]; then
	echo "" >&2
	echo "enforcement check FAILED for ${label}." >&2
	echo "Fix the environment, or record the gap in ${expectations} with a" >&2
	echo "written reason. Deleting the line is never the fix." >&2
	exit 1
fi

echo "enforcement check clean for ${label}: ${enforced} enforced, ${skipped} declared gap(s)"

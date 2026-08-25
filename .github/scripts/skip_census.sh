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
#
# One kind of skip is none of those. A platform Loom has no jail
# implementation for cannot be fixed by installing anything, and the only
# alternative to skipping is to run the suite with nothing enforcing the
# policy it exists to test. Those skips are declared, with a reason, in
# .github/declared-skips, and this script honours that file on the same
# terms .github/enforcement-expectations is honoured: a declared skip that
# stops happening fails the job too, because the declaration has started
# lying. Deleting a line is never the fix.
set -euo pipefail

if [ "$#" -lt 2 ]; then
	echo "usage: $0 <label> <log-file>..." >&2
	exit 2
fi

label=$1
shift

declarations=${LOOM_DECLARED_SKIPS:-"$(dirname "$0")/../declared-skips"}
platform=$(uname -s | tr '[:upper:]' '[:lower:]')

emit() {
	printf '%s\n' "$*"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
	fi
}

found=$(mktemp)
undeclared=$(mktemp)
matched=$(mktemp)
trap 'rm -f "$found" "$undeclared" "$matched"' EXIT

for log in "$@"; do
	[ -r "$log" ] || { echo "no log at $log" >&2; exit 2; }
	# Gleam suites print `SKIP <test>: <reason>` through io.println, which
	# lands mid-line among gleeunit's progress dots, so match anywhere on
	# the line and strip what precedes it. `go test -v` prints its own
	# `--- SKIP: TestName` with the reason on the following line.
	grep -ao 'SKIP [^:]*: .*' "$log" 2>/dev/null >>"$found" || true
	grep -a -- '--- SKIP' "$log" 2>/dev/null >>"$found" || true
done

# --- the declarations that apply to this platform ---------------------------
# Read once into two parallel lists: markers to match skips against, and
# the reason each was declared for.
markers=()
whys=()
if [ -r "$declarations" ]; then
	while IFS='|' read -r kind want marker why || [ -n "${kind:-}" ]; do
		case ${kind:-} in "" | \#*) continue ;; esac
		if [ "$kind" != "declared" ]; then
			echo "skip census: unknown keyword '${kind}' in ${declarations}" >&2
			exit 2
		fi
		[ "$want" = "any" ] || [ "$want" = "$platform" ] || continue
		markers+=("$marker")
		whys+=("$why")
	done <"$declarations"
fi

# --- sort every skip into declared or undeclared ----------------------------
if [ -s "$found" ]; then
	sort -u "$found" | while IFS= read -r line; do
		hit=""
		for i in "${!markers[@]}"; do
			case "$line" in
			*"${markers[$i]}"*)
				hit=${markers[$i]}
				printf '%s\n' "$hit" >>"$matched"
				break
				;;
			esac
		done
		if [ -z "$hit" ]; then
			printf '%s\n' "$line" >>"$undeclared"
		fi
	done
fi

fail=0

if [ -s "$matched" ]; then
	emit ""
	emit "### Skip census — ${label}: declared skips"
	emit ""
	for i in "${!markers[@]}"; do
		if grep -Fqx -- "${markers[$i]}" "$matched" 2>/dev/null; then
			emit "- \`${markers[$i]}\` — ${whys[$i]}"
		fi
	done
fi

# A declared skip that stopped happening is a declaration that has gone
# stale, and a stale declaration is how a real skip gets waved through
# next time. Same rule as .github/enforcement-expectations.
for i in "${!markers[@]}"; do
	if ! grep -Fqx -- "${markers[$i]}" "$matched" 2>/dev/null; then
		emit ""
		emit "**Stale declaration** — \`${markers[$i]}\` matched no skip on"
		emit "${platform}. The skip it excuses is no longer happening."
		echo "skip census FAILED for ${label}: ${declarations} declares a skip" >&2
		echo "  that did not occur: ${markers[$i]}" >&2
		echo "  remove the line; a declaration nobody needs excuses the next one." >&2
		fail=1
	fi
done

if [ ! -s "$undeclared" ]; then
	if [ "$fail" -eq 0 ]; then
		emit ""
		emit "### Skip census — ${label}: clean"
		emit ""
		emit "No undeclared skip. Everything that was supposed to run, ran."
	fi
	exit "$fail"
fi

emit ""
emit "### Skip census — ${label}: **$(wc -l <"$undeclared" | tr -d ' ') undeclared skip(s)**"
emit ""
emit '```'
sort -u "$undeclared" | while IFS= read -r line; do emit "$line"; done
emit '```'
emit ""
emit "A skipped suite proves nothing. Each line above is a prerequisite this"
emit "runner did not have — install it, or the job is claiming coverage it"
emit "does not have. If the skip cannot be fixed by installing anything,"
emit "declare it in ${declarations} with a written reason."

echo "" >&2
echo "skip census FAILED for ${label}: a feature-detected suite did not run." >&2
sort -u "$undeclared" >&2
exit 1

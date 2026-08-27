#!/usr/bin/env bash
# lint.sh — Loom's own lint over the Gleam sources.
#
# Usage: scripts/lint.sh [options] [path...]   (default: every packages/*/src)
#
# The rules are R0 unparseable sources, R1 eager fallbacks, R2 `case` nesting
# depth, R3 catch-all patterns, R4 `panic`/`let assert` in src, R5 O(n)
# answers to bounded questions, and R6 the portable subset `core`, `machine`
# and `prompt` are held to; `packages/lint/CLAUDE.md` says what each is for.
#
# R0, R2, R4 and R6 are at ERROR level and this script exits non-zero on any
# of them; R1, R3 and R5 warn and cost nothing. A rule earns the error tier
# by a census that is zero, decidable and argued — the staging
# scripts/doc_check.sh went through (D2, docs/design-notes/four-decisions.md)
# — and the argument for each of the four is in `finding.error_by_default`.
# R3 can never be promoted: it over-reports by construction. Promoting one of
# the rest is a decision its census has to argue for, and costs one flag:
#
#   scripts/lint.sh --error=R5
#
# The staging itself lives in `finding.error_by_default`, not here, so a
# promotion needs no change to this script or to the Makefile.
#
# The linter's last line is `# <errors> <warnings>`, which is what we read.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)

paths=()
options=()
for argument in "$@"; do
	case $argument in
	-*) options+=("$argument") ;;
	*) paths+=("$root/${argument#"$root/"}") ;;
	esac
done

if [ ${#paths[@]} -eq 0 ]; then
	for directory in packages/*/src; do
		[ -d "$directory" ] && paths+=("$root/$directory")
	done
fi

output=$(cd packages/lint && gleam run -m lint/cli -- \
	${options[@]+"${options[@]}"} "${paths[@]}")
printf '%s\n' "$output"

tail=${output##*$'\n'}
case $tail in
"# "*)
	errors=${tail#\# }
	errors=${errors%% *}
	;;
*) errors=0 ;;
esac
case $errors in "" | *[!0-9]*) errors=0 ;; esac

if [ "$errors" -gt 0 ]; then
	echo "lint FAILED: $errors error(s)"
	exit 1
fi

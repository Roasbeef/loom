#!/usr/bin/env bash
# lint.sh — Loom's own lint over the Gleam sources.
#
# Usage: scripts/lint.sh [options] [path...]   (default: every packages/*/src)
#
# The rules are R1 eager fallbacks, R2 `case` nesting depth, R3 catch-all
# patterns, R4 `panic`/`let assert` in src, and R5 O(n) answers to bounded
# questions; `packages/lint/CLAUDE.md` says what each one is for.
#
# Every rule ships at WARNING level and this script exits 0 unless a rule was
# named with --error, exactly as scripts/doc_check.sh stages its citation
# findings (D2, docs/design-notes/four-decisions.md). Promotion is a decision
# the census argues for, one rule at a time:
#
#   scripts/lint.sh --error=R4
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

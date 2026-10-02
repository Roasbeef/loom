#!/usr/bin/env bash
# lint.sh — Loom's own lint over the Gleam sources.
#
# Usage: scripts/lint.sh [options] [path...]   (default: every packages/*/src)
#
# The rules are R0 unparseable sources, R1 eager fallbacks, R2 `case` nesting
# depth, R3 catch-all patterns, R4 `panic`/`let assert` in src, R5 O(n)
# answers to bounded questions, R6 the portable subset `core`, `machine` and
# `prompt` are held to, R7 a `let assert` that names no invariant, R8 a
# long signature with one caller, R9 a naked `Bool` in a parameter or field,
# R10 a comment with no blank line above it, R11 a body written as one
# undivided block, R12 a closure capturing a whole value for its fields, and
# the orientation rules of issue #593: R13 a large module's `## Flow` spine,
# R14 a transition table checked against its type, R15 state-machine types
# before the first function, R16 an unqualified import of a Loom function,
# and the censuses R17 (call-flow order) and R18 (short helpers the module doc
# never names); `packages/lint/CLAUDE.md` says what each is for.
#
# R0, R2, R4, R6, R10, R13, R14, R15 and R16 are at ERROR level and this
# script exits non-zero on any of them; every other rule warns and costs
# nothing. A rule earns the error tier by a census that is zero, decidable
# and argued — the staging scripts/doc_check.sh went through (D2,
# docs/design-notes/four-decisions.md) — and the argument for each of the
# nine is in `finding.error_by_default`. R3, R8, R17 and R18 can never be
# promoted: they over-report by construction.
# Promoting one of the rest is a decision its census has to argue for, and
# costs one flag:
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

# The lint reads Gleam. The browser package's one JavaScript file is held to
# its own textual gate whenever that package's sources are in the run, which
# is every full run and `make lint-web_client`. It gates as R0 does: a
# violation fails the run. See scripts/web_client_js_check.sh. The same
# runs hold the stylesheet's text colours to a 4.5:1 contrast ratio
# (scripts/web_client_contrast_check.sh).
for path in "${paths[@]}"; do
	case $path in
	"$root"/packages/web_client/src*)
		scripts/web_client_js_check.sh
		scripts/web_client_js_check.sh --self-test
		scripts/web_client_contrast_check.sh
		scripts/web_client_contrast_check.sh --self-test
		break
		;;
	esac
done

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

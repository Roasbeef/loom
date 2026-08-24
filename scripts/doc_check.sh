#!/bin/sh
# doc_check.sh — gate the per-package documentation graph.
#
# Three checks, run over every package under packages/ that has real
# source (Gleam modules under src/, or Go files outside build/):
#
#   1. coverage — the package has a CLAUDE.md.                    (error)
#   2. mirror   — AGENTS.md exists, byte-identical to CLAUDE.md.  (error)
#   3. staleness — src/ has a newer last commit than CLAUDE.md.   (warning)
#
# Staleness is a warning by design: source moves faster than prose, and
# the warning list is the work queue for the /doc-gardening skill. File
# mtimes are meaningless in a fresh checkout (git does not restore them),
# so the comparison uses each path's last commit time instead. A package
# whose docs are untracked, or a tree with no git history, simply skips
# the staleness check rather than guessing.
#
# No builds, no toolchain: this stays usable while other work compiles.

set -eu

cd "$(dirname "$0")/.."

errors=0
warnings=0

# Last commit time (unix seconds) for a path; empty when git cannot say.
committed_at() {
	git log -1 --format=%ct -- "$1" 2>/dev/null || true
}

has_sources() {
	dir=$1
	# Gleam: src/<pkg>/**/*.gleam
	if [ -d "$dir/src" ]; then
		found=$(find "$dir/src" -name '*.gleam' -print -quit 2>/dev/null)
		[ -n "$found" ] && return 0
	fi
	# Go: anything outside build/
	found=$(find "$dir" -name '*.go' -not -path '*/build/*' -print -quit 2>/dev/null)
	[ -n "$found" ] && return 0
	return 1
}

for dir in packages/*; do
	[ -d "$dir" ] || continue
	pkg=${dir#packages/}

	if ! has_sources "$dir"; then
		printf 'skip     %-12s no source modules yet\n' "$pkg"
		continue
	fi

	doc="$dir/CLAUDE.md"
	mirror="$dir/AGENTS.md"

	if [ ! -f "$doc" ]; then
		printf 'ERROR    %-12s missing CLAUDE.md\n' "$pkg"
		errors=$((errors + 1))
		continue
	fi

	if [ ! -f "$mirror" ]; then
		printf 'ERROR    %-12s missing AGENTS.md (cp CLAUDE.md AGENTS.md)\n' "$pkg"
		errors=$((errors + 1))
	elif ! cmp -s "$doc" "$mirror"; then
		printf 'ERROR    %-12s AGENTS.md differs from CLAUDE.md\n' "$pkg"
		errors=$((errors + 1))
	fi

	src_at=""
	[ -d "$dir/src" ] && src_at=$(committed_at "$dir/src")
	[ -n "$src_at" ] || src_at=$(committed_at "$dir")
	doc_at=$(committed_at "$doc")

	if [ -n "$src_at" ] && [ -n "$doc_at" ] && [ "$src_at" -gt "$doc_at" ]; then
		printf 'WARNING  %-12s source committed after CLAUDE.md (run /doc-gardening %s)\n' \
			"$pkg" "$pkg"
		warnings=$((warnings + 1))
	else
		printf 'ok       %-12s\n' "$pkg"
	fi
done

echo
if [ "$errors" -gt 0 ]; then
	echo "doc-check FAILED: $errors error(s), $warnings warning(s)"
	exit 1
fi
echo "doc-check clean: 0 errors, $warnings warning(s)"

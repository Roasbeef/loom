#!/bin/sh
# doc_check.sh — gate the per-package documentation graph.
#
# Four checks. Three run over every package under packages/ that has
# real source (Gleam modules under src/, or Go files outside build/):
#
#   1. coverage — the package has a CLAUDE.md.                    (error)
#   2. mirror   — AGENTS.md exists, byte-identical to CLAUDE.md.  (error)
#   3. staleness — src/ has a newer last commit than CLAUDE.md.   (warning)
#
# The fourth runs over docs/ instead:
#
#   4. citations — docs/**/*.md cite `file.gleam:431`; the file must
#      resolve and still hold the symbol the prose names.          (warning)
#
# Citations are warning-level for now: the existing ones drifted long
# before anything checked them, so the finding list is a work queue, not
# a wall. Resolution is a suffix match against the tracked tree, so a
# bare `planner.gleam` and a package-relative `machine/planner.gleam`
# both land; a name that matches two files is reported rather than
# guessed at. Drift is a windowed symbol check: the backticked symbol
# nearest before the citation must appear within DOC_CHECK_CITE_WINDOW
# lines of the cited span. Citations with no symbol to check are resolution-only and
# counted separately, so the census says how much of the doc corpus the
# stronger check actually covers.
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

# ---------------------------------------------------------------------
# 4. citations
# ---------------------------------------------------------------------
#
# Two inputs on one stream: "I <path>" for every file citations may
# resolve against, "D <path>" for every doc to scan. Dot-directories
# (worktrees, .git) and build/ are pruned — a vendored copy of our own
# sources would make every bare filename ambiguous.

cite_window=${DOC_CHECK_CITE_WINDOW:-5}
cite_limit=${DOC_CHECK_CITE_LIMIT:-10}

cite_out=$({
	find . -path './.*' -prune -o -name build -prune -o -type f \
		\( -name '*.gleam' -o -name '*.go' -o -name '*.erl' \
		-o -name '*.hrl' -o -name '*.sql' -o -name '*.toml' \
		-o -name '*.md' -o -name '*.sh' \) -print | sed 's|^\./|I |'
	find docs -type f -name '*.md' -print 2>/dev/null | sort | sed 's|^|D |'
} | awk -v win="$cite_window" -v limit="$cite_limit" '
BEGIN {
	CITE = "[A-Za-z0-9_./@-]*[A-Za-z0-9_]\\.(gleam|go|erl|hrl|sql|toml|md|sh):[0-9]+"
	IDENT = "[A-Za-z_][A-Za-z0-9_]*"
	# Keywords name no construct, so they prove nothing about a line.
	n = split("pub fn let use case const type opaque import todo panic " \
		"func var return package chan defer struct interface", word, " ")
	for (i = 1; i <= n; i++) keyword[word[i]] = 1
}
{
	path = substr($0, 3)
	if (substr($0, 1, 1) == "I") {
		n = split(path, part, "/")
		byname[part[n]] = byname[part[n]] path "\n"
	} else {
		docs[++ndocs] = path
	}
}
# The one file whose path ends in the cited one: "" none, "?" several.
function resolve(cited,   n, part, k, cand, i, hits, hit) {
	n = split(cited, part, "/")
	if (byname[part[n]] == "") return ""
	k = split(byname[part[n]], cand, "\n")
	hits = 0
	for (i = 1; i <= k; i++) {
		if (cand[i] == "") continue
		if (cand[i] == cited ||
		    substr(cand[i], length(cand[i]) - length(cited)) == "/" cited) {
			hits++
			hit = cand[i]
		}
	}
	if (hits == 0) return ""
	if (hits > 1) return "?"
	return hit
}
function load(f,   i, line) {
	if (f in nlines) return
	i = 0
	while ((getline line < f) > 0) src[f, ++i] = line
	close(f)
	nlines[f] = i
}
# Identifiers in one backticked span: paths and citations are not
# symbols, and a module qualifier is dropped (`api.prompt` -> prompt).
function symbols(span, out,   tok, after, n) {
	n = 0
	if (span == "" || index(span, "/") > 0 || match(span, CITE)) return 0
	while (match(span, IDENT)) {
		tok = substr(span, RSTART, RLENGTH)
		after = substr(span, RSTART + RLENGTH, 1)
		span = substr(span, RSTART + RLENGTH)
		if (after == "." || length(tok) < 3 || tok in keyword) continue
		out[++n] = tok
	}
	return n
}
# Docs also write the symbol just after the citation, parenthesised:
# `storage/memory.gleam:554` (`take_limit`). Only that exact shape — an
# unanchored look-ahead picks up the next English word instead.
function paren_span(s) {
	if (!match(s, /^`?[ ]*\(`[^`]*`\)/)) return ""
	s = substr(s, RSTART, RLENGTH)
	sub(/^`?[ ]*\(`/, "", s)
	sub(/`\)$/, "", s)
	return s
}
# Contents of the last backticked span in s (the one nearest the citation).
function nearest_span(s,   best) {
	best = ""
	while (match(s, /`[^`]*`/)) {
		best = substr(s, RSTART + 1, RLENGTH - 2)
		s = substr(s, RSTART + RLENGTH)
	}
	return best
}
# First line in [a,b] holding sym as a whole word, else 0.
function seek(f, a, b, sym,   i, re) {
	re = "(^|[^A-Za-z0-9_])" sym "([^A-Za-z0-9_]|$)"
	if (a < 1) a = 1
	if (b > nlines[f]) b = nlines[f]
	for (i = a; i <= b; i++) if (src[f, i] ~ re) return i
	return 0
}
# Where sym sits closest to the cited span — the line to cite instead.
function nearest(f, a, b, sym,   i, d, best, dist) {
	best = 0
	dist = nlines[f] + 1
	for (i = 1; i <= nlines[f]; i++) {
		if (!seek(f, i, i, sym)) continue
		d = i < a ? a - i : (i > b ? i - b : 0)
		if (d < dist) { dist = d; best = i }
	}
	return best
}
function report(msg) {
	flagged++
	if (limit == 0 || flagged <= limit) print msg
}
END {
	for (d = 1; d <= ndocs; d++) {
		doc = docs[d]
		lineno = 0
		while ((getline line < doc) > 0) {
			lineno++
			rest = line
			while (match(rest, CITE)) {
				cite = substr(rest, RSTART, RLENGTH)
				before = substr(line, 1, length(line) - length(rest) + RSTART - 1)
				rest = substr(rest, RSTART + RLENGTH)
				total++
				split(cite, part, ":")
				file = part[1]
				first = part[2] + 0
				last = first
				# Ranges: hyphen, en dash or em dash.
				if (match(rest, /^(-|–|—)[0-9]+/)) {
					span = substr(rest, RSTART, RLENGTH)
					sub(/^(-|–|—)/, "", span)
					if (span + 0 > last) last = span + 0
				}
				where = "%s:%d cites %s"
				f = resolve(file)
				if (f == "") {
					report(sprintf(where " — no such file in the tree", doc, lineno, cite))
					continue
				}
				if (f == "?") {
					report(sprintf(where " — several files match that name", doc, lineno, cite))
					continue
				}
				load(f)
				if (last > nlines[f]) {
					report(sprintf(where " — %s has %d lines", doc, lineno, cite, f, nlines[f]))
					continue
				}
				resolved++
				nsym = symbols(nearest_span(before), sym)
				if (nsym == 0) nsym = symbols(paren_span(rest), sym)
				if (nsym == 0) { unchecked++; continue }
				checked++
				for (i = 1; i <= nsym; i++)
					if (seek(f, first - win, last + win, sym[i])) break
				if (i <= nsym) continue
				for (i = 1; i <= nsym; i++)
					if ((at = nearest(f, first, last, sym[i]))) break
				if (i <= nsym)
					report(sprintf(where " — `%s` is at line %d", doc, lineno, cite, sym[i], at))
				else
					report(sprintf(where " — `%s` is not in %s", doc, lineno, cite, sym[1], f))
				drifted++
			}
		}
		close(doc)
	}
	printf "%d cited, %d resolve, %d symbol-checked (%d resolution-only), %d drifted\n",
		total, resolved, checked, unchecked, drifted
	if (limit > 0 && flagged > limit)
		printf "%d flagged, %d shown — DOC_CHECK_CITE_LIMIT=0 lists every one\n",
			flagged, limit
	printf "#%d\n", flagged
}')

# Awk ends with the finding count; the findings come first, then the
# census — which is one line, or two when the listing was capped.
cite_count=$(printf '%s\n' "$cite_out" | tail -1)
cite_count=${cite_count#\#}
case $cite_count in "" | *[!0-9]*) cite_count=0 ;; esac
cite_body=$(printf '%s\n' "$cite_out" | sed '$d')

shown=$cite_count
if [ "$cite_limit" -gt 0 ] && [ "$shown" -gt "$cite_limit" ]; then
	shown=$cite_limit
fi

echo
printf '%s\n' "$cite_body" | head -n "$shown" |
	while IFS= read -r finding; do
		printf 'WARNING  %-12s %s\n' citations "$finding"
	done
printf '%s\n' "$cite_body" | tail -n +"$((shown + 1))" |
	while IFS= read -r summary; do
		if [ "$cite_count" -eq 0 ]; then
			printf 'ok       %-12s %s\n' citations "$summary"
		else
			printf '         %-12s %s\n' citations "$summary"
		fi
	done
warnings=$((warnings + cite_count))

echo
if [ "$errors" -gt 0 ]; then
	echo "doc-check FAILED: $errors error(s), $warnings warning(s)"
	exit 1
fi
echo "doc-check clean: 0 errors, $warnings warning(s)"

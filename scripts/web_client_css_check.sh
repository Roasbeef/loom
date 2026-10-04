#!/usr/bin/env bash
# web_client_css_check.sh — keep the monospace face off the web view's own
# rows: no rule whose selector names `.line`, `.step`, `.chip` or
# `.panel-title` sets the monospace face.
#
#   scripts/web_client_css_check.sh [css]   fail on a violation (default
#                                           packages/web_client/src/
#                                           web_client.css)
#   scripts/web_client_css_check.sh --self-test
#                                           prove the gate catches it
#
# `make lint` runs both, with the JavaScript and contrast checks, whenever the
# browser package's sources are in the run.
#
# ## What it holds
#
# The page's labels, rows and headings are set in the system sans face. The
# monospace face is for code, paths, tags, diffs and the bar's figures
# (docs/design-notes/web-design.md, and the web UI critique that set the
# visual system). A transcript row (`.line`), a step, a strand card (`.chip`)
# and a panel heading (`.panel-title`) are the four places the face crept in
# first, so a rule that names one of them and also names `--font-mono` or the
# `monospace` keyword fails. Where a row carries code, the rule names the
# code's own class (`pre.tool-result`, `.step-summary`, `.diff-row`) and not
# the row's.
#
# The match is textual, in the shape scripts/web_client_js_check.sh uses. A
# rule is the text between a `{` and the `}` that closes it, with comments
# removed; its selector is what precedes the `{` back to the previous `{`, `}`
# or `;`. A class name counts as a whole token, so `.step-summary` and
# `.chip-name` are not `.step` and `.chip`. This is a reviewer's aid, not a
# parser: a rule written across a nested at-rule in an unusual way can slip
# past it, and what it does is make the plain way of breaking the rule fail
# the build.
set -euo pipefail
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
root=$(cd "$(dirname "$0")/.." && pwd)

default_css="$root/packages/web_client/src/web_client.css"

# The class names no monospace rule may name.
classes='line step chip panel-title'

# check <css>: print each violating rule, and return non-zero if there was one.
check() {
	local css="$1"
	local found

	if [ ! -f "$css" ]; then
		echo "web_client_css_check: $css is not a file" >&2
		return 2
	fi

	found=$(awk -v classes="$classes" '
		{
			text = $0
			# Comments go first: their prose names these classes freely.
			while (match(text, /\/\*[^*]*\*+([^\/*][^*]*\*+)*\//)) {
				text = substr(text, 1, RSTART - 1) " " substr(text, RSTART + RLENGTH)
			}
			n = split(classes, names, " ")
			count = split(text, chunks, "}")
			for (c = 1; c <= count; c++) {
				chunk = chunks[c]
				open = 0
				for (k = length(chunk); k >= 1; k--) {
					if (substr(chunk, k, 1) == "{") { open = k; break }
				}
				if (open == 0) continue
				selector = substr(chunk, 1, open - 1)
				body = substr(chunk, open + 1)
				# The selector starts after any enclosing at-rule or earlier rule.
				while (match(selector, /[{};]/)) {
					selector = substr(selector, RSTART + 1)
				}
				if (body !~ /--font-mono|monospace/) continue
				for (i = 1; i <= n; i++) {
					if (selector ~ ("\\." names[i] "([^A-Za-z0-9_-]|$)")) {
						gsub(/[ \t\n]+/, " ", selector)
						printf "%s names .%s\n", selector, names[i]
					}
				}
			}
		}
	' < <(tr '\n' ' ' <"$css"))

	if [ -n "$found" ]; then
		printf 'web_client_css_check: %s\n' "$found" >&2
		echo "web_client_css_check: a rule sets the monospace face on a row; name the code's own class instead" >&2
		return 1
	fi
}

# ------------------------------------------------------------- the self-test
#
# The real stylesheet passes; each violation, planted alone in a copy, fails,
# and the shapes the check must not take for one pass.

self_test() {
	local tmp
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN

	if ! check "$default_css" >/dev/null 2>&1; then
		echo "web_client_css_check: self-test: the stylesheet does not pass" >&2
		return 1
	fi

	local body name
	for body in \
		'.line{font:13px/1.4 var(--font-mono);}' \
		'.line.user,.line.assistant{font-family:var(--font-mono);}' \
		'.step{font:12px monospace;}' \
		'li.chip .x{font:12px var(--font-mono);}' \
		'.panel-title{font:600 11px/1.4 var(--font-mono);}' \
		'@media (max-width:640px){main.x{padding:0;}.step .line{font:12px var(--font-mono);}}'; do
		name=$(printf '%s' "$body" | tr -c 'A-Za-z0-9' '_')
		printf '%s\n' "$body" >"$tmp/$name.css"
		if check "$tmp/$name.css" >/dev/null 2>&1; then
			echo "web_client_css_check: self-test: '$body' passed the check" >&2
			return 1
		fi
	done

	# Longer class names, other faces, comments and other rules are not it.
	for body in \
		'.step-summary{font:12px var(--font-mono);}' \
		'.chip-name{font:500 14px var(--font-sans);}' \
		'.line{font:14px/1.5 var(--font-sans);}' \
		'pre.tool-result{font:12px/1.5 var(--font-mono);}' \
		'/* .line names --font-mono in a comment */ .x{color:red;}' \
		'.line{margin:0;}.diff-row{font:12px var(--font-mono);}'; do
		printf '%s\n' "$body" >"$tmp/ok.css"
		if ! check "$tmp/ok.css" >/dev/null 2>&1; then
			echo "web_client_css_check: self-test: '$body' failed the check" >&2
			return 1
		fi
	done
}

case "${1:-}" in
--self-test)
	self_test
	echo "web_client_css_check: self-test ok"
	;;
"")
	check "$default_css"
	echo "web_client_css_check: ok"
	;;
*)
	check "$1"
	echo "web_client_css_check: ok"
	;;
esac

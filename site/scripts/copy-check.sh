#!/bin/sh
# Looks for the words and marks the site's copy rules forbid.
#
# The rules, from the owner: plain, direct statements; no marketing filler;
# no em dashes. A mechanical check cannot judge style, but it can keep the
# listed words and the em dash out of every file that carries copy, which is
# the part that regresses when somebody pastes a paragraph in.
#
# Usage: scripts/copy-check.sh
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)

# Files that carry copy: the Gleam sources (whose strings are the page text),
# the Markdown documentation pages, and the HTML shell.
files=$(find "$here/src" "$here/public/content" "$here/index.html" \
  -type f \( -name '*.gleam' -o -name '*.md' -o -name '*.html' \) | sort)

status=0

# Marketing filler. Matching is on whole words, case-insensitively.
words='supercharge[sd]?|unleash(es|ed|ing)?|seamless(ly)?|next-generation|next-gen|revolutionary|robust(ly|ness)?|leverag(e|es|ed|ing)|cutting-edge|game-chang(er|ing)|blazing|effortless(ly)?|world-class|best-in-class|powerful|state-of-the-art'
if echo "$files" | xargs grep -n -i -E -w "$words" 2>/dev/null; then
  echo "copy-check: marketing filler found (see above)" >&2
  status=1
fi

# The em dash, U+2014.
if echo "$files" | xargs grep -n '—' 2>/dev/null; then
  echo "copy-check: em dash found (see above)" >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "copy-check: clean"
fi
exit "$status"

#!/usr/bin/env bash
# web_client_js_check.sh — keep the browser package's JavaScript to one file
# that cannot turn text into markup or code.
#
#   scripts/web_client_js_check.sh [dir]     fail on a violation (default
#                                            packages/web_client/src)
#   scripts/web_client_js_check.sh --self-test
#                                            prove the gate catches each one
#
# `make lint` runs both, and so `make lint-web_client` and the last step of
# `make check`.
#
# ## What it holds
#
# packages/web_client is Gleam compiled to JavaScript, and the only
# JavaScript it may carry is `internal/dom.mjs`: one export per DOM call,
# with the components' logic in Gleam over them (docs/lustre.md, and
# `internal/ffi_dom.gleam` for why). Two rules follow, and this script is
# what makes each of them a gate rather than a habit:
#
#   1. `dom.mjs` is the only JavaScript file under src. A second `.mjs`
#      (or a `.js`, `.cjs` or `.ts`) is logic written outside the language
#      the package's tests and lint cover.
#   2. No JavaScript there mentions a way to turn a string into markup or
#      code: `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `eval`,
#      `new Function` or `document.write`. protocol-change/051 keeps raw
#      HTML out of the page, and the page's policy (`script-src 'self'`)
#      would refuse the code forms anyway; naming them in the one file
#      that could use them is the cheapest place to stop it.
#
# The match is on the token anywhere in the file, comments included, so a
# comment that must discuss one spells it differently.
#
# ## Why a script and not a lint rule
#
# `packages/lint` reads Gleam sources through `glance`; it has no parser for
# JavaScript and no rule that looks at anything but `.gleam`. The gate is
# textual and needs nothing but grep, in the shape scripts/web_assets.sh
# and scripts/gen-prelude.sh use for their checks, so it runs wherever
# `make lint` does, without a toolchain.
set -euo pipefail
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
root=$(cd "$(dirname "$0")/.." && pwd)

sole="web_client/internal/dom.mjs"

# Each pattern is an extended regular expression, matched whole-word where a
# longer identifier could contain it (`evaluate` is not `eval`).
patterns=(
	'innerHTML'
	'outerHTML'
	'insertAdjacentHTML'
	'\beval\b'
	'new[[:space:]]+Function\b'
	'document[[:space:]]*\.[[:space:]]*write'
)

# check <dir>: print each violation, and return non-zero if there was one.
check() {
	local dir="$1"
	local failed=0
	local file pattern

	if [ ! -d "$dir" ]; then
		echo "web_client_js_check: $dir is not a directory" >&2
		return 2
	fi

	while IFS= read -r file; do
		if [ "${file#"${dir%/}"/}" != "$sole" ]; then
			echo "web_client_js_check: $file is JavaScript; the only JavaScript" >&2
			echo "web_client_js_check: allowed here is $sole" >&2
			failed=1
		fi
		for pattern in "${patterns[@]}"; do
			if grep -nE -- "$pattern" "$file" >&2; then
				echo "web_client_js_check: $file matches $pattern" >&2
				failed=1
			fi
		done
	done < <(find "$dir" -type f \( -name '*.mjs' -o -name '*.js' -o -name '*.cjs' -o -name '*.ts' \) | LC_ALL=C sort)

	return $failed
}

# ------------------------------------------------------------- the self-test
#
# A clean tree passes; each violation, planted alone in a copy, fails.

self_test() {
	local tmp
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN
	local case_dir

	fresh() {
		case_dir="$tmp/$1"
		mkdir -p "$case_dir/web_client/internal"
		printf 'export function now() {\n  return Date.now();\n}\n' \
			>"$case_dir/$sole"
	}

	fresh clean
	if ! check "$case_dir" >/dev/null 2>&1; then
		echo "web_client_js_check: self-test: a clean tree does not pass" >&2
		return 1
	fi

	local body name
	for body in \
		'el.innerHTML = x;' \
		'el.outerHTML = x;' \
		'el.insertAdjacentHTML("beforeend", x);' \
		'eval(x);' \
		'window.eval(x);' \
		'return new Function("a", x);' \
		'document.write(x);' \
		'document . write(x);'; do
		name=$(printf '%s' "$body" | tr -c 'A-Za-z0-9' '_')
		fresh "$name"
		printf '%s\n' "$body" >>"$case_dir/$sole"
		if check "$case_dir" >/dev/null 2>&1; then
			echo "web_client_js_check: self-test: '$body' passed the check" >&2
			return 1
		fi
	done

	# Words that merely contain a forbidden one are not it.
	fresh contained
	printf '// evaluate the medieval function newFunction\n' \
		>>"$case_dir/$sole"
	if ! check "$case_dir" >/dev/null 2>&1; then
		echo "web_client_js_check: self-test: 'evaluate' was taken for 'eval'" >&2
		return 1
	fi

	# A second JavaScript file is a violation on its own.
	for name in follow.mjs extra.js extra.cjs extra.ts; do
		fresh "second_$name"
		printf 'export const x = 1;\n' >"$case_dir/web_client/internal/$name"
		if check "$case_dir" >/dev/null 2>&1; then
			echo "web_client_js_check: self-test: a second file $name passed" >&2
			return 1
		fi
	done

	# So is one at another depth, including a file named like the sole one.
	for name in other/helper.mjs other/dom.mjs; do
		fresh "nested_$name"
		mkdir -p "$case_dir/web_client/other"
		printf 'export const x = 1;\n' >"$case_dir/web_client/$name"
		if check "$case_dir" >/dev/null 2>&1; then
			echo "web_client_js_check: self-test: $name passed" >&2
			return 1
		fi
	done
}

case "${1-}" in
--self-test) self_test ;;
-*)
	echo "usage: $self [dir | --self-test]" >&2
	exit 2
	;;
"") check "$root/packages/web_client/src" ;;
*) check "$1" ;;
esac

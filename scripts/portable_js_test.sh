#!/usr/bin/env bash
# portable_js_test.sh — run a portable package's tests on the JavaScript target.
#
# Usage: scripts/portable_js_test.sh <package>   (gepa or evalstat)
#
# `gepa` and `evalstat` are held to the R6 portable subset and promise, in
# their package docs, that their suites pass on both targets: gepa because
# it is embedded in projects that are not Loom, evalstat because its
# bootstrap must print the same digits wherever a report is rendered. A
# promise the gate never checks is a promise that drifts, and the codec in
# gepa did drift once, through string functions that see graphemes on one
# target and code units on the other. So scripts/check.sh runs the Erlang
# suite through scripts/test.sh and then this script, which runs the same
# suite under whichever JavaScript runtime is first on PATH (Node, Bun or
# Deno), the way scripts/web_client_test.sh does for the browser package.
#
# A machine with no runtime prints a `SKIP portable_js_tests: ...` line and
# exits zero, as the repository's other feature-detected suites do, so that
# .github/scripts/skip_census.sh turns it into a red CI run instead of a
# suite that quietly did not run.
set -euo pipefail
cd "$(dirname "$0")/.."

package=${1:?usage: scripts/portable_js_test.sh <gepa|evalstat>}
case "$package" in
gepa | evalstat) ;;
*) echo "not a portable package with a JavaScript suite: $package" >&2; exit 2 ;;
esac

runtime=""
for candidate in node bun deno; do
	if command -v "$candidate" >/dev/null 2>&1; then
		runtime=$candidate
		break
	fi
done

if [ -z "$runtime" ]; then
	echo "SKIP portable_js_tests: no JavaScript runtime (node, bun or deno) on PATH for $package"
	exit 0
fi

cd "packages/$package"
echo "==> $package (JavaScript, $runtime)"
python3 ../../scripts/with_timeout.py 600 -- \
	gleam test --target javascript --runtime "$runtime"

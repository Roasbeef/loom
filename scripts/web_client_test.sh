#!/usr/bin/env bash
# web_client_test.sh — run the browser package's tests.
#
# Usage: scripts/web_client_test.sh
#
# packages/web_client targets JavaScript, so `gleam test` there needs a
# JavaScript runtime: Node, Bun or Deno, whichever is first on PATH. The
# tests run the components' decisions (`follow.after_scroll`,
# `composer.matching`, `composer.intent` and the rest) without a page; what
# they cannot reach is the DOM, which packages/web_client/CLAUDE.md lists.
#
# A machine with no runtime prints a `SKIP web_client_tests: ...` line and
# exits zero, as the repository's other feature-detected suites do, so that
# .github/scripts/skip_census.sh turns it into a red CI run instead of a
# suite that quietly did not run.
set -euo pipefail
cd "$(dirname "$0")/.."

runtime=""
for candidate in node bun deno; do
	if command -v "$candidate" >/dev/null 2>&1; then
		runtime=$candidate
		break
	fi
done

if [ -z "$runtime" ]; then
	echo "SKIP web_client_tests: no JavaScript runtime (node, bun or deno) on PATH"
	exit 0
fi

cd packages/web_client
python3 ../../scripts/with_timeout.py 600 -- \
	gleam test --target javascript --runtime "$runtime"

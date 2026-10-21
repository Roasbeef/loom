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
#
# ## Nothing a test loads may reach Lustre or the DOM binding
#
# `lustre/runtime/client/runtime.ffi.mjs` declares `class LustreEvent extends
# CustomEvent` at load, and Node 18 (what the signoff container's apt gives)
# has no global `CustomEvent`, so a test module that imports a component
# throws `ReferenceError` before any test runs. The decisions therefore live in
# `web_client/follow_rule`, `composer_rule` and `duration`, which import
# neither, and the tests import only those. That split is lint rule R20
# (packages/lint, lint/test_imports): `make lint-web_client` walks every
# `web_client/...` module reachable from `test/` and fails on one that imports
# `lustre` or `web_client/internal/...`. It needs no JavaScript runtime, and
# `scripts/check.sh` runs it as part of the lint.
set -euo pipefail
cd "$(dirname "$0")/.."

package=${1:-web_client}
case "$package" in
web_client | web_mermaid) ;;
*) echo "unknown browser package: $package" >&2; exit 2 ;;
esac

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

cd "packages/$package"

# The isolated renderer's adapter is tested with a controlled DOM and vendor
# promise. It reads only source files, not installed npm dependencies.
if [ "$package" = web_mermaid ]; then
	case "$runtime" in
	node | bun) "$runtime" bundle/renderer_test.mjs ;;
	deno) deno run --allow-read bundle/renderer_test.mjs ;;
	esac
fi

python3 ../../scripts/with_timeout.py 600 -- \
	gleam test --target javascript --runtime "$runtime"

# The transport's queue belongs to Lustre rather than a Gleam decision module.
# Test the pinned runtime with fake sockets so a retry cannot replay a submit.
if [ "$package" = web_client ]; then
	case "$runtime" in
	node | bun) "$runtime" test/reconnect_transport_test.mjs ;;
	deno) deno run --allow-read test/reconnect_transport_test.mjs ;;
	esac
fi

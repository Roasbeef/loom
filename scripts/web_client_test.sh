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
# neither, and the tests import only those. `check_imports` walks every
# `web_client/...` module reachable from `test/` and fails on one that imports
# `lustre` or `web_client/internal/...`, so the split cannot quietly regress.
# It needs no runtime, so it runs before the SKIP below can hide it.
set -euo pipefail
cd "$(dirname "$0")/.."

# check_imports <package dir>: print the offending import chain and return
# non-zero if a module reachable from the tests imports Lustre or an
# internal module.
check_imports() {
	local pkg="$1"
	local queue=() seen=" " file import module failed=0
	while IFS= read -r file; do queue+=("$file"); done < <(find "$pkg/test" -name '*.gleam')
	while [ ${#queue[@]} -gt 0 ]; do
		file=${queue[0]}
		queue=("${queue[@]:1}")
		while IFS= read -r import; do
			module=${import#import }
			module=${module%%[ .{]*}
			case $module in
			lustre | lustre/* | web_client/internal/*)
				echo "web_client_test: $file imports $module, which loads the browser runtime" >&2
				failed=1
				;;
			web_client/*)
				case $seen in *" $module "*) continue ;; esac
				seen="$seen$module "
				if [ -f "$pkg/src/$module.gleam" ]; then
					queue+=("$pkg/src/$module.gleam")
				fi
				;;
			esac
		done < <(grep -E '^import ' "$file")
	done
	return $failed
}

check_imports packages/web_client

if [ "${1-}" = "--check-imports" ]; then
	exit 0
fi

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

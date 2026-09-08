#!/usr/bin/env bash
# signoff.sh — run the merge gate on this machine, in parallel, and post
# the verdict as a `signoff/<platform>` commit status.
#
# Usage: scripts/signoff.sh [--commit <rev>] [--url <url>] [--dry-run]
#
#   --commit <rev>  the commit to sign (default: HEAD). A remote runner
#                   checked out detached at a pushed SHA passes it here.
#   --url <url>     the status's details link; a log host if there is one.
#   --dry-run       run every lane and print the verdict; post nothing.
#
# Why this exists. The hosted workflow splits `make check` into buckets
# and the rest into jobs because a hosted runner is one small machine and
# parallelism there means more machines. A developer's box is one large
# machine, so the same split becomes background lanes on one checkout,
# and the queue time — most of a hosted run's wall clock, and all of its
# variance — goes away. Everything here is the exact command a CI job
# runs; only the scheduling differs.
#
# What runs. One serial preparation, then six lanes:
#
#   prep                     `make codemode-seed build binaries
#                            server-shipment`. Serial on purpose: it is the
#                            only step that resolves dependencies, and it
#                            compiles every package (src and test) before
#                            any lane touches one. After it, a lane's own
#                            `gleam build` is a fingerprint check, so two
#                            lanes visiting the same package tree — the
#                            client lane and the bootstrap fixtures both
#                            build packages/client — cannot compile the
#                            same module at once.
#   client                   scripts/check.sh client tui, then
#                            scripts/e2e_client_bootstrap.sh: the native
#                            TUI bootstrap and the shipped-daemon fixtures.
#                            The long pole, and sequential on purpose: the
#                            bootstrap fixtures run tui's launch-lock tests
#                            and drive the client package's shipped
#                            fixtures a second time, and both name their
#                            scratch roots by the millisecond. Two lanes
#                            running them at once collided on the first
#                            warm run — a lock reported busy by the other
#                            lane's copy of the same test. CI never meets
#                            this because those jobs are separate machines.
#   mid                      check.sh runtime storage session events.
#   conformance              check.sh conformance, then the 200-seed soak.
#                            The soak rebuilds packages/conformance once a
#                            chunk, so it stays behind the conformance
#                            suite in one lane rather than beside it.
#   fast                     check.sh over every other package, the Go
#                            sandbox tests included.
#   static                   the scripts/ unittest suite, `make fmt-check`,
#                            `make lint`, `make doc-check`.
#   enforcement              `loom-exec --self-test`, held to
#                            .github/enforcement-expectations — the same
#                            file, so this box must enforce every layer
#                            the hosted jail job enforces.
#
# `make e2e` and `make e2e-codemode` are not lanes because they are the
# conformance and codemode package suites by another name; with a
# delegated cgroup base set for the whole run (below), the conformance
# and fast lanes are the enforced runs the hosted jail job exists to
# provide. The skip census then reads every lane's log with the jail
# job's declarations, so a suite that declined to run cannot read as a
# pass.
#
# Kernel enforcement without root. The pids-limit probe, and every
# shipped fixture that demands helper enforcement, need a process-empty
# cgroup v2 base the helper may create children in. The hosted job builds
# one with sudo. Here, on a systemd host, `systemd-run --user --scope
# -p Delegate=yes` hands an unprivileged user exactly that: a fresh scope
# whose controllers the user may enable for its children. The script
# re-executes itself inside such a scope, moves its own shell into a
# `supervisor` subgroup so the scope root is empty (cgroup v2 forbids a
# cgroup from both holding processes and distributing controllers), and
# offers `base` to the helper through LOOM_CGROUP_BASE. When any step of
# that fails the run continues without a base and says so; the
# enforcement lane then fails honestly, because the expectations file
# requires the pids probe, rather than the gate quietly proving less.
#
# Parallelism inside a package. SIGNOFF_PARALLEL is exported to every
# lane as LOOM_TEST_PARALLEL, so each package's EUnit run may execute up
# to that many tests at once (scripts/test.sh, and scripts/serial-tests
# for the modules held back). It defaults to 8: measured on a 32-core
# box, every package passed three runs of three at that setting once the
# fixture-hygiene work landed, and the client package, the whole critical
# path, fell from about 390 seconds to about 220. Set it to 1 to
# reproduce the sequential run when a failure needs to be told apart
# from a concurrency effect.
#
# Hex. Gleam 1.18.1 as released re-resolves path dependencies through
# the Hex API on every invocation (issue #248), and seven lanes at once
# is a burst the per-address rate limit answers with 429 — the first
# dry run of this script lost five lanes to exactly that within seconds.
# The real fix is the compiler CI builds, the release tag plus the fix
# commit named by GLEAM_PATCHES in .github/workflows/ci.yml; run that
# compiler here too. Every gleam-invoking lane is wrapped in
# .github/scripts/hex_retry.sh regardless, as CI wraps its own steps.
#
# Exit status is the gate's verdict. Every lane runs to completion even
# after one fails, so one run reports everything wrong, and the status is
# posted only from the verdict: `gh signoff <name>` on green, `gh signoff
# fail <name>` otherwise, so a red mark is visible rather than silence.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

commit=HEAD
url=""
post=yes
while [ $# -gt 0 ]; do
	case $1 in
	--commit) commit=${2:?--commit needs a revision}; shift 2 ;;
	--url) url=${2:?--url needs a url}; shift 2 ;;
	--dry-run) post=no; shift ;;
	*) echo "usage: $0 [--commit <rev>] [--url <url>] [--dry-run]" >&2; exit 2 ;;
	esac
done

case $(uname -s) in
Linux) name=linux ;;
Darwin) name=macos ;;
*) echo "signoff: no gate for $(uname -s)" >&2; exit 2 ;;
esac
context="signoff/$name"
sha=$(git rev-parse --verify "$commit^{commit}") || exit 2

# --- a delegated cgroup base, on Linux, with no root involved ---------------
if [ "$name" = linux ] && [ -z "${LOOM_CGROUP_BASE:-}" ] &&
	[ -z "${LOOM_SIGNOFF_SCOPE:-}" ] && command -v systemd-run >/dev/null; then
	export LOOM_SIGNOFF_SCOPE=1
	exec systemd-run --user --scope --quiet -p Delegate=yes "$0" \
		--commit "$sha" ${url:+--url "$url"} $([ "$post" = yes ] || echo --dry-run)
fi
if [ "$name" = linux ] && [ -z "${LOOM_CGROUP_BASE:-}" ] && [ -n "${LOOM_SIGNOFF_SCOPE:-}" ]; then
	scope="/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)"
	if mkdir -p "$scope/supervisor" "$scope/base" &&
		echo $$ >"$scope/supervisor/cgroup.procs" &&
		echo "+memory +pids" >"$scope/cgroup.subtree_control" &&
		echo "+memory +pids" >"$scope/base/cgroup.subtree_control"; then
		export LOOM_CGROUP_BASE="$scope/base"
		echo "delegated cgroup base: $LOOM_CGROUP_BASE"
	else
		echo "signoff: could not shape the delegated scope at $scope; running without a cgroup base" >&2
	fi
fi

# --- the run ---------------------------------------------------------------
logs="$root/build/signoff"
rm -rf "$logs"
mkdir -p "$logs"
export LOOM_BOOTSTRAP_E2E_SERVER="$root/bin/loomd"
export LOOM_TEST_PROVIDER_KEY="loom-provider-fixture-key"
export LOOM_DECLARED_SKIPS="$root/.github/declared-skips"
export LOOM_TEST_PARALLEL="${SIGNOFF_PARALLEL:-8}"
started=$(date +%s)
retry=.github/scripts/hex_retry.sh

echo "== $context on $sha"
echo "== prep"
if ! $retry make codemode-seed build binaries server-shipment 2>&1 | tee "$logs/prep.log"; then
	echo "prep failed; see $logs/prep.log" >&2
	verdict=1
fi

lane_client() {
	$retry bash scripts/check.sh client tui &&
		$retry bash scripts/e2e_client_bootstrap.sh
}
lane_mid() { $retry bash scripts/check.sh runtime storage session events; }
lane_conformance() {
	$retry bash scripts/check.sh conformance &&
		$retry make soak SOAK_SEEDS="${SIGNOFF_SOAK_SEEDS:-200}"
}
lane_fast() {
	$retry bash scripts/check.sh host core machine prompt telemetry provider \
		broker mcp tools cap ext codemode lint sandbox
}
lane_static() {
	python3 scripts/with_timeout.py 20 -- \
		python3 -m unittest discover -s scripts -p 'test_*.py' &&
		make fmt-check && $retry make lint && make doc-check
}
lane_enforcement() {
	./packages/sandbox/loom-exec --self-test 2>&1 | tee "$logs/selftest.log"
	.github/scripts/enforcement_report.sh "$logs/selftest.log" \
		.github/enforcement-expectations "$context (self-test)"
}

lanes=(client mid conformance fast static enforcement)
pids=()
lane_logs=()
if [ -z "${verdict:-}" ]; then
	echo "== lanes: ${lanes[*]} (logs under $logs)"
	for lane in "${lanes[@]}"; do
		"lane_$lane" >"$logs/$lane.log" 2>&1 &
		pids+=($!)
		lane_logs+=("$logs/$lane.log")
	done
	verdict=0
	for i in "${!lanes[@]}"; do
		if wait "${pids[$i]}"; then
			printf '   ok   %-12s %s\n' "${lanes[$i]}" "$(tail -n 1 "${lane_logs[$i]}")"
		else
			printf '   FAIL %-12s see %s\n' "${lanes[$i]}" "${lane_logs[$i]}"
			verdict=1
		fi
	done

	# Skips are censused over every lane at once. A single check bucket
	# without a cgroup base would print the enforcement-unavailable skips
	# the linux-gate declarations cover; this run has the base, so it is
	# held to the jail job's declarations, which cover none of them.
	echo "== skip census"
	if ! .github/scripts/skip_census.sh "$context" "${lane_logs[@]}"; then
		verdict=1
	fi
fi

elapsed=$(( $(date +%s) - started ))
echo "== $context: $([ "$verdict" -eq 0 ] && echo GREEN || echo RED) in ${elapsed}s"

# --- the status ------------------------------------------------------------
if [ "$post" = yes ]; then
	if [ "$verdict" -eq 0 ]; then
		gh signoff --commit "$sha" ${url:+--url "$url"} "$name"
	else
		gh signoff fail --commit "$sha" ${url:+--url "$url"} \
			--description "$(git config user.name): $context red, $elapsed s, see build/signoff on the runner" "$name"
	fi
fi
exit "$verdict"

#!/usr/bin/env bash
# e2e_client_bootstrap.sh — the native-TUI bootstrap and shipped-daemon
# fixtures against the real local server under bin/loomd.
#
# Usage: scripts/e2e_client_bootstrap.sh
#
# This is the body of `make e2e-client-bootstrap`, moved out of the
# Makefile so it can run without the target's prerequisites. The target
# depends on `binaries server-shipment`, both `.PHONY`, so invoking it
# rebuilds the tui shipment and re-exports the server shipment every time.
# Serially that is only wasted seconds; inside scripts/signoff.sh, where
# this runs beside the package lanes, it would re-export packages/tui and
# packages/client while their own test lanes compile the same trees. The
# script assumes the caller built bin/loomd and bin/loom already, exactly
# as the CI jobs assume their restored artifact.
#
# The bootstrap fixtures come first, each under a different shell
# sabotage: `read` and `cat` overridden through exported bash functions,
# then a hostile `cat` ahead on PATH, so the launch lock's single-winner
# property is proved against every way the lock script's own tools can
# lie to it. The shipped daemon fixtures follow, each with the per-module
# budget its own watchdog is written against; LOOM_TEST_TIMEOUT_SECONDS
# overrides every one of them at once.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
server="$root/bin/loomd"
test_sh="$root/scripts/test.sh"
[ -x "$server" ] || { echo "e2e_client_bootstrap: no server at $server (run make server-shipment)" >&2; exit 2; }

LOOM_BOOTSTRAP_E2E_SERVER="$server" \
	bash "$test_sh" tui --match bootstrap_real_server_lifecycle_test
env 'BASH_FUNC_read%%=() { return 0; }' \
	bash "$test_sh" tui --match paused_server_dies_with_launcher_before_release_test
env 'BASH_FUNC_cat%%=() { return 0; }' \
	bash "$test_sh" tui --match launch_lock_is_single_winner_test
env 'BASH_FUNC_read%%=() { return 1; }' \
	bash "$test_sh" tui --match launch_lock_is_single_winner_test

hostile_bin="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/loom-lock-path.XXXXXX")"
trap 'rm -rf "$hostile_bin"' EXIT
printf '%s\n' '#!/bin/sh' 'exit 0' >"$hostile_bin/cat"
chmod 0755 "$hostile_bin/cat"
PATH="$hostile_bin:$PATH" bash "$test_sh" tui --match launch_lock_is_single_winner_test

# The shipped fixtures: module, default budget in seconds, and whether the
# scripted provider key is set. The two recovery fixtures never needed the
# key and the Makefile recipe never set it for them; keeping that exact
# keeps this script the same evidence CI's e2e-client-bootstrap job is.
shipped() {
	local module=$1 budget=$2
	local vars=(LOOM_BOOTSTRAP_E2E_SERVER="$server"
		LOOM_TEST_TIMEOUT_SECONDS="${LOOM_TEST_TIMEOUT_SECONDS:-$budget}")
	[ $# -lt 3 ] || vars+=(LOOM_TEST_PROVIDER_KEY="$3")
	env "${vars[@]}" bash "$test_sh" client --match "client@$module:"
}

fixture_key="loom-provider-fixture-key"
shipped tui_shipped_multiplayer_test 180 "$fixture_key"
shipped tui_shipped_live_delivery_test 180 "$fixture_key"
shipped daemon_shipped_stop_test 180 "$fixture_key"
shipped daemon_shipped_schedule_test 180 "$fixture_key"
shipped daemon_shipped_jobs_test 900 "$fixture_key"
shipped daemon_shipped_confinement_test 150 "$fixture_key"
shipped daemon_shipped_recovery_test 150
shipped daemon_shipped_identity_recovery_test 270

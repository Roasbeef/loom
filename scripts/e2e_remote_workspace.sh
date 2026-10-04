#!/usr/bin/env bash
# Join actual owner custody, mTLS chunks and filesystem effects in one emulator.
# This is a component gate; shipped two-host daemon acceptance remains separate.
set -euo pipefail
export LOOM_REMOTE_WORKSPACE_MUTATION=""
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--mutation" ] || [ "$2" != "skip-owner-receipt" ]; then
    echo "usage: scripts/e2e_remote_workspace.sh [--mutation skip-owner-receipt]" >&2
    exit 2
  fi
  export LOOM_REMOTE_WORKSPACE_MUTATION="$2"
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
for prerequisite in gleam erl erlc python3; do
  command -v "$prerequisite" >/dev/null || {
    echo "remote-workspace: required executable missing: $prerequisite" >&2
    exit 2
  }
done
fixture_ebin="$(mktemp -d "${TMPDIR:-/tmp}/loom-workspace-tls-ebin.XXXXXX")"
trap 'rm -rf "$fixture_ebin"' EXIT
cd "$root"
python3 scripts/with_timeout.py 30 -- erlc -o "$fixture_ebin" \
  packages/executor/test/executor_remote_tls_test_ffi.erl
cd "$root/packages/client"
python3 "$root/scripts/with_timeout.py" "${LOOM_BUILD_TIMEOUT_SECONDS:-1200}" -- \
  gleam build --warnings-as-errors
python3 "$root/scripts/with_timeout.py" "${LOOM_TEST_TIMEOUT_SECONDS:-90}" -- \
  erl +S 4 -pa "$fixture_ebin" build/dev/erlang/*/ebin -noshell -eval '
    try
      {ok, _} = application:ensure_all_started(client),
      nil = client@remote@workspace_integration:main(),
      erlang:halt(0, [{flush, true}])
    catch Class:Reason:Stack ->
      io:format(standard_error, "remote-workspace failed: ~p:~p~n~p~n", [Class, Reason, Stack]),
      erlang:halt(1, [{flush, true}])
    end.'

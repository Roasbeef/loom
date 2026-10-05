#!/usr/bin/env bash
# Join real owner custody and native execution across independent TLS BEAM VMs.
# This is a component integration gate with sequential, drained executor generations.
set -euo pipefail
# Named counterexamples remove one trusted-assembly invariant. They must fail
# the same assertions as the baseline and never modify production source.
export LOOM_REMOTE_OWNER_MUTATION=""
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--mutation" ]; then
    echo "usage: scripts/e2e_remote_owner.sh [--mutation bypass-registration|skip-owner-receipt]" >&2
    exit 2
  fi
  case "$2" in
    bypass-registration|skip-owner-receipt) export LOOM_REMOTE_OWNER_MUTATION="$2" ;;
    *) echo "remote-owner: unknown mutation: $2" >&2; exit 2 ;;
  esac
  echo "remote-owner: counterexample $LOOM_REMOTE_OWNER_MUTATION (nonzero required)" >&2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
for prerequisite in gleam erl erlc python3 go; do
  command -v "$prerequisite" >/dev/null || {
    echo "remote-owner: required executable missing: $prerequisite" >&2
    exit 2
  }
done
cd "$root"
python3 scripts/with_timeout.py "${LOOM_BUILD_TIMEOUT_SECONDS:-1200}" -- make sandbox
cd "$root/packages/client"
python3 "$root/scripts/with_timeout.py" "${LOOM_BUILD_TIMEOUT_SECONDS:-1200}" -- \
  gleam build --warnings-as-errors
python3 "$root/scripts/with_timeout.py" "${LOOM_TEST_TIMEOUT_SECONDS:-90}" -- \
  erl +S 4 -pa build/dev/erlang/*/ebin -noshell -eval '
    try
      {ok, _} = application:ensure_all_started(client),
      nil = client@remote@native_integration:main(),
      erlang:halt(0, [{flush, true}])
    catch Class:Reason:Stack ->
      io:format(standard_error, "remote-owner failed: ~p:~p~n~p~n", [Class, Reason, Stack]),
      erlang:halt(1, [{flush, true}])
    end.'

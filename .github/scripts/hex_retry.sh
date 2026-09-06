#!/usr/bin/env bash
# Run one command, and run it again when the only thing wrong was Hex.
#
# Gleam 1.18.1 re-resolves path dependencies against the Hex API on
# successive invocations (issue #248, gleam-lang/gleam#6244), and hosted
# runners share egress addresses, so a burst of pull requests trips Hex's
# per-address rate limit and a job dies a minute in with
#
#     The rate limit for the Hex API has been exceeded
#
# having proved nothing about the code. That sentence is the only signal
# this script acts on. Any other failure, and any success, is returned
# to the caller unchanged with the command's own exit status, so a real
# red stays red and a retry never launders a failing test.
#
# The waits are long on purpose. Hex's window is measured in minutes and
# every runner on the same address is drawing from it, so a quick retry
# only spends the budget faster. Three retries with doubling waits give
# a job about nine minutes of patience before it gives up.
#
# Usage: .github/scripts/hex_retry.sh <command> [args...]
# The command's combined output is passed through, so a step can still
# `| tee` it into a log.
set -uo pipefail

waits=(75 150 300)
attempt=0
capture="$(mktemp)"
trap 'rm -f "$capture"' EXIT

while :; do
  "$@" 2>&1 | tee "$capture"
  status=${PIPESTATUS[0]}
  if [ "$status" -eq 0 ]; then
    exit 0
  fi
  if ! grep -q 'The rate limit for the Hex API has been exceeded' "$capture"; then
    exit "$status"
  fi
  if [ "$attempt" -ge "${#waits[@]}" ]; then
    echo "hex_retry: Hex rate limit persisted across $attempt retries; giving up" >&2
    exit "$status"
  fi
  wait_s=${waits[$attempt]}
  attempt=$((attempt + 1))
  echo "hex_retry: Hex API rate limit hit; retry $attempt of ${#waits[@]} in ${wait_s}s" >&2
  sleep "$wait_s"
done

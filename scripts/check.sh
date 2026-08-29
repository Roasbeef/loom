#!/usr/bin/env bash
# Build, format-check, and test every package. CI entry point.
# Usage: scripts/check.sh [package...]  (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."

packages=(core storage session machine prompt telemetry runtime provider broker mcp tools cap codemode events client conformance lint sandbox tui)
targets=("${@:-${packages[@]}}")

# The `code_mode` description carries the capability prelude's public
# signatures, generated from `packages/cap` into a committed artifact
# (`make gen-prelude`). Drift there is not a build error anywhere else:
# the tools package compiles happily against a stale rendering and the
# only symptom is a model told about functions that no longer exist. So
# the gate runs here, with the `tools` package it belongs to, and costs
# nothing but sha256 — see scripts/gen-prelude.sh for why it is digests
# rather than a regeneration.
for pkg in "${targets[@]}"; do
  if [ "$pkg" = "tools" ]; then
    echo "==> prelude surface"
    scripts/gen-prelude.sh --check
    scripts/gen-prelude.sh --self-test
  fi
done

for pkg in "${targets[@]}"; do
  if [ "$pkg" = "sandbox" ] || [ "$pkg" = "tui" ]; then
    echo "==> $pkg (Go)"
    # -z on the listing, not a wc -l count: macOS wc pads its output with
    # spaces, so a '^0$' grep never matches and the gate fails with a
    # clean tree. gofmt -l already prints nothing when there is nothing.
    (cd "packages/$pkg" && test -z "$(gofmt -l . | tee /dev/stderr)")
    (cd "packages/$pkg" && go vet ./... && go build ./... && go test ./...)
    continue
  fi
  echo "==> $pkg"
  (cd "packages/$pkg" \
    && gleam format --check src test \
    && gleam build --warnings-as-errors \
    && gleam test)
done
# Loom's own lint runs last. R0, R2, R4 and R6 gate — each has a census of
# zero that the promotion exists to keep (packages/lint/CLAUDE.md, Staging)
# — while R1, R3 and R5 report a census that is still settling. It fails the
# build on a gating rule, or on one promoted for the run with --error.
if [ $# -eq 0 ]; then
  echo "==> lint (house rules)"
  scripts/lint.sh --quiet
fi

echo "all checks passed"

#!/usr/bin/env bash
# Build, format-check, and test every package. CI entry point.
# Usage: scripts/check.sh [package...]  (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."

packages=(core storage session machine prompt telemetry runtime provider broker tools cap codemode events client conformance lint sandbox tui)
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
    (cd "packages/$pkg" && gofmt -l . | tee /dev/stderr | wc -l | grep -q '^0$')
    (cd "packages/$pkg" && go vet ./... && go build ./... && go test ./...)
    continue
  fi
  echo "==> $pkg"
  (cd "packages/$pkg" \
    && gleam format --check src test \
    && gleam build --warnings-as-errors \
    && gleam test)
done
# Loom's own lint runs last and, for now, only reports: every rule is at
# warning level while the census settles (packages/lint/CLAUDE.md). It fails
# the build only for rules promoted with --error.
if [ $# -eq 0 ]; then
  echo "==> lint (house rules)"
  scripts/lint.sh --quiet
fi

echo "all checks passed"

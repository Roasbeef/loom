#!/usr/bin/env bash
# Build, format-check, and test every package. CI entry point.
# Usage: scripts/check.sh [package...]  (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."

packages=(core storage session machine prompt telemetry runtime provider broker mcp tools cap ext codemode events client tui conformance lint sandbox)
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
  if [ "$pkg" = "sandbox" ]; then
    echo "==> $pkg (Go)"
    # Capture the listing directly because macOS wc pads a zero count with
    # spaces. An assignment preserves gofmt's failure status under set -e,
    # while using command substitution inside test would hide that failure.
    (
      cd "packages/$pkg"
      unformatted="$(gofmt -l .)"
      if [ -n "$unformatted" ]; then
        printf '%s\n' "$unformatted" >&2
        exit 1
      fi
    )
    (cd "packages/$pkg" && go vet ./... && go build ./... && go test ./...)
    continue
  fi
  echo "==> $pkg"
  (
    cd "packages/$pkg"
    format_paths=(src test)
    if [ -d dev ]; then
      format_paths+=(dev)
    fi
    gleam format --check "${format_paths[@]}"
    gleam build --warnings-as-errors
    gleam test
  )
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

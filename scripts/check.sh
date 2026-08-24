#!/usr/bin/env bash
# Build, format-check, and test every package. CI entry point.
# Usage: scripts/check.sh [package...]  (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."

packages=(core storage session machine runtime provider broker tools events client conformance sandbox)
targets=("${@:-${packages[@]}}")

for pkg in "${targets[@]}"; do
  if [ "$pkg" = "sandbox" ]; then
    echo "==> sandbox (Go)"
    (cd packages/sandbox && gofmt -l . | tee /dev/stderr | wc -l | grep -q '^0$')
    (cd packages/sandbox && go vet ./... && go build ./... && go test ./...)
    continue
  fi
  echo "==> $pkg"
  (cd "packages/$pkg" \
    && gleam format --check src test \
    && gleam build --warnings-as-errors \
    && gleam test)
done
echo "all checks passed"

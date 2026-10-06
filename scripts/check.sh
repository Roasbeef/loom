#!/usr/bin/env bash
# Build, format-check, and test every package. CI entry point.
# Usage: scripts/check.sh [package...]  (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."

packages=(host core storage session machine prompt session_view web_view web_client telemetry runtime provider broker executor mcp lsp tools cap ext codemode events client tui conformance lint sandbox)
targets=("${@:-${packages[@]}}")

if [ $# -eq 0 ]; then
  # Exercise deadlines and visible skip reporting before trusting package gates.
  python3 scripts/with_timeout.py 20 -- \
    python3 -m unittest discover -s scripts -p 'test_*.py'
  # Release integration tests compile the native client and open private TLS
  # and signing fixtures, so they have the same budget as a package test run.
  python3 scripts/with_timeout.py 1200 -- bash scripts/check-release-update.sh
fi

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

# What the page loads besides Lustre's own runtime (the client components'
# bundle, the Tailwind stylesheet and the two bootstrap scripts) is built
# from packages/web_client into web_view's priv/static by `make gen-client`,
# which needs the network. A stale build compiles and passes every test
# while the page runs old code or misses a style, so drift is gated here,
# with the package that serves it, by digests alone. See
# scripts/web_assets.sh.
for pkg in "${targets[@]}"; do
  if [ "$pkg" = "web_view" ]; then
    echo "==> web view assets"
    scripts/web_assets.sh --check
    scripts/web_assets.sh --self-test
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
    (cd "packages/$pkg" && go vet ./... && go build ./... && \
      python3 ../../scripts/with_timeout.py 1200 -- go test -timeout 10m ./...)
    continue
  fi
  # The browser package targets JavaScript. The gate compiles it, warning
  # free, and runs its tests under whichever JavaScript runtime is on PATH
  # (scripts/web_client_test.sh, which prints a SKIP the census refuses when
  # there is none). The tests cover the components' decisions; what its
  # elements render is checked by web_view's rendered-output tests, its
  # bundle by the asset gate and its one JavaScript file by `make lint`.
  if [ "$pkg" = "web_client" ]; then
    echo "==> $pkg (JavaScript)"
    (cd "packages/$pkg" && gleam format --check src test && gleam build --warnings-as-errors)
    scripts/web_client_test.sh
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
    bash ../../scripts/test.sh "$pkg"
  )
  # JavaScript admits NaN and infinities as terms; BEAM cannot construct them.
  # Keep the portable report constructor regression in the normal core gate.
  # This supplemental target retains existing u64 precision warnings; the
  # Erlang build above remains warning-free and authoritative for u64 custody.
  if [ "$pkg" = "core" ]; then
    (
      cd packages/core
      python3 ../../scripts/with_timeout.py 120 -- gleam build --target javascript
      python3 ../../scripts/with_timeout.py 30 -- node test/report_value_finite_test.mjs
      python3 ../../scripts/with_timeout.py 30 -- node test/command_rewrite_test.mjs
    )
  fi
  # This fixture checks the work removed by leaf memoisation and the provider
  # worker's copy boundary in a disposable VM, separate from correctness tests.
  if [ "$pkg" = "runtime" ]; then
    python3 scripts/with_timeout.py 30 -- escript \
      scripts/projection_cache_bench.escript packages/runtime/build/dev/erlang \
      --expect-cached
  fi
done
# Loom's own lint runs last. R0, R2, R4 and R6 gate — each has a census of
# zero that the promotion exists to keep (packages/lint/CLAUDE.md, Staging)
# — while R1, R3 and R5 report a census that is still settling. It fails the
# build on a gating rule, or on one promoted for the run with --error.
if [ $# -eq 0 ]; then
  echo "==> lint (house rules)"
  scripts/lint.sh --quiet
fi

# The configuration-reference gate's own fixtures. The gate itself runs under
# `make doc-check`; this proves its extraction still catches each way a key can
# go missing, which a passing doc-check on its own would not.
if [ $# -eq 0 ]; then
  echo "==> configuration-key gate self-test"
  scripts/config_keys.sh --self-test
fi

echo "all checks passed"

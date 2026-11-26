#!/usr/bin/env bash
# gantry_lane.sh — run one of Loom's Linux CI lanes as a Gantry action.
#
# Usage: scripts/gantry_lane.sh LANE
#        scripts/gantry_lane.sh match PACKAGE PATTERN...
#        scripts/gantry_lane.sh bake OUT
#
# gantry.json at the repository root names one action per lane, and every
# action runs this script with its lane's name. The lanes are the Linux jobs
# of .github/workflows/ci.yml, cut the same way, and each runs the same
# command as its job. docs/gantry.md has the lane table, the measured times
# and the failures that remain.
#
# Why a script rather than a command in the manifest. A Gantry action starts
# in a container that differs from a GitHub runner in four ways, and every
# lane needs the same answer to them, so the answer lives in one place:
#
# - The root filesystem is read-only and only /work (the checkout) and /tmp
#   are writable. HOME, TMPDIR and every cache are pointed under /work. TMPDIR
#   is not /tmp because Loom's jail replaces /tmp with its own scratch tmpfs,
#   so a path a test made there is not the path the jailed program sees.
# - There is no network. The action image carries a Hex and Go module cache
#   and each package's resolved build/packages tree, made when the image was
#   built, and they are copied in before anything compiles. A lane that
#   needs a dependency the image lacks fails to resolve it, which is the
#   signal to rebuild the image, not to retry.
# - Nothing is restored from an upstream job. GitHub's deps job builds
#   bin/, the helper, the server shipment and the code-mode seed once and
#   hands them on as an artifact. A Gantry output is a list of regular files,
#   and the shipment and the seed are directory trees, so each lane builds
#   what it needs itself.
# - There is no delegated cgroup v2, so the helper reports partial
#   enforcement and the tests that demand every layer fail. That is a
#   property of the worker, and this script does not hide it.
set -euo pipefail
cd "$(dirname "$0")/.."

lane="${1:?usage: scripts/gantry_lane.sh LANE}"
shift
root=$(pwd)

# The writable places, all under the workspace the action owns.
export HOME="$root/.gantry/home"
export TMPDIR="$root/.gantry/tmp"
export XDG_CACHE_HOME="$root/.gantry/cache"
export GOCACHE="$root/.gantry/gocache"
export REBAR_CACHE_DIR="$XDG_CACHE_HOME/rebar3"
mkdir -p "$HOME" "$TMPDIR" "$GOCACHE"

# The offline caches the action image was built with. Gleam writes into its
# cache, so that one is copied rather than read in place; the Go module cache
# is only read. Outside the image these do not exist and the host's own
# caches are used.
if [ -d /opt/loom-cache ]; then
  cp -R /opt/loom-cache/. "$XDG_CACHE_HOME"
fi
if [ -d /opt/loom-gomod ]; then
  export GOMODCACHE=/opt/loom-gomod GOFLAGS=-mod=mod
fi
if [ -d /opt/loom-seed/packages ]; then
  cp -R /opt/loom-seed/packages/. packages/
fi
# The language-server fixture's Rust toolchain, installed into the image by
# .github/scripts/install_rust_analyzer.sh. The fixture grants ~/.rustup and
# ~/.cargo/registry to the jail and runs ~/.cargo/bin/rust-analyzer, so the
# toolchain has to appear at rustup's default layout under this HOME, and CI
# exports the same three variables after installing it.
if [ -d /opt/loom-rusthome ]; then
  ln -sfn /opt/loom-rusthome/.rustup "$HOME/.rustup"
  ln -sfn /opt/loom-rusthome/.cargo "$HOME/.cargo"
  export RUSTUP_HOME="$HOME/.rustup" CARGO_HOME="$HOME/.cargo"
  export PATH="$CARGO_HOME/bin:$PATH"
fi

# The code-mode seed's resolved packages, which scripts/codemode_seed.sh
# needs to make a seed with no network.
if [ -d /opt/loom-codemode-seed/packages ]; then
  export LOOM_CODEMODE_SEED_PACKAGES=/opt/loom-codemode-seed/packages
fi

# Each package's suite takes its deadline from test.sh. A lane of one package
# reports a hang through that deadline before Gantry's timeout kills the
# action; a lane of several can reach Gantry's timeout first, which is why the
# condensed log below is flushed line by line.
#
# Every bucket in CI sets LOOM_EVOLUTION_E2E. CI also sets
# LOOM_BOOTSTRAP_E2E_SERVER for every bucket; here only the lanes that build a
# server shipment set it, which covers its only readers, the client and TUI
# suites.
export LOOM_EVOLUTION_E2E=1

# The public dummy credential the scripted provider fixture expects, which
# ci.yml sets for every job; the shipped fixtures assert it before they run.
export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key

# The one test that needs the Hex registry, the language-server manager's
# fresh-workspace preparation, skips when this is set, since an action has
# no network. No other test reads it.
export LOOM_TEST_OFFLINE=1

# Each package's EUnit modules run eight at a time on its emulator, the
# setting Loom's own signoff gate uses (scripts/signoff.sh). scripts/test.sh
# holds back the modules scripts/serial-tests declares and runs them alone
# afterwards, and docs/design-notes/parallel-tests.md has the measurements
# behind eight. Run one at a time, a lane's tests used one to three of its
# twelve cores, waiting on fixtures far more than computing.
export LOOM_TEST_PARALLEL="${LOOM_TEST_PARALLEL:-8}"

# The client package is the critical path, and its suite still gains from
# more concurrency than eight, where other packages' do not:
# docs/design-notes/parallel-tests.md measured it at 166 s with eight and
# 126 s with sixteen, while storage fails at sixteen. scripts/check.sh reads
# this for the client package alone.
export LOOM_CLIENT_TEST_PARALLEL="${LOOM_CLIENT_TEST_PARALLEL:-64}"

# The warm build. Compiling is most of a lane's time: every package has its
# own build/, so each one compiles its dependencies again, and a client lane
# compiles `client` twice, once for the server shipment and once for its
# tests. The action image carries that build output for one Loom revision,
# made by the `bake` lane below, as a tar per package build/ plus the root
# build/ (shipments, the shipment cache, the seed) and the Go build cache.
#
# A lane copies in the parts it uses before compiling, and Gleam's
# incremental build then recompiles only what changed since the image's
# revision: it compares content, not timestamps, so the newer timestamps of
# a later commit's tree cost nothing. The parts are used only when the
# dependency lockfiles match the ones they were built from; otherwise the
# lane builds from nothing, exactly as without them.
warm=/opt/loom-warm

# The lockfile set the warm build is valid for: every gleam.toml,
# manifest.toml and go.sum outside build output, and the seed's lock.
build_key() {
  {
    find packages -name build -prune -o \
      \( -name gleam.toml -o -name manifest.toml -o -name go.sum \) -print |
      LC_ALL=C sort | xargs sha256sum
    sha256sum scripts/codemode-seed-manifest.toml
  } | sha256sum | cut -c1-64
}

# Copies in the warm build for the named packages, with the root build/ and
# the Go cache, when the image has one for this lockfile set.
warm_for() {
  local started=$SECONDS part
  if [ ! -f "$warm/key" ] || [ "$(cat "$warm/key")" != "$(build_key)" ]; then
    echo "==> gantry: no warm build for these lockfiles; building from nothing"
    return 0
  fi
  for part in root go "$@"; do
    if [ -f "$warm/$part.tar" ]; then
      tar -xf "$warm/$part.tar"
    fi
  done
  echo "==> gantry: warm build ($*) in $((SECONDS - started)) s"
}

# The packages each kind of preparation compiles.
binaries_parts="pkg-tui"
server_parts="pkg-tui pkg-client pkg-codemode"

# What GitHub's deps job builds, for the lanes that restore it there.
#
# The build runs with only the variables it reads. scripts/shipment.py reuses
# a shipment only when a digest of the whole environment matches the one it
# was cached under, and the image's bake and an action differ in variables
# no build reads (the container's hostname, the test settings above), which
# made every action export the TUI shipment again from nothing. With the
# same short list in both, a shipment the image already holds is reused.
prepare() {
  local started=$SECONDS
  echo "==> gantry: prepare ($*)"
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" REBAR_CACHE_DIR="$REBAR_CACHE_DIR" \
    GOCACHE="$GOCACHE" GOMODCACHE="${GOMODCACHE:-}" GOFLAGS="${GOFLAGS:-}" \
    LOOM_CODEMODE_SEED_PACKAGES="${LOOM_CODEMODE_SEED_PACKAGES:-}" \
    make "$@"
  echo "==> gantry: prepared in $((SECONDS - started)) s"
}

# The shipment and the seed, for the lanes that run the shipped fixtures and
# the code-mode builds. The server shipment depends on the seed.
prepare_server() {
  prepare binaries server-shipment
  export LOOM_BOOTSTRAP_E2E_SERVER="$root/bin/loomd"
}

# One lane's commands, chosen by name. Its output goes to the lane log, not
# straight to the action's log; see the end of the script.
run_lane() {
# The pipeline below runs this function with errexit off, which the shell
# would otherwise carry into it, so a failed preparation would let the
# lane go on to test against what was not built. Turn it back on here.
set -e
case "$lane" in

# The static job: the script self-tests, then the four tree-wide gates.
static)
  warm_for pkg-lint
  python3 scripts/with_timeout.py 60 -- \
    python3 -m unittest discover -s scripts -p 'test_*.py'
  make fmt-check
  make prelude-check
  make lint
  make doc-check
  ;;

# The runtime-storage-session-events bucket.
mid)
  warm_for $binaries_parts pkg-runtime pkg-storage pkg-session pkg-events
  prepare binaries
  bash scripts/check.sh runtime storage session events
  ;;

# CI's fast bucket, cut in three. check.sh stops at the first package that
# fails, so one red package in a single action hides every package after it;
# three actions report three verdicts. The cut keeps the Go helper and the
# VMM, which build with a different toolchain, apart from the Gleam packages.
fast-1)
  warm_for $binaries_parts pkg-host pkg-core pkg-json_codec pkg-machine \
    pkg-prompt pkg-statem pkg-statem_parallel pkg-evalstat pkg-gepa \
    pkg-project pkg-session_view pkg-web_view pkg-web_client \
    pkg-web_mermaid pkg-telemetry
  prepare binaries
  bash scripts/check.sh host core json_codec machine prompt statem \
    statem_parallel evalstat gepa project session_view web_view web_client \
    web_mermaid telemetry
  ;;
# The code-mode package's end-to-end tests need the seed, and the TUI's
# real-server lifecycle test needs bin/loomd; without them both skip, the
# second without a word, and the lane would pass having run neither.
fast-2)
  warm_for $server_parts pkg-provider pkg-broker pkg-executor pkg-mcp \
    pkg-lsp pkg-tools pkg-cap pkg-ext pkg-harness pkg-lint
  prepare_server
  bash scripts/check.sh provider broker executor mcp lsp tools cap ext \
    codemode harness tui lint
  ;;
fast-3)
  warm_for $binaries_parts
  prepare binaries
  bash scripts/check.sh sandbox vmm
  ;;

# The language-server fixtures that rename, build a code-mode monorepo or
# read SQL need the seed, as in fast-2.
conformance)
  warm_for $server_parts pkg-conformance
  prepare_server
  bash scripts/check.sh conformance
  ;;

# The evaluation instrument needs the jail and the repository's history. Its
# action declares a shallow .git, so the mined tasks that name older commits
# skip, as they would on a depth-1 checkout.
eval)
  warm_for $server_parts pkg-eval
  prepare_server
  bash scripts/check.sh eval
  ;;

client-1 | client-2 | client-3)
  warm_for $server_parts
  prepare_server
  LOOM_CLIENT_TEST_SHARD="${lane#client-}/3" bash scripts/check.sh client
  ;;

# Not a CI lane: a few named tests of one package, for an ad hoc action that
# checks a fix or a fleet change without running a whole shard. Each pattern
# is a scripts/test.sh --match pattern, and every one runs even after one
# fails, so the action's log answers for all of them.
match)
  package="${1:?usage: scripts/gantry_lane.sh match PACKAGE PATTERN...}"
  shift
  warm_for $server_parts "pkg-$package"
  prepare_server
  failed=0
  for pattern in "$@"; do
    bash scripts/test.sh "$package" --match "$pattern" || failed=1
  done
  [ "$failed" -eq 0 ]
  ;;

# Not a CI lane: the image build runs this to make the warm build. It
# prepares like a server lane, compiles every Gleam package for the targets
# its lane compiles, and writes the parts warm_for copies, with the key.
bake)
  out="${1:?usage: scripts/gantry_lane.sh bake OUT}"
  prepare_server
  for toml in packages/*/gleam.toml; do
    package=$(dirname "$toml")
    # A package that does not compile at this revision still leaves its
    # dependencies built, and the lane that tests it reports the error.
    (cd "$package" && gleam build --warnings-as-errors) ||
      echo "==> gantry: bake: $package does not compile; its build is partial"
  done
  for package in json_codec evalstat gepa project web_client web_mermaid; do
    (cd "packages/$package" && gleam build --target javascript)
  done
  mkdir -p "$out"
  tar -cf "$out/root.tar" build
  tar -cf "$out/go.tar" .gantry/gocache
  for dir in packages/*/build; do
    package=$(basename "$(dirname "$dir")")
    tar -cf "$out/pkg-$package.tar" "$dir"
  done
  build_key > "$out/key"
  du -sh "$out"/*.tar | sort -h | tail -8
  ;;

*)
  echo "gantry_lane.sh: unknown lane: $lane" >&2
  exit 2
  ;;
esac
}

# Gantry keeps only the first 64 KiB of an action's output, and a client
# shard writes several megabytes, so a failure late in a lane would be cut
# from the only log anyone can read. The whole output goes to a file in the
# workspace instead, and the action's log carries what a reader needs to
# act: each section header, each failing test with the error that follows
# it, every SKIP, the suites' totals, and, when the lane fails, its last
# lines. The file is gone with the workspace; rerun the lane locally, or
# under `docker run`, for the rest.
log="$root/.gantry/lane.log"
started=$SECONDS
set +e
run_lane "$@" 2>&1 | tee "$log" | awk '
  # A failing test, or a compiler or Go failure, opens a block of the lines
  # that explain it. The block is bounded so one runaway report cannot use
  # the budget meant for the failures after it.
  /\*(failed|timed out|aborted)\*|^error|^--- FAIL|^FAIL|^panic:/ { block = 16 }
  block > 0 { print; fflush(); block--; next }
  /^==> |SKIP |Failed: [0-9]|tests passed|test command finished|^ok  / { print; fflush() }
'
status=${PIPESTATUS[0]}
set -e
if [ "$status" -ne 0 ]; then
  echo "==> gantry: the last lines of the lane log"
  tail -n 40 "$log"
fi
echo "==> gantry: lane $lane exited $status after $((SECONDS - started)) s"
exit "$status"

#!/usr/bin/env bash
# Prepare the code-mode build seed: the pre-resolved package cache every
# hermetic program build is cloned from (packages/codemode/src/codemode/
# seed.gleam explains why one is needed).
#
# Two steps, and only this script is ever allowed the network: lay the seed
# project out from the compile service's own dependency table, then build it
# online so `build/packages` and a resolved `manifest.toml` exist.
set -euo pipefail
cd "$(dirname "$0")/.."

seed=build/codemode-seed

output=$(cd packages/codemode && gleam run -m codemode/seed 2>&1) || {
  echo "$output" >&2
  echo "codemode seed: layout failed" >&2
  exit 1
}
echo "$output"
case "$output" in
  *LOOM_SEED_LAID_OUT*) ;;
  *) echo "codemode seed: layout did not complete" >&2; exit 1 ;;
esac

# Built twice on purpose. Gleam writes a local dependency's config
# fingerprint into build/packages during resolution, and a seed missing it
# is treated as stale by the *next* build — which then re-resolves, which
# needs the network. The second build settles it, so a clone of the seed
# builds offline. `make e2e-codemode` proves that in a network-off jail.
(cd "$seed" && gleam build && gleam build)

# Prove it offline, here, rather than discovering it in a jail later. A
# clone of the seed is what every build root actually is, so a clone that
# needs the network is a broken seed. When the kernel will not give us a
# network namespace to check in, say so — never let an unchecked seed read
# as a checked one.
probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
cp -R "$seed/." "$probe/"
rm -rf "$probe/build/dev/erlang/loom_codemode_program"
if unshare -rn true 2>/dev/null; then
  if (cd "$probe" && unshare -rn env PATH="$PATH" gleam build \
        --warnings-as-errors >"$probe/log" 2>&1); then
    echo "codemode seed: offline clone build VERIFIED (no network namespace)"
  else
    sed 's/^/    /' "$probe/log" >&2
    echo "codemode seed: a clone of the seed could NOT build offline" >&2
    exit 1
  fi
else
  echo "codemode seed: offline build NOT verified here" \
       "(this kernel refuses an unprivileged network namespace);" \
       "make e2e-codemode still proves it in the jail"
fi

echo "codemode seed ready: $seed"

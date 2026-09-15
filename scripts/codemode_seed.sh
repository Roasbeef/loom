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

# The seed is a release input, including every transitive Hex dependency.
# Recreating its directory must not turn a source-identical build into a new
# dependency resolution when a compatible version is published later.
cp scripts/codemode-seed-manifest.toml "$seed/manifest.toml"

# Generated source timestamps become part of Gleam's cache metadata. Release
# builds use the source commit epoch before compiling the newly laid-out seed.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  python3 - "$seed" <<'PYTIME'
import os
from pathlib import Path
import sys
epoch = int(os.environ['SOURCE_DATE_EPOCH'])
for path in Path(sys.argv[1]).rglob('*'):
    if path.is_file():
        os.utime(path, (epoch, epoch), follow_symlinks=False)
PYTIME
fi

# Built until it stops resolving. Gleam writes *one* local dependency's
# config fingerprint into build/packages per resolution pass, and a seed
# missing any of them is treated as stale by the next build — which then
# re-resolves, which needs the network. So a seed vendoring two packages
# needs three passes before a clone of it builds offline, and a hard-coded
# count would silently break the next time something is vendored. Loop on
# the observable condition instead: build until Gleam stops announcing a
# resolution. The bound is a guard against an infinite loop, not an
# expectation. `make e2e-codemode` proves the result in a network-off jail.
settled=0
for _attempt in 1 2 3 4 5 6; do
  if ! log=$(cd "$seed" && gleam build 2>&1); then
    printf '%s\n' "$log" >&2
    echo "codemode seed: the seed project did not build" >&2
    exit 1
  fi
  if ! cmp -s scripts/codemode-seed-manifest.toml "$seed/manifest.toml"; then
    echo "codemode seed: dependency resolution changed the committed seed lock" >&2
    echo "Review the generated manifest and update scripts/codemode-seed-manifest.toml explicitly." >&2
    exit 1
  fi
  case "$log" in
    *"Resolving versions"*) ;;
    *) settled=1; break ;;
  esac
done
if [ "$settled" -ne 1 ]; then
  echo "codemode seed: still re-resolving after six builds; a clone of this" >&2
  echo "codemode seed: seed would reach Hex, so it is not usable offline" >&2
  exit 1
fi

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

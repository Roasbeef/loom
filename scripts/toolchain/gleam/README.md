# Maintained Gleam patches

Ordinary Loom builds use released Gleam. The SQLite repair is distributed
through `sqlight_loom` and `esqlite_loom` on Hex, where stock Gleam reads the
native Rebar build metadata. The compiler below remains the reproducible
release toolchain; its deterministic-cache patch is not a prerequisite for
`make update`.

`deterministic-cache.patch` is the source change from compiler commit
`4c7a9605be04dbcd8bdcad76c29a5a789cdf9311`. It applies to Gleam 1.18.1 after the
existing `860f8224ddb7e1ecb7f983fb622ede12466225e5` path-dependency fix. The
patch is maintained here; it has not been submitted or accepted upstream.

The compiler serializes randomized maps and sets into module caches, source
line mappings, diagnostic names and the local package manifest. Imported type
IDs also depend on unordered traversal during cache loading. The patch orders
those serialized collections and traversals without changing the serde wire
shapes or replacing randomized runtime hash tables. It includes regressions
for shared generic IDs, inline parameter lists and labelled decision trees,
cached diagnostic names, and package state.

CI and both Docker recipes apply this file after the upstream patch list, using
`git apply` so a compiler upgrade that no longer matches fails explicitly.
The compiler-binary and compiled-module cache keys include the local patch
hash. `check_cache.py` verifies the installed compiler, even on a CI cache hit:

```sh
python3 scripts/toolchain/gleam/check_cache.py --compiler /path/to/gleam --runs 12
```

The fixtures have no downloaded dependencies. Their package/module names select
the compiler's existing standard-library inlining path. Each cold-build series
uses fixed source bytes, paths and modification times. Stock Gleam 1.18.1 and
upstream main at `3b046ec5a7417dfd83dbd4a9cc46f7d4aed62cf1` each produced twelve
distinct hashes in twelve builds; the patched release produced one per fixture.
The patch passed 3,498 compiler-core and 123 CLI tests. The maintained release
uses bincode; upstream main now uses bitcode, so the patch is not advertised as
a tested main-branch fix.

Before this pin was committed, two clean Linux builds of Loom
`21da91d8992cdc02e50ec6d6631beee88b47d236` with the patched compiler produced
identical complete server, bundled-client and slim-client archives, manifests
and checksum files, and passed the release smoke tests. Those builds used one
host and image. The release-candidate workflow verifies complete artifacts on
two separate hosted runners; neither the compiler fixture nor a same-host
comparison substitutes for that result.

Remove the cache patch only after the pinned compiler release includes
equivalent behavior and the fixture and complete-release comparison both pass.
No production release signing is enabled by this pin.

## Native Git dependencies

`native-git-dependencies.patch` lets a pinned Git package declare
`build_tool = "rebar3"` in its `gleam.toml`. The default remains Gleam; unknown
build tools are errors. Native path dependencies are refused because their
cached Rebar output has no immutable source identity. Changing a Git commit
retires the cached package even when its version stays the same.

This patch supported the former esqlite Git pin. The production dependency
now arrives through Hex, so ordinary builds no longer exercise this path.
The maintained compiler still carries the patch and its regression fixture.
See [ADR-002](../../../docs/adr/002-sqlite-binding.md) for the ownership bug
and the move to Hex distribution.

CI release jobs and both Docker recipes build the maintained compiler from
the release tag, apply the upstream path-dependency fix, then apply every
local patch in filename order. To reproduce that release toolchain locally:

```sh
git clone --branch v1.18.1 https://github.com/gleam-lang/gleam.git /path/to/gleam-source
git -C /path/to/gleam-source fetch origin 860f8224ddb7e1ecb7f983fb622ede12466225e5
git -C /path/to/gleam-source cherry-pick -X ours 860f8224ddb7e1ecb7f983fb622ede12466225e5
for patch in "$PWD"/scripts/toolchain/gleam/*.patch; do
  git -C /path/to/gleam-source apply "$patch"
done
cargo build --manifest-path /path/to/gleam-source/Cargo.toml --release --package gleam --bin gleam
export PATH="/path/to/gleam-source/target/release:$PATH"
python3 scripts/toolchain/gleam/check_cache.py --runs 4
python3 scripts/toolchain/gleam/check_native_git.py
```

The native fixture builds a small Rebar dependency through a transitive Gleam
wrapper, checks a clean rebuild, proves that an unchanged pin ignores a newer
repository commit, and changes the pin without changing the version to catch
stale native artifacts. It uses local Git repositories and no Hex downloads.
CI runs it on compiler-cache hits as well as fresh compiler builds.


When retiring the Git pin in favor of a same-version Hex release, rebuild from
a clean checkout. The compiler's existing Hex freshness check compares version
alone and can otherwise retain the former Git package's build output. This
patch fixes changed Git commits; it does not repair that separate transition.

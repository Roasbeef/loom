# Maintained Gleam cache patch

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

Ordinary development can still use the released compiler. Its cache bytes need
not match a release candidate. Remove this patch only after the pinned compiler
release includes equivalent behavior and the fixture and complete-release
comparison both pass. No production release signing is enabled by this pin.

# Maintained Gleam patches

Ordinary Loom builds use released Gleam. The SQLite repair is distributed
through `sqlight_loom` and `esqlite_loom` on Hex, where stock Gleam reads the
native Rebar build metadata. The compiler below remains the reproducible
release toolchain; its deterministic-cache patch is not a prerequisite for
`make update`.

The pinned release is **Gleam 1.19.0**, the final release (tag commit
`904f81cc85f3bdc03fc3d0a6695055ce7ce4a64c`). Both maintained patches apply
to it: `deterministic-cache.patch` needed only its CHANGELOG hunk
re-seated (the code hunks applied cleanly), and
`native-git-dependencies.patch` applied unchanged. The pin in
`.github/workflows/ci.yml`, `nightly.yml`, `release.yml` and both Docker
recipes is therefore the whole change. The tag carries
`860f8224ddb7e1ecb7f983fb622ede12466225e5` (gleam-lang/gleam#6246, the
path-dependency freshness fix for issue #248), which 1.18.1 builds took as a
cherry-picked commit, so no upstream commit is cherry-picked any more.

## Deterministic caches

`deterministic-cache.patch` is the source change from compiler commit
`3a9f1f2dfad4c9eae9e46cf43f00355889fb7542`, the 1.18.1 patch (formerly
`4c7a9605be04dbcd8bdcad76c29a5a789cdf9311`) rebased onto the v1.19.0 tag;
the only hunk that did not apply to the final tag was the CHANGELOG entry
whose context (`## 1.19.0-rc2`) had moved, so it was re-seated above
`## 1.19.0 - 2026-10-05`. The patch is maintained here; it has not been
submitted or accepted upstream.

The compiler serializes randomized maps and sets into module caches, source
line mappings, diagnostic names and the local package manifest. Imported type
IDs also depend on unordered traversal during cache loading. The patch orders
those serialized collections and traversals without changing the serde wire
shapes or replacing randomized runtime hash tables. It includes regressions
for equivalent maps and sets, type IDs assigned while loading a cache,
cached diagnostic names, and package state.

Gleam 1.19 changed three things the patch touched:

- The inlining pass was removed from the compiler, so the serialized inline
  parameter list and the decision-tree label map (`RuntimeCheck::Variant`'s
  `labels`) no longer reach any cache. Their ordering and the inline-function
  regression test were dropped.
- `LineNumbers` moved into the new `src-span` crate, which does not depend on
  `compiler-core`, so it carries its own ordered serializer for `mapping`.
- The cache format moved from bincode to bitcode. Bitcode writes maps in the
  order serde gives them, as bincode did, so every remaining ordering is
  still needed; the diagnostic-name test now encodes with bitcode.

Record labels in the reference index are now keyed by `LabelKey` and
`LabelOwner` instead of `RecordLabel`; both derive `Ord` for the same reason
`RecordLabel` did.

CI and both Docker recipes apply every patch in filename order with
`git apply`, so a compiler upgrade that no longer matches fails explicitly.
The compiler-binary and compiled-module cache keys include the local patch
hash. `check_cache.py` verifies the installed compiler, even on a CI cache hit:

```sh
python3 scripts/toolchain/gleam/check_cache.py --compiler /path/to/gleam --runs 12
```

The fixtures have no downloaded dependencies. They were written to reach the
standard-library inlining path, which 1.19 no longer has; they still exercise
labelled fields, labelled arguments and the reference index. Each cold-build
series uses fixed source bytes, paths and modification times. On macOS
(aarch64) with OTP 29.0.5, twelve cold builds per fixture against the final
v1.19.0 tag gave:

| Compiler | `parameters` | `labels` |
| --- | --- | --- |
| stock 1.19.0 | 11 distinct hashes | 12 distinct hashes |
| patched 1.19.0 | 1 | 1 |

Stock 1.18.1, upstream main at `3b046ec5a7417dfd83dbd4a9cc46f7d4aed62cf1`,
and the 1.19.0-rc2 tag had each produced twelve distinct hashes in twelve
builds as well. On a real package the difference covers every module:
six cold builds of `packages/core` (50 `.cache` files, its own modules and
its Hex dependencies) gave six distinct digests for each of the 50 files
with the stock rc2 compiler, and one per file with the patched compiler.

The stock-versus-patched comparison was re-run on the final v1.19.0 tag
(2026-10-05, macOS aarch64, OTP 29.0.5): stock still fails the fixture and
the patched compiler still passes, so the patch is carried forward. The
patched compiler also passed its upstream test suites on the final tag
(compiler-core, CLI, src-span, cargo test exit 0).

Before the 1.18.1 pin was committed, two clean Linux builds of Loom
`21da91d8992cdc02e50ec6d6631beee88b47d236` with the patched compiler produced
identical complete server, bundled-client and slim-client archives, manifests
and checksum files, and passed the release smoke tests. That comparison has
not been repeated on 1.19.0. The release workflow verifies
complete artifacts on two separate hosted runners; neither the compiler
fixture nor a same-host comparison substitutes for that result.

Remove the cache patch only after the pinned compiler release includes
equivalent behavior and the fixture and complete-release comparison both pass.
No production release signing is enabled by this pin.

## Native Git dependencies

`native-git-dependencies.patch` lets a pinned Git package declare
`build_tool = "rebar3"` in its `gleam.toml`. The default remains Gleam; unknown
build tools are errors. Native path dependencies are refused because their
cached Rebar output has no immutable source identity. Changing a Git commit
retires the cached package even when its version stays the same.

Compiler-owned fetches run automatic maintenance synchronously with
`gc.autoDetach=false` and `maintenance.autoDetach=false`. Rebar builds copy
the source repository, including `.git` for native hooks. A detached GC can
otherwise remove a temporary reverse index after the copy enumerates it.
Waiting for maintenance closes that race while retaining both maintenance
and the repository metadata.

On 1.19.0-rc2 the patch needed two adjustments: a new upstream licence test
sits where its config test was appended, and `Error::FileIo` now carries a
`cause: FileIoCause` instead of `err: Option<String>`; the patch applied to
the final v1.19.0 tag unchanged (`git apply --check` clean). Stock 1.19.0 still
fails `check_native_git.py` (the package is recorded with
`build_tools = ["gleam"]`), so the patch is still required for that path.

This patch supported the former esqlite Git pin. The production dependency
now arrives through Hex, so ordinary builds no longer exercise this path.
The maintained compiler still carries the patch and its regression fixture.
See [ADR-002](../../../docs/adr/002-sqlite-binding.md) for the ownership bug
and the move to Hex distribution.

CI release jobs and both Docker recipes build the maintained compiler from
the release tag, then apply every local patch in filename order. To
reproduce that release toolchain locally:

```sh
git clone --branch v1.19.0 https://github.com/gleam-lang/gleam.git /path/to/gleam-source
for patch in "$PWD"/scripts/toolchain/gleam/*.patch; do
  git -C /path/to/gleam-source apply "$patch"
done
cargo build --manifest-path /path/to/gleam-source/Cargo.toml --release --package gleam --bin gleam
export PATH="/path/to/gleam-source/target/release:$PATH"
python3 scripts/toolchain/gleam/check_cache.py --runs 4
python3 scripts/toolchain/gleam/check_native_git.py
```

Inside a Loom session, `cargo` reports "no default toolchain" even though the
operator has one. The jail sets `HOME` to the session's tool home
(`<workspace>/.codemode/home`), the rustup proxy looks for `$HOME/.rustup`, and
finds nothing. The operator's `~/.rustup` is readable under the default
`HostReads` policy, so point rustup at it for the one command, and keep
`CARGO_HOME` out of `~/.cargo`, which holds `credentials.toml`:

```sh
RUSTUP_HOME=/Users/you/.rustup CARGO_HOME="$TMPDIR/cargo-home" \
  cargo build --manifest-path /path/to/gleam-source/Cargo.toml --release --package gleam --bin gleam
```

Use the operator's real home, not `$HOME`, which is the tool home there. The
session cannot write `~/.rustup`, so a command that needs to install a
toolchain or component fails with a permission error; run it from an unjailed
shell. The server does not derive `RUSTUP_HOME`
because it would have to become a server-owned environment name and join the
base environment allowlist, a policy-surface change for a convenience. An operator who wants it standing
can add `[tools.set]` with `RUSTUP_HOME = "/Users/you/.rustup"` to `loom.toml`;
the catalogue refuses that table only for the five server-owned names.

The native fixture builds a small Rebar dependency through a transitive Gleam
wrapper, checks a clean rebuild, proves that an unchanged pin ignores a newer
repository commit, and changes the pin without changing the version to catch
stale native artifacts. It uses local Git repositories and no Hex downloads.
Its Rebar hook reads `.git`, and two valid object packs force real automatic
maintenance during the updated-pin fetch. Git Trace2 must show the repack
finishing before its owning fetch exits; the fixture does not depend on
catching a temporary file while it disappears.
CI runs it on compiler-cache hits as well as fresh compiler builds.

When retiring the Git pin in favor of a same-version Hex release, rebuild from
a clean checkout. The compiler's existing Hex freshness check compares version
alone and can otherwise retain the former Git package's build output. This
patch fixes changed Git commits; it does not repair that separate transition.

## Formatter

The 1.19 formatter moves a long constant's value onto its own indented line
(`const name =` then the value), which 1.18.1 reverses. The tree is formatted
for 1.19, so `make fmt-check` needs a 1.19 compiler, although 1.18.1 still
compiles every package; the `gleam >= 1.18.0` floors are unchanged because no
package uses a 1.19 language feature.

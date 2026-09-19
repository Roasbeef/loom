# ADR-002 — SQLite binding: sqlight

**Status**: accepted (with verification gate) · **Date**: 2026-08-24 ·
**Spec ref**: Part 7

## Decision

The `storage` SQLite backend uses the `sqlight` Hex package (Gleam bindings
over an Erlang SQLite NIF) rather than a custom NIF.

The three capabilities the spec names are covered without native code of
our own:

- **BLOB parameters** — sqlight's value type includes blobs (payloads are
  stored as BLOB columns).
- **`EXPLAIN` access** — sqlight executes arbitrary SQL, so the CI query-
  plan assertions run `EXPLAIN QUERY PLAN` like any other statement.
- **Busy handling** — `PRAGMA busy_timeout = N` via SQL at connection open.
  We do not need a custom busy callback: the writer lease plus the
  single-StorageWriter design means intra-node contention does not exist,
  and cross-process contention is a defense-in-depth path where a timeout
  is acceptable.

## Why

A custom NIF is a large, security-sensitive C surface for capabilities we
can reach through SQL. sqlight is maintained by the Gleam core team's
orbit, and every requirement reduces to "can we run this statement with
these parameter types," which it satisfies.

## Verification gate

WP-B's exit criteria are the real test: if the conformance suite or the
`EXPLAIN QUERY PLAN` assertions hit a binding limitation (parameter types,
pragma behavior, `BEGIN IMMEDIATE` semantics), the implementer records the
gap here and we escalate to a thin Erlang shim over the same NIF before
considering a custom one.

## Addendum: private query statements need explicit retirement

*Added 2026-09-06. The binding choice is unchanged. Adoption of the
dependency repair described below is pending.*

The daemon soak found 192 additional database and WAL file descriptors
after 16 measured cycles. The shared-history coordinator called
`sqlight.close` for every source, but `esqlite3:q` left its prepared
statements to the resource destructor. SQLite's `close_v2` can return
success while those statements retain the native connection. The result
is garbage-collection-dependent retention, not evidence by itself of a
permanent leak. See SQLite's [close contract](https://www.sqlite.org/c3ref/close.html).

**Queries must finalize the statements they privately own before returning.**
The repair belongs in `esqlite3:q`, below sqlight and the generated query
layer. Its `try/after` cleanup uses the same idempotent release path as
the resource destructor. It preserves query results, raised exceptions
and SQLite error metadata. Manual `prepare`, `fetchall` and `reset`
retain their existing ownership contract; this is not a new general
statement-finalization API. The repair and regressions are submitted in
[esqlite PR #105](https://github.com/mmzeeman/esqlite/pull/105).

A private query statement never escapes to another caller, so this
repair does not require a general statement-locking mechanism. Forcing
collection in Loom or adding a process for each query would make
connection retirement depend on extra runtime machinery. Neither is
needed to release a statement whose owner is already known.

Five dependency regressions cover successful queries with and without
arguments, bind failure, step failure and a raised bind exception. They
close the original connection and require another connection to leave
WAL mode, without forcing collection or ending the caller. Removing the
cleanup makes all five fail. The repaired dependency passes all 35 tests.
An evaluation-only daemon run keeps file descriptors at 68 throughout
the 16 measured cycles. These results establish the repair's effect,
not its inclusion in a shipped Loom build.

Adoption requires a reproducible native dependency build and a fresh
full gate, soak and release smoke. Gleam 1.18.1 accepts this rebar-built
dependency through Hex metadata, not a native git or path dependency.
The [compiler's dependency conversion](https://github.com/gleam-lang/gleam/blob/v1.18.1/compiler-cli/src/dependencies.rs#L926)
selects the Gleam build tool for the latter routes.
An evaluation code-path override or a modified build cache is not a
release mechanism. The dependency reference and final verification
remain open until that packaging step is complete.

## Addendum: pinned native Git build

*Added 2026-09-17. This records the dependency packaging decision; final
adoption verification is recorded with PR #444.*

Storage now selects `Roasbeef/esqlite` commit
`813d37449f1d9222c8bc3bc2374856f0fd371509` through a Git dependency. That
commit adds only package metadata to the query-retirement repair at
`45dbb48ce28c4d78b5cb93de0e1e78bb79f859d9`; its Erlang and C sources are
identical. The SQLite version and the sqlight binding are unchanged.
Every consuming package receives the same pin through storage.

The maintained Gleam compiler accepts explicit `build_tool = "rebar3"`
metadata for Git packages and uses the existing native builder. It retires
cached native output when the pinned commit changes, including changes that
keep the same package version. Native path dependencies remain unsupported.
The compiler patch and cold-build regression are maintained in
[`scripts/toolchain/gleam`](../../scripts/toolchain/gleam/README.md), and CI
and both Docker recipes apply them. Ordinary development now needs this
compiler too. No modified cache or evaluation code-path override is needed.

The real storage suite passes 104 tests against the pinned build. Full native
and Linux gates pass, as do both release smoke tests. The Linux smoke builds
its bundled seed offline. The daemon soak retains 35 descriptors after each
retirement over 16 measured cycles following two warmups. The dependency's
35 tests and the five original retirement regressions also passed in the
Linux evaluation; the adopted source is identical to that tested repair.

[Workflow 35296389719](https://github.com/Roasbeef/loom/actions/runs/35296389719)
builds the maintained toolchain image and compares matching complete release
artifacts from two independent Linux runners. The release workflow pins its
published digest. [The repair review](../review/git-identity-linux.md) records
verification limits and the clean-build requirement when retiring the pin.


## Addendum: Hex distribution for stock compiler builds

*Added 2026-09-18. This supersedes the native Git dependency for ordinary
source builds; the query-retirement repair is unchanged.*

The native Git metadata is understood only by the maintained compiler.
Stock Gleam 1.18.1 accepted the checkout but omitted the C build, producing
a release without `esqlite3_nif.so`. The release smoke test refused startup
before the updater installed the incomplete release.

We distribute the repaired dependency as `esqlite_loom` 0.9.0 on Hex, with
`build_tools = ["rebar3"]` and the original `esqlite` OTP application name.
Its Erlang and C sources match repair commit
`45dbb48ce28c4d78b5cb93de0e1e78bb79f859d9`. The companion `sqlight_loom` 1.2.0
package preserves sqlight's modules and API while selecting that Hex package.
All four direct binding dependencies in Loom select the companion package,
so the upstream packages cannot introduce duplicate modules.

Hex supplies the native builder metadata that released Gleam already
supports. Contributors need Gleam, Erlang/OTP, Rebar3 and a C compiler;
they do not need our native Git compiler patch. CI separately builds the
complete distribution with stock Gleam on Linux and macOS, without restoring
artifacts from patched-compiler jobs. Release reproduction retains its
maintained compiler and deterministic-cache checks.

The cost is maintaining two small package forks until an upstream release
contains the repair. The binding fork changes packaging only. Returning to
upstream packages requires changing every direct dependency together and
checking that the resulting graph contains one SQLite implementation.

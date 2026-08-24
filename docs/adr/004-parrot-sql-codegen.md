# ADR-004 — adopt parrot for typed SQL, gated on a pilot

**Status**: accepted · **Date**: 2026-08-24 · **Supersedes**: nothing ·
**Relates to**: ADR-002 (sqlight stays), `docs/deps-eval.md`

## Decision

Adopt `parrot` — sqlc-style code generation that turns `.sql` files into
typed Gleam — but do not convert the proven backend in one step. The
sequence is: pilot on the next *new* SQL surface (WP-K's full-text search
database at M3), then retrofit `storage/sqlite`'s straightforward
statements in a mechanical commit series, moving the plan-asserted branch
index queries last. Pragmas, schema DDL, and dynamically composed
statements stay hand-written; parrot covers named static queries, which
is most of them.

## Why this is safe for the branch index

The blocking question was whether generated code could carry the queries
whose `EXPLAIN QUERY PLAN` output is a continuous-integration contract.
That was settled by running parrot's pinned sqlc version over Loom's real
schema and the exact segment query text, not by reading documentation.
sqlc parses the `WITHOUT ROWID` tables and the `CROSS JOIN` driving from
`branch_entries`, types the four numbered parameters correctly, and emits
the statement **byte for byte**: the generated function returns the SQL
text alongside its parameters and decoder. Identical text means identical
plans by construction, and `"EXPLAIN QUERY PLAN " <> sql` still composes
because the text is handed back rather than hidden.

Driver compatibility holds too. Parrot is deliberately driver-agnostic —
it returns tuples of text, parameters, and a decoder — so sqlight remains
the binding and ADR-002 is untouched, bridged by a ten-line parameter
wrapper.

## What we are accepting

Parrot has a single maintainer and thin unit tests, with its real
coverage in per-engine integration suites. Generated code imports its
small runtime module, so parrot becomes a full dependency of `storage`
and drags its code-generation dependencies into the resolution tree even
though only the generator uses them. Code generation also fetches the
sqlc binary over the network; the version is pinned in source and a
per-platform checksum is verified before use and re-checked on every run,
and continuous integration can pre-provision the binary at the pinned
path to avoid the fetch entirely.

If the dependency weight ever becomes unacceptable, the escape is
recorded here rather than rediscovered: the runtime module is roughly a
hundred lines and can be vendored with a post-generation import rewrite.
That is friction we accept only if forced.

## Why gated rather than immediate

The storage backend is the most thoroughly proven code in the repository
— a conformance suite over two backends, query-plan assertions, and a
fenced-lease test. Converting it wholesale would put that evidence at
risk to buy type safety it already has by other means. Piloting on a
surface with no regression risk proves the workflow first: the schema
script, the generation step, the wrapper. The retrofit then proceeds
under the same plan assertions that guard the code today, so every step
is arbitrated by a test rather than by review.

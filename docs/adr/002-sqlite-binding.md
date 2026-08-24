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

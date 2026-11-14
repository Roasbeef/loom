# protocol-change/114: bounded exact-key register reads

**Status**: ACCEPTED 2026-11-13, owner-approved interface direction.
**Affects**: Part 1.2 `Storage` behaviour and `StorageError`.

## Problem

Run admission and the strand driver need pending payloads named by their own
captured state, not an inventory of the session's pending namespace. A namespace
scan decodes unrelated rows and can fail on another strand's malformed payload.
Individual exact-key reads preserve the boundary, but each requires a writer
request, a storage request and a SQLite statement.

The [November 4 measurements](../docs/review/session-hotpaths-2026-11-04.md)
show why neither operation is sufficient. With 128 owned keys and no unrelated
backlog, 50 SQLite loads took 20 ms using scans and 86 ms using individual reads.
With 1,000 unrelated keys and 32 owned keys, scans took 221 ms and individual
reads took 20 ms. These historical measurements motivate a scoped bulk read;
they do not establish its performance.

## What was considered

A global scan followed by filtering still decodes unrelated cells. A prefix
cannot express an arbitrary set of reserved entry IDs, and changing its meaning
would violate the existing inventory contract. A backend-specific raw connection
would bypass the generic storage boundary. A second decoded-value cache adds
freshness obligations without removing the unnecessary SQL statements.

The internal snapshot reader can select heterogeneous cells in one actor turn,
but its capture protocol is not the generic `Storage` behaviour and still issues
individual header/value queries. Extending it would add an adapter rather than
the operation the caller needs. Adaptive scan/point thresholds would retain the
unrelated-corruption failure and would need workload assumptions we have not
measured. Group commit concerns writes and is outside this read change.

## Decision

Add one field and its module-level wrapper to Part 1.2:

```gleam
pub fn get_registers(
  store: Storage(handle),
  ns: RegisterNs,
  keys: List(String),
) -> Result(Dict(String, Register), StorageError)
```

For an accepted request, the result contains exactly the existing cells for the
requested keys in that namespace, including each cell's current write sequence.
Missing keys are omitted and duplicate keys collapse. The dictionary has no
ordering guarantee. Values come from one read snapshot for that call, not from
independently timed point reads. Any requested corrupt cell fails the complete
call; no partial dictionary is returned. Unrequested cells are not decoded, even
when they share a key prefix with a requested cell. If several requested cells
are malformed, the contract does not specify which one is reported first.

The module-level wrapper accepts at most 128 raw key occurrences. The count is
checked before deduplication and before backend admission. An oversized request
returns the new `StorageError.RegisterReadLimitExceeded(limit: 128)`, including
when the handle is closed. It is never truncated. A valid empty request still
checks the handle's lifecycle: it returns an empty dictionary on an open handle
and `HandleClosed` on a closed handle. Backend function fields receive validated
requests through the module-level wrapper, as required by `Storage`'s existing
caller convention.

The 128-key bound limits one request's SQL shape and actor work. It is not an
empirically selected scan/point crossover, a total payload-byte bound, or an
operator tuning option. SQLite uses one parameterized `SELECT` with namespace
and exact-key predicates, at most 129 parameters, and the existing composite
namespace/key index. The memory backend performs exact map lookups in one actor
turn. Existing selected-row decoding, corruption reporting and cache validation
against freshly fetched bytes remain in force.

The runtime may split a larger captured key set into calls of at most 128 keys.
Those calls do not share a snapshot. Pending payloads are immutable until their
CAS-guarded placement/deletion; the state and placement expectations remain the
authority for committing a transition. Batching does not replace those guards.
The runtime omits requests for an empty captured set and never falls back to an
inventory scan.

## What it costs

The two backends, erased session store and conformance simulation store gain one
behaviour field. Existing record updates inherit it, but read-counting wrappers
must instrument it explicitly. Exhaustive `StorageError` matches gain the new
limit variant. This is an additive source-interface change, not a backward-
compatible record construction change.

The shared conformance suite must compare successful bulk results with exact
point reads, including missing keys, duplicates, namespace isolation, sequences,
updates/deletes, empty requests and the 128/129 boundary. SQLite tests must cover
requested versus unrelated malformed bytes, warm-cache freshness and the indexed
query plan. Runtime tests must witness the complete captured ID set, more than
one batch, and the absence of pending namespace scans and point-read fallback.

No database schema, durable encoding, storage version, effect-plane wire frame,
cache policy, dependency, FFI boundary or durability setting changes. Existing
session files open without migration. General control-register polling and
production group commit remain separate work.

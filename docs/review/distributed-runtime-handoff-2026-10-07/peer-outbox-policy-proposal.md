> Archived at the October 7 pause. This records its original component or
> proposal state. The current handoff governs publication status and next steps.

# C3a: bounded sender custody and exact receipt reads

**Owner-review proposal. Every policy and API choice below is pending; no implementation is authorized.** This consolidates and supersedes the earlier custody, bounds and reader drafts. Evidence comes from unchanged peer/storage paths at root `dedd107f` in `/Users/roasbeef/gocode/src/github.com/roasbeef/loom/.worktrees/runtime-main-refresh`. Paths below are relative to that checkout.

## Decision requested

Approve sender persistence before transmission, full verified receipt persistence/readback before success, and explicit confirmed-row retirement, with:

- **1,048,576 canonical UTF-8 bytes per sender envelope and complete receipt.**
- **1,048,576 raw stored bytes per recipient receipt read**, checked before BLOB transfer/JSON decoding.
- **67,108,864 charged bytes and 64 outstanding rows per source session**, shared across strands.
- A narrow internal exact-cell reader and its receipt callers, described below.
- Explicit oversized/legacy refusals, preserving all metadata and recipient history.

Keep body <=32,768 UTF-8 bytes and ID 1..128 bytes. Do not truncate source metadata or substitute receipt summaries/digests. These field limits remain, but the aggregate policy can refuse a formerly admissible message whose complete envelope exceeds 1 MiB. Full arbitrary provenance, unlimited acceptance and finite custody cannot all be promised; that compatibility cost requires approval.

The 64-row ceiling is not a lifetime quota. Conservative receipt reservation lets the 64 MiB budget admit at most 63 short outstanding rows. A 256-row ceiling would be redundant. Retirement restores credit for ongoing messaging.

## Immutable envelope, receipt and exact charge

Existing request `Q = {source_session,source_strand,target_strand,message_id,body}` and receipt `R = {request:Q,source:M,admitted:true}` come from `packages/client/src/client/peer_mail.gleam:530-543`. M is complete host provenance. Candidate sender envelope:

```text
E = {request:Q, target_session:canonical_UUID, source:M}
```

Canonicalize recursively and count UTF-8 bytes of `core/json.to_string` (`packages/core/src/core/json.gleam:157-185`). With `e(s)` excluding the two string quotes:

```text
bytes(Q) = 85 + e(source_session) + e(source_strand)
              + e(target_strand) + e(message_id) + e(body)
bytes(R) = bytes(Q) + bytes(M) + 38
bytes(E) = bytes(Q) + bytes(M) + e(target_session) + 42
```

For a 36-byte UUID, E is exactly 40 bytes larger than prospective same-metadata R. A 32,768-byte NUL body contributes 196,608 escaped-content bytes (`core/json.gleam:318-335`); 194,560 is not a send ceiling.

Sender key: SHA-256 of canonical `["peer-outbox-v1",source_session,source_strand,target_session,message_id]`. Include recipient session because recipient dedup keys live in separate stores (`peer_mail.gleam:1263-1279`). Request digest binds all six semantic fields; compare full fields too. First reservation freezes M and E; identical concurrent sends reuse them. Changed body/target strand conflicts while that row exists.

Proposed closed rows, with 64-character lowercase hexadecimal digests:

```text
P = {v:1,state:"pending",envelope:E,
     request_digest:Dq,envelope_digest:De}
Z = {v:1,state:"confirmed",envelope:E,
     request_digest:Dq,envelope_digest:De,receipt:null}
charge = key_UTF8_bytes + max(bytes(P), bytes(Z) - 4 + 1048576)
```

Confirmed replaces null with the complete verified receipt. Charge is immutable and recomputable from retained E. Reserve the full receipt allowance: an existing receipt may have older, larger source metadata; duplicate comparison ignores metadata (`peer_mail.gleam:591-599`).

Allow 1,024 bytes for a version/count/charged-bytes header, included in the total. Before insertion require `count+1<=64` and `1024+charged+charge<=67108864`. Commit row absence and observed header sequence together. Settlement releases nothing. A short row reserves slightly over 1 MiB; near-limit E reserves slightly over 2 MiB, admitting at most 31 such rows. This bounds logical live custody, not transaction history, SQLite/WAL disk, recipient history or heap.

## Proposed storage/API scope

Existing snapshot ExactKey gates normal SQLite BLOBs before fetching JSON, but its 1 MiB budget includes usage metadata and 168 bytes of receipt address/framing. It cannot support every 1 MiB receipt (`storage/snapshot.gleam:334-344,375-379,489-501`; `storage/internal/snapshot_sqlite.gleam:64-78,243-273`). Do not enlarge the general snapshot budget or accept a smaller hidden receipt limit.

Propose one internal reader operation on the existing storage actor:

```text
exact_cell(namespace, key, maximum_stored_bytes, wait_ms)
  -> Result(Option(Cell(payload,seq)), ExactReadError)
```

Receipt callers use the approved 1 MiB maximum. No usage capture, prefix scan, references or callback query language. In one deferred transaction, read only seq and a type-guarded length:

```sql
SELECT seq,
 CASE WHEN typeof(value)='blob' THEN length(value) ELSE -1 END AS value_bytes
FROM registers WHERE ns=? AND key=?;
```

Missing is absent. Invalid type/sequence is corruption. Oversize is an error before payload fetch. Otherwise select value by exact namespace/key/observed seq, additionally requiring BLOB type, matching observed length and length<=limit. Parse the entire JSON, then validate receipt shape, admitted=true and every semantic request field against E. Check canonical receipt size before confirmation. Normal stored output is compact JSON; irregular legacy encodings can fail the raw-byte gate even if canonical form fits. That additional refusal is expressly part of the decision.

Owned proposed changes: `packages/storage/src/storage/snapshot.gleam` reader/error surface; `packages/storage/src/storage/sqlite.gleam` and `packages/storage/src/storage/memory.gleam` actor messages/dispatch; `packages/storage/src/storage/internal/snapshot_sqlite.gleam` and `packages/storage/src/storage/internal/snapshot_memory.gleam` backend paths; `packages/storage/src/storage/sql/snapshot.sql` and generated `packages/storage/src/storage/sql.gleam`; peer command/handler and callers in `packages/client/src/client/peer_mail.gleam`, `packages/client/src/client/peers.gleam`, serialized through existing `packages/client/src/client/agency.gleam`. Keep frozen Storage behavior unchanged. No dependency, schema or FFI change is proposed.

## Both receipt paths must use the bounded read

**Public Deliver:** replace both receipt `api.fact` reads, including the FactConflict fallback after raced admission (`peer_mail.gleam:544-548,574-587`). Current grant/default/denial checks still precede duplicate lookup. Identical duplicates return the original full receipt only if raw and canonical limits pass; changed requests conflict. Newly constructed receipts pass canonical policy before atomic prompt/receipt admission, ensuring stored compact bytes fit.

**Internal reconciliation:** use the same bounded exact receipt reader, not `api.fact` followed by a JSON size check (`:1281-1311`). Return only the complete verified receipt or absent/error. Public inspection's 194,560-byte contract is unchanged; the internal 1 MiB lookup is a separately reviewed API addition.

An oversized exact cell proves only that the addressed stored value exceeds policy. **Admission is unverified**, because admitted/request fields were not decoded. Do not claim historical admission exists, return null, fabricate success, re-key or delete the recipient record. Pending and its charge remain. Enough unresolved oversized legacy cells can exhaust capacity; no administrative release mechanism is included. The owner must accept this limitation or choose an explicit legacy exception allowing unbounded full-receipt handling. That exception would weaken these bounds or change full-receipt-before-success; it is not implicitly approved.

## Authorization, uncertainty and retirement

Keep outgoing-link, resident-recipient, directory-identity and host-bound source checks (`peers.gleam:161-197,686-708`). Retained state grants no current caller authority. Public Confirmed retries still call Deliver, so recipient grant revocation can refuse them. Historical reconciliation requires the outgoing link but adds no recipient-grant check.

Pending means admission unknown. Reserve timeout/unknown commit grants no send handle. Confirmation uncertainty returns error and retains possible committed state; exact readback resolves it without a new ID. Success JSON remains `{request,source,admitted:true}`, proving admission only.

Explicit retirement removes only an observed Confirmed row and decrements charge/count atomically through `api.edit_reserved_facts` CAS (`runtime/api.gleam:2820-2863`). Unknown retirement commit releases no assumed credit. Crash before retirement retains charged state. No pending eviction or autonomous collector is added.

After retirement, no permanent sender-local or offline receipt history is promised. Repeats still depend on permanent recipient receipts and current authorization; changed content remains refused there. Recipient preservation through backup/movement remains essential and outside this slice.

## Remaining limits and cut

Installed SQLite source confirms direct-column length(BLOB)/typeof avoids full content loading; type guards prevent TEXT character-count under-accounting. Memory already owns decoded JSON and currently serializes to measure it; no equivalent pre-allocation guarantee or unrelated rewrite is proposed. Sender Activity/source capture also remains unbounded before aggregate rejection. Standard JSON has depth 256; wait timeout does not cancel actor/database work. These are bounded receipt-input and retained-custody policies, not a universal memory/CPU/wall-clock guarantee.

Cut background delivery/retry/polling, generalized journals, permanent sender tombstones/history, lifetime quotas, truncation, digest-only receipt success, recipient receipt deletion, routing/membership changes, snapshot-budget expansion and new dependencies/schema/FFI. Approve these specific policy/API choices before implementation.

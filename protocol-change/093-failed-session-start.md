# protocol-change/093: a failed session start is kept on its reservation

**Status**: PROPOSED 2026-10-19, owner-approved as option "a" below.
**Affects**: the client control protocol (Part 1.6): the `reserved` status object
of `sessions.list`, `sessions.get` and the operation replies gains one optional
member, `failure`. Durable cells that are not Part 1 interfaces: the catalogue
moves to `user_version` 18 and gains the table `catalogue_start_failures`.
`manager.Status` gains a variant. No command, event or error code changes.
**Raised by**: a session whose start failed on an executor census ("executor
`exec` declares toolchain `codemode` but its census reports `[]`") that stayed
listed as `reserved exec:repo` indefinitely, with nothing to say why.
**Builds on**: [055](055-operator-startup-diagnostics.md) (the reason a failed open reports
for its exact operation), [078](078-distributed-runtime.md) (the executor
census, and the reservation a failed first open leaves).

## Problem

A creation reserves an identity and a database path before any file exists.
`Reserved` is durable on purpose. A retry under the same request key must find
the same registration, resume the same identity, and reuse a partial database,
so the reservation survives a crash and a failed start alike.

The reason a start failed does not survive. The registry keeps it in a
`failed_operations` map, one entry per session, so the operator polling that
exact operation reads `start_failed` with the reason. The map is in memory. After
a restart, and after the operation id is gone, a failed start and a creation in
progress are the same row: `reserved`. The list never says why, the row sits in
it forever, and the owner can only guess that the cause was transient or that a
retry is worth trying.

## What was considered

- **Delete the reservation when a start fails.** It removes the row, so nothing
  stays listed. It also breaks the retry-resume contract whenever the storage
  identity was already published: the executor may hold a scope or a partial
  database under that identity, the creation request key would no longer find
  it, and a retry would mint a second identity beside the first. Eliminating the
  row removes the failed state by destroying the evidence a retry needs.
- **Release the reservation only when no database file exists.** Narrower, and
  it keeps the contract for any start that got as far as a file. It leaves the
  reason unrecorded, so the owner sees a session vanish with no explanation, and
  the same census failure on an executor session (where no file exists on this
  host to test) would be released and re-created on every retry. It decides by
  inspecting the filesystem what the catalogue should simply say.
- **A durable failed state on the reservation (chosen).** The registration is
  untouched, so every property of `Reserved` holds. One more row records the
  reason and the time. The state is visible, deletable and cleared by the next
  attempt.

## Decision

**A reservation may carry one start failure.** The catalogue's version 18 adds
`catalogue_start_failures(session_id, reason, failed_at)`, keyed by the
registration. `storage/catalogue` exposes it as

```gleam
pub type StartFailure { StartFailure(reason: String, at: Int) }
```

with `record_start_failure`, `start_failure` and `clear_start_failure`. It is a separate row and not a field of `Registration`,
so the creation request a retry compares is unchanged, in the way a custody row
is separate from the registration it describes. The kept failure is therefore
not a `Bool` on a record, and "no failure" is the absence of a row.

- **Written when a start fails.** The registry already records a failed build in
  its in-memory map (`remember_failure`). The same call writes the row. Only a
  `Reserved` registration accepts one (`Conflict` for a `Saved` one), because a
  session that has a verified file is not a creation that failed, and its next
  open reports its own failure as before.
- **Cleaned before it is stored.** The registry removes terminal sequences and
  invisible or direction-changing codepoints, collapses the text to one line,
  and cuts it to 512 bytes (`catalogue.start_failure_limit`). The catalogue
  refuses anything that is not one to 512 bytes of printable text, and the table
  holds the length bound itself, so a stored reason is always safe to draw in a
  terminal row or an HTML text node. An empty reason is replaced by a fixed
  sentence.
- **Cleared by the next attempt.** A retry that gets as far as reserving a slot
  clears the row in the same turn, so the list reads as starting again.
  `confirm` clears it when the file is verified, and `delete` removes it with the
  registration. A retry under the same request key finds the same registration
  and resumes the same identity, as it did before; nothing about admission
  changed.
- **Surfaced as a failed start.** `manager.Status` gains
  `FailedStart(reason, at)`: a `Reserved` with a kept failure. The sessions list
  of the CLI, the web home and the terminal's picker draw it as failed with its
  reason instead of `reserved`, and offer the delete they already offer a
  reserved row.

### Wire

The status object keeps `state: "reserved"` and gains an optional member:

```json
{"state":"reserved","failure":{"reason":"executor exec declares toolchain codemode but its census reports []","at":1760000000123}}
```

`failure.reason` is a nonblank single-line string of at most 512 bytes and
`failure.at` is Unix milliseconds. The member is omitted for a reservation
without a kept failure, so that frame is byte-for-byte what an older daemon
sends. Keeping the `state` word means an older client, which dispatches on it,
still draws `reserved` and offers what it offered, and ignores the member. A
newer client that meets a `failure` it cannot decode (a missing `reason`, an
oversized or multi-line one, a negative `at`) treats it as absent and draws
`reserved`; it never fails the row.

A foreign daemon's page (`sessions.elsewhere`) carries the same member by the
same rule.

## What it costs

- A catalogue migration. Version 18 adds one empty table; a downgrade needs the
  pre-upgrade catalogue restored, as for every earlier version.
- One more statement when a page lists a reservation with no slot: the registry
  reads the failure for it. The rows are the reservations, not the saved
  sessions, so the cost follows the count of unfinished creations.
- A failure written during cleanup is best effort. If the write fails the
  reservation stays as `reserved`, which is the state it had before this change.
- A failed start is kept until the next attempt, the file's confirmation or a
  delete. A reservation whose cause is fixed outside the daemon still reads
  failed until someone retries it; the reason says how old it is.

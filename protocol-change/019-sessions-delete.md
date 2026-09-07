# protocol-change/019 — add `sessions.delete` to the control endpoint

**Status**: ACCEPTED 2026-09-07 · **Affects**: daemon control commands ·
**Raised by**: issue #294 · **Implemented**: client + tui + docs

## Problem

The control endpoint can create, open, stop and isolate a session, and it
can revoke one principal's membership. Nothing removes a registration.
`sessions.stop` is ordered cleanup that preserves the conversation
database on purpose. So a state root only grows: every session ever
created stays in the catalogue, and the picker fills with rows nobody
will open again. There is no command, no key and no subcommand for
deleting a session.

## Proposal

One additive owner-only command:

```json
{"v":2,"id":14,"cmd":"sessions.delete",
 "body":{"session_id":"<canonical id>","epoch":"<hello epoch>"}}
```

The reply is `sessions.delete` with the removed registration's
`session_id`, `workspace` and `name`. Errors are `forbidden`,
`stale_epoch`, `not_found`, `busy` and `unavailable`.

Three questions had to be settled.

**Whether delete stops a running session.** It does not. The command is
refused with `busy` whenever the daemon holds a runtime reservation for
the session in any state other than `saved`. The caller sends
`sessions.stop`, waits for `saved`, and sends delete again.

**What is removed durably.** In one catalogue transaction: the
registration, its memberships, its display name, a workspace default
naming it, and its domain mapping. The catalogue revision is incremented. The conversation
database and the files SQLite keeps beside it — `-wal`, `-shm`,
`-journal`, and a `.tmp` scratch directory — are unlinked after the
transaction commits.

**What survives.** The domain record and everything distilled into it:
the memory store, its index, and shared-history rows derived from the
session. These belong to the workspace, not to the conversation.

## Impact

Additive. A client that does not send the command sees no change. The
existing `sessions.list` reply shape is unchanged; a deleted session
simply stops appearing in it, and the revision bump refuses a pagination
that spans the removal. `docs/client-protocol.md` §3.16 documents the
command; §3.17 records that a draining daemon refuses it like every other
mutation.

## Decision

**Accepted.** Two alternatives were considered.

Stopping the session as part of delete was rejected. It would make the
command's outcome depend on how a running conversation happens to drain,
and a caller who mistyped an identity would lose a live session rather
than receive a refusal. Refusing `busy` costs the caller one extra
command and makes the destructive step operate only on a session that is
already at rest, which is also what lets the file unlink run without
racing a writer.

Tombstoning the registration rather than removing it was rejected. A
tombstone keeps the catalogue growing, which is the problem being
solved; it would need a filter in every listing query and an answer for
what a tombstone's files are for. The identity is a UUIDv7 and is never
reissued, so a removed row cannot be confused with a later session.

The cost is that delete is irreversible and the daemon offers no
recovery. Both clients pay for that with a confirmation the person has
to answer: the picker asks before it sends, and `loom sessions rm`
refuses to run unattended without `--yes`.

# protocol-change/035 — archive sessions without deleting history

**Status**: ACCEPTED 2026-09-14 · **Affects**: daemon control v2 from
protocol-change/015 · **Raised by**: the owner's request to make ordinary
session removal reversible.

## Problem

The session picker's delete action currently removes both the catalogue entry
and conversation files. Hiding a completed session should preserve its history,
name, creation key, domain mapping, and memberships for later restoration.

## Decision

Add owner-only `sessions.archive` and `sessions.restore` commands, each with
`session_id` and the current daemon `epoch`. They return the existing
session metadata body under their respective event names. Both reauthenticate the owner, fence the epoch, and require that
the serialized manager holds no runtime slot for the session. Neither command
opens a conversation or changes its files. Repeating the same state is a no-op.

Add owner-only `sessions.archived`, with the same `after` and optional `revision`
as `sessions.list`. Both collections share the catalogue revision and existing
bounded page shape. Normal owner/member listing excludes archived rows in SQL
before pagination. Archived sessions refuse admission, including creation-key
retries. Direct metadata lookup remains available under existing authority;
archiving is a presentation and execution choice, not membership revocation.

Catalogue version 3 adds a session-keyed archive table. The archive write,
removal of any workspace default naming the session, and revision increment
commit together. Restore removes the archive row and increments revision without
starting execution or restoring a default. Initialization state and immutable
creation metadata retain their existing meaning. Permanent deletion additionally
removes the archive row before removing the registration.

In the picker, `d` archives an active session after confirmation, stopping an
active runtime through the existing bounded cleanup path first. `a` switches
between active and archived collections. Enter in the archive restores the row
without opening it; `d` there explicitly confirms permanent deletion. Existing
`sessions.delete` and CLI `sessions rm` retain their permanent-delete contract.

## Alternatives and cost

Adding `Archived` to initialization state would conflate file initialization
with visibility and break creation-key equality. Moving conversation files would
add path migrations and failure recovery without helping this metadata operation.
An independent archive table retains both existing invariants. It costs one
small schema migration and three additive control commands. Older clients keep
their existing commands; older daemons reject the new commands without deleting
anything. Domain history and distilled memory remain available after archival.

## Acceptance

Validate migration from catalogue versions 1 and 2, revision/idempotence, default
clearing, bounded owner/member pagination, and preserved creation metadata.
Exercise owner/epoch/busy rejection and archived admission through the manager,
plus both control codecs and the picker archive/restore/delete paths. Confirm
preserved conversation bytes after archive and restoration without auto-start.

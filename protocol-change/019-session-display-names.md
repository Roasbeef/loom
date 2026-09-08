# protocol-change/019 — rename session display metadata

**Status**: ACCEPTED 2026-09-07 · **Affects**: daemon control v2 from
protocol-change/015 · **Raised by**: explicit session-renaming request ·
**Implemented**: storage catalogue, daemon control, terminal client.

## Problem

Session names are creation metadata today. Both catalogue reservation and
daemon admission compare that name when recovering a creation key. Updating
the original name would turn a valid retry into a conflicting request.

## Proposal

Add one owner-only, epoch-fenced command:

```json
{"v":2,"id":1,"cmd":"sessions.rename","body":{"session_id":"<id>","name":"review auth","epoch":"<epoch>"}}
```

The reply uses event `sessions.rename` and the existing session metadata body.
Names must contain 1–256 UTF-8 bytes. Rename never opens, stops, or retargets
a session. Authorization, epoch validation, and the write are serialized by
the existing daemon manager. A timeout remains an unknown outcome; the client
does not retry automatically.

Catalogue schema version 2 adds a display-name override keyed by session ID.
The override and catalogue revision increment commit together; setting the
same display name again is a no-op. Reads for display use the override, while
creation-key reconciliation retains the immutable original name. Existing
version-1 catalogues migrate transactionally without changing their records.

## Impact

Both control codecs, daemon dispatch, the catalogue DAL and the terminal
command path change. SQL queries and embedded migration DDL are generated
artifacts. Existing clients can keep reading session metadata unchanged; an
older server rejects the new command. Conversation databases and the frozen
conversation protocol do not change.

## Decision

**Accepted.** The owner requested renaming and delegated local protocol
decisions. Updating the original name was rejected because it breaks durable
creation-key equality; adding model-generated names or a background rename
service would introduce unrelated work. Independent review covers authority,
revision fencing, migration, and retry behavior before this change ships.

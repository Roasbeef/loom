# protocol-change/122: a catalogue summary of attention, so counts survive a restart

**Status**: PROPOSED 2026-11-18. The owner accepted autonomous protocol
changes for the attention inbox build on 2026-11-17. This is phase 1b of that
build.
**Affects**: the catalogue schema (version 22, new table
`catalogue_session_attention`), `storage/catalogue` (one upsert, one keyed read,
one delete in the session-delete path), one new registry command that carries the
upsert, four writers of the session store that call it, the session open path,
and the home page's headline and its Needs you group. No control command, wire
frame or `loom.toml` key changes. No existing catalogue table changes.
**Raised by**: `docs/design-notes/attention-inbox/README.md`, section 5
("Counts"), and `ranking.md`, section 7 ("The saved-session count").
**Builds on**: [050](050-session-activity.md) (`sessions.activity` reads
resident sessions only), [113](113-session-agency-limits.md) (the most recent
catalogue migration, version 21, and the way a per-session table is deleted with
its registration) and [120](120-attention-feed.md) (the feed, which reads
resident sessions only).

## Problem

`sessions.activity` and `sessions.attention` ([120](120-attention-feed.md)) read
only resident sessions. [050](050-session-activity.md) rules that the daemon never
opens a saved session for them. After a daemon restart every session is saved
until something opens it, so a session with a pending approval or an open ask is
invisible to Home until a person opens it. Home's headline then says "in N
running sessions" over a set that has just become empty, and a person who left
a run waiting on an approval overnight sees nothing that says it still waits.

The design's section 5 states the test that exposes this: the first acceptance
test of any build is a daemon restart with an approval pending. Without a record
that outlives the session's open store, that test fails by construction.

## What was considered

### Opening saved sessions to read them

Home could open every saved session on a refresh and read its records. Rejected.
It is the cost [050](050-session-activity.md) refused: opening starts a session
host, reads a store, and can fail, for every session the owner has ever saved, on
every refresh.

### A scan at daemon start

The daemon could read every saved session's records once at start and hold the
counts in memory. Rejected for the same cost at the worst time, and because the
counts would then be wrong from the first change after the scan until the next
restart, with nothing to repair them.

### A summary written only when a record closes

A row could be written when an approval is decided or an ask answered, and
cleared then. Rejected. The case that matters is a daemon that stops while an
approval is pending, and a write on close never runs for it. The row has to be
written when the record opens or changes status, as well as when it closes.

### Storing the counts in the session's own store

The counts could be a reserved fact of the session store. Rejected. Reading it
means opening the store, which is what the summary exists to avoid.

## Decision

### The table

Catalogue version 22 adds `catalogue_session_attention`:

```sql
CREATE TABLE catalogue_session_attention(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  pending_approvals INTEGER NOT NULL CHECK(pending_approvals >= 0),
  open_asks INTEGER NOT NULL CHECK(open_asks >= 0),
  open_finds INTEGER NOT NULL CHECK(open_finds >= 0),
  oldest_open_at INTEGER,
  updated_at INTEGER NOT NULL
);
```

| Column | Meaning |
|---|---|
| `session_id` | The registration the row summarizes. At most one row for each. |
| `pending_approvals` | The number of escalation records whose status is `Pending`. It is the count `approvals` that `sessions.activity` reports (`client/peer_mail.gleam`, `standing_from`). |
| `open_asks` | The number of ask records with status `open` and routing `owner`, as `asks.count` is in [120](120-attention-feed.md). |
| `open_finds` | The number of find records with status `open`. |
| `oldest_open_at` | Unix milliseconds: the smallest `created_at` over the open owner-routed asks and the open finds. `NULL` when there are none. It says nothing of approvals, because an escalation record carries no raise time (`runtime/escalation.gleam`, `Escalation`). |
| `updated_at` | Unix milliseconds on the daemon's clock when the row was written. It is the time the summary was last made, not the age of any record. It is never read from monotonic time, which is negative on the BEAM. |

The migration is `#(22, catalogue_attention_schema.schema)` in
`catalogue.migrations`, from a new `packages/storage/sql/catalogue_attention.sql`
and the named queries in `sql/catalogue.sql`, generated with `make gen-sql`, and
`current_version` becomes 22 (`storage/catalogue.gleam`, `current_version` and
`migrations`). `migrations_end_at_the_current_version_test` fails until both
change. The migration creates an empty table. It cannot read any session's store,
so a session saved before the upgrade has no row until it is next opened (see
"Absence").

A row is written for a session that has had its summary made, including a row of
zeros. A zero row says "read, and nothing was open at `updated_at`". The
absence of a row says "never read".

### Who writes it

The summary is made by one function that reads a session's own records and
returns the four figures: the escalation list (`api.escalations`), and the ask and
find lists (`client/attention.asks` and `finds`). Each is a bounded read that
the Agency already makes for the overview (`client/peer_mail.gleam`, `overview`)
and the insertion already makes for its count. It is called by whoever commits a
change to one of the three records, after that commit, in the same function that
commits it.

The writers of the session store that change an escalation's status or an
ask's or a find's, which are the places the call goes:

| Writer | Change it makes |
|---|---|
| `client/escalate.gleam`, the `api.claim_escalation` call | an escalation becomes `Pending`, or a decided one is reopened. |
| `client/gateway.gleam`, `commit_approval` and the deny path that calls `api.deny_escalation_at` | an escalation is approved or denied. |
| `client/remote_decision.gleam`, the calls to `api.approve_escalation_at` and `api.deny_escalation_at` | the same, for a decision made on an orchestrator's behalf. |
| `client/attention.gleam`, `try_insert` after `api.edit_reserved_facts` succeeds | an ask or a find is opened. |
| the settle of [120](120-attention-feed.md) (`AttentionSettle`) | an ask is answered or a find is closed. |

`api.consume_escalation_at` moves an escalation from `Approved` to `Consumed` and
does not change the pending count, so it is not a writer of the summary.

The write goes to the catalogue as the subtitle does. The session's host holds a
closure that sends a fire-and-forget command to the registry, as
`gateway.with_first_prompt` carries `manager.seed_subtitle` (`client/gateway.gleam`,
`client/top_host.gleam`, `client/daemon/manager.gleam`, `SeedSubtitle`). A new
command, `RecordAttention(session, summary)`, is handled in the registry's turn,
which serializes it with every other catalogue change, and calls a new
`catalogue.record_attention`, an upsert on `session_id`. The committer does not
wait. A failed write is logged and is not reported to it: the record has
committed, and the summary lags it (see "Consistency").

The summary is written when the record commits, not only when it closes, so a
daemon that stops with an approval pending has already written the row that says
so. That is what the restart test exercises.

### Who removes it

Deleting a registration deletes its summary row first. Foreign keys are enabled
on the catalogue connection (`storage/catalogue.gleam`, the options passed at
open), so `delete_registration` cannot run while a row refers to the registration.
The delete function removes the row with the other dependants, beside
`delete_session_agency_limits` and `delete_session_subtitle`, in the order that
function already uses for [113](113-session-agency-limits.md). The schema has no
`ON DELETE CASCADE`, so this explicit delete is the cascade.

### How Home reads it

Home reads the summary for every session it lists, resident or saved, with one
keyed read (`catalogue.attention_for(ids)`) over the page's identities, which
are bounded by the listing's page size of 100. A member's read is filtered to
the sessions it holds, by the same check as [050](050-session-activity.md)'s
addendum, so a member learns the counts of sessions it holds and no others. The
read adds no registration-page query shape: it does not change
`RegistrationPage`.

For a session that is resident, Home uses the live reads
(`sessions.activity` and `sessions.attention`) and ignores the summary, because
the live reads are current. For a saved session, Home uses the summary:

- A saved session with `pending_approvals` or `open_asks` above zero appears in
  the Needs you group, with those counts and the words "saved", and links to the
  session's page. An approval is decided there, from its dock, as before. An ask
  is answered after the session is open, because `attention.answer` refuses a
  saved session ([120](120-attention-feed.md)). What opening a saved session's
  page does to the session is the page's existing behaviour and is unchanged.
- A saved session with `open_finds` above zero and none of the above appears as
  a find count and not in Needs you, because a find does not need a person.
- A saved session whose row is all zeros contributes nothing.
- A saved session with no row is **not checked**.

The headline counts what it read and names what it did not:

> 2 need you in 6 running and 3 saved sessions

The figures are the sessions that need a person (a resident session whose state
is `needs_you`, or a saved one by the rule above), the resident sessions read,
and the saved sessions with a row. A saved session with no row is counted
separately and the headline says so ("2 saved not checked"). Home MUST NOT print
"Nothing needs you" while any listed session was not read, and MUST say how many
were not.

### Consistency and reconciliation

The record is the truth. The summary is a cache of it, and it can disagree in
two ways.

- **It lags.** A write can fail, the daemon can stop between a record's commit
  and the registry handling `RecordAttention`, and two commits that finish at the
  same moment can reach the registry in the opposite order, leaving the older
  figures. In each case the summary shows fewer or more than the record, and it
  stays so until the session's next change or its next open.
- **It is absent** for a session that has not been opened since the upgrade.

The session page reads the records and never the summary, so a person who opens
a session sees the truth. Reads never write: a read of the feed or of the summary
does not repair a row.

**The reconcile rule.** When a session opens, the summary function is run once
over the session's records and the row is rewritten from the result, whether or
not it differs. The call is made where the session's host finishes opening and
has the runtime, before the session is reported resident. An open that cannot
read the records leaves the old row, logs, and does not fail the open.

No mechanism orders concurrent writes or retries a failed one. The odds are low
(two commits within the registry's turn, or a failed write to a local SQLite
file), the effect is a count that is wrong until the next change or open, and the
reconcile rule bounds it. A mechanism to make it exact would be a version column
and a compare in SQL for a lag that the open already repairs.

### What the summary does not cover

- A stuck strand and a failed `main` run. They are derived from the runtime's
  strand state and last result, which the summary does not hold, so a saved
  session whose only need is a failed run is not in Needs you. The live reads
  report them when it is resident.
- An approval's age. See `oldest_open_at`.
- A session whose records changed while it was saved. A saved session's store is
  not written by anyone, so this cannot happen except through an import or a
  repair, which open the session.

## Cost

- One table and one migration. Existing catalogues migrate with an empty table.
- One upsert for each commit to an escalation's status, an ask or a find: one
  SQLite write in the registry's turn, and the summary function's reads in the
  committing process. The reads are the bounded ones the overview and the
  insertion already make (the escalation list, at most 232 ask cells and 328 find
  cells). An approval raise gains those reads on the escalation path.
- One keyed read for each Home refresh, over at most 100 identities.
- One summary function run for each session open.
- A catalogue change touches the session-delete path, and a missed delete fails
  the registration's removal on the foreign key rather than leaving a row, so the
  cascade test is the guard.

## Verification

Each item is a test over the real catalogue and, where it says so, the real
daemon.

- The restart acceptance test: with a session holding a pending approval,
  stop the daemon without closing the session, start it again, and read Home. The
  session is not resident, its summary row has `pending_approvals` 1, and Home's
  headline counts it in Needs you with "saved". The same test with an open ask.
  This is the first acceptance test of the build.
- `storage/test`: the migration from version 21 to 22 creates the table and
  `migrations_end_at_the_current_version_test` passes; a fresh catalogue and a
  migrated one have the same schema; the `CHECK` constraints refuse a negative
  count; `record_attention` upserts, so a second write replaces the first and
  leaves one row.
- The cascade test: deleting a registration removes its summary row, and a
  registration with a row is deletable (the foreign key does not block it). A
  session id reused after deletion inherits no row.
- `client/test`: each of the five writers in the table above calls the upsert
  after its commit; a raise followed by a daemon stop leaves a row of 1; an
  answer or close writes the lowered count; a decision lowers
  `pending_approvals`; `consume` does not write; a failed catalogue write does
  not fail the commit.
- The reconcile rule: a row made wrong on purpose (the count too high, the count
  too low, a missing row) is rewritten correctly by opening the session, and a
  session whose open cannot read its records keeps its old row and opens.
- `oldest_open_at` is the smallest `created_at` over the open owner-routed asks
  and open finds, is `NULL` for a session with only approvals, and is not
  lowered by an ask routed to a strand.
- A member's keyed read returns only the sessions it holds.
- `web_view/test`: the headline words for each combination of running, saved
  with a row and saved without; "Nothing needs you" is never drawn while a listed
  session was not read; a saved session with a pending approval appears in
  Needs you with "saved" and a link to its page.
- `make doc-check` passes.

## Decisions for the owner

None are open. The owner accepted autonomous protocol changes for this build on
2026-11-17.

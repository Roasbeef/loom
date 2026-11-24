# Protocol 050: report what resident sessions are doing through owner control

**Status**: Proposed implementation · **Affects**: v2 daemon control · **Raised by**: the terminal's cross-session session picker

## Problem

The terminal's session picker is becoming a view over every session the owner
runs: rows grouped by workspace, filters for sessions that need the operator,
sessions that are working, and sessions that are idle, and a details pane for
the selected row. `sessions.list` cannot supply this. Its rows carry lifecycle
only (`saved`, `resident`, and so on), so the terminal can tell that a session
is resident but not whether it is waiting on an approval, running, or idle.

Adding activity fields to `sessions.list` was rejected. Members may call
`sessions.list`; its page budget is shared with the catalogue rows; and it is
a metadata read that asks no session actor anything. Activity requires a call
into each resident session's Agency actor, which is owner-level information
and has a different cost. It belongs on its own route.

## Decision

Add owner-only `sessions.activity` on the existing v2 control socket. The
request names between 1 and 24 distinct canonical session identities and the
current daemon epoch:

```json
{"v":2,"id":1,"cmd":"sessions.activity","body":{"sessions":["<canonical-id>"],"epoch":"<current-epoch>"}}
```

A request with no identities, more than 24, a duplicate, or a non-canonical
identity is refused as `bad_request` before authorization. The server then
authenticates the owner and checks the epoch, exactly as `peers.inspect`
(Protocol 049) does. A member credential is refused with `forbidden`; an old
epoch with `stale_epoch`.

The server resolves each identity through the registry. Only a session whose
slot is running is asked. A saved, archived, opening, stopping, blocked, or
unknown identity is omitted from the reply; the client reads absence as
inactive. The server never opens a saved session and never reads a saved
session's database. `sessions.activity` is a read, so it is also served on an
existing control socket while the daemon drains.

Each resident session is asked through a new read-only `Overview` command on
the recipient's harness-owned peer endpoint. The recipient's Agency actor
answers from its own runtime. The server makes these calls concurrently from
the control socket's process, not from the registry actor, under one deadline
of 2,000 ms. A resident that returns an error, crashes, or misses the
deadline yields a row whose `state` is `unknown` and which carries no other
field. One slow session cannot fail the reply.

The response body is `{"activity":[row, ...]}`, with rows in request order:

```json
{"session_id":"<canonical-id>","state":"needs_you","strands":3,"working":1,"approvals":1,
 "last_outcome":"completed","last_message":"Merged the fix.","model":"glm-5.2",
 "glances":[{"strand":"sub:main/audit-1a2b","title":"Audit","summary":"Reading manager.gleam"}]}
```

- `state` is `needs_you` when any escalation record is pending, or when the
  main strand's last run failed and main has no current operation. Otherwise
  it is `working` when any strand has a current operation, and `idle`
  otherwise. A receiver MUST treat a `state` it does not recognize as
  `unknown`, so a later server can add states.
- `strands` counts the session's strands. `working` counts strands with a
  current operation. `approvals` counts pending escalation records.
- `last_outcome` is the main strand's last run outcome: `completed`, `failed`,
  or `aborted`. It is `null` when main has not finished a run, or when its
  latest terminal result is a compaction or navigation.
- `last_message` is the text of the final assistant entry of main's last run,
  with whitespace collapsed and cut to at most 280 bytes on a grapheme
  boundary. It is `null` when that run has no final assistant entry.
- `model` is main's configured model identity, at most 64 bytes, or `null`
  when main has no configuration.
- `glances` holds at most four strand glances, newest first. A glance is
  included only while its operation is still its strand's current operation,
  as `core/glance` requires. The glance loop does not write one for `main`
  or the advisor today, but a `main` glance that exists is reported like any
  other. `strand` is cut to 96 bytes, `title` to 60, and
  `summary` to 160.

The recipient bounds its own row to 2,300 encoded bytes: when the row is
larger, it drops glances from the oldest, then `last_message`. The server
checks each complete row again against 2,400 bytes and replaces an oversized
row with an `unknown` row. 24 rows of at most 2,401 bytes each fit the
60,000-byte reply budget, and the server still asserts that budget on the
encoded reply and refuses with `metadata_too_large` if it is exceeded.

Each reply is one fresh observation. The daemon does not cache, poll, or push
activity. A client that wants a current view repeats the request.

## Cost

The recipient Agency gains a read-only `Overview` endpoint command. It reads
strand states, the main strand's last result, configuration, and final entry,
the escalation records, and glance cells. Those reads run inside the Agency
actor, so a request delays that session's other peer commands by the time the
reads take. The strand-state listing grows with the number of strands in the
session.

Each request costs up to 24 registry lookups and up to 24 concurrent Agency
calls. The route reports nothing about saved sessions, usage, tokens, or git
state, and it records nothing about whether the operator has seen a session.
The terminal gains one command, one reply, and a total decoder for the row.

## Addendum: members are answered for the sessions they hold (2026-10-04)

**Status**: IMPLEMENTED with the home page's activity words (065, the addendum on
the home list). It amends the decision above, which refused a member.

**Ruling (owner, 2026-10-04).** A non-owner principal is answered, with rows
only for the ids where it holds a membership, at any role. An id it does not
hold is omitted exactly as an unknown or non-resident id is, so the reply never
distinguishes "not a member" from "not resident". The request's validation
(1 to 24 distinct canonical ids, `bad_request` before authorization), the
epoch check, the 2,000 ms deadline and the 2,400-byte row cap are unchanged. The
owner is unchanged: it is answered for every id.

**How.** `server.held` asks the registry, with the credential's digest and at
the moment of the read, whether the credential holds each id
(`manager.session_authority`, the check every other per-session command uses),
and passes only those ids to `activity`. Membership is never taken from the
request, from a page's list or from an earlier read, so a revoked credential or a
removed membership reads nothing from the next request on. The home page's read
(`server.home_activity`) is the same function over the page's own credential.

**What this changes.** `forbidden` is no longer a member's answer to
`sessions.activity`. A member can learn the state word, the last outcome, the
last message, the model and the glances of a session it holds, which are what
its own page of that session shows it. It learns nothing about any other
session, and cannot tell whether one exists or runs. The cost is as above, for at
most 24 sessions the member holds, and a member's registry check adds up to 24
registry calls to a request.

## Addendum: two times on the activity row (2026-11-19)

**Status**: IMPLEMENTED with the data layer of the final inbox mockup.

### The problem

A row's `last_message` is the words of the main strand's last finished run, and
the page cannot say when they were written, nor when the run now going began.
The mockup dates both ("said at 13:15", "working for 4 minutes"). Neither time
is in the row.

### The decision

The row gains two members, both Unix milliseconds, both `null` when there is
nothing to date:

| Member | Meaning |
|---|---|
| `last_message_at` | The `ts` of the entry behind `last_message`, the final assistant entry of main's last run. `null` whenever `last_message` is `null`, so a time is never present without the words it dates. |
| `turn_started_at` | The mint time of the operation now open on main (`ids.op_id_timestamp_ms`). `null` while main runs nothing. It is the start of the current turn and never the end of the last one. |

The resident computes them in `Overview` from reads it already makes: the entry
it reads for the text, and the strand-state listing. When the row is over its
bound, `fit_overview` drops the message and its time together. The daemon's
decoder (`server.report_of`) reads both as whole non-negative numbers and takes
anything else, or a row from a resident that predates them, as no time. Both
reach the page as `web_view/sessions.Report.last_message_at` and
`turn_started_at`, `Option(Int)`. The daemon formats no time.

### What it costs

About fifty bytes in a row that is bounded at 2,300. No new store read: the
text's entry is read already, and the operation id is in the strand-state cell.

## Addendum: open asks on the activity row (2026-11-23)

**Status**: ACCEPTED 2026-11-23, the owner asked for it. Additive: a client
that does not read the member ignores it.

### The problem

A session that has asked the owner a question (protocol-change/120) is waiting
on a person, but its activity row does not say so. `state` is `needs_you` only
for a pending approval or a failed main run, and the row carries no count of
asks. The web view's sidebar draws its second line for each running session
from this row, so a session waiting on an answer read `quiet` or `running` in
every other page's sidebar. Home's sidebar was right only because it also reads
the attention feed, which a session page does not.

### The decision

The row gains one member, `asks`: the number of asks that are open and routed
to the owner. An ask routed to a strand needs no person and is not counted, and
neither is a settled ask. The member is always present on a row a resident
answers. `state` is unchanged: an open ask does not make a session `needs_you`,
so the terminal's filters and the dots keep their meaning. A receiver reads a
missing member, or one that is not a whole non-negative number, as 0, so a row
from an older resident is still a row.

The resident computes it in `Overview` from the same records and the same rule
as `open_asks` of the catalogue's attention summary (protocol-change/122):
`attention.open_owner_asks` is the one filter both use, so the two counts cannot
disagree. The daemon's decoder reads it into `web_view/sessions.Report.asks`,
and the session page's activity read narrows a report to `sessions.Watch`, the
state and the count, so the page still learns nothing a session said.

### What it costs

One prefix listing of the ask records, inside the Agency actor that already
answers `Overview`. It is the listing `attention.summary` makes, bounded by the
open and settled ask counts (`attention.max_open_asks` open, settled ones
pruned past 200), and it reads no transcript. About 12 bytes in a row that is
bounded at 2,300. A resident that cannot read its ask records answers an
`unknown` row, as it does for any failed read.

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

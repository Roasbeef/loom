# protocol-change/121: a glance for `main`

**Status**: ACCEPTED 2026-11-18, amended the same day with the route rule
below. The owner accepted autonomous protocol changes for the attention inbox
build on 2026-11-17.
**Affects**: the glance writer, which also writes a glance for `main`; the
ordering of the glances in a `sessions.activity` row; and two terminal
readers, which must ignore the glance of `main`. No wire frame, command,
event, stored-cell shape or `loom.toml` key changes.
**Raised by**: phase 1 of the attention inbox
(`docs/design-notes/attention-inbox/README.md`, section 4, "Phase 1": "the
harness also starts writing a glance for `main`").
**Builds on**: `core/glance` (the cell shape and its key) and
`client/glance` (the writer). **Implemented**: `client/glance`,
`client/peer_mail`, `tui/session_selector`, `session_view/agent_roster`.

## Problem

The attention inbox's Updates group shows what a working session is doing now,
in one line. Phase 0 can show only two things for a session with no
sub-agents: that it is working, and the text of its last finished turn.

The `sessions.activity` row's `last_message` is the text of the last
finished turn of `main`, read from `session.last_result` and trimmed
(`client/peer_mail.gleam`, `overview`, which reads `last_result` and
`final_message`). While a turn runs, that text is the previous turn's, so it
is stale in exactly the case the Updates group exists for.

The row's glances do carry current work, but the glance writer does not write
one for `main`. `is_watched` returns false for the primary strand and the
advisor (`client/glance.gleam`, `is_watched`), and the writer's `stepped`
consults it before planning a request (`client/glance.gleam`, `stepped`). The
module documentation gives the reason: the terminal shows both from data it
already has. The test asserts it (`client/glance_test.gleam`,
`the_primary_and_the_advisor_are_not_watched_test`, which asserts
`!glance.is_watched("main")`).

## What was considered

### Deriving a line without a model

The harness could build a line for `main` from the running tool's name and
arguments. It would cost no summarizer call, but it would be a second
implementation of what the glance loop already does for every other strand, with
its own rules for clipping, for staleness against the current operation and for
the pacing that bounds cost. It is rejected in favour of using the same loop.

### Showing the transcript's own tail

The live mode lifts a session's pending approval, failed calls and results from
its own transcript. That is the page's classifier over lane entries and is
unchanged. It needs the session open on the page, and the Updates group lists
sessions that are not.

## Decision

### The writer

The glance writer MUST also write a glance for `main`, but only when the
glance target resolves to a `summarize` or `subagent` route, and never when
`glance.target` falls back to the `main` role. The loop knows the route
(`glance.route`, a two-variant `Route`, `Cheap` or `MainOnly`, carried in
`Wiring`), and `is_watched(strand, route)` returns false for the advisor and,
on a `MainOnly` route, for `main`. Sub-agents are watched on either route.

The reason is cost and fixtures. With `summarize` unrouted, which is the
default (`docs/configuration.md`), a glance of `main` would be a paced request
to the main model for every working turn, a spend the owner did not ask for.
Main-only scripted fixtures would also receive a request they did not script.
The glance of `main` is therefore a request to a model the operator routed for
that purpose, and a session without one behaves as it did before.

Everything else about the writer is unchanged: the
cell is `client/glance/main` (`core/glance.gleam`), written with
`api.put_reserved_fact` (`client/glance.gleam`, `write`), clipped to the
cell's bounds, and describes one operation, so it is shown only while that
operation is the strand's current one.

The advisor stays excluded. Its strand is not a participant the owner reads
about.

### The terminal

The terminal draws `main` from its own data and MUST ignore the glance for
`main`, so nothing is drawn twice. Today nothing in the terminal ever sees a
glance for `main`, so two readers need an explicit exclusion.

| Reader | Change |
|---|---|
| The strip and roster (`session_view/agent_roster.gleam`, `current_glance`, which looks a glance up by strand name) | The primary, `agent_roster.primary`, is never given a glance, so its line stays the deterministic activity it shows today. |
| The session selector's STRANDS section (`tui/session_selector.gleam`, `glance_lines`, applied to every glance of the row) | A glance whose `strand` is `main` is not drawn. |

### The activity row

`sessions.activity` keeps its bound of four glances (`client/peer_mail.gleam`,
`overview_glances`). `current_glances` sorts glances newest first and keeps four
(`client/peer_mail.gleam`, `current_glances`). `main`'s glance MUST be ordered
first when it is present and current, then the others newest first, and the
list is cut to four after that ordering.

The order matters for the row's size bound. When an encoded row exceeds
`overview_row_bytes` (2300), `fit_overview` removes glances from the end of the
list, one at a time, before it removes the final message
(`client/peer_mail.gleam`, `fit_overview`, which keeps `list.take(glances,
list.length(glances) - 1)`). A glance first in the list is the last one removed.
`main`'s is therefore the one that survives the bound.

A reader of the row identifies `main`'s glance by its `strand` field, the
same field every glance line carries. The row's shape is unchanged.

## What it costs

- One more request per paced refresh, for `main`, to the `summarize` role or,
  when that is unrouted, the `subagent` model; never to the main model, since
  `main` is not watched on a `MainOnly` route. The pacing
  applies to `main` as to any strand: a refresh at most every 20 seconds, at
  most three requests at once across the session, a strand asked only when a
  step has committed since its last request, failures backing off to five
  minutes and a strand forgotten after ten quiet minutes
  (`client/glancepace.gleam`, `default_pace`). The loop already spends a
  request per running sub-agent on that schedule. `main` is active in every
  working session, so a session with no sub-agents now spends requests it did
  not.
- The glance is model-written summary text. It is untrusted and MUST be drawn
  as text. It is written by the harness into a reserved cell, so the model
  cannot write it directly, but the words are the summarizer's.
- With four glances in the row and `main`'s first, a session with four or more
  working sub-agents shows at most three of them in `sessions.activity`. The
  row carries `main`'s glance in place of the fourth.
- The terminal gains two exclusions that must be kept in step with the writer.
  A future reader of the cell that does not exclude `main` shows it twice.

## Verification

- `client/test/client/glance_test`: `is_watched` is true for `main` on a
  `Cheap` route and false on `MainOnly`, true for sub-agents on both, false for
  the advisor on both; `glance.route` is `Cheap` when `summarize` or `subagent`
  is routed and `MainOnly` when only `main` is. On a cheap route a step on
  `main` writes `client/glance/main` and the sub-agent's request still names
  its own task and asks for a title; on a `MainOnly` route a step on `main`
  asks nothing and writes nothing.
- `client/test/client/peer_mail_overview_test`: with a current glance on
  `main` and four on sub-agents, the row holds four glances and the first is
  `main`'s; a glance for `main` whose operation is no longer current is
  dropped as any other is. That `main`'s glance is the last shed from an
  oversized row follows from its being first and `fit_overview` shedding from
  the end; no row of four bounded glances reaches `overview_row_bytes`, so
  the shedding itself is not exercised.
- `tui/test/session_picker_layout_test`: a row whose glances include `main`'s
  draws the other glances and not `main`'s.
- `tui/test/agent_strip_test`: with a glance cell for `main` in the capture,
  the roster holds no glance for it and the `main` row's line is unchanged.

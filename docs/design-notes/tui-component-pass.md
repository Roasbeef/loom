# TUI component pass

Status: Phases 1 and 2 implemented, reviewed, and verified through `157c5207`,
September 21, 2026. The implementation baseline is `ef469716` on PR 478. The PR
is open and ready for review; it has no automatic merge. This note records
settled scope and the evidence each phase must produce. Later phases remain
planned.

## Purpose and constraints

This pass improves six existing operator surfaces without changing their
authority or transport. It may repair a directly adjacent presentation or state
gap found while implementing a phase. It does not authorize unrelated features.

All phases reuse etui, [`tui/theme`](../../packages/tui/src/tui/theme.gleam),
and [`tui/appearance`](../../packages/tui/src/tui/appearance.gleam). Selection
uses a full-row focus treatment plus a text marker that survives no-color mode.
Extract a small reusable component only after two real call sites need the same
behavior. Add no dependency, UI framework, FFI, frozen-interface change, wire
message, or mutation capability. Preserve the existing compiler boundaries that
keep rebuilds bounded.

The server and captured state remain authoritative. Missing evidence stays
unknown; an old observation stays visibly stale. A receipt is evidence that a
send reached the existing delivery boundary, not that a person or model read it.
Progress, completion, relationships, and authority must never be inferred from
color, layout, or an idle phase.

## Serial execution

Each phase follows the same sequence:

1. Root writes a source-grounded brief naming the existing state, reducer,
   renderer, commands, and tests that own the behavior.
2. One Sol worker implements that phase. No other phase begins concurrently.
3. Root reviews the diff, runs focused checks and the full TUI gate, then tests
   the native renderer at 132×42, 80×24, and 40×12.
4. An independent review checks the phase's authority, provenance, focus,
   narrow-layout, and stale-state invariants when those risks apply.
5. Root resolves findings and creates one atomic commit before briefing the next
   phase.

At the end, refresh the package documentation and this note, run the relevant
documentation and lint gates, and report local, full-repository, and hosted-CI
status separately. Record test counts, timings, screenshots, skips, and failures
only after they are observed.

## Phase 1: agent messages

Replace the current prose-like message detail with a selectable list keyed by
invocation identity. Each row shows direction, an observed-delivery badge, and a
bounded body preview. The selected row exposes its full retained detail without
turning an accepted or started result into a read receipt. The client continues
to retain the latest twenty observed sends rather than claiming complete message
history.

`[` and `]` change the selected message. Up and Down change the inspected agent.
Tab transfers focus to the existing composer. Enter opens the inspected agent as
the existing composer recipient. `o` explicitly opens the selected sender's
transcript. Preserve per-recipient drafts, the current recipient until an
explicit change, and the provenance rules in
[`agent_messages`](../../packages/tui/src/tui/agent_messages.gleam). A message
occurrence remains identified by its captured invocation, sender, operation,
and branch rather than body text or a reusable call ID.

Acceptance evidence must cover both directions, missing results, accepted and
started receipts, repeated call IDs, operation completion, retained selection,
composer focus, explicit transcript opening, and all three terminal sizes.

### Phase 1 evidence

Independent review found that a new capture reset body scroll and that a short
wide panel could hide the body. Both findings were fixed and the reviewer
confirmed the repairs. The first root-run full TUI gate then passed 676 tests in
16.11 seconds. A native pass at 132×42, 80×24, and 40×12 verified bracket
selection, `o` opening the sender and changing the composer recipient, and
compact PgDn advancing to the next wrapped line. A later native finding gave the
wide list three rows per message: direction, short observed-result badge, and
excerpt, so the earlier gate was not the closing result.

The [wide capture](tui-agent-workspace/messages-component.png) and
[40×12 capture](tui-agent-workspace/messages-component-40.png) have adjacent
ANSI recordings. After the obsolete test labels were corrected, the closing TUI
gate passed all 676 tests with exit zero in 9.16 seconds. This was an incremental
gate; the prior measured compile was 7.38 seconds.

## Phase 2: agent notes

Use one note-list and detail presentation in both standalone `/notes` and the
agent inspector. Highlight the stable note key and show owner, revision, and
freshness as quiet header facts. Retain readable and raw forms. Preserve the
selected key and transcript position through refresh and reorder; a reply for a
different owner cannot replace the visible board. At narrow widths, stack the
list and selected detail without losing identity or controls.

Build on [`notes_view`](../../packages/tui/src/tui/notes_view.gleam) and the
existing read path. Acceptance evidence must distinguish current, historical,
stale, unavailable, malformed, empty, and reordered notes in both entry points.

### Phase 2 evidence

Commit `157c5207` installs one notes browser for the agent inspector and
standalone `/notes`. Note display mode and body scroll are independent of
transcript detail mode and transcript scroll. Entering a different owner resets
to that owner's first key; refreshing the same owner retains its key and clamps
the existing scroll to the refreshed body. Only the selected body is formatted,
and its modifiers and links survive rendering. Compact layouts keep stale and
omitted facts visible and size the body from the available height.

`[` and `]` select notes, Ctrl+g switches the selected note between readable and
raw form, PgUp/PgDn scroll its body, and `r` refreshes it. Independent review
found five issues; all five were fixed and reverified. The same pass repaired an
adjacent message-body overscroll boundary. Native QA covered 132×42, 80×24, and
40×12 inspector layouts plus standalone `/notes` at 80 columns, including raw
mode, selection, and controls. The [wide capture](tui-agent-workspace/notes-component.png)
and [40×12 capture](tui-agent-workspace/notes-component-40.png) have adjacent
ANSI recordings.

The closing TUI gate passed all 678 tests with exit zero in 9.30 seconds. It was
an incremental run, so it establishes no fresh compiler timing.

## Phase 3: goals

Group status, objective, budget consumption, latest check result, and reviewer
feedback into one coherent card. Budget is consumption against the configured
bound; it is not completion percentage. The card must keep status, phase, cause,
and missing observations distinct.

Offer Pause or Resume only when the captured state makes that existing operator
command applicable. Route the action through the current `/goal` command path.
Do not introduce automatic mutations, new wire messages, or another authority
for setting, completing, clearing, pausing, or resuming a goal. Preserve the
read-only automatic `goal_get` behavior and the semantics documented in
[`goal_view`](../../packages/tui/src/tui/goal_view.gleam) and
[`goals.md`](../architecture/goals.md).

Acceptance evidence must cover an absent board and the pinned states Active,
Paused, Limited, and Complete. It must distinguish `Paused(ByAbort)` from other
pause causes rather than inventing an aborted terminal state. Every pinned board
must show its required budget fields and consumed amount; budget unavailability
belongs to an unavailable board, not to missing fields on a pinned goal. Cover
check and reviewer absence, explicit Pause/Resume dispatch, and narrow rendering.

## Phase 4: queued inputs

Make queue, steer, and read-only state visible as text badges. Selecting an item
shows its complete fetched message and makes the existing revision-safe edit
actions easy to find. Preserve the current fetch-before-edit, authoritative
revision fence, conflict handling, and retained local draft in
[`queue_editor`](../../packages/tui/src/tui/queue_editor.gleam). Presentation
must not add a deletion, reorder, replacement, or delivery capability.

Acceptance evidence must cover queue versus steer priority, unavailable and
read-only state, long full-message detail, changed authoritative text, stale
revision refusal, local draft preservation, focus ownership, and narrow layout.

## Phase 5: diff navigation

Give the existing worktree observation a selected-file list with status accents,
a sticky file header, and explicit focus hints. Reuse the current patch renderer
and line numbering; do not build a second diff interpretation. Narrow terminals
stack the file list and patch. The UI must always say whether navigation or the
composer owns the keys, and switching ownership must preserve both the selected
file and composer draft.

Acceptance evidence must cover added, modified, deleted, binary, empty, and
unavailable observations; multi-file selection; patch scrolling; focus transfer;
refresh; and the three native terminal sizes.

## Phase 6: context and summary

Group measured context, usage, completion evidence, and live jobs into a
scannable summary. Keep cumulative session accounting separate from the latest
measured request. Completion comes only from the captured terminal result. Live
jobs remain a separately refreshed observation, as defined by
[`live_jobs`](../../packages/tui/src/tui/live_jobs.gleam); they are not progress
bars or proof that the completed run still owns work.

Where the existing facts contain selectable job identity and detail, expose it.
Do not invent detail from a label or add a new observation command. Preserve the
current refresh actions and label unknown, stale, omitted, malformed, and
unavailable states directly.

Acceptance evidence must cover measured and missing context, cache and output
accounting, success/failure/abort completion, zero and multiple live jobs,
omitted jobs, refresh transitions, stable selection, and narrow layout.

## Evidence ledger

Phases 1 and 2 are verified by commits `27da4a7d` and `157c5207`, their closing
TUI gates, native captures, and independently confirmed review repairs recorded
above. For later phases, focused and full gate results, timings, native captures,
review findings, and commit IDs remain pending. The final documentation refresh
must repair the known line-citation drift in `docs/architecture/advisor.md` and
add the new panels to the `docs/architecture/client.md` code-location table.
Avoid churning those anchors between phases. The final full-repository gate and
hosted CI also remain pending. The unrelated `.blobs/` directory is outside this
work and must remain untouched.

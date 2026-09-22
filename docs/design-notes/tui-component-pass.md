# TUI component pass

Status: all six phases implemented, reviewed, component-verified, and pushed at
`ff4c5fa3`, September 22, 2026. The inline queue follow-up is committed at
`6c796795`, with test calibration at `0003f32f`. Its closing full-repository
gate and hosted validation remain pending.

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

Commit `c599661c` installs one notes browser for the agent inspector and
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

### Phase 3 evidence

Commit `62a43f93` adds a raised, independently paged goal inspector.
It groups status and cause, objective, token and cost consumption, continuation
count, pinned and updated ages, the latest check and its output, and reviewer
feedback. `r` uses the existing `goal_get` read, `p` uses the existing pause
command only for Active, and `c` uses the existing resume command only for
Paused or Limited. PgUp, PgDn, Home, and End own the viewport; Escape restores
the unchanged composer. While a correlated request is pending, the card disables
actions and waits for the server board rather than predicting a transition. On
a busy 40×12 fixture, the goal temporarily owns the space otherwise consumed by
status bands while preserving the actual editor and footer, so status, objective,
and controls remain visible.

Independent review findings, including stale-board retention, warning and scroll
placement, and compact geometry, are closed. Native QA typed `/goal` and pressed
Enter through the real palette path, then inspected 132×42, 80×24, and 40×12.
End reached reviewer feedback, Home returned to the start, the wide gutter was
clear, and the compact busy fixture retained status, objective, and controls.
The [wide capture](tui-agent-workspace/goals-component.png) and
[40×12 capture](tui-agent-workspace/goals-component-40.png) have adjacent ANSI
recordings.

The closing TUI gate passed all 685 tests with exit zero in 9.15 seconds. It was
incremental; the latest worker compile took 7.75 seconds.

## Phase 4: queued inputs

Make queue, steer, and read-only state visible as text badges. Selecting an item
shows its explicitly captured excerpt and makes the existing revision-safe edit
actions easy to find. The complete document remains available through the
existing fetch-and-edit path; a read-only item cannot fetch it. Preserve the
current fetch-before-edit, authoritative revision fence, conflict handling, and retained local draft in
[`queue_editor`](../../packages/tui/src/tui/queue_editor.gleam). Presentation
must not add a deletion, reorder, replacement, or delivery capability.

Acceptance evidence must cover queue versus steer priority, unavailable and
read-only state, long full-message detail, changed authoritative text, stale
revision refusal, local draft preservation, focus ownership, and narrow layout.

### Phase 4 evidence

Commit `cc7e0671` adds `queue_panel`, which renders selectable `[QUEUE]` or
`[STEER]` rows with `[EDIT]` or `[READ-ONLY]` access. Its selected preview says
that the text is a captured excerpt and owns a scroll offset separate from the
editor and composer.
Up/Down changes identity, PgUp/PgDn pages the excerpt, and Enter fetches the
complete revision only for an editable item. Read-only input remains inspectable
but cannot request complete text.

The existing revision-fenced editor retains full source and attachments. Its
styled header names priority, delivery state, Ctrl+s save, Ctrl+r reconcile,
Escape, and newline behavior; it adds no mutation. Source review is closed,
including fixes that pad by terminal cell width and clamp the render offset after
a resize.

Native QA opened `/queue`, reopened the fixture's retained draft, and returned
with Escape to the inspector. It covered 132×42, 80×24, and 40×12, arrow
selection, and a read-only Enter refusal. The wire fetch of complete text is
covered by automated tests, not this no-daemon native fixture. On the compact
view, PgDown reached the tail of a twelve-line excerpt; resizing to 132 columns
without another key restored the visible start instead of leaving a blank
preview. The
[wide capture](tui-agent-workspace/queue-component.png),
[40×12 capture](tui-agent-workspace/queue-component-40.png), and
[editor capture](tui-agent-workspace/queue-editor-component.png) have adjacent
ANSI recordings.

The closing TUI gate passed all 687 tests with exit zero in 9.29 seconds. It was
incremental; the latest compile took 8.02 seconds. Native testing submitted no
mutation to a real daemon.

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

### Phase 5 evidence

Commit `8a568ae3` gives rendering, keyboard navigation, mouse hits, and
wheel routing one shared geometry. It presents a status-accented file list, a
full-row selection marker, a sticky selected-file header, and the existing patch
rows. Navigator and Composer are explicit focus states. Up/Down selects a file,
`r` refreshes, PgUp/PgDn scrolls the patch, Enter returns to the composer, and
Ctrl+d re-enters navigation.

The panel reuses the existing patch renderer, numbering, selected raw identity,
and patch cache. On a short terminal, focused navigation may borrow status-band
space only above the actual editor; the editor and footer remain owned by the
composer. Compact mode retains the observation line and a readable Navigator
help title.

Independent review is closed after repairs to active wheel bounds, focus-time
cache clamping, and the overlay borrowing guard. Native QA covered 132×42,
80×24, and 40×12. Arrows selected an added file and its patch; compact PgUp/PgDn
reached both start and tail. Enter returned to the composer, typing `retained
draft` and pressing Ctrl+d preserved both draft and selected file, and F2
replaced the borrowed view. Automated tests cover mouse hits and wheel routing;
the native pass did not exercise a physical mouse. The
[wide capture](tui-agent-workspace/diff-component.png) and
[40×12 capture](tui-agent-workspace/diff-component-40.png) have adjacent ANSI
recordings.

The footer-one-row snapshot was regenerated only for the intentional diff rows;
inspection confirmed that its footer and editor were unchanged. The closing TUI
gate passed all 692 tests with exit zero in 9.30 seconds. It was incremental;
the latest compile took 8.15 seconds.

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

### Phase 6 evidence

The current `context_panel` presents estimated context capacity against the
model window, its estimate basis and durable sequence, aligned component
estimates, the compaction boundary, and optional bounded item inventory. It says
that component estimates are independent and need not sum to the headline. Its
observation line distinguishes last observation, refresh pending, another queued
refresh, and unavailable state. Paging is clamped to the current geometry and
the ordinary composer draft remains outside the inspector.

The current `summary_panel` separates Completion, Usage, and Jobs. Completion
shows only captured terminal outcome, ancestry coverage, final assistant entry,
file-tool evidence, and tool results. Usage distinguishes cumulative all-strand
accounting from the latest measured active request. Jobs is a separately
refreshed roster: `[` and `]` retain a selected stable job identity and expose
only its captured command excerpt, owner, age, and deadline facts. Keys 1, 2,
and 3 change section, `r` refreshes jobs, and page keys scroll the selected
section.

Independent source review is now closed after fixes for bounded evidence,
relative job timing, wrong-strand rosters, and render purity. Native `/summary`
verified sections 1, 2, and 3 at 80 columns. Completion showed a completed
`sub:viewport-review` operation and correctly remained missing on active `main`.
Jobs at 132×42 and 40×12 retained immediate bracket-selected identity; paging
reached timing and roster detail, and `r` reset the viewport before refresh.

The real Preview `/context` path correctly refused a live observation. The
provider-free `run_context` Replaying fixture opened an explicitly illustrative
board at 132×42, 80×24, and 40×12. It showed capacity, component estimates, and
the compaction threshold; `a` opened inventory and paging reached the three-item
omission tail. These fixtures made no daemon or provider call and performed no
mutation.

The compact context help now keeps `Esc` visible at 40 columns. All six final
PNGs and their adjacent ANSI recordings were inspected:

- [context, wide](tui-agent-workspace/context-component.png) and
  [context, 40×12](tui-agent-workspace/context-component-40.png);
- [jobs, wide](tui-agent-workspace/summary-jobs-component.png) and
  [jobs, 40×12](tui-agent-workspace/summary-jobs-component-40.png);
- [completion, 80×24](tui-agent-workspace/summary-completion-component.png);
- [usage, 80×24](tui-agent-workspace/summary-usage-component.png).

The focused 13-test pass compiled in 8.44 seconds. The closing TUI gate passed
all 693 tests with exit zero in 9.46 seconds; it was incremental. The private
native tmux fixture was closed and made no daemon or provider call.

## Evidence ledger

All phases are component-verified by rebased commits `8622ce94`, `c599661c`,
`62a43f93`, `cc7e0671`, `8a568ae3`, and `1b04a549`. Their recorded timings and
captures were produced before the rebase; the corresponding TUI source commits
are unchanged apart from commit identity. Their closing TUI gates, native
captures, and confirmed review repairs remain the evidence recorded above. The
final full-repository gate passes at `3ce4d7ce`. The completed pass was later
pushed at `ff4c5fa3`; its current hosted-CI exception is recorded below. The
unrelated `.blobs/` directory is outside this work and must remain untouched.

## Post-rebase validation

The tested code is `3ce4d7ce`, based on `f440f381`. Commit `ec62d0fa` corrected
the real-context end-to-end label, and `3ce4d7ce` strengthened the
styled-approval end-to-end assertions. The first full `make check` reached 2,036
client passes before five failures. Two newly merged code-mode examples used an
offline seed from before the `cap` and `notes` APIs. `make codemode-seed` passed,
after which the real code-mode suite passed all 15 tests, including notes and
recipes.

The other three failures were stale semantic UI expectations: `CONTEXT USAGE`
had become `CAPACITY`, `ITEM ESTIMATES` had become `INVENTORY`, and `PERMISSION
REQUEST` had become `Permission required`; the multiplayer fixtures also needed
the concrete command preview and opening raw details before checking the
captured sequence. The fixes change tests only. They do not change production
lifecycle behavior or weaken a deadline.

The five real TUI end-to-end tests, the approval-effect test, and both
multiplayer tests passed in focused runs. The final full `make check` then
passed with exit zero: 2,041 client tests, 693 TUI tests, 306 code-mode tests, 83
conformance tests, and 139 lint tests, along with every other package, the
sandbox Go checks, and release-update checks. The house lint reported zero
errors and 842 warnings. `make doc-check` separately passed with zero errors and
152 warnings.

The built-in shipped-daemon tests remained skipped because
`LOOM_BOOTSTRAP_E2E_SERVER` was unset, as did the real MCP process-death case on
macOS because `/proc` is unavailable. The task-owned native capture client and
its private `loom-visual-review` tmux session are stopped; the installed daemon
was untouched. Push and hosted CI were pending at this validation point; the
status above and follow-up record below supersede that snapshot.

## Inline queue follow-up: final validation pending

Commit `6c796795` places queued messages above the composer, with message text before their
priority and access badges. `Alt+q` and bare `/queue` focus the same bounded
inspector while retaining the transcript, ordinary draft, and attachments.
The queue reserves its rectangle before transcript rendering. The passive
card shows up to three entries; the focused inspector owns selection and
excerpt paging within that rectangle.

Opening the inspector always browses the captured queue. `e` explicitly
resumes a retained edit, and Escape returns first to inspection and then to
the composer. A clean editable draft permits fetching another item. A dirty,
Saving, or Unknown draft prevents a fetch from replacing it with another item
or namespace. Resuming also clears pending fetch ownership, so a late reply
for another item cannot replace a draft the operator has resumed editing.
Ctrl+s remains the explicit save action, with the existing owner, namespace,
and revision checks.

Independent source review found and closed four issues: a late fetch replacing
a resumed draft, capture refresh using fullscreen paging geometry, compact
excerpt text becoming unreachable, and clicks on controls selecting list rows.
Compact rendering and paging share the displayed excerpt width. When a 40×12
card has no inner row beside a multiline draft or active status, its title
pages the excerpt. Both title and body clamp offsets on resize.

All 22 focused queue tests pass; the source rebuild took 9.04 seconds and the
incremental compile took 0.5 seconds. Native verification covered the passive
card, Alt+q inspection, and
explicit draft resume at 132×42, preserving the ordinary composer throughout.
The editor and cursor were checked at 80×24. At 40×12, an active status and two
wrapped composer rows left a paged title; paging reached the final
`reached.` text. A width-only resize to 80×12 immediately showed the complete
`Native paging tail reached.` line. Escape restored composer focus without
saving.

The private fixture is stopped.

The [passive card](tui-agent-workspace/queue-inline-wide.png),
[inspector](tui-agent-workspace/queue-inline-inspector.png),
[editor](tui-agent-workspace/queue-inline-editor.png), and
[compact view](tui-agent-workspace/queue-inline-40.png) have adjacent ANSI
recordings. Each capture was inspected during native verification. The closing
full-repository gate remains pending.

The approval review comment about the hidden action digest was assessed against
the capture-to-decision path. Readable mode presents the action preview and
requested grants; raw mode retains the exact escaped digest. The panel keeps
its captured `Review`, and confirmation echoes its digest, grants, and sequence
without a fresh lookup. The gateway checks the sequence and action before
committing approval. Displaying the hash by default is a presentation choice;
omitting it from readable mode does not change the consent binding. The bounded
preview remains the existing visibility limit, which displaying a hash would
not remove.

Hosted CI for the completed six-phase head `ff4c5fa3` passed every job except
the Linux client job. Its retry repeated an MCP timing failure. The test-only
repair in `0003f32f` changes the shared shutdown budget from 100 ms to 500 ms and checks an aggregate bound of
3,000 ms. That bound accommodates the existing 1,000 ms collector margin and
scheduler delay while rejecting eight sequential 500 ms waits. Six correct
runs passed at about 532 ms; an actual serial mutation took 4,010 ms and failed
the assertion.

Independent source review confirmed that production deadlines are unchanged.
`make doc-check` passed with zero errors and 153 warnings. Hosted validation of the repair remains pending. The failed hosted result
predates the inline queue follow-up.
The prior local full-repository gate at `3ce4d7ce` remains historical evidence,
and does not establish validation of these follow-up commits.

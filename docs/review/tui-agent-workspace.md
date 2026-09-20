# Agent workspace review, September 20, 2026

Base: `9c9bb576`. Scope: the native agent workspace, draft/history ownership,
full advisor nudges, palette adaptation, and their tests. One independent
report-only review covered invariants, simplification, and same-shape variants.
A targeted follow-up checked the three repairs; it was not another broad pass.

## Dispositions

1. **Returned held input crossed strand ownership. Confirmed and fixed.**
   The gateway returns a held prompt to its submitting connection even when the
   operator has since opened a worker. `restore_returned_draft` now updates the
   active editor only when the event's strand matches; otherwise it appends to
   the saved `(session, strand)` workspace. The regression keeps the worker
   draft unchanged and restores both pieces of main's draft on return.
2. **A stale pending approval replaced terminal status. Confirmed and fixed.**
   Escalation timeout can leave a pending journal record after its waiter ends.
   `agent_view.observe` now gathers attention-producing approvals only for a
   live working/waiting operation. Completed, failed, and aborted regression
   cases retain their authoritative outcomes and expose no stale approval.
3. **Session adoption retained advice and goals from the old session.
   Confirmed and fixed.** `select_workspace` clears these observations and
   their request bookkeeping when the session changes. Session identity is
   also a refresh edge. The adoption regression covers idle-to-idle replacement;
   the follow-up caught running-to-running goal refresh, which is now covered
   by the goal-action test.

The related legacy `FullSnapshot` path now selects the correct workspace too.
Live v2 drops that event, so this repair serves older recordings and fixtures.

No further actionable finding was reported in exact approval authority,
successor excerpt ownership, or palette cell preservation. The reviewer did
not run tests; the implementation session ran the gates documented in
[the implementation note](../design-notes/tui-agent-workspace.md).

## Explicit limits

Draft preservation spans session changes; frozen history and reading-position
restoration span strand switches within one session. Session changes release
old history buffers. Native fixture captures demonstrate renderer behavior,
not real provider outcomes. The client now attaches after other clients released admission. A provider-backed request has not run; local fixtures do not establish real provider behavior.

## Complete layout follow-up

The second implementation pass adds Focus framing, compact tool disclosure,
Studio sections, workspace typing, named wait dependencies, recent tools, and
exact pending-decision previews. A fresh independent review found three
reachable presentation/input paths:

1. **Hidden diff keyboard ownership. Fixed.** Entering the workspace composer
   now transfers ownership from the diff navigator. Choosing the navigator
   again exposes the diff surface instead of concealing it behind inspection.
2. **Commands opened behind inspection. Fixed.** Help, notes, context, queue,
   summary, diff, and overlays retain their ordinary surface ownership. The
   workspace returns only after an ordinary editor action. Reducer regressions
   cover both transitions and opening from previously visible help.
3. **Generic failures lost multiline diagnostics. Fixed.** Narrative-bearing
   calls and orphan results now use the same bounded diagnostic preview as
   grouped results. The regression failed on the old generic branch and checks
   both paths, the expansion hint, and exact full diagnostics after expansion.

The reviewer verified both input regressions and found no additional issue in
roster omission or shared composer measurement. Implementation validation also
updated the stale-cell regression's terminal height: compact failures now keep
eight diagnostic lines, so its 72-row pane again has an asserted blank tail.
It still verifies the expanded pane is full and every vacated cell is blank.

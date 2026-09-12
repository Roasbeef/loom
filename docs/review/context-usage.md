# Context observation review

The context inspector reads a bounded server projection rather than the TUI's
retained transcript. Protocol 030 records the accounting and compatibility
boundaries. Provider totals already contain the static prompt and tool schemas;
component estimates are displayed independently and never added to that total.

One fresh, report-only review covered accounting, compaction, observation
admission and cancellation, reply correlation, cached rendering, and terminal
input routing. All three findings were confirmed and corrected:

| Finding | Reachable sequence | Correction and regression |
|---|---|---|
| Strand switch loses the refresh | Switch strands after a pending acknowledgement while the original worker still holds the connection slot. | Retain its request ID as `RefreshAfter`, discard the old strand's result, then request the selected strand. The test drives both completions in order. |
| Refusal leaves a cached percentage | Refresh a previously observed board, then receive an unavailable response while idle. | Invalidate the frame when applying the refusal. The test checks both cleared data and the frame revision. |
| Wheel scroll reaches the hidden transcript | Open `/context all`, then scroll over the inspector. | Route wheel events to the visible inspector. The test preserves the transcript offset while moving the context offset. |

Unsupported-command state also survives strand changes within the same
attachment; a new attachment permits another attempt. The existing regression
now checks both transitions. No further production finding was reported.

Focused validation covers provider-baseline accounting, carried usage after
compaction, active tool inventory, escaped output bounds, invalid windows,
a real committed session projection, authenticated observation admission, and
request identity. All ten context TUI tests pass after the review fixes. The
native terminal fixture enters `/context`, expands its inventory, and returns
to the conversation without losing the settled response. The final local client suite passed 1,552 tests, including that native
fixture in 26.6 seconds; the TUI suite passed all 367 tests. The full local `make check` completed with exit 0 and reported 4,227 passing
cases; seed-dependent and shipped-server fixtures declined without their local
prerequisites. `make doc-check` also passed. Hosted CI and exact-head Linux
signoff remain separate acceptance gates.

# Queue, worktree, and completion review

The September 10, 2026 review covered the implementation against baseline
`822c5c8b`, including newly added modules and tests. One independent pass
examined invariants, simplification, and related failure paths. Each finding
below was checked against its reachable caller before changing code.

## Verified findings

| Finding | Repair | Regression |
|---|---|---|
| `live_jobs` was classified as a mutation when sent, but its roster required a read reply. A valid reply therefore closed the terminal channel. | Classify the command as a read at admission. | `live_jobs_is_a_read_and_its_correlated_roster_keeps_channel_ready_test`. |
| Worktree completion carried `reply_to` after the pending acknowledgement had already released that request. | Final ready/failed events are pushes without `reply_to`; the body retains the original request ID. | Domain wire assertions and `ready_push_before_pending_reply_survives_channel_correlation_test`. |
| An old queue draft could adopt an equal item ID in another session or incarnation during explicit refresh. | Retain session, epoch, and incarnation separately from the connection and refuse cross-namespace reconciliation. | `retained_draft_cannot_refresh_or_save_into_another_queue_namespace_test`, including same-namespace reconnect. |
| A generic protocol error cleared pending observations even when it belonged to another request. | Carry command and actual sent ID in `RequestRefused`; settle only the matching feature request. | `unrelated_correlated_and_pushed_errors_do_not_cancel_a_worktree_observation_test`. |

The same integration pass corrected reused client request IDs being used as
queue identity, preserved same-item unsaved text during explicit refresh,
retained complete summary evidence after history eviction, and used the patch
viewport height consistently for rendering and scrolling. Focused regressions
exercise those boundaries. No further concrete review findings remained.

## Full-gate integration repairs

The first full gate reached 1,529 passing client tests and two failures.
The local format-two decoder omitted the new request kinds from its closed
whitelist, so an automatic `live_jobs` request made the recording unreadable.
The decoder now accepts all four added commands and the existing `notes` read
as body-free descriptors. Round-trip and replay tests retain rejection of
unknown kinds and verify original request-slot correlation.

The approval/effect fixture had already executed its native action and verified
the winning author in the inspector. Its final history assertion assumed that
author was still in the newest 80-by-24 viewport. The completion card moved the
older approval summary above it. The fixture now scrolls the finite history
through real PageUp input before checking the same rendered author; authority,
execution count, and cleanup assertions remain intact.

## Joined acceptance

`joined_queue_worktree_and_completion_drive` uses a real daemon, websocket,
terminal driver, broker, and Git repository. A deterministic provider produces
a successful file edit, a command with actual exit code 7, and a live background
job. The terminal edits a complete multiline queued prompt, verifies revision
one, and the provider receives those exact bytes for the successor operation.
The summary attributes the preceding result and job while that successor is
active. The worktree navigator displays tool edits, an external edit, and an
untracked file, then selects an individual patch.

The focused joined run passed in 0.927 seconds of test time (7.99 seconds
including compilation and runner startup). It exercises the shipped TUI model
with a virtual display backend, rather than an external provider network or
interactive terminal emulator. Full repository gate results and integration
state are recorded in `docs/next.md` and the pull request.

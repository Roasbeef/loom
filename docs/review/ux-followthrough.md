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

## Direct native terminal follow-up

A separate tmux pane ran the shipped native client against a disposable daemon,
Git workspace, and loopback HTTP provider. Real tool execution edited `e.txt`,
returned bash exit 7, and started a background job. The completed operation card
showed its captured edit and a separate live-job count while a successor ran.
The provider later received the exact multiline input saved in the queue editor.

The native run found two gaps beyond the earlier independent review. First,
macOS terminal settings retained `ixon`, with Ctrl+s assigned to output stop.
The terminal consumed the advertised save shortcut. Disabling flow control only
in the disposable pane confirmed that the editor then saved successfully. This
isolated the native terminal setup issue in etui. The fork repair and repeat
native validation below close that gap.

Second, selecting a file changed its highlight without invalidating the outer
render cache. The patch could continue showing all files. The earlier test
forced a resize before painting and only checked that selected text was present;
the joined fixture also accepted that text within an all-file patch. The repair
invalidates selection and observation transitions and keys cached patches to
the board and selection that actually produced them. Tests now flush an ordinary
idle tick, exclude unrelated patch content, and cover keyboard, mouse, and
observation delivery before the next tick. The strengthened regression failed
before the repair.

The rebuilt native client showed only the selected external-file patch at
160-by-48 and retained it after resizing to 100-by-30. The joined daemon fixture
also passed with assertions excluding the other files' patch content.

After that repair, the complete TUI package gate passed all 312 tests. TUI lint
and the documentation gate reported zero errors. These are local results;
the earlier PR head has failing GitHub jobs and remains a draft.

At the prior head `947c6ee3`, GitHub run `34517952502` reported 1,529 passing
Linux client tests and two failures in the opt-in shipped live-delivery and
multiplayer fixtures. Both terminal deadline frames show the newest answers
and the completion card; their predicates still require every earlier answer
in the same 80-by-24 viewport. The Linux jail job also fails in that multiplayer
fixture. They were skipped in the earlier local gate because no shipped
server was set. The fixtures now inspect answers across eight real PageUp
frames and return to the newest viewport. Their exact record, author, order,
idle, and stream-settlement predicates remain unchanged.

A fresh `DIST_CODEMODE=0 make release` supplied the supported lean native
server for the two opt-in tests. Shipped live delivery passed in 6.74 seconds
including compilation and startup; shipped multiplayer passed in 5.15 seconds.
The tests ran with `LOOM_BOOTSTRAP_E2E_SERVER` set, rather than taking their
missing-server skip. This exercises their real server lifecycle on macOS;
it does not establish the next GitHub run or code-mode bundle acceptance.


## Etui flow-control repair

The fork commit `ff80e0e21580a4b0077cc6989b6dc551af320505` clears POSIX `IXON`
after OTP enters raw mode. It reuses etui's existing controlling-terminal
`stty` path and retains normal and watchdog `stty sane` restoration. This
commit directly follows `702a884`; all seven existing frame-diff, polling,
input-preservation, batching, benchmark, and documentation commits remain.
Loom's TUI and client declarations and generated manifests now use the new tip.
The resolver also refreshed the client's stale local-host requirement metadata
from the host's existing declaration; no other package version changed.

The new real PTY regression starts with software flow control enabled, waits for
an actual Ctrl+s acknowledgement, requires subsequent output without Ctrl+q,
and verifies restored canonical mode, echo, `IXON`, and alternate-screen state
after normal exit, SIGKILL, and SIGINT with `+B`. It fails waiting for Ctrl+s
against the old fork source and passes with the repair on macOS/OTP29. The fork
also passed 891 Erlang tests, 844 JavaScript tests, JavaScript smoke, and format
checks. The new Linux/OTP28 CI probe has not yet been observed running. A single
independent review of the change and both probes found no actionable issue.

A freshly rebuilt native `bin/loom` then ran in a disposable 160-by-48 tmux
terminal whose initial settings had `IXON` enabled. Etui disabled it on entry.
While the local provider held the first operation, the editor saved
`Native queue draft.\nSaved through native Ctrl+S.` using the advertised key.
The successor provider request contained those exact multiline bytes. No
manual terminal adjustment was applied after startup. The disposable client,
daemon, and provider were stopped after the check.

Loom's updated TUI package gate passed all 312 tests, its native shipment built,
and the joined queue/worktree/completion fixture passed. The approval/effect
fixture that failed in Linux CI at the preceding `dadecfce` head also passed in
a focused local rerun; this does not establish Linux success for the new head.
[Issue #345](https://github.com/Roasbeef/loom/issues/345) tracks upstreaming all
eight remaining fork commits and eventually returning Loom to upstream.

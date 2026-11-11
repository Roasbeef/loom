# Active UX work — September 11, 2026

This is an in-progress handoff, not a completion report. The local main checkout is
`d12e8f7ed6eb5999fdeec6621c1f1c1df5f6adc6`, the verified merge of #349.
The older `docs/next.md` still describes #349 as pending; that part is stale.
Preserve the separate worktrees and the user's running daemon and clients.

## Published work

| PR | Worktree | Pushed head | Current evidence / next gate |
|---|---|---|---|
| #348 tool progress | `.worktrees/pr348-review` | `ba2f2a300ea3a19714d01307d155a91f9987e8ca` | Full local `make check` passed; Linux signoff passed all six lanes in 671s, clean skip census, status posted. Hosted run 34652819142 passed all checks. Final review completed; merged as `6a484a4f67ef38eee8c76a7e0f6b5832696ea9af`. |
| #351 context usage | `.worktrees/context-usage` | `3bbe55198f50a5caf0597409c79ff281c28269ee` | Context-send notice regression failed before and passed after fix; TUI 368 and lint passed. Hosted run 34653778358 pending. Hosted Linux/macOS E2E now passed. Linux signoff failed one known atom-allocation fixture timeout (1551 other client tests passed; other five lanes green). One bounded retry queued after #352. |
| #352 Escape / held input | `.worktrees/escape-queue` | `97e8129b493af27e8152c6610dde40c08f09045a` | Client 1546, gateway 87, documentation/lint passed. Hosted run 34651698210 all 15 checks passed. Linux signoff now running; log `/private/tmp/ci352-linux-signoff.log`. |

The user authorized Obelisk checkout copying and GitHub signoff publication.
Use normal merge rules, exact head checks, no admin bypass. Merge authorization
is explicit for #348 and already executed for #349. Do not infer authorization
to merge the other PRs from green tests alone. Do not overlap heavy Obelisk gates.
Remote directories are `/home/roasbeef/loom-signoff-{348,351,352}`.

#351 has an unresolved shipped multiplayer rerun: the original deterministic
notice overwrite is repaired, and later runs passed that point and tool custody
but failed final reconnect with 503 capacity refusal. Do not label this green or
attribute it to a flake without evidence. Logs:
`/private/tmp/ci351-notice-check-tui.log`, `ci351-notice-lint.log`,
`ci351-notice-multiplayer.log`, `ci351-notice-multiplayer-rerun.log`.
`.worktrees/context-usage/.ci-loop/brief.md` has the detailed gate history.

## Transcript fixes — draft PR #353

Worktree `.worktrees/transcript-followup`, branch `tui/transcript-followup`,
rebased onto merged #348 (`6a484a4f`). Four commits are pushed through `60dcbc1d`; worktree is clean. PR: https://github.com/Roasbeef/loom/pull/353.

- Preserve a reading viewport even at offset zero, keep the End/click return
  path, and request older pages near the retained edge. The transcript already
  has a bounded history/render cache; do not replace it with full-history render.
- Give expanded tool results the compact call's stable source anchor so Ctrl-G
  does not jump when a large result expands. `Call.result_source` stores the
  completion entry identity, including completion-summary construction.
- Render historical notes as nested readable text, improve messaging payloads,
  show context_remaining measurements compactly, and insert bracketed paste
  without replacing an existing draft. New tests include
  `composer_paste_test.gleam` and `context_remaining_presentation_test.gleam`.
- Restore leading markdown indentation through wrapping. Three existing screen
  snapshots changed; inspect and update only after confirming intended layout.
- Show a persistent disconnected composer title, rather than stale responding
  status. This is presentation, not a proven repair of transport reconnects.

Focused history tests passed (20); two new history cases and the long-result
anchor regression fail on the baseline. Logs are
`/private/tmp/transcript-history-{focused,baseline}.log` and
`/private/tmp/transcript-anchor-baseline.log`.
The native package gate passed380 tests after rebase; the final Escape delta
then passed all381 tests. Lint0 errors88 warnings, doc-check0 errors137 warnings.
Independent review found the disabled-checkpoint wording bug, fixed with tests;
missing-details fallback also tested. Three indentation snapshots reviewed.
Logs: `/private/tmp/transcript-rebased-check.log`, `transcript-stop-tests.log`,
`transcript-stop-lint.log`, `transcript-final-doc.log`. A committed native shipment
is building for replay inspection. Hosted CI and Linux signoff remain pending.

## Reports still requiring investigation

1. **Escape cancellation error.** The latest screenshot shows
   `provider cancellation could not be confirmed (runtime: explicit stop)`.
   A successful user stop should be a normal stopped state. Trace the ownership
   and cancellation acknowledgement; do not hide an actual failed cancellation.
   Start with `packages/runtime/src/runtime/strand_runtime.gleam` around 1985–2070
   and `runtime/internal/provider_custodian.gleam`. This is separate from #352's held-input behavior. FIXED presentation in #353:
   durable Aborted now shows Stopped; diagnostic remains in expanded details.
   Root verified normalize_stop retains error text, while runtime requires provider
   drain before ProviderDone publication. Independent delta review found no issue.
   The reason acknowledgement was missing in the live provider is not established.
2. **Repeated fs_read calls.** The user asked to inspect the live session database
   after the UX fixes, distinguishing model repetition from duplicated UI output.
   This analysis has not started. Use a read-only SQLite backup including WAL;
   keep private transcript data local. Do not upload it to review services.
3. **High live daemon CPU.** PID 16570 measured roughly one core busy and 1.1–1.3GiB
   resident. Our private inspector client PID 40900 was closed cleanly; load
   remained with the user's client. OS samples show UTF-8/binary construction,
   memory copies, and GC; SQLite appears but is not established as the cause.
   `/private/tmp/loomd-16570-live-sample.txt` holds the sample. JIT frames were not
   resolved to Gleam functions. A brief LLDB attach failed and detached. No
   restart, hot reload, code injection, or daemon termination was performed.
4. **Disconnect and scrolling videos.** Long and short recordings have only been
   partially examined. Latest Ctrl-G short video frames are under
   `/private/tmp/loom-scroll-new/`. Check remaining diff-panel frames and live
   acceptance before closing the user's report. Reconnect footage shows failure
   followed by recovery; transport cause remains unproved.

Private daemon session: `01a09244-535d-7cc1-beeb-8da1658eec67`, database
`~/.loom/sessions/01a09244-535d-7cc1-beeb-8da1658eec67.db`; address
`ws://127.0.0.1:60742/v2/control`. Read credentials only through token-file APIs;
never print the owner token. The running server came from the separate
`loom-extensions` checkout. PID identity must be rechecked before any inspection.

## Working constraints and next actions

The user reported $28.68 remaining credit and wants focused completion plus a
reliable handoff. Avoid broad new review waves and repeated identical failed
integration reruns. Finish the existing gate sequence, preserve current work,
and prioritize reachable defects. Do not remove tests or silently reduce scope.
No user daemon/client restart or installation is authorized by the UX requests.

First refresh PR gates and finish #353 native replay/CI/signoff. #348 is merged.
#351 needs its bounded signoff retry; #352 is running. The repeated-read database and CPU attribution work remain explicit
acceptance items after the UX fixes. Update this ledger as each item closes.


## Latest verified findings and handoff artifacts

PR #353 is published at `60dcbc1db3f3892dc48748121cf31683550c27ad`.
The committed native shipment replayed the existing real transcript successfully;
its former red cancellation diagnostic now renders as Stopped. The replay output
and local validation logs are saved under `.sessions/handoffs/ux-2026-09-11/`.
These files and the database snapshot contain private conversation content and
must remain local; do not stage or upload this handoff artifact directory.

Read-trace analysis is complete to the requested distinction: the database has
2,473 entries,1,244 tool calls,79 fs_read calls,40 distinct fs_read argument sets.
Identical `{path: packages/client/src/client/hookserve.gleam, limit:6}` occurs13
 times with13 distinct provider call IDs and successful results. Sequence15104–15382
shows consecutive small reads without an offset and the unchanged digest
`2acfebf39721c2d6-18562`. At15389 the model explicitly identifies its own loop,
reads offset433, then begins an edit at15404. This establishes actual repeated
model calls, not duplicated TUI output. It does not by itself justify adding
retry logic or suppressing legitimate rereads. The script, call index, and WAL-
consistent read-only snapshot are saved in the private artifact directory.

The latest CPU observation still shows PID16570 at112.6% CPU and1,168,112KiB RSS.
The session database contains only5.46MB of entry payloads; that does not account
for all process memory or establish a leak. Native profiling was performed;
UTF-8/binary construction and GC dominate visible frames. The exact Gleam caller
remains unresolved. No JIT perf map is present and the daemon has no distributed
node configured. Do not claim SQLite is responsible or restart the user daemon
just to improve attribution without authorization.

#353 Linux copy/signoff was blocked by automatic approval review as a private-
repository transfer requiring explicit approval for this PR. An async question
is pending to authorize copying source to `/home/roasbeef/loom-signoff-353`,
running signoff, and publishing its GitHub result. Do not bypass this rejection.
#351 hosted CI is fully green; its one bounded Linux retry waits after #352.


## Usage-budget checkpoint

The user now reports $8 remaining and requests the handoff in the PRs. Public-
safe continuation sections have been added to #351, #352, and #353, including
exact heads, current blockers, and next steps. #351 and #352 are NOT merge-ready:
hosted CI passes, but required Linux signoff failed the shared atom-allocation
fixture. Logs show lost provider drain proof/shutdown, so do not assume the fix
is merely a longer timeout. No retry is running. #353 is the only active Linux
signoff; collect completion, update its PR, and stop additional campaigns.

The user explicitly approved #353 Obelisk source checkout/signoff/status posting
and clarified that the repository is public. The earlier approval block is resolved.
The new file-descriptor screenshot is untriaged: full client tests in the user's
loom-extensions jailed environment reported emfile and SQLite open14 failures.
Do not accept the model's claim that all failures are environmental without
checking limits, descriptor ownership/leaks, and concurrency. Screenshot:
`/var/folders/wz/_ch4w0f15qj3_t6ymz3427240000gn/T/TemporaryItems/NSIRD_screencaptureui_LP5NzV/Screenshot 2026-09-11 at 3.41.12 PM.png`
(original filename uses a narrow no-break space before PM).
No source change, reproduction, or fix exists for descriptor exhaustion yet.

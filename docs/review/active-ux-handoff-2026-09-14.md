# Loom UX and diagnostics handoff — September 14

This is an in-progress handoff. The user's request is to follow every related item to completion. Do not treat local validation, a draft PR, and required Linux signoff as equivalent. The original checkout still has its unrelated untracked files and remains on local main; source work is isolated.

## Current work

| Item | Verified state |
|---|---|
| Model-selection/cancellation work, PR #403 | Merged as `813daf2a`; all hosted checks and exact-head Linux signoff passed before merge. |
| Diagnostic install, PR #405 | User merged as `6a64b07a`. Its original signoff failed on client test fixtures. Do not describe that original head as fully green. |
| CLI help, PR #406 | Merged as `bcfe471e949bff87b9ff7328fcbfaf235382f132`, after all hosted Linux/macOS checks and signoff at `e44c4425012826b08391769c74820be3f88574f3` passed. |
| Short compaction notice, PR #407 | Merged as `7cacb150f2d1fd443705624deb960490b4d833fd` after all hosted CI and exact-head Linux signoff passed at `cc284cb6780521655f90da638f03f9fe6a74f65a`. Signoff exited 0 in 804 seconds: 11 enforced layers, no undeclared skips. The first Hex-preparation failure is retained separately. |
| Earlier history prefetch, PR #408 | Draft, head `21ed55c6b0ca87058c126cb22bfe8249b70b8b91`. All 476 TUI tests passed. The new test rejects the old ten-row threshold and passes with two viewport heights. Hosted CI is terminal green after three supported local simulation repetitions passed and one macOS rerun passed (run 34902292779). First Linux signoff stopped in Hex prep after three retries. Second signoff is running in exec session 72857; log `/private/tmp/loom-pr408-signoff-attempt2.log`. |
| Normal-build profiling flags, PR #409 | Draft, head `77b39805b251c6ef6a2ea564c39f104e72529556`. Normal bundled client and full code-mode-enabled server releases passed; release smoke passed; generated profile helpers attached successfully. Hosted CI run 34903487778 is terminal green. Exact-head Linux signoff remains to do. |
| Stop-hook watcher loop, Substrate PR #97 | Head `f55342bc23193c2d32ccc481b49c4c1e6d08ea35`. Focused tests, lint and independent review passed. Installed CLI and Stop hook match the built artifacts. Real installed CLI lease and hook check passed across different HOME values in an isolated test project. Go CI, frontend checks and production build passed. Frontend E2E is a confirmed baseline failure: Playwright passes unsupported `-web-only`; main failed the same way. No unrelated frontend patch was made. |
| PR #404 review | Head `3b2dafb94271659356d2fa37fcce04d9f5821cca`, two independently verified findings. Existing sockets can submit after held-queue drain; same-version live installation can label old binaries with a new commit. Review is `/private/tmp/loom-pr404-review.md`. No author checkout edit or posted review comment. |

The approval-panel paint barrier is a separate commit on the three new TUI/profiling branches. Original commit `d6f7c4ccf7bc3facec7f594e987918f764fece91` waits for the frame to contain the panel before assertions. It passed all 1,797 client tests in the supported Linux container. It is now on main through PR #406; do not weaken or duplicate the test further.

## Live memory investigation

The original TUI process reached approximately 13 GiB RSS and exited before the diagnostic client was launched. No forced GC, kill, or restart of that process was performed by the agent. Do not equate that exit with reclamation.

Current identified processes: diagnostic TUI PID 98697 and ordinary daemon PID 98740, launched around 14:44 local time. The diagnostic TUI stayed near 100 MiB RSS while observed. The daemon rose to approximately 2.88 GiB RSS. At 15:27:59, the same daemon's vmmap physical footprint was 2.5 GiB (peak 3.2 GiB): about 536 MiB resident writable memory and 2 GiB swapped out. Most is VM_ALLOCATE; native malloc accounted for only tens of MiB. The RSS drop does not establish that BEAM freed the retained data.

That daemon was not launched as a distributed diagnostic node. Exact attribution to process heaps, binaries, ETS, and allocator carriers is still unavailable. The user has a pending question authorizing a graceful restart or choosing to restart manually. **Do not stop or restart the user daemon without that answer.**

A complete, isolated, normal-build installation is ready at:

`/Users/roasbeef/gocode/src/github.com/roasbeef/loom/.worktrees/profiling-flags/build/profile-install/bin`

It contains `loom`, `loomd`, and `loom-profile`. The server was rebuilt with code mode enabled and passed release smoke. The eventual daemon command is that directory's `loomd --profile`; it defaults to the same `~/.loom` state. Use the matching `loom` wrapper for the TUI. The daemon prints the exact helper command; use observational mode, not forced collection. Verify the live PID and state before any approved transition.

Profiling review fixes: private cookie-file loading avoids exposing the cookie in process arguments; application HOME is restored before Loom starts; extension/replay/sessions tails are preserved; empty-array expansion works in macOS Bash 3; server helper uses the actual release boot path. The older temporary diagnostic client still uses the earlier argument-file cookie path; the new staged build does not.

## Installed watcher fix

Installed paths: `/usr/local/bin/substrate` and `~/.claude/hooks/substrate/stop.sh`. Backups and hashes are under `/private/tmp/substrate-watch-backup-20260914T221727Z`. The installed old hook was byte-identical to the base source before replacement. Existing old watchers were not stopped; old HOME-scoped state is not migrated.

The fix stores leases, watermarks, and arming stamps in project `.substrate/watch`. The CLI and hook agree on root selection, including nested working directories. Installed-artifact smoke passed with a real background CLI watcher and real `watch --check`, isolated database initialized from the repository's generated schema, different HOME values, and stubbed mail operations. Evidence directory: `/private/tmp/substrate-watch-direct-smoke-wssudgq1`.

An extra smoke exposed a separate pre-existing `watch --queue-only` panic: queued client heartbeat falls through to a nil Registry. It was not patched or conflated with the HOME-state fix.

## Pending user-facing items

Manual session naming already exists as `/rename <name>`. The user suggested generated short titles through the summarizer. An async preference question asks whether to generate after the first completed turn or only on request. No automatic-title implementation has been started; do not silently call that complete.

The separately requested Terra rate-limit/partial-tool-call task still has only queued creation ID `client-new-thread:11545787-193f-4385-8a98-4c031c6f2f86`. Repeated task listings did not return a real task ID, so execution is unconfirmed. Do not create another duplicate or pass the client ID to APIs requiring a task ID. Computer Use refused to inspect the Codex app. Include the created-task directive in the next final response so the queued task is represented to the user.

## Next actions

1. PR #407 is merged. Finish PR #408 exact-head signoff in session 72857; preserve the first attempt logs. Do not run several Hex-heavy signoffs concurrently again.
2. Once #408 signoff passes, verify normal merge requirements and merge the reviewed head. Hosted CI is already green.
3. Finish #409's hosted CI and exact-head Linux signoff. Full local packaging/attachment validation is now complete; do not repeat the earlier rate-limit blocker as current.
4. Respect the pending restart answer, then profile the daemon using the staged build and reproduce the user's memory growth through normal use. Do not infer a leak owner from RSS alone.
5. Keep Substrate #97's baseline frontend failure explicit; do not merge past a required red check or fix unrelated frontend scope without a separate decision.
6. Resolve the generated-title preference and the queued separate task without forgetting either.

# Per-Launch native retirement design review

Status: approved by the owner on October 6, 2026; implementation in progress.
The approval covers the recommended exact-helper retirement and bounded Compile
attempt designs. The source revisions below describe the reviewed baseline,
not completed implementation evidence.

Recommend a **Launch-only disposition on the existing executor row that retires its exact borrowed helper through the existing pool inventory**. Reuse the current native-retirement acceptance grade. Keep the session-scoped executor and pool alive; Compile and raw-native dispatch retain their current helper-reuse behavior.

This is a source-grounded design recommendation, not implementation signoff. No source, Git, index, build or test changes were made. Integration source was `7b7188c45d347cc07ebbb3bdc2750304342e75b8`; the whole-owner files were uncommitted WIP.

## Why the current path cannot release each successful Launch

`executor/remote/native.gleam:193–239` persists the terminal through its publisher, receives `Settled`, calls the asynchronous `Execution.release`, sends `control_done`, and stops. `broker/executor.gleam:1113` handles that release by checking the helper back into the pool and deleting the row. `remote/service.gleam:639` deletes its transient native control row on `ControlDone`. None of those events witnesses helper retirement.

`broker/exec.gleam:3625` makes a ready borrowed helper Available again. `packages/sandbox/internal/server/server.go:225–246` writes `exec_exit` before calling the release closure; its chained `waitDone` is the later cleanup boundary. Thus the returned helper and the native terminal are distinct from retirement. Whole-owner WIP correctly keeps this distinction: `launch_channel.NativeCustody` currently has only Unresolved and ExcludedBeforeDispatch, and its directory deletion accepts only the exclusion branch. A successful dispatched Launch cannot take that branch. Its active slot consequently remains held.

`remote/service.close_scope` can produce a real witness today: it quiesces admission, calls `local.close` on the whole scoped pool, and only on success applies `admission.ConfirmRetirement` to covered identities. Using that per Launch would close the shared session service and affect sibling work.

## Reuse the pool's actual witness

The pool already owns the needed sequence in `exec.gleam:3560–3619`: Borrowed/Available becomes Draining; native retirement succeeds; the pool sends ForgetRetired and moves to RetiringActor; only its original normal owner monitor removes the entry and frees capacity. Its original monitor and inventory predate dispatch. Add one original per-helper retirement observer to this sequence, and notify success from that final normal-owner transition. Capture the positive event before dropping the entry; a later lookup finding no entry is never success.

Do not implement this as `exec.close(helper)` followed by ordinary checkin. Direct close bypasses the pool's Draining/RetiringActor bookkeeping. The pool then sees a normal owner exit while the entry is still Borrowed and records RetirementOwnerGone/Unconfirmed, retaining capacity. Nor should the caller check in first and then ask to retire: a later execution could already hold the helper.

The acceptance grade here is explicitly the existing `local.close`/ScopeRetirement grade, as requested. Keep `native_verdict` unchanged, including its justified SettledJail and platform-dependent LiveJail handling. This establishes the current native-retirement contract, not guaranteed deletion of every cgroup directory or stronger platform descendant containment. In particular, `jail/run.go:800` discards a cgroup cleanup error, and some accepted native-exit cases do not run the graceful post-frame release path. Those limitations already exist in scoped retirement; they are not a reason to enlarge this change or reject the same witness for the exact original Launch helper.

## Minimum additive API surface

The names below are proposals, not existing functions. They avoid changing the frozen Dispatch/Execution record shapes or forcing existing ExecutorConfig callers to opt into new semantics.

1. **Pool-owned targeted retirement:** add an internal exported `exec.retire_borrowed(pool, helper, completed)` where `completed` receives `Result(Nil, RetirementFailure)`. The request must match the original inventoried helper and current borrowed custody. It withdraws the entry permanently from lending and uses the existing retirement transitions. Keep one original bounded completion observer on that entry, not an unbounded waiter list. A duplicate, stale, foreign or missing target cannot produce a positive witness. Failures keep existing Unconfirmed custody. Scope closure must preserve and deliver the already registered targeted observer. The callback should only send to its owner, so it never blocks the pool actor.

2. **Executor construction and Launch-only dispatch:** add an alternate `executor.start_with_retirement(config, retire_helper)` that binds the above pool operation to the exact pool supplying checkout/checkin. Existing `start(config)` stays unchanged. Add `executor.dispatcher_retiring_with_native_deadline(executor, retired)` returning the existing Dispatcher. This selects a private row disposition before checkout/dispatch, for example Reuse or RetireOriginal(observer). An executor without the configured retirement seam must refuse this dispatcher before dispatch. The observer should carry the original ExecutionId and its retirement result. Ordinary `dispatcher` and `dispatcher_with_native_deadline` continue selecting Reuse.

3. **Native adapter entry point:** add `native.start_launch(config, retired)` or an equivalent closed local start-policy argument. It uses the retiring dispatcher; existing `native.start` keeps its behavior. Thread the already validated command route into `service.launch`: only Command plus LaunchService/SatelliteCommand selects the new entry point. Do not infer the choice from argv, step text, Prepared stream mode or the presence of a terminal.

4. **Exact remote custody publication:** have the original adapter/service continuation carry the retirement result with its exact native RequestKey and prepared digest. On success, apply `admission.ConfirmRetirement` in that original native journal without closing the epoch or quiescing the session. Preserve the positive live observation across a journal-write error for a bounded original retry; a failed commit must not be advertised as durable retirement. Historical callers may inspect a durably retained NativeRetired fact, but must not reconstruct it from Terminal alone.

5. **Whole-owner consumption:** add a distinct NativeRetired custody variant/event at the original channel owner, separate from its existing NativeObserved enforcement report and ExcludedBeforeDispatch path. Deliver it only after validating the original native association and the actual retirement observation above. Resource release still requires transport join and successful deletion of the original directory. Release the active entry only after that concrete channel/resource disposition and its existing continuation/report drain obligations; keep unresolved entries held.

The executor's new row disposition is essential, rather than an optional post-settlement cleanup call. It must cover normal Release, Abandon, relay loss, start-reply loss after dispatch, and scope closure. Every path that currently checks the row's helper back in must respect it. A Launch helper must never transiently become Available between execution settlement and retirement. Existing single-sender protection remains in the executor's exact incarnation/sequence row: cancel, stdin and release enter there, and stale messages cannot reach a newer execution. Pool shutdown is a withdrawal operation on that exact borrowed helper, not another execution sender.

Use the existing actors' asynchronous state transitions for the retirement observation. Do not block the executor service on a helper retirement wait: it must continue serving cancellation and sibling executions. Retain the retiring row, or equivalent original bounded custody record, until its exact callback arrives. A timeout/lost owner gives uncertainty; absence of that row or pool entry gives no success. Successful retirement frees that helper's capacity, and the existing pool lazily creates a replacement for later calls.

## Alternatives

| Option | Assessment |
| --- | --- |
| Exact helper retirement through current pool | Recommended. Adds a local custody seam and per-row disposition, reuses existing two-boundary proof, preserves the session service and existing Compile/raw behavior. Costs one helper restart per Launch. |
| New per-execution native retirement frame | Potential later optimization for helper reuse. Requires a versioned native protocol feature, placement after the original release boundary, total decoding, exact execution binding and new custody evidence. More surface than needed for this acceptance grade. |
| A pool/service per Launch | Can isolate whole-pool close, but changes provisioning, lifecycle ownership, service identity and resource accounting. It duplicates a scoped service to solve one helper disposition. Not the smallest change. |
| Close the existing session scope per Launch | Incorrect for this task: quiesces sibling Compile/raw/Launch work and destroys the intended shared service. |

## Focused acceptance controls

The meaningful success control is more sequential Launches than `max_active`, through one still-open session service, with each Launch's exact helper retirement, transport join and directory cleanup observed. Verify pool capacity recovers by replacement while Compile and raw-native calls retain their existing reuse behavior.

Hold native retirement after terminal publication: known terminal/completion must coexist with unresolved Launch custody and a retained active slot. Hold the original helper-owner Down after native retirement: capacity and the Launch witness must remain withheld until that second boundary. Then release each boundary and require the original completion observer exactly once.

Exercise stale/foreign ExecutionId, duplicate Release, release-reply loss, relay/adapter death, pool closure overlapping targeted retirement, and retirement failure. No path may re-lend the original Launch helper before its witness or turn an absent row into success. Finally, fail ConfirmRetirement persistence after positive local proof; retain the original evidence for retry without redispatch or substituting a new helper.

## Source pins at read

| Source | SHA-256 |
| --- | --- |
| integration `broker/executor.gleam` | `42ed5ec0e8b805aa39680a774eb9012909b4f36ac1481aa11fe5475bb2c36c67` |
| integration `broker/exec.gleam` | `55a8e849ed303cdb00d9800a5b4877d7449e6eb91fddc4875bf554836b77cd6f` |
| integration `executor/remote/native.gleam` | `70233616aba25a906b3ff75cc5a7724d4cc22f8d4d8fdc660bc91a6d118510d2` |
| integration `executor/remote/service.gleam` | `c9ed4d919e3c2bd978fec3dc62b362f8df6def597e987508c3ae2387c91a79ef` |
| integration `sandbox/internal/server/server.go` | `a9eef0811e9d11b51c2f6a11a3de8643cb1c209d995822744584579eee803ef0` |
| whole-owner WIP `executor/remote/launch_channel.gleam` | `aa9d1e570263a6a459b0255504cb8ae7159037d5bf0cf60408024ba00f6c495a` |
| whole-owner WIP `executor/remote/launch_service.gleam` | `3ea7b2a3fce1042f6658beb24f26abcbb53ee42f8ad3db5f8586ea0d98dffbe8` |

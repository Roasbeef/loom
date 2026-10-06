# Current handoff

This edition covers the distributed runtime integration after rebasing onto
`origin/main` at `552e44033d615675ae670aea784b399105476c60` on October 6,
2026. The replay ends at `7f8ff65cc`; compatibility repairs are in `6cffb133f`.
The current task is the rebase only. Resume implementation when the owner
continues the task; no merge into main is authorized.

The previous edition named `35c64e259` as current integration source and
appended an October 4 main handoff. Both baselines were stale. Its passing
counts describe earlier trees, not this rebased candidate. Historical reviews
remain attached to the commits they examined.

## Where the tree is

[PR #819](https://github.com/Roasbeef/loom/pull/819) is the draft integration
review for [issue #697](https://github.com/Roasbeef/loom/issues/697). The
[integration guide](design-notes/distributed-runtime-integration.md) remains
the component map and acceptance checklist. This local rebase has not been
pushed. The original head, `b3bc47efdb2be7df421287aa437debdd034af9e5`, is
retained by the pre-rebase recovery branch. Component branch refs moved by
Git's automatic update-refs behavior were restored to their original commits.

| Boundary | State after rebase |
|---|---|
| Catalogue | Main's subtitle, credential-kind and browser-login migrations remain versions 5 through 7. Typed workspace binding is version 8. The version-7 migration test checks display metadata, owner authentication, browser logins and reopen. |
| Daemon | Control and home-page creation share the current server helper. Typed workspace selections and retained bindings coexist with main's authorization, subtitles and browser login behavior. |
| Code mode | Main's single unused-import rewrite and call-ledger prechecks coexist with managed provenance and retained reports. Upstream constructors and opaque artifact accessors are reflected in feature adapters and fixtures. |
| LSP | The extracted physical host retains main's canonical dependency inventory hashing and method-receiver lookup behavior. |
| Generated sources | Storage SQL and the capability prelude were regenerated during conflict resolution. The prelude digest and self-test pass. |
| Unfinished work | Executor resource-schema version-3 edits remain separate from committed rebase repairs. The unrelated client owner-binding runner and main checkout files must remain untouched. |

The upstream performance investigation is
[BEAM CPU measurements](review/beam-cpu-2026-10-05.md). Its measurements
belong to its stated revisions; they were not repeated for this integration.

## Verification for this rebase

The committed rebase baseline passes the complete client package gate with
3,067 tests and fifteen explicit optional skips: one Linux `/proc` witness,
thirteen shipped-server controls and one rust-analyzer control. Executor passes
314 tests with no skips; storage passes 224, code mode 459, tools 748 and cap
189. Core, broker, runtime and conformance also compile warning-free. Code-mode
acceptance includes actual jailed compilation and satellite execution. The first run
used an old offline seed and failed in Rebar's home-directory lookup while
recompiling SQLite. Rebuilding the seed with `make codemode-seed` corrected
that fixture input; the complete code-mode gate then passed.

Repository lint and documentation checks pass with their existing warning
censuses. All six unfinished executor files and the unrelated client runner were
restored byte-for-byte against their pre-rebase SHA-256 records. Those unfinished
edits were excluded from the committed baseline gates above; they remain
unvalidated work. An independent review
found no reachable regression in the migration, daemon creation, satellite
provenance/precheck, LSP inventory or report/prelude resolutions. It did not
claim whole-system distributed acceptance. The full repository gate and hosted
CI have not been run for this rebased candidate.

## What to do next

1. Resume the accepted [Launch channel plan](design-notes/distributed-launch-channel.md),
   preserving the separate foreground implementation and model worktrees.
   **Exit:** whole Launch owns token/listener placement, final-recipient
   consumption and cleanup evidence; real blocked-I/O controls and the model
   agree with the implementation. Preserve unfinished executor schema edits
   until their ownership and validation are complete.
2. Wire registered remote Compile/Launch and LSP into ordinary session assembly.
   **Exit:** the normal tool path uses the selected executor, with the workspace
   absent from the owner. Resolve the unused-import rewrite interaction before
   enabling remote Compile: the rewrite changes source under the same managed
   identity, while the remote consumer retains exact original input. Current
   production construction selects the local compile service, so this is an
   integration obligation rather than a live rebase failure.
3. Complete the remaining **#697** acceptance in the integration guide: executor
   pools, orchestrator ownership/routing, durable cross-node messaging, controlled
   session movement and retained-report lifecycle across archive/restore/compaction.
   **Exit:** separate-host cancellation, partition, restart and lost-reply tests,
   applicable model gates, full repository gates and assembled-system review.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Executors share the runtime trust domain.** Trusted TLS BEAM membership carries
physical service traffic. Satellites remain jailed and distribution-disabled;
executor membership does not grant Raft voting membership. See the
[integration guide](design-notes/distributed-runtime-integration.md).

**Cleanup has distinct witnesses.** Endpoint retirement, native close,
capability-channel consumption and complete-report COMMIT discharge different
obligations. A receipt or lost reply cannot stand in for another boundary's
proof. The [scoped host review](review/distributed-scoped-host.md),
[Launch plan](design-notes/distributed-launch-channel.md) and
[report model review](review/distributed-report-custody-model.md) retain the
specific claims and their limits.

**Component evidence is not product acceptance.** The prior
[live retained-report review](review/distributed-report-live.md) and
[Launch binding review](review/distributed-launch-command.md) cover their
stated paths and revisions. Remote deployment, resource retirement and
whole-system recovery still require the integrated tests above.

## How to verify

Use `make check-<package>` for a changed package, `make lint`, `make doc-check`
and `make prelude-check` for the shared gates, and `make check` for the complete
candidate. Regenerate the offline seed after changing its source or compiler;
`make e2e-codemode` checks it through the actual jail. Read each command's own
exit status. Keep checkout-backed acceptance worktrees outside `/tmp`, which
the jail replaces. See [execution](execution.md) for the remaining gate rules.

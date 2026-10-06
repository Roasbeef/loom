# Current handoff

This edition records the distributed runtime integration through `5559b4c3`
on October 6, 2026, checked against source, command receipts and live PR state.
Rewrite it when the next integration milestone changes those facts. The branch
includes `origin/main` at `552e44033`; no merge into main is authorized.

The previous edition left the live bridge and finite stream binding in
implementation worktrees. Both are now committed after independent review and
a combined executor gate. The owner consumer is still under implementation.
This does not complete the distributed runtime acceptance criteria.

## Where the tree is

[PR #819](https://github.com/Roasbeef/loom/pull/819) remains the draft integration
review for open [issue #697](https://github.com/Roasbeef/loom/issues/697). The
[integration guide](design-notes/distributed-runtime-integration.md) is the
component map and acceptance checklist. The local rebase and subsequent work
have not been pushed. GitHub still names `b3bc47efdb2be7df421287aa437debdd034af9e5`
as the PR head, with no reported checks. That head is also retained by the
pre-rebase recovery branch. Main's CI run `37426538781` passed at `552e44033`;
this is evidence for the base, not for the integration candidate.

| Boundary | Current integration state |
| --- | --- |
| Catalogue | Main's subtitle, credential-kind and browser-login migrations remain versions 5 through 7. Typed workspace binding is version 8. The migration regression checks display metadata, owner authentication, browser logins and reopen. |
| Daemon | Control and home-page creation share the current server helper. Typed workspace selections and retained bindings coexist with main's authorization, subtitles and browser login behavior. |
| Code mode | Whole foreground Launch owns physical preparation and consumed channel windows. The client propagates cleanup custody before deleting its local directories. Main's unused-import rewrite and call-ledger prechecks remain present. |
| LSP | The extracted physical host retains main's canonical dependency inventory hashing and method-receiver lookup behavior. Registered remote default assembly remains pending. |
| Generated sources | Storage SQL and the capability prelude were regenerated during rebase. The Launch resource SQL was regenerated from its source after the format-3 change. |
| Executor resource custody | Closed Launch completions, role-specific native association and the atomic refusal fence are committed. Resource format 3 rejects old formats before interpreting their rows. Compile retains its separate completion contract. |
| Launch model | The bounded P model and source correspondence are committed. Root replay and independent review do not claim implementation refinement or unbounded liveness. |
| Remote Launch | The whole owner, finite TLS BEAM controls, duplex bridge and finite stream binding are committed. The owner consumer remains in its isolated worktree. Associated-native retirement and default assembly are pending. |
| Preserved work | The unrelated client owner-binding runner and main checkout files remain outside this change. |

## Verification and its limits

The earlier rebase baseline passed client with 3,067 tests and fifteen explicit
optional skips, executor with 314, storage with 224, code mode with 459, tools
with 748 and cap with 189. Core, broker, runtime and conformance also compiled
warning-free. Those counts belong to that baseline. Rebuilding the offline seed
corrected its initial Rebar home-directory fixture failure before the final
code-mode gate.

The new executor resource slice passed an independent complete executor gate:
335 tests, followed by executor lint and documentation checks. Its review covered
role confusion, original producer readback, the association-versus-refusal race,
native readback outside the resource writer and format-3 reopening policy.

The frozen foreground source passed the root's separate code-mode, tools and
client package gates: 482, 749 and 3,073 tests respectively. Client has fifteen
explicit skips: one Linux `/proc` witness, thirteen shipped-server controls and
one rust-analyzer control. Changed-package lint and documentation checks pass.
Independent review found and then closed a capability-drain gap: transport
closure alone did not join already admitted work. The
[foreground review](review/distributed-foreground-launch.md) records the
correction, real socket and jailed controls, mutation evidence and exact limits.

The whole Launch owner and finite controls passed the root's assembled executor
gate with 357 tests, executor lint and documentation checks. Review and actual
transport composition found and corrected historical admission-slot retention,
Refused-phase termination and a cancellation message that erased the original
close reply. The [owner review](review/distributed-launch-owner.md) records
those paths, deterministic controls, mutation evidence and the known missing
associated-native retirement witness.

The final live stream and finite binding passed the independent combined
executor gate with 364 tests, followed by executor lint and documentation checks.
Nine compiling mutations were killed across these two slices. The Final check
monitors the original executor reader before cancellation, closing a blind spot
where the owner reducer could hide an incorrectly continuing reader. Independent
review found no correctness blocker. The
[stream review](review/distributed-launch-stream.md) records the exact limits.

The full repository gate, registered remote default path, separate-host tests
and hosted CI have not run on this candidate. Passing component tests do not
establish those results.

## What to do next

1. Finish the remote half of the accepted [Launch channel plan](design-notes/distributed-launch-channel.md)
   for **#697**. Integrate the original live stream, its finite binding route,
   owner consumer and composed scope cleanup after their independent gates.
   **Exit:** more sequential Launches than the active limit complete in one
   live session; each retains exact native, transport and resource witnesses.
   The additive exact-helper retirement API is awaiting the owner's decision.
   Do not infer that witness from terminal history or close the shared session
   pool for each Launch.
2. Wire registered remote Compile/Launch and LSP into ordinary session assembly.
   **Exit:** the normal tool path uses the selected executor, with the workspace
   absent from the owner. Resolve the unused-import rewrite interaction before
   enabling remote Compile: the rewrite changes source under the same managed
   identity, while the remote consumer retains exact original input. Production
   still selects the local compile service, so this remains an integration
   obligation.
3. Complete the remaining **#697** acceptance in the integration guide: executor
   pools, orchestrator ownership/routing, durable cross-node messaging, controlled
   session movement and retained-report lifecycle across archive/restore/compaction.
   **Exit:** separate-host cancellation, partition, restart and lost-reply tests,
   applicable model gates, full repository gates and assembled-system review.
   Automatic failover and workspace snapshot migration remain deferred.

## Decisions still needed

The native service returns helpers to its pool after terminal publication.
Its per-execution path has no retirement witness; only scoped pool closure does.
The reviewed proposal retires the exact borrowed Launch helper through the
existing pool's native and owner-exit observations, keeping Compile and ordinary
command reuse unchanged. It costs one helper restart per Launch. That additive
API has not been approved or implemented; a new per-execution helper protocol
is the alternative under consideration.

Separate-host testing also awaits permission to copy the private source to the
designated remote host. The copy was rejected before transfer, and no remote
checkout was created. Local implementation and two-node TLS controls can continue.

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

**Component evidence is not product acceptance.** The
[live retained-report review](review/distributed-report-live.md),
[Launch binding review](review/distributed-launch-command.md) and
[foreground review](review/distributed-foreground-launch.md) cover their stated
paths and revisions. Remote deployment, resource retirement and whole-system
recovery still require the integrated tests above.

## How to verify

Use `make check-<package>` for a changed package, `make lint`, `make doc-check`
and `make prelude-check` for shared gates, and `make check` for the complete
candidate. Regenerate the offline seed after changing its source or compiler;
`make e2e-codemode` checks it through the actual jail. Read each command's own
exit status. Keep checkout-backed acceptance worktrees outside `/tmp`, which
the jail replaces. Keep Unix socket test roots short enough for the platform's
path ceiling. Do not run two Make targets that package the same generated TUI
shipment concurrently. See [execution](execution.md) for the remaining rules.

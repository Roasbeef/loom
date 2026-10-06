# Current handoff

This edition records the distributed runtime integration through `81c7c83f7`
on October 6, 2026. Source packets, independent command exits and live GitHub
state were checked for this milestone. Rewrite this file when the next
integration milestone changes those facts.

The previous edition left exact-helper retirement and immutable Compile rewrite
identities in progress. Both are now implemented and committed. Ordinary
registered session assembly and remote LSP remain unbuilt, so this milestone
does not complete distributed runtime acceptance.

## Where the tree is

[PR #819](https://github.com/Roasbeef/loom/pull/819) remains draft and
[issue #697](https://github.com/Roasbeef/loom/issues/697) remains open. The local
integration commits have not been pushed. GitHub still names
`b3bc47efdb2be7df421287aa437debdd034af9e5` as the PR head and reports no checks.
The integration branch includes `origin/main` at `552e44033`; current main must
be incorporated again before final validation. The latest observed main runs
`37474395428` and `37447150575` failed at `5a9619d5e`. These runs are not evidence
about this local candidate. No push or merge is authorized.

| Boundary | Current integration state |
| --- | --- |
| Owner custody and transport | Retained inputs/results, finite TLS BEAM controls, native forwarding and semantic workspace consumers are implemented. |
| Compile | Exactly Original and UnusedImportRewrite identities preserve immutable inputs, checked predecessor evidence and the original authority/deadline. Protocol 071 and `85fa75c20` implement the approved contract. |
| Launch | The consumed stream, original satellite, owner consumer and exact-helper retirement now compose. `23c6fabd9`, `a57c907f0` and `81c7c83f7` complete this component milestone. |
| Ordinary daemon path | Registered default assembly, deployment configuration, enrollment pinning and full executor activation still need their proposed APIs approved and implemented. |
| LSP | The physical host exists. The bounded registered LSP contract has completed source review but still requires owner approval and implementation. |
| Distributed orchestration | C1 ownership, C2 routing, C3 durable cross-node messaging and M1 controlled movement remain required and unimplemented. |
| Preserved work | The unrelated owner-binding test runner and main checkout changes remain outside this work. |

The [integration guide](design-notes/distributed-runtime-integration.md) maps the
components and full acceptance criteria. The
[Compile and retirement review](review/distributed-compile-retirement.md) records
the final source, corrected review findings, execution evidence and limits.
Earlier review records remain evidence for their stated revisions.

## Verification and its limits

Independent complete package gates passed core with 189 tests plus JavaScript
checks, storage with 224, code mode with 483, broker with 444, executor with 370
and client with 3,084. The final combined client gate returned exit zero.
Fifteen explicit optional controls remain skipped: one Linux `/proc` witness,
thirteen shipped-server controls and one rust-analyzer control. All 59 final
source paths matched between integration and verification checkouts before
these documentation updates.

Final formatting, the six changed-package lint targets, documentation and
prelude checks passed with exit zero. Documentation reported 186 warnings and
zero errors.

The real executor control completes three Launches through one active slot.
The composed owner controls require exact retained native/outer receipts,
Released resource custody and physical path removal for both Original and
Rewrite builds. Five Compile and two retirement mutants compile and fail their
runtime assertions. Source review and bounded correction reviews are complete.
Earlier failed test runs remain recorded separately; focused passes and observed
host load do not establish that every failure was a flake.

Full repository gates, ordinary registered tools, separate-host acceptance and
hosted CI have not passed on this candidate. Component results do not establish
those outcomes. The new SSH user promised for host testing has not been supplied;
the earlier rejected transfer created no remote checkout. Wait for that new
destination identity before transferring source.

## What to do next

1. Finish and obtain approval for the concrete registered administration and LSP
   contracts for **#697**. Ordinary close/reopen must define owner-process
   lifetime and exact registration generations. The current permanent endpoint
   fence cannot become a reusable idle witness. **Exit:** reviewed APIs cover
   fresh work after close/reopen and archive/restore, with bounded capacity and
   no automatic replacement after uncertainty.
2. Implement those contracts through ordinary daemon assembly. Preserve one
   original owner Broker/custodian, executor-only physical paths, full report
   admission, jobs, hooks, guidance, Git and LSP. **Exit:** default tools and
   code mode work with the checkout absent from the owner, including complete
   report retention and lifecycle controls. Historical query alone is not the
   fresh-work acceptance criterion.
3. Complete executor pools, C1-C3 and M1 from the API plan. Each session has one
   authoritative owner; cross-node acknowledgement follows recipient durable
   admission under the same message ID, not model consumption. **Exit:** the
   separate-host cancellation, partition, restart, lost-reply and controlled
   movement controls pass. Automatic failover and workspace snapshot migration
   remain deferred.
4. Incorporate current main, run applicable model and full repository gates,
   then review the assembled system. **Exit:** exact candidate results justify
   the remaining integration checklist before requesting publication or merge.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Executors share the runtime trust domain.** Trusted TLS BEAM membership carries
physical service traffic. Satellites remain jailed and distribution-disabled;
executor membership does not grant Raft voting membership. See the
[integration guide](design-notes/distributed-runtime-integration.md).

**Compile has two fixed attempts.** The approved
[protocol 071](../protocol-change/071-remote-compile-attempts.md) permits one
Original and one deterministic UnusedImportRewrite. It does not grant a retry
framework, renewed deadline, new budget or new grants.

**Launch retires its exact borrowed helper.** The approved
[protocol-067 addendum](../protocol-change/067-remote-workspace-services.md#addendum-exact-original-helper-retirement-for-launch)
costs one helper restart per Launch. It preserves ordinary command/Compile
reuse and never closes the shared pool for each Launch.

**Cleanup witnesses remain separate.** Original native retirement, transport
join, capability drain, resource removal and complete-report COMMIT discharge
different obligations. Terminal history, actor death, absence and receipt cannot
replace another boundary's witness. See the
[retirement architecture](architecture/launch-native-retirement.md).

## Deliberately open

Registered administration and LSP are proposed contracts, not approved public
APIs. The lifecycle amendment must account for the current sixteen lifetime
endpoint rows and immutable owner doors before implementation. Full filesystem
quota policy is also distinct from bounding new LSP allocations. These are known
design decisions; C1-C3 and M1 are known unbuilt scope. None is unfinished work
somebody forgot.

## How to verify

Use `make check-<package>` for affected packages, `make fmt-check`, changed-package
lint, `make doc-check` and `make prelude-check` for shared gates, then `make check`
for the complete candidate. Regenerate the offline code-mode seed when its
source or compiler changes. Capture each command's own exit status.

Keep checkout-backed tests outside `/tmp`, which the jail replaces, and Unix
socket roots short enough for the platform. Serialize heavy real-helper suites
and tests that package the same generated TUI shipment. Preserve red receipts
and investigate the actual failure before changing a timeout or calling it a
flake. See [execution](execution.md) for the remaining rules.

# Current handoff

## Distributed runtime design (issue #697)

The proposed [user journeys and ownership design](design-notes/distributed-runtime.md)
separates existing multiplayer access from remote execution and later clustered
ownership. The first recommendation is executor-resident workspaces with a
typed remote workspace service, without a shared POSIX filesystem. Session
content stays with the owning orchestrator; Khepri is a candidate for small
cluster metadata after a compatibility spike. No distributed runtime or new
wrapper library is implemented by these notes.

The companion [API and delivery plan](design-notes/distributed-runtime-api.md)
records correct-by-construction boundaries, Loom style/lint requirements and
separate PlusCal, P and Lean responsibilities. It identifies independent work
packages for execution after contract review. Phone/laptop screen switching
uses existing multiplayer; moving session ownership or workspace contents is
a different operation.

## Executor service (issue #696)

Issue #696 is built as a stack of six phase branches, each a PR on the one
below it:

| Phase | Branch | PR |
|---|---|---|
| fixes | `broker/busy-checkin` (busy helper re-lent) | [#698](https://github.com/Roasbeef/loom/pull/698) |
| fixes | `sandbox/stdin-off-frame-loop` (Go stdin stall; off `main`, independent) | [#699](https://github.com/Roasbeef/loom/pull/699) |
| S0 | `executor/s0-design`, on #698 | [#700](https://github.com/Roasbeef/loom/pull/700) |
| S1 | `executor/s1-service` | [#701](https://github.com/Roasbeef/loom/pull/701) |
| S2 | `executor/s2-hardening` | [#704](https://github.com/Roasbeef/loom/pull/704) |
| S3 | `executor/s3-ops` | [#705](https://github.com/Roasbeef/loom/pull/705) |
| S4 | `executor/s4-standalone` | [#706](https://github.com/Roasbeef/loom/pull/706) |
| S5 | `executor/s5-go-decision` | [#707](https://github.com/Roasbeef/loom/pull/707) |

Merge them bottom up. The design is `docs/architecture/executor.md`, and the
decisions are ADR-017 (the seam, plus addenda for the S1 build and the
default flip) and ADR-018 (the Go helper keeps its code). The witnessed-kill
evidence rule is an addendum inside protocol-change/014. Correction comments
are on #696.

- **What runs now.** Every session's effect plane runs the executor service,
  `broker/executor`: a weft state machine per session over that session's
  pool. It is the only process that sends a helper `Run`, `Stdin` or
  `CancelExec`, and it settles each execution exactly once through
  Live/Granted rows. The per-execution relay (`broker/relay` over the pure
  `broker/execution` core) watches the helper actor too, so a dead helper
  settles at once as `ExecutionLost`. The one-shot build and check planes run
  on it as well. `broker/direct` is deleted. `broker.start(BrokerConfig)`
  stays for the callers that hold a pool's seams and no session (the tests
  of every package that runs a tool, and the M3 demo): it starts a service
  over `checkout` and `checkin`, with no custody query and no pool to close.
- **Lifecycle rules a change must keep.**
  - A deliberate kill retains the port and is judged by exposure: no jail,
    a settled jail, or a live jail. A live jail retires only under bwrap,
    and a kill whose exit never comes loses the proof after five seconds.
  - A `Run` whose caller is gone is refused.
  - Stdin frames take fresh ids, so a helper's stdin error cannot settle the
    execution.
  - The relay's own cancel is an ask to the service.
  - `executor.close(draining:, helpers:)` always gives the pool its full
    native-exit budget.
  - A write that fails to a helper's port waits for the exit status that may be
    queued behind it (`PendingExit(Unprompted(..))`, bounded by the same
    five-second witness window) and does not record the proof lost at once. A
    port delivers `{exit_status, S}` and then closes, so a helper that died by
    itself and met a write had its status dropped, which held its pool slot for
    the life of the pool and blocked the writer lease (protocol-change/014,
    addendum of 2026-10-03).
  - The snapshot's custody is read in the observer's process. The service
    answers an `executor_view.Observation` of its own rows and books, and the
    caller joins the pool's custody to it (`executor_view.completed`), so a slow
    pool delays the observer and no settlement. The halves are not one instant.
  - A stale relay cancel cannot reach the next execution on a reused helper,
    and `cancel_fence_test` shows it: through the link the service builds
    (`executor.relay_link`, internal) the cancel is dropped with its row, and a
    control link that cancels the helper directly cancels the next execution.
    The stale cancel is injected, since a real relay never produces one.
- **Observability.** `executor.snapshot` is bounded and secret-free
  (`executor_view`). It also writes one telemetry line per settlement. There
  is no operator command: every daemon route is the client protocol, and
  what protocol-change/062 would need is written on the executor page.
- **Standalone.** `packages/executor` boots the service without the harness,
  prints a version census, runs one jailed `true` and drains
  (`make executor-smoke`). It has no socket and no wire. `dispatch.Dispatcher`
  is the adapter #697 implements, and `census.skew` has no production caller
  until #697 pairs two sides; only a test calls it.
- **The Go decision (S5).** No Go moved. A generated tag contract was
  prototyped, measured at about 750 lines against zero observed drift, and
  reverted (ADR-018). `enforcement_tags_test` pins the broker's tags to the
  Go jail sources, and `exec.skip_prefix` is the one Gleam constant for
  `skip:`. The pin proves a tag is spelled somewhere in the jail sources,
  not at each emit site, so the fixtures and real-helper tests are what catch
  emission. ADR-018 lists the four events that reopen the question.
- **Measure with** `make bench-exec`, the opt-in real-helper benchmark. The S0
  baselines are on the executor page.

- **Testing the service.** `executor_property_test` draws seeded plans (starts,
  broker and caller cancels, caller death, helper crash, a close in flight) and
  holds every plan to exactly-one-settlement, an empty inventory with dead
  relays, a bounded pool census, a clean close for a quiet plan and a stored
  second verdict; `LOOM_EXECUTOR_PROPERTY_SEEDS` sizes it and
  `LOOM_EXECUTOR_PROPERTY_ONLY` replays a seed. `leak_census_test` draws its
  hundred endings from a seed as well. The simulation runner sends each tool
  call through the executor over fake helpers before applying the fault
  schedule, with two checks, `effects/no-orphan` and `effects/one-settlement`
  (`docs/architecture/simulation.md`, "The effect plane"). Each check was shown
  failing by mutation (the commit messages name them).
- **A kill's cgroup directory (#702).** `loom-exec` now sweeps, at the start of
  server mode, the `exec-<id>-<pid>` directories in its delegated base whose
  execution process has gone and whose cgroup is unpopulated (`cgroup.Sweep`).
  The pid test is not in the issue's proposal and is what keeps a sweeping
  helper from removing a cgroup another helper has made and not yet entered.
  Only a Linux host with a delegated `LOOM_CGROUP_BASE` runs the real-cgroup test
  (`TestSweepRemovesARealCgroup`); the fake-base tests run everywhere.

**Left open, in order of value.**
1. [#703](https://github.com/Roasbeef/loom/issues/703): `OutputIsWire` leases
   (the LSP jail) stream uncapped, so their mailbox is bounded only by the
   consumer.
2. `stop_one_shot`'s `stop_pool` fallback stays on purpose. The follow-up brief
   called it dead because `executor.close` already sends `StopPool`, but
   `stop_pool` also sends `ForgetPool`, which reaps a pool whose proof arrives
   after a timed-out close. `stop_helpers` (the session path) has no such
   fallback, so a late proof there leaves the pool to its owner's death.
3. The simulation schedule has no fault aimed at a helper, and the plane's
   helpers are fake: what a real helper does to a payload under a mid-execution
   fault is still the jailed end-to-end suite's.
4. Idle retirement (#283) is still unbuilt; the service only must not block
   it.

## LSP dependency preparation work (2026-10-03)

The preparation branch adds protocol 064's opt-in Gleam recipe: a fixed,
60-second network-capable downloader job followed by the existing offline
server lease. It verifies dependency records and invalidates reuse after
workspace-local dependency configuration or inventory changes. Existing
installed profiles gain no authority until explicitly updated. The companion
Gleam profile update must follow the harness release that accepts the key.
Validation and review status are recorded in the PR, not inferred from this
handoff. The previous LSP SQL work is merged in #693.

## Sliced strand.wait windows (PR #719, merged `59549a99c`)

A code-mode orchestration program naming a join window larger than the
harness's per-call ceiling used to observe the join "complete" after
30 s with every long-running handle `Pending`: the agency clamps each
`strand.wait` to `max_wait_ms` (30 s) by design, and the satellite stub
forwarded the program's `within_ms` verbatim as one capability call, so
the named deadline and the observed behaviour silently disagreed —
the review fan-out that reported `needs_attention` with no findings was
this, not a model failure.

`cap/strand.wait` now slices: it re-issues the join on still-pending
handles in requests of at most `max_wait_slice_ms` (30 s) until they
settle or the program's `within_ms` is spent, accumulating `waited_ms`
across slices and taking the host's per-slice report at face value (zero
is reachable only from a zero-window probe and is accurate there). The
harness clamp is untouched; `strand.map` still stops admission at the
first unresolved child. Mismatched-handle answers now surface as
`StrandResultMalformed` rather than `StrandsUnavailable`, and each join
failure kind is pinned to its variant by test. An independent GLM 5.3
review returned approve-with-comments; its four findings (slice-bound
coupling, the variant, dead code in `join_batch`, the
`execution.receive` cousin) are all addressed in the merged commits.

**Ruled:** [protocol-change/062](../protocol-change/062-strand-wait-slicing.md)
was accepted by the owner on 2026-10-02 after the merge (implemented in
#719 on the owner's authorization). It records the residual cost (a
never-settling child now blocks up to the program's own deadline) and
why raising `max_wait_ms` was rejected.

**Flake note:** issue #513 (runtime `interleave_test` tools case) has a
second recorded occurrence — run `37072703564`, job 111057019796, on an
unrelated PR — same supervisor-killed shape under parallel lane load;
[the recurrence is logged on the issue](https://github.com/Roasbeef/loom/issues/513#issuecomment-5962830928).
The lane passed on the final CI run, consistent with the timing-flake
diagnosis; a single pass is corroboration, not proof.

## SQL LSP observation branch

On October 2, `codex/lsp-sql` is rebased onto `ee8c5e341` for
[PR #693](https://github.com/Roasbeef/loom/pull/693). The implementation follows
[protocol 062](../protocol-change/062-lsp-sql-observations.md) and the new
[saved-source contract](../protocol-change/063-saved-code-mode-programs.md).
The [usage guide](lsp-sql.md), [design examples](design-notes/lsp-sql.md) and
[architecture](architecture/lsp-sql.md) explain explicit collection and
satellite-local SQL. Source integration does not update a running daemon.

Semantic access goes through `cap/lsp` and `cap/lsp_sql` in code mode.
All seven legacy top-level constructors, schemas, argument decoders and
execution wrappers are removed, along with sixteen obsolete surface tests.
Shared rename landing, anchored previews and automatic write diagnostics remain;
ten shared regressions retain stale-file, partial-write, settlement and
observer-retention checks.
Installed profile hints follow the admitted capability into the description
and `cap://lsp`. Saved session pins are not rewritten.

A run or background launch accepts exactly one of inline `program` and
`program_path`. File source uses canonical native read authorization before the
ordinary vet, compile and jail pipeline. Approval retries retain loaded source;
a later invocation reloads it. Handle interactions perform no source reads.
`loom-default-15` directs agents to save tested programs with purpose/input notes,
reuse them by path and collect fresh observations. Reuse saves neither authority
nor semantic facts.

Before the memory integration rebase, the independent full `make check` exited
zero against the published graph and normal seed, using stock Gleam 1.19.0-rc2. It passed 2,666 client tests, 1,052
TUI tests, 93 conformance tests, 172 capability tests and 340 code-mode tests,
along with the other package gates. All six real jailed LSP fixtures ran
without prerequisite skips. The Gleam SQL fixture loads a saved file; Go uses
inline source. Both prove joins, counts, anti-joins, typed-decoder errors,
SQL refusal and unchanged provenance. This replaces the earlier experimental
seed evidence. Mixing compiler versions invalidates seed-byte comparisons.

Current full format, lint, prelude and documentation gates exit zero. R13 flow
spines, R14 checked transition tables, R15 state types before functions and R16
qualified domain calls are enforced on this rebased tree. R17/R18 remain
censuses; no prose was padded to suppress them. The usage guide links these
rules. The final Astra high source review of
`a3dc25359..ea4b2359b` found no actionable defect and independently passed
170 focused tests. It grants source signoff; the same reviewer also approved
the published dependency integration.

The supporting [esqlite PR #1](https://github.com/Roasbeef/esqlite/pull/1) and
[sqlight PR #1](https://github.com/Roasbeef/sqlight/pull/1) are merged. Hex now
carries `esqlite_loom` 0.9.1 and `sqlight_loom` 1.2.1, with source tags on their
merged trees. The native 0.9.1 payload passed forty-seven cold tests before
publication. The native library remains inside the addressed satellite artifact.

The direct `cap` pin, all four companion updates and eight compiler-generated
package manifests select the genuine releases. The generated offline seed lock
adds only the native package and `cap`'s dependency edge; its checksum matches
Hex. A fresh normal seed builds with stock Gleam 1.19.0-rc2 and Rebar, without
the temporary wrapper. Prelude regeneration was byte-identical. The earlier
hosted jail lane failed both SQL fixtures with `SqlUnavailable` while the old
seed lacked this dependency; ninety-one other tests passed. No assertion was
weakened and that failure is not treated as a flake.

The architectural freeze test now pins exactly `cap_ffi.erl` and
`loom_cap_lsp_sql.erl`, the reviewed satellite bridges. A third foreign source
still fails. Its fourteen focused regressions passed, and Astra approved the
exact-list update.

Hosted stock-compiler packaging exposed Rebar's absolute `pc` plugin link in
the native seed. Seed preparation now copies only that known in-seed plugin
before the relocated offline probe; archive link restrictions remain unchanged.
The relocation regression removes the original root and preserves plugin modes
and native-library bytes. External targets and nested links are refused. All
51 script tests and four archive regressions passed, and Astra approved this
packaging delta. The fresh seed rebuilt normally; real fixture and distribution
gates must still pass on the corrected head.

Merge criteria: current-head hosted checks and the repository's full Linux
signoff. The owner authorized removing draft status and merging green. The local
aggregate run skipped shipped-server fixtures without their opt-in server and
the Rust manager probe without a working analyzer. The Linux signoff provisions
its own dependencies, runs the shipped fixtures and enforces its skip census.
Existing macOS kernel degradation is reported rather than weakened.

The Linux signoff exposed a missing serial-test declaration for
`cap@lsp_sql_test`: its fixture installs the same VM-global capability channel
as the other capability tests. The parallel package run reproduced all four
failures locally because EUnit also runs a parallel module's individual tests
concurrently. The module now uses the existing serial group, preserving every
assertion while preventing its four fixtures from replacing each other's channel.
The same parallel package command then passed all 172 tests.

The hosted Linux fan-in also caught an undeclared SQL Go fixture skip: its
ordinary conformance bucket did not install `gopls`. That bucket now installs
the same pinned 0.23.0 server as the existing jail and macOS jobs. The fixture
runs instead of gaining a waiver; the strict skip census remains unchanged.

The integration rebase preserves main's reduced caller-side LSP manager and
transport-start ownership. SQL collection now reads its workspace and timing
from that handle. The retired-tool memory regression follows the live
write-diagnostics observer, retaining the sibling-capture assertion rather
than discarding coverage. Astra found no actionable integration defect.
The `acc648436` tree passed the full local gate, all six Linux signoff lanes,
release/update verification and the strict skip census. The next integration
preserves merged strand-wait slicing and its accepted protocol record, with
the prelude regenerated from both capability surfaces. This rebased head
requires fresh local, hosted and Linux signoff results.

## October 2 daemon memory pass

The pre-removal `codex/memory-lsp-query-handle` measurement reduced the seven
direct LSP tools' flat copy cost from 2,205,760 to 184,920 bytes using the installed daemon's
configuration in an isolated probe VM. Each tool owns only its callback;
the caller-side manager excludes transport-start custody. The manager actor
and keeper still own startup. See
[the live evidence and validation](review/daemon-memory-2026-10-02.md).

The installed build remains `a3dc2535`; there is no installed RSS reduction
claim. Targeted collections reclaimed 57.712 MiB of allocation across six
owners, while the service supervisor's restart inputs remained. The second
process named `loomd` is a `web_search` satellite. The two roughly 92 MiB
terminal clients lack profiling nodes; attribute their BEAM owners after a
client launch with `--profile`. The next memory exit criterion is a matched
installed baseline/candidate run with the same workload and observation cuts.

The CPU extension reuses Darwin descendant-tracker scratch under the ledger
lock: the 1,200-row indexing benchmark falls from 46,672 bytes and six
allocations to zero, with median time 9.9% lower. Kernel reads, 20 ms cadence
and birth-checked delivery remain. `loom observer` / `loomd observer` now
attach to a profiled daemon, with `--pid` for a profiled client and `--erl` for
a local Observer/wx installation. See `docs/distribution.md` for navigation.
Installed CPU savings and function-level attribution of the busy unprofiled
terminal remain measurement work, not established results.

## Local orientation in large modules (issue #593)

Branch `lint/local-orientation` ([PR #679](https://github.com/Roasbeef/loom/pull/679))
carries all six of issue #593's suggestions: the style guide section, the
content, and the gates.
`docs/gleam-style.md` Part II, "Orientation in large modules", is the rule
of record; `packages/lint/CLAUDE.md` says how each check decides.

- **Gates (error tier).** R13 `flow-spine`: every hand-written module of a
  thousand lines or more opens with a `//// ## Flow` spine, and every
  backticked name in any spine must be a function the module defines (or
  `alias.fn` on an import). A spine may instead be a ```` ```text ````
  diagram, read by shape: a word with an interior underscore or written as
  a call must resolve. R14 `transition-table`: a
  `<!-- transitions: module.Type -->` table's rows must be exactly the
  type's constructors. R15 `state-first`: a module with a step function
  (`update`, `step`, `transition`, `handle_message`, `handle`) defines the
  types its signature names above its first function. R16
  `qualified-domain-call`: no unqualified import of a Loom function.
- **Censuses (warn forever).** R17 `flow-order` (zero at the default 50%)
  and R18 `unnamed-helper` (859: short one-caller helpers the module doc
  never names). Never pad a module doc with helper names to quiet R18.
- **Content.** 99 modules gained spines, 47 late state types moved up, two
  imports were qualified, and fifteen transition tables are checked against
  their types: `session_channel.Phase`, `broker/exec.Phase`,
  `broker/escalation.Phase`, `codemode/satellite.Phase`, `client/jobs.Phase`,
  `client/provider_relay.Phase`, the `Phase` of `client/daemon/root`,
  `ui_socket` and `session_socket`, and the language-server stack's six
  (`client/lsp/manager.Phase` and `KeeperPhase`, both `lsp/client.Phase`
  tables, `client/lsp/jail.Phase`, `lsp/framing.Buffer`).
  `client/daemon/manager.Phase` and `runtime/strand_runtime` were judged
  too thin for one (two states; no single phase type).
- **The style was applied to what landed during review.** Main's
  language-server stack, revamp groundwork, memory and resource retention,
  code-mode cues, MCP concise types and JSON-RPC codec were brought into
  line: spines for new modules past a thousand lines, stale spine names
  fixed, the six language-server tables marked for R14, and the 61 short
  one-caller helpers those changes introduced reviewed under rule 4 (five
  pure forwarders inlined, 56 kept as domain operations, function values or
  multi-call helpers). A spine's wire fields are quoted literals, and a
  module with no functions carries a description, not a Flow section.
- **When new code lands without the style.** The gates catch a missing
  spine past a thousand lines, a stale spine name, a table out of step with
  its type, a late state type and an unqualified Loom import. They do not
  catch an unmarked table or a helper that names no domain operation; a
  table written by hand needs its `<!-- transitions: module.Type -->`
  marker, and R18's census is the reading list for the second.
- **What a change now costs.** Renaming a function a spine names, adding a
  constructor to a tabled type, or defining a state type below the code
  that handles it fails `make lint`. Writing a wire field in a spine needs a
  quoted literal (`"message_stop"`), because a bare backticked lowercase
  name is read as a function.
- **Left open.** The `session_channel` table agrees with the P model under
  `protocol/models/terminal-attachment` wherever the model has a cell; the
  model has no resume path, lookup or history intents, or server refusals,
  so those cells are unchecked against it. A mechanical check of the table
  against the model's states is the follow-up the issue names. Prose
  citations (`file.gleam:N`) were re-pinned through the diff after the
  sweep; a large module-doc edit will shift them again, and doc-check gates
  only the symbol-checked ones.

The October 1 resource and typed-MCP follow-ups are separate changes with
separate evidence. [PR #689](https://github.com/Roasbeef/loom/pull/689) was rebased
onto main `7d37ec86`; its final resource head is `4a6e4fad`. The owner authorized
merge once that exact head is ready. Fresh hosted CI and local signoff are being
checked; the earlier green results in the review report belong to their named
heads. The running normal daemon was not upgraded by these follow-ups.

## Memory and CPU follow-ups

The [resource report](review/daemon-resource-usage-2026-10-01.md) covers context
metadata, peer-router, gateway membership and restart-callback projections, plus
Darwin tracker allocation reductions. A matched bare-session fixture measured
1.521 MiB less idle BEAM memory and 5,776 KiB less RSS than main `31db7c68`.
Darwin's sleeping execution fixture allocated about 14 percent fewer bytes and
96 percent fewer objects; CPU windows overlapped. These bounded observations do
not establish savings for an installed normal session. Earlier installed-daemon
cuts and the live Jev result remain historical evidence in that report.

A local rebase gate exposed two fixture failures. The operator-page connection
timeout passed five focused repetitions. The job-stop/reopen failure had a
concrete ordering defect: the test treated cancellation acknowledgement as a
completed durable write and observed Lost before notification handling finished.
Existing actor poll/list barriers fix that fixture. A forced schedule fails the
old fixture and passes the ordered one. The scanner fixture also waits for
asynchronous rearming and checks the exact logical deadline, preventing an
unrelated driver timer from satisfying its retry bound. Production source and
deadlines remain unchanged. Final checks must belong to `4a6e4fad`, not its older green CI heads.

The [directory follow-up, PR #691](https://github.com/Roasbeef/loom/pull/691),
projects a restartable writer address for mutation and Storage for readback.
Its [review report](review/directory-fact-retention-2026-10-01.md) records constant
1,385-flat-word administration overhead as unrelated executor payload grows.
Package gates, independent review, full local signoff at the named pre-rebase
head, and a fresh-runtime retirement witness passed. Its rebased hosted head is
`b06b3a29`. These term measurements do not predict installed RSS. The additive
internal fact interfaces were approved by the owner; public signatures and wire
contracts remain unchanged.

## Concise typed MCP

The [concise MCP report](review/mcp-concise-types-2026-10-01.md) explains the
replacement for exposed node-path names and branch wrapper records. Semantic
names have module-wide collision allocation, and required distinct literal tags
belong to constructors such as `ChoiceQuestion` and `ScoreQuestion`. Decoders
still require exact tags and closed objects. For the same four Jev schemas, full
API prose shrank 48.35 percent in bytes; this is not a tokenizer measurement.

The MCP gate, independent review, full local signoff at `ac0c26ca`, and the
installed-server HTTP fixture passed. After rebase, release `239db772` also
passed all three Jev channel regressions and the real isolated daemon fixture:
generated API discovery, jailed mixed batch, exactly one HTTP request, expected
durable result, credential confinement, and authenticated shutdown exiting zero.
MacOS filesystem/network enforcement ran; resource-limit and process-lifecycle
gaps remained explicit. The fixture used dummy credentials and no live Jev call.
[The Jev walkthrough](jev-mcp.md) contains the complete tested program.

Jevelin's installed self-contained launcher is still the open
[installer PR #1](https://github.com/Roasbeef/jevelin-mcp/pull/1) at `307b7e4d`.
It bundles its own ERTS and boot files. Newly assembled Loom session runtimes
regenerate MCP modules automatically; resident sessions keep their assembled
surface, and saved programs using older generated names need updating. Resources,
prompts, and Loom HTTP transport configuration remain separate scope.

Next: verify and merge #689 at its exact final head, then retarget its follow-ups
to main and verify their final hosted checks. Installation and a matched normal-
daemon measurement remain separate from source proof. Keep actual process heaps,
allocator carriers, flat-size retention evidence, and OS RSS distinct; do not
force collection in ordinary-runtime comparisons.

## Code-mode prompt cues

The prompt change is rebased onto `5fbcda3ad` on October 1, 2026. It adds executable
alternatives to the five direct workspace-tool descriptions only when the
default code-mode seam admits and services the call. `loom-default-13` asks
for immediate planned batching, API discovery before unfamiliar calls, and
explicit completeness and truncation checks. The third-probe fallback remains.
Compile failures retain diagnostics and state that execution never began.

The comparison is recorded in [the prompt review](review/code-mode-prompt-cues.md).
This change retains the complete capability types, discovery and recipes.
Calling instrumentation remains in [PR #673](https://github.com/Roasbeef/loom/pull/673);
the reduced-roster experiment remains in [PR #433](https://github.com/Roasbeef/loom/pull/433).
Neither is implemented by these prompt cues. The next evaluation should compare
model call choices and compile failures on the same workspace tasks; source
size alone cannot establish improved batching behavior.

The validation below predates this prompt change and belongs to its named
heads. The new review record carries this branch's own gate results.

## Concurrent watcher and language-server reliability (PR #687)

The reliability work is based on `f84842d17bc3230c2a796f136d222b5179b5be28`,
checked on October 1, 2026. Main's hosted
[run 36922134008](https://github.com/Roasbeef/loom/actions/runs/36922134008)
is green at that exact base. This branch's local results belong to the
reliability changes, rather than to main or a running installation.

## Watcher and language-server reliability

[Protocol 061](../protocol-change/061-watch-and-lsp-reliability.md) records
the accepted changes. A session-lifetime watcher survives abort of the model
operation that started it. Remembered wall-zero consent authorizes only the
same strand, tool and canonical arguments; another action still needs its
own authority. Finite jobs retain their previous abort semantics, and
explicit owner kill and session close still stop session jobs.

A language-server lease can read the session-authorized portion of the
workspace, including sibling path dependencies. Package writes, protected
paths, network-off and server-named answer admission keep their existing
boundaries. Retained error-level window messages make empty semantic replies
and diagnostics report `Unavailable`. A diagnostics deadline and an empty
hover or rename object cannot erase that failure.

`loom-default-11` explicitly asks agents to prefer offered LSP tools for
definitions, references, types and file symbols, and use `cap/lsp` for batches.
It also distinguishes unsupported features from setup failures and advises
against repeating failed probes without new evidence. Existing sessions keep
their pinned prompt. Code-mode guidance keeps warnings as errors and gives
concrete import and repair advice.

The complete affected-change gate exited zero in 495 seconds on the final
executable tree `0372d301b`, with a fresh helper, shipment and offline seed.
The [review record](review/watch-and-lsp-reliability.md) records its package
counts, review regressions and actual jailed code-mode/LSP proofs.
The running user daemon was not upgraded by this work. Hosted verification
and installation remain outstanding.

## Corrections to the earlier records

The earlier watcher paragraph described protocol 058 as branch work awaiting
landing. PR #671 merged at `7b1c662cfd4e9f6fe8d4b63dc8a40e5a54e3a55d`. The new
work repairs consent and custody defects in that behavior; it does not add a
second lifetime API. The older terminal priority still said to land #583;
that PR merged at `8b3455493bbcb11f6788e908664e260fdb4a36db`.

The records below retain their original dated heads and evidence. Their
tracker state and broader remaining-work claims were not re-audited by this
reliability pass and must not be treated as current verification.

## Next actions for PR #683

1. Publish and verify the reliability PR against its exact head. Exit: the
   affected gates, hosted CI and required Linux signoff pass, with the
   review findings closed. PR #683 independently changes code-mode prompt
   guidance; preserve both sets of instructions during integration.
2. After landing and updating the daemon, check real watcher survival across
   stop/resume, reusable exact-action consent and a positive semantic query
   in a sibling-dependent Gleam project. Exit: the watcher remains running
   and a real `cap/lsp` call returns semantic content without repeated
   approvals for the same action. A new session gets the revised prompt.
3. Recheck the tracker before resuming the older terminal, Trace and remote
   access priorities. Their design choices remain separate from this fix.

## Rulings to preserve

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

Exact-action consent cannot become general unlimited wall authority. Session
job attribution and broker custody have different identities. LSP sibling
reads derive from existing authority, while writes and answer admission stay
package-scoped. [Protocol 061](../protocol-change/061-watch-and-lsp-reliability.md)
and the ADR-015/016 addenda record these boundaries.

## How to verify this work

Use `make check-affected BASE=f84842d17bc3230c2a796f136d222b5179b5be28`, followed
by the required signoff. Focused reproductions use `bash scripts/test.sh lsp`,
`bash scripts/test.sh client --match client@lsp@jail_test` and
`bash scripts/test.sh conformance --match conformance@lsp_e2e_test`. Build the
helper and offline code-mode seed first; a prerequisite skip is not proof.
Read each gate's own exit code. See [execution](execution.md) for the remaining
verification rules.

## Earlier baseline records

## MCP handoff baseline

The MCP handoff was refreshed against `f875811be` on October 1, 2026.
The previous edition described extraction validation as pending before
merge. [PR #669](https://github.com/Roasbeef/loom/pull/669) has now merged
at `1b2a1748deb4bafe59b4f12312d167eae1525c0b`.

The [Jev MCP walkthrough](jev-mcp.md) records a successful real-daemon
integration at the merged extraction tree `5aad549bd`. A scripted local
model discovered the generated API through `cap://mcp/jev`, submitted a
Choice query to code mode, and received the Jev fixture's answer. The
hermetic build, satellite, MCP process and HTTP adapter all ran. A fresh
credited snapshot retained the completed tool result and final assistant
response; authenticated daemon shutdown exited zero. That earlier run used a dummy credential and a local HTTP fixture. Live
Jev authentication and inference now pass through both installed Loom and
the typed-generation shipment, using the installed self-contained Jevelin
bundle at `18ab557`. The service identifies itself as `jev-1.13.0` and
returns `logs` with confidence 1.0 and usage 324/31. Each isolated daemon
retains the completed result and exits zero after authenticated cleanup;
the credential remains outside model requests and configuration. Evidence
is in `build/jev-live-20261001-150405` and
`build/jev-live-20261001-151059`. A fresh session in the normal running
daemon also passes the live query; `build/jev-live-20261001-151240` records
its completed durable result and cleanup to saved state, preserving the
daemon and existing sessions. The enabled Stop hook added one model turn.

The normal daemon needs a newly assembled session to discover an installed
MCP server; existing resident sessions keep their previous generated modules.
Keep the key in daemon environment configuration or its command-backed
secret store. Resources, prompts and Loom HTTP
transport configuration remain separate scope.

The validation history below belongs to the exact heads and runs it names.
It is not a new full-gate or hosted-CI claim for this documentation baseline.

## Typed MCP generation (issue #449)

The follow-up to extraction adds recursive structural schema planning and
matching generated declarations. Required inputs can be nested records,
lists, enums, named booleans, nullable values and supported disjoint unions.
Optional inputs use tool-specific `Options` records and omission constants.
Unknown shapes remain explicit `report.Value` fields, so typed siblings and
required names survive fallback. An advertised `outputSchema` now produces
a typed return with a total decoder inside the satellite.

The fixed codec lives in `cap/internal/mcp_codec`; generated functions still
call the internal per-server capability seam. `ResultSchemaMismatch` retains
its path and original tool result. Structural shape, enum, literal and
closed-object checks belong to this decoder. Numeric bounds and general
JSON Schema refinements remain server admission checks. This work changes
no frozen capability envelope and grants no additional server authority.

The earlier claim that MCP describes only inputs is corrected in the
[MCP architecture](architecture/mcp.md). Its GitHub triage example still
uses raw result readers because that fixture advertises no output schemas;
the input options now use generated types. The [Jev guide](jev-mcp.md)
distinguishes the earlier #669 integration proof from the typed program.

The exact typed Choice program passed through a fresh production daemon on
October 1, 2026: `fs_read` discovery, jailed compilation, satellite execution,
Jevelin MCP, one HTTP fixture request, typed output decoding and a durable
structured outcome. The run exited zero; `build/typed-reviewed-jev-daemon-e2e.log` retains its output; evidence is retained in `build/jev-e2e-20261001-144704`.
The dummy credential stayed confined and authenticated cleanup exited zero.
The program in the guide matches the tested source byte for byte.
The focused native client suite passed eight cases covering nested options
and null presence, typed output, retained mismatch text/path, and compiler
rejection of malformed enum/options/nested input before any tool call. The
complete GitHub-shaped facade compiles in the jail, and the documented
structured example runs unchanged. A schema-valid nested union result also
survives a rendering fallback without an ambiguous decoder failure.

The independent review reproduced three issues: constructor names whose
semantic fragments imitated ordinals, a union discriminator lost during
nested fallback, and an unused payload hidden by module-alias references.
`832f17a2` fixes them with trusted ordinal prefixes, rendered-shape
exclusivity checks and encoder-owned payload usage. The scoped independent
recheck compiled all three original reproductions without warnings and
decoded the valid union result unchanged. The final MCP suite passes all
117 tests with zero lint errors. Generated display suffixes are capped at
64 ASCII characters without changing wire literals or declaration identity.

The complete local `make check` passed at the earlier `cb2effa5` head, with
zero lint errors. Its own exit code is recorded in
`build/typed-full-check-status.json`; that gate does not prove later review
fixes. The current real code-mode suite passed all 26 tests, with the
Linux-only process-retirement case feature-skipped on macOS.

macOS Seatbelt filesystem/network enforcement was active; resource and
lifecycle enforcement remained degraded. Live Jev authentication and
inference now pass in the separate runs recorded above. Full-gate and hosted-CI claims still belong to
the exact final head and runs recorded with its pull request; the historical
results below do not prove the new generator. The affected full client gate
passed all 2,614 tests after the review fixes. The subsequent official Go SDK
v1.7.0 capture regression also passes in the real jail; its provenance pins
the actual SDK-generated nullable input/output schemas.

## Extraction rebase history

The MCP extraction is rebased onto `origin/main` at
`275efc42e7909c3c3ec481b7466c3484f381eb80`, including the typed capability
surface from PR #670. Recovery refs retain the previously tested `a569e1f68`
and `a102a3523` heads. The import conflict retains both main's typed-operation
module and the extracted SDK client; the package documentation retains both
main's typed schedule projections and the MCP boundary. Main's capability
sources, generated prelude and protocol 057 remain unchanged by extraction.

The independent GPT-6.1 Sol review at high reasoning found no high or medium
findings at `14dc4545d`; its stale ownership comment was corrected without
changing executable code. The preceding published head `a102a3523` passed
complete hosted Linux/macOS CI in [run 36795638550](https://github.com/Roasbeef/loom/actions/runs/36795638550)
and a fresh containerized Linux signoff, including all six lanes, release
updates and a clean skip census. Its full local gate passed with 2,401 client
tests and zero lint errors. These results belong to that head; validation of
the latest rebase is recorded on PR #669 before merge.

## Standalone MCP extraction

Generic JSON/JSON-RPC, framing, client actors and native process custody
live in [Gleam MCP](https://github.com/Roasbeef/gleam-mcp). Both direct
consumers and the conformance closure pin
`686955fc0461630bf64a4dc8eb51565dc7ca1ac9`. Its full Linux/macOS CI passed
[run 36765278006](https://github.com/Roasbeef/gleam-mcp/actions/runs/36765278006):
232 unit tests, including every required Draft 2020-12 vector; 139 linter
tests; five tooling checks; and 39 native stdio/HTTP/TLS checks. Independent
review findings were fixed and rechecked before publication.

The direct Mist dependency matches the SDK at
`28b43178ff57bfb619c64b8c3544831646d5fdb9`; all affected locks resolve Glisten
to `3eb785919be0736da0a20732a56275dce0132327`. Glisten registers its connection
factory before its listener and acceptors start. Mist registers its SSE
factory before Glisten starts. Reverse shutdown stops admission before
retiring those factories. Mist's framing and startup fixes passed
[CI](https://github.com/Roasbeef/mist/actions/runs/36764236673) and remain
open in [PR #2](https://github.com/Roasbeef/mist/pull/2) and
[PR #3](https://github.com/Roasbeef/mist/pull/3).

[Glisten PR #1](https://github.com/Roasbeef/glisten/pull/1) merged into
`compat/v9.0.1` at `1e53a4d9befb3fe6fb6f9cee2d9b13ba621a2e67`. Consumers
retain the tested `3eb7859` commit rather than moving to that merge commit.
The upstream startup-order report is
[rawhat/glisten#55](https://github.com/rawhat/glisten/issues/55).

The SDK adds released MCP `2026-07-28`, typed tool definitions, HTTP, explicit
multi-round-trip continuations and owned subscriptions. Loom continues to
use its initialized stdio profile and supplies its own client identity,
server isolation and result reduction. Optional resource and prompt APIs
are tracked in [SDK issue #1](https://github.com/Roasbeef/gleam-mcp/issues/1).

`packages/mcp` retains four pure adapters: code generation, schema planning,
name sanitization and MessagePack interchange. Frozen core and capability
interfaces are unchanged. `client/mcp` reduces lossless non-text content
only when constructing the existing capability result. The generic suites
moved with their implementation; local adapter and actual-server fixtures
remain here. Current main's other dependencies, including weft 0.4.5 and
its shared UI packages, were preserved during rebase.

The fresh offline seed and focused `make check-mcp` passed at `7b8cd39f9`,
each with its own zero exit status. The full local `make check` also exited
zero through the public SDK/Mist/Glisten pins with that fresh seed and the
CI-matching patched Gleam 1.19.0-rc2 compiler. All packages, native tests,
static gates and lint passed; lint reported zero errors and 943 warnings.
Published extraction head `6de0188aaea01ede036082d0d5c19ce0d06dd5af`
passed the required Linux gate and macOS advisory package check in
[run 36767905423](https://github.com/Roasbeef/loom/actions/runs/36767905423).
A fresh public Linux checkout built its helper and seed, then passed 102
adapter tests, 29 native client MCP tests and both actual MCP/configured-server
code-mode exchanges with no skips. An independent rerun of both E2Es passed
at that same head. These results belong to `6de0188`, rather than being
reassigned to the subsequent fixture correction.

The first macOS e2e attempt timed out observing the shipped multiplayer tool's
return to idle after its final answer was visible. The original shipped-bootstrap
target passed locally, followed by five fresh runs of the original multiplayer
module. The hosted rerun also passed bootstrap. The first timeout remains
intermittent with no established source cause; no deadline or assertion changed.

The macOS rerun then failed `worktree_diff_test.gleam:95` with GitFailed(128),
matching [exact base main `01f14ef8`](https://github.com/Roasbeef/loom/actions/runs/36694588061/job/109820029705).
The earlier assumption that repository layout alone explained this failure was
incomplete. A normal local clone still passed under Apple Git 2.39; changing
only the Git version to 2.55 reproduced the failure. Both independent runs
used the original source and helper: fourteen tests passed under 2.39, while
2.55 failed one with `fatal: error reading '<checkout>/.git'`.

The uninitialized fixture was beneath the source checkout, so it did not
satisfy its outside-Git premise. Seatbelt correctly denied reads of ancestor
repository metadata, and Git 2.55 treats that discovery denial as fatal.
Correction `b69de8672` constructs private fixtures under `/var/tmp`, following
the existing shipped-jobs convention and avoiding Linux's `/tmp` scratch mount.
All fourteen assertions pass on the changed source under Git 2.55 with no skips.
The full client gate also passed under Git 2.55: 2,398 tests, formatting and
warning-free compilation. The documentation check exited zero.
The sandbox grants, production error classification and test deadlines remain
unchanged. Independent review found no additional affected assertion.
Published correction head `314c3071c` passed its required Linux gate. Its actual
Linux jail ran all fourteen observations under Git 2.55 with eleven enforcement
layers active and zero skips, and its terminal-observation skip census was clean.

That head's macOS run passed multiplayer, then failed the shipped-confinement
turn at `daemon_shipped_confinement_test.gleam:353` before reaching the corrected
Git fixture. The interval between the token tool-use and final-text provider
announcements was 7.887702 seconds; the final announcement preceded the original
eight-second UI timeout by only 32.902 ms. That interval includes transport,
durable transitions, tool execution and the next provider request, so it cannot
be attributed to shell execution from the uploaded evidence. Five fresh local
runs of the original confinement fixture passed. Neither this timeout nor the
earlier multiplayer timeout has an established source cause.

Diagnostic commit `759ab088d` uses the existing terminal recorder in those two
fixtures, with unique session/role paths. Their assertions and deadlines remain
identical. `LOOM_TEST_TIMING=1` adds a second stock OTP handler only to the private
shipped daemon launcher; it retains UTC event timestamps and existing debug
provider/tool dispatch and settlement events without changing the JSON handler.
Terminal recordings are unconditional in the two fixtures; the extra daemon
handler is opt-in. Its 8,192-character limit applies per event, not to the file.
The actual local confinement and multiplayer suites passed with this handler,
and their generated logs and raw frames were inspected. Independent review
approved the unchanged cleanup, grants and assertions. The complete local
client gate also passed all 2,398 tests, formatting and warning-free compilation;
the documentation check exited zero.

CI commit `a0300e896` enables this evidence for shipped bootstrap and uploads the
private effect logs and terminal recordings. The original hard macOS terminal
observations run before bootstrap so its failure cannot hide their result; the
zero-skip census and failing fan-in are unchanged. Pre-rebase head
`a569e1f681fae2098979ff79bd327fc30e43ebde` passed both aggregate gates in
[run 36779051580](https://github.com/Roasbeef/loom/actions/runs/36779051580).
Its timing artifacts were inspected. Both intermittent timeout causes remain
unconfirmed; a green run does not prove their correction. The rebased head
requires its own hosted verification.

[Jevelin MCP](https://github.com/Roasbeef/jevelin-mcp) consumes the SDK and
existing Jevelin library directly. Published application head
`fb5b434bde8d48736c835d44a4a176efb17d007d` passed Linux/macOS CI in
[run 36766066616](https://github.com/Roasbeef/jevelin-mcp/actions/runs/36766066616).
Its four shared typed definitions retain original label/rubric/batch
decoders. An independent Linux build passed the full application gate through
the public dependencies, then fifty fresh runs of the original HTTP peer.
Those runs retained all assertions, including 150 bearer refusals and fifty
Origin refusals. The inherited startup blocker is closed by the published
factory-order fixes above. That application-head validation used fixtures.
The installed-release live inference proof at the start of this handoff
supersedes the earlier statement that authenticated Jev requests were untested.

[PR #669](https://github.com/Roasbeef/loom/pull/669) records the current
validation boundary and review status. Continue to require the full gate,
real native MCP process and configured-server code-mode exchanges when
updating this dependency. Remote MCP admission policy remains separate
from the reusable library's HTTP implementation.

## Existing work on main

The preceding main handoff is preserved below. Its references and validation
are attached to the heads it names, rather than reassigned to this extraction.


This handoff is baselined against `998be7a64` (`main` after #666, the last
pull request that closed [#569](https://github.com/Roasbeef/loom/issues/569))
on 2026-09-30. Tracker state was read with `gh` the same day. Every claim
below was checked against that tree or that tracker; a claim that could not be
checked says so.

## Persistent web-view startup

`[daemon] ui = true` enables the web view when ordinary `loom` starts a
new daemon from the selected catalogue. Omission keeps it disabled, and
`loomd --ui` enables it even when the file says false. Startup captures
UI and connection limits from one read before preparing the root; session
catalogues and later file edits cannot change a running listener. Restart
an existing daemon to apply the setting. `loom ui --session ID --open`
still requests a browser link; `loom --ui` remains its older spelling.

## Herdr integration corrections (this branch)

The `tui/herdr` adapter was audited against upstream herdrdev/herdr
(v0.9.1 locally, v0.9.3 upstream) and four real bugs were fixed. The
previous wire format was schema-valid but claimed an identity Herdr
cannot honor: it reported under the reserved `herdr:loom` source, and
its docs claimed session restore keyed off the announced session id —
but Herdr's `agent_session_id` restore path is gated by a hard-coded
allowlist of its own integrations (`is_official_agent_source` in
upstream `src/agent_resume.rs`), in every version through 0.9.3, so
resume never worked and the announce was dead weight. The adapter now:

- reports under the third-party source `loom:terminal` (the `herdr:`
  prefix is reserved for Herdr's own integrations, per their
  add-herdr-support guide)
- carries `resume_argv` `["loom", "--session", <id>]` on every state
  report — the actual third-party resume mechanism, honoured by Herdr
  0.9.2+ and safely ignored by older servers
- queues `pane.release_agent` on quit as the last effect of the step,
  a bounded synchronous exchange the runtime performs before the loop
  exits, so the pane clears before the VM halts instead of waiting for
  Herdr's idle-shell safety net
- names the pending approval in a blocked report's `message` (tool +
  preview, with a count when several queue up), and the message is part
  of the change comparison, so a second approval while blocked
  republishes

What was already correct and is pinned by tests: the env gate, NDJSON
framing, one-request-per-connection exchanges, the `PaneAgentState`
enum, the wall-clock sequence seed, and change-detection. Herdr 0.9.1
→ 0.9.3 upgrade is safe for existing panes (no breaking change beyond
the removed pane-graphics API, which Loom never used) and is what
activates `resume_argv`.

## What the previous edition got wrong

The previous edition was pinned to `3088ee3ce`, before the last three lanes of
#569 landed. It is stale in these ways.

- It called #569 open and listed its remaining items as work. All of them
  merged in #665 and #666, and #569 was closed on 2026-09-30 with a comment
  that says so.
- It said the page cannot show settled strands or images, and that 053 phases
  2 and 3 and the invite control were not built. They are built (below).
- It ordered the Trace tab and remote access after the terminal revamp with
  the revamp waiting on #569. The revamp is now first, and #656 and #654 follow
  it.
- It said a streamed code block re-sends the whole block each batch and that
  an unsettled generation leaks its start time. Both are fixed (#658).

The statements about the step extraction (ADR-014's blockers, the shared step)
were checked again and still hold.

## Where the tree is

**Part 1 of #569 is done, and so is the issue.** The session's half of the
client step lives in `packages/session_view`, which depends on `core`,
`machine` and `gleam_stdlib` alone, held there by lint R6. It holds the lane
(`session_channel`), the decoders, snapshot adoption, the projection and the
line builders, and the shared step: the session record
`model.Shared(socket, recorder, source, replay_source)`, the folds of pushed
events and lane updates (`event_fold`, `lane_fold`), the operator's commands
(`commands`), the side-surface reads (`surfaces`), the settle, and
`step.update`.

The two hosts run it in different shapes.

- **The terminal** (`packages/tui`) holds `Model(shared, view)`, with
  `TerminalShared` binding the four handle parameters. It calls the shared
  units one at a time, applies the surface facts each records between the
  drain's updates, and does not call `step.update`. Its socket wakes its
  loop, and `terminal_poll_timeout` follows the lane's deadline with a
  one-second idle ceiling, because a resize needs a poll.
- **The web view** (`packages/web_view`) holds `component.Model(shared,
  view)`. `update` reads the transport's clock once, hands the step a
  message (`Arrived` files, `Ticked` drains and ticks, `Acted` runs a
  command) and derives what it draws from the record the step left. A burst
  of at most 64 frames is one message, and so one render, and one timer is
  armed for the lane's `next_due`. `session_view/step_test` holds
  `step.update` to the order of the terminal's tick.

The lane's pushing refresh is 5,000 ms, and the gateway pushes the roster to
a subscriber (protocol-change/054). [Delivery](architecture/delivery.md)
explains the ordering and ownership, and [the client
architecture](architecture/client.md#the-client-engine-and-its-hosts) is the
map.

**The page today (concept A2, [the web design
note](design-notes/web-design.md)).** `loomd --ui` serves an observer's page
and an operator's page for one session. Both draw:

- **Three collapsible columns** inside `<loom-shell>`: a sessions sidebar
  (operator pages only), the transcript and dock in the centre, and a
  right-hand panel. Buttons at the ends of the top bar hide each side
  column, and a hidden column is inert and out of the tab order.
- **A tabbed panel** with Strands, Changes and Session. Strands holds the
  strand cards and the detail of the strand in focus, and lists settled
  strands after the live ones as a collapsed group (#659). Changes lists the
  files the session's own edits changed, keyed by path, and is always
  present. Session shows the goal, jobs, viewers (operator pages only) and
  estimated cost. There is no Trace tab (#656). In the Strands pane, under
  the strand cards, the advisor's settled commentary is a read-only section:
  the request labels and full bodies, newest three then a count
  (2026-10-02); the lane keeps one hairline per review where the full amber
  blocks were. Under the panes, on every
  tab, the advisor's pending nudges are a read-only card (2026-10-02: it
  moved out of the dock, which also lost its Stop button and Set goal form —
  stopping is the terminal's Escape and a goal is pinned by typing `/goal ...`).
- **Strand focus.** A card, a chip of the agent strip or a timeline row
  focuses a strand, and the transcript, breadcrumb, composer target and
  approval cards follow it. The transcript is a timeline with a dot in the
  hue of each piece's strand. A settled strand can be focused, and the roster
  then lists it.
- **Rows and streams.** The agent strip with cache rings and miss notices,
  turns with folded work, sub-agent, advisor and peer rows, rendered
  Markdown, expandable rows, the todo panel with the reviewer band, live
  reasoning and answer streams, and the newest 150 rows with paging back to
  300 (`Load older`). A streamed fenced code block is drawn as keyed line
  spans, so a batch patches the lines that changed and not the whole block.
  The generation clock restarts per request and on a change of strand, so an
  unsettled generation no longer leaks its start into the next elapsed
  reading (#658). The memory context the daemon attaches to a prompt is shown
  collapsed under it. Advisor nudges are shown read-only.
- **Images** (#661). A transcript row shows the images its message carries,
  served from a same-origin image route that reads under the page's cookie
  (`ui_sessions.images`), so the content security policy does not loosen. The
  operator's composer attaches images with a prompt. An operator's page
  socket takes a 12 MiB frame, and the `PageOperator` connection class is
  charged 64 MiB, which covers the five copies of that frame the submit's
  decode chain holds at once (`ui_socket`, `root.operator_peak`).
- **Keyboard.** `<loom-shell>` listens on the document for three keys
  (`shell_rule.intent`): Command or Control with B toggles the sidebar, with
  Alt as well it toggles the panel, and Escape returns to `main`. A key is
  ignored while composing, when already handled, when held down, and inside
  an approval card. Escape also does nothing in the composer. None of them
  sends a decision.
- **Saved layout and theme.** Whether each side column is open and which tab
  shows are kept in the browser's storage per workspace, under a key built
  from a digest the daemon computes, and the theme (system, light, dark) is
  kept per browser. The storage is two calls, `storage_read` and
  `storage_write` in `web_client/internal/dom.mjs`, reached through
  `web_client/internal/ffi_dom`; `layout_rule` does the rest and reads any
  stored string totally. Nothing derived from a session is stored, and the
  server never learns the layout.
- **The operator's composer** completes slash commands, sends on Command or
  Control with Enter, takes a returned prompt back into the editor, and
  runs any session command a draft names except `/add-dir` and
  `/add-write-dir` (protocol-change/051, the newest addenda).
- **Session switching** (operator pages). A sidebar row for a running
  session other than the one on screen, or an Open button on a peer message
  that names one, asks the daemon for a ticket. `ui_socket` mints it into
  the ticket table with the page's own principal and ceiling, and
  `<loom-switch>` navigates the browser to the exchange address after
  `switch_rule` checks its shape, with `location.replace` so the tab keeps one
  history entry per page and Back does not land on a page whose nonce is gone
  (#658). A ticket whose source page has already ended is refused as
  unknown, so a switch never revives a page past its deadline. A principal
  may hold up to four pages per session (`ending.max_pages`), and a page
  ended by that cap or by a restart says so.
- **Share and invite** (owner's operator page, #663). An "invite to this
  session" control offers an observer button and an operator button. It makes
  the invitation `loomd access invite` makes, with a claim that lives one hour
  (`invites.claim_ttl_ms`), and shows the command and token once in copy
  boxes. A credential may mint three invitations an hour
  (`ui_sessions.reserve_invite`). The page checks the principal and the
  capability again when the click arrives (`ui_socket.invite_for`). The
  protocol-change/051 addendum on inviting from the session page says what a
  stolen owner page is worth.

**Access tooling.** 053 phases 1 to 3 are merged; phase 4 is not. `loom access`
lists principals and memberships and shows one (`host/access`, the grammar
`loomd access` shares), served by `principals.list` and
`principals.memberships` on the client protocol. The terminal's `/access`
overlay (`tui/access_overlay`) shows the same checks `loom access list` and
`show` print (`membership_lines`), and on a rotation shows the `loom access`
line to run in a shell.

The page still cannot show per-call timing, a skills catalogue for slash
commands, or the composer target menu of the design note's section 3.3 (not
built, no owner ruling).

The toolchain is Gleam 1.19.0-rc2 (`.github/workflows/ci.yml`). `make
check-affected BASE=origin/main` runs only the gates a change can affect; a
change to the daemon's package also needs `make signoff`.

## Caller-owned messaging inspection and fair delivery

The messaging work landed in #667 at `01f14ef8f` on 2026-09-30. The upstream
web and issue #569 priorities below retain their order; their original
handoff baseline above is separate from this messaging update.

The default code-mode host now exposes caller-owned pending and transcript
inspection through `cap/peer`, existing recipient admission receipt history,
and linked sender receipt lookup. The router supplies session and strand
identity; `peer.roster` still means authorized outgoing remote links. A queued
steer is eligible after the current complete tool batch and before the next
provider request. This removes repeated-tool starvation without preemption.

Inspection is read-only. Admission is not a read receipt. No new local
post-abort retention or acknowledgement was added. Receipt cursors order hash
keys, so pollers rescan and reconcile identities rather than treating them as
arrival watermarks. Protocol 056 records the decision; the independent review
and focused gate evidence are in
[the messaging review](review/message-inspection-and-steering.md).

The six ownership/pagination/abort tests, seventy-two production code-mode
wiring tests, cap marshalling, model-visible discovery, and real jailed
cap-channel proof passed. The next-request runtime regression checks exact
local and remote bodies after a blocked tool completes. The parent's full
`make check` at `c52038cd2` exited zero, including 2359 client tests, 990 TUI
tests and zero lint errors. The next-request regression fails against the old
policy; the page-seek regression fails against the old SQL. The final PR head
`00229385e` passed the fresh-container Linux signoff, including all six lanes,
release verification and the skip census, before #667 merged. Hosted macOS
has a separately
confirmed baseline `worktree_diff_test` ancestor-read failure; do not describe
that CI as fully green or change messaging scope to work around it.

## Typed capability follow-up

The owner's follow-up covers `cap/peer`, `cap/workflow`, `cap/execution`,
`cap/strand`, `cap/job` and `cap/schedule`. [Protocol 057](../protocol-change/057-typed-capability-results.md)
records the approved source API migration, and [the migration guide](capability-types.md)
names the public records, variants, identity parsers and cursor constructors.
Peer pages and receipts are decoded inside the satellite; workflow and
execution preserve channel error categories. Child and job identities and
independent cursors are validated before they become usable handles. Schedule
creation and listing expose granted cadence projected from the host's timing
record, while keeping `when` for display.

The wire shapes remain unchanged except for the additive schedule cadence
field. Sender-owned payloads and custom metadata remain open values. Authority,
delivery priority, admission semantics and retention remain those of #667.
The generated capability prelude prefers each module's own public identity
aliases, so peer-only host programs need no child-strand import.

The follow-up on `cap/typed-surface` is rebased onto `01f14ef8f`. The full
`make check` at `01844b49a` exited zero, including 126 cap tests, 2,399 client
tests, 1,032 terminal tests and zero lint errors. Real jailed proofs cover
peer inspection with exact bodies in both host modes, schedule admission,
listing and cancellation, resident actor input, cross-session grants and
workflow recovery. The independent review's custom metadata collision and
lost body assertion findings were fixed and rechecked. Negative checks kill
both defects, invalid-ID admission, negative-cursor clamping and the original
alias renderer. Capability mutations need a rebuilt code-mode seed; the final
full gate used a restored seed. Hosted CI and Linux signoff on the new PR
remain separate from this local verification.

## Language-server support (issue #25)

The LSP stack merged through [#680](https://github.com/Roasbeef/loom/pull/680),
including #514, #516 and #521, on 2026-10-01. The
[user setup guide](language-servers.md) now covers the three v0.1.0 profiles,
server installation, offline dependencies, host checks and session activation.
This documentation pass was based on `f875811be` and adds no runtime behavior.

Loom's own agent can ask a language server about the code it is editing. The
ruling is [ADR-015](adr/015-language-servers-as-jailed-leases.md) and the
account is [the LSP architecture doc](architecture/lsp.md). Read both before
touching any of it; the ADR's "Measured" table and its corrections are what
the code is built against.

`packages/lsp` carries its own JSON-RPC envelope (`lsp/jsonrpc`) and channel
transport seam (`lsp/transport`) over `core/json` and no longer depends on
`gleam_mcp` (#678, ADR-015's last addendum). That is why the `tools` and
`codemode` manifests do not carry `mist`, `glisten` or `gun`. A third
JSON-RPC consumer would be the reason to share one codec through a split of
`gleam_mcp`; until then the two copies stay separate.

A session whose `loom.toml` carries an `[lsp.<name>]` table gets:

- seven tools, `lsp_definition`, `lsp_references`, `lsp_hover`, `lsp_symbols`,
  `lsp_calls`, `lsp_diagnostics` and `lsp_rename`. They address symbols by
  name (optionally qualified, `util.Greet`, and narrowed by a path and a
  1-based line), never by position, and answer with anchored sites a model can
  feed straight into `fs_edit`.
- settled diagnostics appended to `fs_write` and `fs_edit` results for files
  the running server owns.
- `cap/lsp` in code mode, admitted only when a server is configured, so a
  session without one pays nothing in its cached prefix.
- a rename that previews by default and applies through the hashline landing
  path, refusing the whole rename when any file on disk no longer matches what
  the server saw.

The server runs as an ordinary jailed exec under the session's own enforcement
demand, after a probe proves that demand is met, one per session, with a lazy
restart. A server starts only for a configured `[lsp.<name>]` table or an
installed profile extension; an unconfigured workspace with no installed
profile starts nothing.

Validated on a cgroup-v1 container, so under `BestEffort`: the scripted-model
acceptance in `conformance/lsp_e2e_test.gleam` against a jailed `gleam lsp`
(rename across three files, concurrent-write rejection, an `fs_edit` using a
references anchor) and a `gopls` variant. Not validated there: the enforced
path under `PlatformEnforcement` (the probe refuses on that host, correctly),
and macOS. The Linux signoff on a host with a delegated cgroup v2 base is where
those run.

Language support ships as profile extensions in separate repositories
([ADR-016](adr/016-language-profiles.md) and its 2026-09-30 addendum). Loom
keeps the mechanism: the protocol client, the profile schema and decoder, the
profile extension tier, `loomd ext check`, readiness, `cache_env` and the jail.
The three first-party profiles are
[loom-lsp-gleam](https://github.com/Roasbeef/loom-lsp-gleam),
[loom-lsp-go](https://github.com/Roasbeef/loom-lsp-go) and
[loom-lsp-rust](https://github.com/Roasbeef/loom-lsp-rust), each tagged v0.1.0
with its own CI that builds Loom and runs `loomd ext check`. Install one with
`loomd ext install https://github.com/Roasbeef/loom-lsp-go --rev v0.1.0`. A new
language is a profile, a fixture, `[[check]]`s and a passing `loomd ext check`,
with no change to Loom. Loom's own tests that still run real servers do so to
test the mechanism: the `gleam lsp` and `gopls` sessions in
`conformance/lsp_e2e_test` and the manager's rust-analyzer fixture.

Rulings the next change must preserve:

- **Positions never leave `packages/lsp`.** The model and every surface speak
  `lsp/query.Site`; `lsp/text` is the only converter, against the exact text a
  position was computed on. A site's text is the line as hashline sees it (a
  CRLF line keeps its `\r`), so its anchor is the one `fs_read` prints.
- **Gate every request on advertised capabilities.** `gleam lsp` never answers
  a request it did not advertise.
- **Edits land only through hashline.** The server never writes;
  `workspace/applyEdit` is declined and resource operations are refused.
- **The harness never reads a path a server merely names.** The jail bounds
  what a server reads, not what it names. `client/lsp/resolve.admit` admits a
  server-named path only under the server's root and outside every protected
  entry; anything else is shown with no text and never opened.
- **Enforcement is proven before a server starts,** because the helper reports
  enforcement only when an execution exits.

A weft ordering race the LSP end-to-end exposed, fixed in weft 0.4.5.
`make check` failed the LSP rename end-to-end once, on a machine loaded by two
parallel cold builds. The cause was in weft: a scope monitors an owner, but the
permit that starts the owner reaches it through another process chain and can
overtake the monitor signal, because BEAM orders signals only per sender and
receiver pair. An owner that exited normally in that window was judged
`noproc`, weft read that as `weft_drain_proof_lost`, and the session failed
closed. The scripted provider's owner exits about 100 µs after begin, which is
why this test found the window first; real httpc owners were exposed too, only
rarely.

weft 0.4.5 (Roasbeef/weft#14) puts a delivery barrier between the monitor and
the permit on both owner arms, `adopt_owners` and `adopt_published`. The
barrier is `process_info/2`, not `erlang:is_process_alive/1`: on OTP 29 the
latter leaves the overtaking rate unchanged, measured, although its
documentation promises the same ordering. Against weft itself, under CPU load,
8 or more of 7.68M adoptions settled as `DrainProofLost(Noproc)` before the fix
and none after. Every package pins `weft == 0.4.5`.

Remaining language-server work:

1. The daemon custody retirement path stops the manager with the service tree,
   racing the broker stop that follows. A graceful ordered stop needs a custody
   part in `internal/instance_owner`.
2. The helper writes stdin while holding the mutex `Cancel` needs (ADR-015 §1,
   known hazard), so a wedged server blocks cancel until the broker's
   three-second helper kill. Worth fixing in the helper.
3. Count extension hosts against the per-session lease cap.
4. A second server per session. A Go and a Gleam project side by side evict
   each other today.
5. Follow-ups from the design discussion that are the owner's call: move #26
   (DAP) out of release-blocker in favour of a satellite-local trace
   capability; bounded read-only BEAM introspection for the agent (#454);
   structured session-trace queries beside `history_search` (#236); write the
   upstreaming stance down.

The root `CLAUDE.md` paragraph on `gleam lsp` is about the editor tooling a
developer drives this repo with, which is separate from everything above:
Claude Code still has no Gleam server configured. A project-local plugin with
an `.lsp.json` (`gleam lsp`, `.gleam`) would give local CLI sessions
go-to-definition and post-edit diagnostics; cloud sessions do not start
language servers.

## Next actions, in order

Terminal CPU work merged in #664 at `a54effa07` and is locally verified
against installed `3088ee3ce`: counting strip rows during layout and painting
known-width
padding directly reduced frame reductions by 37.6% and scroll reductions
by 40.8% at 200×50, with identical styled-cell witnesses. Full `make check`
passed; the changed client has not been installed or measured live. See
[the measured report](review/tui-render-cpu-2026-09-29.md) for the fixture,
limits and next live check. The changed client still needs the live CPU and scrolling check.

**Check open pull requests and branches first.** A branch may exist and a pull
request may have opened since this baseline. Continue an existing lane rather
than starting a second one.

The owner's order (2026-09-30) is the terminal revamp, then the Trace tab and
remote access.

1. **The terminal revamp, [#655](https://github.com/Roasbeef/loom/issues/655).**
   It takes the web design (A2) as its reference and begins with a design note
   and screenshots for the owner's sign-off, as the web pass did. Decide first
   whether it takes option (d): moving the terminal onto `step.update` with a
   pure `fn(view, facts) -> view` callback the sequencer calls after each
   piece, so both hosts run one sequence. Exit for that decision: a written
   estimate of the three costs the step-extraction note names (callbacks
   through the step, reordering risk that the replay identity checks catch,
   and the Erlang inliner on long settle chains), measured with
   `scripts/tui_perf.sh` and `erlc +time` before any code. The small composer
   notice bug, which reads "prompt_content admitted" after a send, is listed on
   #655 and can go in with it.
2. **The Trace tab, [#656](https://github.com/Roasbeef/loom/issues/656).**
   Two steps. First the untimed list of the latest `code_mode` program's
   calls, drawn from what the page already receives. Then per-call timing: a
   `protocol-change/NNN.md` for per-call start and end fields on the wire,
   bars in the tab, and optionally in the terminal.
3. **Remote access, [#654](https://github.com/Roasbeef/loom/issues/654).**
   [protocol-change/052](../protocol-change/052-web-view-remote-origin.md) is
   still a proposal, and the owner accepts or amends it before work starts. It
   means the page behind a TLS reverse proxy on the daemon's host for remote
   teammates, with a `Host` allowlist and no TLS code in `loomd`. It does not
   mean TLS in the daemon. Before it, measure the server-side re-render and
   diff cost per batch per viewer, and add the mailbox and patch-rate
   metrics the step extraction deferred to 052.
4. **Terminal state.** Land or close PR #583 (#399, #524).
5. **Wake etui on SIGWINCH** before raising the terminal's one-second idle
   ceiling. Exit: resize repaints without waiting for a poll, and a quiet
   terminal wakes only for work its lane or runtime owes.
6. **Measure actual provider token counts** and representative workloads
   before choosing tool search. Exit: measured prompt size, cache-prefix
   behavior and discovery cost, rather than the character estimate in
   [the design note](design-notes/tool-search-and-code-mode.md).

Known small follow-ups, none of which has its own issue:

- The composer notice above.
- A settled strand's row shows no end time, because the roster carries none.
  It needs a wire field, so a `protocol-change/NNN.md`.
- `loom access` takes its global flags before the subcommand.

## How work lands here

[docs/execution.md](execution.md) is the method: briefing, verification and
landing. In practice a batch of ready pull requests lands like this.

1. Make a queue branch, `queue/<name>`, from `main` and merge each pull
   request into it with `--no-ff`.
2. Run `make check-affected BASE=origin/main` and `make doc-check` on it,
   and check the page by hand in a browser against a drive daemon for any
   web change.
3. Push the queue branch and run one Linux signoff on it (`make
   signoff-remote`, about 13 minutes, one at a time, since concurrent runs
   share caches and produce false reds). A flake never blocks a merge: rerun,
   and give the flake its own fix pull request.
4. On green, open a queue pull request and merge it with `gh pr merge
   --admin`, because `main` rejects direct pushes. The constituent pull
   requests close as merged.

## Rulings to preserve

**Hosts do not poll for traffic.** A frame is reduced when it arrives: the
terminal's socket wakes its loop, and the web view's selector is the wake.
A host sleeps until `session_channel.next_due` and wakes on its own only
for what no wake announces. A fixed-cadence tick added to find traffic is
a review finding; a new source of messages that wakes nothing belongs in
`tick.wakes_itself` or gets a wake of its own.

**Session logic has one home.** What a frame means, when to catch up,
which lines a capture becomes and what an operator's input becomes on the
wire are `session_view`'s. A host owns its runtime and its view and
nothing else; session logic found in `web_view`, or duplicated in `tui`, is
a review finding. The page compares what each projection was built from, and
not `render_revision`, which moves for stream fragments and tool tails the
page does not draw (question 3 of the step-extraction note).

**Commands, not a shared key vocabulary** (owner, 2026-09-27). Keys stay in
the terminal, and both hosts hand the session the same closed
`msg.Command`. The web view maps its DOM events to it. ADR-014's second
blocker is amended accordingly.

**Daemon control, reconnect and the attachment jobs stay terminal-only**
(owner, 2026-09-27). A session sidebar mounts one component per session.

**The host keeps the loop over a drain's updates** (owner, 2026-09-28,
question 11). One update is the shared unit, and the recorded facts are
applied between updates.

**`step.update` is the entry for a host with no surfaces of its own** (owner,
2026-09-28, question 12, option (a)). The terminal keeps calling the shared
units, and a `session_view` test holds the two orders together. A change to
the terminal's tick order changes `update` and `step_test` too.

**The page runs every session command but adding a directory** (owner,
2026-09-29). `/add-dir` and `/add-write-dir` name a path on the daemon's
host and are refused on the page. A `command.Surface` command is refused
with a notice and never sent as a prompt.

**Effects are values and name their handles.** A step or a lane returns
what it decided; the host performs it, in decision order, against the
handle each effect names, never a handle looked up at perform time. The
web host performs the step's effects inside one `effect.from`, because
Lustre's `effect.batch` does not order them.

**The buffer bound is the host's.** Admission never drops a frame for
capacity, a host reads no more from a mailbox than a buffer has room for,
and admission files a frame only into the inbox whose subject it names, so
nothing from a replaced inbox reaches a reducer after an adoption.
Event-driven delivery changes when a host reduces, not these.

**A page is never more than an operator.** The role is the smallest of the
membership, the ceiling the link was minted with, and Operator. A page
never offers allow for the session, its approval cards sit above the
composer and are drawn from the record alone, nothing from the session
becomes markup, and the page nonce is never rendered into a document.

**Authority and communication are separate.** A peer link grants neither
child custody nor filesystem access. A peer receipt proves durable
admission, not that a model read the message. `busy_only` never wakes an
idle target; `may_wake` is a separate owner choice.

**A virtual read is a capability call.** `cap://` and `job://` are served
through the capability router, not mounted, and prompt guidance must match
the installed router and generated prelude.

**053 phase 4 waits for use** (owner, 2026-09-30). The admin page is built
only after the owner has used the terminal's `/access` overlay and says it
leaves a need.

**The page invite keeps both buttons** (owner, 2026-09-30). The observer and
the operator button both stay. The risk is accepted: a stolen owner page can
mint an operator invitation, bounded by three an hour for the credential, and
each invitation is a durable membership the owner can revoke.

**The operator page frame is 12 MiB, and `PageOperator` reserves 64 MiB**
(owner, 2026-09-30). The reservation covers the five copies of a frame the
submit's decode chain holds at once. A change to the frame limit changes the
reservation with it.

**Operator surfaces do not open saved sessions.** The CLI and the terminal
use the membership- and epoch-checked control protocol, and a
listing is never permission to activate a saved target.

## Deliberately open and carried forward

- **The page runs reads for surfaces it does not draw.** After a first
  capture it reads notes, context, advisor nudges and the goal, four round
  trips that hold the lane's command slot, and it reads the context again
  when an operation ends. The owner chose this over choosing which reads a
  host has a surface for. Revisit it if a per-page cost is measured.
- **The page loads no skills catalogue**, so a skill's slash command is
  refused as unknown there. Reading the catalogue is a follow-up.
- **The 053 admin page** (phase 4) is built only on the owner's confirmation,
  after use of the `/access` overlay.
- **The composer target menu** of the design note's section 3.3 is not built
  and has no owner ruling.
- **`conformance` declares `prompt` as a dependency and imports nothing
  from it.** Remove it, with the manifest updates that follow.
- The test fixture `pushed.attached()` is a replaying peer with a lane, a
  state the shipped client never reaches.

## Background watcher lifetime work

The background-watch-lifecycle branch is based on `01f14ef8f` after #667.
Protocol-change/058 adds an explicitly approved session lifetime for Bash and
code-mode background jobs, retaining finite defaults. It also fixes cancellation
grace measured from a stale timestamp before a quiet receive. The installed
`loom-herdr-update` session still runs its earlier release and finite jobs;
this branch does not upgrade that daemon or replay its watcher commands.
Local validation and independent review are recorded in the PR, with hosted
signoff required before landing.

## Earlier collaboration follow-ups

The collaboration stack landed through #510 at `645b8faf`; protocols 048
and 049 own its wire. [Async collaboration](architecture/async-collaboration.md)
and [messaging](architecture/messaging.md) explain it. Saved-session
outboxes, cross-machine transport, durable actor recovery, and the
outgoing-link limit race remain carried-forward follow-ups. The coordinator
example for following up with already launched children also remains open.
Protocol 054 still needs its previously requested live quiet-web drive to
confirm attachment reaches `Pushing` and rendering follows the pushed rate.
This edition did not re-test the reachability of these items or close them.

## Held-input and goal reading guide follow-up

The #583 follow-up is baselined to merged `8b3455493`. The
[delivery guide](architecture/delivery.md#reading-the-held-input-and-goal-paths-in-gleam)
now traces durable goal publication, held queue projection, read debt and
request ownership through the shared lane and both hosts. Its web goal row
corrects the older delivery claim that the page renders no goal panel.
The carried-forward `session_view/model` "will bind" item was already fixed
in that merged baseline; the module says the web view binds the handles now.

The follow-up changes comments, declaration order and documentation only.
An independent review and a comparison of all 996 production declarations
across the 14 changed modules found no executable or public-interface change.
Focused session-view, events and terminal suites passed, as did the client
build, format, lint, prelude and documentation checks. The follow-up PR records
the final affected gate and Linux signoff against its published head. Existing
behavior tests remain the evidence for the underlying #583 invariants; a
reading guide creates no new runtime guarantee. All unrelated next-work
priorities and open boundaries above remain as recorded in this edition.

## Earlier edition's validation boundary

The earlier edition changed documents only. `make doc-check` was its proof:
coverage, the `AGENTS.md` mirrors and every file:line citation in the
documents it checks. No code was built or run for it. The description of the
page was checked by reading the source at `998be7a64` (the `web_client`
element modules and their rules, `web_view/view/*`, `component.gleam`,
`ending.gleam`) and the tracker, not by driving a browser. Where the tracker
and the code disagreed, the code was taken.

# Current handoff

## First-session startup — October 17

Startup improvements must not buy lower latency with increased CPU or memory.
The final source retains one TOML parse per configuration load, three narrow
Settings callback captures, and OTP 29 dependency-aware concurrent application
startup. File rereads, secret rotation, validation order, restart custody,
native identity, rollback and UTF-8 diagnostics remain intact. No heap, cache
or CPU allowance was increased. No operator daemon was installed or restarted.

The TUI async overlap and 25-module domain-loading batch were removed after
fixed-capacity resource measurements. Async warm-client peak RSS increased by
328 KiB in smoke and 1,260 KiB with 32 models; cold smoke CPU increased 153 ms
(paired medians). The batch-enabled release raised smoke daemon HWM by
1,968 KiB in all seven pairs; a four-way factor comparison isolated consistent post-domain memory
costs in both serial and concurrent application startup. The batch binding,
checker and tests are gone. TUI source is restored, with all 827 released
client BEAMs matching the original pre-optimization baseline.

The real stock server rebuilt at `72c6263` was compared to that original
baseline using seven alternating pairs per fixture, under the same one-CPU
quota and affinity. Paired median cgroup CPU through the real composer fell
280 ms in smoke and 89 ms with 32 models. Daemon HWM fell 1,748/2,664 KiB in
all seven pairs in each fixture; combined sampled RSS fell 1,428/3,720 KiB.
Cold launch to composer improved by paired medians 215/86 ms, but only four
and five of seven pairs were faster respectively. These measurements include
all retained changes and do not isolate an application-concurrency saving.

Absolute resource neutrality is not established. CPU rose in three of seven
pairs per fixture, smoke combined sampled RSS rose in one, and smoke client
composer HWM/RSS rose by a paired median 16 KiB (five of seven higher).
Sequential RSS samples and component HWMs are not simultaneous aggregate peak
memory. No arbitrary tolerance is assumed. Fixtures use warm page cache,
synthetic unreachable providers, saved-session reopening and explicit
best-effort enforcement; they are not deployment/full-enforcement or
interactive picker-to-New results.

The [startup note](design-notes/first-session-startup.md) documents the final
comparison and explicitly labels earlier batch/async latency results as
historical. The [resource archive](review/startup-resources-2026-10-17.json)
retains all 148 trials, warmups, driver hashes, summaries and artifact audits.
All final trials proved durable input admission, normal shutdown and affinity;
all 64 final seed/replacement native identities retired. Independent source,
artifact and data review supports the reduced scope with those stated limits.

Final local validation passed the full TUI gate (1,447 tests), 16 real-control
client tests, 134 catalogue tests, six configuration-document tests, seven
domain tests, format/build/lint, stock release build, two native launcher
checks and release smoke. The bundled offline toolchain compile was not
verified because this kernel refuses its unprivileged network namespace.
Earlier broad local client runs hit the existing bwrap jailed-listing and
satellite-readiness fixtures; there is no passing full local client claim.
Reviewed head `32e881e` passed all 18 executed hosted checks, including Linux
and macOS gates and the full client job (two release-image jobs were skipped).
The owner requested removal of one-off experiment scripts and an administrator
merge without waiting for a new hosted run of this cleanup. The three archived
Python diagnostics, parser benchmark and disposable launcher probe are removed;
results and hashes remain, with historical script locations documented in the
note. Regression tests for the retained behavior remain. This cleanup changes
no production code.

The separate [request gzip experiment PR](https://github.com/Roasbeef/loom/pull/1000)
contains real TUI/browser experiments and native transport measurements;
it changes no production request-encoding default.

## Distributed runtime — October 17

The distributed runtime is complete through remote subagents phase 4
(protocol-change/084, with 089 and 090) and the operator surface of
protocol-change/085, on main `3c6f53c4c` (PR #1006). The runtime itself is #923.
The Khepri session directory (083, `docs/architecture/directory.md`) and the
membership ledger (086) are merged. `protocol.version` of the executor host is 3.

What shipped, by document, so that the next reader does not look for a plan:

- **085, the operator surface:** node reports, `deployment.status`,
  `sessions.elsewhere`, the Admin page's machines list and read-only machine
  pages, Move with candidates, Abandon, and the executor and pool cards in the web
  form (#957, #995, #996, #999). The status addendum at the end of
  `protocol-change/085-distributed-admin-surface.md` lists what was deferred.
- **084, remote subagents:** phase 1 (#960, #969); `Release` and retention (#998),
  metering (#999), messaging with the link keeper, approvals on the
  laptop (089), observation (090) and depth across machines (#1006).
- **Not built, by design:** failover and moving a session between executors
  (`docs/architecture/directory.md`, "What failover would add").

Open follow-ups, none of which blocks a release:

1. **Shared-history `Begin` bound.** The 5 s bound on `Begin` in the shared
   history path equals SQLite's `busy_timeout`, and this is a suspected cause of
   the flake in the restart drill. Separate the two values so that the bound
   outlasts the lock wait. Reproduce with the restart drill, not with synthetic CPU
   load.
2. **Three decoders for `deployment.status`.** `tui/deployment_view`,
   `web_view/machines` and `ledger_control.member_view` each decode it. One total
   decoder in a package all three depend on replaces them.
3. **`scripts/gen-sql.sh` output.** The dependency-fetch output of the script
   pollutes the load order of the generated modules. Silence or separate the fetch
   step.
4. **One link keeper per daemon start.** `daemon/main.start_link_keepers` starts a
   keeper for each `[orchestrators.<name>]` row that exists at start. An
   orchestrator enrolled afterwards has none until the next start, a vote for it
   is dropped, and its calls dial on demand
   (`protocol-change/084`, the addendum on messaging). Start a keeper when the
   ledger roster gains an orchestrator.
5. **Forget for session-scope grants on the laptop.** `protocol-change/089`
   documents `Resolve(.., Forget(grant))` and the box admits it, but no command or
   card on the laptop sends it, because the laptop does not list what the box
   remembers. The box owner's list (073) is the only way to withdraw one today.
6. **The 085 topology SVG.** Optional. The machines list and the terminal's text
   topology cover the need; the SVG of section 8 of the design note has no owner.
7. **`RemoteChildrenChanged` reads stubs in the hub's turn.** The bus-hint arm of
   the gateway (`client/gateway.gleam`, `BusHint` for `bus.RemoteChildrenChanged`)
   reads the stubs and builds the push inside the gateway actor's turn, so the
   turn is as long as the read. Move the read out of the turn.

## Previous handoff

Baselined October 16, 2026 against main `1536934a4` and the rebased `/btw`
branch for PR #981. The earlier instruction to merge `207c6571b` is obsolete:
the owner requested a rebase and fresh UI screenshots after main advanced.
`207c6571b` passed hosted CI run 38558170965 and signed Gilgamesh signoff.
The first October 16 rebase, `bbeb4b61c`, also passed all 18 executed CI jobs
(run 38935120272), both actual macOS advisory shards, and strict Gilgamesh
signoff in 1809 seconds (driver 1815 seconds). Those results do not validate
the next rebase: #990 merged just as the first rebase became green.

## Property and model-based testing

Branch `test/qcheck-machine-pilot` (from main `8f66fc6`) moved every
randomized test onto shared tooling. The rules are in `docs/gleam-style.md`,
"Property and model-based tests"; read them before writing a test that draws
anything at random.

- **What landed.** Every hand-rolled generator (SplitMix copies, linear
  congruential generators, `draw(seed, n)`) is gone; tests draw from qcheck on
  fixed seeds. `packages/statem` is stateful model-based testing over qcheck:
  generated command sequences, shrinking by deleting chunks from anywhere,
  same-tag acceptance, crash rescue, shrink retries for scheduling-sensitive
  systems. It is in the portable subset and tested on both targets. Model tests
  now cover the TUI session channel, live tail and queue editor; the storage
  exec ledger, session store (memory against SQLite) and catalogue; the broker
  executor and leak census; the client membership ledger, pacing books, advisor
  guard and peer outbox; the LSP client's sync; the todo board and output tail;
  session_view's history window; session projection growth; and web_view
  paging. Lint gained R19 and R20 over test sources, `affected.py` became
  `lint/affected`, and the soak's chunking moved into the conformance suite.
- **Defects found.** `blocksummarybook.landed` counted a slot its own request
  had just freed (fixed, 38308d6); `claim_delegate` answered a raw foreign-key
  error instead of `Missing` (fixed, 9d70d19); the conformance shrinker could
  slide onto another check and accepted racy candidates (fixed). Two
  properties were too broad and were narrowed with citations (an aborted
  response's tool calls; the hashline empty-file rule).
- **Deliberately not ported.** The conformance simulation keeps its own integer
  seeds and schedule shrinker (`docs/architecture/simulation.md`). Pure
  one-shot properties and whole-sequence folds (`execution_test`,
  `goalloop_test`, `jobstate_test`) stay on plain qcheck.
- **Scripts.** The survey that decided which test scripts could become Gleam
  is summarized in the PR. `with_timeout.py`, `check.sh`, `test.sh`'s EUnit
  runner and the signoff family stay: each would need new custom FFI to spawn
  or signal OS processes.
- **Open.** A parallel (linearizability) layer for statem over weft is the
  natural next step for the broker and runtime actors; it needs processes, so
  it would be a BEAM-only sibling package. statem has no coverage-label
  feature; suites assert coverage with `statem.commands` census tests instead.
  The session channel's schedules are now drawn 0 to 80 events long where they
  were 20 to 80; the coverage census still holds, but a minimum length would
  restore the old event volume. In this container the client gate fails only
  jail and shipped-binary tests that also fail on the untouched base.

## Accepted side-query design

Protocol-change/087 specifies frozen effective dispatched context, bounded
follow-ups, explicit refresh and no tool execution in TUI and web. Settled
text-only answers may extend a base; streaming fragments and pending tool
exchanges never do. Histories remain private, ephemeral attachment state.
Side requests retain provider settings and the frozen Anthropic cache endpoint.
Live Anthropic cache savings remain unmeasured until credits are configured.

The review fixes retain capacity after lost drain proof, suppress expired side
poll deadlines while the command lane is busy, share TUI paint/scroll/copy
geometry, and wrap side text at the actual docked width. Three review rounds
and cold slice reviews approved the earlier implementation. See
[the triage](review/btw-2026-10-13-triage.md). UX follow-ups are #983; integrated
fallback-capture coverage is #984.

## Rebase boundaries

Current main includes per-strand throughput, catalogue completion, bounded
native-test concurrency, provider disconnect diagnostics and keepalives,
preparation reuse, process identity and UTF-8 TLS options encoding. Preserve
those paths. The web component conflict was additive: both completion choices
and the side-state accessor remain. Package docs retain both features.
The ordinary Linux deployment skip uses main's single declaration, with its
separate delegated enforcement test and empty skip allowance unchanged.

For the upstream performance and TLS investigations, consult main's
[previous handoff](https://github.com/Roasbeef/loom/blob/6430703a98c6371020c09aedb5b067e8c5c570aa/docs/next.md)
and the linked review reports. CPU, cumulative allocation, retained memory and
RSS are separate claims. This branch neither installs nor restarts the user's
daemon.

## Strand-notes integration

Main `d9553247f` adds #990's bounded read-only strand-notes browser. Both the
surface-custody equivalence test and the side-action refusal regression remain.
Web components retain notes adoption and side polling; package docs preserve
both boundaries. Production source merged without textual conflict. The generated
web assets are rebuilt from the combined source.

Fresh TUI/web captures from `bbeb4b61c` are posted in
[the PR comment](https://github.com/Roasbeef/loom/pull/981#issuecomment-6220628018),
outside Git history. Both UIs answered side questions during main streaming;
raw requests and the two main-only durable entries prove context and history
isolation. Repeat UI smoke checks after this notes integration.

## Queue-control integration

Main advanced through #980 to `1536934a4` while the notes-integrated head
finished validation. Retain both `remove_queued_input` and `btw` in auxiliary
command decoding, queue-removal authority and side-observer denial tests, and
both queue/notes custody and side-refusal regressions. The shared host cleanup
retains its current queue-aware rules; private side state remains separate.
Generated assets are rebuilt from the combined source.

At `2b42233a8`, strict Linux signoff passed all six lanes, release/update and
the strict skip census in 1799 seconds (driver 1804 seconds). Linux CI and the
second macOS advisory shard passed. The macOS E2E job hit the unchanged
code-mode cancellation fixture's 500 ms invocation deadline. Five exact local
attempts and the full local code-mode E2E gate (410 tests) passed, supporting a
suspected timing flake. No test was changed and no hosted retry was issued;
the run was cancelled as superseded when #980 created new conflicts.

[Refreshed captures](https://github.com/Roasbeef/loom/pull/981#issuecomment-6221718804)
show both real UIs and Notes beside the private web side answer on `2b42233a8`.
Both private requests retained main context and their question/answer text was
absent from durable entries. They are prior-head evidence for the next rebase.

## Verification and next steps

Three separate total decoders read `deployment.status` (`tui/deployment_view`,
`web_view/machines` and `ledger_control.member_view`); one in a pure package could
replace them.

Earlier personal E2E drove both real UIs during a continuing main stream,
proved frozen follow-ups and refresh through captured requests, checked private
attachment histories and main-only durable entries, and verified cancellation,
tool refusal, long-answer paging and OSC52 copying. Rebuild and repeat the UI
checks for this rebase; post screenshots as PR attachments, outside Git history.

Run affected package and static gates, hosted CI, and exact-head strict Linux
signoff through the confirmed `gilgamesh-signoff` alias. Its `obelisk` hostname
and separate account are intentional. The owner authorizes merge once all these
gates are green on the published head; prior-head green results never substitute.

## Memory as recall

[The memory page](architecture/memory.md) is the account of how it works and
[the decision record](design-notes/memory-recall.md) is the reason.

**What landed.** Memory is now recall, not a digest. `history_search` is the
memory tool: it takes `syntax` (`words` with prefix terms and `OR`, or `raw`),
`kind`, `before` and, for `read`, `around`, and every hit carries its kind and
date. `remember` writes typed notes (`title`, `description`, `kind`, `note`),
indexes them under kind `note`, and rebuilds the 1 KiB `loom-memory.notes`
index that each run carries by default (`[memory] inject = "notes"`), and a
session open rebuilds that index from the store without taking the lease. The
digest and the distillation pass that produced it were removed; `distill =
"off"` still parses and does nothing, and an old store's leftover rows and
digest file are not read or deleted. `propose` queues a standing rule and
`loom-rules.md` changes only when the daemon's owner approves it
(protocol-change/086); the prompt carries the file last, in an
`origin=approved-proposal` fence, and only new sessions read it. The
transcript draws a search as a step with its hits, and the owner reviews
proposals with `Alt+p` in the terminal or in the Session pane on the web page.

**Left open on purpose.**

- A proposal kind that edits configuration, and one that targets the global
  `AGENTS.md`. Both stay out until there is an edit door for them.
- Owner-only admission of the web proposals pane at the operator socket, by
  teaching `ui_socket.owner_accepts` the path. Today the socket admits it like
  remembered permissions, and the daemon is the gate.
- Notes search on the standalone host. Only the daemon adds the memory store
  to the history owner's sources.
- A logger with session context for `memory.search_called`. `serve` calls
  `history.seam` and `history.seam_for`, which log through the Erlang logger,
  where `seam_with_logger` and `seam_for_with_logger` already take one.
- A guard for the 512-source bound. The memory store is one source in the
  list, so a domain with 512 saved sessions and a store refuses shared history.

The proposal queue is the domain's, in `loom-memory.db`, and every write
holds the store's writer lease, so a review in any session shows every
proposal and two approvals cannot erase each other. A `propose` or a decision
that finds the lease held is answered busy and is not retried. The notes index
is rebuilt from the store when a session opens. The usage counter for notes is `note_hits` on
`memory.search_called`; `memory.proposal` records each proposal transition.

**The first number to watch.** Whether any of the owner's eight existing notes
is ever returned by a search. Read `note_hits` on `memory.search_called` over
the first two weeks; zero means the index and the search are not earning their
cost. The recall test's figures (6 of 30 paraphrase wordings found by exact
quoted words, 16 of 30 by prefix terms with `OR`) come from a synthetic corpus
and say nothing about real use.

## PR #955 rebase and focused review

PR #955 was rebased onto main `877e05f56270fada0392ad7b1f252462230ebfa3`
on October 16, 2026. The replay preserves remote-child drain and release,
held-input withdrawal, Notes, completion and private side queries. Side-query
accounting now calls `auxiliary.record_request`, and the lease-free register
reader uses main's decode cache for the duration of its connection. The Memory
overview is implemented in both hosts; the earlier open-item list incorrectly
left it pending.

The focused independent review found one P2 defect in
`memory.rebuild_notes_index`: its lease-free read could publish an old snapshot
after a concurrent `remember` had committed and published a newer index. The
fix takes the existing memory-store writer lease before reading and retains
it through sidecar publication. A held lease leaves the index alone and logs
an in-band refusal without failing session startup. Overview reads remain
lease-free. Regressions cover writer exclusion, preservation of newer notes,
absent-store behavior and cleanup after a publication failure.

The rebased client builds with warnings treated as errors. Storage (299 tests),
events (56), focused memory (71), proposals (53), side queries (6) and daemon
manager (50) suites pass.
Formatting, documentation, generated web assets, prelude and lint gates pass.
The original PR's Linux signoff predates this rebase. Full hosted CI, fresh
Linux signoff and live UI validation are still required before merge.

The follow-up fix passes 73 focused memory tests, including real server
startup while another memory writer holds the lease. The exclusion regression
fails against the original implementation and passes with the fix. A fresh
Astra review of `36a465c9e` against base `877e05f56` found no actionable
findings in the fix or the broader targeted recall/proposal review. Proposal
(53 tests) and daemon-manager (50 tests) regressions also pass on that source.
The review inspected the test evidence without independently rerunning it;
full hosted CI, Linux signoff and live UI validation remain pending.

Hosted run `39003421131` passed every Linux test job but its fan-in rejected
inherited enforcement skips for deployment-status scope and remote subagents.
The ordinary-runner census now declares those exact prerequisites. The
existing strict delegated deployment step covers both scope and up/down;
a new strict delegated subagent step executes the child lifecycle fixture
with an empty skip allowance and retains its log. No fixture assertion or
skip condition changed. The recorded Linux bucket logs pass the repaired
census, and a delegated subagent skip is still rejected.

Strict signoff on `9810ad1db` passed all six lanes, release/update and the
skip census in 1882 seconds (container driver 1887 seconds). Its client log
shows both deployment scenarios and the remote-subagent fixture executed.
Those results are prior-head evidence: this CI integration must receive
fresh hosted CI and Linux signoff before merge.

The next hosted client run and strict Linux signoff on `e962d3e21` failed
one inherited delegate-retention assertion: the test accepted `Stopping`
as drained because it waited only for non-residency. The manager correctly
retains that slot until its normal custody witness exits, so an immediate
second sweep can delete zero rows. The regression now waits for `Saved`,
which proves that the slot has been removed, before demanding one deletion.
The deletion-count and catalogue assertions and the existing two-second
observation bound remain unchanged. All 23 delegate-host tests and five
focused runs pass locally. Fresh validation is required on this test repair.

# Current handoff

Baselined October 12, 2026 against main `b197c9566` (through PR #964),
with the tool-latency work rebased for PR #949. The original measurements use
`4417fdb6a073865660bf029495a9ecf08bc9e315` and the candidates named in their
reports. Work is on `perf/tool-latency` in the isolated `5086/loom` worktree.
PR #949 is out of draft. The installed daemon has not been changed.

The prior integrated head `f918ae5df` passed full local `make check`, hosted CI
and Linux signoff. Main then advanced through the program-card web changes and
Khepri directory work. Rebasing replayed the individual feature commits; the
conflicts were handoff snapshots and the generated stylesheet's source digest.
`make gen-client` regenerated the assets. The prior green gates do not attest to the final rebased head.
The automatic merge timer has been removed at the owner's request.

## Final merge validation boundary

The first rebase, `7515d0d82`, passed full local `make check` with exit 0,
including 3,931 client, 1,331 TUI and 98 conformance tests. Its Linux signoff
failed an unchanged LSP fixture: a late concurrent caller correctly received
`Warm`, while the test assumed all spawned callers reached the manager during
startup. Five focused baseline runs passed. The corrected fixture holds
transport startup until a test-only OTP state snapshot proves all three callers
are parked, preserving every original assertion. It passed 100 parallel
repetitions and all 52 manager tests, and independent review found no issue.

Hosted macOS end-to-end CI exhausted its 20-minute job budget during progressing
code-mode tests, after bootstrap and conformance steps passed. The job budget
is now 30 minutes; individual test deadlines are unchanged. The final rebase
also brings in main's distributed membership-ledger and remote-subagent work.
The owner explicitly authorized force merge without another full hosted/Linux
cycle. Final build, focused test and documentation results are recorded on
PR #949; do not treat this authorization as a fresh Linux signoff. The recurring
automation was deleted, and the installed daemon remains unchanged.

## What moved

Distributed runtime PR #923 merged at the earlier measurement baseline.
PR #950 subsequently brought peer mail and remote code-mode/MCP support from
PRs #937 and #938 onto main. Integration conflicts only in this handoff; the
admission, indexed scan and completion-witness source changes have no overlaps.
The execution boundary remains
`runtime/effects.ToolSurface.run`: the orchestrator owns sessions, SQLite,
providers and approvals; the executor owns the workspace plane, including its
broker, jailed commands, jobs, LSP and code mode. The optimizations use those
shared boundaries rather than a per-command remote broker interface.

Three benchmark layers now separate the costs:

- `make bench-tool-latency` measures real broker/helper/jail execution.
  The [October 9 report](review/tool-latency-2026-10-09.md) records warm
  medians of 18 to 23 ms on macOS.
- `make bench-tool-roundtrip` measures the scripted-provider-to-provider
  interval through shipped local and TLS distributed daemons. The
  [completion report](review/tool-completion-latency-2026-10-11.md) records
  tiny-call medians of 95 to 51 ms locally and 99 to 52 ms distributed after
  replacing positive polling waits with a completion witness.
- `LOOM_BENCH_TOOLS_WORKLOAD=history make bench-tool-roundtrip` fixes a
  65,550-byte prompt. The [storage report](review/tool-storage-latency-2026-10-11.md)
  records additional median reductions from 62 to 47–51 ms locally and 70 to
  50–51 ms distributed. Its standalone SQLite scan falls from 8.166 to
  0.100 ms over exactly 128 messages containing 1 MiB of text.

The previous edition left repeated reads and transcript scans as an open lead
from the [bounded call trace](review/tool-completion-calls-2026-10-11.txt).
That lead now has two measured changes. Image-capable model admission checks
model capability before reading operation or transcript state. SQLite pushes
kind filtering into the existing covering index and caps fetches at the
remaining limit when custom-type filtering cannot reject rows. It still
resolves stops and cursor windows on the unfiltered branch first.

The latest live [Pickglass resource profile](review/loom-live-resource-profile-2026-10-11.md)
observed the installed main daemon during active sessions. It identified
repeated failed-tool refusal trimming in web rendering. A failed body now
uses one memo leaf over its words and rows; its rows are drawn directly.
The real Lustre cache fixture falls from four trim calls to zero on unchanged
patches. Empty bodies remain empty; independent words and row changes
invalidate the memo. The adjacent profile JSON records sanitized counters.

The JSON lead now has a controlled [decoder comparison](review/json-decoding-allocation-2026-10-11.md).
The parser dispatches empty runs before slicing and validates nonempty string
runs directly, avoiding an intermediate Result pair and cursor update. Three
alternating fresh-VM comparisons reduce measured heap allocation by 14.0% for
128 transcript-shaped objects, 15.3% for escaped text and 53.0% for dense
adjacent escapes. Full values and corruption reports match for 882 differential
inputs. Final concatenation, output ownership and numeric parsing are unchanged.

The backing-binary follow-up has a [targeted provider comparison](review/provider-identity-retention-2026-10-11.md).
The OpenAI-compatible accumulator now materializes selected `id` and `model`
values of 65–256 bytes only when their event document is at least eight times
larger. Sixteen synthetic accumulators retaining two 96-byte identity fields
hold 3,072 binary payload bytes instead of 16,781,495. Generic JSON decoding
keeps its existing ownership: a rejected global copy policy slowed a retained
2,048-field fixture by 21% at 96 bytes. Full-event timing is noisy; primitive
materialization costs about 0.09 µs for 96 bytes. These are isolated ownership
and overhead measurements, with no installed-daemon memory reduction claim.

## Rulings

Production positive waits use `jobseam.production` and `jobs.await_completion`.
Each watched live job lazily owns one linked weft actor. Terminal processing
attempts the fact write before stopping that witness. Callers monitor it and
reread authoritative state on DOWN or timeout. There are no retained waiter
subjects. Local and distributed executors select the same constructor.
Injected-clock polling remains available to simulations.

A dead witness is never a successful result. The existing commit path updates
memory after a failed persistence attempt; the wake preserves write-attempt
ordering, not successful durability during owner failure. No tool schema,
frozen interface, distributed protocol, durable job format or jail enforcement
was changed.

Kind metadata is derived from the immutable entry at insertion. Matching
malformed payloads still fail total decoding; payloads excluded by kind are no
longer fetched or validated. Custom-type filtering stays in pure refinement.
The existing `ix_be_type` supplies both traversal orders without a new index,
migration or temporary sort.

## Verification and remaining work

The completion change passed 57 focused job tests, including a direct witness
monitor held across blocked terminal persistence. The test fails when witness
shutdown is moved before the write. Both real shipped placements passed.

The transcript changes passed focused storage, wiring and vision runs. Tests
check zero reads for image-capable admission, failure on selected malformed
payloads, stop-before-filter semantics, sparse pagination and exact traversal
around the 256-row boundary. Independent review found no remaining actionable
defect. A benchmark count observation was corrected, and both scan timings
were rerun on the exact 128-message fixture.

The full pre-integration `make check` passed with exit 0: client 3,749, TUI
1,331 and conformance 98, followed by Go sandbox tests, house lint and the
configuration-key self-test. The parallel Linux signoff on an older head found
two TUI fixtures sharing a credential path. Their three calls now own distinct
paths; the full 14-test module passed 100 parallel runs. The exact failing Linux
interleaving remains inferred, since twenty local baseline pair runs passed.

The full integrated `LOOM_TEST_PARALLEL=8 make check` also passed with exit 0:
storage 271, client 3,835, TUI 1,331 and conformance 98, plus all remaining
packages and static gates. Three subsequent shipped history runs passed, but
their full-round medians varied substantially (local 56 / 57 / 65 ms and TLS
55 / 59 / 74 ms, candidate / read-baseline / candidate). A following host
snapshot showed load around 19 with unrelated compilers and VMs consuming CPU.
The earlier 18–29% full-path reductions are observations; an isolated host is
needed to establish a repeatable integrated speedup. All samples are retained
in the storage report.

The live-profile follow-up passed all six preprocessing regressions and the
final `make check-web_view` (956 tests). Astra reviewed the actual drawing
callback, memo dependencies and empty-body shape. `make doc-check` passed
with 198 existing warnings and zero errors. The follow-up full
`LOOM_TEST_PARALLEL=8 make check` also passed with exit 0, including client
3,835, TUI 1,331, conformance 98, Go tests and zero house-lint errors. The
final web-only check includes the empty-body regression added during that
full run.

The JSON decoder follow-up passed the full local
`LOOM_TEST_PARALLEL=8 make check` with exit 0, including 163 core, 3,835 client,
1,331 TUI and 98 conformance tests, Go sandbox tests and zero house-lint errors.
Documentation checks passed with the same 198 warnings. Astra reviewed parser
correctness and the inline simplification; Sol 6.1 checked benchmark arithmetic
and evidence. Both found no remaining actionable issue. The optional JavaScript
comparison still has the same pre-existing non-finite-number corpus failure
and 25 build warnings on both sides; both new regressions pass.

The targeted provider retention follow-up passed the full local
`LOOM_TEST_PARALLEL=8 make check` with exit 0: core 163, provider 301, client
3,835, TUI 1,331, conformance 98, Go sandbox tests and zero house-lint errors.
Its ownership assertion fails against the old provider at 65 bytes; the final
candidate passes boundary and small-event cases. Both independent production
and evidence reviews found no actionable issue. Documentation checks pass with
198 existing warnings. The prior `4c2c0a982` head now has green hosted CI and
Linux signoff; these do not validate the newer provider source.

Exact-head hosted/Linux gates are separate from the local results. Current status
is on PR #949 and under `build/signoff/`; do not infer green from an earlier
candidate or this handoff. The full `make check` runs outside the nested macOS
sandbox so jailed conformance cases can create their capability sockets.
After pushing, use the prescribed
`LOOM_SIGNOFF_HOST=gilgamesh-signoff make signoff-remote` for the current SHA.

All latency results are from one Mac with loopback TLS, with first calls
separate from warm samples. They are not production SLOs. Repeat on Linux and
across physical hosts, then measure contention, growing transcripts, code-mode
compilation and provider inference separately. Attribute further costs on one
clock before adding storage or transport machinery. Keep profiling separate
from timing comparisons and capability sockets outside `/tmp`.

Read [distributed architecture](architecture/distributed.md),
[the setup guide](distributed-setup.md) and
[protocol-change/078](../protocol-change/078-distributed-runtime.md) for the
shipped system. PR #950 adds remote background code mode and executor-placed MCP servers. This
task did not re-audit the remaining reattachment and session movement limits;
consult current code before treating historical notes as a current issue list.

## Next measurements

The bounded live allocation probe counted 146.7 MB in 5.119 seconds over its
selected functions and processes. The decoder follow-up measures only synthetic
parser inputs; it cannot scale that live total or establish retained-memory
savings. A generic 96-byte selected output still references the same roughly 1 MiB
input backing binary. The targeted provider identity policy detaches only its
measured owner boundary; study other selected-field lifetimes before expanding
that policy. Typical identities of at most 64 bytes already detach on OTP 29,
so the measured large-event fixture does not establish real workload prevalence.

Repeat the integrated local/TLS latency comparison on an isolated host. Only
compare live resource profiles after an authorized deployment under a matched
workload. The installed daemon remains unchanged, and no live CPU or memory
reduction is claimed for this candidate.

## Inherited main handoff

The following is the main handoff at `b197c9566`, retained for its design
rulings, evidence and open work. Its earlier branch-status statements are
historical; the corresponding work is in the base above.

This edition covers the distributed runtime (issue #697) on
`distributed/simplify`, rebuilt from `main` at `7091d5a42` after PR #819 was
archived. An orchestrator daemon keeps a session's runtime, SQLite store and
approvals. An executor daemon of the same release holds the checkout and runs
the session's workspace tool calls. The two talk over TLS Erlang distribution
with pinned leaf certificates.

The branch is published as
[PR #923](https://github.com/Roasbeef/loom/pull/923); merging it is the owner's
call. Every claim below was verified on the code candidate
`3318250e0` (`3318250e0b32fd9f470c611d7e2022935f73f8e9`, 195 commits over
`7091d5a42`). The next commit, `88a70dd34`, changes one shipped test to wait for
a file rename it raced on Linux, and the commit after it changes only this file;
no source file differs from `3318250e0`. After that, `7628912ba` changes
`client/distribution` so the daemon starts `epmd` when none answers, and
`6c945a8c2` documents it (see "Rulings already made"). The gated signoff is
green on `6c945a8c2`, and `main` was then merged into the branch as
`3a541c1d4`. The commits up to `61429be82` add the architecture page and fix
the Compose quick start; the cross-host run was repeated on `61429be82`. A
second merge of `main` followed (below), with one semantic fix: the executor's
code-mode seed ladder now verifies the workspace seed as a local daemon's does.

The previous edition on `main` covered the compile and export work of
[PR #917](https://github.com/Roasbeef/loom/pull/917); its measurements are in
[the compile-time report](review/compile-hill-climb-2026-10-07.md).

Read [the design note](design-notes/distributed-runtime.md) for the design,
[protocol-change/078](../protocol-change/078-distributed-runtime.md) and its
addenda for the wire and the rules, and [the setup guide](distributed-setup.md)
for running it. `packages/client/CLAUDE.md` has one section per phase, from
"Trusted distribution membership" to "Moving a session between orchestrators".

## Merged from main

A second merge of `main` (after `3a541c1d4`) brought in four PRs, each
described in its own record. None changes the distributed runtime's rulings
below; the two code conflicts were in `client/serve.gleam` (main's
`usable_seed` beside this branch's move of `mixed_entropy` into
`workspace_plane`) and the imports of `ui_route_test`.

- [PR #925](https://github.com/Roasbeef/loom/pull/925): terminal large-result
  wrapping by a linear cursor over code rows. Measurements are in
  [the wrapping report](review/tui-large-result-wrap-2026-10-08.md).
- [PR #926](https://github.com/Roasbeef/loom/pull/926): the web Link form hides
  sessions that are already linked.
- [PR #927](https://github.com/Roasbeef/loom/pull/927): code-mode and LSP
  readiness. Automatic code-mode selection admits a workspace seed only after
  `seed.verify` accepts it, and the LSP diagnostics scope is recorded in
  `protocol-change/078-lsp-diagnostics-scope.md`.
- [PR #928](https://github.com/Roasbeef/loom/pull/928): paged and downloadable
  full tool results in the browser, keyed by immutable result records
  ([protocol-change/079](../protocol-change/079-browser-result-records.md),
  [the browser report](review/browser-large-results-2026-10-08.md)). Paging
  reads one storage fragment through `serve.Resident.result_reader`, and a
  download reads a complete bounded record under one deadline. Search in the
  viewer applies to one page, and byte windows can split JSON syntax or lines.
  Output summarization and whole-result browser search are not done.

A third merge of `main` (after `e1dc3a77f`) brought in the web fixes queue
[PR #933](https://github.com/Roasbeef/loom/pull/933), which pins a session's main
model at creation
([protocol-change/080](../protocol-change/080-session-model-choice.md)). It
added catalogue version 10 (`catalogue_models`), so this branch's three
migrations moved to 11 (executors), 12 (pools) and 13 (moves); main's version 10
shipped first and keeps its number. `Registration` and `manager.Creation` now
carry `model` beside `executor` and `pool`, the control command's `sessions.create`
decodes all three, and `session_move.Manifest` carries the model so a moved
session keeps the choice. The web form for a registered workspace draws no model
select, so a registered session created from the page takes the configuration's
roles. The proposal numbers collide: `078` is taken twice (this branch's
distributed runtime and main's LSP diagnostics scope) and the Khepri branch's
`080-khepri-session-ownership` shares `080` with main's model choice.

A fourth merge of `main` (through `89d252605`) brought in
[PR #935](https://github.com/Roasbeef/loom/pull/935), which moves a session's
blob store out of the workspace and into the daemon's state
(`serve.session_blob_root`, `client/blobs.adopt_legacy`, `fs_read` authorizing
the blob root). This branch had moved the workspace half into
`client/workspace_plane`, so the root became an input to the plane:
`WorkspaceSpec.blob_root`, with `Census.blob_root` carrying it back to an
owner whose workspace is elsewhere. A local session passes
`serve.session_blob_root` and adopts a legacy `.blobs` after `prepare`, as main
does. An executor keeps a remote session's blobs in `<state>/blobs/<session>`,
which a close does not remove, masks it from every jail with
`workspace_policy.protecting_blobs`, and does not adopt a legacy directory,
because no release ever wrote a registered session's store into a checkout.
Main added protocol-change `081` and `082` and no catalogue version, so the
numbers above still hold.

Main's handoff for that work also said: run `make gen-client` after changing
browser source, and judge every gate by its own exit code. A gate run on a
PR's original head does not attest to a later integration head, so each merge
checks its own current SHA.

## Where the tree is

| Phase | What exists |
| --- | --- |
| 1. One orchestrator, one executor | `ToolSurface.run` is the cut. The executor runs main's own workspace plane behind `remote/host`, with one SQLite ledger per executor (`storage/exec_ledger`, schema version 3). Scope rows carry an incarnation and an attach token; call rows are keyed by `(session, op, step, source_index)`. A session attaches once per open. A reconnect re-sends the same `Run`. Only a non-`noconnection` DOWN cancels. Recovery fences `ReplayNever` keys. An acknowledgement leaves a tombstone until the incarnation changes, so a key admitted once in an incarnation never starts again in it. Owner-bound code-mode capabilities answer over the owner port. `loom distribution` (`dist`) provisions and installs bundles, and `loomd executor release` is the operator override for a scope whose cleanup was never proven. |
| 2. Executor pools | `[pools.<name>]` with a trial order and declared requirements. The scope record names the executor before `Attach`. The next candidate is tried only on a failed connection or `CapacityExhausted` at first open. A census that contradicts the declaration closes the scope. |
| 3. Two orchestrators | Option C: `session_directory` is a Khepri-shaped interface backed by a 2 s parallel lookup over pinned peers, and each catalogue stays the source of truth. `not_owner` and `owner_unreachable` redirect the owner principal only, with no automatic follow. |
| 4. Peer mail between orchestrators | A sender outbox (`client/peers/outbox/<digest>`: pending, admitted or refused) drained by a weft state machine; `PeerCommand` (Allow, Revoke, Deliver, SentReceipt, Roster) and `Describe` (the owner's catalogue, never opening the session) on the `loom_orchestrator` port; a typed `peer_mail.Failure` (`Refused`, `Unreachable`, `NotOpen`). A recipient its owner holds saved is queued and delivered once when opened, locally and across; the drainer backs off from 5 s to 5 min while that is all it waits for (the "peer mail reach" addendum in protocol-change/078). |
| 5. Controlled movement | `sessions.move` and `loom sessions move`. Authority is two catalogue CAS rows (v13 `catalogue_session_moves`), a write-ahead intent and the executor's token fence, over six steps with resume at boot. A committed activation is always answered `Accepted`. An imported session cannot be moved on or deleted until its origin has retired. |
| 6. Acceptance | Two independent Fable 5.1 reviews of the assembled system (remote core; directory, peer mail and movement), each with re-verification of its fixes; a P model of remote execution and a TLA+ model of a move, both gated; the evidence below. |

### Evidence

All rows are for `3318250e0` unless marked. Mac: Darwin arm64 (macOS 15.5).
Linux: the box described below.

| Gate | Host | Result |
| --- | --- | --- |
| `make check-gleam` (format, warning-free build, every package's tests and the lint package's own tests; the house-rule lint is `make lint`, below) | Mac | exit 0, 636 s. host 75, core 140, storage 256, session 65, machine 93, prompt 103, session_view 427, web_view 927, telemetry 34, runtime 190, provider 257, broker 401, executor 10, mcp 123, lsp 191, tools 680, cap 182, ext 37, codemode 381, events 47, client 3591, conformance 97, tui 1312, lint 240 |
| `make doc-check`, `make prelude-check` | Mac | exit 0, exit 0 |
| `make server-shipment`, `make sandbox` | Mac | exit 0, exit 0 |
| Ten shipped modules against `bin/loomd` (`daemon_shipped_remote`, `_codemode`, `_caps`, `_tools`, `_pool`, `_strand`, `_owner_loss`, `daemon_shipped_directory`, `_peer_mail`, `daemon_shipped_remote_move`) | Mac | every one exit 0, 0 SKIP lines |
| `make model-check` | Mac | exit 0. TLA+ `session-move`: 1179 states, 392 distinct, depth 20; four mutants each violate their invariant. P `terminal-attachment`: every case and probe. P `remote-execution`: every case and probe; seven mutants (token ignored, `noconnection` cancels, recovery without a fence, second run for a key, reply before commit, plane checked before ledger, ack deletes the row) each caught by its spec |
| `make selftest` | Linux | exit 0, 11 layers enforced (cgroup-v2 included), none skipped |
| `make check-gleam` | Linux | exit 0, 1698 s, the same per-package counts as the Mac row |
| `make e2e` | Linux | exit 0, 97 tests; two gopls tests skip because the box has no gopls |
| Ten shipped modules | Linux | every one exit 0 with 0 SKIP lines, except `daemon_shipped_remote_move_test`'s first run, which failed asserting the moved session's file was gone in the instant between the `moved` row and the rename. It passed when rerun alone, and on `88a70dd34` (the test waits for the rename) it passed three runs out of three |
| `make model-check` | Linux | not run: the box has no Java, TLA+ jar or P tool |
| Cross-host, both directions (Mac brains with box hands, and the reverse): file, `bash`, `fs_read` and `git` in the remote checkout and absent locally; stop then `Closed(AllRetired)`; reopen at incarnation 2; tunnel cut during a 75 s call, which ran once and was delivered after recovery | Mac and Linux | passed on `61429be82` (and earlier on `193dbd8db`), credentials from `loom distribution provision` and `install --home`. Each direction ran two cuts: a short one restored while the call was still running, and a long one restored 96 s after the cut, about 20 s after the executor finished the call. In both, the command started once and finished once, and the model received its real result after the reconnect (in the long cut, from the executor's terminal ledger row). Before each drive, the tunnelled `epmd` named the executor and `openssl s_client` showed the executor's own leaf |
| Shipped SIGKILL restart and partition drills (`daemon_shipped_remote_test`) | Mac | in the shipped row above |
| Gated signoff (`make signoff-remote`), fresh Linux container | Linux | green on `0e7be0b43`, the head after the second merge of `main`, and earlier on `6c945a8c2`. An earlier run in a fresh container, with no `epmd` running, found the missing `epmd` start that `7628912ba` fixes. Red runs in between found three things, all fixed with a test: an advisor goal that rested until the two-minute tick when pinned in the instant after a review ended (`ee6402c8b`, a product defect), the remote goal test stopping before the reviewer's last request (`7bceffb6e`), and the movers' tests checking the files between the `moved` row and the rename (`0e7be0b43`) |
| `make lint` (the house rules) | Mac | exit 0 on `0e7be0b43`, 0 errors |

## Rulings already made

**The cut.** The cut is `effects.ToolSurface.run`. Clearance and approvals stay on the
orchestrator. The executor never sees the conversation.

**One ledger, durable outcomes.** One SQLite file per executor, short transactions,
full sync and a digest over each stored outcome. A row is terminal before any reply.
An unknown call is never run again. A key answered from the ledger is answered before
any question about whether a plane exists.

**Phase 3 is option C** (owner, 2026-10-08). The directory is an interface, not a
store. Creation happens on the connected orchestrator, and ids are UUIDv7, so there is
no register step.

**Phase 5 authority is two catalogue rows, not a third store.** The owner's wording was
"an authoritative store behind the directory". The adopted design has no third party:
the source's `moving`/`moved` row and the receiver's `imported` row are ordered by a
write-ahead intent, and the executor's incarnation fence is a second guard. Only an
answer abandons a move; silence stalls. This difference was flagged to the owner.

**Unproven cleanup is released by hand.** A scope whose children could not be proven
gone gets no automatic successor. `loomd executor release` (daemon stopped) records the
override in the ledger's `scope_release` table, and the next open reopens at the next
incarnation.

**The daemon starts `epmd`.** The daemon VM boots without a node name and starts
distribution with `net_kernel:start/2`, and that dynamic start never launches
`epmd`, unlike `erl -name` at boot. On a machine where nothing had started one,
the node failed to register. `distribution.start` now asks the loopback `epmd`
first and, when none answers, runs the release's `epmd -daemon` (or the one on
`PATH`) and waits up to three seconds; `-start_epmd false` turns this off. The
signoff caught the defect in a fresh container (`7628912ba`, documented in
`6c945a8c2`).

**Formal models.** `make model-check` runs TLC on `session-move` and P on
`terminal-attachment` and `remote-execution`, with probes and mutants. No directory
model was written, because the directory holds no state of its own.

**Trust.** An executor is a trusted Erlang peer. The TLS check binds a leaf to some
configured pin and that pin's node name, so per-node identity between pinned peers is
not established at the distribution layer. The owner port limits the kinds of command
a peer can send, which is scope hygiene and not a security boundary.

## Known limits and follow-ups

- No failover, and no moving a session between executors. Ra/Khepri comes later.
- After an executor restart, a session that stays open keeps failing new tool calls
  with "attach first" until it is closed and reopened. Calls the ledger knows are
  answered honestly. Orphan runs left by an orchestrator that died hold their budget
  until the session is reopened and closed; there is no executor-side listing.
- An imported session whose origin is decommissioned, renamed or reinstalled can never
  move on, and has no override yet. The web home's delete button does not apply the
  inbound hold that the control `sessions.delete` applies.
- A queued message to a saved session learns that the session was opened at its
  next attempt, up to five minutes later once the backoff has grown; nothing tells
  the sender's drainer that a recipient opened. A message queued while the drainer
  is backed off for older messages waits for the same tick.
- A session that moved is not listed on its source: `sessions.list` carries `moved`
  and both clients leave the tombstone out. It lists only on the receiver, until the
  elsewhere group (protocol-change/085) shows it from the source's side.
- The receiver identifies the sender by `from_node` through its `[orchestrators]`
  table, as claimed by the sender. Copies refused or abandoned stay in `incoming/`,
  and a failed rename of the moved-away file is not logged.
- `loomd executor release` leaves its own endpoint reservation behind, so `loom` may
  report "still starting" until the next daemon starts.
- On macOS, an executor started from a checkout looks for its code-mode seed under
  the workspace's `build/` by default, which is wrong there. Pass `--codemode-seed`.
- Remote sessions refuse extension tools and operator directory additions.
  Background code mode and MCP facades on a remote session are on the stacked
  branch `distributed/remote-codemode` (see below), not on this one.
- `remote/protocol` and `storage/exec_ledger` each keep their own `Key` and
  `CloseOutcome` types with mappers between them.
- Two recorded flakes: `daemon_shipped_remote_test`'s partition drill saw an
  `options_mismatch` at executor boot once, and the macOS gate's skip census flags two
  undeclared broker `/proc` skips. Both are filed as tasks.

## Web code mode card and tool-schema fixes (web/code-mode-ui)

The web view draws a `code_mode` step as a typed card instead of the terminal's
text rows: `session_view/program_card` is the projection, `turns.Step.program`
carries it, `web_view/view/program_card` draws it. Deferred, deliberately:

- Copy buttons for the program and result text. `<loom-copy>` takes only
  shape-checked subjects, so copying arbitrary text needs a new client element
  and a ruling under protocol-change/051 on clipboard writes of server-chosen
  text.
- Rolling consecutive `code_mode` calls of a turn into one summary row.
- Live per-call rows while a program runs. The call record is written at
  settlement, so a running card shows an elapsed clock and no rows.
- `program_card.value_of` still reads the result's kind from the terminal's
  rendered preview text; `transcript_lines` should expose the pair it renders
  from.

The same branch fixes a placeholder-filling failure seen in GPT sessions: tool
fields the model should omit (`todo` `task:""`, `job_poll` `since:""`, bash
`permissions` with `wall_s:0`, `agent_send` `within_ms`) arrived as values, which
raised an approval prompt for every bash call. The cause was inferred, not
confirmed: Responses function tools carried no `strict` field and the model
reported every field as required. The branch sends `strict: false` and pins the
optional fields out of `required` in tests. **Not checked against the live
Responses API.** If placeholders still appear, `agent_wait` `within_ms:0`
(a poll, not a refusal) and bash `permissions` are the first places to look.

A release's bundled `erl` could not boot bare, because the release had no
`bin/start.boot`; any model shell typing `erl` died. `release.sh` and
`release-client.sh` now install it and `--smoke` checks it. Releases installed
before this stay broken until rebuilt.

## Background code mode and MCP on a remote session

The branch `distributed/remote-codemode`, stacked on PR #923, implements the
protocol-change/078 addendum "background code mode and MCP façades on a remote
session" at protocol version 3. The orchestrator keeps each background
execution's record, input and progress in `async_runs`; the executor runs the
program under the ledger key `(session, op, "async/<id>", 0)`; a closed record
sends `StopExecution`, which `exec_ledger.stop_or_fence` turns into an unknown
row or a barred key; the owner port's reconciler stops orphans and acknowledges
an execution's row only once its record is closed; recovery after an
orchestrator restart keeps a result the executor already stored. `[mcp.<name>]`
gains `runs_on`, and an executor-placed server runs from the executor's own
table. `packages/client/CLAUDE.md`, "Background code mode and MCP on a
registered session", is the map; the P model's mutants M8 to M12 and the
shipped fixtures `daemon_shipped_remote_background_test` and
`daemon_shipped_remote_mcp_test` are the evidence.

Open on that branch: `check`, `send` and `cancel` wait out a link cut because
`code_mode` is placed on the executor by name; the execution budget (1 MiB a
row) is per executor; a rebound attach keeps the old MCP plan without a log
line saying so; and the launching call that the record now stores is used to
attribute a background program's workflow steps but does not change the step
id the workflow ledger records.

## The Linux box

Owner-provided, used for every Linux and cross-host run: `sectional-falcon.exe.xyz`,
user `exedev` (uid 1000), x86_64, 2 cores, kernel 6.12, OTP 29.1.1 at
`/opt/erlang/29.1.1/bin`, gleam 1.19.0, go 1.27.1, bwrap 0.9.0, and docker (the user is
in the `docker` group). There is no Java and no P tool, so `make model-check` cannot run
there.

- Environment: `PATH=/opt/erlang/29.1.1/bin:$HOME/.local/bin:$PATH` and
  `ERL_FLAGS='+S 2:2'`.
- Keep checkouts and sockets outside `/tmp`. Each candidate goes to
  `~/loom-distributed-tests/<sha>/src` through `git archive` streamed over ssh, with
  `LOOM_TEST_SCRATCH=~/loom-distributed-tests/<sha>/sockets`.
- cgroups: `systemctl --user` runs and `user@1000` delegates `cpu memory pids`. Run each
  step in a fresh scope with a fresh name,
  `systemd-run --user --scope --unit=loom-crosshost-<step>-<sha>`. The recorded wrapper
  (`~/loom-distributed-tests/<sha>/inner.sh`, called by `run-step.sh` and `driver.sh`)
  creates `supervisor/` and `base/` inside its own scope, enables `+memory +pids`, and
  sets `LOOM_CGROUP_BASE=<scope>/base`. Without it the pids-limit selftest layer is
  skipped. Do not change global cgroups.
- Verify read-only first (ssh, `systemctl --user`, `/run/user/1000/bus`, toolchain,
  free space), then prepare the new candidate in its own directory and record its
  results beside the earlier ones.
- Cross-host: the box's ports sit behind the provider's proxy, so distribution needs
  ssh forwards. For a box executor, forward epmd and the executor's distribution port
  with `ssh -L` to an address the Mac's own epmd does not hold. For a box orchestrator,
  use `ssh -R` to loopback ports, with `ERL_EPMD_PORT` set on the box side. Section 5 of
  the setup guide has the commands. For a partition drill, kill the ssh process itself,
  not a wrapper shell.

## What to do next

1. Run the gated signoff (`LOOM_SIGNOFF_HOST=gilgamesh-signoff make signoff-remote`) on
   PR #923's exact head. Exit: green. If `daemon_shipped_remote_tools_test`'s goal check
   fails again, treat it as a defect in the remote goal path, not as a poll budget to
   raise.
2. Close the cheap follow-ups above: the web delete hold, re-attach after an executor
   restart, an override for an imported session whose origin is gone, and the TUI's
   `moving`/`moved` rendering.
3. Session ownership in Khepri is a separate PR stacked on this one (branch
   `directory/khepri`, ADR-020): opt-in by a `[directory]` table, with Khepri deciding
   moves and every session on a member recorded. Failover and executor movement remain
   out of scope.

## The session directory in Khepri (`directory/khepri`)

This section covers `directory/khepri`, built on top of the tree this handoff
describes: the session directory in Khepri (protocol-change/083). Everything
above still describes the distributed runtime it builds on. What the branch adds is a deployment option, a `[directory]`
table, under which the orchestrators and executors form one Khepri cluster that
holds the single authoritative record of which orchestrator owns each remote
session, and every change of owner is one compare-and-set on that record. Local
sessions are recorded too, as lookup hints.

The branch is PR #934, built on PR #923. An independent implementation review
was done; its confirmed findings and the owner's ruling on local sessions were
fixed in a second pass (ADR-020's addendum lists them), a third pass made a
missing record after the seed set the source's copy aside instead of reverting,
and a fourth made a receiver that owns the record answer `Failed` rather than
`Refused`. The branch is rebased onto PR #923's head (`8dee702e5`, after its
latest merge of main). Its proposal is protocol-change 083, since main took 079
through 082, and its catalogue migration is version 14, after #923's 11 to 13 and
main's 10. The link's settle came from this branch and now lives on #923.

Read [the session directory](architecture/directory.md) for the design,
[ADR-020](adr/020-khepri-for-session-ownership.md) for the choice of Khepri and
what the spikes measured, [protocol-change/083](../protocol-change/083-khepri-session-ownership.md)
for the interfaces, [the plan](design-notes/khepri-ownership.md) for how the work
was ordered, and the section "The session directory" in
[the setup guide](distributed-setup.md) for running it. `packages/client/CLAUDE.md`
has a section, "The session directory in Khepri".

### Where the tree is

| Part | What exists |
| --- | --- |
| Dependency | `khepri == 0.19.3` in `packages/client`, which pins Ra 3.2.0, horus, aten, gen_batch_server and seshat; `packages/conformance/manifest.toml` updated by hand. One FFI module, `client/internal/ffi_khepri` over `client_khepri_ffi.erl`. |
| Distribution | Members start visible with `-kernel connect_all false` (the launchers pass it with the TLS flags; a member VM without it is refused). Member-to-member connects use `net_kernel:connect_node/1`; everything else stays hidden. A daemon without `[directory]` is unchanged. |
| Configuration and provisioning | `[directory] members` (3 to 7, every orchestrator a member). A plan's top-level `directory` list makes members peer with each other and writes the table into their bundles. |
| The cluster | `client/directory/member` keeps the links and joins a member with no joined store as a Ra `promotable` non-voter after removing its stale identity; Ra promotes it once caught up. The join is sequenced in `client/directory/store` over `weft/poll`, one FFI primitive per Ra call. `loomd directory bootstrap` creates the cluster once and refuses where it would make a second; the Ra system's own files are not a store, and each refusal names its remedy. `directory.status` reports the member's view. |
| The record | `{loom_owner, 1, Owner, serving \| {moving, Op, To}}` per remote session, and `{loom_owner, 1, Owner, local}` per local session. Remote creation reserves, writes the record, then opens; deletion marks (catalogue v14 `catalogue_session_deletions`), deletes the record conditionally, then the registration. A local session's record is written after it exists by the movers' upkeep (`migrate.cover_local`, at boot and after each local creation, again until a pass succeeds) and removed best-effort on delete. Lookups read the local copy. Opening makes no Khepri call. |
| Moves | `session_mover` under `Recorded` authority: the row first, then the intent CAS (a record gone after the seed means the session was deleted elsewhere, and the move ends with the copy set aside, never served again), close, cut, send, the receiver's activation CAS before its import, and retirement on the receiver's answer and a consistent read. Abandon is a CAS that fails once the receiver activated; a give-up that finds the receiver owning the session asks it again rather than retiring. A silent receiver is given up after 30 minutes of stalls with a quorum (receiver's migration marker and this daemon's seed required; `Deferred` stalls are not counted); the owner can abandon with `sessions.move` `abandon: true`. No inbound hold on members. |
| Migration | Each orchestrator seeds the store from its catalogue once, then writes `[loom, migrated, <node>]`. |
| Model | `protocol/models/session-move/KhepriMove.tla`: two moves (there and back), content versions, crashes, a lost majority, late activations, a receiver that deletes the session, receiver steps fair only while the source asks, nine mutants (one temporal), gated by `make model-check` beside `Move.tla`. |

#### Evidence

On the rebase onto PR #923's head `823530f28` (after its third merge of main,
with this branch's proposal at 083 and its catalogue migration at 14), every
gate passed: `make lint` (0 errors), `make doc-check`, `make prelude-check`,
`make model-check` (`KhepriMove` 332,902 states, nine mutants caught), `make
server-shipment` and `make sandbox`, the shipped `remote_move`, `directory`,
`directory_quorum`, `peer_mail` and `remote_test` modules with 0 SKIP lines, and
`make check-gleam` (3725 client tests, 667 s). An earlier `check-gleam` run at a
load average near 200 failed 13 `ui_route_test` fixtures whose lock helper did
not settle; the module passed alone once the load fell. The paragraphs and
table below are earlier runs.

After the re-verify review's fixes (a receiver that owns the record answers
`Failed`, never `Refused`; the gone record logged on the abandon path; the seed
marker's assumptions documented) and the rebase onto PR #923's head
`0e7be0b43`, every gate passed on the first run: `make lint` (0 errors),
`make doc-check`, `make prelude-check`, `make model-check` (`KhepriMove` 332,902
states, nine mutants caught), `make check-client` (3699 tests), `make
server-shipment` and `make sandbox`, the shipped `daemon_shipped_remote_move_test`
and `daemon_shipped_directory_test` with 0 SKIP lines, and `make check-gleam`
(649 s). The table below is the earlier run on `cb69cd798`.

All rows are for `cb69cd798` and its successors, which change only this file
and move one function in `session_movers` (the R15 fix below), on a Mac
(Darwin, macOS 15.5), each gate's own exit code captured directly. The machine
was shared and heavily loaded (load average 14 to 21) during these runs.
`make check-gleam` names its packages, so it does not run the house-rule lint;
that is `make lint`, run separately below.

| Gate | Result |
| --- | --- |
| `make check-gleam`, first run | exit 2, 542 s: `client@codemode_live_test` timed out copying a directory, which ended the client package's run. The module passed when run alone (30 tests). |
| `make check-gleam`, second run | exit 2, 228 s: `cap_test.parallel_map_worker_crash_is_reported_test` saw the exit reason `abnormal` for `killed`, a race in `cap`, which this branch does not touch. `cap` passed when run alone (191 tests). |
| `make check-gleam`, third run, after the R15 fix | exit 2, 413 s: `client@codemode_live_test` timed out again, on another of its cases. The module passed when run alone and in the per-package `client` check below. |
| `make lint` | exit 2 at first: R15 in `session_movers`, `no_upkeep` sat above the actor's message and state types (entered with the local-session work, unseen because `check-gleam` runs no lint). After the move, exit 0, 0 errors and 2300 warnings. |
| `make check-<package>` for the packages the full gate did not reach (`ext`, `codemode`, `events`, `client`, `conformance`, `tui`, `lint`) | every one exit 0: `ext` 16 s, `codemode` 57 s, `events` 6 s, `client` 366 s (3697 tests), `conformance` 53 s, `tui` 21 s (1316 tests), `lint` 2 s. Together with the first run, which passed every package before `client`, each package's format, warning-free build, tests and lint passed on this head. |
| `make doc-check`, `make prelude-check` | exit 0, exit 0 |
| `make model-check` | exit 0, 260 s. `Move`: four mutants. `KhepriMove`: 332,902 states, 87,390 distinct, depth 34; every invariant, `MoveSettles`, `MoverEnds` and `OwnerCanServe` hold; nine mutants each violate their property. Both P models pass. |
| `make server-shipment`, `make sandbox`, `bin/loom-exec` installed | exit 0, exit 0, exit 0 |
| `daemon_shipped_remote_move_test` (4 tests: clean and crash, rows and members) | exit 0, 0 SKIP, 174 s |
| `daemon_shipped_directory_test` (2 tests; the member one with a local session redirected and mailed) | exit 0, 0 SKIP |
| `daemon_shipped_directory_quorum_test` (quorum loss, disk-lost rejoin) | exit 0, 0 SKIP |
| `daemon_shipped_peer_mail_test` (2 tests, one with members) | exit 0, 0 SKIP |
| `daemon_shipped_remote_test`, `daemon_shipped_remote_tools_test` | exit 0, exit 0, 0 SKIP |
| Linux | not run on this branch |

### Rulings already made

These are the owner's rulings of 2026-10-08 on the review of the first design.

**Visible distribution for members only.** `connect_all false`,
`dist_auto_connect never` and the pinned allow list stay. Every member-to-member
connect goes through `distribution.connect`. A deployment without `[directory]` is
hidden as before.

**Khepri decides, rows stay.** The record is the authority. The catalogue's move
rows and the deletion mark are local write-ahead memory: a local change that stops
serving precedes the record write and is reverted if it fails; one that grants
serving follows a committed write. Opening a session makes no Khepri call. `Owns` fan-out, `owner_unreachable` and the inbound
hold are retired on members.

**A stalled move is abandoned by the record.** After 30 minutes of stalls while the
store has a quorum, never without a quorum, never while the receiver's migration
marker is absent. An operator can abandon by hand.

**A member that lost its disk rejoins as a non-voter.** Bootstrap is an explicit
command that refuses when a local store exists or a configured member runs one.
Odd member counts are recommended.

**Local sessions are recorded** (owner ruling after the implementation review).
Every session on a member has a record; a local session's is a lookup hint in a
state of its own (`local`) that no move can use, written best-effort and never
gating a creation. A stale one names the right owner, who answers `not_found`.

**Formal model.** `KhepriMove.tla` sits beside `Move.tla`; both are gated. Its
`KhepriMutantImportOverMoving` shows that the receiver must refuse a session its
own row still holds before it writes the record, which the importer does.

### Known limits and follow-ups

- A local session created in the last few seconds, or while the cluster had no
  majority, is `not_found` on another member until its record lands. A delete
  from the web page does not remove a local session's record; the stale record
  names the right owner.
- A member's copy can lack a record during its join or after a long outage, and
  answers `not_found` meanwhile (review finding 5, transient, not changed).
- No terminal or web surface for `directory.status` or for abandoning a move;
  both are control commands only.
- No membership removal command (`ra:remove_member/3` behind a `loomd directory
  forget`), and no check of the record at open, which failover will need.
- No shipped test moves a just-imported session onward at once; the in-VM mover
  tests and the model cover it.
- The shipped quorum-loss test cannot show a remote session opening without a
  quorum, because the executor such a session needs is one of the members it
  stops; `directory/daemon_record_test` shows it in the VM.
- One unexplained failure of `loomd directory bootstrap` in a shipped fixture,
  in the first run of `daemon_shipped_directory_quorum_test`; it did not recur in
  the runs since. `remote_duo.start_members` now prints the command's output when
  it fails.
- Everything in the previous edition's list for the distributed runtime still
  stands (executor restart re-attach, the web delete hold, the TUI's `moving` and
  `moved` rendering, and the rest).

### What to do next for the directory

1. Independent review of `directory/khepri`, then publish it (push and PR) with
   the owner's authorization, and run the gated signoff and hosted CI on the head.
2. Run the shipped member tests and `make model-check` on Linux.
3. Failover: a lease or liveness rule, the takeover CAS, a check of the record at
   open, an ownership epoch at the executor's attach, and the conversation file
   available to the new owner.

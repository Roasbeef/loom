# Next

**Read this first.** This is the handoff between sessions: where the tree
stands against the plan of record, what to work on next, the rulings
already made so nobody re-litigates them, what is deliberately left open,
and how to verify a change. Rewrite it when you finish a body of work.

**Active work: single daemon and multiplayer.** The owner selected one
daemon across workspaces, no legacy compatibility path, and catalogue
restoration followed by lazy session opening after restart. The target is
documented in [sessions](architecture/sessions.md) and
[multiplayer](architecture/multiplayer.md). The daemon replacement is not
yet shipped.

The foundation, [PR #227](https://github.com/Roasbeef/loom/pull/227),
merged into `main` at `a6cea08`. The owner published Weft v0.4.3 after
[Weft #11](https://github.com/Roasbeef/weft/pull/11). Loom uses the
published release, not an evaluation path dependency.
GitHub stack #231 is now `main → #228 → #229`, rebased with the native
`gh stack` commands onto `main` at `5e2112b`.
[PR #228](https://github.com/Roasbeef/loom/pull/228) replaces strand and
factory names; its rebased head `d57438d` passed all four CI jobs in run
`33936465271`.
[PR #229](https://github.com/Roasbeef/loom/pull/229) replaces runtime
service names and preserves ordered retries after writer replacement.
Its first rebased run found one stale documentation citation. That
citation is corrected at `11035fb`, which passed all four CI jobs in run
`33937341782`. No merge is implied by these results.

Work continues on `client/session-services`, rebased onto #229 at
`11035fb`. The previous checkpoint's pending rebase and verification are
complete. The implementation at `f3ca94b` passed the combined local gate;
only documentation corrections follow it. Its implemented changes are:

- The eleven composition-service names and the demo's two names now use
  reclaimable Weft addresses. Writer subscribers distinguish direct
  subjects from routed addresses; hints remain lossy and execute no
  caller-supplied callbacks in the writer.
- `serve.Instance` owns session resources without a public listener.
  `open_instance` can open two independent sessions in one VM;
  `Booted` adds the listener. Tests execute real provider turns in both,
  close one while the other remains usable, and measure zero atom growth
  across warmed repeated assembly cycles.
- Failed gateway attachment closes even an idle socket, after Mist
  transfers TCP ownership. The TUI isolates abnormal socket exits behind
  a Weft lifetime actor. Six focused real-socket tests pass, including
  peer-observed cancellation while the HTTP handshake is withheld.
  Independent review caught delayed handshake cancellation; moving
  blocking startup back into the untrapped worker fixed it, and the
  reviewer verified that correction.

The rebased `make check` passes 1,124 client, 164 TUI, 115 runtime and 69
conformance tests, with zero lint errors. `make doc-check` and the real
`make e2e-client-bootstrap` also pass. The bootstrap target builds the
server shipment and exercises startup, detach, reuse and cancelled
connection attempts, followed by the hostile-environment cases.

The first combined gate failed the existing crash/lease-theft simulation
at seed 33 (`run/terminated`). It did not recur in 360 scheduled
executions on this branch or 360 on the unchanged parent at `11035fb`.
The parent's complete conformance gate and the branch's full rerun both
passed. The original failure's cause remains unestablished; the rerun
does not erase that observation.

**Next: surviving cleanup custody, then daemon admission.**
The assembly slice is published as
[PR #233](https://github.com/Roasbeef/loom/pull/233), head `b6df17e`,
above #229 in native stack #231. Work continues on
`client/session-ownership` above that head.
All four #233 CI jobs passed in run `33938772943`.

The ownership branch adds an internal `api.open_published` hook. The
root's first child-start callback publishes the runtime and direct drain
witness before starting the writer or recovered drivers. The runtime
gate passes 118 tests. Three focused tests cover paused publication,
refusal and scope-holder death; moving publication after startup makes
the ordering regression fail. Independent source review found no issue.
The full combined gate has not yet run for this ownership slice.

Weft v0.4.3 keeps a raw managed-worker crash outcome pending while an
adopted owner remains alive; it does not automatically cancel that owner
on the raw crash. The owner-death regression instead kills the scope
holder, which initiates cancellation and produces a normal drain witness.
Full assembly integration must cover independent worker faults explicitly,
not assume that consuming a withheld outcome will initiate cleanup.

`open_instance` still uses the old host and `close_instance` still
discards its runtime drain result. Neither is ready for a daemon manager
to call as a complete lifecycle boundary. Partial boot and owner death
must leave resource handles with surviving custody before recovered work
can execute. Ordinary `api.open` still resumes drivers before it returns;
the assembly must use the new publication hook to establish custody first.
An uncertain drain must retain the reservation and prevent replacement.

After custody, implement the durable catalogue with restore-only startup,
lazy authorized opening, one daemon listener and routed attachments, safe
client startup and switching, multiplayer authorization and convergence,
and internal plus live Herdr E2E. These remain required work, not
follow-up scope. The older project-wide handoff below is not freshly
verified by this active-wave checkpoint.

It is deliberately not a history; the git log and the PR bodies carry how
each change was reviewed. Re-baselined 2026-09-04 against `main` at
`18e71d5`, with every claim below checked against the tree or against a
CI run rather than carried forward. The previous edition, baselined at
`576d640` on 2026-09-03, described the Gemini adapter as living on a
branch and knew nothing of the client's testing plane; both have since
landed, so this edition rewrites those items rather than carrying them.

## Compaction review: PR #223

This section is the 2026-09-04 compaction update against `main` at
`f019322`, integrated by `d87900e`. The project-wide survey below retains
its earlier baseline; it is not a renewed audit of every issue or CI run.

The host now publishes notes-based checkpoints without a summarizer
provider. The review preserves the newest assistant exchange and every
following result or user message across a cut. `keep_recent_tokens` is a
soft target: an unread exchange cannot be discarded merely to meet it.
Exact `history_search` reads resolve canonical session/entry IDs through
host-registered absolute paths, validate the source identity, and preserve
writer leases. Oversized results spill completely to blobs or fail
explicitly. Prior checkpoints remain addressable for inherited context.

The default prompt describes stable note keys and exact recall. The
run-start digest still injects current notes as user-context data, while
the checkpoint is an immutable snapshot. **Rollout starts fresh sessions**;
we are not supporting resumed tasks from the removed summarizer. The
near-limit reminder is not Codex's final fallback phase, and there is no
model-callable rollover tool.

`docs/architecture/compaction.md` is the current design reference. It
corrects the former claim that a summarizer's omissions were permanently
unrecoverable: both policies preserve the durable transcript. It also
separates snapshot bounds from preservation of the complete note board.

Next for this subsystem is the real-model comparison described there:
multiple boundaries, actual note writes, omitted-fact recall, restart and
a child with an independent board, with correctness and cost measured
against a pinned summarizer baseline. That evaluation has not been run.
#132's projected task-state design and window-listing recall remain
separate work. Vector search could share the exact-read addresses, but
requires embedding and native-extension integration of its own.

Validation: the integrated native `make check` passed. See PR #223 for
the final follow-up integration results and checks on the published head;
a prior head's green CI is not evidence for later commits.

---

## Where the tree is

The plan of record is `docs/issue-plan.md` and its milestone `v0.1 —
claimed, true, and self-extending`, with the acceptance rows and the
evidence rule in `docs/loom-implementation-spec.md` Part 4. Phases 1
through 3 are substantively in the tree. Phase 4, the promotion ladder
the milestone's name calls self-extending, has changed shape: the
extension architecture that subsumes most of it is built through its own
phase 3, and what remains of the ladder is the tier-H loader and the TCB
freeze. Phase 5 has not been started, and the extension route is now its
intended home.

| Phase | Body of work | Where it stands |
|---|---|---|
| 1 | Claimed and true (M0–M4), #1–#13 | Code done; CI completes and is green more often than not. The gate is one owner action away (#1, and `main` has no branch protection today). #62 and #99 are answered by measurement and still open. |
| 2 | Orchestration seam (M4.5 / WP-N), #20–#24 | Landed. M4.5's row stays `partial` because the sample's fan-out reaches a scripted Agency rather than live children. #24 and #93 are still open. |
| 3 | Semantic tools, routing, memory (M5), #14, #15, #16, #25–#29 | Routing, session id, the capability router, triggered rules, MCP through code mode and both memory stages are on `main`. #25 and #26 moved to phase 5. #106 stays open on the jail decision (#109). |
| 4 | Promotion ladder (M6 / WP-M), #18, #30–#33, #100 | Extension phases 1–3 built (#170, #175–#182, #195, #196, #198, #199, #200). Phase 4 built in its decided form: the TCB freeze proven as gated tests with a recorded review (#204, closes #33), `before_compact` and `usage` hooks and the tool-override ruling (#203), `ext.remember`/`ext.recall` (#205). The tier-H loader (#32) is deferred with the reason on the issue; L1/L2 (#30, #31) not started. |
| 5 | Language-service tier, #25 (LSP), #26 (DAP) | Not started. The design note names both as extensions over the persistent satellite, blocked on a `[proc]` grant for binaries. |

### Phase 1: green, with a different red than the previous edition named

The previous edition said the last six merge runs on `main` were green
across all four jobs and that `gate (macos)` had failed twice in twelve
runs, both times on the `runtime` interleave stall. Neither is true now.
Of the twelve completed `main` runs before this baseline, three failed,
all on `gate (macos)`, and none of the three was the interleave stall:
one was `writer_publish_test` sending to an unregistered name beside an
`escalation_test` await (the shape #180 then fixed in the drain-registry
test), one was a `cap_test` assertion, and one was `make e2e` with a
single failure. The interleave cause #171 removed has not recurred.

The soak is better than the previous edition said, not worse: `soak (200
seeds)` passed in all twelve of those runs, not eleven. The nightly long
soak is where the red lives, and it is narrower than claimed: its last
run failed only the `seeds 1001..` band, with `seeds 1..`, `seeds 501..`
and `seeds 1501..` green. **#155** should be re-scoped onto that one band
before anybody picks it up.

The `jail (linux)` job still runs the self-test with nine of nine probes
enforced and zero skipped, and `make e2e`'s applied-layer line reads
`degraded=False` with `landlock:abi=7` beside `bwrap`, `cgroup-v2`, the
two rlimits, `no-new-privs` and `seccomp-net`. That measurement is on
**#62** in this change; the previous edition said the spec's M2 note was
corrected and it was only half so, the environment list in Part 4 still
said Landlock had never executed until this change.

Phase 1's remaining work is bookkeeping and one owner action: post the
measurements on **#99** and **#62** and close them, re-scope **#155**,
and set `gate-linux` as the required check (**#1**).

### Phases 2 and 3: unchanged since the previous edition

Everything phases 2 and 3 name is on `main`. Three issues stay open over
completed work, for the same reasons as before: **#106** is held open by
the MCP jail question split into **#109**; **#24** wants a check against
`make e2e-codemode` before closing; **#93**'s sweep over the build and
getting-started docs is still owed. M4.5's row stays `partial` because no
single run has put a model-written program in front of live child
strands, and by Part 4's own rule a criterion met with a test-supplied
substitute is not met.

### Phase 4: the extension architecture is built through phase 3

The previous edition said phase 4 was at zero, that there was no
`packages/ext`, and that the extension work was the next body of work,
arriving with a PR that had not merged. All three were true when written.
Now:

- **`packages/ext`** is the package an extension compiles against inside
  the jail: `ext.gleam` (the tool vocabulary), `ext/hook.gleam` (the typed
  hook vocabulary and the JSON wire shapes) and `ext/runtime.gleam` (the
  receive loop over `hook_call` frames). The harness side is
  `packages/client/src/client/extension/`: archive reading, the manifest,
  install and its record, discovery, `loom ext install|list|remove|verify`,
  the egress policy, the router seam, dispatch, the hook bus and the host
  registry.
- **`net.request` is served**, by `broker/egress` making the HTTP request
  on the host under a per-extension policy, so the previous edition's
  "deliberately open" entry saying it was unserved and gated on a sidecar
  is retired.
- **The acceptance test the owner named passed** on 2026-09-02: `loom ext
  install https://github.com/Roasbeef/loom-web-search` fetched over
  codeload, and a Kimi K3 session called `web_search` and answered from
  Brave's results with `BRAVE_API_KEY` in the server's environment and
  nowhere else. That is a documented drive, not a CI job; the e2e that
  reads the jail's environment and every frame on the channel is what CI
  runs.
- **Phase 3's exit criteria are met by the e2e** in
  `packages/client/test/client/extension_e2e_test.gleam`, over real jailed
  satellites: a jailed `tool_call` hook blocked a call and the refusal
  named the extension, a jailed `context` hook appended a message within
  the cap, two invocations cost one node launch, and an oversleeper was
  reaped with its extension marked unavailable for the rest of the
  session.
- **Phase 4 was decided on 2026-09-03 and built the same day.** The
  previous edition planned the tier-H loader. A survey of the pi
  ecosystem (about 490 extensions) found none that needs code loaded into
  the harness VM: the tool, gate, context, memory and LSP classes are all
  jailed, and what they lacked in Loom was vocabulary. So the loader
  (**#32**) is deferred with that reason on the issue, and phase 4 became:
  the TCB freeze proven as gated tests without a loader, with
  `docs/review/extension-zone.md` as the record (#204; **#33** closed);
  `before_compact` as a notify-plus-note event with no veto, `usage` as a
  notify-only event fired after the ledger row commits, and the ruling
  that an extension never overrides a built-in (#203); and
  `ext.remember`/`ext.recall` over the durable blackboard under a reserved
  `ext/` prefix (#205). Each PR had an independent review pass and a
  re-verify; no HIGH was found. What the plan's M6 closing criterion still
  owes is the L0→L3 ladder test with a live rollback, which cannot exist
  without the loader, so the row stays `partial` on purpose.

The previous edition's grep for `ExtensionZone`, `ExtTool`, `ExtHook`,
`ExtProjection` and `load_binary` still returns nothing, because the
shipped vocabulary is different; do not read that grep as "phase 4 is at
zero" again.

What phase 3 deliberately left out, each recorded at the site: the host
registry is not stopped on `serve` shutdown (the supervisor kills it and
the launcher's janitor reaps every node, so only enforcement reports are
lost); `agent_settled` is accepted by the manifest and carried by the bus
but nothing in the harness fires it; `agent_end` carries no outcome word
because it is asked before the terminal transaction commits; the host
registry serialises the whole session's invocations rather than one
extension's; and Linux never ran the phase 3 e2e locally, only in CI.

### The model plane: three dialects, driven

Merged 2026-09-04 (#209). A third wire dialect sits beside Messages
and chat-completions: `provider/adapter/gemini.gleam` speaks the Gemini
Developer API's `streamGenerateContent` with a Google AI Studio key, and
`dialect = "gemini"` in `loom.toml` routes to it. It was driven live on
gemini-3.8-flash through the TUI: tool calls with thought-signature
replay, a two-subagent fan-out, and a code-mode program all worked, and a
Gemini-driven review of the adapter found two real replay defects that
are fixed with tests. Two things the drive turned up outside the model
plane were fixed on the same branch: the broker relay now cancels a
jailed command whose caller died (an escaped run used to leave the child
running to its wall limit), and `make server-shipment` now builds the
code-mode seed, because a server without one registers no `code_mode`
and the model appears unable to find code mode. `docs/architecture/
models.md` has the dialect; the Vertex AI route is not reachable with an
API key and is not built. One observation is recorded here rather than
filed: finished subagents are reaped from the agents overlay once waited
on, so there is nothing to select.

### Memory: the producer now runs

The previous edition said the producer was inert: `client/distill` was
imported only by tests and no release entry point reached it. That was
true when written and is false since #208 (2026-09-03). `client/serve`
now starts `client/distillpass` at every ordinary boot, the release
smoke proves the pass ran with no toolchain on `PATH`, and **#149** is
closed. **#124**, the unrecoverable cascade, closed the same day (#212):
a cascade that drops rows now rewinds every recorded source cursor and
the notes cursor in the head-replacing transaction, so the next pass
rebuilds. Memory is complete against its plan and has its architecture
page, `docs/architecture/memory.md`.

### The client can now be driven and read without a terminal

The largest change of 2026-09-04, and the one that changes how the next
client bug gets fixed. Until it landed, every layer was tested except the
one a person touches: `render_frame` had unit tests, and the rendered
result had a tmux-bound end-to-end that asserted a few substrings.

etui's `Backend` is a record of five functions, so #221 supplies a
scripted one. `tui/virtual_backend` answers a list of events instead of a
file descriptor and hands back every `Buffer` the shipped loop drew;
`tui/frame` turns one into text. On top of that sit two things:

- **`loom --record <path>`** writes every inbound message and input event
  as JSON lines while a real session runs, and **`loom replay <path>
  [--at N] [--all] [--width W] [--height H]`** replays one and prints
  frames as text. That is the agent-facing surface: a bug seen in a pane
  becomes a file, and an agent reads frames by running a command rather
  than by scraping a terminal.
- **Golden files** under `packages/tui/test/snapshots`, compared by
  `test/snapshot_test` and rewritten by `LOOM_UPDATE_SNAPSHOTS=1`. Ten
  are hand-built states; one replays a committed recording of a real
  Gemini turn (`test/recordings/gemini-flash-reply.jsonl`).

The rule that shaped it: **a replay reproduces inbound traffic and
rendering, and never an outbound effect.** `tui.Peer` makes that
structural rather than remembered — `Attached` carries the socket and
sends, `Preview` is `--demo` and echoes, `Replaying` performs only the
live path's local half — because the first replay of a real recording
drew an assistant line the live client never showed, and a golden that
records an invention is worse than no golden. The same rule removed a
fabricated tokens-per-second figure computed from the replay's own clock.

Two defects have been found by using it, both in the replay path itself;
none yet in the live client, because the goldens are hours old. Its value
is prospective, and `docs/architecture/client.md` §"Recording and
replaying a session" plus `packages/tui/CLAUDE.md` carry the whole
contract, including the one divergence that is deliberate: `/sessions`
reads a local catalogue a recording cannot carry, so a replay says so
rather than inventing either answer.

### Four client fixes, all merged the same day

Each was found by an operator looking at a pane, which is the gap the
section above exists to close.

- **#217** — the footer decided its row count from the width of the text
  it happened to hold, so it flipped between one row and two as a turn
  ran and moved the prompt box under the operator's hands. Rows now come
  from the window alone; the `/details` status label was shortened
  because it was the one string the section had to cut.
- **#219** — the tokens-per-second clock started at the first stream
  fragment, and a provider that streams whole parts (Gemini) delivered a
  short reply as one burst, so the footer read `126000 tok/s`. The clock
  now starts when the strand enters its `assistant` phase, and a window
  under `output_rate_min_ms` reports no rate at all.
- **#218** — three things a jailed shell hit on macOS. Apple's `git` and
  `make` are `xcrun` shims that write a cache to the per-user darwin temp
  directory whatever `TMPDIR` says, so every `git status` printed
  `Operation not permitted`; both that directory and the user cache
  directory are now Seatbelt writable roots, and the helper's private
  scratch moved to `/private/tmp` so that grant cannot make one
  execution's scratch writable by another. `HOME` was the workspace, so
  macOS built a `Library/Caches` in the operator's checkout; it is now
  `<workspace>/.codemode/home`. And a linked git worktree keeps its
  metadata outside the workspace, so `git commit` died on the index lock:
  the base now grants the worktree's git directory and the main
  repository's `.git`, and `bash` asks for every root the base grants
  rather than the workspace alone, because the meet would otherwise take
  the widening straight back.
- **#216** — `[tools]` in `loom.toml` opens the jailed shell's network
  (`network = "full"`), passes named host variables through, sets
  literals, and appends directories to `PATH`. It is what lets `gh` work
  inside the jail. `grep` stays pinned offline whatever the base allows.

---

## What to do next

In this order. The first item is a body of work; the rest are smaller and
can be interleaved by whoever is not on it.

### 1. The client simulator, both halves

Briefed in full in `docs/design-notes/tui-simulation.md` (#220), written
before the code so the code has something to be held to. Both stand on
the virtual backend that has now landed, and neither is worth starting
before reading that note.

**Part A, the client-side simulator.** One seed splits into a script
(server events keyed by durable position, and the operator's actions
anchored to them) and a schedule (batching, tick pacing, resizes across
every layout threshold, cross-strand interleaving, disconnect and
reconnect, input bursts). It runs through the shipped `update` and
`render_frame` under the virtual backend, and every frame is held to nine
named invariants. Three of them are this week's bugs stated in one line
each: layout is a function of the window, no truncation without an
ellipsis, no rate without a window. It lives in `packages/tui/test`, not
in `conformance`, because the checks are about frames.

**The one production change it needs is an injected monotonic clock.**
`tui.gleam` reads `ffi_bootstrap.monotonic_time_ms` in five places —
`new_model`'s `last_frame_ms` seed, `advance_activity_indicator`,
`refresh_frame_cache`'s 16 ms pacing decision, the `StreamDelta`
generation clock, and `UsageChanged` — and until a schedule owns time,
only the last frame of a replay is reproducible. That refactor is a
behaviour-preserving prerequisite for both halves and should be done
first, on its own.

**Part B, the end-to-end run.** The same client loop against a real
`loomd` whose provider and tools are the conformance simulator's scripted
surface, over the real websocket, with no binary, PTY or tmux. It adds
the wire round trip between the client and gateway codecs — two
hand-written codecs with no test that they agree — plus command effects,
settled-frame goldens per pinned seed, and the escalation path through
the UI. It retires `client/tui_e2e_test` once it runs in the client gate.

### 2. Memory is done; what is left is bookkeeping and two decisions

**#149 is built and merged** (#208). Distillation now runs in
the shipped session lifecycle: `client/distillpass` is a supervised
worker every ordinary boot starts, which runs one pass on a weft scope
bounded by a wall deadline and then idles. The cadence, the opt-out
(`[memory] distill = "on-boot" | "off"`, `distill_wall_ms`), the model
cost, the retry policy ("the next boot reads the same material again")
and when a digest becomes visible are written down in three places that
say the same thing: `docs/architecture/memory.md` (new, the whole
subsystem), `docs/distribution.md` ("Memory distils on the release's own
lifecycle"), and the `[memory]` table's own decoder. `make
release-smoke` now asserts the pass ran on a release with no Gleam
toolchain on `PATH` and skipped the live session.

Two consequences worth knowing before touching this code. The digest is
read at **run start** rather than once at boot — a boot-time read would
hold every session one pass behind its own pipeline, and the design
note carries the addendum. And a pass killed mid-flight cannot release
the memory session's ten-minute lease, so a boot inside that window
logs `memory.distill.failed` and distils nothing; the store is
consistent, and the cost is freshness in minutes rather than a lost row.

**#124 is closed too** (#212). When a cascade drops rows, the same
compare-and-set that replaces the head rewinds every source cursor the
pipeline has recorded and the notes cursor, so the next pass re-extracts
everything still readable; a cascade over a session nothing names stays
a no-op, and `--dry-run` previews the counts without writing.
`distill_test`'s `an_emptying_cascade_rewinds_so_the_next_pass_rebuilds`
pins the rebuild. Nothing in memory is owed; the items below are what
the tree waits on, and the first two are the owner's.

Note what this does *not* do: it does not touch extension memory
(`ext.remember`/`ext.recall` are cells an extension owns, not the
distillation pipeline) and it does not build memory stage M3.

### 3. Close the phase-1 gate

Small, and it is what the milestone's closing criterion actually asks for.
**#99** and **#62** are closed with their measurements and **#155** is
re-scoped onto the nightly `seeds 1001..` band (2026-09-03). What is left
is the one owner action: set `gate-linux` as the required check
(**#1**), which needs repository admin. The macOS reds worth a look
first are the two flakes this week's PRs hit: `writer_publish_test`
sending to an unregistered name, and the TUI `bootstrap_test` launch
lock; neither is the interleave stall.

### 4. The agent-authored on-ramp, if the ladder is still wanted

**#30** (L1 skill store) and **#31** (L2 candidate pipeline) are the
agent-authored path into the same manifest and install record an operator
uses today. With the loader deferred, the ladder ends at the jail, which
is where the design note said the on-ramp should end anyway. Decide
whether the milestone's "self-extending" still means an agent may author
and install a jailed extension under a recorded human decision; if yes,
this is the body of work, and its exit is a fixture tool that goes from
agent-written source to an installed, vetted, jailed tool serving a live
call with the approval recorded durably.

### 5. Decide #144 against the extension route

**#144** (provider-backed web search as a core tool) is now the other
answer to a question the extension route has answered in practice. The
registry seam the previous edition called closed is open (#178), so the
argument that #144 must be a core change no longer holds. Decide whether
#144 closes as "done by loom-web-search" or stays as a core tool for
operators who will not install extensions.

### 6. Two macOS CI flakes, if either recurs

Neither is filed, because one occurrence is not a pattern and a
speculative issue is worse than none. Both appeared on `gate (macos)`
during #218's landing, on reruns that then passed, and neither touched
the diff under test: a lock race in `packages/tui`'s `bootstrap_test`,
and a `conformance/simulation_test` seed that did not reproduce. **File
each the moment it happens a second time**, with both run URLs, rather
than rediscovering it. The nightly long soak's `seeds 1001..` band
(**#155**) is the standing example of the same shape.

### 7. Multiplayer, if it is wanted

Briefed in `docs/design-notes/multiplayer.md` (#222), from a cited survey
of the gateway rather than from assumption. More holds than the word
suggests: the gateway already fans every durable event out to every
attached connection, the storage seq gives N clients one total order, and
the single writer serialises every command, so the transcript is already
the lock. What is missing is everything about *who* — twelve measured
gaps, of which four need one `protocol-change` document. The brief's own
first decision is the load-bearing one: identity is a server-minted
principal bound to a token, never a name a client claims, because the
transcript is the durable record. It is a body of work, not an
afternoon, and it is listed last because nothing else waits on it.

### 8. After that

Phase 5 (**#25** LSP, **#26** DAP) is designed as extensions: a long-lived
JSON-RPC child the extension starts from `session_start` through
`cap/proc`, in the jail, which needs a `[proc]` manifest table granting
binaries and the toolchain in the jail's readable roots. **#18** (chaos
runner and ten-minute soak) is the only test that separates a rollback
from a leak and belongs with **#32** if the loader is ever built.
**#107** (async code mode) sits
outside every ladder with its design dossier on the issue. **#181**
(pluggable secret backends behind one `SecretStore`) is the follow-on to
the process-environment secret lookup extensions use today.

---

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record
the reopening where the ruling lives.

**One daemon hosts sessions across workspaces; restart restores only the
catalogue.** Open a session lazily when an authorized operator requests
it. Listing and preview never resume work. Concurrent opens for one
session share one runtime. The new default does not retain a legacy
server or protocol adapter, and existing user data stays untouched.
[The execution ruling](design-notes/single-daemon.md#execution-ruling)
supersedes the design note's historical migration proposal. These are
implementation requirements, not claims about the baseline server.

**A replay reproduces inbound traffic and rendering, and never an
outbound effect** (`docs/architecture/client.md`, "Recording and
replaying a session"). `tui.Peer`'s three variants are what make it
structural: a site that asked "is there a socket?" would take the demo
branch under a replay and invent what the live client never drew. The one
deliberate divergence is `/sessions`, which reads a local catalogue a
recording cannot carry and so answers with a notice instead; inventing
either live answer is the thing the type exists to prevent.

**The replay command still guarantees only its settled final frame.**
Tests can now inject the presentation clock and reproduce intermediate
frames. The command still uses the host clock, so `--at` and `--all`
remain tools for inspection; mapping recording offsets onto the injected
clock is separate work. A replay golden must still end settled.

**A footer's layout is a function of the window, never of its text.**
Measuring the rendered sections made the row count change mid-turn and
moved the prompt box under the operator's hands. Sections are capped and
the row count is decided from the width (#217).

**A throughput figure needs a window worth dividing by.** Under
`output_rate_min_ms` the footer shows no rate, because at that length the
quotient is request latency and stream batching rather than throughput
(#219).

**A jailed tool's `HOME` and `TMPDIR` live under `<workspace>/.codemode`,
and macOS grants the user's own temp and cache directories.** Apple's
toolchain shims write there whatever the environment says, and a `HOME`
that was the workspace made macOS build a `Library/` in the operator's
checkout (#218).

**Extensions run jailed by default, and reach the network through the
broker** (`docs/adr/007-extension-tiers-and-brokered-egress.md`,
`docs/design-notes/extension-architecture.md`). An installed extension has
one manifest and up to two bodies. A tool is always jailed; a hook is
harness-resident only when it cannot be jailed, because the risk is in the
hooks and not the tools. `net.request` is served by the broker making the
HTTP request on the host under a per-extension policy: https only, an
exact origin allowlist, a method allowlist, reserved and malformed headers
refused, TLS verified with session resumption off, same-host redirects
only, a streamed size cap, one monotonic deadline, and the credential
named in configuration, held by the harness, and absent from both the
jail and the channel.

**The install fetches an archive over the broker, never `git clone`**
(`docs/design-notes/extension-architecture.md`, "Hardening the install").
The source is fetched under a one-host egress policy, read by a total
tar.gz reader that refuses symlinks, `..`, oversize entries and off-host
redirects, pruned to the extension's own tree, vetted against the
extension seam ahead of the compiler, compiled offline inside the
code-mode sandbox, and pinned by the tree digest the record carries. The
record is written last and discovery re-digests, re-vets and fingerprints
the artifact on every boot.

**`prompt_snippet` is required, diverging from pi** (the design note's
status paragraph). A tool that would be silently unlisted is refused at
install, because an install is the one moment the author is present to
read the refusal.

**A persistent satellite per extension, and `hook_call` is the reverse
direction** (`protocol-change/012-hook-call.md`, ACCEPTED 2026-09-02;
`docs/design-notes/extension-architecture.md`, Decision 3). The satellite
lives for the session and computes between invocations but cannot act: a
cap-channel token is minted per invocation and revoked on the answer, one
invocation is outstanding per satellite, and a deadline destroys the node
rather than waiting on it. The node runs under its own operation, never
the first caller's, because the broker's abort of an operation cancels
every execution under it and code mode aborts its operation on every
teardown; the phase 3 review found that a host launched under a run's
operation died the first time `code_mode` ran in that run.

**The hook bus is a `weft/event_manager`** (the design note, "The hook
bus"; `packages/client/src/client/extension/hooks.gleam`). One handler
per installed extension in load order; notifications by `notify`, the
`tool_call` gate by `sync_notify` with any block winning, and the two
chained transforms, `context` and `tool_result`, as a fold rather than a
fan-out. The fan-out runs on a deadline-bounded weft worker, never on the
strand driver, because an unanswered `call` exits its caller. The
`Invoker` the bus is given must return inside its documented bound and
must never raise, because the manager is linked to the host process and
has no rescue; `hosts.invoke_event` meets that by construction and a
queued invocation that cannot answer inside its caller's window is
refused rather than started. A malformed verdict costs the handler its
place on the bus and is logged; it is never read as a policy.

**The TCB freeze is proven without a loader, and the resident seam is
derived from authority** (`docs/review/extension-zone.md`,
`packages/client/test/client/extension/freeze_test.gleam`). Two
mechanisms, both gated: `packages/ext` and `packages/cap` name no TCB
package and no module under them imports one, walked from the tree; and
the extension and resident vetting allowlists are pinned as exact sets and
shown disjoint from every module name the fourteen Gleam packages in the
harness VM ship. The resident seam is the extension seam minus every
module that reaches the broker, and which modules those are is derived
from the source walk (`ext/memory` today), not from a list somebody must
remember to extend; the beam import table is a subset of the source
imports, so authority is read from source. Two findings are handed to
#32 for the day a loader exists: an artifact check must be per-MFA, and
an extension may name its own module after a base module.

**An extension never overrides a built-in** (the design note, "The rest
of pi's surface, mapped"; `client/contributions.gleam`). A name collision
with an *active* built-in refuses boot. An operator who wants an
extension's tool to stand in for a built-in deactivates the built-in with
`LOOM_DISABLE_TOOLS`, which frees the name and nothing else: it is not a
capability control, and code mode's prelude still reaches `cap/proc.run`
and `cap/fs.write` through the broker.

**`before_compact` notes and never vetoes; `usage` is notify-only and
outside the replay rule** (`client/extension/hooks.gleam` and
`runtime/effects.gleam`). A compaction hook fires after the runtime has
decided to compact and before the summary generation, and may return a
note that lands fenced and attributed after the summariser's instruction,
bounded cumulatively across the gather; the compaction happens whatever
the hook does. `usage` fires from the one commit path after the writer
returns, on the strand driver's process, so the slot must never block; it
is at-most-once and covers the conversation ledger only.

**Notify-only events ride a second manager** (`client/extension/hooks.gleam`,
"Two managers"). A cast onto the same mailbox an answering event waits on
let one extension's slow `usage` handler spend the `tool_call` gate's
budget and turn another extension's block into a fail-open allow. The bus
now holds an `answers` manager for `sync_notify` events and a `notices`
manager for casts, built from the same extension list; a handler is
dropped per manager, and the module doc names the one case that does not
converge.

**Extension memory lives under a reserved `ext/` prefix the extension
never spells** (`client/extension/memory.gleam`, `runtime/api.gleam`).
`ext.remember`/`ext.recall` write and read last-write-wins cells at
`ext/<name>/<key>` on the durable blackboard; the prefix comes from the
installed record, the model's blackboard tool refuses `ext/` on both
write and read, keys are bounded leaves and values bounded JSON documents,
and there is no key-count ceiling because an install is an operator's
trust decision and the plane has no per-writer quota for anyone.

**The client surface is a different surface area** (the design note,
"The rest of pi's surface, mapped"). `user_bash`, `ui_prompt_*`, `ctx.ui`,
commands, shortcuts and flags belong to the TUI's own extension surface
under its own ruling, not to the harness vocabulary; the manifest reserves
a `[client]` table for it.

**Process machinery goes through weft, and `docs/weft.md` is the standing
guide.** Phases 1 through 3 of loom#159 are on `main`, and the hook bus
is the first consumer of `weft/event_manager`, which the adoption note's
census had said fit nothing in the tree. The page carries which shape
maps to which primitive, the nine rules a port is held to, and the
standing rejections. Weft does not shrink the tree: the adoption note
measured net +1,191 lines through phase 2 and a further +167 for phase
3, because an exhaustive `case state, message` matrix is larger than the
recursive functions it replaces. What it buys is one owner per race.

**The `noproc` claim rule, both halves.** The drain ledger installs its
monitor when it *handles* a claim, so the claim is made from a leaf owner
the scope adopts before releasing it
(`runtime/strand_runtime.claim_through`), pinned by
`restart_reap_test.reaper_claim_outlives_a_driver_killed_mid_claim_test`.
That ordering cannot be the ledger's only defence, because a claim reaches
the ledger as a message and a reaper that drains and exits in the gap can
be met no other way. `noproc` is what a monitor answers about a pid that
was already gone and never a reason a process exits with, so the ledger
reads it as a departure and retires that generation (#171,
`drain_registry_test.claim_naming_an_already_departed_reaper_retires_it_test`).
`Killed` and every other abnormal reason still fail the session closed.
The comment above the claim site in `strand_runtime.gleam` said the
opposite until this change; the test was right and the comment was stale.

**A model-created schedule may steer, but may not wake.**
`ModelSchedulesSteer` is the default; the addenda in
`docs/design-notes/scheduled-heartbeats.md` carry the argument, and
**#161** is the evidence: a fresh name is a fresh clock, so a woken model
can create the next schedule before this one expires, and the priority
order puts isolation before capability. None wakes an idle strand unless
the operator writes `[schedules] model_created = "wake"`.

**A schedule has an owner and a target, and lives no longer than its
target** (#163, #154). The owner is the strand that created it or the
operator; the target is the strand it fires onto and, with the name, its
identity. A strand may target itself or a strand it spawned, decided from
the lineage ledger and failing closed. Waking is for roots only whatever
the policy says: a subagent has one run, so a schedule onto any `sub:`
strand steers and holds. The scanner treats a reaped or settled target as
expired, a `run_end` reaper removes a settled child's cells, and cancel
retires marks, then the observation instant, then the config cell, so a
reused name inherits nothing.

**Expiry counts from first observation, not first fire** (#157), recorded
once under `schedule/seen/`. **Cron is UTC with at most a fixed offset**,
never a zone database; its first fire is its first match after the
schedule was seen, unlike an interval, which fires the slot it is created
inside. **No jitter**: one session is not a fleet. **`cap/schedule` stays
off the orchestration seam** (#156): minting a future turn is authority
`report.emit` does not carry.

**`AGENTS.md` and `CLAUDE.md` are both read, in that order** (#169).
`client/system_prompt.discover` fills two slots, a workspace file beats
both globals, and `AGENTS.md` renders first because it is the file every
other harness reads. Each file arrives in an `<instructions>` fence naming
its path and origin, and the default pack tells the model that at most
one `user-default` block exists and that it is always first.

**MCP is code-mode only, and the jail decision is open** (#106, #109).
Generated per-server capability modules, never a generic dispatcher,
because a generic dispatcher collapses the vetting bound to "the whole
registry, for every program". `mcp/transport.PortTransport` spawns the
server **unjailed** and its own module doc says so; `docs/architecture/mcp.md`
records the jail as an open decision. Do not let any document claim
otherwise.

**The ledger keys on `{op_id, step_id}`; paths key on `{op_id, step_id,
source_index}`** (ADR-005's addendum). `source_index` is absent from
`ExecIdentity` because adding it would mint one ledger per `code_mode`
call. The abort-epoch table is measured and not pruned.

**A host missing a code-mode prerequisite registers no `code_mode` tool at
all**, because a tool definition is a byte prefix of the provider's cached
region. Code mode ships in the main release artifact with
`DIST_CODEMODE=0` as the opt-out (`docs/distribution.md`).

**R3 and R8 will never gate, and R10's exemptions are the formatter's.**
The first two over-report by construction. R10 exempts a comment at the
top of a block and one between two constructor fields because
`gleam format` deletes a blank line in both positions.

---

**Frame pacing and etui's input batching compose**
(`packages/tui/src/tui.gleam`, `frame_decision`; `docs/performance.md`).
Etui applies up to sixty-four immediately ready events before drawing again.
The tui still paces because each event passes through `update`, where Loom
maintains the completed-frame cache, and longer input runs can cross etui's
batch boundary. A stale frame is rendered at most once every 16 ms while paced
events keep arriving, the rest is recorded as `FrameDeferred`, the tick after
the drained queue flushes it, and the poll wait is 8 ms while a frame is owed.
The view never renders on its own; it shows whatever the event handler last
cached for the screen.
The original one-off 200×50 pseudo-terminal measurement reported that forty
wheel events went from forty frames and 250 KB to three or four frames and
20 KB; its harness was not committed, so those figures are historical rather
than a reproducible baseline. `make bench-tui` now keeps the panel optimization
measurable in-tree and also compares the old and bounded input policies. On
OTP 29 and Gleam 1.18.1, three runs put the 200×50 panel pair at 0.171 to
0.177 ms through etui's block and 0.084 ms through the border-only path.
Rebuilding a Loom-style frame took 43.10 to 44.57 ms per forty-event old-style
burst and 1.94 to 1.96 ms per bounded burst.

## Deliberately open

Named, with an issue where one exists. None of these is unfinished work
somebody forgot.

- **The TUI reads the wall clock in five places**, so a scripted run
  cannot own time and only a replay's last frame is reproducible. The
  injected clock is the first item of the simulator work above, not a
  loose end.
- **Loom's state directories sit in the workspace, untracked.** A jailed
  `git status` warns `could not open directory '.blobs/'` because the blob
  store is protected by design. Whether `.blobs` and `.codemode` should be
  excluded at boot, or live outside the workspace entirely, is undecided
  and unfiled.
- **The client plane has no TLS and one all-or-nothing bearer token.**
  Documented in `docs/architecture/client.md`; it is a prerequisite for
  multiplayer *between machines* over `--addr`, and is deliberately not
  folded into the multiplayer brief.
- **`deny` on an escalation is not CAS-guarded** where `approve` is, so
  two clients racing approve and deny have no ordering on the deny side.
  Harmless with one operator, which is why it is open rather than fixed.

- **The MCP server jail** (#109). Undesigned, not unbuilt. `mcp/transport`
  is the seam an answer attaches to.
- **The rest of MCP's v1 cuts**: HTTP transport plus OAuth (#108), an
  end-to-end against a third-party server from the wild (#110),
  elicitation (#111), `listChanged` (#112).
- **Extension secrets come from the process environment.** An extension's
  `[[net.secret]]` names an environment variable the server reads and the
  broker injects into the request; there is no vault, keychain or command
  backend. That is **#181**, filed after the design settled on one
  `SecretStore` seam, and it is undesigned in the sense that the seam's
  shape is the open part.
- **The tier-H loader** (#32). Deferred, not refused: nothing in the
  surveyed pi ecosystem needs in-VM residency, and every hook is
  expressible in the jail. The vetting seam a resident body would start
  from is pinned by the freeze test, and the review record hands the
  loader two findings to build against. It reopens when a resident
  consumer appears.
- **A producer for `agent_settled`.** The manifest accepts it and the bus
  carries it; nothing in the harness fires it, and a declaration is
  logged inert at boot rather than left to look as if it fired.
- **A local jailed e2e on macOS.** `make codemode-seed` on this host
  produces a seed whose clone re-resolves inside the jail, so every real
  jailed install is `BuildUnavailable` locally and the extension e2e
  skips; CI's Linux and macOS runners build a working seed. Until the
  seed script verifies the offline build on Darwin, the gate for a change
  to the install or satellite path is CI, and a local green on those
  suites is a skip, not a pass.
- **Per-extension serialisation of invocations.** The host registry is one
  actor whose mailbox is the queue, so two different extensions invoked
  from two strands at once wait on each other. The module doc names the
  case and the per-extension lease that fixes it, to be built when the
  case is measured rather than imagined.
- **`[proc]` grants for extensions**: the jail's readable roots would need
  the toolchain and the manifest would need to name which binaries an
  extension may run. This is what phase 5 (#25, #26) is blocked on, and it
  is undesigned.
- **Nested `AGENTS.md` files** are not read (#172). `Host.guidance` is one
  string fixed at session open; per-edit precedence needs a per-tool-call
  channel, which is a question about the two-channel doctrine before it is
  a build.
- **`cap/task` on weft.** `cap` is the satellite-side prelude with no weft
  dependency, and adding one puts weft into the offline build seed. That is
  a distribution decision.
- **One weft gap upstream**: a monitored, non-panicking call against a
  pre-existing pid, which `broker/internal/call.try_call` and the host
  registry's `ask` still hand-roll.
- **The residual `runtime` interleave flake**: the `tools` scenario's
  boundary count, pinned at 14 in `interleave_test.gleam`, reported 13
  about four times in a thousand under the previous edition's stress
  runs. Two parallel tool calls whose results arrive together look like
  the cause; relaxing the pinned count is the owner's call.
- **Playbooks** (#139). An installed extension's `skills/**` is already
  part of the installed subset, so the storage half exists; what does not
  is the server surfacing name, description and location in the system
  prompt. Track it on the extension route rather than building it twice.
- **Scheduling**: the review's eight filings are answered (#162, #164,
  #157, #163, #154 fixed; #156 ruled; #165 landed on both sides; #161
  stays closed as ruled), cron and a relative one-shot are on every door,
  and the `schedules`/`schedule_cancel` commands give the operator a live
  surface. Still open, and named where it lives: an operator table with
  `wake = true` onto a *live* subagent can wake it until the brief
  settles; the model ceiling can over-admit by up to `max_outstanding`
  under a code-mode fan-out; the scanner's settled-target check reads the
  strand result through the writer, one round trip per subagent-targeted
  schedule per tick. **weft 0.4.2 is not on hex**: the eight consumers
  point at `../weft` (path dependency, as the phase-3 branch did) and the
  last commit before merge switches them back to `>= 0.4.2 and < 1.0.0`;
  until the release is published that resolution step is red, which is
  expected.
- **Egress for the shell tools is all-or-nothing.** `[tools] network =
  "full"` in `loom.toml` opens the jail's network for `bash` and `grep`,
  per catalogue and by the operator alone; there are no allow or deny
  lists behind it, because host-level filtering needs the egress proxy
  the spec defers and a config key that accepted hosts would promise
  filtering nothing enforces.
- **Compaction stages C1/C2 and memory stage M3** are out of the release
  by design and have no issue.

---

**Etui now batches queued input.** The pin at `702a884` applies up to
sixty-four immediately ready events before a buffered loop draws again. Loom
retains its pacing because each event still passes through `update`, where the
completed frame cache is maintained, and longer input runs can cross the batch
boundary. The remaining upstream follow-up is allowing `block.render` to skip
its interior clear when a caller has already painted the area. Loom already
uses `render_panel_border`, whose test pins the bytes, so that API would remove
local code rather than provide another client-side speedup.

## How to verify

`make help` lists the commands. `make check` is the full gate and is
exactly what CI runs; `make check-<package>` narrows it; `make doc-check`
checks the doc graph and the citations; `make lint` is the house-rule
lint; `make selftest` says which enforcement layers the kernel actually
provides; `make e2e` and `make e2e-codemode` are the jailed end-to-ends
(`make codemode-seed` prepares the offline cache the second needs, and
the extension e2e refuses a stale seed until it is rebuilt).

Five hazards, each of which has cost real time here.

**Verify a gate by its own exit code.** `make check > log; echo $?; tail
log` reports `tail`'s status and has produced confident false greens here
more than once, including one in this week's extension work. Capture
`make`'s status directly into the log, then read the log for failures.

**`make check-<package>` does not run lint, and a failing package never
reaches lint either.** `scripts/check.sh` runs the lint only when it is
given no package arguments, and it runs it last under `set -e`. `make
doc-check` is a separate target that `make check` never runs, and in CI it
is a separate step after the gate, so a green `make check` with a red
doc-check is the ordinary way a PR fails: three citation line numbers
drifted on #200 after its author's last doc-check, and it cost a CI
round. Run `make doc-check` on the final tree, after the last commit.

**A fresh worktree can fail on Hex rather than on your diff.** A new tree
resolves every package's dependencies from scratch, and enough parallel
requests hit the Hex API rate limit; it presents as a build failure with
nothing to do with the change. Wait and re-run before diagnosing.

**Do not put a verification worktree under `/tmp`.** Code mode correctly
refuses a cap socket there, because the jail replaces `/tmp` with the
scratch tmpfs, and `/tmp` also breaks `make codemode-seed` discovery. Put
it beside the repository and remove it when done.

**A PR that conflicts with `main` gets no CI at all.** GitHub cannot
compute the merge ref, so the checks never start and `gh pr checks`
reports nothing rather than a failure. Rebase first; #199 sat with no
checks for an hour because of a one-file docs conflict.

Two more belong to the tree rather than to the gates: a long-lived tree's
incremental build cache can produce a deterministic failure in a package
the diff never touched, so check a fresh-worktree control before calling
it a flake; and `make gen-prelude` and `make gen-sql` produce committed
artifacts the build gates rather than regenerates, so changing
`packages/cap`'s public surface without regenerating fails
`make prelude-check`.

`docs/execution.md` is the rest: how a wave is planned, how sub-agents are
briefed and monitored, the standard of proof, and why a correction goes on
the issue rather than only in a commit.

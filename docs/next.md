# Next

Read this first for current work, settled boundaries, and remaining acceptance.
Rewrite it after the next body of work. Detailed review and measurements belong
in their own documents.

Re-baselined September 12, 2026 against merged main `87df00a5`. Since the
previous edition, the native Herdr integration (#354) and the imported
Claude-hooks compatibility layer (#355) are merged, each on a green
`signoff/linux` at its exact head: #354 at `759080b0` (main `a39a6a5f`) and
#355 at `ed6349f1`. The next work is the follow-ups those two left named
rather than implied, and the Escape cancellation proof-delivery race.

## Where the tree is

| Body of work | Current state |
|---|---|
| Human controls | Queue editing, priority steering, worktree observations, and completion summaries are merged in #344. |
| Markdown skills | #346 is merged; discovery, explicit activation, paged completion, and model-selected loading are shipped. |
| UX polish | #347 and its reading follow-up #349 are merged. |
| Streaming tool output | Merged in #348 (`6a484a4f`). A running `bash`/`grep` call's bounded output tail reaches the terminal while it runs: collector observer, `Outputs` bus topic, pushed `tool_output` frame, one `ToolTail` per stream ([protocol 031](../protocol-change/031-tool-output-stream.md), issue #186). |
| Context usage | Merged in #351. `/context`, `/context all`, and a persistent `ctx ~N%` footer; the server captures the active strand's configuration and immutable history, so the count is independent of scrollback retention ([protocol 030](../protocol-change/030-context-observation.md)). |
| Escape and held input | Merged in #352. An explicit abort now admits every message held for that strand into one successor run, not just the first ([protocol 032](../protocol-change/032-abort-held-batch.md)). |
| Transcript reading and drafts | Merged in #353. A reading viewport is preserved even at offset zero, expanded tool results keep the compact call's anchor, bracketed paste inserts at the cursor without replacing a draft, and an aborted turn renders as Stopped with its diagnostic visible. |
| Herdr integration | Merged in #354. The terminal reports idle, working and blocked to a Herdr pane over its unix socket, sequenced from the wall clock, announcing the session when its identity is first known and on every switch. `done` is Herdr's own derivation from an idle report on an unseen tab and is never sent. |
| Imported hooks | Merged in #355 (issue #350, first wave). A Claude Code hook collection loads unchanged from the operator's `~/.claude/settings.json`, trusted on first sight and re-reviewed on change; the composed gates fire at run start, tool clearance (after the harness's own, with a rewrite re-cleared), the result fold, the summarizer, and run end. A committed acceptance fixture boots a real instance and proves each gate fires. |
| Advisor strand | Merged in #NNN (issue #137, phase 1). A catalogue that routes an `advisor` role gets a second strand beside `main`, created by the harness rather than by the Agency, that reads a rendering of what `main` did since a stored cursor at each of its run ends and answers with one `advise` call: `quiet`, `nudge` folded into `main`'s next run start, or `block` delivered now. An emission guard downgrades a block inside its cooldown and drops advice already given. Unrouted, nothing is created. |
| Release dependencies | SQLite, hosted latency, joined fault/pressure coverage, schedules, and memory-off observations retain their separate issue acceptance. |

### Corrections to the previous edition

The previous handoff (September 11) was written before #348 merged and called
for landing it as the next step; it is merged at `6a484a4f`. That edition
predates the UX series, which was reviewed adversarially, fixed, signed off, and
merged on September 12. During that series the Escape "cancellation could not be
confirmed" report was diagnosed: it is a proof-delivery race, not a failed stop
(see "Deliberately open"). The previous edition's verification block referenced
tool-output test matches that are now merged; the block below is refreshed.

The previous edition listed #354 and #355 as the next work. Both landed after
adversarial review found defects the original branches' own tests could not
see. #354 encoded a `done` state Herdr's request schema rejects and seeded its
sequence from the monotonic clock, which is negative on this platform, so every
report failed validation; a schema-validated drive through a unix-socket
listener found both. #355's composition layer had never run: its merged
configuration never reached the wiring, its environment requirement was never
granted by the jail, and its trust pin was inert; it is reworked and proven by
a committed session-level fixture rather than the shell demo it shipped with,
which could not run.

### The UX series and its verification

Three PRs landed after one adversarial review each (Opus), every finding
verified against the code before acting:

- **#351 context usage.** The inspector and footer read the server's captured
  configuration and branch, never presentation state. Review removed a
  redundant eight-MiB encode guard (the 4096-entry scan and the board's
  47,000-byte budget already bound the read) and moved the footer refresh from
  once per committed entry to the operation boundary, so a long turn no longer
  starts a server-side scan per entry.
- **#352 held input after abort.** The held queue owns its drain policy as a
  two-variant type, so an emptied queue drops its batch intent and a later idle
  transition cannot inherit it. The empty-queue-at-abort arm is deliberate
  (protocol 032) and pinned by a regression.
- **#353 transcript reading.** The load-bearing fix: an aborted turn keeps the
  "Stopped" headline and shows its diagnostic beneath it, because a clean abort
  carries no diagnostic and the only aborted turns that carry text are the ones
  the harness could not confirm. The shipped multiplayer fixture no longer
  asserts on the last-writer-wins `notice` scalar; it observes the refusal by
  the attempt lifecycle, which survives a render cut.

Each PR was rebased current, re-signed off green on its exact merged head, and
verified live against a real provider (GLM 5.3): the context footer and
inspector with a provider-total update, held input batching into one successor
after Escape, and an aborted turn rendering Stopped with a visible diagnostic.

## What to do next

1. **Finish the imported-hooks layer's follow-ups.** The matrix names them:
   the `loom hooks trust` command, without which project and local sources can
   never be approved (the trust module already has `trust`, `revoke` and
   `scan`; the CLI is surface beside `loom ext`); the prompt-admission seam
   (`UserPromptSubmit`), which touches surfaces protocol 024 froze and may need
   a `protocol-change/NNN.md`; and asynchronous hooks on the job plane.
   **Exit:** each as its own PR with a regression and a matrix row moved from
   follow-up to tested.

2. **Carry the advisor's phase-1 deferrals.** Each is named in
   `docs/architecture/advisor.md` with what it waits on. The **awaited run-end
   hard block** — holding the run boundary open until the advisor answers —
   waits on counts of how often `block` fires and how often the re-wake came
   too late; the machinery for an awaited run-end key already exists in the
   assistant path, so this is an evidence question rather than a build one.
   **Extraction to an extension** waits on two capabilities the satellite does
   not have: a transcript read on the cap prelude, and an `AgentEnd` hook that
   carries more than an operation id. A **code-mode `cap/advise`** surface, a
   **brief override file** in place of today's constant, and **advisor status
   in the terminal** — the branch is reachable through the strand list, but
   nothing reports that a review is in flight or when the last verdict landed
   — are each their own small piece. **Exit:** counts recorded on #137 before
   the hard block is built; each of the other four as its own PR with a
   regression.

3. **Land the Herdr-side half.** The Herdr repo needs the `Loom` registry
   variant, the `("herdr:loom", "loom")` resume-plan entry mapping to
   `loom --session <id>`, and the schema enum; the wire contract this tree
   speaks is the one Herdr's schema already defines. **Exit:** a pane opened
   onto a loom session resumes by its announced id.

4. **Fix the Escape cancellation proof-delivery race.** A plain Escape can
   commit `Aborted` with "provider cancellation could not be confirmed" even
   though the provider did stop. The smallest fix is in the client provider
   relay: deliver the owner-authored terminal on entry to `ProvingTerminal` and
   gate only the relay's own retirement on drain, mirroring the runtime
   custodian. **Exit:** the two-line relay change, a `protocol-change/010`
   addendum, and a regression that commits `Aborted` with the confirmed text
   under a delayed-owner-exit fixture. This is a runtime change, separate from
   the UX series.

5. **Keep release dependencies explicit.** **#247** owns SQLite, **#241**
   hosted macOS latency, **#246** the shipped authority/fault/pressure matrix,
   **#244** schedules and timer recovery, and **#245** memory-off evidence.
   **Exit:** each issue's own acceptance on the final dependency set.

6. **Keep maintenance follow-ups narrow.** **#248** tracks dependency
   re-resolution, **#296** bundled ERTS in jailed PATH, **#286** refused
   extension visibility, **#283** idle helper retirement, and **#345** the etui
   fork stack. **Exit:** reproduce the specific symptom before changing its
   owner.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Context inspection reads captured state, never presentation.**
[Protocol 030](../protocol-change/030-context-observation.md) captures the
active strand's configuration and immutable history through the bounded
observation workers and rechecks authority before delivery. The headline reuses
the latest usable provider total plus estimated newer messages; component counts
are independent estimates, never summed into a provider total. The read is
bounded by a 4096-entry scan and a 47,000-byte board. The footer refreshes at
the operation boundary, not per committed entry; manual `/context` forces a read.

**An explicit abort admits the whole held queue.**
[Protocol 032](../protocol-change/032-abort-held-batch.md) marks the strand's
existing held queue to drain as one batch after the aborted operation retires,
preserving each message's content, images, and author in FIFO-within-priority
order. An empty queue at abort carries no batch intent, so input typed inside
the cancellation window keeps the one-head drain. Ordinary completion and
steering retain their existing ordering.

**Queue edits do not resubmit.** [Protocol 024](../protocol-change/024-edit-queued-input.md)
keeps FIFO position, priority, author, timestamp, and images while comparing
held ID and revision in the gateway actor. Only the currently mutable original
principal can fetch or edit. A stale or drained item conflicts. Queue lifetime
is transient under protocol 018.

**Worktree observation is owner-scoped and bounded.**
[Protocol 025](../protocol-change/025-worktree-observation.md) uses the attached
workspace's final policy and existing broker, demoting filesystem grants to
reads, running Git outside the handler through Weft, and rechecking authority
before a push with no `reply_to`. A pinned HEAD plus later reads is not an atomic
snapshot.

**Committed changes require a durable starting revision.**
[Protocol 029](../protocol-change/029-session-commit-observation.md) captures
HEAD before the runtime starts on first activation and keeps it across restarts.
A clean working tree does not imply no commits since session start.

**Completion evidence and current jobs have different timestamps.**
[Protocol 026](../protocol-change/026-live-jobs-observation.md) queries the jobs
actor explicitly. Ordinary conversation refreshes neither scan job history nor
invoke Git; the terminal attributes history only between an observed operation
source and its result leaf.

**One daemon, explicit activation.** The
[execution ruling](design-notes/single-daemon.md#execution-ruling) keeps listing
and preview from resuming work. [ADR-009](adr/009-record-terminal-attempt-custody.md)
and [ADR-010](adr/010-retain-one-unsent-terminal-command.md) retain attempt
identity and one unsent command without retrying uncertain mutations.

**Original custody evidence decides retirement.**
[Protocol 014](../protocol-change/014-helper-shutdown-witness.md) retains the
native port until observed exit. Timeout, closed channels, and late `noproc`
are not cleanup proof. Normal code-mode teardown remains scoped to
`broker.abort_step`; operation-wide abort keeps its separate meaning in
[ADR-005](adr/005-budget-pooling-granularity.md).

**Authority and jail roots remain server-owned.** Protocols
[015](../protocol-change/015-daemon-control-and-session-attachments.md),
[016](../protocol-change/016-record-human-origin.md), and
[020](../protocol-change/020-minimal-jail-root.md) own activation, origin, and
jail roots. Host reads and tool networking are the development default; workspace
writes and protected masks remain. Read-scope and network flags independently
select lockdown.

**Portable decisions and process ownership keep their boundaries.**
`core`, `machine`, and `prompt` remain free of I/O and external functions.
Process machinery follows [the Weft mapping](weft.md).

**Skill metadata precedes instructions.** [Protocol 027](../protocol-change/027-markdown-skills.md)
shares one captured catalogue between the terminal and model. The model sees
names and descriptions until `load_skill` selects a document; loading grants no
new tool permissions.

**Imported hooks run in the session's jail, and that is accepted.** A
hook from an imported Claude Code collection runs under the session's policy
and environment, never with the user's full permissions; `CLAUDE_PROJECT_DIR`
names the workspace, and `transcript_path` names the SQLite file rather than
a JSONL transcript. Both differences are recorded in the parity matrix with
their reasons. A leading `~` is **not** one of them: the hook process runs
with `HOME` set to the operator's own home, so the shell resolves `~` where
the operator keeps their scripts, and nothing rewrites the command string. The accepted formats are the Claude JSON
shape verbatim plus a native `[[hooks.Event]]` TOML layer, sources merged
rather than replaced, with hash-pinned trust per source.

**Herdr reports only the states its request schema accepts.** The reportable
set is idle, working and blocked; `done` is derived by Herdr from an idle
report on an unseen tab and is never sent. The report sequence is seeded from
the wall clock, since the BEAM monotonic clock is an arbitrary-offset counter
that is negative on this platform and the schema types `seq` as unsigned. The
reporter is a plain in-order queue, deliberately not a superseding one: Herdr
drops out-of-sequence reports on its side, and the unlinked reporter never
stalls the terminal.

**The advisor is a peer of main, never an Agency child.** It is created
through `api.create_idle_strand` rather than through the Agency, so it carries
no `lineage/` cell: `main` cannot address it, it can address nothing, and
`strand.roster` does not list it. That absence is the whole of the isolation,
and it is why the advisor must never be spawned through `cap/strand` or the
`agent_*` tools. Three consequences are settled with it. The `block` verdict is
**asynchronous** — the primary is woken with the concern, not held at its run
boundary — because a hook slot is a synchronous function on the strand driver
and a provider round trip in one would stop the driver serving `Nudge`,
`RequestAbort` and `PollTick`; the awaited form is deferred behind counts. The
**emission guard is harness policy, not prompt instruction**: a cooldown
counted in the primary's runs and a ring of delivered digests are decisions the
harness makes and the model is told about afterwards, in its tool result, which
is the same split the broker draws between what a model may ask for and what it
is granted. And the advisor's standing brief is **transient**, prepended per
request through the `context` hook and never stored, so the advisor's own
compaction cannot lose it and its request head stays byte-stable for the
provider's prompt cache. `docs/architecture/advisor.md` is the document of
record.

**Only the gate posts Linux signoff.** `scripts/signoff.sh` owns the verdict
for a pushed commit. Never post success by hand or treat an older commit's
signoff as evidence for a changed tree.

**Failure context does not replace drain proof.** [Protocol 028](../protocol-change/028-provider-failure-context.md)
preserves bounded local causes and request bounds through cancellation. Context
is redacted before persistence, classification uses the underlying error, and
unconfirmed cleanup remains terminal.

**Running tool output is display state on the bus, not a hint.**
[Protocol 031](../protocol-change/031-tool-output-stream.md) carries a running
call's bounded output window as the `Outputs` topic's `ToolOutput` and the
pushed `tool_output` frame. Every event is the whole window, so receivers
replace rather than append; the durable tool result stays the truth.

**History retention is a payload bound.** Older pages retain at most 600 entry
descriptors and 16 MiB of encoded payload. Source identity anchors the viewport;
selected transcript cells stay frozen while live metadata progresses. In a
reading viewport, Reading mode owns the endpoint even at offset zero, so
returning to live output is an explicit End or click, not a consequence of
scrolling to the newest row.

## Deliberately open

None of these is unfinished work somebody forgot.

- **The Escape cancellation proof-delivery race** (item 4 above) has a diagnosed
  root cause but no fix yet. The #353 presentation stands on its own: it renders
  the retained diagnostic honestly rather than hiding it.
- **Live daemon CPU attribution** from the September 11 inspection is
  unresolved. A read-only native profile found sustained cost in UTF-8/binary
  construction and garbage collection; the exact Gleam caller is not established,
  and neither SQLite nor a leak has been shown to be the cause. The session
  database held only about 5 MiB of entry payloads, which does not account for
  the resident memory.
- **Repeated file reads** in the September 11 session were distinct
  model-authored calls with successful results, not duplicated terminal output.
  The model omitted the offset, recognized its own loop, then supplied the
  offset. No tool retry or read-suppression change is warranted.
- Completion remains latest-wins. A missed operation start or evicted ancestor
  makes captured evidence partial; the terminal does not invent a complete turn.
- The worktree pane presents bounded observations, not an atomic snapshot,
  filesystem watcher, staging interface, or commit action.
- **#243** remains the shipped approval-policy question; **#85** remains optional
  microVM work.

## Known flakes

The parallel-runner gate has a small residual flake rate tracked on **#335**
(closed on its fix but recording recurrences): the `serve_test` provider-wiring
instance turn and a conformance `run/terminated` seed. Both recurred once on the
September 12 #351 signoff and cleared on an honest re-run with no code change.
The rule stands: one re-run plus a note on #335; never re-run until green
blindly, and never admin-merge past the gate for a code change. History-index
issue **#324** is closed and fixed. The provider-wiring instance turn recurred
once more on the #355 signoff and cleared on the bounded re-run; the same run
exposed a genuine fixture-hygiene race in `hooktrust_test`, fixed with
per-test directories, which is the distinction the rule exists to force.

## How to verify

```sh
make check
make doc-check
make codemode-seed
make release-smoke
bash scripts/test.sh tui --match context_view
bash scripts/test.sh tui --match tool_activity
bash scripts/test.sh tui --match history_view
bash scripts/test.sh tui --match markdown
bash scripts/test.sh client --match context_view
bash scripts/test.sh client --match gateway_test
bash scripts/test.sh client --match domain_observation
bash scripts/test.sh client --match protocol_conformance
bash scripts/test.sh client --match tool_output
bash scripts/test.sh client --match advisor
bash scripts/test.sh tools --match advise
bash scripts/test.sh tui --match advisor_view
```

The full local gate ran with the real native helper and prepared code-mode
seed. Platform-specific prerequisites and opt-in shipped bootstrap fixtures keep
their own coverage; an ordinary package pass does not imply Linux shipment
acceptance. The Linux signoff runs `scripts/signoff.sh` on a pushed head.

**Capture each command's own exit status.** A successful log reader is not a
successful gate. **Use one build/gate at a time per checkout.** Keep enforced
code-mode worktrees outside `/tmp`, where the jail replaces sockets with scratch.
See [execution](execution.md) for the remaining operational rules.

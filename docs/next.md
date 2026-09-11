# Next

Read this first for current work, settled boundaries, and remaining acceptance.
Rewrite it after the next body of work. Detailed review and measurements belong
in their own documents.

Re-baselined September 12, 2026 against merged main `7ea66bdb`. The streaming
tool-output work (#348) and the three-PR UX series (#351, #352, #353) are all
merged; the previous edition described #348 as pending and predates the series
entirely. Each of the four merged on a green `signoff/linux` at its exact head:
#348 at `6a484a4f`, #352 at `178e701f`, #353 at `eff46b43`, #351 at `7ea66bdb`.
The next bodies of work are the native Herdr integration (#354) and the imported
Claude-hooks compatibility layer (#355).

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
| Herdr integration | PR #354 on branch `herdr`, not yet merged. The terminal reports its lifecycle to a Herdr multiplexer over a unix socket when launched inside a Herdr pane (issue #140). |
| Imported hooks | PR #355 on branch `hooks/claude-compat`, not yet merged. A compatibility layer that runs imported Claude Code hooks unchanged. |
| Release dependencies | SQLite, hosted latency, joined fault/pressure coverage, schedules, and memory-off observations retain their separate issue acceptance. |

### Corrections to the previous edition

The previous handoff (September 11) was written before #348 merged and called
for landing it as the next step; it is merged at `6a484a4f`. That edition
predates the UX series, which was reviewed adversarially, fixed, signed off, and
merged on September 12. During that series the Escape "cancellation could not be
confirmed" report was diagnosed: it is a proof-delivery race, not a failed stop
(see "Deliberately open"). The previous edition's verification block referenced
tool-output test matches that are now merged; the block below is refreshed.

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

1. **Land the native Herdr integration.** PR #354 on `herdr` teaches the
   terminal to report its lifecycle (`pane.report_agent_session`, then
   `pane.report_agent` across idle/working/blocked) over the Herdr unix
   socket, gated by `HERDR_ENV`/`HERDR_SOCKET_PATH`/`HERDR_PANE_ID`. The adapter
   is compiled in rather than installed, because the terminal is a single binary
   with no plugin directory. One new FFI, `tui/internal/ffi_herdr.exchange`, a
   deadline-bounded `gen_tcp` unix round trip. **Exit:** adversarial review,
   rebase onto current main, Linux signoff on the exact head, then merge. The
   Herdr-side registry change is a separate change in the Herdr repo.

2. **Land the imported-hooks compatibility layer.** PR #355 on
   `hooks/claude-compat` runs imported Claude Code hooks unchanged (issue
   #350, first wave): the pinned contract, the design note, the parity matrix,
   and six client modules. **Exit:** adversarial review, rebase, Linux signoff
   on the exact head including the jailed `hookrunner` fixtures and the demo
   in `docs/fixtures/hooks-compat/`, then merge. The matrix's follow-up rows
   are the next waves, not part of this exit:
   - the prompt-admission seam (`UserPromptSubmit`): the harness has no moment
     where a queued prompt can be inspected or rejected before admission; the
     decision layer already reads the answers, the gateway slot is missing, and
     it touches surfaces protocol 024 froze, so it may need a
     `protocol-change/NNN.md`;
   - a `loom hooks` CLI (list, trust, revoke, convert over the trust root);
   - asynchronous hooks, whose natural shape is the job plane with delivery at
     the next safe point.

3. **Fix the Escape cancellation proof-delivery race.** A plain Escape can
   commit `Aborted` with "provider cancellation could not be confirmed" even
   though the provider did stop. The smallest fix is in the client provider
   relay: deliver the owner-authored terminal on entry to `ProvingTerminal` and
   gate only the relay's own retirement on drain, mirroring the runtime
   custodian. **Exit:** the two-line relay change, a `protocol-change/010`
   addendum, and a regression that commits `Aborted` with the confirmed text
   under a delayed-owner-exit fixture. This is a runtime change, separate from
   the UX series.

4. **Keep release dependencies explicit.** **#247** owns SQLite, **#241**
   hosted macOS latency, **#246** the shipped authority/fault/pressure matrix,
   **#244** schedules and timer recovery, and **#245** memory-off evidence.
   **Exit:** each issue's own acceptance on the final dependency set.

5. **Keep maintenance follow-ups narrow.** **#248** tracks dependency
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
and a leading `~` mean the workspace, and `transcript_path` names the SQLite
file rather than a JSONL transcript. Both differences are recorded in the
parity matrix with their reasons. The accepted formats are the Claude JSON
shape verbatim plus a native `[[hooks.Event]]` TOML layer, sources merged
rather than replaced, with hash-pinned trust per source.

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

- **The Escape cancellation proof-delivery race** (item 3 above) has a diagnosed
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
issue **#324** is closed and fixed.

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
```

The full local gate ran with the real native helper and prepared code-mode
seed. Platform-specific prerequisites and opt-in shipped bootstrap fixtures keep
their own coverage; an ordinary package pass does not imply Linux shipment
acceptance. The Linux signoff runs `scripts/signoff.sh` on a pushed head.

**Capture each command's own exit status.** A successful log reader is not a
successful gate. **Use one build/gate at a time per checkout.** Keep enforced
code-mode worktrees outside `/tmp`, where the jail replaces sockets with scratch.
See [execution](execution.md) for the remaining operational rules.

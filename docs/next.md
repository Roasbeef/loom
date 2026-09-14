# Next

Read this first for current work, settled boundaries, and remaining acceptance.
Rewrite it after the next body of work. Detailed review and measurements belong
in their own documents.

Issue #383 is implemented on `fix/cli-help`. The shipped `loom` and `loomd`
launchers answer top-level and subcommand help before terminal or daemon
startup, including extension help without an installed server. The shipped
help acceptance, 475 TUI tests, and 1,792 client tests passed locally, and
the independent review findings are resolved. Hosted CI and Linux signoff
remain outstanding. The broader shipped multiplayer fixture fails locally
on both this branch and its unchanged base, `7635d029`: the provider rejects
the latest-message shape, then the terminal wait expires. That baseline
failure remains open; the help acceptance is independently green.

The September 14 scrolling work is recorded in
[Transcript scrolling](review/scroll-presentation-2026-09-14.md): PR #401
removes repeated history-anchor projection, and the etui fork implements
scroll-region presentation for #367. The package docs describe the pinned
renderer. The broader project audit below remains the September 13 snapshot;
its unrelated status claims have not been re-audited for this change.

The September 14 model-selection change is scoped in
[protocol 034](../protocol-change/034-agent-model-selection.md).
`agent_spawn` can select a configured catalogue name and report the child's
durable model; `cap/strand.with_model` carries the same choice in code mode.
The broader audit below remains the September 13 snapshot and has not been
re-audited as part of this change.

Re-baselined September 13, 2026 against merged main `10b77fc4`, the merge of
`cap/search` (#378, closing issue #365) on a green `signoff/linux` at its exact
head `374f6362`. At that audit, every claim below was checked against the tree, the cited
issue or PR, or a command run against this commit — not carried forward from
the previous edition. That matters here more than usual: the previous edition
said it was baselined against `87df00a5`, but its own table already described
the advisor strand (#360) and terminal parity (#366) as merged, work that
lands later in the log. Those rows were kept accurate by being amended inside
the feature branches that carried them, commit by commit, rather than by a
fresh rewrite at the end — exactly the append-instead-of-rewrite failure mode
this file exists to avoid. This edition is a full rewrite, checked line by
line against the tree at `10b77fc4`.

Since that stale baseline, three bodies of work reached main: the advisor
strand's phase 1 (#360, already reflected in the previous table), vision
routing (#362, closing #358), and `cap/search` (#378, closing #365, the work
this rewrite follows). Two unrelated defects were also found and fixed on
main in the same window, independent of any of the three: a busy-refusal race
in `loom-exec` between the exit frame it writes and the state it reports
(#375), and two imported-hook test fixtures asking Linux for enforcement
tolerance no jailed fixture in the tree actually gets (#376). Neither opens
new work; both are folded into "Corrections to the previous edition" below
because the previous edition's picture of a fully green tree predates them.

## Local diagnostic installation (September 14)

The `build/diagnostic-install` branch starts from `4c266dde` and adds
`make install-debug`. It preserves BEAM debug chunks, skips stripping the
bundled ERTS/toolchain, and supplies OTP profiling modules plus the memory
census. The normal launcher remains undistributed. A debug launcher enables
a loopback node only when `LOOM_DEBUG_ARGS_FILE` is supplied; the credential
setup and attachment commands are in `docs/distribution.md`.

The complete install target passed under a separate prefix. The server and
client release smokes passed, and an installed diagnostic daemon accepted an
observational memory census with allocator accounting. The probe also verified
BEAM debug chunks, profiler availability, loopback configuration, removal of
the startup environment variable, and Loom's own `tools` application metadata.
The existing user daemon was neither replaced nor restarted. Its roughly
3 GiB OS footprint remains unattributed at the BEAM-process level; profile a
named diagnostic instance before proposing a memory fix. These packaging
checks are not a full `make check` or a Linux signoff.

## History prefetch (September 14)

Reading history starts the next fetch two transcript viewport heights before
the oldest loaded row. Both wheel input and idle demand use that threshold;
the existing single pending request, hundred-position page, and retained
window bounds remain. All 476 TUI tests passed, and the new regression rejects
the previous ten-row threshold. Lint and doc-check passed with zero errors.
Hosted CI and Linux signoff passed at `21ed55c6`; the merge of main preserves
both TUI changes and needs fresh checks at its new head.

## Compaction notice (September 14)

The TUI now renders compaction as one short notice with the approximate token
count before compaction and the number of retained messages. The model-facing
checkpoint remains in the durable entry and is omitted from the transcript,
including expanded details. The entry carries no post-compaction token count,
so the notice does not claim savings. PR #407 merged as `7cacb150` after
hosted CI and exact-head Linux signoff passed.

## Where the tree is

| Body of work | Current state |
|---|---|
| Human controls | Queue editing, priority steering, worktree observations, and completion summaries are merged in #344. |
| Markdown skills | #346 is merged; discovery, explicit activation, paged completion, and model-selected loading are shipped. |
| UX polish | #347 and its reading follow-up #349 are merged. |
| Streaming tool output | Merged in #348 (`6a484a4f`). A running `bash`/`grep` call's bounded output tail reaches the terminal while it runs: collector observer, `Outputs` bus topic, pushed `tool_output` frame, one `ToolTail` per stream ([protocol 031](../protocol-change/031-tool-output-stream.md), issue #186). |
| Context usage | Merged in #351. `/context`, `/context all`, and a persistent `ctx ~N%` footer; the server captures the active strand's configuration and immutable history, so the count is independent of scrollback retention ([protocol 030](../protocol-change/030-context-observation.md)). |
| Escape and held input | #352 made an explicit abort admit every message held for that strand into one successor run ([protocol 032](../protocol-change/032-abort-held-batch.md)); that successor started the moment the abort retired, so Escape read as "skip ahead". [Protocol 033](../protocol-change/033-abort-halts-held-input.md) now halts the held queue at abort and releases it, as one batch with the operator's next message last, only when a client submits on the strand. Not halted: runs started through `runtime/api` by a parent's downward send or an advisor block; see "Deliberately open". The smoother daemon update path is filed as #392. |
| Transcript reading and drafts | Merged in #353. A reading viewport is preserved even at offset zero, expanded tool results keep the compact call's anchor, bracketed paste inserts at the cursor without replacing a draft, and an aborted turn renders as Stopped with its diagnostic visible. |
| Herdr integration | Merged in #354. The terminal reports idle, working and blocked to a Herdr pane over its unix socket, sequenced from the wall clock, announcing the session when its identity is first known and on every switch. `done` is Herdr's own derivation from an idle report on an unseen tab and is never sent. |
| Imported hooks | Merged in #355 (issue #350, first wave). A Claude Code hook collection loads unchanged from the operator's `~/.claude/settings.json`, trusted on first sight and re-reviewed on change; the composed gates fire at run start, tool clearance (after the harness's own, with a rewrite re-cleared), the result fold, the summarizer, and run end. A committed acceptance fixture boots a real instance and proves each gate fires. Its follow-ups are gathered in #369, superseding the looser list a previous edition carried here; see "What to do next" below. |
| Server per-step CPU | Merged in #379, closing issue #359. The daemon spent a turn's CPU building binaries and sweeping the heap. Measured on the issue's own 1,208-entry session with `make bench-server`: one step cost 1015 ms, of which the estimator the issue suspected was 0.01 ms. The cost was `core/json` working one codepoint at a time on both sides, and the driver decoding the whole branch three times per step. The codec now walks bytes and cuts strings as slices (decode 283 to 103 ms, request encode 142 to 15 ms), the threshold query carries the projection the driver already made, the reminder counts the messages it holds, and the driver memoises the branch scan by leaf and extends it incrementally (`runtime/projection`). A run's first step now costs 124 ms and every later step 24 ms. Not done: the `loom diag` control command the issue proposes, and the per-delta streaming path was not profiled. |
| Terminal parity | Merged in #366. The bottom-anchored viewport walks to the tail one row per frame instead of jumping by each provider chunk, a tick that carried transcript traffic is a paced boundary under the frame budget, and the record projection is rebuilt only when its inputs change. A running tool and streaming reasoning keep the height their settled form will have in compact mode; reasoning collapses to one row that Ctrl+G expands. Markdown renders tables as a bordered grid measured in terminal cells, inline code in its own colour, code with a gutter distinct from a quote, wrapping code rows, strikethrough as strikethrough, GitHub alerts as callouts, and headings by weight. A strand switch parks the loaded scrollback instead of discarding it (#361). etui is pinned past the emoji-presentation width table and synchronized output. The pure pacing arithmetic lives in `tui/pacing`, and `tui.update` is split into a dispatch and a settle because the Erlang inliner re-visited the dispatch once per settling step and had doubled the package's compile time past three CI deadlines (`docs/execution.md` §8). |
| Advisor strand | Merged in #360, closing issue #137. A catalogue that routes an `advisor` role gets a second strand beside `main`, created by the harness rather than by the Agency, that reads a rendering of what `main` did since a stored cursor — at each of its run ends, and again every `feed_every_steps` steps inside a run still going — and answers with one `advise` call: `quiet`, `nudge` folded into `main`'s next run start, or `block` delivered now. An emission guard downgrades a block inside its cooldown and drops advice already given. Unrouted, nothing is created. #137 is closed; its phase-1 deferrals live on in `docs/architecture/advisor.md` and in "What to do next" below, no longer gated by that issue number. |
| Vision routing | Merged in #362, closing issue #358. The catalogue's `vision` key routes an image-bearing request through the `vision` chain; a text-only target gets a text placeholder for each image instead of a silent drop; a request routed nowhere usable gets a worded in-band refusal. Two rounds of adversarial review moved the design twice before landing: the first found the classifier reading the newest user message, which misclassified the common case where a run-start digest injection sits after the operator's actual image-bearing turn, fixed by classifying the *current turn*; the second found the turn boundary sitting before a tool call, so the request carrying a tool's result back was classified imageless and handed to the text-only model, fixed by moving the boundary past tool calls. The key's default flipped for the same reason nothing on the wire marks the capability: an entry that never wrote `vision` reads images, and the routing and the refusal act only on an entry explicitly declared `vision = false`. |
| `cap/search` | Merged in #378, closing issue #365. A read-only navigation and search capability — `glob`, `grep`, `stat`, `read_lines` — on the workspace and extension seams, served entirely in the harness with no process spawn. See "The `cap/search` rulings" below for what it settled and "Deliberately open" for what it left unmeasured. |
| Retry ladder | Open in #391 (issue #368, first item). The runtime's default policy is now `Unbounded` from a 1 s base to a 60 s cap, and every wait is equal-jittered into the upper half of its interval, seeded from the failed attempt's entry id so the machine stays pure. A rate limit long-polls at most once a minute until the provider answers or the run is cancelled. An operator sets the budget and cap in a `[retry]` table (`client/retryconf`), and the classifier no longer turns a 429 terminal: the status is checked ahead of the overflow patterns, and an untyped mid-stream error chunk whose message says throttling is retryable. Not done: issue #368's second item, documenting `[schedules] model_created = "wake"`. |
| Release dependencies | SQLite, hosted latency, joined fault/pressure coverage, schedules, and memory-off observations retain their separate issue acceptance. |

### Corrections to the previous edition

The previous edition's stated baseline (`87df00a5`, September 12) was already
behind its own table by the time it was last touched; see the preamble above.
Two claims in it are now plainly wrong rather than merely stale:

The preamble described vision routing as "ready for its PR" on a branch. It
merged as #362, after the two rounds of adversarial review described in the
table above; that work is no longer pending, it is a settled body of work
with its own row.

Item 2 of "What to do next" told the reader to record advisor block/nudge
counts "on #137" before building the awaited run-end hard block. #137 is
closed — phase 1 shipped and the issue tracked exactly that, nothing more.
The counts still need recording, but there is no open issue to record them
on until one is filed; the exit criterion below is corrected to say so
rather than point at a closed issue. The same audit found
`docs/architecture/advisor.md`'s deferred list had grown a sixth item,
**interrupt-policy nuance** (plan mode, terminal-answer suppression), added
by #360's own final commits after this file's item 2 was last written. It is
included below for the first time.

Item 1's imported-hooks follow-up list was accurate in kind but looser than
what now exists: #369 gathers the same follow-ups with the exact shape each
takes (an `import = "on" | "off"` switch, the `loom hooks trust` CLI,
`SubagentStop` for `sub:` strands, a Loom-native TOML hook source, and
`UserPromptSubmit`/async hooks). The list below cites #369 directly instead
of repeating a paraphrase that could drift from it again.

Two defects unrelated to any of the above were found and fixed on main in
this window, neither opening new work: #375 fixed a busy-refusal race
between `loom-exec`'s exit-frame write and the channel closure the broker's
dispatch check reads, reproduced once in CI and now regression-tested with
the write and the close on separate signals. #376 lowered two imported-hook
test fixtures from `PlatformEnforcement` to `BestEffort`, the level every
other jailed fixture in the tree already asks for; the two outliers were
failing all twelve `check (linux, client)` cases on an unrelated
`skip:cgroup-v2` degradation, not the hook behaviour the assertions named.

Two smaller repairs, made inside the `cap/search` branch itself because main
had drifted under it between the advisor-strand and vision-routing merges,
are not corrections to a previous edition but are worth naming here so a
reader of the log is not puzzled by them: two citations in
`docs/architecture/advisor.md` had moved when vision routing shifted
`client/catalog.gleam`'s line numbers, and
`client/test/client/advisor_e2e_test.gleam` constructed `CatalogModel`
without the `vision` field vision routing had added, which had left the
client suite not compiling on main. Both are fixed on main as of `10b77fc4`.

### The `cap/search` rulings

Issue #365 proposed `cap/search` and left six open questions; its closing
comment settles each, and this section is the durable home for that ruling
now that the issue itself is closed:

**Names.** The draft's `walk`, `find` and `read_slice` shipped as `glob`,
`grep` and `read_lines`. The cap exists to replace the `bash grep` fallback,
so the model should reach for `search.grep` on unix priors without reading
docs; `find` in unix searches paths, not contents, so it was rejected as a
name for content search.

**Result shape.** `capped` and `truncated` are exclusive — hitting the match
cap stops the scan — so they are one three-variant `Coverage`
(`Exhaustive`, `MatchesCapped`, `ScanTruncated`,
`packages/cap/src/cap/search.gleam:263`) rather than two `Bool`s. There is
no score field on a workspace hit; the seam shared with #226 (deferred) is
`path`, `line`, `column`, `text` plus context, and a future hybrid ranker
adds its own score on its own type.

**Symlinks are never followed inside a walk**, with no opt-in. `glob`
classifies with `lstat` and reports a link as `Symlink(target:)`, never
descending into or reading through one. `read_lines` resolves the whole
path the way `fs.read` does, so reading through a *contained* link works
and an escaping one is refused; `stat` resolves the parent and lstat's the
leaf, so a link is reported as a link. This makes containment hold by
construction for everything a walk reaches, from the one `resolve_real`
call at the boundary, rather than by a check repeated at every entry.

**Pattern language.** Glob is the ripgrep `-g` subset (`*`, `?`, `**`; a
pattern without `/` matches basenames at any depth, stated where the model
reads it in `packages/cap/src/cap/search.gleam`); content search is
`gleam_regexp`. Both are bounded by pattern length, entries visited, bytes
scanned, and the serving call's own execution deadline, and both `glob` and
`grep` look one past their bound so an exact fill is reported `Exhaustive`
rather than as a truncated miss — the fix for the one defect an adversarial
review pass found in `grep`, which had reported capped coverage on an exact
fill; `glob` had the same shape fixed during the build, with a regression
for each.

**Ordering.** Results are path-sorted, deterministically. No mtime mode
shipped; `mtime_seconds` rides on every entry for a caller that wants one.

**Ignore files are not honoured.** `.gitignore` and its relatives are read
by neither call. Hidden entries are skipped by default, overridable with
`IncludeHidden`; a fixed `prune` list (`.git`, `_build`, `build`,
`node_modules`, `target`, `deps`) is never descended, overridable with
`prune: []`. Parsing `.gitignore` correctly is real complexity, deferred
until a trace shows it is needed.

**`cap/history` stays deferred and tool-only**, as the issue's draft leaned.
Durable-history recall sits behind an index that is a trusted host object
and an embedding runtime that is native inference; neither belongs behind a
model-authored import, and #226 (Spindle) is building the retrieval
underneath the tool-only door in the meantime.

Two gates fire on any new `cap/*` module and are easy to forget when
planning similar work: the extension seam's exact-set freeze test, and the
prelude coverage check in `scripts/gen-prelude.sh`. Both fired here and
both are why `ad6dda59`, `3627d168` and `0914a3fc` each regenerate the
prelude.

The prompt steers a model toward this cap rather than a shell pipeline: the
`code_mode` and `grep` snippets, and a new paragraph in the system prompt's
`tool_discipline` section (`packages/prompt/src/prompt/default.gleam`), say
that finding, filtering, counting or joining across files belongs in a
`code_mode` program using `cap/search`, because a shell pipeline prints its
intermediate output into the model's context and hands back the shaping
anyway. Whether that nudge actually moves real traces off the bash fallback
is unmeasured; see "Deliberately open".

## What to do next

1. **Finish the imported-hooks layer's follow-ups**, tracked in #369: an
   `[hooks] import = "on" | "off"` switch (default `on`); the `loom hooks
   trust` CLI, without which project and local sources can never be
   approved (the trust module already has `trust`, `revoke` and `scan`; the
   CLI is surface beside `loom ext`); `SubagentStop` for `sub:` strands
   (and a ruling on whether the advisor counts); a Loom-native
   `~/.loom/loom.toml` `[[hooks.Event]]` source, which already parses and
   round-trips but is wired to nowhere; and the `UserPromptSubmit` seam,
   which touches surfaces protocol 024 froze and may need a
   `protocol-change/NNN.md`. **Exit:** each as its own PR with a regression
   and #369 closed or narrowed to what remains.

2. **Carry the advisor's phase-1 deferrals.** Each is named in
   `docs/architecture/advisor.md` with what it waits on; #137 tracked phase
   1 only and is closed, so none of these has an open issue yet. One has
   since been answered and is no longer on the list: the **feed's cadence**.
   It shipped per run, which left a long run opaque to the reviewer because
   nothing bounds a run's length, and the step trigger
   (`[advisor] feed_every_steps`) now feeds part-way through one. That
   change moved the block cooldown from runs to reviews and made the
   threshold a floor under an advisor-paced loop rather than an interval;
   read the architecture doc's "Backpressure is coalescing" before tuning
   it. The
   **awaited run-end hard block** — holding the run boundary open until the
   advisor answers — waits on counts of how often `block` fires and how
   often the re-wake came too late; the machinery for an awaited run-end
   key already exists in the assistant path, so this is an evidence
   question rather than a build one, and the first step is filing an issue
   to hold the counts. The step trigger did **not** take the bounded wait
   `oh-my-pi` pairs with its per-turn feed, and the reasoning is worth
   keeping: a wait shorter than one review is inert, and a longer one is
   this same awaited block, so there is no useful middle value while the
   reviewer is by construction the slower model. **Extraction to an extension** waits on two
   capabilities the satellite does not have: a transcript read on the cap
   prelude, and an `AgentEnd` hook that carries more than an operation id.
   A **code-mode `cap/advise`** surface, a **brief override file** in place
   of today's constant, **interrupt-policy nuance** (plan mode,
   terminal-answer suppression, beyond the one cooldown policy shipped),
   and **advisor status in the terminal** — the branch is reachable through
   the strand list, but nothing reports that a review is in flight or when
   the last verdict landed — are each their own small piece. **Exit:**
   an issue filed and counts recorded before the hard block is built; each
   of the other five as its own PR with a regression.

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

**`cap/search` is a separate module, not four more arms on `cap/fs`.**
Issue #365's closing comment is the record; see "The `cap/search` rulings"
above for the full settlement, including names, result shape, symlink
policy, pattern language, ordering, ignore-file scope, and the deferral of
`cap/history`.

**A code-mode program's traversal and shaping belong in `code_mode` with
`cap/search`, not a shell pipeline.** `packages/prompt/src/prompt/default.gleam`'s
`tool_discipline` section states this as policy: a pipeline that shapes
output is a program written in the wrong language, and it prints its
intermediate output into the model's context on top of forcing the shaping
back out through text. `bash` remains the reach for a real tool the
workspace provides, and `grep` for a case where the model will read the
matches itself. Whether the nudge measurably moves traces is open; see
"Deliberately open".

**A vision-routing entry's default is to read images.** Issue #358's work,
merged as #362: nothing on the wire marks whether a model reads images, so
the fact is learned by probing rather than declared, and the routing and
the in-band refusal act only on an entry explicitly declared
`vision = false`. The turn that decides routing is the *current* turn, past
any tool calls in it, not the newest user message — both were the subject
of an adversarial-review correction each, recorded in the table above.

**Context inspection reads captured state, never presentation.**
[Protocol 030](../protocol-change/030-context-observation.md) captures the
active strand's configuration and immutable history through the bounded
observation workers and rechecks authority before delivery. The headline reuses
the latest usable provider total plus estimated newer messages; component counts
are independent estimates, never summed into a provider total. The read is
bounded by a 4096-entry scan and a 47,000-byte board. The footer refreshes at
the operation boundary, not per committed entry; manual `/context` forces a read.

**An explicit abort halts the held queue until the operator speaks.**
[Protocol 033](../protocol-change/033-abort-halts-held-input.md) marks the
strand's existing held queue `Halted` at abort: the aborted operation retires,
the strand goes idle, and nothing held starts. The next client submission on
the strand joins the queue and releases it as one batch, preserving each
message's content, images, and author in FIFO-within-priority order, with a
prompt last and a steer first. An empty queue at abort carries no intent, so
input typed after it keeps the one-head drain ([032](../protocol-change/032-abort-held-batch.md)'s
surviving arm). Ordinary completion and steering retain their existing
ordering.

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

**The transcript moves at frame rate, never at chunk rate.** The provider
delivers text in chunks and the viewport reveals it one row per rendered
frame, accelerating above a backlog of a screen's worth so it is never more
than about a second behind; only a gesture that addresses the transcript
snaps it to the tail, and typing into the composer does not. A live region
in compact mode has the height its settled form will have, so a settle
changes text and never height; a failing tool's failure row is the stated
exception. The live tail's markdown parse is not memoized, because any memo
pins one extra generation of the live region and the retained-bytes gate on
streaming has no headroom for it.

## Deliberately open

None of these is unfinished work somebody forgot.

- **Whether the `tool_discipline` prompt nudge actually moves traces off the
  bash fallback and onto `code_mode` with `cap/search`** is unmeasured. The
  right next step is reading real traces, not adding more prompt bytes on
  the strength of intuition.
- **If `search.grep` proves slow on a large monorepo**, the designed fix is
  a jailed `rg` behind the same typed `Coverage`/`Found` result, not a
  change to the capability's API. No measurement has shown this yet.
- **Ignore-file support (`.gitignore` and relatives) is deferred**, not
  designed away. It waits on a trace that actually needs it; parsing them
  correctly is real complexity that a hidden-entries-plus-`prune` default
  has so far made unnecessary.
- **Escape's halt covers held client input only.** Protocol 033 halts the
  gateway's held queue, which is what an operator sees start on its own.
  A run started through `runtime/api` without a client — a live parent's
  downward `send_to_strand` into an idle child, an advisor `block`, a
  `wake = true` schedule firing on an idle strand — is not halted, because the
  gateway never sees it. Closing that is a paused mark on
  the strand cell in `machine`/`runtime`, read by `accept_request`, and is
  worth doing only once a trace shows one of those starters undoing an
  operator's Escape.
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

A related but distinct hazard surfaced building `cap/search`, worth keeping
apart from a flake because re-running does not fix it: a test module that
installs a fake capability channel into `cap/internal/dispatch`'s VM-global
`persistent_term` slot (as `cap_test` and `cap@mcp_test` already did, and as
`cap/search_test` now does) must be listed in `scripts/serial-tests`, or the
signoff's eight-way parallel EUnit hands it a sibling's fake reply instead of
its own. The failure looks exactly like a flake — a handful of assertions
fail on what reads as the wrong data — until the serial list is checked.

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
bash scripts/test.sh tools --match search
bash scripts/test.sh tui --match advisor_view
```

The full local gate ran with the real native helper and prepared code-mode
seed. Platform-specific prerequisites and opt-in shipped bootstrap fixtures keep
their own coverage; an ordinary package pass does not imply Linux shipment
acceptance. The Linux signoff runs `scripts/signoff.sh` on a pushed head.

**Capture each command's own exit status.** A successful log reader is not a
successful gate. **Use one build/gate at a time per checkout.** Keep enforced
code-mode worktrees outside `/tmp`, where the jail replaces sockets with scratch.

Three hazards from landing `cap/search` cost real time and are worth
carrying forward:

- **Adding a hex dependency to a package requires hand-updating that
  package's `requirements` line in every downstream `manifest.toml`**
  (`client`, `conformance` for `tools`'s new `gleam_regexp`). The released
  `gleam 1.18.1` silently heals a stale line locally; the patched compiler
  CI builds against does not, so a green local `make check` proves nothing
  about this.
- **A test module calling `cap/internal/dispatch.install` must be listed in
  `scripts/serial-tests`**, or the signoff's eight-way parallel EUnit hands
  it a sibling's fake reply. See "Known flakes" above.
- **The remote signoff checkout can hold a stale `packages/*/build/erlang-shipment`
  directory** that fails prep on an otherwise clean run.

See [execution](execution.md) for the remaining operational rules.

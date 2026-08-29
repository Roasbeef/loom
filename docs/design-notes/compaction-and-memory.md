# Design note: compaction and memory

Status: **Stages C0 and M1 are built; everything else is proposed.**
Part 0 below describes the position this note was written from, which
C0 has since changed: compaction now runs in production, answered by
`client/wiring`'s hooks against a real provider. M1 has since changed the
memory half the same way: recall is wired, `history_search` is
registered, and the `agent/` digest is injected. Read Part 0 as history
and Part 5 as the plan. Loom's compaction machinery was already
implemented from the durable entry type up through the state machine,
and none of it ran: `client/serve` installed hooks whose threshold never
fired, whose structural decisions always declined, and whose summary
requests settled as terminal "not wired" errors. Loom has no
memory story at all — nothing carries knowledge from one session into the
next (as of writing; M1 has since given it one). This note designs both,
after reading how the two reference implementations actually do it.
Everything claimed about Loom, pi, and omp below was verified in source; the handful of claims that rest on
vendor blogs or third-party writeups are marked as such.

Two of the note's inputs deserve naming up front, because they shape
every decision:

1. **The machine is not the gap.** `machine/planner.gleam` already
   implements the full checkpoint procedure — threshold check once per
   trigger boundary, the structural-decision lifecycle, the nested
   summary-request loop with retries, overflow provenance, standalone
   compaction operations, summarized navigation. What is missing is the
   production wiring on three seams, plus every decision about what the
   summary request actually says to a provider.
2. **Prompt caching is live and priced.** The Anthropic adapter spends
   four cache breakpoints on every request — two one-hour marks on the
   tools and system prompt, two five-minute marks rolling on the last
   two user turns (`provider/adapter/anthropic.gleam:322`). Compaction
   replaces the head of the projected message list, so it invalidates the
   message-region cache while leaving the tools+system head intact.
   Memory injection, done wrong, is worse: a single changed byte in the
   pinned system prompt costs a full 2× cache rewrite for every strand
   for the rest of the hour (`packages/prompt/CLAUDE.md`). The designs
   below treat both as line items, not footnotes.

---

# Part 0 — Where Loom actually stands

Verified against source at the time of writing. This section exists so
the rest of the note can say "wire X" and mean something checkable.

## Built and tested, with no production caller

- **The durable shape.** `core/entry.gleam` defines `CompactionEntry`
  (summary, complete `retained_tail` copy, `tokens_before`, `from_hook`,
  `usage`) and `BranchSummaryEntry` (`from_id`, summary). Both are
  write-once rows in the conversation tree, frozen in spec Part 1.1.
- **Projection.** `session/session.gleam:604` scans the branch
  newest-first, stops inclusively at the first compaction, and projects
  the compaction as its summary — *as a user message*, because the
  summary is injected context, not model output — followed by the
  retained tail. Error/aborted/deferred responses drop; orphaned tool
  calls heal with synthetic results.
- **The branch index depends on compaction.** The SQLite segment index
  bounds its divergence copy at the newest compaction on the path
  (`docs/architecture/durability.md`, "The segmented branch index") —
  compaction is what keeps forking from costing quadratic index growth.
  The storage plane already assumes compaction happens; it just never
  does.
- **The machine.** The checkpoint procedure runs threshold compaction as
  step 3, at most once per trigger boundary
  (`machine/planner.gleam:746`). The structural-decision hook chooses
  between declining, supplying a finished summary, or generating one
  (`StructuralVerdict`, planner line 261); generation loops nested
  `SummaryRequest`s until `SummaryProduced`, with per-request usage rows
  and retry classification. Standalone compaction operations and
  summarized navigation exist as operation kinds, and the client
  protocol already carries `Compact(strand, instructions)`
  (`client/protocol.gleam:118`).
- **Blob offload.** Tool outputs over 64 KiB never enter the transcript
  wholesale: `tools/blob.gleam` writes them content-addressed and stores
  `{ref, size, head_excerpt, tail_excerpt}` with 2 KiB excerpts. This
  matters for compaction sizing: pi truncates tool results at
  summarization time because they dominate context; Loom already bounds
  the worst of them at commit time.

## Inert in production — the three unplugged seams

`client/serve.gleam:652` builds effects through `wiring.build_effects`,
which installed `effects.default_hooks()` (`client/wiring.gleam:111`),
wrapped only by `agency.reaping_hooks` for child-reaping. The defaults
(`runtime/effects.gleam:288`):

1. **The threshold never fires.** `threshold: fn(_) {
   ThresholdNotExceeded }`. Step 3 of every checkpoint is a no-op.
2. **Every structural decision declines.** `structural_decision: fn(_,
   _) { VerdictDeclined }` — and a declined threshold compaction quietly
   restores the checkpoint, while a declined *overflow* compaction
   drains the run as `context_overflow` (planner line 3567). The
   overflow-preparation default is `EmptyPreparation`, which drains as
   failure before the decision hook is even consulted (planner line
   1438). In production today, an overflowing run simply dies.
3. **The provider surface refuses summaries.** `client/wiring.dispatch`
   settles any `SummaryRequest` as a terminal in-band
   `unsupported_request` error ("structural summaries are not wired to a
   provider surface yet").

Two adjacent facts complete the picture. The default admission hook
grants a fictional 1,000,000-token window under api `"unknown"`, so even
the *accounting* a threshold would need is fake in production. And the
compaction visible in `make check-client`'s demo is the demo answering
itself: `client/demo.gleam:922` installs hooks whose
`structural_decision` returns `VerdictSupplied` with a canned string. No
provider is ever asked to summarize anything, anywhere.

A real hook registry exists — `runtime/hooks.gleam` has pipeable setters,
a config-driven `admission`, and a `threshold` constructor that reads the
durable projection and prepares a keep-recent split. It has no caller
outside tests and the simulation. The spec records all of this honestly:
"a production hook registry" is one of the four named bodies of
unscheduled work (`docs/loom-implementation-spec.md` §5.1).

## Memory-shaped things Loom already has

Worth listing before designing anything new, because Part 3's answer is
mostly composition:

- **The blackboard** — `fact.custom` registers, the one namespace shared
  across strands, with reserved harness-only prefixes
  (`docs/architecture/messaging.md`). Model-facing doors exist:
  `agent_note` writes under `agent/{caller}/`, `agent_notes` reads under
  `agent/`, and a subagent's cells travel back attached to its result
  (`tools/agent.gleam`).
- **The FTS index** — `events/search`: an FTS5 index over entry text,
  synced by generation-stamped cursor, tested against hostile queries.
  "Nothing wires search into a running harness. It is a complete, tested
  service waiting for a consumer" (`docs/architecture/events.md`). Two
  limitations matter later: queries cannot be scoped to a session, and
  the default `unicode61` tokenizer makes CJK text unsearchable.
- **`cap/kv`** — a session-scoped scratch store for code-mode programs,
  ephemeral by contract ("treat it as a cache, never a database").
- **Branch summaries** — specified, machine-supported, storable, and
  never produced, for the same reason compaction never runs.
- **The tree itself** — write-once and fully retained. Compaction in
  Loom does not delete anything; every "forgotten" entry remains
  navigable and indexable. This is the correctness backstop the whole
  design leans on.

---

# Part 1 — How the reference implementations actually do it

## pi (verified in source, `/home/user/earendil-works/pi`, branch `dev`)

pi carries two compaction implementations. The shipped coding agent
(`packages/coding-agent/src/core/compaction/`) stores a
`firstKeptEntryId` *pointer* on its compaction entry and re-walks the
session file to rebuild context. The newer harness
(`packages/agent/src/harness/compaction/`) stores the retained tail as a
*copy* on the entry — the design Loom's `CompactionEntry` descends from.
Where the two differ below, the harness is named.

**Trigger.** After each settled assistant turn, compact when
`contextTokens > contextWindow − reserveTokens` (`shouldCompact`;
defaults `reserveTokens` 16384, `keepRecentTokens` 20000). The token
count is not an estimate when it can be real: pi takes the last valid
assistant message's provider-reported usage (`totalTokens`) and adds a
chars/4 estimate only for messages after it (`estimateContextTokens`).
A guard rejects usage that predates the latest compaction, so a stale
pre-compaction number cannot re-trigger compaction immediately after one
finished (`core/agent-session.ts:~2130`). Two more triggers: manual
`/compact [instructions]`, and **overflow recovery** — on a
provider-reported context overflow, remove the failed assistant message
from live state, compact, and retry the turn exactly once
(`_overflowRecoveryAttempted`).

**Cut point.** Walk newest-first accumulating estimates until
`keepRecentTokens` is reached; cut at the nearest valid cut point at or
after that entry. Valid cut points are user/assistant/custom messages —
**never a tool result**, which must stay adjacent to its call. If the
cut lands mid-turn (one turn bigger than the whole keep budget), it is a
**split turn**: the turn prefix is summarized separately from the older
history and the two summaries are merged under a "Turn Context (split
turn)" divider. On re-compaction, the harness re-materializes the
previous entry's retained tail as virtual entries so messages that
survived one compaction are included in the next summarization pass
rather than silently dropped (`prepareCompaction`, harness
`compaction.ts:602`).

**The summary request.** pi does *not* send the live conversation to the
model. It serializes the doomed messages to role-tagged text
(`[User]: … / [Assistant]: … / [Tool result]: …`, tool results truncated
to 2,000 chars), wraps them in `<conversation>` tags, and sends a single
user message under a dedicated summarization system prompt that forbids
continuing the conversation. The prompt demands an exact structured
format — Goal / Constraints & Preferences / Progress (Done, In Progress,
Blocked) / Key Decisions / Next Steps / Critical Context — with an
explicit instruction to preserve exact file paths, function names, and
error messages. When a previous summary exists, an *update* prompt merges
it iteratively ("PRESERVE all existing information… move items from In
Progress to Done"). Cumulative file-operation tracking — read/written/
edited paths extracted from tool calls, merged across successive
compactions — is appended as `<read-files>`/`<modified-files>` tags.

**Cache stance.** Every summarization call sets `cacheRetention: "none"`
and a fresh routing session id (`completeSimpleWithRetries`, harness
`compaction.ts:110`): a one-off prompt will never be read again, so pi
declines to pay cache-write premiums on it. Note what pi does *not* do:
the summary request re-uploads the serialized history at full input
price rather than reusing the live cached prefix.

**Branch summaries.** On `/tree` navigation, pi finds the common
ancestor, collects the abandoned entries, budget-truncates newest-first,
generates a summary in the same structured format, and appends a
`BranchSummaryEntry` at the navigation target — context from the
abandoned branch is carried, not lost.

**Extension seams.** `session_before_compact` may cancel or supply the
whole compaction; `session_before_tree` likewise for navigation;
`session_compact_failed` reports terminal outcomes. Loom's hook slots
are a direct transcription of these seams.

**Memory: none.** pi has no cross-session memory subsystem; searches for
one in the repo come up empty. Its extension seams are where omp grew
one.

## omp (= `can1357/oh-my-pi`, verified in a shallow clone of `master`)

The design doc's "omp" is **Oh My Pi**, a heavily extended pi derivative.
Its compaction and memory are both far past pi's, and several of its
ideas transfer; several deliberately do not.

**Compaction** (`docs/compaction.md`, confirmed against
`packages/agent/src/compaction/`): six triggers — manual, overflow,
incomplete-output (`stopReason: "length"`), post-turn threshold,
*mid-turn* threshold at safe tool-loop boundaries, and idle. Before
compacting at all it tries **context promotion**: switch to a
configured larger-window model and retry without losing anything.
Compaction itself walks a configurable `methodOrder` (default
`["remote", "snapcompact", "handoff", "shake", "soft"]`):

- **shake** — mechanical, model-free elision: replace eligible old tool
  results and large fenced blocks with recoverable `artifact://`
  references, under a protected recent window and a minimum-savings
  threshold.
- **snapcompact** — archive the discarded history as pixel-font PNG
  frames sized per model line and per provider image-billing formula, on
  the eval-backed claim that bitmap text preserves QA recall at fewer
  billed tokens than raw text for vision models.
- **handoff** — generate a continuation document **through the live
  cache prefix**: the request is the real system prompt, tool array, and
  message history — routed with the same `promptCacheKey` as the live
  turn — plus one appended user instruction, `toolChoice: "none"`
  (`docs/handoff-generation-pipeline.md`). The summarizer reads the
  history at cache-read price instead of re-uploading a serialization.
- **soft** — pi-style serialized-text summarization, with remote and
  provider-native (OpenAI `/responses/compact`) variants.

Around the methods: **speculative compaction** (`asyncEnabled`) starts a
background summarization when context enters a pre-threshold band, off a
branch snapshot under a side session id, and commits the armed result
instantly when the threshold is actually crossed — summarization latency
hidden, discarded if the branch prefix changes first. **Cache-aware
pruning** blanks superseded and useless tool results only when the
suffix after the candidate is small (≤ ~8k tokens) or the session has
idled past the provider cache lifetime — an explicit "don't churn a warm
cache to save bytes" rule. The TUI keeps full scrollback and renders
compaction as an inline divider; only the LLM context resets.

**Memory** (`docs/memory.md`, confirmed against
`packages/coding-agent/src/hindsight/` and `src/memories/`): four
backends — `off` (default), `local`, `hindsight` (remote server), and
`mnemopi` (local SQLite). The two instructive ones:

- **`local`** is a two-phase background distillation pipeline over
  *persisted session files*. Phase 1: for each changed past session, a
  model extracts durable signal — decisions, constraints, resolved
  failures, recurring workflows — into a raw memory block and synopsis.
  Phase 2: a consolidation pass (run under a lease with heartbeat)
  produces `MEMORY.md` (curated long-term document),
  `memory_summary.md` (the compact block injected at session start,
  under a ~5,000-token cap shared with lessons), and generated skill
  playbooks. A `learn` tool appends explicit lessons to `learned.md`
  (100-entry cap, 2,000 chars each, secret-redacted). Injection framing
  is explicit: memory is *heuristic* context — "prefer repo state and
  user instruction when they conflict with memory; treat conflicting
  memory as stale."
- **`hindsight`** talks to a memory server (vectorize-io/hindsight):
  `retain` (auto every third user turn, plus a debounced tool-call
  queue), `recall` (auto on the first turn, injected as background
  context — and available as extra context *during compaction*),
  `reflect`, and **mental models** — named, persisted summaries seeded
  from curated queries ("What does the user prefer…") and refreshed on
  server-side consolidation. Banks are scoped per project by lowercased
  repo-root basename. Recalled `<memories>` blocks are tag-stripped
  before any retain so a recalled memory is never re-retained as new —
  an anti-feedback rule (`src/hindsight/content.ts`).

Two omp memory rules are cache rules in disguise and transfer directly:
a `learn` call **does not mutate the active session's prompt-cache
prefix** (lessons appear starting the next session), and recall injects
once, early, as ordinary context rather than editing the system prompt.

## The wider field (secondary sources, marked)

- **Anthropic's API-level context management** (context editing +
  memory tool, Sept 2025): the platform can clear old tool results and
  thinking blocks *server-side* — applied after cache lookup, before
  token counting — and the `memory_20250818` tool gives the model a
  file-store it reads and writes across sessions. Anthropic reports 39%
  improvement and 84% token savings on a 100-turn benchmark with both
  enabled — vendor-reported numbers, not independently verified.
  (claude.com/blog/context-management;
  platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)
- **Claude Code** layers a per-turn "microcompaction" (old tool-result
  clearing) under threshold auto-compact and manual `/compact` —
  consistent with the docs and third-party teardowns read for this note,
  but the implementation is closed; treat specifics as unverified.
- **Manus** ("Context Engineering for AI Agents", manus.im blog) argues
  KV-cache hit rate is *the* production metric for agents (input:output
  ≈ 100:1; cached input at 0.1× price), and derives: stable prefixes,
  append-only context, externalize memory to the filesystem. Loom's
  append-only tree and byte-stable prompt pack already embody this; the
  blog is confirmation from production, not a source of new mechanism.
- **MemGPT** (Packer et al., arXiv:2310.08560) is the academic ancestor
  of most agent-memory designs: treat the context window as main memory
  and page against external stores via self-directed tool calls. The
  memory tool above and omp's retain/recall are both recognizably this.

---

# Part 2 — Compaction for Loom

## The principle the durability model dictates

In a CLI whose session is a JSONL file, compaction can afford to be
casual — worst case, the file still has everything. Loom's model is
stricter and, for once, strictness helps: **compaction is an append, not
a rewrite.** A `CompactionEntry` is one more write-once row; the
summarized history remains in the tree, navigable, forkable, and
FTS-indexable; only *projection* changes, because the branch scan stops
at the first compaction. Nothing is erased (the precise rewrite remains
the repo's sole erasure mechanism, unrelated to compaction). The
log-is-truth rule is undisturbed: recovery replays the same projection
because the compaction entry is *in* the log.

Fork semantics follow with no extra design. A fork below the compaction
never sees it (its path has no compaction, so its scan runs to the
root). A fork above it inherits summary + retained tail, and the branch
index's divergence copy is bounded at that compaction — the cheap-fork
property the storage plane was already built around. Compaction is a
path-local event; siblings are untouched. Contrast pi's coding agent,
where compaction conceptually applies to the whole session's replay;
Loom's divergence here (inherited from pi's newer harness: the
self-contained retained-tail copy) is deliberate, and the price is named
in Part 4.

## Trigger

Keep the machine's discipline exactly as built: **threshold compaction
at checkpoints only, once per trigger boundary** (spec §3.2, planner
step 3). What changes is only that the hooks answer honestly:

- **Admission** stops lying. `hooks.admission` is installed with the
  gateway's resolved model facts — real api, real context window, real
  output limit. Everything else keys off this.
- **Threshold** = `projected_tokens > context_window − reserve_tokens`,
  pi's inequality with pi's defaults (16384 reserve, 20000 keep-recent)
  as the initial `CompactionSettings`. Accounting follows pi, not the
  current estimate-only registry hook: take the newest settled assistant
  message's *durable* provider usage from the projection and add a
  chars/4 estimate only for entries after it. No new plumbing is needed
  — the registry's `threshold` constructor already receives the
  projected messages and can fold usage out of them; it needs the
  usage-aware fold and the stale-usage guard (reject usage older than
  the newest compaction on the path). Deciding from durable state keeps
  the decision crash-stable, which is the registry's stated rule.
- **Overflow** reuses the machine's existing one-shot recovery: wire
  `overflow_preparation` to the same preparation builder so a provider
  overflow compacts and retries once instead of draining the run. The
  adapter already classifies overflow uniformly and counts cache writes
  toward the comparison.
- **Manual** compaction needs zero new protocol: `Compact(strand,
  instructions)` exists; it needs only the same hooks to stop declining.

Deliberately not adopted now: omp's mid-turn and idle triggers, context
promotion, and speculative compaction. Checkpoint-only is what the
machine proves properties about; each of those is an optimization with
real concurrency surface (speculation especially), and none is needed to
stop overflowing. They are Stage 2 candidates, behind evidence.

## What the summary request actually is

This is the genuinely contentious decision. Two defensible shapes:

**(a) Serialized preparation, pi-style.** `client/wiring.dispatch` maps
a `SummaryRequest` to a plain generation: the summarization system
prompt, one user message containing the serialized
`messages_to_summarize` (plus `<previous-summary>` when present, plus
custom instructions), no tools. The serialization and the two prompts
(initial + iterative update; a third for split-turn prefixes) are pi's,
ported into the `prompt` package as named pack sections so they are
versioned, decoded, and byte-stable like everything else. The input is
exactly the frozen `op.preparation` register — the provider sees what
the decision hook approved, which is the property the register exists to
guarantee.

**(b) Live-prefix reuse, omp-handoff-style.** Send the real projected
context — which is byte-identical to the last generation request's
prefix and therefore warm in cache — plus one appended user instruction,
and read the history at 0.1× instead of re-uploading a serialization at
1×. At a 150k-token compaction point, (a) pays roughly 40–80k fresh
input tokens for the serialized text; (b) pays ~15k-equivalent
(150k × 0.1) plus a small write. Three-to-five-fold cheaper, and the
model sees richer input (real tool structure, not truncated text).

The recommendation is **(a) first, (b) later, and honestly**. (a) is a
small, provider-neutral change that matches the frozen preparation
contract as written. (b) sends input that is *not* the preparation
register's content (it includes the retained tail; its bytes are the
projection, not the serialization), so it touches the frozen structural
contracts and deserves a `protocol-change/` note plus real measurements
— including the failure mode omp handles where a provider rejects
`toolChoice: "none"`. Either way, two of pi's rules carry over verbatim:
the summary settles like any assistant settlement (its usage rows land
in the ledger — the machine already writes them), and a response that
attempts tool calls is a failed attempt.

For shape (a), one cache decision: mark no breakpoints on summary
requests at all. pi's `cacheRetention: "none"` is right — a one-shot
prompt read once is pure cache-write waste. The adapter currently spends
all four breakpoints unconditionally, so this is a small adapter change
keyed off the request kind.

## What it produces, and where it lives

Exactly the built shape: a `CompactionEntry` appended at the leaf, with
the generated summary, the complete retained tail, `tokens_before` from
the preparation, `from_hook: False`, and the summarizer's usage. Adopt
pi's structured summary format and its file-operations tracking
(`FileOperations` already exists on the preparation, currently always
empty — filling it means extracting read/write/edit paths from tool
calls in the summarized span and merging the previous compaction's
lists). Blob refs deserve one Loom-specific addition to the prompt: an
instruction to carry forward `{ref}` names for oversized outputs, since
the refs remain readable via `fs_read` after the excerpts are
summarized away.

Branch summaries ride the same wiring for free: the machine's navigation
host and `BranchSummaryPreparation` are built, the summary path is the
same `SummaryRequest` loop, and the projection already renders branch
summaries as user-message context. They should ship in the same stage as
threshold compaction, because they exercise the identical seams.

## Pricing the cache interaction, concretely

The adapter's own comment block states the mechanism ("What rewriting
history costs", `anthropic.gleam:371`); here is the arithmetic for this
design. Layout: two 1h breakpoints on tools+system, two 5m breakpoints
rolling on the last two user turns.

- **The head survives compaction by construction.** Tools and system
  render before messages and their bytes do not change, so the 1h
  prefix still reads at 0.1× on the first post-compaction request. Only
  the message region misses.
- **The first post-compaction request** re-pays the message region as
  fresh input — but that region is now summary + retained tail, ~22k
  tokens under default settings, not the 150k it replaced. Cost: ~22k
  at 1× (plus 1.25× on the new 5m marks) instead of ~150k at 0.1×. Call
  it roughly 22k-equivalent versus 15k-equivalent — the *cache* cost of
  compacting is about half a turn's input, once.
- **Every subsequent turn** reads ~25k instead of ~150k at 0.1× — the
  compaction pays for its own cache miss within one to two turns, before
  counting the far larger saving on what the window can now hold.
- **The summary call itself** is the dominant cost: 40–80k fresh tokens
  in shape (a), ~15k-equivalent in shape (b), plus output.

The conclusion worth stating plainly: *in Loom's breakpoint layout,
compaction's cache damage is small and self-amortizing.* The expensive
cache mistakes available to this design are elsewhere — churning the
pinned system prompt (memory injection done wrong, Part 3) and paying
cache writes on one-shot summary requests (declined above). Where the
tension is real is *timing*: compacting earlier than needed throws away
context the model may still want and buys little, because pre-compaction
turns were already reading at 0.1×. That argues for pi's late trigger
(window minus reserve) over aggressive fractional thresholds.

---

# Part 3 — Memory

## What each kind is for

"Memory" hides four different jobs. Naming them keeps the design from
building one blurry thing:

1. **Working memory (within one session):** what parallel strands and
   successive operations need to share right now. Loom already has this
   — the blackboard, agent notes, `cap/kv` — and it is under-surfaced,
   not under-built.
2. **Episodic recall (across sessions):** "have I seen this error
   before; what happened last time in this file?" Wants search over
   *what actually happened*, with provenance. Loom has the substrate
   already indexed.
3. **Distilled knowledge (across sessions):** stable preferences,
   project facts, resolved gotchas — small, curated, injected at start.
   This is omp's `memory_summary.md` / mental models. Loom has nothing.
4. **Procedural knowledge:** playbooks promoted from repetition. The
   spec already names this as follow-up track 8 ("promotion path
   memory→L1 skill") and it stays out of scope here.

The best answer for Loom is composition for 1 and 2, modest construction
for 3, and deferral for 4.

## Working memory: surface what exists

The blackboard is durable, transactional, and already has model doors —
but nothing ever *shows* a strand its notes unprompted; a subagent's
notes come back with its result, and everything else requires the model
to think to call `agent_notes`. The `run_start` hook (built, inert) is
the right seam: inject a compact digest of the caller's `agent/`
namespace at run start as ordinary born-placed messages. Two properties
make this safe and cheap: run-start messages are appended entries, so
they ride the rolling 5m tail and never touch the pinned head; and the
digest is data from a store the model already wrote through a
capability-checked door, not a new trust surface.

`cap/kv` stays exactly what it is — ephemeral scratch for code-mode
programs. It is explicitly not memory ("may be evicted or reset between
calls") and promoting it would betray its contract; anything worth
keeping already has an exit via `cap/report` artifacts.

## Episodic recall: the index is already built — expose it

The FTS index spans every session in the repository, and its one
documented scoping "limitation" — a query cannot be restricted to a
session — is, read from this angle, exactly the shape cross-session
recall needs. The proposal is a harness tool (a tool, not a capability —
it runs trusted, brokered, outside the jail, per the precedent in the
agent-comms note): `history_search(query, limit)` over `events/search`,
returning ranked snippets with session and entry ids. Branch summaries
and compaction summaries are entries, so once Part 2 ships, the index
holds *distillates* of old work as well as raw transcript — search gets
better as compaction runs, for free.

Three pieces of honest fine print, all from `events.md`: session scoping
must be *added* for the within-session use of the same tool (the rank/
LIMIT interaction means post-filtering is wrong — the scope belongs in
the SQL); CJK content is unsearchable until the tokenizer changes; and
nothing currently calls `search.open`, so wiring it into `client/serve`
with sync driven off the event bus is part of the work, not an
afterthought. Recall output is fenced as data, like any tool result — it
is quoted history, not instructions.

No vector store. FTS5 with ranked snippets over role-structured,
path-dense engineering transcripts is a strong baseline, costs zero new
dependencies (the design's dependency posture is deliberately spare),
and the upgrade path (a `trigram`/ICU tokenizer, or embeddings later) is
additive. Building semantic retrieval before the lexical baseline is
even wired would be construction for its own sake.

## Distilled knowledge: a memory session, written by a pipeline

For cross-session distillates Loom needs a durable home that is none of:
the workspace (models edit files there; memory must not be silently
model-writable), the pinned prompt (cache), or a new store (the last
thing this repo needs is a fourth storage concept). The proposal: **a
dedicated memory session per workspace** — an ordinary session file
whose tree is the memory log. Distillates are `CustomEntry` rows under
registered types (`memory/fact`, `memory/lesson`, `memory/preference`),
each carrying provenance: the source session id and the entry ids it was
distilled from. Everything is inherited rather than built: write-once
durability, total decoders, the conformance suite, FTS indexing (the
index spans sessions — memory becomes searchable through the same
`history_search`), and the projection machinery for rendering.

The pipeline is omp's two-phase local design, translated to BEAM idiom:
an operator-scheduled background job (not a per-turn hook) that walks
persisted sessions changed since their last processing, runs per-session
extraction on a cheap model role, then a lease-guarded consolidation
pass that *replaces* the current distillate head — by appending, as
ever. omp's numbers are sane defaults: skip sessions younger than a few
idle hours or older than ~30 days, cap consolidation input, cap the
injected digest at ~5k tokens. Secret redaction before commit is not
optional; the ledger rows for extraction/consolidation land in the
memory session's own usage ledger, so memory's cost is visible.

Injection follows two hard rules, both cache rules, both learned from
omp and consistent with the Manus production evidence:

1. **Memory rides messages, never the pinned head.** The digest is
   injected via `run_start` as ordinary entries. The system-prompt pack
   stays byte-stable. (A changed distillate therefore costs one 5m tail
   write, not a session-wide 2× head rewrite.)
2. **Memory updates land at session boundaries**, not mid-session — the
   equivalent of omp's "learn does not mutate the active prompt-cache
   prefix."

And one framing rule, verbatim from omp because it is a correctness
statement: memory is heuristic context; repo state and user instruction
win conflicts; conflicting memory is stale.

An explicit `remember` tool (omp's `learn`) — the model appending a
lesson through a harness tool with the same caps (entry-count and size)
— is cheap once the memory session exists, and is the only
model-initiated write path into it. Reserved-prefix discipline applies:
the distillation pipeline and the `remember` door write disjoint entry
types, so a model cannot forge a "consolidated" fact.

## The security paragraph this design owes

Memory is durable prompt injection by construction: content influenced
by one session's inputs steers later sessions. Loom's posture ("prompts
are UX, never a control") bounds the blast radius — nothing a poisoned
memory says can widen a policy, mint a token, or touch the effect plane
— but three mitigations belong in the design anyway: provenance on every
distillate (auditable back to source entries); injection always fenced
and attributed ("distilled from session X, N sessions ago"), never
presented as operator text; and the anti-feedback rule — recalled or
injected memory blocks are excluded from later retention passes, omp's
tag-stripping made structural (the pipeline skips `memory/*` entries and
injected digests by type, not by string matching).

One genuinely unsolved interaction, named rather than hand-waved: the
precise rewrite's "erase X" contract cannot mechanically reach prose
*derived* from X. A distillate summarizing an erased secret survives its
erasure. Provenance makes cascade deletion *possible* (erase X → find
distillates naming X's entries → re-consolidate without them), and the
pipeline should implement exactly that; but a consolidation-of-a-
consolidation weakens the link, and the honest statement is that erasure
guarantees stop at the first derivation unless every derivation keeps
full source lists. The compaction analog is already covered — the spec's
erase-X audit includes retained-tail copies — and summaries share the
retained-tail's exposure: an erased entry's content may live on in a
compaction summary's prose. Erasure-sensitive deployments re-summarize
after erasure; the tooling should make that one operation.

---

# Part 4 — The honest costs

- **Compaction is lossy, and the loss is silent.** A summary that drops
  a load-bearing constraint produces a model that proceeds confidently
  without it — a correctness price, not a token price, and the one pi's
  structured format, iterative-update rule, and "preserve exact paths
  and error messages" instruction exist to reduce, not eliminate. Loom's
  mitigation is stronger than the references': the full history remains
  in the tree — navigable by fork and reachable by `history_search` —
  so the loss is recoverable *when noticed*. Nothing recovers it when
  unnoticed.
- **Split turns double the summary cost** (two model calls) and produce
  the weakest summaries, since the model summarizes half a thought. This
  is inherent to the cut-point rule; blob offload makes giant single
  turns rarer in Loom than in pi, but not impossible.
- **The summary call is real money at the worst moment** — by
  construction it fires when context is largest. Shape (a): 40–80k fresh
  input tokens per compaction. Shape (b) cuts that ~3–5× at the cost of
  contract complexity. Usage rows make the spend visible either way.
- **The cache miss is small but real:** roughly one turn's worth of
  re-written message region, amortized within a turn or two (arithmetic
  in Part 2). The design's *avoidable* cache costs — head churn from
  memory, cache writes on one-shot summaries — are avoided by rule, and
  those rules must be tested, because both regress silently as pure
  cost.
- **Retained-tail copies duplicate bytes** and widen the erase-X audit
  surface (every copy of an entry must be scrubbed). That is the price
  of self-contained checkpoints, single-scan projection, and bounded
  fork copies; the spec already carries the audit test.
- **Memory grows without bound unless bounded.** Caps everywhere or the
  digest eats its token budget and the pipeline eats its model budget:
  entry caps, per-entry size caps, injection token cap,
  consolidation-input cap, session-age windows. All have omp precedents;
  all are settings someone must actually enforce at write time.
- **Stale memory misleads.** A distilled "the tests are flaky in
  events" outlives the fix. Consolidation refresh plus the "repo state
  wins" framing is mitigation, not solution; memory quality is a
  maintenance liability accepted knowingly or not at all.
- **The pipeline is new moving machinery** — leases, heartbeats, a
  background writer per workspace — in a codebase whose discipline is
  that machinery earns its keep by conformance suites. Memory ships with
  scenario coverage or it will be the least-tested writer in the system,
  touching the store everything else trusts.

---

# Part 5 — The staged plan

## Stage C0 — compaction becomes live (the bar is "runs at all")

The gap is wiring, not machinery. Concretely:

1. `client/wiring.Config` grows the compaction inputs (settings; the
   projection read it already has through the session); `build_effects`
   builds hooks through `runtime/hooks` instead of installing defaults:
   real `admission` from gateway model facts; the usage-aware
   `threshold` (durable last-usage + trailing estimate + stale guard);
   `structural_decision` returning `VerdictGenerate`;
   `overflow_preparation` sharing the threshold's preparation builder;
   `resolution` consulting the gateway.
2. `dispatch` maps `SummaryRequest` to a real gateway request — shape
   (a): serialization of the frozen preparation + the ported pi prompts
   as pack sections; no cache breakpoints on these requests;
   `summary_progress` parses the settled response into
   `SummaryProduced`/`SummaryFailed`.
3. Exit criteria: the M3 demo passes with its `demo_hooks` deleted —
   compaction answered by the real seams against the sim gateway; a
   conformance scenario drives threshold, overflow-retry, and manual
   `Compact` end-to-end including kill/recover mid-compaction; `make
   e2e` shows a session crossing the threshold, compacting, and
   continuing.

## Stage C1 — compaction becomes good

File-operation tracking filled in and rendered; blob-ref carry-forward
in the prompt; branch summaries wired through the navigation host (same
seams, small delta); `tokens_before` recomputed at commit; TUI treatment
of the compaction divider (omp's inline-divider display is the model —
scrollback intact, context reset visible).

## Stage C2 — cache-clever, behind measurements

Evaluate shape (b) (live-prefix summary requests) with a
`protocol-change/` note and real cost numbers from C0 telemetry;
consider omp-style cache-aware elision of superseded reads; consider
speculative compaction only if C0 shows summarization latency actually
hurting interactive sessions. Snapcompact-class ideas are research, not
roadmap.

## Stage M1 — recall and surfacing (composition only) — **built**

Wire `events/search` into `client/serve`; add session scoping in SQL;
register the `history_search` tool; inject the `agent/` notes digest via
`run_start`. No new storage, no new services. Exit: a fresh session
finds, by search, a decision made in a previous session's
compacted-away history.

Shipped as issue #28, with one design change worth recording. The plan
here said "event-bus-driven sync"; what landed is driven by the
**writer's own commit publication** — a second subscriber on
`api.Options.subscribers`, the `client/gateway.commit_forwarder`
pattern, poking a named holder actor that owns the index. A one-session
server's writer sits in the same VM as its index, so a bus subscription
would have made the same pull happen twice and bought a `pg` scope for
nothing. Hints stay lossy either way; the sync's own durable cursor is
what makes a lost hint cost latency rather than a row.

Two gaps are accepted rather than hidden, and both are written down in
`docs/spec-gaps.md` "From WP-K": there is no backfill (a session's rows
enter the index while it runs, so a session never reopened stays
unfindable), and an injected digest is indexed like any other user
message. The structural anti-feedback exclusion belongs to M2.

## Stage M2 — the memory session and the pipeline

Registered `memory/*` custom entry types with provenance; the
distillation pipeline (extract → consolidate, leased, capped, redacted)
writing to a per-workspace memory session; `run_start` injection of the
digest under a token cap, fenced and attributed; the `remember` tool.
Exit: conformance scenarios for the pipeline's crash points and caps; a
demonstrated preference persisting across two sessions; the anti-
feedback exclusion tested.

## Stage M3 — judged later, on M2 evidence

Retention cadence during sessions (omp's every-N-turns), mental-model-
style named distillates, cross-workspace memory, tokenizer upgrade for
the index, spec track 8's promotion path memory→skill. Each is an
extension of a running system, which is the only position worth
designing them from.

## Open questions, owned here rather than hidden

- Whether `ThresholdQuery`/hook signatures need a usage-bearing field or
  the usage-aware fold inside the registry suffices (current reading:
  the fold suffices; confirm against the frozen `PlannerInputs` before
  C0).
- Which model role summarizes. pi uses the session model; omp routes to
  a cheap role. Loom's role routing (design §4.4) makes the cheap-role
  answer natural, but summary quality is the correctness-critical
  variable — decide with an eval, not a preference.
- Where compaction settings live and who validates them (spec §3.2 says
  "validated at set time"; nothing sets them today).
- Whether the memory session is one per workspace or one per repository
  identity, and what names it (the omp lowercased-basename lesson says:
  decide the fold explicitly, or one repo becomes two memories).

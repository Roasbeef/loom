# Compaction

Loom bounds a strand's active context by appending a checkpoint to its
conversation tree. The checkpoint contains a bounded snapshot of the
strand's notes and a verbatim recent tail. Older entries remain in the
store; they stop appearing in the next model request. The host builds the
checkpoint locally, without asking a model to summarize the transcript.

This document describes the notes-based policy in PR #223. Deployment
starts fresh sessions. Resuming an in-flight task from the removed
summarizer implementation is outside this change's supported rollout.

The policy depends on three distinct mechanisms:

| Mechanism | Responsibility | Limit |
|---|---|---|
| `agent_note` and `agent_notes` | Maintain and retrieve the strand's working notes. | The model decides what to record; the harness does not prove completeness. |
| Compaction | Replace older projected conversation with a notes snapshot and recent messages. | Snapshot size is bounded; the newest exchange may exceed the recent-token target. |
| `history_search` | Find excerpts, then retrieve complete entries by session and entry IDs. | Search covers indexed text in registered repository sessions, not every possible source. |

The durable transcript is the source for recall under both the former
summarizer policy and this policy. Removing the summarizer does not make
history durable for the first time. It removes a provider dependency and
an additional model's choice of what to preserve, while placing more
responsibility on the working agent's note-taking and retrieval.

## The durable boundary

A `CompactionEntry` is an append, not a rewrite. It is parented on the
strand's current leaf and stores the replacement text plus the retained
messages. Publication moves the leaf in the same transaction. A crash
therefore exposes either the prior context or the committed checkpoint,
not a partially replaced conversation.

Projection scans backward to the newest compaction, includes it, and
stops. The checkpoint text becomes a user message, followed by the
retained tail and subsequent entries. Neither the notes nor recalled
history becomes system instructions. The original entries remain
available to storage scans and exact history reads.

The frozen structural contract still calls the replacement text
`summary` and the cut input `messages_to_summarize`. Those names do not
imply a summarizer call. This host supplies the text through
`VerdictSupplied`; it does not select the generation path. The retained
structural machinery also serves branch operations and remains part of
the frozen interface.

```mermaid
flowchart LR
    T[Threshold or provider overflow] --> P[Frozen preparation]
    O[Operator compact] --> P
    P --> C[Local checkpoint from notes]
    N[Strand note registers] --> C
    C --> H[before_compact additions]
    H --> D[Commit checkpoint and leaf]
    D --> G[Project checkpoint plus retained tail]
    S[Original durable entries] --> R[Search excerpts and exact reads]
```

`before_compact` extensions can append notes to a supplied checkpoint.
Their additions pass through the structural lifecycle before publication;
an extension does not rewrite the already committed transcript. The
checkpoint's 16 KiB note cap bounds the strand-note block, not arbitrary
extension additions or the entire eventual provider request.

## What survives a cut

`runtime/hooks.preparation` is shared by threshold, overflow and operator
compaction. It selects a contiguous suffix using `keep_recent_tokens`,
then applies two retention rules:

1. Keep the newest assistant message and every message after it. Those
   messages can contain tool results or queued user input that the model
   has not read. Before the first assistant message, keep all input.
2. If the candidate boundary starts on a tool result, move it backward to
   retain the assistant call and its results together.

The token setting is a target, not a hard cap. For example, a batch that
returns 25,000 tokens survives a 20,000-token recent target. Trimming the
batch to satisfy the target could remove the result that caused the
threshold crossing before the agent ever sees it.

If this protected exchange cannot fit the model's window, compaction may
not recover enough room. The existing overflow path then reports failure.
A successful cut must not conceal the failure by discarding unread input.
If there is nothing eligible to cut, preparation is empty.

The replacement text contains the closed-window ordinal, cut and retained
message counts, the pre-cut context estimate, the strand's notes, and any
operator compaction instructions. Its note block is capped at **16,384
bytes**, newest-written first. Older notes may be omitted, and a single
oversized note may be clipped. The text identifies truncation and points
to `agent_notes` for the complete board. Bytes are not model tokens; the
rough four-characters-per-token estimate is not a universal bound.

When a prior checkpoint exists on the branch, the new text includes its
session and entry IDs. A child strand can inherit a checkpoint while
having an empty note board of its own. The reference makes that inherited
context retrievable without recursively embedding all prior checkpoints.
It does not guarantee that the child notices an omission. The prompt
asks the child to copy relevant inherited requirements into its own notes.

## Notes and the system prompt

The default prompt tells the agent to maintain a small set of current
notes: objective, constraints, decisions, progress, evidence, and next
steps. Stable keys are preferable to one new key per event, because the
snapshot has a fixed byte budget. Notes should include concrete file and
entry IDs, test outcomes, failed approaches, and unfinished work.

The agent should update notes before a large tool batch, not wait for a
capacity reminder. A tool result can move context from below the reminder
point to above the compaction point in one step. Loom currently provides
no guaranteed final note-writing turn.

Run-start note injection still matters. `client/notes.digest_hooks`
appends a user message containing up to **4,096 bytes** of the current
strand's notes. An empty board injects nothing. This refreshes mutable
notes that may have changed since the last checkpoint, including notes
written after it. The immutable checkpoint remains the snapshot that was
published at its own boundary.

Both renderings quote and attribute notes as historical data. Their
fences prevent text from closing the surrounding presentation; they do
not prove that a model will ignore a malicious instruction in that text.
The prompt must preserve the distinction between recalled facts and
current instructions. It also asks the agent to verify facts against
current evidence when the distinction matters.

The system prompt is pinned for a session. This rollout assumes new
sessions receive the new default. Mutable note contents are not inserted
into that system prompt: doing so would change its cached prefix on each
update and give model-authored records the wrong instruction authority.
If an operator removes note or recall tools, the model must respect its
actual tool schema. The checkpoint checks the strand's active tool list
before advertising history search.

## Triggers and context introspection

Automatic compaction is checked at run checkpoints, including the
boundary where a run may finish. With context window `W` and reserve `R`,
the threshold is **estimated context > W − R**. The machine records which
trigger entry it already checked, so the same boundary does not repeatedly
request compaction. Host defaults are a 16,384-token reserve and a
20,000-token recent target; invalid settings disable compaction.

The context fold uses the latest useful provider usage report plus
estimates for later messages. After a cut, it excludes usage reports
inside the carried tail: those reports measured the context that was
replaced. Without that exclusion, an old report could immediately fire
the threshold again. Estimation remains approximate and does not promise
an exact provider-side count of every prompt, tool schema or image.

The host uses each strand's configured model window, falling back to its
configured default when model facts are unavailable. Switching a strand
to a smaller model therefore changes the threshold it is measured against.

A transient reminder is appended to generation requests after context
passes **W − 2R**. It repeats while the strand remains in that band; it is
not a durable, one-time fallback phase. Threshold compaction runs before
the next generation, so a sufficiently large result can skip the band.

`context_remaining` reports the caller's strand, current window ordinal,
estimated usage, space before the checkpoint threshold, recent-token
target and note count. Its strand identity comes from harness coordinates,
not model arguments. It reports whether compaction is disabled. It does
not reserve capacity, write notes, or request a cut.

A provider context-overflow settlement can also trigger one recovery
compaction. The structural state records that attempt before publication;
a subsequent overflow follows the existing failure path instead of
retrying indefinitely. Operator `compact` uses the same preparation and
publication machinery. There is currently **no model-callable
`new_context` or equivalent compact tool**.

If checkpoint construction cannot read its required durable state, it
declines rather than claiming that the strand wrote no notes. A declined
threshold compaction leaves the run alive; a declined overflow recovery
cannot recover the rejected request and drains the run. The original
transcript is still present in both cases.

## Search, exact recall and large results

`history_search` uses a repository-wide SQLite FTS5 index. Ordinary calls
use `query`, optional `scope` (`repository` or `session`), and a hit limit
clamped to 1–50. Search returns ranked excerpts with canonical session and
entry IDs. SQLite currently chooses a 12-FTS-token snippet; those are
search-index tokens, not model tokens.

A subsequent call retrieves the complete entry:

```json
{"action":"read","session":"<session ID from hit>","entry":"<entry ID from hit>"}
```

The host records source paths in the rebuildable index. The model supplies
IDs, never a database path. An exact read resolves the host's locator,
opens the source read-only, validates its canonical session identity,
and decodes the stored entry using the ordinary total decoder. It neither
acquires nor renews a writer lease and cannot create a missing source.
Unknown IDs, a mismatched source, corruption or an unavailable file
produce explicit failures. Removing a session from the index also removes
its source locator.

Exact reads return the complete encoded entry, including fields that FTS
does not search. The current FTS extraction covers user, assistant and
tool-result text plus compaction and branch-summary text. It does not
index tool-call arguments, thinking, images or custom-entry payloads.
Exact reads can inspect those fields when an entry ID is known; they do
not make an unindexed term searchable. Parent IDs in full entries also
provide addresses for following preceding context. Window listing and
paged transcript browsing are not implemented by this extension.

Entries larger than **65,536 bytes** spill to the content-addressed blob
store. The tool returns bounded excerpts and an explicit path; it does
not duplicate the complete payload in result details. A failed blob write
returns an error rather than truncated success. Spill is implemented by
this tool; it is not an automatic wrapper around every tool result.

The stored JSON may contain a very long single line. `fs_read` refuses a
rendered window over 64 KiB and a file over 8 MiB, so line pagination alone
cannot read every blob. The result directs the agent to bounded byte-range
reads through `bash` for these cases. This is a delivery limitation when
the host has disabled that tool. Blob spill bounds model-context delivery;
it does not bound the decoded entry's peak allocation inside the harness.

Sessions are indexed while running and on reopen. There is no repository
backfill service. A never-indexed session is not searchable, and a removed
or moved source may make an old hit unreadable. The index has no authority
over session commits; a failed sync does not roll back conversation.

A future vector index can share these source IDs and exact reads. FTS
would still serve exact names and errors, while embeddings could retrieve
semantically related passages. Such an index remains derived data, with
its own model-version and rewrite invalidation rules. The current sqlight
surface exposes no extension-loader API; trusted registration or binding
support and release packaging would need validation. No embedding model
or vector extension is introduced by this change.

## Codex prior art and issue #132

[Issue #132](https://github.com/Roasbeef/loom/issues/132) discusses both
context policy and a separate projected task-state design. Notes-based
compaction does not implement that projected state, transactional
`state_patch`, or a schema that proves task-state completeness.

The relevant Codex changes establish several separate mechanisms:

| Codex change | Mechanism | Loom status |
|---|---|---|
| [#29743](https://github.com/openai/codex/pull/29743) | Local reset at token-budget compaction, retaining fresh initial context. | Local checkpoint publication; Loom also retains a recent exchange. |
| [#33255](https://github.com/openai/codex/pull/33255) | A final fallback phase with additional room and tools available before reset. | Not implemented; the transient reminder is weaker. |
| [#39827](https://github.com/openai/codex/pull/39827) | History window/item listing, exact reads and search; separate note operations. | FTS search and exact entry reads, plus strand notes. Window browsing remains absent. |
| [#40539](https://github.com/openai/codex/pull/40539) | A bounded thread hint, with native-provider handling. | Run-start note content and checkpoint snapshots use user-context messages. |

A hard reset, note persistence, note injection, retrieval and a final
fallback phase are separate choices. Sharing some of them is not evidence
that Loom has reproduced Codex's full behavior or quality. The current
policy follows the issue's later choice of notes as the default; it is
not a measured claim of superiority over summarization.

## Verification and remaining evidence

The deterministic tests cover preparation boundaries, checkpoint
rendering and truncation, context arithmetic, supplied checkpoint hooks,
provider-overflow recovery, exact cross-session reads, writer-lease
preservation, source validation and large-entry spill behavior. Scripted
providers establish harness transitions; they do not establish whether a
real model writes useful notes or recalls an omitted constraint.

A quality comparison should cross at least two boundaries with a real
provider. It should hide checkable requirements, decisions and tool-result
canaries in the early conversation; require real `agent_note` calls;
exercise restart and a child with an independent board; and require exact
retrieval of a fact omitted from the notes. Compare against a pinned
summarizer baseline using final task correctness, missed constraints,
recall success, note and retrieval tokens, latency and provider cost.
That comparison has not been completed here. “State of the art” is an
evaluation target, not a property conferred by the architecture alone.

## Source map

| Source | Responsibility |
|---|---|
| `core/entry.gleam`, `session/session.gleam` | Durable checkpoint format and context projection. |
| `machine/operation.gleam`, `machine/planner.gleam` | Frozen preparations, threshold guards and structural publication. |
| `runtime/hooks.gleam` | Usage accounting and retention boundaries. |
| `runtime/strand_runtime.gleam` | Hook execution and durable driver transitions. |
| `client/checkpoint.gleam`, `client/wiring.gleam` | Notes snapshot, prior-checkpoint references, reminder and host decisions. |
| `client/notes.gleam`, `prompt/default.gleam` | Run-start digest and agent note-taking protocol. |
| `tools/history.gleam`, `client/history.gleam` | Search/read tool contract and host-owned source resolution. |
| `events/search.gleam`, `storage/sqlite.gleam` | Rebuildable index and lease-free source reads. |

# Memory as recall, not a digest

Status: proposed, 2026-10-11. Supersedes the injection rules in
`compaction-and-memory.md` Part 3 for the managed daemon.

## Problem

Today a background pass distils saved sessions into a digest, and the digest is
injected into every run. Three properties make that hard to trust.

- **The model decides what is worth keeping, once, and the decision is
  undated.** A fact that was true in September is injected in October with no
  signal that it may have changed.
- **Injection is unconditional.** Every run pays the tokens whether or not the
  digest is relevant to the prompt, and a stale or off-topic row can steer the
  run.
- **Nobody can see whether it helps.** The only visible trace is a collapsed
  `Memory · n lines` row. There is no read count, no age and no way to trace a
  row to the words that produced it.

An audit of Claude Code's equivalent feature (Theo, "Turn off Claude Code's
Memory") found 26 of 45 saved memories never read and about three writes per
read. We have not measured our own store. The one on this machine holds eight
`remember` notes and no consolidated digest, because the owner turned the pass
off.

## Decision

Keep the raw record and make it cheap to search. Stop writing conclusions on
the model's behalf.

1. **The digest is off by default.** A new `[memory] inject` key gates the
   `run_start` hook, and `distill` defaults to `off`. Setting `inject` to
   `digest` opts back in and implies a pass unless `distill` is set explicitly. (The digest
   and the pass were later removed; see "What happens to distillation" below.)
   `remember` stays registered, and the old pipeline stays available.
2. **`history_search` becomes the memory tool.** The index already covers every
   saved session. It gains what a retrieval tool needs: a safe word mode,
   a `kind` filter, `before` paging, a read with surrounding entries, and a
   date and kind on every hit. Each hit names its session and entry, so every
   answer traces to the original words.
3. **Notes are typed, dated and searchable, and writing one never asks the
   owner.** `remember` takes a `title`, a one-line `description`, a `note`
   and a `kind` (`feedback`, `fact` or `decision`), and its description
   asks for the reason and how to apply it, the shape of the owner's own
   Claude Code notes. A note is indexed under kind `note`, so
   `history_search kind=note` finds it with its date and provenance. A bounded
   index is injected by default, because a note the model never sees is a
   write-only store: one line per note, newest first, in the form
   `- (kind, date) title: description`, capped at about 1 KiB. When notes are
   dropped to fit, a last line says how many remain and names the search that
   finds them. Bodies are fetched on demand. `inject = "off"` turns the index
   off. The index is small and removable on purpose: as models get better at
   deciding what to look up, it should be possible to delete it without
   touching anything else.
4. **Standing rules are proposed, never saved.** A model that notices a
   correction worth keeping calls `propose`. The call returns at once with a
   proposal id and the run continues. The proposal waits in a durable queue
   until the owner reviews it, near the end of a session or later. Approving
   one applies a digest-bound edit to `loom-rules.md`, a file the harness owns
   in the domain's persisted directory under the Loom home, next to
   `loom-memory.db` and `loom-search.db` and outside the project checkout. The
   prompt renders it in its own fence,
   `<instructions origin="approved-proposal">`, after the operator's files,
   with the date and source session. The workspace `AGENTS.md` is never
   written: in this repository it is a generated mirror of `CLAUDE.md`, and
   a model-authored sentence in the operator's own file would speak in the
   operator's voice to every later session, which `client/rules.gleam`
   refuses. The owner's approval is what makes a proposal an instruction. The
   model can never write a rule directly. Rejecting one records the decision.
5. **The UI shows recall as a step and proposals as a queue.** No digest
   message means no `Memory` row. A `history_search` call renders its query,
   hit count and source sessions. A pending-proposals badge appears in the
   terminal footer and the web header, and opens a review pane.

### What happens to distillation

The pass read saved sessions, extracted candidate facts, lessons and
preferences, and consolidated them with outstanding notes into the head that
rendered the digest. With the digest off by default and notes searchable
directly, its output reached no run unless the owner set `inject = "digest"`.
This note first kept it in the tree as an opt-in, to be deleted after the
counters below had run for a while.

**Update: the pipeline was removed.** The owner never turned it on, and an
opt-in that nobody uses is still code to keep correct. The change deleted
`client/distill`, `client/distillpass`, the domain maintenance worker and its
quiesce and resume handshake in the daemon registry, the erasure cascade, the
cursors, the digest sidecar and its run-start hook, and the `loom-distill`
command. What stays is what notes need: the store, the lifetime counter, the
notes index, and the single-prompt model requests the block summaries and the
glance loop make (now `client/auxiliary`).

Two compatibility rules follow from not touching a user's data. An existing
`loom-memory.db` may hold distillate rows and `distill/*` cells; nothing reads
them, and the file is not rewritten. An existing `loom-memory.digest` is left
on disk and never read. The `[memory]` table keeps parsing `distill = "off"`,
because a file written while the pass existed says exactly that and an unknown
key is a parse error; `inject = "digest"`, `distill_wall_ms` and any other
`distill` value are refused with a message that the pipeline was removed.

### Scopes

Memory is keyed per admitted domain, `WorkspacePrivate` or `SessionOnly`
(`storage/domain.gleam`). Notes and the search index are both per domain, and
nothing crosses workspaces. There is no user-global store and this change does
not add one. Cross-repository preferences are text the owner edits in the
global `AGENTS.md`. A later proposal kind may target that file. A global index
would put one repository's quoted text into another's context.

## What OptChat contributes

OptChat (`ericjuta/omp-optchat` v0.7.0) keeps an append-only log of every
message beside a tree of summaries, and its harness found that exact-word
search over the original log recovered all 12 planted facts where navigating
summaries found 3 to 5. We take the search and open-the-original tools, the
explicit "no answer found" failure, and the principle that the log is the
truth. We do not take the summary tree: Loom already has compaction, and a
second summary hierarchy would be the staleness problem again. We do not take
the judge-guided `chat_recall` yet. It needs a measured judge, and the first
step is to see whether search alone suffices.

## Contracts between slices

### Search (slice A)

`history_search` arguments, all optional except `action`:

| Argument | Meaning |
|---|---|
| `query` | Words. Each token is quoted as an FTS5 prefix term (`deploy` becomes `"deploy"*`) and the tokens are ANDed. A bare `OR` token between two words is kept as the OR operator, so `deploy OR release` works. |
| `syntax` | `words` (default) or `raw`, which passes FTS5 syntax through. |
| `kind` | `user`, `assistant`, `tool`, `summary`, or `note`. |
| `before` | An entry id. Only hits with a smaller `(session, entry)` order are returned. |
| `around` | With `read`, the number of neighbouring entries to return on each side, 0 to 5. |

Each hit carries `session`, `entry`, `kind`, `ts` (milliseconds since the
epoch) and `snippet`. The index records `kind` and `ts` at index time. The
schema version moves up one, and an older file is migrated by a version marker
and a resync, never by deleting the file.

### Injection (slice B)

`distillpass.Options` gained `inject: Off | Digest`, with `inject = "digest"`
refused when `distill` was `off`, so no combination hid a pass. Unknown keys
stayed an error. A later slice added a `Notes` variant, the bounded index of
note titles, and made it the default. That option type is now
`memory_config.Options`, whose `inject` is `Off | Notes`.

### Proposals (slice C)

A proposal is `{id, kind, target, base_digest, old, new, rationale, source,
created_ms, state}`.

- `kind` is `rule` in this change. `target` is the harness-owned
  `loom-rules.md` beside the domain's memory store, fixed by the host. The
  model cannot choose it and the workspace `AGENTS.md` is never written. A
  config-rule kind is left for the branch that carries the config edit door,
  and a kind that targets the global `AGENTS.md` may follow.
- The prompt renders `loom-rules.md` after the operator's guidance files,
  in its own `<instructions origin="approved-proposal">` fence, with the date
  and source session of each rule. It reaches new sessions only, because the
  prompt is pinned per session.
- `old` must match once, or be empty to append. The match and the base
  digest are checked again at decision time, because the file may have
  changed since the proposal. `new` is capped at 2 KiB.
- `source` is a session id and entry id, so the review pane can show the words
  that prompted the proposal.
- `state` is `pending`, `approved`, `rejected`, or `stale`. A proposal is
  `stale` when `base_digest` no longer matches the file at decision time.
- Storage is a `fact.custom` cell `proposal/<id>` in the domain's
  `loom-memory.db`, beside the rules file the proposals edit. The queue is the
  domain's, so a proposal made in one session is reviewed and decided from any
  other. Every write holds the memory store's writer lease, and an approval
  holds it from reading the rules file to marking the proposal, so two
  approvals in different sessions run one after the other. The first
  design kept the cell in the proposing session and could not do either: a
  review showed one session's proposals, and two sessions could both pass the
  digest check and let the second write erase the first rule.
- Session commands: `proposals_get`, `proposal_decide{id, approve|reject}`.
  A `ProposalsChanged` push tells open clients to re-read, as
  `GoalChanged` does; it is published under a key every session of the domain
  shares. This is `protocol-change/086`.
- The tool is `propose`. It validates, stores, and returns
  `queued as <id>`. It never blocks and never raises an approval.

### Rendering (slices D1 and D2)

`history_search` gets a step arm in `session_view/step_words` and
`transcript_lines`: pending text `Searching history for "<query>"`, done text
`<n> hits`, expanded text one line per hit with session, date, kind and snippet.
The proposals list follows `session_view/remembered` and
`web_view/remembered`. The terminal review pane follows `tui/access_overlay`.

## Cut list

- No summary tree, no per-message compressor, no judge gates.
- No new background model calls. The default path makes none.
- No config-file proposal kind and no blocking approval path.
- No note expiry and no per-note read counters. They are machinery for a
  store of eight notes. The counters below say whether they are needed.
- No user-global store, no synonym table and no new tokenizer.
- No automatic deletion of the old store. Existing `remember` notes remain
  readable and the old pipeline still runs on request.

## Verification

Search misses on vocabulary before anything else, because the index has no
stemming: `deploy` does not match `deployed`, let alone `release`. The tool
description tells the model to try two or three variants joined with `OR`,
and a search with no hits echoes the query so the model retries instead of
concluding. The planted-fact test includes a paraphrase set, ten facts each
queried by three wordings the author did not use, so this has a before and
after.

The daemon logs `memory.note_written`, `memory.search_called` with its hit
count and its `note_hits`, the number of hits whose kind is `note` (there is no
separate per-hit event), and `memory.proposal` with its decision, kind and id
and never the proposal's text. Whether any of the owner's eight notes is
ever returned by a search over the next two weeks is the first usage number.

The index migration is checked against a copy of a real `loom-search.db`. Search
quality is checked by an offline test that plants facts in a synthetic corpus
and asserts that word search finds them, which gives "is it useful" a number
that can be re-run. The default-off change is checked by a lifecycle test that
asserted that no digest message reached a run and no extraction turn was
dispatched. The pipeline and that test were removed with it.

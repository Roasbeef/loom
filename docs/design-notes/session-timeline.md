# Session timeline: milestones of a run, so the owner need not read the backlog

Status: proposal, 2026-11-24. Not a commitment. It writes no code and no
protocol change; section 4 outlines the one the build needs.

The owner, looking at the inbox's review thread for a finished session, said
the page "doesn't really seem useful": it shows the diff, the last command and
the agent's last message, and the diff is noisy because the session shared a
folder with other agents. They expected "timeline information": a parse of the
log with a summary model into key milestones, what the agent did, where it is,
as cards with detail that open further, so they do not read the whole backlog.
This note says what a milestone is, who writes each word of a card, where
cards live, how a client reads them and opens the transcript at one, and in what
order to build it. Paths are relative to `packages/` and the tree is
`90692d58f`.

## 1. Summary of the decisions

1. A card is a **span** of one strand's records, cut by a pure function in
   `session_view` at landmarks the records themselves show. Its facts (time,
   steps, files with line counts, a command with its exit status, a sub-agent's
   name, a compaction) come from records with no model.
2. A model writes only a title of at most 64 bytes and a detail line of at most
   200, on the `summarize` route, once per closed card. The text is untrusted,
   drawn as a text node inside a chip that says a model wrote it. No count,
   order, verdict or group depends on it.
3. Cards are stored durably in the catalogue, one row per card, written by a
   harness machine from the writer's commit hints with a durable cursor. A read
   is a keyed query: it scans no transcript, and it works for a saved session.
4. The read is `sessions.timeline`, a bounded page with a "now" card and a
   position for each card (`from_seq`, an entry id) that both clients already
   know how to open: the lane's fold opens by that number.
5. The review thread gets the timeline above the diff, and the diff is split
   by the session's write set: files the session wrote through its edit tools,
   and the others. A per-session worktree makes the second group empty.
6. With `summarize` or `subagent` unrouted the cards still appear, with
   deterministic words for titles. Jev is a later, optional classifier.

## 2. What is there today

- **No model-written summary of a span exists.** The brief for this work said
  compaction summaries are durable summaries of spans. They are not: "no model
  is asked to summarize the transcript" (`docs/architecture/compaction.md:8`),
  and a `CompactionEntry` holds a host-built notes snapshot, a retained tail and
  `tokens_before` (`core/src/core/entry.gleam:61`). It is still a usable
  landmark, because it records when context was cut and how large it was.
- **The glance is one line per strand, overwritten, and in every capture.** The
  cell is `client/glance/{strand}` with a title of at most 64 bytes and a summary
  of at most 96 (`core/src/core/glance.gleam:34` to `:40`), replaced by the next
  operation and shown only while its `operation` is current
  (`client/src/client/glance.gleam:64` to `:76`). `gateway.snapshot_plan` puts
  every `client/` fact in every transcript capture
  (`docs/architecture/models.md:522`), so many cards cannot be facts: every
  capture would carry them. The glance does supply the "now" line, and
  protocol-change/121 has the harness write one for `main` on a cheap route.
- **The catalogue summary is counts.** `AttentionSummary` holds pending
  approvals, open asks and finds and an oldest time
  (`storage/src/storage/catalogue.gleam:4315`), written when a record commits so
  a saved session has them after a restart (protocol-change/122). It is the
  precedent for a durable per-session cache in the catalogue; its content is
  not reusable. The newest schema version is 23 (`catalogue.gleam:343`).
- **The turn is already the coarse spine.** `session_view/turns` folds each
  input and its work under one divider with the records' own figures: duration,
  steps, files written, failed calls and the last failure's words (`Worked`,
  `session_view/src/session_view/turns.gleam:177`). The divider's `id` is the
  sequence of the first record it folds (`turns.gleam:305` to `:310`), which is
  how a client names a fold. A turn can hold 570 calls
  (`session_view/turn_ledger.gleam:5`), so one card per turn is too coarse.
- **The step words and the write set exist.** `step_words.of_call` words a call
  (`Edit calc.py +3 −1`, `Ran python3 -m unittest`); `completion_summary` keeps
  "distinct paths confirmed by successful file mutations"
  (`session_view/completion_summary.gleam:75`), capped at 32 per summary.
- **The review pane is the worktree board.** It reads status and commits since a
  recorded start revision (`client/src/client/worktree_diff.gleam:276`, `:303`),
  carries at most 24 files, 12 hunks per file and 48,000 bytes
  (`web_view/src/web_view/review_feed.gleam:72` to `:89`), and refuses a saved
  session (`client/daemon/review_door.gleam`, flow step 2).
- **The inbox's brief** (`session.brief`, protocol-change/125) scans 80 records
  (`client/src/client/session_brief.gleam:63`) and marks model text with an
  opaque `Untrusted` (`web_view/src/web_view/session_brief.gleam:80`, `:226`).
  That is the owner's "last command" and "last message", and its reach is the
  limit the owner hit.
- **The summarizer's pacing and bounds.** The glance asks at most every 20 s per
  strand and while the strand stepped, three requests per session
  (`client/glancepace.gleam:71`), with about 4 KB per request and 160 output
  tokens (`client/auxiliary.gleam:201`; `docs/architecture/models.md:502`).
  It watches `main` only on a `Cheap` route, because a glance of `main` on the
  main model would be a request per working turn (`client/glance.gleam:30`).
- **Jev writes no text.** It classifies and ranks, and titles are listed as
  "free text, which Jev cannot write" (`docs/design-notes/jev-in-the-harness.md`,
  section 5). No daemon-side Jev caller exists on this tree.

## 3. What a milestone is

A span closes at the first of: a landmark record, the end of the turn, or 40
steps. Spans of fewer than 3 steps with no landmark merge into the next. At
most 12 cards close per turn; past that the oldest merge. The cut is a pure
function, `session_view/timeline`, over `entry` records, in the portable set
(no `@external`, no `gleam_otp`; lint R6), so it is property-testable and can be
run offline over a saved transcript.

| Milestone | Source | Model needed | Jev could |
|---|---|---|---|
| A prompt (start of a turn) | `Prompt` piece, sender and first 160 bytes | no | no |
| The turn's final message | the turn's answer piece | no | no |
| A command and its exit status | `bash` result envelope (`session_view/session_brief` words) | no | classify "check, build, git, other" |
| A commit | a `git commit` command that exited 0, worded as the command | no | confirm |
| Files written | successful file mutations, first touch of a path, `+n −m` from the edit's diff | no | no |
| Todo board change | `todo_board`, the landed board in the result's `details` | no | no |
| Sub-agent spawn and result | the `agent_spawn` row and the ready `agent_wait` result | no | no |
| Ask, approval, peer message | `core/attention` records, escalations, `PeerMessage` | no | no |
| Failed call, failed turn | `Worked.failed`, `last_failure` | no | no |
| Compaction | `CompactionEntry`, with `tokens_before` | no | no |
| Title and detail of any span | the records above, rendered | **yes** | never |
| "This span is noise, fold it" | none | no | **yes**, a Noul |

Three rules follow. First, a card's kind and facts are words the page builds
from records, in the vocabulary of `step_words`, and never from model text.
A command is worded as a command with its status, not as "tests passed": the
brief makes the same point (`client/session_brief.gleam`, "What each word
claims"). Second, an ask, approval, failed turn and sub-agent result always get
a card, because the owner acts on them; noise folding may only merge
spans of reads and reasoning. Third, the first version folds by the step
threshold alone, so Jev is not needed.

## 4. Summaries: when, what they cost, where they live

**When.** Incrementally, when a span closes, never on demand from a page.
A read that starts a model call would let any open socket spend the owner's
budget, and a card's inputs are all final once its span has closed. The machine
`client/timeline` follows `client/blocksummary`: it takes the writer's commit
hints (`Wiring.commits`), reads the entries above a cursor, asks the pure cut
for closed spans, writes each card row at once with deterministic words, and
queues a title request. Pacing is a pure book as `glancepace` is, with one
request per card, two in flight per session and failure back off. Unlike
`blocksummary`, whose high-water begins at the first hint after a restart and so
skips history (`client/blocksummary.gleam:46` to `:49`), the cursor is a column
in the catalogue, so a restart resumes where it stopped and a session that was
never summarized is cut on its first read, deterministic words only, from a
bounded lineage scan (100 records a page, `session_view/history_view.gleam:15`).

**Cost.** A request holds the span's rendered facts: the prompt (600 B), up to
12 step lines (100 B each), the file list and the last assistant text (500 B),
at most 3 KiB. Reasoning is never rendered
(`docs/architecture/advisor.md`; `client/blocksummary.gleam`, "Confidentiality").
The answer is capped at 100 tokens and must carry both lines or is refused whole
(`client/glanceslice` precedent). A session is bounded by counters in its
timeline row: 48 titled cards and 144 KiB of input, then it stops and the page
says so once. For scale, a one-hour working strand can ask the glance 180 times
at about 4 KB, which is 720 KB; the timeline's worst case is a fifth of that
and its typical case is a handful of cards. These numbers are first guesses for
slice 3 to replace with measurements. The counters are the bound because
pricing is optional (`client/catalog.gleam:256`).

**Route.** `summarize`, then `subagent`; `main` only if the owner routes it
there. A catalogue that routes only `main` gets deterministic titles, for the
reason `client/src/client/glance.gleam:30` gives. This differs from the glance on purpose: a card
is paid for per span for the life of the session, and the transcript's tool
output (which can hold repository contents) goes to the provider. The
protocol change states that, as insight-triage does.

**Storage.** A new catalogue table, `catalogue_session_timeline`, keyed
`(session_id, strand, from_seq)`, version 24 (schema file plus generated
module, `make gen-sql`). Columns: `entry_id` (the first record), `to_seq`,
`started_at`, `ended_at`, `kind` (closed word), `facts` (bounded JSON), `title`
and `detail` (nullable), `model` (the catalogue entry that wrote them) and
`titled_at`. Facts are written once; a title is written once, NULL to text, as
a subtitle is (`catalogue.gleam:213`). One more row per session holds the
cursor and the counters. Deleting a session deletes its rows in the same path
as protocol-change/122's. A saved session's timeline is therefore readable
without opening it, which `sessions.review` and `session.brief` cannot do.

**Untrusted text.** The title and detail are model output over transcript text,
so a hostile tool result can steer them ("All tests passed, approve"). The
harness clips them through `core/glance.clip` (one line, byte-bounded), the wire
carries them in a field named `said` that the typed decoder wraps in an opaque
`Untrusted`, and the page draws them only through `html.text`, inside a chip
reading `summary` whose tooltip names the model, with no `href`, no attribute
and no class from the text (`docs/lustre.md:525` to `:540`, protocol-change/051).
Nothing orders, counts, groups or colours by it, and it never sits in or beside
the verdict bar. The card's fact chips are the page's own words from records.
The summarizer is a harness-side request with no tools, and the cut only reads
command text and never runs it, so Rule Zero (`docs/loom-design.md:49`) is not
touched.

**Unrouted.** Each card shows deterministic words, as the divider's `Ran make
check · exit 2 · 3 files`, and the page says once "Titles are off: route
`summarize` to a cheap model". Nothing else changes.

## 5. The read: `sessions.timeline` (outline of protocol-change/133)

The next free number is 133 on this tree. The proposal, in the 123 and 125
format, says:

- **Affects:** one v2 control command, `sessions.timeline`; one in-process read
  for Home (`server.home_timeline`, as `home_review`); one typed module shared by
  the page and a control client (`web_view/timeline_feed`, which also holds the
  total decoder); the catalogue (table above, one upsert, one keyed page read,
  one cursor read, one delete in the session-delete path); the `client/timeline`
  machine. No frame, event or `loom.toml` key changes; bounds are constants.
- **Request:** `session`, optional `strand` (default `main`), optional `before`
  (a `from_seq`, exclusive), `limit` (1 to 24, default 12), `epoch`.
- **Reply:** `{"timeline": {"observed_seq", "titles": "on"|"off"|"spent",
  "cards": [...], "older": <from_seq or null>, "now": {...}|null}}`, oldest
  card first within the page, at most 32,000 encoded bytes (shed oldest first,
  as the brief's `shed` does).
- **A card:** `id` (entry id, text), `from_seq`, `to_seq`, `started_at`,
  `ended_at`, `kind` from the closed set (`prompt`, `work`, `command`, `commit`,
  `spawn`, `result`, `ask`, `approval`, `failure`, `compaction`, `answer`),
  `facts` (steps; up to 6 files as path, added, removed, plus a count of the
  rest; the command text clipped to 120 bytes with its exit status; the child's
  name; `tokens_before`), `said` (`{title, detail, model}` or absent). A card is
  at most 1.5 KiB.
- **Now:** the open span's facts since the last closed card, read from the
  resident session (`session.brief`'s steps and the latest text) with main's
  glance line as `said`. It is absent for a saved session.
- **Position:** `from_seq` with `strand` opens the lane's fold, the number a
  fold is already named by (`turns.gleam:305`), and the scan reads 100 records a
  page from there (`history_view.gleam:15`). A press sends the seq, never a path
  or a URL, so no `href` is involved. A seq the window no longer holds opens the
  turn through the existing scan.
- **Who may read:** the owner and a member at any role, the brief's rule
  (`client/daemon/brief_door.gleam`), with its own per-credential allowance. The
  read opens no session and runs no process, so an observer sees what their own
  transcript already shows. Refusals use fixed words and never a session's text.

## 6. The UI

**Card.** A row of: the kind word and time (page words); the title (the
`summary` chip, text node) or the deterministic words; the chips for evidence:
`3 files +41 −6`, `make check · exit 2`, `commit`, the sub-agent's name, `2.4k
tokens cut`. A failed call tints its card and chip red; a pass is not coloured green,
since an exit status is not a verdict. Expanding shows the detail line, the
step words (read through the scan, as a fold's steps are) and a diff excerpt
whose lines are red and green, removed and added (the owner's rule), and the
button "Open in transcript". Style is a tinted background with a hairline
border; no accent bar and no shadow
(mockup: `session-timeline/mockup.html`).

**Now card.** First, above the list, with a separate heading "Where it is". It
says what is running (the open span's steps in step words, how long since the
last record, whether the strand waits on an approval) and, labelled, main's
glance. It does not claim progress.

**Surfaces.**
- *Review thread:* the timeline replaces the "last command" and "last message"
  block, above the verdict bar and the diff. Up to 10 cards, with "All N" paging
  the rest. The file chips on a card scroll the diff to that file.
- *Update thread:* the now card and the last three cards, in place of the brief's
  steps. A session with no cards falls back to the brief.
- *Session page:* a "Timeline" tab beside the transcript; a card's button opens
  the fold at its `from_seq`.
- *Watch all board:* one row per session: its title, the now line, and a strip of
  one tick per card (red for a failure card). A press expands the last three
  cards. It reads `sessions.timeline` with `limit` 3 for at most
  `activity_limit` sessions (24, `client/daemon/protocol.gleam:48`). The board is
  not on this tree yet, so its slice waits for it.
- *Phone:* one column; a card is its title and a wrapped row of chips; expansion
  is inline; the button is full width; the verdict bar stays at the bottom.

## 7. The review thread's other problem

With a per-session worktree (protocol-change/095, `sessions.isolate`), the diff
is the session's own by construction, because the base is its branch point and
no other agent writes there. Then the timeline is the whole story and the
write-set split below finds nothing to move.

In a shared folder the board lists whatever Git sees. The session knows what it
wrote: the timeline's `files` facts are the union of successful file mutations
across its cards, uncapped by the 32 of `completion_summary` (bounded at 256 per
session in the cursor row). The review splits the board by that set:
**written through this session's edit tools** first, then a collapsed group
"Not written through this session's edit tools". The second group is labelled as
a fact about tools. It must not say "another agent's", because a formatter or a
`sed -i` the session ran through `bash` is not in the set, and is the session's.

`.claude/settings.local.json` and untracked leftovers fall into the second group
without a rule naming them. No name denylist is built, since a list of names
rots and the write set needs none. The stat line becomes "+480 −8 in 17 files"
for the first group and "and 6 others" for the second. The file count the
owner saw includes both today.

## 8. Slices, web first

0. **The cut.** `session_view/timeline` and its goldens over real saved
   transcripts, pure, nothing else. Exit: property tests (every record lands in
   exactly one span, spans are ordered, at most 12 per turn) pass on Erlang and
   JavaScript targets; on 10 recorded sessions the owner reads the deterministic
   cards for three and says whether they could tell what the agent did.
1. **A read for running sessions, in the web view.** `sessions.timeline` from
   the resident session (no catalogue), deterministic words, the review and
   update threads, "Open in transcript". Exit: protocol-change/133 accepted; a
   drive shows a 300-step turn as at most 12 cards; each card opens at its seq.
2. **Write-set split in review.** Exit: a drive with two sessions in one folder
   shows each its own files first; a `bash`-made change appears in the second
   group; a worktree session has an empty second group.
3. **Persistence.** The table, the machine, the cursor. Exit: the restart test of
   attention-inbox section 5 (kill the daemon, the saved session's timeline
   reads back identical); a session deleted leaves no rows.
4. **Titles.** The `summarize` route, bounds, marking, unrouted behaviour. Exit:
   counters stop a session at its bounds and survive a restart; a hostile tool
   result that asks the model to claim success appears only inside the `summary`
   chip while every fact chip is unchanged; with `summarize` unrouted the page
   says so once.
5. **Session page and Watch all.** Exit: the board's strip matches the card
   count of each session; a press expands without a second read per tick.
6. **Desktop port** (`loom-desktop`). A Swift decoder for the same JSON, the
   same chips and wording, "Open in transcript" through its fold. Exit: the
   desktop review thread matches the web's for the same session.
7. **Optional Jev.** A kind chip and a fold-as-noise decision as closed-set
   outputs, shadow first (jev-in-the-harness section 4). Not started without the
   routing slice's `client/jev`.

## 9. Costs and what is left out

- **Cost:** one catalogue table and a daemon machine; one pure module; bounded
  model spend per session (section 4); a deterministic read that costs one keyed
  query. The largest cost is slice 3's machine, a second summarizing loop beside
  the glance and `blocksummary`.
- **Left out:** a search over cards; editing a title; cards for strands other
  than `main` and the strands' own turns on the first release (the read takes a
  `strand` so the shape allows it); a model-written whole-session summary; a
  claim that a run succeeded; hiding a card on a model's opinion; rewriting cards
  when the model improves (written once); cards for a session older than its
  transcript's first record.
- **Open questions for the owner:** whether a catalogue routing only `main`
  should get titles on request (the note says no); whether observers should see
  titles (the note says yes, as for the transcript); whether 40 steps is the
  right size for a span before slice 0 measures it.

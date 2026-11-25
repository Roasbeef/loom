# Session timeline: milestones of a run, so the owner need not read the backlog

Status: proposal, 2026-11-24, revised after a review. Not a commitment. It
writes no code and no protocol change; section 5 outlines the one the build
needs. The owner has ruled on three questions (section 9).

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
   `session_view` at landmarks the records show. The cut is prefix-stable: the
   cards of a prefix of the records are a prefix of the cards of the whole,
   apart from the open span. Facts (time, steps, files with line counts, a
   command with its exit status, a sub-agent's name, a compaction) come from
   records with no model.
2. A model writes only a title of at most 64 bytes and a detail line of at most
   200, on the `summarize` route only, once per closed card. The text
   is untrusted and drawn as a text node beside a chip that says a model wrote
   it. No count, order, verdict or group depends on it.
3. The live read computes cards from the resident session. What cannot be
   recomputed, the titles and their spend, is stored in the catalogue. A facts
   table for saved sessions is built only if a measurement asks for it.
4. The read is `sessions.timeline`, a bounded page with a "now" card. A card
   carries the number of its turn's fold (`turn_seq`), its own `from_seq` and
   `to_seq`, and the entry id of its last record. Opening one span is new page
   work in slice 1; the existing fold opens a whole turn only.
5. The review thread gets the timeline above the diff, and the diff is split by
   the session's write set, built from every strand. A per-session worktree
   makes the second group empty.
6. With no cheap route the cards still appear, with plain record words. Jev is a
   later, optional classifier.

## 2. What is there today

- **No host selects a model-written summary of a span.** Compaction is
  host-built: "no model is asked to summarize the transcript"
  (`docs/architecture/compaction.md:8`). `CompactionEntry` and
  `BranchSummaryEntry` can carry a `summary`, `from_hook` and `usage`
  (`core/src/core/entry.gleam:54` to `:76`), but a generated one is not what the
  host writes today. A compaction is a usable landmark: it records when context
  was cut and `tokens_before` (`entry.gleam:61`).
- **The glance is one line per strand, overwritten, and in every capture.** The
  cell is `client/glance/{strand}` with a title of at most 64 bytes and a summary
  of at most 96 (`core/src/core/glance.gleam:34` to `:40`), replaced by the next
  operation and shown only while its `operation` is current
  (`client/src/client/glance.gleam:74` to `:76`). `gateway.snapshot_plan` puts
  every `client/` fact in every transcript capture
  (`docs/architecture/models.md:522`), so cards cannot be facts: every capture
  would carry them. The glance supplies the "now" line (protocol-change/121
  writes one for `main` on a cheap route).
- **The catalogue summary is counts.** `AttentionSummary`
  (`storage/src/storage/catalogue.gleam:4315`) is the precedent for a durable
  per-session cache in the catalogue (protocol-change/122); its content is not
  reusable. The newest schema version is 23 (`catalogue.gleam:343`).
- **The turn is the coarsest unit that already exists.** `session_view/turns`
  folds each input and its work under one divider with the records' own figures
  (`Worked`, `session_view/src/session_view/turns.gleam:177`). A fold is named by
  the sequence of the first record of the turn's work (`turns.gleam:305` to
  `:310`), and `FoldToggled` with a number that names no held fold changes
  nothing (`web_view/src/web_view/component.gleam:1471` to `:1480`). Opening a
  fold reads the turn's newest steps from its last record (`component.gleam:4302`)
  and keeps at most 100 rows (`session_view/fold_budget.gleam:145`).
  A turn can hold 570 calls (`session_view/turn_ledger.gleam:5`), so one card per
  turn is too coarse and an early step of a long turn is not shown by opening it.
- **A scan starts at an entry and walks down.** `session_channel.lineage` reads at
  most 100 records of one strand from an entry id along parent links
  (`session_view/session_channel.gleam:1865` to `:1872`; `history_view.gleam:12`
  to `:13`; protocol-change/072).
- **The step words and the write set exist, in part.** `step_words.of_call` words
  a call (`Edit calc.py +3 −1`). `completion_summary` keeps "distinct paths
  confirmed by successful file mutations" (`session_view/completion_summary.gleam:75`),
  capped at 32 per summary, and recognises only `fs_edit` and `fs_write`
  (`:377`). A code-mode program's `fs.write`, `fs.edit`, `fs.delete` and
  `lsp.rename` are file writes in `program_card` (`:580` to `:582`), and the call
  record keeps an allowlisted path for some (`tools/src/tools/call_record.gleam:411`)
  for the first 128 calls of a program.
- **The review pane is the worktree board.** It reads status and commits since a
  recorded start revision (`client/src/client/worktree_diff.gleam:276`, `:303`),
  carries at most 24 files and 48,000 bytes
  (`web_view/src/web_view/review_feed.gleam:72` to `:89`), and refuses a saved
  session (`client/daemon/review_door.gleam`, flow step 2).
- **The inbox's brief** (`session.brief`, protocol-change/125) covers the last 80
  records (`client/src/client/session_brief.gleam:63`), which is why the owner saw
  so little. It marks model text with an opaque `Untrusted`
  (`web_view/src/web_view/session_brief.gleam:80`, `:226`).
- **The summarizer's pacing and bounds.** The glance asks at most every 20 s per
  strand, three requests per session (`client/glancepace.gleam:71`), about 4 KB per
  request and 160 output tokens (`client/auxiliary.gleam:201`;
  `docs/architecture/models.md:502`). It watches `main` only on a `Cheap` route
  (`client/glance.gleam:30`). The writer's commit hints are lossy
  (`runtime/src/runtime/writer.gleam:8` to `:10`).
- **Jev writes no text** ("free text, which Jev cannot write",
  `docs/design-notes/jev-in-the-harness.md`, section 5). Its only daemon-side
  caller is project routing (`project/src/project/jev.gleam`); `client` has none.

## 3. What a milestone is

The cut `session_view/timeline` is a pure function over one strand's records, in
the portable set (no `@external`, no `gleam_otp`; lint R6). It walks the strand's
parent-link lineage, as `blocksummary`'s `on_primary` does, never the seq
range, so records on an abandoned branch (a `BranchSummaryEntry`) are not cut.
It is total: a record it does not know, including a `CustomEntry` of an unknown
type, joins the open span and adds no fact.

A span closes at a record in the "closes" column below, or at 40 steps. A closing
landmark that finds fewer than 3 steps in the open span, and is not an
always-card kind, joins that span instead of closing it; the decision uses only
records already seen, which keeps the cut prefix-stable. There is no per-turn
cap. A session stops closing spans at 400 cards, after which only always-card
kinds and turn ends close; that too depends only on the prefix. Paging bounds
what a read returns.

| Milestone | Source | Closes a span | Model | Jev could |
|---|---|---|---|---|
| A prompt | `Prompt` piece: sender, first 160 bytes | yes, starts a turn | no | no |
| The turn's final message | the turn's answer piece | yes | no | no |
| A failed command | `bash` result with an exit status other than 0 | yes | no | classify |
| A command after edits | `bash` result with a status, when the span holds a file write | yes | no | classify "check, build, git, other" |
| A commit | a command the review board's commits confirm (below) | yes | no | no |
| Files written | successful file mutations, first touch, `+n −m` from the edit's diff | no | no | no |
| Todo board change | `session_view/todo_board` | no | no | no |
| Sub-agent spawn, result | the `agent_spawn` row, the ready `agent_wait` result | result: yes | no | no |
| Ask, approval | `core/attention` records, escalations | yes, always a card | no | no |
| Peer message | `PeerMessage` | no, a chip | no | no |
| Failed turn | `Worked.failed`, `last_failure` | yes, always a card | no | no |
| Compaction | `CompactionEntry`, `tokens_before` | yes | no | no |
| Title and detail | the span's rendered facts | n/a | **yes** | never |
| "Merge this span as noise" | none | n/a | no | **yes**, a Noul |

Rules. A card's kind word and numbers are the page's own. Every other string
(command text, paths, child names, the prompt excerpt, failure words) is session
text and travels as `Untrusted`; `last_failure` is likewise drawn as a text
node (`turns.gleam:188` to `:194`). A command is worded as a command with its status, never "tests
passed" (`client/session_brief.gleam`, "What each word claims"). The kind
`commit` is set only when a commit the review board reads since the start
revision (`worktree_diff.gleam:276`) falls in the span's time range; otherwise
the card is a `command`, because `echo git commit`, `--dry-run` and a compound
command's status say nothing, and code mode's `git.commit` has no command text.
The first version folds by the step threshold alone, so Jev is not needed.

## 4. Summaries: when, what they cost, where they live

**When.** Incrementally, when a span closes, never from a page read: a read that
starts a model call would let any open socket spend the owner's budget. The
machine `client/timeline` follows `client/blocksummary`. It takes the writer's
commit hints, cuts the records above its cursor, writes a row for each closed
span in one transaction with the cursor (the cursor is the largest `to_seq` among
the session's rows, so there is no separate cursor row), and queues a title
request. Hints are lossy, so a catch-up runs when the operation settles; without
it a finished session could lack its last cards, the review-thread case. Pacing
is a pure function of (book, event, now), as `glancepace` is.

**Limits on requests.** One request per card, two in flight per session and a
daemon-wide cap of 4 in flight, because the glance's limit is per session and N
resident sessions after a restart would otherwise send 2N. A request that fails
backs off. A row whose title is NULL is retried at most 3 times; its attempt and
input bytes are counted in the row before the request is sent, so a crash cannot
reset spend. Titles are requested newest card first, so the cards a review shows
first are titled first.

**Cost.** A request holds the prompt excerpt (600 B), at most 12 step lines of
100 B (the first 4 and last 8 of the span), the file list and the last assistant
text (500 B): at most 3 KiB. Reasoning is never rendered
(`docs/architecture/advisor.md`). The answer is capped at 100 tokens and must
carry both lines or is refused whole (`client/glanceslice` precedent). A session
is bounded by 48 titled cards and 144 KiB of input (sums over its rows), after
which it stops and the page says so once. For scale, a one-hour working strand
can ask the glance 180 times at about 4 KB, 720 KB; the worst case here is a
fifth of that. Pricing is optional (`client/catalog.gleam:257`), so the bound is
in counters. All numbers are first guesses for slice 4 to replace.

**What reaches the provider.** The request carries session text: the user's
prompt excerpt, step lines that include tool-result words for failures, file
paths, and the agent's last text. Command text is reduced the way the call record
reduces arguments: executable and subcommand only, no argv tail, env or token
(`tools/src/tools/call_record.gleam`, module doc), so `curl -H "Authorization:
…"` becomes `curl`. The same reduced text is what is stored. The protocol change
states this exposure, as insight-triage does.

**Route.** `summarize` only (owner ruling, 2026-11-24). Titles never fall back to
`subagent` or `main`, as the glance does. A catalogue with no explicit
`summarize` route gets no titles: cards show plain record words and the page says
once "Titles are off: route `summarize` to a cheap model". The reason is that a
fallback would send transcript text to a provider the owner did not choose for
this purpose, which insight-triage's provisional ruling 3 also refused for its
role (`docs/design-notes/insight-triage.md:660`).

**Storage.** Slice 3 adds a catalogue table `catalogue_session_timeline`, version
25, keyed `(session_id, strand, from_seq)` with `to_seq`, `title`, `detail`,
`model`, `attempts`, `input_bytes` and `titled_at`. A title is written once, NULL
to text, as a subtitle is (`catalogue.gleam:213`). The row count is capped at 400
per session; at 1.5 KiB a card a full session is about 600 KiB, accepted. The
facts are recomputed on read from the resident session. Only if slice 1 measures
that read as too slow for the Watch all board (24 sessions a refresh), or saved
sessions' timelines are wanted, does slice 4 add `kind`, `facts` and the entry
ids to the row. A saved session with no rows shows "No timeline until opened":
the machine cuts on open, as protocol-change/122 rewrites its row on open, from a
lineage scan of at most 2,000 records (20 pages), and spans cut that way get no
titles. Deleting a session deletes its rows in the path 122 uses.

**Untrusted text.** The title and detail are model output over transcript text,
so a hostile tool result can steer them. The harness clips them through
`core/glance.clip`, the wire carries them in a field `said` that the typed decoder
wraps in `Untrusted`, and the page draws them only through `html.text` beside a
chip reading `summary` whose tooltip names the model, with no `href`, attribute
or class from the text (`docs/lustre.md:525` to `:540`, protocol-change/051).
Nothing orders, counts, groups or colours by it, and it is never in or beside the
verdict bar. The summarizer has no tools and the cut only reads command text, so
Rule Zero (`docs/loom-design.md:49`) is not touched.

## 5. The read: `sessions.timeline` (outline of protocol-change/134)

Number 133 and catalogue version 24 belong to the own-worktree work
(`sessions/own-worktree`), so this outline takes 134 and version 25; whichever
lands second takes the next free number and version. The proposal, in the 123 and
125 format, says:

- **Affects:** one v2 control command, `sessions.timeline`; one in-process read
  for Home (`server.home_timeline`, as `home_review`); one typed module shared by
  the page and a control client (`web_view/timeline_feed`, with the total
  decoder); a new page read, "show this span"; slice 3's table and its machine.
  No frame, event or `loom.toml` key changes.
- **Request:** `session`, optional `strand` (default `main`), optional `before`
  (a `from_seq`, exclusive), `limit` (1 to 20, default 10), `epoch`.
- **Reply:** `{"timeline": {"observed_seq", "titles": "on"|"off"|"spent",
  "cards": [...], "older": <from_seq or null>, "now": {...}|null}}`, oldest card
  first within the page, at most 32,000 bytes (20 cards at 1.5 KiB fit; shed
  oldest first, as the brief's `shed` does).
- **A card:** `turn_seq` (an Int, the fold number), `from_seq` and `to_seq`
  (Ints), `last` (the entry id of the span's last record, text), `started_at`,
  `ended_at`, `kind` (`prompt`, `work`, `command`, `commit`, `spawn`, `result`,
  `ask`, `approval`, `failure`, `compaction`, `answer`), `facts` (steps, reads,
  files as up to 6 of path, added, removed plus a count, the reduced command with
  its exit status, the child's name, `tokens_before`; every string `Untrusted`),
  and `said` (`{title, detail, model}` or absent).
- **Now:** the open span's facts since the last closed card, from the resident
  session, with main's glance line as `said`. Absent for a saved session.
- **Open in transcript.** The press sends `turn_seq` and `last`, never a path or
  URL. The page opens the turn's fold (`FoldToggled`), then runs the new "show
  this span" read: a scan starting at `last`, walking down parent links, stopped
  at `from_seq`, at most 100 records. This is new page work in slice 1: the
  fold's step read starts at the turn's end and keeps 100, so a span deep in a long
  turn is not shown by the fold alone.
- **Who may read:** the owner and a member at any role, the brief's rule
  (`client/daemon/brief_door.gleam`), with its own per-credential allowance.
  Observers see the same cards, titles included (owner ruling 2). When strands
  other than `main` get cards, the read applies the strand grant of the lineage
  read (protocol-change/072). Refusals use fixed words, never a session's text.

## 6. The UI

**Card.** A row of: the kind word and time; the title beside a `summary` chip, or
plain record words; evidence chips (`3 files +41 −6`, `make check · exit 2`,
`commit`, the child's name, `2.4k tokens cut`). A failed call tints its card and
chip red; a pass is not coloured green, since an exit status is not a verdict.
Expanding shows the detail line (with its chip), the step words (read through the
span read) and a diff excerpt in red and green, removed and added, and the button
"Open in transcript". The style is a tinted background with a hairline border; no
accent bar and no shadow (mockup: `session-timeline/mockup.html`).

**Now card.** Above the list, headed "Where it is": what is running (the open
span's step words, time since the last record, whether the strand waits on an
approval) and, labelled, main's glance. It does not claim progress.

**Surfaces.**
- *Review thread:* the timeline replaces the "last command" and "last message"
  block, above the verdict bar and the diff. Ten cards, "All N" pages the rest. A
  file chip scrolls the diff to that file by its index in the review's file list,
  never by using the path as an id, key or anchor.
- *Update thread:* the now card and the last three cards, in place of the brief's
  steps. A session with no cards falls back to the brief.
- *Session page:* a "Timeline" tab beside the transcript.
- *Watch all board:* one row per session: title, now line, a strip of one tick per
  card (red for a failure card); a press expands the last three. It reads
  `sessions.timeline` with `limit` 3 for at most 24 sessions
  (`client/daemon/protocol.gleam:51`). The board is on this tree (`WatchAllToggled`, `inbox.Watch`); slice 5 draws the strip on it, and slice 1 does not.
- *Phone:* one column; a card is its title and a wrapped row of chips; expansion
  is inline; the button is full width; the verdict bar stays at the bottom.

## 7. The review thread's other problem

With a per-session worktree (protocol-change/095's worktree mode and the
own-worktree work), the diff is the session's own, because the base is its branch
point and no other agent writes there. The timeline then covers everything the
diff shows, and the split below finds nothing to move. (`sessions.isolate` is
domain isolation, protocol-change/015 and 053, and is a different thing.)

In a shared folder the board lists whatever Git sees. The session knows what it
wrote. The **write set** is the union of successful file mutations of every strand
of the session, whether or not that strand has cards, including the paths of
code-mode calls (`fs.write`, `fs.edit`, `fs.delete`, `lsp.rename`) where the call
record kept one. Paths are normalised to the board's form: workspace-relative,
`/` separators, a leading `./` removed, an absolute path under the workspace root
made relative, and a path with a `..` segment or outside the root matches nothing
(the board's paths are `--relative`, `worktree_diff.gleam:478`). Slice 2
checks the form the edit result's `details.path` takes against a drive.

The review shows the files in the set first, then a collapsed group **"No
edit-tool record in this session"**. A file `bash` wrote (`sed -i`, a formatter)
is in the second group, and the label says only that no edit tool recorded it.
The set can be incomplete: past 256 paths, past a code-mode call record's 128
calls, or from a partial scan. Then the group is labelled "Write set incomplete:
some files below may be this session's", and the page never says "another
agent's".

`.claude/settings.local.json` and untracked leftovers fall into the second group
with no rule naming them. No name denylist is built, since a list of names goes
out of date and the write set needs none. The stat line becomes "+480 −8 in 17
files" for the first group and "and 6 others" for the second.

## 8. Slices, web first

0. **The cut.** `session_view/timeline` and goldens over real saved transcripts,
   pure. Exit: property tests pass on both targets: every record lands in exactly
   one span; spans are ordered; **cut(prefix) is a prefix of cut(whole), apart
   from the open span**; an unknown record joins the open span. Over the 10
   recorded sessions it prints the card-count distribution for spans of 20, 40 and
   80 steps (owner ruling 3 keeps 40), and the owner reads the cards of three and
   says whether they could tell what the agent did.
1. **A live read in the web view.** `sessions.timeline` from the resident session,
   plain words, the review and update threads, the span read and "Open in
   transcript". Exit: protocol-change/134 accepted; a drive shows a 300-step turn
   as a bounded set of cards; each card opens its span, including one deep in a
   long turn; the read's time at 24 sessions is measured.
2. **Write-set split in review.** Exit: two sessions in one folder each see their
   own files first; a sub-agent's and a code-mode write are in the first group; a
   `bash` write is in the second; a worktree session has an empty second group; a
   session past the caps shows the incomplete label.
3. **Titles.** The `summarize` route, the titles table, the machine, spend
   counters, retry and catch-up. Exit: bounds hold and survive a restart; a
   settled session has every card titled or counted as spent; a hostile tool
   result asking the model to claim success appears only beside the `summary`
   chip while every fact chip is unchanged; a `main`-only catalogue shows plain
   words and says so once; a command's argv tail is in no request.
4. **Facts in the catalogue, if measured.** Exit: restart test of attention-inbox
   section 5 (a saved session's timeline reads back identical); deletion leaves no
   rows.
5. **Session page and Watch all.** Exit: the board's strip matches each session's
   card count; a press expands without a second read per tick.
6. **Desktop port** (`loom-desktop`). A Swift decoder for the same JSON, the same
   wording, "Open in transcript" through its fold and span read. Exit: its review
   thread matches the web's for the same session.
7. **Optional Jev.** A kind chip and a merge-as-noise decision as closed-set
   outputs, shadow first (jev-in-the-harness section 4), after routing's
   `client/jev`.

## 9. Costs, rulings and what is left out

- **Cost:** one pure module; a read computed from the resident session; one small
  table and a daemon machine for titles; bounded spend per session (section 4).
  The largest cost is slice 3's machine, a third summarizing loop beside the
  glance and `blocksummary`.
- **Owner rulings (2026-11-24):** a catalogue routing only `main` gets no titles;
  observers see the same cards as the owner, titles included, under the strand
  grant when other strands get cards; the span size is 40 steps, with slice 0
  printing the distribution for 20, 40 and 80; titles use the `summarize` route
  only, with no fallback to `subagent` or `main`.
- **Left out:** a search over cards; editing a title; cards for strands other than
  `main` on the first release (the request takes a `strand`, and the write set
  already covers every strand); a whole-session summary; any claim that a run
  succeeded; hiding a card on a model's opinion; rewriting a title when the model
  improves; cards before a transcript's first record; an owner-pressed "title
  this session" on a `main`-only catalogue, which can be added later.

## 10. Slice 0, as built (2026-11-24)

The cut is `session_view/src/session_view/timeline.gleam`, with its examples and
five properties in `session_view/test/timeline_test.gleam`: every record is in
exactly one span, a prefix's cards are a prefix of the whole's, an unknown record
changes no card, a command or result card holds at least three steps, and a
strand stops closing landmark cards at 400. It differs from the note in four
places, each because the records do not hold what the note assumed.

- **No `failure` kind.** A failed call counts in the card's `failed` fact, and a
  failed command closes a `command` card. A failed turn has no record of its own.
- **No approval card.** Approvals are register cells, not entries, so the cut
  cannot see them. Slice 1 reads the pending approvals into the now card.
- **No `commit` kind yet.** It waits on the review board's commits (section 3),
  which slice 1 reads; until then a commit is a `command` card.
- **`turn_seq` is the seq of the prompt that began the turn**, not the divider's
  fold number. The page maps it to the held turn whose input has that seq.

`gleam run -m timeline_census -- <dir>` (in `packages/client/dev`) cuts copies of
stores and prints the card count at limits of 20, 40 and 80 steps. Over 174
sessions copied from the owner's drive stores (never the live daemon's), each
with a mean of 659 records and 334 steps:

| limit | min | median | p90 | max |
|---|---|---|---|---|
| 20 | 3 | 54 | 286 | 615 |
| 40 | 3 | 51 | 270 | 615 |
| 80 | 3 | 49 | 270 | 615 |

The limit barely moves the count: landmarks (a prompt, an answer, a command
after edits, a failed command) close most spans before any limit is reached, as
the review of this note predicted. A session yields about one card for every
three steps, which is too many to read as a list of milestones. The page needs a
density control that shows only the landmark kinds by default, and the 40-step
ruling stands because nothing here argues for another. Slice 0's last exit
criterion, that the owner reads the cards of three sessions and says whether they
could tell what the agent did, is the owner's to give and is not yet.

## 11. Slice 1, as built (2026-11-24)

`sessions.timeline` reads a running session's newest 2,000 records of `main`,
cuts them, and answers a page of at most 20 cards with a cursor and the open
span; `sessions.span` answers the lines of one span (protocol-change/134). Home
reads the newest page with a thread's brief and an older page when the person
presses "Earlier cards", and draws the cards above the review pane in a session's
thread, which serves the review and update threads, whatever the session's state.
A card opens to its span's own lines, read once when it is opened. It differs from
the note in these places.

- **One allowance.** Both reads spend the brief's allowance and take none of
  their own, so an open thread spends two of the six reads in four seconds and a
  card opened a third.
- **A density control the note did not have.** The census showed a card for about
  every three steps, so the thread starts at the landmark kinds (prompts, answers,
  asks, compactions, sub-agent results, commands that exited with a failure) and
  offers "All cards" and "With detail". The idea came from the owner's reference
  image, which had a low, medium and high density.
- **The window's stability.** A strand longer than the scan is cut from a sliding
  window, so cards before the window's first hard boundary (a prompt, an answer, an
  ask or a compaction) are not offered; see protocol-change/134.
- **Where it is** says how many steps ran since the last card and how long ago the
  last record was written, and is absent when no step ran. It does not say what the
  strand is doing now, because the open span has no title until slice 3.
- **No approval or commit card**, for the reasons in section 10.
- **The span opens beside the card**, in the thread, not in the session page. A
  card's "Open the session" still opens the session's page.

**Measured read time.** The resident's read (scan of up to 2,000 records, cut,
page, encoding) over 23 copies of recorded sessions, on the machine that builds
this tree: minimum 2 ms, median 51 ms, 90th percentile 306 ms, maximum 361 ms, with
replies of about 3.3 KB (`gleam run -m timeline_census -- timing <dir>`). The
sessions that fill the 2,000-record window take 250 to 360 ms, so a board that
refreshes 24 such sessions starts 24 scans of about a third of a second each, one in
each session's own actor, spread by the allowance. The scan materialises up to 2,000
records with their payloads, which can be tens of kilobytes each, and is not bounded
in bytes; it is bounded in records and time, and a byte bound waits on a read that
needs less than the whole record.

**How many landmark cards, measured.** Over 27 more copies of recorded sessions
the whole strand made a median of 67 cards at the 40-step limit, 53 of them
landmark kinds, from a median of 24 turns, so a list of every landmark kind is
too long to be a list of milestones for most sessions. A turn where something
happened (it wrote a file, had a failed call, asked, compacted or got a
sub-agent's result) is a milestone and a turn that only talked is not: the median
session has 12 such turns, and 15 of the 27 have 15 or fewer. The Landmarks
density therefore keeps the landmark cards of those turns and of the newest turn,
and the first page of a thread shows at most ten cards, so a thread opens with a
handful (six or seven of the newest ten on the sessions driven live) and "Earlier
cards" pages back through the rest.

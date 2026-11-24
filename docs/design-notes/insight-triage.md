# Insight triage: a cheap model that labels what the inbox lifts

Status: proposal, 2026-11-23. Not a commitment.

The owner asked: "do we have another smaller model go over the transcript and
surface those similar to advisor/summarize?" The attention inbox's design put
that question in the project meta layer, which is undesigned
(`attention-inbox/README.md`, section 3, question 7, and section 4, phase 3).
The owner then said "sure let's give that a shot." This note proposes what the
first version is, what it is not allowed to do, and how to find out whether it
is worth keeping. It writes no code and no protocol change.

## 1. Summary of the decisions

1. The triage model reads, per run end, a small rendering of the rows the
   deterministic classifier already lifted, each with a bounded window of
   surrounding transcript. It does not read whole slices in the first version.
2. It produces labels on lifted rows: a weight from a closed set of three and
   one line of reasoning. It never creates a row, never hides one, and never
   changes a count, a group or a hold.
3. It runs as a harness-side request on a new `triage` role. It has no tools,
   is not a strand, and cannot be addressed. It is off unless the catalogue
   routes the role.
4. Its labels are durable, in a reserved namespace of the session store, and
   are drawn with a mark and wording that say they are a model's opinion.
5. The inbox uses a label to order the Insights group and to show a "why" line.
   Needs you is never reordered.
6. The first test is offline and costs an hour of the owner's time: does the
   triage order beat "newest first" at putting the rows the owner would open
   first among the top three?

## 2. Background

### 2.1 Three sources of lifted text, and what each can claim

An inbox row today has one of two origins.

- **The classifier** is a pure function over the lane's pieces, the register's
  approvals and the session's open records
  (`packages/session_view/src/session_view/attention.gleam:152`, `lift_all`).
  Its `Kind` is a closed set: a pending approval, a failed step, a failed turn,
  a sub-agent's result, a peer message, an open ask, a stuck strand and an open
  find (`session_view/attention.gleam:69`). It states facts the harness holds: a call
  returned an error, a message arrived. Its module comment says what it will not
  state: "The daemon knows it stored the message, not that it is relevant or
  that anyone has answered it, and the rail must not claim either"
  (`session_view/attention.gleam:35`). A peer message's head is the fixed phrase
  "messaged this session" (`session_view/attention.gleam:289`, `piece_rows`).
- **The agent** records an `ask` or a `notice`
  (`packages/tools/src/tools/attention.gleam:68` and `:71`, protocol-change/119
  and 120). A find has a kind, free text and an optional path and line
  (`packages/core/src/core/attention.gleam:295`, `Find`). These are the
  agent's own words about its own work, and the page draws them as such.

The attention-inbox ranking found a third kind of text that nothing in the
system can produce, and said where it had appeared: "Three mockups claim a peer
message is relevant." A's row said the message was "about the same grant", B's
face said "Not answered", and C's thread gave advice about read-only checks
(`attention-inbox/ranking.md`, the finding of that name). Its rule follows:
"Peer messages are listed by time and origin with no claim of relevance or of
being unanswered" (`ranking.md`, "Text the page may not write"). All four
concepts used the classifier plus the agent's records, and none proposed a
model pass (`concept-a.md` to `concept-d.md`).

A triage model produces exactly that third kind of text. It can say "this
message mentions the grant this session is blocked on", which is a judgment and
may be wrong. The design problem is to admit that text into the inbox without
letting it pass as the first kind or the second.

### 2.2 The precedents

**The advisor** is a second model reading a strand's work
(`docs/architecture/advisor.md`). Four of its decisions carry over.

- The feed is one-way. The harness renders the entries since a stored cursor
  into text (`client/advisorslice.gleam:233`, `render`) under two byte caps,
  2,048 for one block and 32,768 for the slice (`advisorslice.gleam:111`).
  Thinking never renders. A tool result is clipped from the middle
  (`advisorslice.gleam:542`, `middle_clip`).
- The feed fires at a run end and, optionally, at a step threshold, and
  coalesces while a review is open, so a busy primary costs one further review
  and not ten.
- The harness rations what a verdict costs. The advisor does not decide how
  often it is heard.
- The primary cannot address the advisor and cannot read its cells. The prefix
  `advisor/` is reserved, `put_fact` refuses it and `facts` hides it. The
  standing brief says the feed is evidence and not orders, and is prepended
  transiently, never stored.

The advisor differs in one respect that matters here. It is a strand with a
tool, and its output goes to the primary. Triage output goes to the owner and
never to the primary, so triage needs no strand and no tool.

**The summarizer and the glance loop** are cheaper and closer in shape.
`client/glance` is a harness-side request on the `summarize` route, falling back
to `subagent` and then `main`, with thinking off and the answer capped at 160
tokens (`client/auxiliary.gleam:201`, `capped_gateway_summarizer`). The reduced
request is about four kilobytes, an answer that lacks the lines asked for is
refused whole, and the result is a reserved cell
(`docs/architecture/models.md`, the glance section; `runtime/api.gleam:2970`,
`put_reserved_fact`). The glance has no switch to turn it off, because routing
`summarize` to a cheap entry is how an operator controls its cost. Triage should
not copy that last property, for the reason in section 4.4.

## 3. What the triage model reads

### 3.1 The options

**A. Rendered slices, as the advisor's feed does.** The triage model sees every
entry since a cursor, up to 32 KB, and decides what to surface.

- For: it can find what the classifier cannot, such as a tool call that
  succeeded and did the wrong thing.
- Against: it costs about eight times the request below on every run end, and
  most of that text is rows the classifier correctly ignores. It also asks the
  model to produce rows, which is the riskiest output (section 4).

**B. The classifier's rows and a window of context around each.** The harness
runs the classifier, takes up to eight rows, and renders for each its head, its
kind word and a bounded window of the surrounding transcript.

- For: the request is small and its output space is small, since the model is
  asked about named rows and can only answer about them. The baseline is the
  classifier's own list, which is what the evaluation needs (section 8).
- Against: it cannot find a problem the classifier did not lift.

**C. Both**, as separate passes.

The first version is B. A is the second slice (section 9), and it is built on
what B shows about whether a labelling model is useful at all. If a model
cannot beat "newest first" on rows already lifted, it will not do better by
being asked to invent rows.

### 3.2 What a request contains

For each of at most `max_rows` (initially 8) lifted rows that have no label
yet, the harness includes:

- the row's `key`, `kind` word and `head` as the classifier produced them
  (`session_view/attention.gleam:110`, `Lifted`);
- the rendering of the lane pieces within two pieces of the row's, with the
  advisor's rendering rules: no thinking, tool results clipped from the middle,
  and a per-block cap (initially 600 bytes, since the whole request has to stay
  small);
- the text of the run's final assistant message, once, so the model knows how
  the run ended.

A request is capped at 8,192 bytes. Rows past the cap are left unlabelled for
the next request. The rows are ordered newest first, so the cap drops the
oldest.

The classifier today runs only in the web view
(`packages/web_view/src/web_view/component.gleam:7468`). A request therefore
needs the daemon to run it over the stored entries. `session_view` is a pure
package and `client` already depends on it (`packages/client/gleam.toml`), so
this is a call and not a new dependency, but it is the largest structural cost
of the first slice. The page and the daemon must also agree on a row's `key`,
which is the piece's own key and is already a daemon identity.

### 3.3 When it runs

At a primary run end, not at the advisor's step threshold. Rails drawn during a
run show unlabelled rows until the run ends, and the owner is not misled by the
absence of a label, because an unlabelled row is the classifier's row, which is
a fact. The step threshold is deferred until there is evidence that late labels
cost the owner something (question 4).

Requests coalesce as the advisor's feeds do. If a request is open when a run
ends, nothing is queued, and the next run end covers both stretches. A run end
with no unlabelled lifted row sends nothing. Unlike the advisor's catch-up, there
is no debt: an unlabelled row waits for the next run end, and an idle session
that never runs again keeps its last rows unlabelled. That is acceptable, because
an idle session's rows are the oldest and the least likely to be opened first.

### 3.4 The cost ceiling

The ceiling is a promise the owner can read, so it is a counter and not an
estimate. A session's triage stops when either bound is reached.

| Bound | Initial value | Reason |
|---|---|---|
| Input bytes per request | 8,192 | Section 3.2. |
| Output tokens per request | 400 | Eight labels of about 120 characters. |
| Requests per session | 24 | A long session has dozens of run ends. |
| Input bytes per session | 131,072 | 16 full requests. |

The values are first guesses to be replaced by measurement in the first test. A
session that reaches a bound shows its rows unlabelled and says so once, in the
reading pane: "Triage stopped: its budget for this session is spent." The
counters live in a durable cell (section 6), so a restart does not reset them.
Triage requests are metered here and not in the session's cost ledger, as the
glance's are not, which is why the ceiling has to be this cell.

### 3.5 Which model

A seventh routable role, `triage`, declared as `model.Custom("triage")` as the
advisor's is (`packages/client/src/client/catalog.gleam:480`, `advisor_role`)
and settable in `[roles]` and in `[profiles.<name>.roles]`
(`catalog.gleam:1940`, `parse_profiles`). The role has these rules.

- **Off by default.** A catalogue that does not route `triage` starts no triage:
  no request, no cell and no mark on the page. This is the advisor's posture
  ("A catalogue that does not route it gets a session that runs exactly as
  before").
- **Not defaulted to the summarizer's route.** The glance falls back from
  `summarize` through `subagent` to `main`, so every catalogue gets glances. A
  triage that did the same would send transcript text, including tool output
  that may hold repository contents, to a provider on every run end of every
  session for a feature the owner did not choose, and its cost would have no
  switch. An example catalogue routes `triage` to the same entry as `summarize`,
  which makes the one-line opt-in easy and visible.
- **Thinking off.** Reasoning is not needed for a three-way label, and it is the
  confidential and expensive part of a response.
- **Reasoning is never sent.** The rendering omits thinking, as the advisor's
  does, so the summarizer's same-endpoint rule for reasoning blocks does not
  apply.

## 4. What it may produce

### 4.1 The three kinds of output

**(a) Labels on rows the classifier lifted.** Each label has a row `key`, a
`weight` from `high`, `normal` and `low`, and a `why` of at most 120
graphemes, the classifier's own `head_limit` (`session_view/attention.gleam:56`).

**(b) Finds of its own.** A row the classifier did not lift, with a transcript
anchor, a kind and a line of text.

**(c) Suppression.** Hiding or folding a row the classifier lifted.

The first version produces (a) only. The reasons follow.

**Suppression is rejected, not deferred.** A rail that hides a row the owner
would have wanted reads as a rail that is wrong without the owner knowing. The
attention counts say what they read, and a restart test stands behind them
(`attention-inbox/README.md`, section 5, "Counts"). A count that depended on a
model's opinion would stop being a count. A `low` row sorts last in its group
and is drawn at the same size as any other. Triage changes order, and never
which rows exist, how many there are, which group holds them or how long they
stay (`Hold`, `session_view/attention.gleam:59`).

**Finds of its own are deferred** to the second slice. They are the only output
that adds a row, so they need their own record kind, a distinct place in the
page, and a way to measure false finds. Slice 1 gives the evidence for whether
to build them.

**Pinned rows are not ranked.** A pending approval, an open ask and a stuck
strand are `PinnedUntilAnswered`, and all of them need the owner whatever a model
thinks. Only the `FoldsOnceOpened` rows, the Insights group, are given a weight
that orders them. A label may still be shown on a pinned row as a "why" line,
which is the second use in section 7, but it never moves one.

### 4.2 Three sources, drawn so the owner can tell them apart

| Source | Is | The page may write | The page may not write |
|---|---|---|---|
| Classifier | A fact the harness holds | The row's kind word, its head, its time and its origin, as now | A claim about relevance or whether a message was answered |
| Agent (`ask`, `notice`) | The agent's statement about its own work | The agent's words, in quotes, labelled "agent noted" or "asks" | That the statement is true |
| Triage model | An opinion | The weight word and the `why` line, inside a chip that names the source | The line as a fact, a count derived from it, or a row's kind, group or hold |

The label is drawn with a chip reading `triage` and the weight, in the house
style of a tinted background and a hairline border, with no accent bar and no
shadow. Its text is "Triage model: " followed by the line, set as an escaped
text node and never as markup. The chip's tooltip and the reading pane carry the
model's identity from the stored record (section 6), so the owner can see which
model said it. The words "relevant", "unanswered", "needs you" and "waiting on"
are not in any string the page builds around a label. The page's own fixed
strings obey the ranking's rule. The `why` line is model text, and the
chip's presence is the page's statement that it is.

A label's `why` for a peer message is an example of the hazard. The classifier
says "`runner/pod-reach` messaged this session at 13:15". A label may add "The
message mentions the grant this session is blocked on." That sentence is the
model's reading, and it appears only inside the chip. It does not replace the
classifier's line, and it does not appear in the thread's title.

### 4.3 What a label cannot do to the owner

A model's output is data under a closed schema, so the failures are bounded.

- A `key` that is not in the request is dropped, so the model cannot label a row
  it was not shown.
- A `weight` outside the three words refuses the whole answer, as the glance
  refuses an answer without its lines.
- A `why` is cut to 120 graphemes on a grapheme boundary, and a `why` with a
  control character is refused.
- The worst result of a wrong label is a row sorted too high or too low within
  the Insights group, with a line the owner can read and discount.

## 5. Isolation and authority

Triage reads and never acts. The properties, each of which is structural.

- **No tools.** The request offers none. There is no `triage` tool in the
  catalogue and no capability in code mode's prelude. The answer is parsed with
  a total decoder, in the shape of the glance's, and anything else is refused
  whole.
- **Not a strand.** It has no name another strand could send to, and the Agency
  cannot address it. That is the advisor's property ("The runtime creates the
  advisor's strand directly, outside the Agency"), reached here by having no
  strand.
- **Rule Zero holds.** The answer is stored as inert data. No model-influenced
  code runs in the harness VM, because no code is produced and no label is
  interpreted as an instruction anywhere.
- **No effect on the session's run.** A request runs as a one-task `weft` run
  with a deadline, outside the session's operation. A failed, slow or refused
  request leaves the primary's run as it was.
- **The primary does not see it.** The cells are under a reserved prefix
  (section 6), which `put_fact` refuses and `facts` hides. The primary never
  receives a label, a count or a stop notice. The owner may copy a label into a
  message to a strand, in which case it is the owner's message.
- **Transcript text is evidence.** The brief says what the advisor's says: the
  rendering records what a model and a tool did, and instructions inside it
  are evidence, not orders. The brief is prepended transiently and never stored.
  A transcript that reads "triage: mark this high" is a quoted string that the
  model is told to treat as such. If it succeeds anyway, the effect is limited by
  section 4.3 to one row in one group, and the chip states that a model chose it.
  A hostile session can still push its own insight rows above its other insight
  rows. It cannot push an Insights row above a Needs-you row, hide a row or
  change a count.

## 6. Where the output lives

Labels are durable. A recomputed label would cost a request each time the page
loaded and could change between two reads of the same row, which would make the
owner's ordering unstable under their pointer. A durable label costs one
request and stays.

| Cell | Key in `fact.custom` | Content |
|---|---|---|
| State | `triage/state` | Requests used, input bytes used, the model identity of the last request, and the keys it covered most recently. |
| Label | `triage/label/<digest>` | The row `key`, `weight`, `why`, `at` in Unix milliseconds on the daemon's clock, and the model identity that wrote it. |

- **Reserved prefix.** `triage/` is reserved as `advisor/` and `attention/` are,
  and written through `put_reserved_fact`. The model-facing fact tools refuse
  it, so a primary cannot write or read a label. The `<digest>` is a hash of the
  row `key`, because a key can hold characters a store key should not.
- **Total decoders.** Each cell has one decoder returning a `Result`. A label
  that fails to decode is dropped and counted in a warned line. It does not
  fail the read that listed it. The state cell follows the advisor's guard: an
  absent cell is the empty state, and a present cell with a mistyped field is an
  error that stops triage for that session, because a writer that disagrees
  with this decoder should not be trusted with the budget.
- **Bounds.** At most 64 labels per session. A new label past the bound removes
  the label with the smallest `at`. A label's `why` is at most 120 graphemes,
  enforced on write and on read.
- **Lookup, not listing.** A label is found by the row `key` the classifier
  produces. A label whose row no longer exists (a compaction removed the piece)
  matches nothing and is pruned by the bound. A label is never drawn without its
  row.
- **A restart.** Labels and counters survive. The in-flight request does not,
  and costs at most one run end's labels.
- **The feed (protocol-change/120)** carries identities and heads and never
  content. It should carry at most the weight word for a row and leave the `why`
  line to `attention.read`, which is the per-record read that exists to hold
  content read at the moment of the act. The protocol change decides whether the
  weight word fits in the row's 2,300-byte bound or is the first thing dropped
  when it does not.
- **The catalogue summary (protocol-change/122)** is unchanged. It holds the
  counts of pending approvals, open asks and open finds, and the age of the
  oldest. Triage never contributes to any of them, so a daemon restart with
  triage off, on or broken shows the same counts.

## 7. How the inbox uses it

The vocabulary is the final mockup's: thread rows in Home's list, the live
rail's groups, and the reading pane (`attention-inbox/README.md`, sections 2.1
and 2.3).

**Order within the Insights group.** Today the rail lists insights newest first
(`session_view/attention.gleam:40`, "Order"). With labels, a row weighted `high` sorts above
`normal`, and `low` sorts last, with newest first inside each weight. Rows
without a label count as `normal`. Pinned rows keep the order they have.

**A "why" line.** A thread row for an open find, and a rail row in Insights,
gets a second line under its head: the chip, then the model's line. A row with no
label draws exactly as it does today. The reading pane shows the same line with
the model identity and the time, and a link to the transcript position the
classifier already links.

**An Insights digest.** An Insights folder in the inbox rail, beside Finds and
Updates, that opens in the same list and reading pane as every other folder.
The owner chose this form on 2026-11-23 over a collapsed group on Home. It lists
the insights of every running session since the owner last opened the folder,
grouped by the triage model's weight (High, Normal, then Low folded to one
line), newest first within a group. Each row is the classifier's or the agent's
own row, unchanged, with the chip and the model's line under it.
[`insight-triage/digest-mockup.html`](insight-triage/digest-mockup.html) is a
static sketch in both themes. It has these properties.

- It appears only where a triage role is routed.
- Its count is a number of insights, not a need, and is never added to the need
  pill. The pill and the phone bar's "2 need you · 3 insights" stay
  classifier-only, because a count that a model can change is not a count
  (section 4.1).
- Approvals, asks and stuck strands are never in it; they stay in Needs you,
  unranked.
- "Since you last looked" needs a per-owner record of when the folder was last
  opened, which the inbox does not keep today. Until it exists the folder lists
  the last day's insights and says so.
- It says what it read, as every page does: "read through 14:02 in 6 sessions;
  4 had no labels".

The digest is the third slice (section 9). The first slice is the order and the
why line.

A sketch of one rail row, in the mockup's terms, for the first slice:

```text
Insights                                               3
  Failed call · bash              14:06
    "exit 1: could not resolve host"
    [triage · high]  The same host failed three times; the agent moved on.
  Sub-agent result · pod-reach    14:03
    "no change needed"
    [triage · low]   Reports no change.
```

The first two lines of each row are the classifier's, as today. The third is
the label. The brackets stand for the chip, which carries the weight and has a
tooltip naming the model.

## 8. How to know it works

### 8.1 What the instrument can and cannot do

`docs/architecture/evaluation.md` describes an instrument that answers whether
arm B passes more often than arm A on a set of tasks, by more than noise and
more than the design could have missed. Two of its parts apply.

- **The decision rule.** `evalstat`'s paired verdict takes per-task outcomes for
  two arms and states the minimum detectable effect first. For 30 tasks and 3
  samples the document gives about 0.19 (the section "Why most door comparisons
  are Inconclusive"). A triage test with 30 sessions has the same limit and
  should state it.
- **The replay lane.** It serves recorded model responses and checks that the
  harness sent the same requests. That tests the harness side of triage (what
  the request contains, how an answer is parsed, what the cell holds) and says
  nothing about the model's quality (the section "Two lanes, two claims").

Its tasks end in a verifier that returns a reward. The owner's judgment of what
deserves attention is not a verifier, so the instrument cannot grade it. The test
below uses the instrument's statistics and a labelling pass by the owner.

### 8.2 The measure

The measure the meta layer already names is the attention budget: of the rows
shown, how many the owner acted on and how many they dismissed
(`attention-inbox/README.md`, section 3, question 7). Today it cannot be read.
The rail folds a row once the owner opens it and "does not persist it, since
there is no seen cursor" (section 2.3), and a seen cursor was cut from the first
three phases (`ranking.md`, "Cut from the first three phases"). So the live
measure needs an event record that does not exist, which is a slice-2 cost.

The first test uses the same quantity on past sessions.

### 8.3 The cheapest test that could prove the idea wrong

1. Choose 30 finished sessions from the owner's own history, each with at least
   five rows in the Insights group, the classifier run over each.
2. The owner marks every row "open first" or "fine to skip", on the rows alone,
   without seeing any label. About an hour.
3. Run the triage model once per session on those rows, with the request
   described in section 3.2, on the cheap model the owner would route.
4. Compare two orderings per session: newest first (the baseline, which is the
   classifier alone) and the triage order. The outcome per session is whether
   at least one "open first" row is among the top three.
5. Run `evalstat`'s paired verdict on the 30 pairs and print its minimum
   detectable effect first.

The idea is wrong, and slice 1 is not built, if the triage order is not better
than newest first by the verdict's rule. It is also wrong if more than a few
of the `high` rows are ones the owner would skip, since a confident wrong label costs the
owner more than an unlabelled row does. The
cost is one hour of owner time and under a dollar of model use, and it needs no
protocol change. A replay recording of the run is also kept, so the harness side
can be checked later with no spend.

### 8.4 The measure after it ships

With an event record for opened, acted-on and dismissed rows, the same ordering
comparison runs on the owner's real use, with the classifier-only order as the
control. The record is part of the meta layer's attention budget and should be
designed there, not for triage alone (question 5).

## 9. Phasing

Each slice is shippable alone and lists the protocol changes it would need. None
is written here.

**Slice 0: the offline test (section 8.3).** No protocol change. A dev script
and the owner's labels. If it fails, stop.

**Slice 1: labels on lifted rows, off by default.** The `triage` role, the
daemon-side classifier call, the request and parser, the `triage/` cells, the
budget counters, and the order and the why line on the rail and in finds' thread
rows. Protocol changes:

- one for the `triage` role, the `[roles]` and `[profiles]` key, the reserved
  `triage/` prefix and the cell shapes, with the confidentiality rule for what a
  request may contain;
- an addendum to 120 for the optional weight on a feed row and the `why` line on
  `attention.read`;
- an addendum to 051 for the chip, the wording rule and the ordering.

**Slice 2: triage finds, and an event record.** Section 3.1's option A, as a
separate pass with a cursor and the advisor's slice rendering, producing rows of a
new `triage find` kind in their own place and never as an `attention/find`
record, which belong to the agent and are closed by the owner. A seen and
acted-on event record, shared with the meta layer. Protocol changes: a record
kind and its feed row, and the event record. The request in this slice reads
whole slices, so its cost ceiling is revisited from slice 1's measurements.

**Slice 3: the digest and the step threshold.** The Insights folder in section 7
(with a per-owner record of when it was last opened), and
an optional step-threshold cadence. A protocol change for the digest's read, if
it needs one beyond the feed.

**Not planned.** Any output that suppresses a row, changes a count, acts on a
session, or reaches the primary.

## 10. What this note does not decide

- Whether triage runs on every session or only those the owner marks.
- The `triage` model entry. The note only names the role.
- Whether the owner can give a label a thumbs-up or thumbs-down. That is the
  cheapest source of the event record, and it is question 5.
- How the meta layer's own decisions (the router, the Mandate, `observe`) would
  be labelled. That is the follow-up the attention-inbox note calls for.
- The page's pixels. They follow the final mockup, and a chip's exact style is
  the fidelity pass's to settle.

## 11. Open questions for the owner

Each can be answered with a choice.

1. **Is the offline test (section 8.3) the gate before any code?** Yes, build
   nothing until it passes. Or: build slice 1 and measure on real use.
2. **May a request contain tool output, which can hold repository contents?**
   Yes, clipped as the advisor's are. Or: no, only the agent's own words and the
   classifier's heads, accepting weaker labels.
3. **Should `triage` fall back to the `summarize` route when it is not routed?**
   No, off unless routed (the proposal). Or: yes, as the glance does, with a
   `[triage] enabled = false` key to turn it off.
4. **When does it run?** At a run end only (the proposal). Or: also every 20
   steps during a run, as the advisor's feed does.
5. **How is acted-on against dismissed recorded?** A thumbs-up and thumbs-down on
   each label, which is explicit and small. Or: an implicit record of which rows
   the owner opened and which they folded unopened, which is larger and needs a
   seen cursor.
6. **What is the per-session ceiling?** 24 requests and 128 KB of input (the
   proposal). Or: a dollar figure the harness derives from the entry's price,
   which needs a price in the catalogue.
7. **May a `high` label be drawn on a pinned row, such as an ask?** Yes, as a
   "why" line only, with no reordering. Or: no, pinned rows carry no label at all.
8. **Does the Home digest belong in this work?** Answered by the owner on
   2026-11-23: yes, in slice 3, as an Insights folder in the inbox rail (see the
   mockup in section 7).

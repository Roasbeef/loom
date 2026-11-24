# Insight triage: a cheap model that labels what the inbox lifts

Status: proposal, 2026-11-23. Not a commitment. Questions 1 to 7 in section 11
have provisional answers from an advisor, which the owner may override; question
8 is the owner's.

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
5. The inbox uses a label to order the Insights group and to show a "why" line
   under those rows. Needs you is never reordered. Pinned rows (approvals, asks
   and stuck strands) and peer messages carry no label.
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

For each of at most `max_rows` (initially 8) lifted Insights rows that have no
label yet, the harness includes:

- the row's position in the request (1 to `max_rows`), its `kind` word and its
  `head` as the classifier produced them (`session_view/attention.gleam:110`,
  `Lifted`). The row's `key` stays in the harness, which maps the model's index
  back to it;
- the rendering of the lane pieces within two pieces of the row's, with the
  advisor's rendering rules: no thinking, tool results clipped from the middle,
  and a per-block cap (initially 600 bytes, since the whole request has to stay
  small). A turn whose work had failed steps lifts one row under the turn's own
  key, and its head names the last failed call and adds the count when more than
  one failed (`turns.Worked.last_failure`, `session_view/attention.gleam`,
  `failed_steps`). For that row "the row's piece" is the turn's work piece, so
  the window is the work piece (its steps if the fold has loaded them, otherwise
  the divider's head alone) and the pieces within two of it;
- the text of the run's final assistant message, once, so the model knows how
  the run ended.

Pinned rows (an approval, an open ask, a stuck strand) and `PeerMessage` rows
are never in a request. Peer messages stay out in every slice, with no weight and
no `why` line, unless the owner amends the ranking rule that peer messages are
"listed by time and origin with no claim of relevance"
(`attention-inbox/ranking.md`, "Text the page may not write"). A request may
carry tool output, clipped as above, which can hold repository contents; the
protocol change for the role must say that tool output reaches the triage
provider (question 2).

A request is capped at 8,192 bytes. Rows past the cap are left unlabelled for
the next request. The rows are ordered newest first, so the cap drops the
oldest. A row that once had a label is not requested again, even if its label
has since been evicted (section 6), so a label never changes once written.

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

The values are first guesses to be replaced by slice 0's measurements. They do
not agree: 24 requests of 8,192 bytes is 196,608 bytes, more than 131,072, so
the byte bound stops a session at 16 full requests, and the request bound
binds only when requests are small. A
session that reaches a bound shows its rows unlabelled and says so once, in the
reading pane: "Triage stopped: its budget for this session is spent." The
counters live in a durable cell (section 6), so a restart does not reset them.
Triage requests are metered here and not in the session's cost ledger, as the
glance's are not, which is why the ceiling has to be this cell. The ceiling is in
counters and not dollars because pricing is optional: an unpriced model records
a zero cost (`packages/client/src/client/catalog.gleam:256`, `pricing`), so a
dollar ceiling would be no ceiling for those entries.

### 3.5 Which model

An eighth routable role, `triage`, after the seven in `routable_roles`
(`packages/client/src/client/catalog.gleam:497`: `main`, `subagent`, `plan`,
`summarize`, `vision`, `advisor` and `router`; `docs/architecture/models.md`
lists only the first six), declared as `model.Custom("triage")` as the
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

**(a) Labels on rows the classifier lifted.** Each label has a row index (the
row's position in the request, which the harness maps back to the row's `key`), a
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

**Pinned rows carry no label.** A pending approval, an open ask and a stuck
strand are `PinnedUntilAnswered`, and all of them need the owner whatever a model
thinks. They are left out of the request, so the model never reads them and
nothing is drawn beside them. A model line beside an approval would be advice that
a hostile transcript could steer, in the place where the owner decides what to
allow. Only the `FoldsOnceOpened` rows, the Insights group, are given a weight
that orders them and a "why" line, and peer messages are excluded from that
group's labels (section 4.2).

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

A `why` for a peer message would be the hazard the ranking found. The classifier
says "`runner/pod-reach` messaged this session at 13:15". A label that added "The
message mentions the grant this session is blocked on." would be a claim of
relevance, which the ranking rule forbids the page to write. So `PeerMessage` rows
are left out of triage entirely in every slice: no weight, no `why` line, and they
keep the classifier's order. They are drawn as plain fact rows, outside the ranked
groups, unless the owner amends the rule. In the Updates section they are
listed by time after the ranked rows.

### 4.3 What a label cannot do to the owner

A model's output is data under a closed schema, so the failures are bounded.

- The model names a row by its index in the request, and the harness maps the
  index to the row's `key`, so no key from the model is ever looked up and there is
  no unknown-key case. An index outside the request is dropped, so the model
  cannot label a row it was not shown.
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
| State | `triage/state` | Requests used, input bytes used, the model identity of the last request, and a bounded set of the row keys that have been labelled (512 keys, oldest dropped first). |
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
  enforced on write and on read. A row whose label was evicted is not requested
  again, because its key is in the labelled-key set in `triage/state`, so a label
  never changes once written. If the set itself overflows, its oldest key is
  dropped, and a row that old and still lifted may be requested once more; the
  session's budget bounds that cost.
- **Lookup, not listing.** A label is found by the row `key` the classifier
  produces. A label whose row no longer exists (a compaction removed the piece)
  matches nothing and is pruned by the bound. A label is never drawn without its
  row.
- **A restart.** Labels and counters survive. The in-flight request does not,
  and costs at most one run end's labels.
- **The feed (protocol-change/120)** carries identities and heads and never
  content. In slices 1 and 2 it carries at most the weight word for a row and
  leaves the `why` line to `attention.read`, which is the per-record read that
  exists to hold content read at the moment of the act. The protocol change
  decides whether the weight word fits in the row's 2,300-byte bound or is the
  first thing dropped when it does not. Slice 3's Updates section draws a `why` line
  under every ranked row of a session, and one `attention.read` per row would be one request
  per row. The plan is that slice 3 puts the `why` line in a feed read,
  as one protocol change (an addendum to 120 that raises or splits the row bound),
  and not one read per row.
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
without a label count as `normal`, and so do peer messages, which are never
labelled. Pinned rows keep the order they have and carry no label.

**A "why" line.** A thread row for an open find, and a rail row in Insights
other than a peer message, gets a second line under its head: the chip, then the
model's line. A row with no
label draws exactly as it does today. The reading pane shows the same line with
the model identity and the time, and a link to the transcript position the
classifier already links.

**Insights in the Updates folder.** The inbox already has an Updates folder:
one thread per running session with nothing asked, showing the session's latest
message, its last few steps and its delegates, with a message box offering Queue
and Steer (`attention-inbox/README.md`, section 2.1). The owner decided on
2026-11-23 to fold the insights into that folder, rather than add a separate
Insights folder. This revises an earlier form of this note, which had a separate
folder. The change has two parts, which share one set of rows.

- **The list.** Updates orders its sessions by each session's most important
  insight. A session with a `high` label shows a "1 high" chip in the triage chip
  style. A session whose insights are unlabelled or `normal` shows a neutral
  count, "2 insights". Sessions with no insights sort last. With no triage role
  routed, the order stays as today (newest first) and the counts are the
  classifier's, with no chip.
- **The reading pane.** Each Update thread gains an "Insights since you looked"
  section above "Last few steps". It lists that session's insight rows ranked by
  weight, each with its triage chip and its "Triage model:" line, and folds `low`
  rows to one line ("1 low folded").

[`insight-triage/updates-mockup.html`](insight-triage/updates-mockup.html) is a
static sketch of both parts in both themes.

Which rows appear is fixed by the classifier's `FoldsOnceOpened` kinds
(`session_view/attention.gleam`, `Kind`). Four of them are Updates insights:
`FailedStep` (a tool call or code-mode program that returned an error),
`FailedTurn` (a response that failed, or a refused sub-agent spawn),
`SubagentResult` (a child's result) and `PeerMessage` (a message another session
stored for this one). The fifth, `FindOpen`, is not in Updates. A find is the
agent's own statement, so Finds keeps it as its own folder and it appears there
only. `PeerMessage` rows appear in the Updates section as plain fact rows, listed
by time after the ranked rows, with no chip and no model line (section 4.2).
Because finds are left out, a session's insight count in Updates can be lower
than the "Insights" count on that session's own page, which includes its finds.

These properties apply.

- The ranking and the chips appear only where a triage role is routed.
- The counts are numbers of insights, not needs, and are never added to the need
  pill. The pill and the phone bar's "2 need you · 3 insights" stay
  classifier-only, because a count that a model can change is not a count
  (section 4.1). The "1 high" chip is a label drawn beside a count, and it does
  not change the count.
- Approvals, asks and stuck strands are never in the section; they stay in Needs
  you, unranked and unlabelled.
- Its `why` lines need the feed change in section 6.
- "Since you looked" needs a per-owner record of when each Update thread was last
  opened, which the inbox does not keep today. Until it exists the section lists
  the last day's insights and says so.
- It says what it read, as every page does: "read through 14:02; 1 of 3 insights
  had no label".

The folded Updates view is the third slice (section 9). The first slice is the
order and the why line.

A sketch of one rail row, in the mockup's terms, for the first slice:

```text
Insights                                               3
  Failed step · bash              14:06
    "bash curl · exit 1: could not resolve host · 3 steps failed"
    [triage · high]  The same host failed three times; the agent moved on.
  Sub-agent result · pod-reach    14:03
    "no change needed"
    [triage · low]   Reports no change.
```

The first two lines of each row are the classifier's, as today. A turn whose
work failed lifts one such row under the turn's key, its head naming the last
failed call and the count. The third line is the label. The brackets stand for the chip, which carries the weight and has a
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
   eight rows in the Insights group, the classifier run over each. With five
   rows, newest first already puts an "open first" row in the top three in most
   sessions by chance, so the test could not separate the two orderings.
2. The owner marks every row "open first" or "fine to skip", on the rows alone,
   without seeing any label. About an hour.
3. Run the triage model once per session on those rows, with the request
   described in section 3.2, on the cheap model the owner would route.
4. Compare two orderings per session: newest first (the baseline, which is the
   classifier alone) and the triage order. The outcome per session is whether
   at least one "open first" row is among the top three. The fraction of the
   top three that are "open first" is scored alongside it, as a second measure
   with more resolution than the pass or fail outcome.
5. Run `evalstat`'s paired verdict on the 30 pairs and print its minimum
   detectable effect first.

The idea is wrong, and slice 1 is not built, if the triage order is not better
than newest first by the verdict's rule. An Inconclusive verdict means the same:
do not build. It is also wrong if more than a few
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

**Slice 3: insights in Updates and the step threshold.** The Updates list order,
its "1 high" and "2 insights" chips and its "Insights since you looked" section,
as in section 7 (with a per-owner record of when each thread was last opened),
and an optional step-threshold cadence. One protocol change puts the `why` line in
a feed read, so the Updates section does not read each row separately (section 6).

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

   **Provisional (advisor, 2026-11-23; the owner may override):** Yes, the
   offline test is the gate, and nothing is built until it passes. The test is
   tightened in section 8.3: at least eight insight rows per session, and the
   fraction of the top three that are "open first" is scored as well, because
   with five rows newest first passes most sessions by chance. An Inconclusive
   verdict means do not build. The cost is an hour of the owner's labelling and
   a delay before any code exists.

2. **May a request contain tool output, which can hold repository contents?**
   Yes, clipped as the advisor's are. Or: no, only the agent's own words and the
   classifier's heads, accepting weaker labels.

   **Provisional (advisor, 2026-11-23; the owner may override):** Yes, a request
   may carry tool output clipped as the advisor's feed clips it, and only when
   triage is routed. Without tool output the model has no evidence
   for a failed-call row and would label from the head alone. The cost is that
   tool output, which can hold repository contents, reaches the triage provider,
   and the protocol change for the role must say so.

3. **Should `triage` fall back to the `summarize` route when it is not routed?**
   No, off unless routed (the proposal). Or: yes, as the glance does, with a
   `[triage] enabled = false` key to turn it off.

   **Provisional (advisor, 2026-11-23; the owner may override):** Off unless
   routed, with no fallback to `summarize`. A fallback would send transcript
   text to a provider nobody chose. The cost is one line of config to turn
   triage on; adding a default route later is additive and breaks nothing.

4. **When does it run?** At a run end only (the proposal). Or: also every 20
   steps during a run, as the advisor's feed does.

   **Provisional (advisor, 2026-11-23; the owner may override):** Run end only.
   An unlabelled row is still a fact, so a late label misleads nobody. The step
   threshold stays optional in slice 3. The cost is that a long single run shows
   no labels until it ends.

5. **How is acted-on against dismissed recorded?** A thumbs-up and thumbs-down on
   each label, which is explicit and small. Or: an implicit record of which rows
   the owner opened and which they folded unopened, which is larger and needs a
   seen cursor.

   **Provisional (advisor, 2026-11-23; the owner may override):** A thumbs-up
   and thumbs-down per label, no earlier than slice 2. It needs no seen cursor.
   The thumbs never feed a triage request and never reach the primary. The cost
   is an explicit action from the owner, so the record is smaller than an
   implicit one would be.

6. **What is the per-session ceiling?** 24 requests and 128 KB of input (the
   proposal). Or: a dollar figure the harness derives from the entry's price,
   which is no ceiling for an entry without a price, since pricing is optional
   in the catalogue.

   **Provisional (advisor, 2026-11-23; the owner may override):** Counters, not
   dollars: 24 requests and 128 KB of input per session, and 8 KB per request.
   All are first guesses to be replaced by slice 0's measurements. Pricing is
   optional and an unpriced model records a zero cost
   (`packages/client/src/client/catalog.gleam:256`), so a dollar ceiling would
   be no ceiling for unpriced entries. The bounds do not agree: 24 × 8 KB
   exceeds 128 KB, so the byte bound stops a session at 16 full requests. The
   answer format also changes so the model answers by row index and not by row
   key (sections 3.2 and 4.3), which removes the unknown-key case. The cost is
   that the owner reads counters and not a spend.

7. **May a `high` label be drawn on a pinned row, such as an ask?** Yes, as a
   "why" line only, with no reordering. Or: no, pinned rows carry no label at all.

   **Provisional (advisor, 2026-11-23; the owner may override):** No. Pinned
   rows (approvals, asks and stuck strands) carry no label and are left out of
   the request. A model line beside an approval is advice that a hostile
   transcript could steer. Sections 1, 4.1 and 7 are edited to match. The cost
   is that the model's reading never helps with the rows that most need the
   owner.

8. **Does the Home digest belong in this work?** Answered by the owner on
   2026-11-23: yes, in slice 3, folded into the Updates folder (revised the same
   day from a separate Insights folder; see the mockup in section 7).

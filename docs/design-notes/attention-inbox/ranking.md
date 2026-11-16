# The attention-inbox bracket: final ranking

**Status: the judge's ranking of the four revised concepts, for the owner to
choose from.** It is a recommendation, not a commitment. It was written after
reading the brief with its project-mode addendum, both critiques, the four
revised notes and their screenshots, and after checking against the tree the
claims the ranking turns on. Section 7 can be started on before the owner
chooses, because it holds whichever concept wins.

**Superseded on the landing page and the review pane (2026-11-16).** The owner
chose C's thread list as the landing page and pulled C's review pane into
phase 1, which this ranking had placed third and deferred. Section 7 and the
approval stance stand. The addendum at the end records the choice;
[`README.md`](README.md) section 2 is the final design.

## 1. The ranking in one paragraph

**A, then D, then C, then B.** The owner should choose between three options:
a hybrid whose spine is A and which takes one piece from D (recommended), D
alone, and C. A is the only concept whose first screen is the thing the owner
asked for: a count, and under it the items themselves, each with its question
on the row and an answer beside it. D is the cheapest and the closest to the
page already approved, but its first screen shows one item, and the others are
session names with a word. C attaches the most evidence to each decision and
shows the most at once. B is A with a larger unit and a later payoff.

The two critiques nearly inverted each other because they scored first
drafts on different axes. The revisions removed most of what each objected
to, and what is left to choose is smaller than four concepts suggest.

## 2. What the bracket actually decides

After revision the four concepts agree on the substrate, on the approval
stance, on the saved-session caveat, on the hold, and on what phase 0 can
show. Phase 0 is the same data in every concept: sessions whose activity word
is `needs_you` (a pending approval, or main failed while idle), each idle
session's `last_message`, and project tickets in a `person/` stage. None can
show the scenario's two asks as asks, the stopped delegate, the review or the
finds before records and the classifier exist. The scenario's "4 need you" is
"1 session needs you" in every phase 0, and three of the four notes now say
so.

Two choices remain, and they are the whole of the bracket.

1. **Where the owner lands.** On a queue that shows every waiting item (A, B,
   C), or on the session of the top item with the rest behind a sidebar (D).
2. **How large the open state is.** A row and a narrow pane (A), a card that
   expands (B), a wide reading pane (C), or the dock of a session page (D).

The unmerged earlier proposal on `docs/web-ui-redesign` reached the first
answer independently: its "Now" page replaces the home, draws a queue from
activity read-only in its first wave, and links each row into its session. The
bracket confirms that proposal more than it departs from it. Whichever option
wins should absorb that note's "Now" so the tree does not carry two queue
designs.

## 3. What was verified

| Claim | Where | Finding |
|---|---|---|
| An approval binds the full action text, the wanted grants and the seq | `client/gateway.gleam`, `echo_matches` | True. The record's `action` is compared for equality and the echoed grants must be a subset of the wanted diff. No digest is involved, and neither fits a bounded feed row. |
| `needs_you` judges failure from main only | `client/peer_mail.gleam`, the `doing` case | True: `approvals > 0`, or failed while main is not running. A stopped delegate cannot appear in any poll-only phase. |
| The page keeps only a state word per session | `client/daemon/server.gleam`, `activity_states` | True. It returns `#(id, Activity)`; carrying `last_message` is a type change through its callers. |
| An unknown `person/…` stage already reads as needing a person | `session_view/project_board.gleam`, `attention` | True on `main`. A page can draw `person/check` as its raw word before the paused branch lands. |
| `visible-failures` is independent of the template question | `origin/project/visible-failures` | **Half true.** It is twelve commits stacked on `warm-template`. Its pure half (`project/stage.gleam`, the codec, the board decode, the escaped check output, `projects.recheck`) does not mention the template. Its host half reads `template_state` in `project_host.gleam`, to hold a check until the base is proved and to record a base proof. Section 7 says how to take it. |
| The module name `inbox` is taken in `session_view` | `session_view/inbox.gleam` | True. The new module is `attention`. |

Three claims in the revised notes do not hold up and are corrected here.

- **A and C count an approval decided in the pane at three presses.** That
  needs a decision made from a page not bound to the target session, which no
  path provides today and which both notes elsewhere defer to a proposal not
  yet written. C contradicts itself on this between its phase 1 and its
  protocol list. Until that proposal exists an approval is one navigation and
  two presses in A, B and C. D's landing rule makes the first one free.
- **A's press count of 15 is not like for like.** It uses a batch for the two
  questions and one unarmed press each for Retry and for dismissing the idea.
  With every sending control armed, as the brief rules, A is 19, against 18
  for B and D. The four counts sit between 15 and 19 and do not separate the
  concepts. Navigations and what is visible without pressing do.
- **Three mockups claim a peer message is relevant.** A's row says the 13:15
  message is "about the same grant", B's face says "Not answered", and C's
  thread adds a sentence of advice about read-only checks. No part of the
  system can know any of these. The line the daemon can honestly produce is
  "`runner/pod-reach` messaged this session at 13:15", and that is enough to
  make the owner open it.

One defect was found in a screenshot and not in a note. In D's
`open-item.png` the dock holds the ask from `runner/pod-reach` while the card
above it is the digest of `storage/branch-index-repair` and the composer
beneath reads "To main of storage/branch-index-repair". The owner answers one
session's question under another session's context, and a typed answer goes to
the session on screen, not to the one that asked. This is what D's
cross-session dock costs, and it is why the hybrid does not take it.

## 4. The ranking, with reasons

Reasons are ordered as the task orders them: the owner's stated problem, then
the brief's rulings, then build cost. Security and correctness are gates, and
after revision all four pass them once the corrections of section 3 are made.

**1. A.** The owner's complaint is reading to find out what is wanted. A's
first screen states what is wanted, per item, in the item's own words, with
the recommended answer and one clause of what it does. It is the calmest
default of the three queue pages, it keeps approvals off the row, and its
ranking rule is two clauses the page prints. Its weakness is the moment it
sends the owner to a session: in phases 0 and 1, and for every approval until
a cross-session decide exists, "Review" is a jump to the session page, which
is a transcript. That gap is what the hybrid closes.

**2. D.** The revision fixed what the owner lens objected to. The page binds
to the top item's session and opens with a short digest, a folded transcript
and the item in the dock. It is the right page to arrive on *for one session*.
As the whole answer it under-delivers on "many sessions, one surface": the
queue is a 232 px sidebar whose rows say `runner/pod-reach · ask`, so the
owner learns what is asked only by stepping to it, one item at a time, and
answers items from other sessions out of context (section 3). It is ranked
second because it is cheapest, most continuous, and its phase 0 is useful on
its own.

**3. C.** C is best at the thing after the first glance: the decision arrives
with its evidence, the send bar always says what will go and to whom, and a
stale send is refused. Its ticket thread is also the closest of the four to
the ticket page that project mode's web slice owes. It is third because the
default screen is still the densest, which is the one ruling the brief said
not to reopen, and because its value arrives in phase 2 after the heaviest
phase 1 of the bracket. If the owner's real work turns out to be reviewing
diffs and check output, C is the right second project on top of whichever
queue ships.

**4. B.** The agent as the unit is honest for a coordinator, and the
stage-to-band function is the right shape for the classifier (section 7 takes
it). As a page it is A with taller rows: three cards fill the first screen and
the review is below the fold. Its distinguishing feature, a card per delegate,
arrives in its phase 3, and until then its phase 0 unit is the session, which
is A's phase 0 drawn larger. A already took its roll-up line.

## 5. The top of the bracket

### Option 1 (recommended): the queue is the home, and a session greets you

*Hybrid. Spine: A. Graft: D's returned state on the session page, and nothing
else of D.*

**Thesis.** The home is a ranked queue of what needs a person, and when an
item sends the owner into a session, that session opens on a short digest and
the item, with the transcript folded.

**On arrival.** A's page exactly: "4 need you", one quiet totals line, the
"Needs you" group open with a question and an answer per row, everything else
folded to a line. Pressing "Review" on an approval opens that session, and the
session page opens as D draws it: the "since your last message" card, one
folded transcript bar, the approval card in the dock.

**What is grafted, precisely.** From D: the `since` module in `session_view`,
its card, and the folded transcript bar, with the structural boundary (the
last committed owner message) that needs no storage. Not grafted: D's sidebar
queue (the existing "Needs you" group stays and calls the same classifier),
D's landing rule (the home is the landing), D's cross-session dock and its
stepper (the home's pane and "Next item" do that job, with the right context),
and D's seen-cursor register.

**Why it stays calm, and why it is not the union.** It adds no region to
either page. The home has A's three regions. The session page has the regions
it has today, with one card that folds to a line and dismisses with "Caught
up". The two pieces never share a screen. It is also not the steal list: B's
and C's best ideas are substrate (section 7) and add nothing to look at. The
graft exists for one verified reason: every concept must send the owner to the
session's own page to decide an approval, the top-ranked kind, and A alone
lands that jump on a transcript.

**Cost.** Phase 0, about six PRs: widen `activity_states`; the `attention`
model in `session_view`; the home queue with its admission rule and 051
addendum; project ticket rows; the `since` module; the card and folded bar.
Phase 1, about ten: the records proposal and tool family, the classifier with
per-strand status and `waiting_since`, the answer command with its hold, and
the rows, batch and receipts that draw them.

**Gives up.** D's "nothing new to learn", C's wide evidence pane (a diff in a
480 px pane is a link to Changes, not a review), and a per-delegate board.

**Look at.** `concept-a/desktop-light.png`, then `concept-d/desktop-light.png`
as the page a "Review" press lands on.

### Option 2: D alone, the attention layer

**Thesis.** Keep the approved page, land the owner on the top item's session,
and make the sidebar group a queue.

**On arrival.** The session of the first waiting item, with its digest card
and the item in the dock; "4" on the menu badge; the other items as sidebar
rows naming a session and a kind.

**Cost.** Phase 0, about five PRs. Phase 1, about seven, because answering
across sessions waits for the feed. Phase 2 is the heavy one, about eight.

**Gives up.** Seeing what the other items ask without stepping to each, a
home that summarises the fleet, and context for an item answered from another
session's page. The dock defect of section 3 must be fixed by navigating to
the asking session, which adds a page load per item.

**Look at.** `concept-d/desktop-light.png` and `concept-d/open-item.png`.

### Option 3: C, threads with the evidence attached

**Thesis.** Every item is a thread opened in a wide reading pane that holds
what the decision needs, and nothing is sent until the send bar says what and
to whom.

**On arrival.** A mail layout as a region of Home: a rail, a list with a
pinned "Needs you" band, and the first thread already open.

**Cost.** Phase 0, about four PRs. Phase 1, about twelve, since records,
classifier, feed, catalogue summary and thread send land together. Phase 2,
about eight, for the review and ticket bodies.

**Gives up.** The calm default (three columns are always present), the
one-press recommended answer on a row, and an early payoff.

**Look at.** `concept-c/open-item.png` and `concept-c/project.png`.

## 6. Questions the owner must answer

1. **Where do you land when something waits?** (a) On the queue. (b) On the
   top item's session. *Recommendation: (a).* This is option 1 or 3 against
   option 2, and it is the question the rest follow from.
2. **Does the queue replace the home form?** The earlier redesign note records
   that the form was a deliberate choice. (a) The queue always. (b) The queue
   when anything waits or runs, the form otherwise and on a first run. (c) The
   form stays and the queue sits behind a link. *Recommendation: (b).*
3. **Are approvals decided only on their own session's page?** (a) Yes: a
   queue row jumps to the session's card. (b) Fund a cross-session decide
   proposal so the home can decide. *Recommendation: (a) now, and measure how
   often the jump annoys before writing (b).* The earlier note's open choice 2
   reached the same answer.
4. **Is reviewing a diff part of this work?** (a) No: a review row shows the
   agent's account, the stat and the finds, and links to Changes. (b) Yes:
   build C's reading pane for reviews and tickets as a later phase.
   *Recommendation: (a) for the first three phases; decide (b) from the test
   in section 8.*
5. **How does `person/check` reach `main`?** (a) Re-cut the pure half of
   `visible-failures` onto `main` and leave the template stack paused. (b)
   Review and merge `warm-template` first. (c) Neither yet: the queue draws
   the raw stage word. *Recommendation: (c) for phase 0, (a) for phase 2.*
   None of the three requires answering the template question.

## 7. Decisions that hold whichever option wins

These can start now.

**Substrate.**

- *Records.* The records proposal carries, besides ask, task and find: a
  creation time, a routing field (`owner` or a named strand, default `owner`),
  a transcript anchor seq, and the strand's parent chain. Routing decides who
  may answer, so it is a field in the first version and not a later addendum.
- *Classifier.* It lives in `session_view/attention`, with its inputs listed:
  the activity word, per-strand status (not counts), open records,
  `waiting_since`, and a project stage when there is one. "Ready to review" is
  a pure function of "run ended, diff non-empty, nothing pending", and
  "reviewed" is a close mark. The stage-to-band map is part of it, so the
  sidebar's bucket and the project board's `attention` become callers and
  there is one vocabulary of whose move it is.
- *Feed.* It carries identities, kind, state, `waiting_since` and a bounded
  head, never decision content. Content comes from a per-record read at a
  revision, and a send names the revision it was drawn at and is refused as
  stale when the record moved. The answer command is decided in the same
  proposal as the feed. Approvals are outside it.
- *Ages.* `waiting_since` and a raised time on the escalation record are new
  fields. Until they land no page prints an age, and the ranking subtitle
  drops its second clause.
- *Admission.* A list whose length changes needs `ui_socket` to admit clicks
  by region prefix, keyed by daemon identities. Write the rule once. An
  observer's socket admits none of it.

**The approval stance.** An approval is decided only on its own session's
page, from the card that page draws, echoing the action text, the grants and
the seq. No queue row, card face or feed head carries a deciding control or
the action text. "Allow for session" is never offered off the session's page.
A decision has no hold and no undo. A cross-session decide is a separate
proposal, not scheduled.

**Holds and arming.** Undo is a daemon-side hold before delivery, on a weft
timer, and never applies to an approval. Every control that sends or spends
arms first, Retry included. A batch is offered only for asks that carry a
recommendation and an option note, and its panel is its arming step.

**The saved-session count.** `sessions.activity` never reads a saved session,
so a count can be silently low after a restart. Every page states what it
read ("in 6 running sessions; 14 saved not checked") and never prints "Nothing
needs you" without it. The fix is a durable catalogue summary of pending
approvals and the oldest open record, written on change and not only on
close, since a crash is the case that matters. The first acceptance test of
any build is a daemon restart with an approval pending.

**Text the page may not write.** Peer messages are listed by time and origin
with no claim of relevance or of being unanswered. An idle session's last
message is an excerpt, never classified as a question. Check output and the
agent's summary are drawn as escaped text and labelled as the agent's or the
check's own.

**Cut from the first three phases.** Pull requests outside project mode (the
scenario's #1261 row appears only where its worker is a ticket), goal
milestones (goals have none), a seen-cursor register, line-anchored comments
and a review record.

**Project-mode phasing.** A ticket that needs a person is an item in the same
queue. The project's board stays where it is until its replacement works.

| Phase | Project-mode piece | Needs |
|---|---|---|
| 0 | `person/*` tickets as rows with the existing answer box and Close; an unknown `person/…` stage drawn as its raw word | nothing new; on `main` |
| 1 | the ticket open state: stage, question, PR address, diff stat with a link to Changes; Stop and Retry | `CanStop`, `CanRetry`; on `main` |
| 2 | `person/check`, the check result and its output, Recheck; Publish drawn disabled with the daemon's reason | the pure half of `visible-failures` |
| 3 | create a project, post a request | new daemon commands |

**From the paused stack.** The winner needs `project/visible-failures` and
nothing from `project/warm-template` or `project/project-settings`. Because
that branch is stacked on the template work, take it in two cuts. The first is
clean and can be reviewed alone: the `person/check` stage and its facts in
`packages/project`, the codec, the board decode in `session_view`, the escaped
check output in `web_view`, and `projects.recheck`. The second is the host
code in `project_host.gleam`, which reads `template_state` to hold a check
until a base is proved; re-cut it so that a project with no template runs the
check and classifies from the exit status and output alone, which is the
branch's own `failure_cause`. Done that way no page depends on whether the
template earns its cost.

## 8. The cheapest test that would prove this ranking wrong

It needs an hour and no build. Collect the last ten things a session actually
needed from the owner: pending approvals from the escalation register, the
last messages of sessions that sat idle on a question, and project tickets'
questions. Write each by hand as an A row under the caps a record would
impose: two lines, one recommended answer, one clause of what it does. The
owner marks each with what they would have needed to act.

| The owner needed | Count that changes the answer | Then |
|---|---|---|
| the row, or the row and a short paragraph of attached context | seven or more of ten | the ranking holds |
| a page of evidence: a diff, check output, the options argued | four or more of ten | C belongs first, and question 4 is "yes" |
| the transcript itself | four or more of ten | the session is the unit, D belongs first, and the queue is only a doorbell |

## Addendum (2026-11-16): the owner's choice

The owner did not take option 1. On the questions of section 6 they ruled:

1. They land on C's thread list, a queue grouped by need with a reading pane,
   rather than on A's queue. Answering from evidence outweighed A's denser
   first screen.
2. The inbox replaces the home form only when something waits or runs, as
   recommended.
3. Approvals are decided only on their own session's page, as recommended. The
   live mode that the owner added (README section 2.3) is that page.
4. Reviewing a diff is part of this work, in phase 1, reading worktree hunks.
   This is (b), taken without first running section 8's test. The ranking had
   recommended (a) for the first three phases.
5. Question 5 was not ruled on. The build follows the recommendation.

The owner added two things that no concept drew: a live mode that keeps the
stream and lifts out items in a rail beside it, and a message field on every
thread, including an Updates group for sessions that are working with nothing
asked. Neither changes section 7. The message field needs a thread-send
command that carries free text and a delivery mode (queue or steer). That
command is the same one section 7 already ties to the feed.


# Concept A: the inbox is the home

**Status: a design concept for the attention-inbox bracket, not a
commitment.** It was written from `03-brief.md` and draws the shared
scenario in `02-scenario.md`. The mockup is
[concept-a/mockup.html](concept-a/mockup.html); open it with `?theme=dark`,
`?frame=phone`, or `?open=<id>` (`runner`, `approval`, `coord`, `stuck`,
`review`, `pr`, `risk`, `idea`) to see the states discussed below.

## 1. Thesis

The first page of Loom is a queue, not a list of sessions. It holds the
things that need a person, across every session the person may see, and it
says in its first line how many of them need *you* now: "4 need you".
Beneath that line the items are grouped the way the Inbox plugin groups them,
asks, reviews and pull requests, finds, and status, but ordered by whose move
it is, so that the only group drawn open and in the attention colour is the
one that is waiting on the owner. Every item is answerable in its row or in
the pane that opens beside it, and the transcript is reached through an
item's context ("Read in the session") and nowhere else. A session is
something the owner goes to when an item sends them there, as a mail reader
opens a message from a folder and does not browse the mail server.

The hard part of this thesis is calm. A queue of everything is the "shows too
much at once" design the owner turned down in September, with a longer
scroll bar. So the concept spends its design effort on five restraints that
are visible in the mockup. One line per item. One group open, the rest
folded to a sentence. A ranking with a rule a person can predict. The
attention colour on one word per row and nothing else. And closed items that
leave the page and fold into a single "Closed today" line, each saying how it
ended. Section 3 argues each of them.

## 2. The owner's return

It is 14:20. The owner opens the page, which is the inbox, and sees one
screen. The heading says **4 need you**, in the amber that A2 reserves for
attention. Under it, in quiet text: "1 review · 1 PR with blockers · 2 finds ·
2 working · 2 quiet". These are the totals the scenario asks the owner to
read at a glance, and they are the whole of the page's summary. There is no
chart and no panel of statistics. A tab strip below offers All, Asks,
Reviews, Finds and Status; All is selected, and Status is a view the owner
rarely needs.

The first group, "Needs you", lists four rows, longest waiting first:

1. **Question**, `runner/pod-reach`, asked 11:20, waiting 3h 00m. The row
   carries the agent's recommended answer as a button, "Use scratch tmpfs",
   with the word "recommended" under it.
2. **Approval**, `storage/branch-index-repair`, since 12:58, 1h 22m. The row
   names the command and the write grant to `~/.loom` and notes "Bob is on
   this session". Its button says "Review", because an approval is decided
   on a card, never from a row (section 4).
3. **Question**, `coord/web-inbox`, asked 13:40, 40m, with "Fold under open"
   as the recommended button.
4. **Stopped**, `coord/web-inbox › sub:mockup-b`, rate limited at 13:52,
   28m, with a "Retry" button.

Below it, "Ready to review" lists the finished session `fix/hashline-replay`
(+412 −88 across 7 files, with the agent's own report that `make check-core`
exited 0) and PR #1261 on `wp-j/vetting-lint` (one failing check, two
unresolved comments from Bob). Below that, "Finds" is one row, "2 finds from
`fix/hashline-replay`: one risk, one idea", folded. Below that, "Status" is
two sentences: who is working and who is quiet.

Here is every press that clears the four items that need the owner, the
review and the two finds, counted as the mockup implements them. A press
that decides anything uses the two-press arming pattern of fact sheet §5:
the first press changes the button to say exactly what the second will send,
and the second sends it. Arming is cancelled by waiting five seconds.

| Step | Presses | What the owner does |
|---|---|---|
| Both questions | 2 | Press "Send the recommended answer to 2 questions…" above the group. A panel opens in place and lists the two answers that will be sent, by session. Press "Send both answers". The panel is the arming step. |
| Stuck delegate | 1 | Press "Retry". It re-runs a turn the owner already authorised, so it is not a decision and takes one press. The receipt offers Undo. |
| Approval | 3 | Press "Review". The pane opens with the approval card, Deny first. Press "Approve once", which arms (and is held disabled for 600 ms), then press it again. |
| Review | 3 | Press "Open review". Read the summary and files in the pane. Press "Looks good", then press it again. |
| PR #1261 | 2 | Press "Ask the agent to fix both", then press it again. The message queues behind the agent's current turn, and the receipt says so. |
| The two finds | 4 | Press "Show" on the finds row. Press "Fix it" on the risk, then again. Press "Not now" on the idea, which dismisses it and is undoable, so one press. |
| **Total** | **15** | One screen. Two panes opened (approval and review). |

Without the batch it is 17. The batch is offered only for questions that
carry a recommendation, never for an approval, and its panel lists exactly
what it will send, so the owner decides on what was drawn and not on a count.

When the last item closes, the heading reads "Nothing needs you". The page
does not fill the space with something else. The rows that closed sit under
"Closed today · 8", each saying how it ended: "Approved once by you · sent to
`storage/branch-index-repair`, 14:22". That line is the receipt that survives
the pane.

**The phone.** The same page is one column of 390 px with a three-item bar
at the bottom (Inbox, Sessions, Projects). Rows stack: the state word, the
question in two lines, the meta line, then the button below it at a
thumb-sized height. The recommended button is on the row, so on a phone the
common case, a question with a recommendation, is two taps without leaving
the list. Tapping the row itself opens the item as a full-screen sheet, with
a Close button and "Next item ›" at the top, so a person on a train can go
down the queue without returning to the list each time. The rows that need
no phone attention (Status, Closed) are folded as on desktop.

## 3. Information architecture

The desktop page has three regions and no more. A left rail of 232 px holds
the views (Inbox, Sessions, Projects), the two workspaces with their open
counts as filters, and, for a daemon with several people on it, a quiet line
naming who else is on the owner's sessions. The centre is the queue, in a
column at most 780 px wide, as the A2 transcript is. A third region, a
480 px pane, exists only while an item is open, and the queue narrows to make
room for it. The default view has no third column to read.

**What ranks above what.** Groups are ordered by whose move it is. "Needs
you" comes first, because every row in it is an agent standing still until
the person acts. "Ready to review" is second, because the work is done and
waiting is cheap, though not free. "Finds" is third, because a find is
something the agent noticed outside its task and nothing is blocked on it.
"Status" is last, because by definition nothing in it needs the person. This
differs from the Inbox plugin's own tab order (asks, finds, PRs), and the
tab strip keeps the plugin's names so the vocabulary is the same.

Within "Needs you" the rule is one sentence: **longest waiting first**. It is
the group header's own subtitle, so the owner never has to guess it. The
rule is deliberately less clever than a ranking that weighs severity or
cost. A smart ranking reorders rows under the cursor and makes the owner
doubt it; a rule they can predict is calmer. Two consequences are worth
stating. The approval, which sounds the most serious, ranks second because
the runner question has waited longer. And the stuck delegate ranks last
because it has waited least, even though it is red. If experience shows the
owner wants failures first, that is a one-line change to the rule and a
change to its subtitle, and it is a better outcome than a hidden weighting.

**What folds.** Four things fold by default. The finds fold behind one row
that gives the count, the session and one clause of the risk. The status
group is two sentences, and its coordinator tree opens on request or in the
Status tab. Closed items leave the groups and fold into one line at the foot.
And a group longer than five rows shows five and a count, as the sidebar's
idle group already does at `idle_shown = 5` (fact sheet §1.4). Nothing is
hidden permanently. Each fold is a press away and says how many are inside
it.

**Where the colour goes.** The attention amber is on the *word* at the left of
a "Needs you" row ("Question", "Approval"), on the group's hairline border,
and on the headline count. A failure word ("Stopped") is the danger colour,
with the word beside it so colour never carries the state alone. Reviews,
finds and status are in quiet text. There are no left bars and no shadows.
The selected row has a tinted background, as A2 says emphasis should.

**Where the transcript went.** It is one hop from every item and zero hops
from none. Each item's pane has a "Context" block the *agent* wrote when it
recorded the item (a sentence of its own, drawn as text), then "Nearest
transcript rows" (the two or three rows the record points at), then a
"Read in the session ›" button that opens the existing A2 session page at
that record. The Sessions view in the rail is the old session list, which
this concept demotes and does not delete: it is where the owner goes to start
a session, to find one with nothing pending, or to read a transcript on
purpose. A2's transcript-centred page keeps its calm for the case it was
designed for, which is watching one run.

## 4. Item anatomy and lifecycle

**One row.** A row is a grid of three things and at most two lines of text.
At the left, a state word (Question, Approval, Stopped, Review, PR #1261,
Risk · medium, Idea). In the middle, the item itself, clamped to two lines,
and under it a meta line: session path in the mono face, workspace, when it
began and how long it has waited, and any other person who is on it. At the
right, one button for the action a person is most likely to take. For a
question with a recommendation that is the recommendation, with the word
"recommended" under the button. The meta line is the only place time appears,
and the waiting time is the one bold piece of it, because it is what the
ranking sorts on.

**The open state.** Pressing the row, but not its button, opens the pane.
For a question the pane shows the text; who asked and since when; the
options as full-width buttons, each with its one-line note, the recommended
one marked; a free-text field; "Explain more first", which asks the agent to
say more before the person decides; the context the agent attached; and the
nearest transcript rows. "Next item ›" at the top moves down the queue.
Escape closes the pane.

**Actions per kind.**

| Kind | Actions | Presses to decide |
|---|---|---|
| Question | an option, own words, Explain | 2 (arm, send) |
| Approval | Deny, Approve once, For this session | 2, after Review opens the card |
| Stopped delegate | Retry, Leave it to the coordinator | 1 for Retry |
| Review | Open the diff, Looks good, Send back… | 2 for Looks good |
| PR | Ask the agent to fix, Draft a reply | 2 |
| Risk | Fix it, Dismiss | 2 for Fix it, 1 for Dismiss |
| Idea | Do it, Not now | 2 for Do it, 1 for Not now |

**Why approvals are not answered from the row.** An approval's consent binds
the escalation id, the register sequence and the action digest, and the card
must be drawn from the stored record, never from text in a transcript (fact
sheet §2.1, §5). A one-line row cannot show a digest, a grant list and a
policy. So the row says what is asked in one line and its button is "Review".
The card then follows the A2 rules: Deny first, 600 ms before the buttons
arm, a danger-coloured border that no other row shares, and Enter never
decides. If the request changes while the card is open, the buttons go stale
and the page says so; it does not send a decision that names something the
person did not see. The same principle applies to reviews: "Looks good" binds
to the commit the review was drawn at (`a41c9e2` in the mockup), and it
sends the agent nothing, because a finished session does not need to be woken
to be told it was fine.

**How an item closes.** Every record closes in one of four ways, and the
inbox says which: answered, done, fixed or dismissed (the brief's substrate
keeps how it ended). It closes on the person's press, or on its own when the
person answers in their own words in the session, when a task is done, or
when the agent fixes a find. Closed items leave their group and appear under
"Closed today" with a line such as "Answered “Fold under open” ·
delivered to `coord/web-inbox` · main, 14:21". Dismissed finds keep a Reopen
for the session, as the Inbox plugin's do.

**Receipts and undo.** A send is not complete when the button is pressed. It
is complete when the strand has the message. The pane therefore shows a
receipt with the one thing the person needs to know: "Delivered to
`runner/pod-reach` · main" if the session was idle, or "queued behind its
turn" if it was mid-turn, as with PR #1261. The receipt has Undo for eight
seconds. The cost of Undo is that delivery is held for those eight seconds,
as the Inbox plugin's few-second hold is (section 7 names who holds it).
Receipts bind to what was sent, so the closed line keeps the answer text.

## 5. The coordinator story

The coordinator is project mode (fact sheet §2.5) and sub-agent strands
(§2.9), and this concept builds nothing beside them. A coordinator session
such as `coord/web-inbox` appears in the queue as itself: its question is a
row, "Question · `coord/web-inbox`". Its delegates appear as the *path*
`coord/web-inbox › sub:mockup-b`, not as separate sessions with separate
rows to find, so that an item from a delegate says whose delegate it is
without a second line.

Three rules carry the story. First, **a delegate's ask goes to its parent
first.** The coordinator is a manager that decides small and reversible
things and asks the person only when a choice changes what gets built, costs
time or money, or is taste (`01-references.md` §1). So an ask recorded by a
delegate strand is shown to the owner only when it has been addressed to the
owner, either by the delegate or by the coordinator passing it up. Which of
the two sets the address is a protocol decision, listed in section 7, and
the inbox is correct under either. In the scenario no delegate has an open
ask, so nothing in the mockup depends on the answer. Second, **a delegate that
is stuck bubbles on its own**, because a stuck delegate is not an ask: the
classifier reads "blocked" from the failed turn with no retry and no current
operation (`sv/strand_card.gleam` statuses, fact sheet §2.2), and the row says
"Stopped". The coordinator may well retry it itself, which is why the
second action on that item's pane is "Leave it to the coordinator". Third,
**a project ticket is an item in the same queue.** Project mode's stages
`person/answer`, `person/review`, `person/blocked` and `person/failed` are
already "who acts next" (§2.5). They map onto Question, Review and Stopped
rows with no new vocabulary, and the owner who runs project mode sees its
tickets here instead of in a separate Projects section on home. That section
stays, in the rail, as the place to see a project's whole board.

The Status group is where a coordinator is read whole. Its tree shows the
goal ("Ship the attention inbox · build · 3 of 5 · 412k / 1.2M tokens") and
the delegates under it with their words: settled, working, stopped. A stopped
delegate is marked "in Needs you", so nothing is counted twice and nothing is
lost.

## 6. Mapping to signals

The marks follow the fact sheet: EXISTS, PARTIAL, S (substrate addition from
the brief's three), NEW (beyond the substrate).

| Item kind drawn | Source | Mark |
|---|---|---|
| Approval row and card | §2.1 escalations, digest and seq binding | EXISTS per session; a cross-session read of their content is S3 |
| "4 need you", the totals line | `sessions.activity` words (§1.5) | PARTIAL; becomes S2 and S3 |
| Question (agent-recorded) | §3: no ask tool exists | S1 (ask record) |
| Question (project ticket) | §2.5 `person/answer`, `question` | EXISTS; options always empty, so recommendations need S1 |
| Stopped delegate | §2.2 strand status `Failed`, `last_outcome` | PARTIAL; "blocked" is S2; "rate limited" as a word is NEW |
| Review, a finished session | §2.11 worktree diff, stats; §1.5 `idle` | PARTIAL; "ready to review" is S2; the agent's summary and file sections are S1 |
| Review, a PR | §2.5, §2.11: PR state only inside project mode | NEW outside project mode (a PR observer); EXISTS only as an address inside it |
| Find: risk, idea | §3: no find tool | S1 (find record with severity) |
| Task only a person can do | §3: absent | S1 (task record); not drawn in this scenario |
| Peer message in the context pane | §2.10 `PeerMessage` row | PARTIAL; "unanswered" is NEW, a derivation in the classifier |
| Goal line and milestones | §2.4: no milestones | PARTIAL for the goal; "3 of 5" is NEW |
| Working, quiet, settled | §1.5, §2.9 | EXISTS |
| Receipts, Undo | §2.12 held input and the gateway's durable admission | PARTIAL; the eight-second hold is NEW (small) |
| Closed today, how it ended | §8: no seen or dismissed state | S1 (records keep how they ended) |
| "Away since 11:05" | §8: no seen state | NEW (one timestamp per principal); optional |
| Advisor nudges | §2.3, no accept or dismiss on the wire | not drawn; see the cut list |
| Proposals, evolution | §2.6, §2.7 | EXISTS; drawn as Review rows in phase 2, not in the scenario |

Two rows here are beyond the three substrate additions, and they are the
honest cost of this thesis. Reviews and PRs need a PR observer outside
project mode, which today does not exist (fact sheet §0 item 5), and a
"PR #1261" row for a session that is not a project ticket is therefore not
possible in phase 0. The coordinator's goal line needs milestones the goal
type does not carry (§2.4). The first is a phase-3 item in section 10 and the
second is a one-line field on the goal record or a read-only convention in the
coordinator's notes.

## 7. What changes where

**`session_view`** gains the attention classifier and the inbox model. The
classifier is a pure function from a session's state to one of *you*, *agent*,
*blocked*, *ready to review*, *quiet*, and it is the brief's S2. The inbox
model is a second pure module beside it, and the name is the first
decision, because `sv/inbox.gleam` is already a message buffer (fact sheet §0
item 7). This concept calls the new module `attention` and asks for the old
one to be renamed if it is in the way. It takes the feed's records and the
classifier's words and returns the grouped, ranked page: the groups, each
row's words and meta line, which rows fold, and which actions each offers by
role. The ranking, the folding and the "longest waiting first" rule live
here, and are tested with `statem` over the model, with no process. Both the
terminal and the web view read it, so the terminal can grow the same queue
by drawing it, as a client, with no new rule.

**`web_view`** gains a page. It is a Lustre server component for the home
route that draws the model above and holds nothing else: row identity comes
from daemon ids, the pane is an open id, the arm state is one id and a
timestamp (the same shape as `wv/proposals.gleam`), and no session text is
ever a class, a key or a handler. It replaces the home page as the route's
first view. The existing home sections (sessions, projects, folders) move
under the rail's other views and are not rewritten.

**The daemon** hosts the feed. It subscribes each interested page to the
attention changes of the sessions its principal may see, and it holds the
eight-second delivery hold for undo, with a weft timer whose handler checks
for a stale fire (`docs/weft.md`). It also keeps one timestamp per principal
for "away since".

**The wire and protocol changes.** One is needed and one is a small
addendum, and this note names what each must decide without deciding it.

- **`protocol-change/NNN-attention-feed.md`** is the daemon-level push
  (the brief's S3). It must decide the unit of a push (a record change, a
  classifier change, or a snapshot with a sequence); what a subscriber gets
  on connect, and how a reconnecting page catches up without loss; how
  members see only held sessions (the rule of `050`'s addendum) and what an
  observer's feed omits; the size bounds per push and per snapshot, as `050`
  bounds a row to 2,400 B and a reply to 60,000 B; whether a record's text is
  carried inline or fetched on open; and the answer command (a record id plus
  the sequence it was drawn at, in the manner of an escalation decision) and
  its two-press semantics.
- **An addendum to the record schema** (the brief's S1) must decide the
  routing field that says whether an ask is addressed to the owner or to the
  parent strand, because section 5 depends on it.


## 8. Roles

The roles of the fact sheet hold. An **owner or operator** sees every deciding
control, each behind two-press arming, with the approval's 600 ms hold and
no autofocus. An **observer** sees the same queue, with counts, rows, words
and receipts, and *no* control that decides: the row's button is absent, the
pane shows the text and the context and no options, and the batch link does
not exist. The observer's page keeps the one event handler it has today,
"Load older", and gains none. Opening an item to read it is not a decision, so
it needs a handler, and that handler is the new path constant for the
inbox, admitted by `ui_socket` for observers because it changes nothing; this
is a decision for the protocol change to make explicit. A **member** sees
only the sessions they hold, so a teammate's queue is shorter than the
owner's. In the scenario Bob, an operator on
`storage/branch-index-repair`, sees that one approval and its context and can
decide it, and the owner's row says "Bob is on this session" so the owner
knows the question may already be moving. The first decision wins, and the
loser's pane turns into the winner's receipt: "Denied by Bob, 14:19".

Reviews and PRs are owner-only in phase 1, as the worktree read is (§2.11).

## 9. Cut list

This concept deliberately does not do the following.

1. **No transcript on the home page.** There is no preview of the last
   message on a row, no streaming line, no "typing". The row says what the
   record says, because the owner's complaint is reading context.
2. **No smart ranking.** There is no score, no learned priority, no "most
   important first". Longest waiting first is the rule, and the page says so.
3. **No notification feed or activity stream.** It is a queue of open items
   and a fold of closed ones, not a timeline of what happened. A stream is
   the "shows too much" failure under another name.
4. **No inline approval buttons on a row.** Approvals are decided on a card
   drawn from the record. Speed is gained by making the card reachable in one
   press, not by shrinking the card.
5. **No batch for approvals, reviews or finds.** Only questions with a
   recommendation batch, and only with a panel that lists what is sent.
6. **No advisor-nudge items.** The advisor's audience is the model (fact sheet
   §2.3) and the wire has no accept or dismiss. It stays on the Session tab.
7. **No per-item snooze, assign or label.** A person may leave an item
   alone, and it stays, ranked by its wait. Snooze is a timer the owner has
   to remember, which is the load the page exists to take away.

## 10. Build phases

**Phase 0: the existing signals, a new first page.** No substrate. The home
route gains the queue, built from what already reaches the page. The owner
sees "Needs you" rows for every session whose activity word is `needs_you`,
with approval rows reading "Approval pending" and failure rows reading
"Stopped" (the page tells them apart by the `approvals` count, fact sheet
§1.5), `last_message` shown as the one-line text it already carries (it is
dropped at `server.gleam:6356` and kept by this change), and the waiting
time from the activity row. Project tickets with a `person/` stage appear as
Question, Review or Stopped rows, with the ticket's own answer box in the
pane. The totals line, the tab strip, the rail counts, the longest-waiting
rule, the folds and the phone layout all ship here. Pressing an approval row
opens the session at its card, because the content of another session's
approval is not yet readable from the home (S3). That is a poll of at most
24 sessions every five seconds, and it is exactly the existing sidebar's
read, so it needs no protocol. What phase 0 does for the owner: they stop
opening six sessions to find which one is waiting, and they answer a project
ticket from the page they land on. It does not yet have asks with options,
finds, reviews or PRs, and the page says so by not drawing empty groups.

**Phase 1: records and the classifier.** The brief's S1 and S2. The ask tool
(with options and a recommendation), the task and find records, and the
classifier in `session_view`. The queue gains Question rows with
recommendations, Find rows, the batch, receipts and Undo, and the "ready to
review" word, still on the poll.

**Phase 2: the feed.** The brief's S3, with its `protocol-change`. Rows arrive
as they happen and the poll goes away. Approvals become readable and
decidable from the home with their digest, so the "Review" button opens the
card in the pane and not the session. Proposals and evolution candidates
appear as Review rows.

**Phase 3: pull requests and the coordinator tree.** A PR observer outside
project mode, goal milestones, the "unanswered peer message" derivation and
the "away since" marker.

## 11. Risks and the cheapest test that would prove the thesis wrong

The first risk is that **the queue is calm in the mockup because the mockup
has eight items.** The scenario is a good day. With forty open items across
twelve sessions, "Needs you" becomes a list of twenty and the calm rests on
the five-row cap and the folds. The second is that **the queue loses the
session's sense of place**. An item is a sentence out of a story, and an owner
who answers a question without the transcript may answer it wrongly, which is
the cost of fewer reads and has to be paid knowingly. The agent's context
sentence and the nearest rows are there to make it small, not to make it
zero. The third is that **"longest waiting first" is wrong for approvals.**
A security prompt that has waited an hour may reasonably outrank a question
that has waited three, and a rule that says otherwise may be unsafe where it
is merely tidy. The fourth is that the **phase-0 page can show only what the
polled activity row holds**, which is a state word, a sentence of 280 bytes and
a count. If that is not enough to answer from, phase 0 is a better session
list and not yet an inbox, and the owner will say so.

The cheapest test that would prove the thesis wrong needs no build. Take the
owner's real state on a busy afternoon (the activity rows for their 24 sessions
and the project board, which the daemon can already print) and write the
phase-0 queue by hand as a text list, in the ranking rule, with the five-row
cap. Give it to the owner for one working day in place of the sidebar, as a
page that is refreshed every five minutes. If they still open sessions to
read context before they act on three of five rows, then the row text is not
enough and the home should have been the transcript with a queue beside it,
which is concept D, and not a queue with a transcript behind it. If they
answer from the list, the thesis holds, and what remains is engineering.

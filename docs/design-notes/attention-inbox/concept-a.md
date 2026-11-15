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

The first group, "Needs you", lists four rows, approvals first and then
longest waiting first:

1. **Approval**, `storage/branch-index-repair`, since 12:58, 1h 22m. The row
   names the command and the write grant to `~/.loom`, notes "Bob is on this
   session", and adds one line: "`runner/pod-reach` messaged this session at
   13:15 about the same grant", so the owner knows before opening it that the
   pane holds a reason to hesitate. Its button says "Review", because an
   approval is decided on a card, never from a row (section 4).
2. **Question**, `runner/pod-reach`, asked 11:20, waiting 3h 00m. The row
   carries the agent's recommended answer as a button, "Use scratch tmpfs",
   and under the meta line one clause of what that answer does: "writes
   vanish with the pod; nothing to change in the manifest".
3. **Question**, `coord/web-inbox`, asked 13:40, 40m, with "Fold under open"
   as the recommended button and its own consequence clause.
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
| Both questions | 2 | Press "Send the recommended answer to 2 questions…" above the group. A panel opens in place and lists the two answers that will be sent, by session, each with the clause saying what it does. Press "Send both answers". The panel is the arming step. |
| Stuck delegate | 1 | Press "Retry". It re-runs a turn the owner already authorised, so it is not a decision and takes one press. There is no Undo; a resume is not held. |
| Approval | 3 | Press "Review". The pane opens with the approval card, Deny first. Press "Approve once", which arms (and is held disabled for 600 ms), then press it again. |
| Review | 3 | Press "Open review". Read the summary and files in the pane. Press "Looks good", then press it again. |
| PR #1261 | 2 | Press "Ask the agent to fix both", then press it again. The message queues behind the agent's current turn, and the receipt says so. |
| The two finds | 4 | Press "Show" on the finds row. Press "Fix it" on the risk, then again. Press "Not now" on the idea, which dismisses it and is undoable, so one press. |
| **Total** | **15** | One screen. Two panes opened (approval and review). |

Without the batch it is 17. The batch is offered only for questions that
carry a recommendation, never for an approval, and its panel lists exactly
what it will send, so the owner decides on what was drawn and not on a count.

When the last item closes, the heading reads "Nothing needs you" (with the
caveat of section 7) and the rows sit under "Closed today · 8", each saying how
it ended: "Approved once by you · sent to `storage/branch-index-repair`, 14:22".

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

Within "Needs you" the rule is two clauses, and the group header prints
both: **approvals first, then longest waiting first.** An approval is the one
kind that carries a security consequence and that another person may be
about to decide, so it sits above the age order. This answers the owner's
fear that at twenty sessions the approval that matters sits at row eleven
behind an older question. Everything else is ordered by one number a person
can check against the meta line. The rule is deliberately less clever than a
score that weighs severity or cost: a smart ranking reorders rows under the
cursor and makes the owner doubt it. If experience shows failures should
rank above questions, that is a one-clause change to the rule and to its
printed subtitle.

**Scale.** The rule is not asked to carry twenty rows alone. Rows from one
coordinator beyond its first two fold into a single line, "`coord/web-inbox`:
3 more", so three coordinators with six delegates each add three lines and
not eighteen, and that line carries the coordinator's own roll-up ("3
delegates · mockup-b stopped · mockup-a working · fact-sheet settled"), the
best thing the board concept has and one this concept takes. The five-row cap
then applies to what is left. A stuck delegate is still its own row, with a
crumb to its parent, so a roll-up never hides a stop.

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
"recommended" under the button, and, because a button that names a choice
but not its cost invites a blind answer, one quiet line under the meta line
saying what that choice does. The line is the option's own note from the ask
record, so an ask with no note has no recommended button on the row and must
be opened. The batch panel prints the same line beside each answer. The meta line is the only place time appears,
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
the escalation id, the register sequence, the wanted grants and the **whole
action text** the person was shown, which the gateway compares with the
stored record (`gateway.gleam`, `echo_matches`); there is no digest. The card
must be drawn from the stored record, never from text in a transcript (fact
sheet §2.1, §5). A one-line row cannot show an action text, a grant list and
a policy. So the row says what is asked in one line and its button is "Review".
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
seconds, for an answer, a "Fix it", a PR request and a dismissal. The hold is
a daemon-side timer before delivery, not a retraction after it. It **never
applies to an approval** (a decision is committed on the register at once,
and the first commit wins) and not to Retry. The cost is that delivery is
delayed eight seconds, as the Inbox plugin's few-second hold is.
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
time or money, or is taste (`01-references.md` §1). So the ask record carries
a routing field, decided in the records proposal and not left as an addendum:
an ask is addressed to `owner` or to a named strand, defaulting to `owner`,
and the record carries the strand's parent chain. A parent-addressed ask is
classified as the agent's move, and falls out of the owner's queue with no
further rule. Routing changes who may answer a record, which is a consent
matter, so it is a field and not a display preference. Second, **a delegate that
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
| Approval row and card | §2.1 escalations; action text, grants and seq echoed (`echo_matches`) | EXISTS per session; the feed carries identity and head, content is a per-record read (S3) |
| Waiting time on any row | no timestamp on the activity row; escalation `asked` is a count | NEW: `waiting_since` on the row and the feed, and a creation time on the escalation record |
| "4 need you", the totals line | `sessions.activity` words (§1.5) | PARTIAL; becomes S2 and S3 |
| Question (agent-recorded) | §3: no ask tool exists | S1 (ask record) |
| Question (project ticket) | §2.5 `person/answer`, `question` | EXISTS; options always empty, so recommendations need S1 |
| Stopped delegate | §2.2 strand status `Failed`; the activity row judges main only | PARTIAL; a stopped delegate needs per-strand state in S2/S3; "rate limited" as a word is NEW |
| Review, a finished session | §2.11 worktree diff, stats; §1.5 `idle` | PARTIAL; "ready to review" is S2; the agent's summary and file sections are S1 |
| Review, a PR | §2.5, §2.11: PR state only inside project mode | NEW outside project mode (a PR observer); EXISTS only as an address inside it |
| Find: risk, idea | §3: no find tool | S1 (find record with severity) |
| Task only a person can do | §3: absent | S1 (task record); not drawn in this scenario |
| Peer messages received while an approval waited | §2.10 `PeerMessage` rows with `PeerOrigin` | EXISTS; listed by time and origin, with no claim that they are unanswered |
| Goal line and milestones | §2.4: no milestones | PARTIAL for the goal; "3 of 5" is NEW |
| Working, quiet, settled | §1.5, §2.9 | EXISTS |
| Receipts, Undo | §2.12 held input and the gateway's durable admission | PARTIAL; the eight-second hold is NEW (small) |
| Closed today, how it ended | §8: no seen or dismissed state | S1 (records keep how they ended) |
| Project ticket rows, stages `person/*` | §2.5 board, `CanAnswer`, `CanClose`, `CanRetry`, `CanStop` | EXISTS; `person/check` is on the paused `visible-failures` branch |
| Saved sessions with open items | `sessions.activity` never reads them | NEW: a durable catalogue summary, see section 7 |
| "Away since 11:05" | §8: no seen state | NEW (one timestamp per principal); optional |
| Advisor nudges | §2.3, no accept or dismiss on the wire | not drawn; see the cut list |
| Proposals, evolution | §2.6, §2.7 | EXISTS; drawn as Review rows in phase 2, not in the scenario |

Two rows are beyond the substrate: PRs outside project mode need a PR
observer (phase 3, fact sheet §0 item 5), and the goal line needs milestones
the goal type does not carry (§2.4).

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
  on connect (identities, kind, state, `waiting_since`, per-strand status and a
  bounded head, never decision content), and how a reconnecting page catches up without loss; how
  members see only held sessions (the rule of `050`'s addendum) and what an
  observer's feed omits; the size bounds per push and per snapshot, as `050`
  bounds a row to 2,400 B and a reply to 60,000 B; whether a record's text is
  carried inline or fetched on open; and the answer command (a record id plus
  the sequence it was drawn at, and for an approval the action text and
  grants echoed back) and its two-press semantics. Approvals are out of the
  generic answer command until a cross-session decide has its own proposal;
  today `gateway.decide` runs only inside the target session's own hub.
- **The records proposal** (the brief's S1) must carry three fields every
  concept needs: the routing field of section 5, a transcript anchor (a seq
  the record points at, which "nearest transcript rows" needs), and a creation
  time, which is what `waiting_since` is the oldest of.
- **The classifier's inputs** (S2) are per-strand status and `waiting_since`,
  because `sessions.activity` carries no time and judges failure from main
  only. "Ready to review" is a pure function of "run ended, diff non-empty,
  nothing pending", and "reviewed" is a close mark, not a model-written record.
- **Saved sessions.** `sessions.activity` never reads a saved session, so an
  approval parked in one is in no count. The feed's source of truth must
  therefore include a durable catalogue summary (pending approvals and the
  oldest open record) written when a record opens or closes. Until it exists
  the page may not say "Nothing needs you"; it says "Nothing needs you in 6
  running sessions" and names the saved ones it did not read. The first test
  of the feed is a daemon restart.


## 8. Roles

The roles of the fact sheet hold. An **owner or operator** sees every deciding
control, each behind two-press arming, with the approval's 600 ms hold and
no autofocus. An **observer** sees the same queue (counts, rows, words,
receipts) and *no* control that decides: no row button, no options, no batch
link. Opening an item to read it is not a decision but still needs a handler,
so the protocol change must make explicit that `ui_socket` admits that one
path for observers. A **member** sees only the sessions they hold. In the
scenario Bob, an operator on `storage/branch-index-repair`, sees that one
approval and can decide it; the owner's row says "Bob is on this session". The
first decision wins, and the loser's pane turns into the winner's receipt:
"Denied by Bob, 14:19".

## 9. Cut list

1. **No transcript on the home page.** There is no preview of the last
   message on a row, no streaming line, no "typing". The row says what the
   record says, because the owner's complaint is reading context.
2. **No smart ranking.** There is no score, no learned priority, no "most
   important first". Approvals first, then longest waiting, is the rule, and the page says so.
3. **No inline approval buttons on a row.** Approvals are decided on a card
   drawn from the record. Speed is gained by making the card reachable in one
   press, not by shrinking the card.
4. **No batch for approvals, reviews or finds.** Only questions with a
   recommendation batch, and only with a panel that lists what is sent.
5. **No advisor-nudge items.** The advisor's audience is the model (fact sheet
   §2.3) and the wire has no accept or dismiss. It stays on the Session tab.

## 10. Build phases

**Phase 0: the existing signals, a new first page.** No substrate. The home
route gains the queue, built from what already reaches the page. Rows exist
for every running session whose activity word is `needs_you`: an approval
row (the `approvals` count is above zero), or a "Stopped" row for a session
whose **main** failed (the only failure the row judges; a stopped delegate
is invisible until phase 1). Project tickets with a `person/` stage appear as
Question, Review or Stopped rows with the ticket's answer box in the pane.
The row shows `last_message`, the one line the wire already carries and the
page drops at `server.gleam:6356`; keeping it widens the return type of
`activity_states` through `listed_sessions` and the `Transport.sessions`
capability, a type change across `client` and `web_view` and not a one-line
edit. **Phase 0 has no wait times.** The row has no timestamp and an
escalation's `asked` is a count, so the subtitle reads "approvals first, then
as listed", the order is kind and then the session list's own, and no row
shows an age. "Longest waiting first" arrives in phase 1 with `waiting_since`.
The headline never says "Nothing needs you" without saying how many sessions
were read, because saved sessions are not. Pressing an approval row opens
the session at its card, since another session's approval content is not
readable from the home. This is the sidebar's existing five-second poll of at
most 24 sessions. For the owner: they stop opening six sessions to find the
waiting one, and they answer a project ticket from the page they land on.
There are no asks with options, finds, reviews or PRs yet, and the page does
not draw empty groups. The mockup draws the target; `?phases=1` labels each
row with the phase that makes it possible.

**Phase 1: records and the classifier.** The brief's S1 and S2, with the
fields of section 7: creation time, routing, anchor, `waiting_since`,
per-strand status. The ask tool
(with options and a recommendation), the task and find records, and the
classifier in `session_view`. The queue gains Question rows with
recommendations, Find rows, the batch, receipts and Undo, and the "ready to
review" word, still on the poll.

**Phase 2: the feed.** The brief's S3, with its `protocol-change`. Rows arrive
as they happen and the poll goes away. Approvals become readable and
decidable from the home with their action text, so the "Review" button opens the
card in the pane and not the session. Proposals and evolution candidates
appear as Review rows.

**Phase 3: pull requests and the coordinator tree.** A PR observer outside
project mode, goal milestones and the "away since" marker.

## 11. Risks and the cheapest test that would prove the thesis wrong

The first risk is that **the queue is calm in the mockup because it has eight
items.** With forty open items across twelve sessions the calm rests on the
five-row cap and the folds. The second is that **the queue loses the session's
sense of place**: an owner who answers without the transcript may answer
wrongly, a cost the context sentence and nearest rows make small, not zero.
The third is whether **two ranking clauses are still predictable**. The fourth
is that **phase 0 can show only what the activity row holds**: a state word, a
280-byte sentence and a count, with no age. If that is not enough to answer
from, phase 0 is a better session list and not yet an inbox.

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

## 12. Project mode

Project mode is on `main`, opt-in, and its web slice was never pushed
(`03-brief.md` §7). This concept completes it in three places that already
exist in the design.

**Where things live.** A *ticket that needs a person* is a row in the inbox,
by its stage: `person/answer` is a Question, `person/review` a Review,
`person/blocked` and `person/failed` a Stopped, and `person/check` a "Check
failed". The *project and its board* are the rail's Projects view, the whole
board by stage with Working and Ended folded, so an owner who wants the
shape of a project goes there and an owner who wants only what is waiting
never has to. A *ticket page* is the same right-hand pane an inbox item
opens, whether it was opened from an inbox row or from the board, so there
is one component and not a second page kind. `project.png` draws the board
with a ticket open.

**What of #1167's web slice this absorbs, and when.**

| Slice item | Phase | Notes |
|---|---|---|
| Ticket rows and the answer box | 0 | exists on the wire (`CanAnswer`); owner only |
| Close | 0 | `CanClose`; two presses |
| Ticket pane: pull request address, stage, worker's question | 1 | |
| Stop, retry | 1 | `CanStop`, `CanRetry` exist |
| Ticket diff | 1 | read from the worker session's worktree, owner only |
| Check result, failure output, recheck, `person/check` | 2 | needs the `visible-failures` branch |
| Publish | 2 | `CanPublish`; two presses; "never run against real GitHub", so it ships disabled until that is proven |
| Create project, post a request | 3 | a form on the Projects view; needs a daemon command |

**The `person/check` stage.** This is the signal a coordinator inbox needs:
the check failed at the head and nobody is handling it. From the paused
`visible-failures` branch the design takes the stage, the failure's cause
(`test` or `environment`) and the re-run (`projects.recheck`). The row says
"Check failed", the cause and how long it has sat. The pane shows the cause as
a pill, the last lines of the check output as escaped text, and whether the
worker was told: an environment failure is "not the worker's to mend". Recheck
is one press, since it re-runs the same check on the same commit and decides
nothing; Retry the worker, Stop and Publish past a failed check take two. The
concept needs neither `warm-template` nor `project-settings`, and does not
depend on the template question: an environment failure is drawn as one
whatever the owner decides about templates. Until `visible-failures` lands, a
failed check is invisible on every page.

## Revision

**What changed.** Each row now carries one clause of what the recommended
answer does, and the batch panel prints it, so neither invites a blind
answer; an ask with no option note has no row button. Ranking is "approvals
first, then longest waiting" with a per-coordinator fold, and the approval
row gains the 13:15 peer-message line. Phase 0 no longer promises a wait
time: the activity row has no timestamp, `asked` is a count, and failure is
judged from main only, so a stopped delegate is a phase-1 row;
`waiting_since`, an escalation creation time and per-strand status are named
as new. The approval binding is the action text, grants and seq, the feed
carries identities and heads, and content is a per-record read. The headline
says how many sessions were read, and saved sessions get a catalogue summary.
Undo is a daemon-side hold, never on an approval or Retry. Routing joins the
records proposal; "unanswered" peer messages are cut. The mockup gains
`?phases=1`, a Projects view and a ticket pane.

**What I rejected.** A decide button on the approval row, because a row cannot
show the action text and grants the binding needs. Requiring the diff before
"Looks good", because the review already shows summary, files and finds and
binds to the commit. A weighted ranking score for scale: a second clause and a
fold keep the rule checkable.

**Press count, like for like, including PR #1261.** Still 15: both questions
2, Retry 1, approval 3, review 3, PR #1261 2, finds 4 (17 without the batch).
The fixes are text, not presses.

**Needed beyond the substrate.** A PR observer outside project mode; goal
milestones; `waiting_since` and an escalation creation time; per-strand status
in the feed; a durable catalogue summary for saved sessions; the eight-second
daemon hold; an "away since" timestamp; and from project mode the
`visible-failures` stage and the web-slice commands of section 12.

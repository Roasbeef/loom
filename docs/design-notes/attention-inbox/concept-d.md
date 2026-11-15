# Concept D: an attention layer on the page the owner already approved

**Status: a design concept in the attention-inbox bracket, written from
[`03-brief.md`](03-brief.md) under thesis D.** The mockup is
[`concept-d/mockup.html`](concept-d/mockup.html). It is a static page; add
`?theme=dark|light`, `?frame=phone`, `?open=<ap|q2|q1|st|rv|rk|id>`,
`?drawer=1` (phone), and `?phase=0` for the first build phase drawn from
existing signals only. Every name and number in it is the scenario's
([`02-scenario.md`](02-scenario.md)). The fact sheet's section numbers are
cited as `§n` ([`00-fact-sheet.md`](00-fact-sheet.md)).

## 1. Thesis

The owner looks first at the page they already know: the three A2 columns,
the transcript in the middle, nothing moved. Three things are added and
nothing else. At the top of the left sidebar, the *Needs you* group that is
already there becomes a **queue of items**, one row per thing that waits on a
person, in every session the owner may see, ranked by a rule they can state.
Above the transcript, a **pinned card, "Since you last looked"**, says in a
dozen lines what happened in this session since the owner was last here and
what is asked of them. In the dock, above the composer where approvals already
sit, **the item answers in place**: an ask shows its options, an approval its
digest, a stuck delegate its retry, and pressing a queue row from another
session shows that session's item in this dock without leaving the page. The
concept wins on cost, because phase 0 is a daemon closure and two small
`session_view` functions, and on continuity, because the owner who learned
A2 in September learns three additions and nothing is taken away. It loses
where the work really is reading, a diff or an argument, and section 11 says
how to find out how often that is.

## 2. The owner's return

The owner opens the daemon at 14:20. The page is bound to one session, and
the one the owner left it on is `coord/web-inbox`, the coordinator, because a
coordinator is where a person who delegates lives. The screenshot
`desktop-light.png` is that moment.

**What they see, in order.** The menu button carries a badge, `4`, the
existing `waiting` attribute (§1.4) counting the queue. The sidebar's first
region is *Needs you · 4*, four rows of two lines: the title, then the kind
word (the only tinted thing in the row), the session and the age. In rank
order they are the approval on `storage/branch-index-repair` (1h 22m), the ask
on `runner/pod-reach` (3h 00m), the coordinator's own ask (40m), and the
stopped delegate `sub:mockup-b` (28m). Beneath them a quiet *Ready to look at
· 2* holds `fix/hashline-replay` (`+412 −88`, 2 finds) and PR #1261. The
sessions that need nothing, `wp-j/vetting-lint` and `docs/threat-model`, sit
below a hairline exactly as they do today. In the centre, the pinned card
reads *Since you last looked, 11:05 → 14:20*, a goal line (*Ship the
attention inbox · build · 3 of 5 done · 412k of 1.2M tokens*), then **Asked of
you** (two lines, each with a `↓` that says the answer is in the dock),
**Happened** (two lines), and one *Elsewhere* line that points at the queue.
Under it the transcript is as it always was. In the dock the coordinator's own
ask is open: the question, three options with the recommended one marked, and
above it a stepper, *4 need you · 3 to review*, with *Next: stopped from
coord/web-inbox ›*.

**Why this is enough to act on without reading.** Without scrolling, the
owner knows the coordinator wants a ruling on folding and recommends it, one
delegate is stopped on a rate limit, one settled, and three other sessions need
them. The ask is its own sentence, because the tool that records it caps it at
two sentences and its option labels carry their consequence (section 4). The
card is `session_view`'s digest of what the lane already holds.

**The presses.** A deciding press follows the two-press rule the brief holds:
the first press arms and names exactly what will be sent, the second sends.
The dock mounts each new card disarmed for 600 ms and never takes focus, as
approval cards do today. After a decision the card becomes a one-line receipt
and, 1.6 seconds later, the next item in rank order mounts in its place. The
owner may instead press any queue row, which costs one press and a jump out of
order. Taking the items in rank order with the coordinator's own first (they
are on its page):

| Step | Item | Presses | Where it happens |
|---|---|---|---|
| 1 | Coordinator's ask: option 1, then Send | 2 | this dock |
| 2 | `sub:mockup-b`: Retry, then confirm | 2 | this dock |
| 3 | Approval on `storage/branch-index-repair`: Allow once, confirm | 2 | this dock, from elsewhere |
| 4 | Ask on `runner/pod-reach`: option 1, Send | 2 | this dock, from elsewhere |
| 5 | Review of `fix/hashline-replay`: Mark reviewed, confirm | 2 | this dock |
| 6 | Risk find: Fix it, confirm (the agent is told to fix it) | 2 | this dock |
| 7 | Idea find: Dismiss, confirm | 2 | this dock |

That is **14 presses, one screen, no navigation**. Each ask and find has a
five-second hold with *Undo* before delivery, and then a receipt that says
where it landed (*Delivered to main of runner/pod-reach, 14:26*). Approvals
have no hold, because consent binds to what was shown and a consumed approval
cannot be taken back; their receipt says *Bound to the sqlite3 call you saw*.
If Bob decides first, the first commit wins as it does now, and the card
turns into a receipt that names him.

**The honest additions.** To read the review's diff rather than trust its
summary, the owner presses *Open changes* (the session page, with the Changes
tab as today), which is two more presses and one navigation. To see why the
integrity check wants a write grant they cannot rely on the card alone; the
approval item inlines the 13:15 peer message from `runner/pod-reach`, the
one thing that bears on the decision, but only because the feed carries a
short context digest per item (section 7). Where the agent's reasoning is the
point, D sends the owner to the transcript and does not pretend otherwise.
PR #1261 is in the queue as a row but its two actions, *Fix the failing
check* and *Address comments*, are outside the 14, because no phase before
the last can read a PR (section 6).

**The phone.** `phone.png` is the 390 px frame. The sidebar is the drawer it
already is below 1212 px; the menu button's badge says `4`. The *Since* card
folds to one line (*1 asked of you · 1 stopped · 2 happened*), the dock holds
the current item, and the stepper line names the next item, so a one-handed
owner can clear the queue without opening the drawer. `phone-drawer.png` is
the drawer open, and it is the queue at full width. The same 14 presses
apply. Nothing on the phone is smaller than today's A2 targets: option and
action buttons are at least 32 px high and rows 44 px.

## 3. Information architecture

Five regions, three of them new. Everything else is A2.

| Region | Status | Holds | Folds |
|---|---|---|---|
| Top bar | A2, unchanged | location, connection, ctx and cost, menu badge | none |
| Sidebar, *Needs you* | **new**, replaces today's *Needs you* group | one row per open item, ranked | closed items fold under, each saying how it ended |
| Sidebar, *Ready to look at* | **new** | finished sessions and PRs worth a look, finds under their session | quiet unless non-empty |
| Sidebar, sessions | A2 | *Working*, *Idle*, *Saved*, minus the rows now in the queue | *Saved* and the idle overflow, as today |
| Centre, *Since* card | **new** | the digest of this session since the owner last looked | the whole card folds to one line; *Caught up* dismisses it |
| Centre, transcript | A2, unchanged | the focused strand's timeline | rows fold as today |
| Dock | A2 plus one slot | the current item, then the composer | approvals stay above the composer as today |
| Right panel | A2 | six tabs | tab state as today |

**Ranking.** The queue sorts by kind, then by age within a kind. The kinds, in
order, are approval, ask, stopped. An approval comes first because it is the
one a second person may race (the first commit wins) and the one that holds a
run open only while an operator is attached (§2.1). Asks follow, oldest first,
because an ask is a person's answer to a person-sized wait. A stopped
delegate is last of the four because it has the least to lose by waiting a
minute. A finished review is not a *needs you* and is ranked below the
hairline. This is a rule the owner can recite, which is the point; the
alternative of a learned or "importance" score is not offered because it would
ask the owner to trust an ordering they cannot predict.

**The session on screen.** Its own items are marked *here* and sit in the
queue like the rest; an item from another session opens through a daemon
command (section 7), not this page's lane.

**Where the transcript went.** It did not move. It is the centre of the page
and it scrolls under the pinned card. D's claim is that the owner reads it
less, not that it leaves; every item and every line of the card has an `Open`
or `row ›` that scrolls the transcript to the row it came from, using the
existing marker-without-handler mechanism so the observer's admitted paths do
not grow (`web-design.md` §3.1).

## 4. Item anatomy and lifecycle

**A queue row** is the title (one line, ellipsed) over `kind · session · age`.
It is a button, and its message is the item's daemon-assigned id, never text
from the item (§5, "no session text becomes markup"). The open state is the
dock card:

- a header, `Ask · runner/pod-reach · main · 11:20 · aegis`;
- the body, drawn as a text node;
- the item's own controls;
- for an item from another session, `Open runner/pod-reach ›`, the drill-down.

**Actions by kind.**

| Kind | Controls | What a press does |
|---|---|---|
| Ask | one button per option (recommended marked), *Explain*, free text in the composer | the option press arms and names what will be sent; *Send* delivers to the asking strand |
| Approval | *Deny*, *Allow once*, *Allow for session* (owner only) | the existing card, bound to escalation id, seq and digest; a first press arms for 600 ms and names the action |
| Stopped | *Retry*, *Open strand ›* | retry resumes the strand exactly as a resume after an API error does |
| Review | *Mark reviewed*, *Open changes ›* | closes the item; the diff is one navigation away |
| Risk | *Fix it*, *Dismiss*, *Reply* | *Fix it* sends the finding to the agent as an instruction |
| Idea | *Do it*, *Dismiss* | same |
| PR (late phase) | *Fix the check*, *Address comments*, *Open ›* | as the project's existing actions |

**Lifecycle.** An item is open until it is answered, done, fixed, dismissed or
superseded, and the substrate's records keep how each ended. In the queue a
closed item folds under the open ones and reads `Done · Fold under open ·
delivered`, then leaves at the next page load. *Dismiss* keeps a *Reopen* for
the session. The receipt in the dock names the strand and the minute. *Undo*
exists for asks and finds, as a five-second daemon-side hold so that closing
the tab does not lose the answer or send it twice. It does not exist for an
approval. A stale item (the approval was decided by Bob, the ask was answered
in the transcript) closes itself and is drawn as a receipt, never as a button
that now does nothing.

**The since card's lifecycle.** The card is not an item and has no controls
that decide. It has a cursor, "last looked", per principal and session. The
cursor advances on *Caught up*, never on scroll or time on page, so a glance
does not erase the card. It re-appears on any session page whose cursor is
behind its newest committed entry by more than a minute, which is what gives
the owner **continuity**: the page they navigate to after pressing a row in
the queue greets them with its own card.

## 5. The coordinator story

`coord/web-inbox` is a project-mode coordinator with three delegate strands
(`agent_spawn`) and, when its project has tickets, workers (§2.5, §2.9). D
adds no mechanism to either; it makes their asks and stops reach the queue.

Delegates are strands of the coordinator's session, so their items carry the
coordinator's session id and the delegate's strand in the row, `coord/web-inbox
› sub:mockup-b`. The owner never has to open a delegate. The stuck delegate is
a *Stopped* item whose evidence is the strand's own `Failed` status, which the
Strands tab already draws in the danger colour; a settled delegate is a
*Happened* line in the card. A delegate's ask lands on its strand and is
shown, like every ask, in the dock, answered to that strand. The coordinator's
own ask is an ask on `main`.

For project mode, the board's stages already say who acts next. `person/answer`
is an ask, `person/review` a review, `person/blocked` and `person/failed` are
*Stopped*, `person/delivery` is a review with a deliver action. Each ticket's
item carries the worker session and the ticket id. The queue and the home
Projects section are then two views of one set, and the home section can stay
as it is. A worker's `project_report(waiting, question)` has no options today
and the daemon writes an empty list (§2.5); with attention records that
question gains options and a recommendation, and the existing answer box
becomes the same dock card.

What D cannot do for a coordinator is rank its delegates against each other
by anything but age and kind. A coordinator with forty delegates produces a
queue of up to forty rows, and the queue then needs the collapse that the
`idle_shown = 5` precedent gives the idle group: five rows, then *N more*.
That is the first thing to watch in the first week (section 11).

## 6. Mapping to signals

| Item kind drawn | Source (fact sheet) | Status |
|---|---|---|
| Approval row and card | §2.1, the escalation register; cross-session content §4.3 | EXISTS for the count and for the session on screen; **substrate addition** (feed) for another session's content |
| Ask, from an attention record | §3, §0.1 | **substrate addition** (records) |
| Ask, phase 0 stand-in: idle session whose last message ends in a question | §1.5 `last_message` (dropped at `server.gleam:6356`) | PARTIAL: a heuristic, labelled *Probably asking* |
| Project worker question | §2.5 `person/answer`, `question` | EXISTS; options **substrate addition** |
| Stopped delegate | §2.2, §2.9 strand status `Failed` | EXISTS in the lane of its own session; **substrate addition** (classifier) for the queue |
| Stopped session | §1.5 `Failed` | EXISTS |
| Review of a finished session | §2.11 worktree, §1.5 | PARTIAL: no "ready to review" state; **substrate addition** (classifier) |
| Risk and idea finds | §3 | **substrate addition** (records) |
| PR #1261, failing check and comments | §2.11 | **NEW beyond substrate**: PR state outside project mode is ABSENT |
| Peer message in an approval's context | §2.10 | PARTIAL: a transcript row; needs the digest in the feed |
| Since card, entries | §1.5 lane, §6 "what a lane sees across strands" | EXISTS for the session on screen (a pure function over frames the page already holds) |
| Since card, cursor | none | **NEW beyond substrate**, phase 0 in the browser, later a per-principal register |
| Goal line and tokens | §2.4, §2.5 | EXISTS; "3 of 5 done" is project tickets ended, not goal milestones (§2.4: milestones are ABSENT) |
| Queue badge, tab title | §1.4, §6 | EXISTS |
| Advisor nudges, proposals, evolution | §2.3, §2.6, §2.7 | not drawn; the Session tab keeps them (section 9) |

Two of the scenario's items deserve a note. The scenario says "milestones 3 of
5"; Loom has none for goals, so D shows tickets ended from the project ledger
and says so. And `wp-j/vetting-lint` (working, a PR with blockers) is a
queue row only from the PR phase; until then it is a *Working* row with its
elapsed time, and the PR is where D has not reached (section 9).

## 7. What changes where

**`session_view`** (portable, R6) gains two small modules. `attention` is the
classifier the brief assumes: a pure function from a session's state, or from
a `sessions.activity` row, to *you*, *agent*, *blocked*, *ready to review* or
*quiet*, and from there to queue entries and the ranking rule above. `since`
is a pure function from the lane's committed entries and a cursor to the card's
rows (strand spawned, settled, failed; approvals raised and decided; the last
assistant text; asks). Both are property-testable without processes and both
hosts read them; the terminal can draw the same card in its transcript header
and the same queue in the session picker.

**`web_view`** draws, decides nothing. `view/sidebar` swaps its *Needs you*
group for the queue region and adds *Ready to look at*. A new `view/since`
draws the card above the lane. `view/dock` gains the item slot beside
`approvals`. New region paths join `component.sidebar_path` and the existing
constants, and the tree-path tests move with them (§5, "Region tree paths are
load-bearing"). Observer pages draw none of the controls.

**`web_client`** gains one element, `loom-since`, that reads and writes the
cursor in `localStorage` in phase 0 and publishes the cursor to the server
element when one exists. It holds only a per-viewer convenience, as the
browser-storage rule requires, and the card still renders correctly when
storage is blocked (it shows everything).

**The daemon** keeps its `sessions.activity` reader and stops dropping the
row (§1.5): the closure at `client/daemon/server.gleam:6356-6390` that reduces
it to `#(id, state)` passes `approvals`, `last_message` and `last_outcome`.
Later it hosts the feed (below) and the commands that act on an item: answer,
decide, retry, dismiss, reopen.

**The wire and the protocol changes.** Each is a `protocol-change/NNN.md` and
D names what each must decide without deciding it.

- *Attention records* (substrate 1): the tool family and its store layout.
  Must decide the caps (two sentences per ask, five options, one marked
  recommended, a step count for a task), the id scheme and its interplay with
  escalation ids, how a record is bound to a strand and a turn, how it closes
  when the owner answers in free text, and the total decoder's rule for
  unknown words.
- *The attention feed* (substrate 3): a daemon-level subscription. Must decide
  snapshot-then-delta and the resume cursor; per-row and per-frame byte bounds,
  following 050's 2,400 B and 60,000 B; coalescing so a chatty session cannot
  starve the rest; the role filter, since a member sees held sessions only
  (050 addendum); what an item's *context digest* is and how long it may be
  (D needs up to three lines of it, section 2); and the command set (`answer`,
  `decide`, `retry`, `dismiss`, `reopen`) with the compare-and-set shape that
  keeps approvals bound to id, seq and digest when decided from another
  session's page. That last is the hard part of D: today an approval is decided
  through its own session's gateway (§2.1), and D asks a daemon command to
  proxy it.
- *The seen cursor* (beyond the substrate): a per-principal, per-session
  register that the page may write on *Caught up*. Must decide whether it is
  advanced by the page or the daemon, and whether it travels between devices.
  D needs this only from phase 3; phase 0 uses the browser.
- *A 051 addendum* for the new regions' admitted click paths: owner and
  operator pages admit them, observer pages admit none.

**Beyond the three substrate pieces D needs exactly two things:** the cursor
above, and the context digest per item. It does not need a new transcript
projection or a new session lane. Its cost section, for the owner reading it
as a budget, is therefore: three substrate additions the brief grants, one
small register, and one field on the feed.

## 8. Roles

An **operator** (and the owner on an operator page) sees everything above and
may press. An **observer** sees the *Since* card for the one session their
page is bound to, and the dock shows that session's open items read-only: the
text, the options, the digest, and no buttons, as an observer's page draws no
approval cards today. An observer does not see the queue, because their page
is bound to one session and listing others would show them what they were not
given. This is a deliberate narrowing: the brief says an observer sees counts
and items, and D gives them both for the one session they hold and no more.
A **member** who is an operator on only some sessions sees a queue of the
sessions they hold (050's addendum filters it) and may decide the items they
may decide; a row they cannot decide is drawn without its controls and says
whose it is. **Bob** is an operator on `storage/branch-index-repair`, so he
sees the same approval, with *the owner is viewing* in place of *Bob is
viewing*, and either decision wins by the first commit. Presence on an item
uses the viewers the Session tab already knows, so it is operator-only
(§6, "Multiplayer").

Every deciding control is owner or operator only, the two-press arming holds,
and the card is drawn from the record, never from transcript text.

## 9. Cut list

1. **No inbox page.** There is no route that is "the inbox"; the queue is a
   sidebar region and the dock. A person who wants one page of everything has
   the home page, unchanged.
2. **No review surface.** D does not annotate plans, split a diff into
   sections, or draw the agent's summary per hunk. A review is a summary, a
   number, *Mark reviewed*, and *Open changes*. This is where D concedes to
   a rival that makes the diff the home of the work.
3. **No PR actions until the last phase.** PR state outside project mode is
   absent (§2.11), and a poll of GitHub for the owner's PRs is a project of
   its own. PR #1261 is therefore a row only once that exists. Until then the
   owner learns of it from the project board or the Changes tab.
4. **No peer-message items.** The 13:15 message to `storage/branch-index-repair`
   is not an item; it is context on the approval it bears on, and a row in the
   transcripts it lives in. "Unanswered peer question" is not a state D
   invents (§2.10).
5. **No snooze, no priority edit, no scoring.** Ranking is the three-kind
   rule; the owner cannot reorder, and cannot hide a kind. They can *Dismiss*
   a find, which keeps *Reopen*.
6. **No new push into the session lane.** One daemon feed carries items; a
   page still holds one session lane.
7. **Advisor nudges, proposals and evolution candidates stay where they are.**
   They remain in the Session tab with their badges. Surfacing them as queue
   kinds is possible and is not done, because the brief's four things that
   need a person are the first claim and an extra kind would be an extra
   weight on a calm page.
8. **No agent-written importance.** Only the owner's rule ranks.

## 10. Build phases

**Phase 0: existing signals only.** `phase0.png` is this phase. Four changes,
none of which is substrate:

1. Stop dropping the activity row in the daemon's closure (§1.5), carrying
   `approvals`, `last_message` (at most 280 bytes) and `last_outcome` to the
   page, and extend `wv/sessions.activity_from`.
2. Add `session_view/attention`: classify a row as *Approval waiting* (needs
   you with approvals above zero), *Failed* (needs you with none) or *Probably
   asking* (idle after a completed run, last message ending in a question
   mark), and rank them by the three-kind rule with age omitted, since the
   row carries none.
3. Draw the queue in place of the *Needs you* group, each row showing the
   excerpt under two lines (the screenshot), and the `waiting` badge unchanged.
4. Add `session_view/since` and `view/since`, drawn from the lane's own frames:
   the strand statuses, the last assistant message, the spawn and settle
   rows, the approvals raised and decided. The cursor is `localStorage`.

What the owner gains in phase 0: they see, from any session page, which three
sessions need them and what each last said, and when they open a session it
greets them with what happened. What they do not gain: options, dock
answering (they navigate, then type in the composer as today), the review
and finds, ages for other sessions' rows, and the stopped delegate as a queue
row (it is on its own session's card and Strands tab). The count at 14:20 is
*3 sessions need you* where the scenario says four items, and the honest
reading is that phase 0 is a better sidebar and a first card, not the inbox.

**Phase 1: attention records and the classifier.** The tool family, the
decoder, the strand-scoped store, and `attention` reading records. Asks with
options and a recommendation, finds with severity, tasks with steps. The
dock answers items **of the session on screen**: the coordinator's ask, its
stopped delegate, and in any session the owner navigates to, its finds. The
approval card is unchanged. The 14-press path holds for items *here*; for
other sessions it is a navigation each.

**Phase 2: the daemon feed and the commands.** Items from every session arrive
in the queue with ages, and a press on a row opens the item in this dock.
The approval is decided from here through the daemon command. The queue
badge is the feed's count. This is the phase in which the scenario's count of
14 is reached.

**Phase 3: the review and the seen cursor.** The classifier's *ready to
review* state, *Mark reviewed*, and the cursor moving from the browser to the
principal. **Phase 4: PRs**, a bounded GitHub read for watched PRs, and the
two PR actions, which is the only phase that adds to what D can see rather
than where it shows it.

## 11. Risks, and the cheapest test that would prove the thesis wrong

**The risk the thesis runs.** D bets that a short digest and an answerable
card replace reading. If the owner opens the transcript of the session they
just pressed in more than a third of the cases, then the queue is a better
doorbell and the drag the owner named has not gone away; it has moved one
press later. The cases most likely to fail: an ask that leans on earlier
discussion ("as we discussed"), an approval whose reason is not in the action,
a stopped delegate whose error is not self-explanatory, and every review.

**The cheapest test, before phase 1.** Phase 0 is already enough to run it.
Log, per owner and per day, how often the owner presses a queue row and then,
within a minute, either scrolls the transcript past the card or opens the
Changes tab, against how often they type a reply and move on. The thesis is
wrong if the first count exceeds a third of the second after a working week.
A cheaper still, paper version: take the last ten real questions that
sessions asked the owner, cut each to its 280-byte `last_message` excerpt,
and ask the owner, for each, whether they could have answered from the
excerpt alone. Fewer than seven in ten and the ask record's two-sentence cap
and self-contained options are doing more of the work than the interface is,
which is useful to know before building the tool.

**Other risks.**

- *Heuristic false positives in phase 0.* *Probably asking* trades on a
  question mark. It is labelled as a guess; the risk is that the owner stops
  trusting the word. The remedy is to ship phase 1 soon, not to tune the
  heuristic.
- *Auto-advance under a finger.* The dock mounts the next item while a thumb
  may be near. The rules that hold it: 600 ms disarmed, no focus, a 1.6 s
  receipt in between, and a press never decides an item that was not on screen
  when it armed. A usability test on the phone is the check.
- *Cross-session approval decisions.* Deciding another session's approval
  from here moves a decision from its own gateway to a daemon command. If the
  cost of keeping digest binding intact through it proves higher than
  estimated, the fallback is to leave approvals as a row that navigates, and
  D keeps its design and gives up the in-place decision for that one kind.
- *A calm page with more on it.* With the queue empty and the card caught
  up, the page is A2 exactly; that is the check.

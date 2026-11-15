# Concept D: an attention layer on the page the owner already approved

**Status: a design concept in the attention-inbox bracket, written from
[`03-brief.md`](03-brief.md) under thesis D and revised once after the two
critiques.** The mockup is [`concept-d/mockup.html`](concept-d/mockup.html), a
static page. Add `?theme=dark|light`, `?frame=phone`, `?phase=0` (the first
build phase from existing signals only), `?open=<ap|q2|q1|st|rv|tk>`,
`?unfold=1` (the transcript), `?panel=1` (the right panel), `?drawer=1`
(phone), and `?view=ticket[&stage=check]` (the project ticket page). Every name
and number is the scenario's ([`02-scenario.md`](02-scenario.md)). Fact-sheet
sections are cited as `§n` ([`00-fact-sheet.md`](00-fact-sheet.md)). The last
section, *Revision*, says what the critiques changed and what this note
rejected.

## 1. Thesis

The owner opens the page they know and does not read a transcript. When the
daemon link names no session and something waits on a person, the page binds to
the session of the **top-ranked item**, and the centre column opens in a
*returned* state: a pinned card, "Since you last looked", that says in a dozen
lines what happened in that session and what is asked, then the item itself in
the dock, answerable where it stands. The transcript is one folded bar,
`Transcript · 3 rows since 11:05, read only if you want the reasons`; the right
panel is hidden. What is left is four regions of A2: the top bar, the sidebar,
the card, the dock. In the sidebar, the *Needs you* group that already exists
becomes a queue, one row per session that has something for the owner, with the
kinds as words. The queue is how the owner moves between sessions; the card and
the dock are what they do when they get there. The concept wins on cost, since
phase 0 is a widened daemon reduction and two small `session_view` modules, and
on continuity, since a person who learned A2 learns three additions and loses
nothing. It loses where the work is reading, a diff or an argument, and the
note says where, and how to measure how often (section 11).

## 2. The owner's return

The owner opens the daemon at 14:20 with a link that names no session. The queue
is non-empty, so the page binds to the session of its first row, which is
`storage/branch-index-repair`, because an approval ranks first (section 3).
`desktop-light.png` is that moment.

**What they see, in order.** The menu badge reads `4`. The sidebar's first
region is *Needs you · 4*, subtitled *approvals first, then longest waiting*,
with three rows, each a session and its kinds in words: `storage/branch-index-repair
approval`, `runner/pod-reach ask`, `coord/web-inbox ask · stopped`. Beneath, *Ready to
look at · 2*: `fix/hashline-replay review · 2 finds` and `wp-j/vetting-lint lint
failing · ticket`. In the centre, the card for *this* session:

> **Since you last looked** 11:05 → 14:20 · workspace-write · network off · Bob is viewing
> **Asked of you** 12:58 Approval: a code_mode program wants to run `sqlite3 … integrity_check` with a write grant to `~/.loom`
> **Happened** 13:15 peer runner/pod-reach · main asked: "Does the integrity check need the write grant, or can it run read-only?" Stored, not answered.

Under it the folded transcript bar. In the dock, the approval card, whose
buttons are the ones approvals have today (*Deny* first, *Allow once*, *Allow
for session*), and above it a stepper: *4 need you · 2 to look at*, *Next: ask
from runner/pod-reach ›*.

**What this fixes, and what it does not.** The first screen answers the
owner's ten-second question without a transcript: four things need me, the
first is an approval, it wants a write grant outside the workspace, and a peer
asked whether it needs that grant. The peer message sits on the card because
the card is *this session's* own digest, so it is the same session, adjacent in
time, with no claim of relevance and no pairing by content. It does not fix the
case where the reason for an action is in the agent's reasoning rather than its
action text; there the owner unfolds the bar, one press. And the sidebar is
not where the eye goes first. The card and the dock carry the page. The queue
is the doorbell for the other sessions.

**The presses.** Every deciding control is two presses, the first arming and
naming exactly what will be sent, the second sending. A new card mounts
disarmed for 600 ms and never takes focus, as approval cards do. When a
decision lands, the dock shows a one-line receipt above the next item in rank
order, and the next item appears on that same press, never on a timer. In order:

| Step | Item | Presses | Where |
|---|---|---|---|
| 1 | Approval: *Allow once*, confirm | 2 | this page, the card the session draws itself |
| 2 | `runner/pod-reach` ask: option 1, *Send* | 2 | this dock, from another session |
| 3 | `coord/web-inbox` ask: option 1, *Send* | 2 | this dock |
| 4 | `sub:mockup-b` stopped: *Retry*, confirm | 2 | this dock |
| 5 | `fix/hashline-replay`: *Open changes*, then *Accept*, confirm | 3 | one navigation, then the dock there |
| 6 | the risk find: *Fix it*, confirm | 2 | same card |
| 7 | the idea find: *Dismiss*, confirm | 2 | same card |
| 8 | `wp-j/vetting-lint` ticket: *Open the ticket*, *Retry*, confirm | 3 | one navigation to the ticket page |

That is **18 presses, three screens, two navigations** (`fix/hashline-replay`
and the ticket), against the earlier 14. The difference is honest: the 14 left
out PR #1261 and counted a review accepted without being opened. A review accepted
on trust, with the *Accept without opening the changes* link beside *Open
changes*, saves one press and is labelled for what it is: 17. Asks and finds are
held five seconds with *Undo* before delivery and then receipt where they
landed (*Delivered to main of runner/pod-reach, 14:22*). An approval has no
hold. If Bob decides first, the card turns into a receipt that names him.

**The phone.** `phone.png` is the same first screen at 390 px: the card folds to
one line of counts, the dock holds the approval, and the stepper names the next
item, so one hand can clear the queue without opening the drawer.
`phone-drawer.png` is the drawer, which is the queue at full width. The same 18
presses apply.

## 3. Information architecture

| Region | Status | Holds | Folds |
|---|---|---|---|
| Top bar | A2 | location, connection, ctx and cost, menu badge | none |
| Sidebar, *Needs you* | **new**, replaces today's group | one row per session with an open item, kinds as words | at most five rows, then *N more*; closed rows fold with how they ended |
| Sidebar, *Ready to look at* | **new** | finished sessions and tickets worth a look | absent when empty |
| Sidebar, sessions | A2 | *Working*, *Idle*, *Saved*, minus rows now in the queue | as today |
| Centre, card | **new** | this session's digest since the owner last looked | folds to one line; *Caught up* dismisses |
| Centre, transcript | A2 | the focused strand's timeline | **folded to one bar while the card has something to say** |
| Dock | A2 plus one slot | the current item, then the composer | approvals stay above the composer |
| Right panel | A2 | six tabs | **hidden in the returned state** |

On arrival four regions are visible (bar, sidebar, card, dock), and each has
one job. The returned state is not a mode the owner enters. It is A2's own
collapse rules, which already persist per workspace, applied when there is
something to say: the panel is hidden and the transcript folds to a bar. Press
the bar and the page is exactly A2 again.

**Ranking.** The rule is printed under the heading. An approval comes first,
because it is the one a second person may race and the one that holds a run
open only while an operator is attached (§2.1). The rest are ordered by how long
they have waited. A session's row sits at the rank of its best item. **The age
does not exist today.** `sessions.activity` carries no timestamp, and the
escalation record's `asked` is a count of questions, not a time. Ranking by wait
needs one new field, `waiting_since`, on the activity row: the creation time of
the oldest open record, which for an approval means the escalation record gains
a raised time. Until it lands, ranking is approvals first and then the
catalogue's own order, and the subtitle drops its second half.

**The landing rule.** A link that names a session opens that session, as now.
A link that names none opens the session of the first row when the queue is
non-empty, and the home page otherwise. That is a change to how pages are
minted and needs a 051 addendum; it costs one daemon read at mint.

**What the queue does not count.** `sessions.activity` never reads a saved
session, so an approval parked in one is in no count today and the queue's
"4" could be silently low after a restart. D does not hide that. While the
catalogue holds saved sessions the queue says so in a quiet line under the
rows, *3 saved sessions are not checked*, with the existing resume
affordance, and the fix is in the feed's source of truth (section 7). The first
acceptance test is a daemon restart with an approval pending.

**Where the transcript went.** It did not move. It is the centre of the page,
folded when the card already says what the owner needs, and every line of the
card carries an `Open` or `row ›` marker that unfolds and scrolls to its row,
using the marker-without-handler mechanism (`web-design.md` §3.1) so the
observer's admitted paths do not grow.

## 4. Item anatomy and lifecycle

A queue row is a session name over its kinds, a button whose message is a
daemon-assigned id and never text from the item (§5). The dock card shows a
header (`Ask · runner/pod-reach · main · 11:20 · from another session`), the
body as a text node, the controls, and for an item from another session
`Open runner/pod-reach ›`.

| Kind | Controls | Where it decides |
|---|---|---|
| Approval | *Deny*, *Allow once*, *Allow for session* | **only on its own session's page**, from the card that page draws |
| Ask | one button per option, recommended marked, *Explain*, free text | any page, through the daemon's answer command |
| Stopped | *Retry* | any page, through a resume-strand command (section 7) |
| Review | *Open changes*, *Accept*, with *Accept without opening the changes* beside | any page |
| Risk, idea | *Fix it* / *Do it*, *Dismiss*, *Reply* | any page |
| Ticket | per its stage: *Answer*, *Recheck*, *Retry*, *Stop*, *Close*, *Publish* | the ticket page |

**Approvals do not cross sessions.** The earlier draft asked the daemon to
proxy an approval decision from another session's dock. That is withdrawn. An
approval binds the *full action text* the person saw, the wanted grants and the
register seq (the gateway's `echo_matches`), judged inside the target session's
own hub, and *Allow for session* leaves a standing grant wider than any card.
So an approval from another session is drawn in the dock read-only, with its
content from a per-record read, and a button *Decide in storage/branch-index-repair
›* that opens that session, where its own card decides. That costs one
navigation per approval beyond the first. The landing rule makes the first one
free, because the page opens on the first approval's session.

**Review is not a signature.** The review card shows the agent's summary, the
diff stat, the tests as the agent reported them, and the finds. *Accept* is
absent until *Open changes* has been pressed; beside it is a quieter link,
*Accept without opening the changes*, whose receipt says so. The owner may
accept on trust, and the record shows they did.

**Lifecycle.** An item is open until answered, done, fixed, dismissed or
superseded, and the substrate's records keep how each ended. Closed rows fold
under open ones (`Done`), and the receipt names the strand and the minute.
*Dismiss* keeps *Reopen* for the session. **Undo is a hold, held by the
daemon**, never by the page, so closing the tab neither loses an answer nor
sends it twice; it is a weft timer whose handler checks for a stale fire. It
applies to asks and finds and never to an approval, whose receipt reads *Bound
to the action text you saw* and cannot be recalled. A stale item (Bob decided
the approval, the ask was answered by typing in the transcript) closes itself
and is drawn as a receipt, never as a button that now does nothing. Typing an
answer to the asking strand in the composer closes the record with that text.

**The card's lifecycle.** The card has no deciding controls. Its boundary in
phase 0 is structural: *since your last message*, the last committed owner
message in the lane, which needs no storage. It is a fold over the loaded
window, and when the window does not reach the boundary the card says so
(*older rows not loaded*) and does not pretend to be complete. From phase 3 the
boundary is a cursor, a small per-principal, per-session register the daemon
holds, advanced only by *Caught up*, never by a glance. The earlier idea of a
cursor in the browser is dropped, since it needs a browser-to-server property
channel the observer does not register.

## 5. The coordinator story

A coordinator is a session with delegate strands (`agent_spawn`) and, in project
mode, workers on tickets (§2.5, §2.9). D adds no mechanism to either.

**Delegates** are strands of the coordinator's session. Their items carry the
coordinator's session and the strand, and the queue shows one row per
*session*, so `coord/web-inbox` is one row reading `ask · stopped` however many
delegates it has. The row opens its items one after another. This is the
roll-up that keeps three coordinators readable: forty delegates make one row,
not forty. When the owner is on the coordinator's page its card carries the
roll-up in one line, `3 delegates · mockup-b stopped · mockup-a working ·
fact-sheet settled`, taken from the strand statuses the lane already holds.

**A stuck delegate is invisible to the activity row today.** `needs_you` judges
failure from *main's* last run only, so no poll-only phase can show
`sub:mockup-b` as stopped; it is visible in its own session's Strands tab and
card. For the queue the classifier needs per-strand status, which the feed
carries (section 7). This is why *stopped* is a phase 2 row and not phase 0.

**The coordinator's own ask** is an ask on `main`. A worker's
`project_report(waiting, question)` is an ask with a ticket id; it has no options
today and the daemon writes an empty list (§2.5), so with attention records it
gains options and a recommendation and the ticket's answer box becomes the same
dock card. The project mode section says how tickets themselves draw.

## 6. Mapping to signals

| Item kind | Source (fact sheet) | Status |
|---|---|---|
| Approval row and card, session on screen | §2.1 register, lane | EXISTS |
| Approval, another session: row and count | §1.5 `approvals` | EXISTS as a count; content needs a per-record read |
| Queue ranking by wait | none | **NEW**: `waiting_since` on the activity row and a raised time on the escalation record |
| Ask | §3 | **substrate** (records) |
| Idle session's last message in *Ready to look at* | §1.5 `last_message` | EXISTS on the wire, dropped at `server.gleam:6356`; shown as a quiet excerpt, never as "asking" |
| Stopped session | §1.5 `Failed` | EXISTS |
| Stopped delegate | §2.2, §2.9 | **substrate** (classifier with per-strand status); main-only today |
| Review | §2.11, §1.5 | **substrate** (classifier: run ended, diff non-empty, nothing pending); *reviewed* is a close mark |
| Finds | §3 | **substrate** (records) |
| Ticket per stage: answer, review, blocked, failed | §2.5 | EXISTS, owner only, behind `[project]` |
| Ticket `person/check` and its check result | `project/visible-failures` | EXISTS on a paused branch, not on main |
| Check result `at_ms` as the age of that stage | same | EXISTS there |
| PR #1261 outside project mode | §2.11 | ABSENT |
| Peer message on the card | §2.10 | EXISTS as a lane row of the same session |
| Since card, entries | §6 lane | EXISTS for the session on screen |
| Since card, cursor | none | **NEW** (a register), phase 3 |
| Queue badge | §1.4 | EXISTS |

The scenario's "milestones 3 of 5" is not a goal field (§2.4: milestones are
ABSENT). D shows project tickets ended from the ledger on a coordinator's card
and says so; the storage card carries no such line.

## 7. What changes where

**`session_view`** (portable, R6) gains `attention`, the classifier the brief
assumes, a pure function from a session's state or an activity row to *you*,
*agent*, *blocked*, *ready to review* or *quiet*, and from it to queue entries
and the ranking rule; and `since`, a pure function from the lane's committed
entries and a boundary to the card's rows. Both are property-testable without
processes and both hosts read them. The classifier's inputs are explicit:
per-strand status, the oldest open record's time, and for a finished session
whether its diff is non-empty and nothing is pending.

**`web_view`** draws and decides nothing. `view/sidebar` swaps its *Needs you*
group for the queue and adds *Ready to look at*; `view/since` draws the card;
`view/dock` gains the item slot beside `approvals`; the lane gains the folded
bar. New region paths are added to `component`'s constants with the tree-path
tests, and observer pages draw none of the controls.

**The daemon.** In phase 0 the reduction at `client/daemon/server.gleam:6356-6390`
(`activity_states`, an `@internal pub` function returning `#(id, state)`)
returns a richer `Activity`. That is a type change that runs through every
caller up to `listed_sessions` and the `Transport.sessions` capability, small
but not a one-line edit. Later it hosts the feed and the commands.

**The feed carries identities, kinds, states and a bounded head, never decision
content.** An approval's decision echoes the record's full `action` string, the
wanted grants and the seq, not a digest, and none of that fits the activity
row's 2,400-byte bound. So content comes from a per-record read at a seq, and
that read is what a decide command echoes. Wherever this note says "the action
text", it means that.

**Protocol changes**, each a `protocol-change/NNN.md`, named and not decided:

- *Attention records*: the tool family and store. Must decide the caps (two
  sentences per ask, five options, one recommended), the id scheme and its
  relation to escalation ids, binding to a strand, a transcript anchor (the seq
  a record points at, which every "open at this point" link needs), a routing
  field and the strand's parent chain for the coordinator row, closing by typed
  answer, and the total decoder's rule for unknown words.
- *The attention feed and its answer command*: snapshot-then-delta and a resume
  cursor; byte bounds after 050; coalescing; the role filter (a member sees held
  sessions only); per-strand status, not counts; `waiting_since`; the source of
  truth for saved sessions, a durable catalogue summary (pending approvals,
  oldest open record) written on change and on close; and the commands `answer`,
  `retry-strand`, `dismiss`, `reopen`. **Approvals are explicitly outside it.**
  A cross-session approval decision would be its own proposal, with the three
  rules the gateway's single-writer judgment implies: the role comes from the
  grants table per session, the exact action text and seq are echoed, and *Allow
  for session* is refused from any page not bound to that session. D does not
  depend on it.
- *The seen cursor*: the register, who advances it, and whether it crosses
  devices (phase 3).
- *A 051 addendum*: the landing rule, the new regions' admitted click paths
  (owner and operator admit them, observer admits none), and the marker that
  unfolds the transcript bar.

**Beyond the three substrate pieces D needs:** `waiting_since` and a raised time
on the escalation; per-strand status on the feed; a durable catalogue summary
for saved sessions; a resume-strand command (the board's `CanRetry` is for
tickets, not strands); the seen cursor; and the landing rule at mint. It needs
no new transcript projection and no new lane.

## 8. Roles

An **operator** and the owner on an operator page see everything above and may
press. An **observer** sees the card for the one session their page is bound to
and the dock's items read-only: the text, the options, the action text, and no
buttons, as an observer's page draws no approval cards today. An observer gets
no queue, since their page is bound to one session and listing others would show
what they were not given; they see counts only where the page already has them.
A **member** who is an operator on some sessions sees a queue of the sessions
they hold (050's addendum) and can decide only the items they may; a row they
cannot decide says whose it is. **Bob** is an operator on
`storage/branch-index-repair` and sees the same approval, and either decision
wins by the first commit. *Allow for session* is the owner's alone, as today.
Every deciding control is two presses, drawn from the record and never from
transcript text.

## 9. Cut list

1. **No inbox page.** The queue is a sidebar region; the home page is unchanged.
2. **No review surface.** No plan annotation, no diff split into sections; a
   review is a summary, a stat, the finds and the Changes tab.
3. **No PR state outside project mode.** It is ABSENT (§2.11). PR #1261 is drawn
   because its worker is a project ticket; a loose PR is not.
4. **No peer-message items.** The 13:15 message is a row on its own session's
   card, not an item, and an "unanswered peer question" is not a state.
5. **No snooze, no priority edit, no scoring.** The owner cannot reorder or hide
   a kind. They can *Dismiss* a find.
6. **No cross-session approval decision.** Withdrawn from the earlier draft.
7. **No timed advance and no browser-held cursor.** Both are gone.
8. **No heuristic "probably asking".** A text-ending-in-a-question-mark guess is
   cut; an idle session's last message is an excerpt under *Ready to look at*.
9. **No agent-written importance.** Only the owner's rule ranks.
10. **Advisor nudges, proposals and evolution candidates stay in the Session tab.**

## 10. Build phases

**Phase 0: existing signals only.** `phase0.png` is this phase.

1. Widen `activity_states` to carry `approvals`, `last_message` (at most 280
   bytes) and `last_outcome`, and extend `wv/sessions.activity_from`.
2. `session_view/attention`: classify a row as *approval waiting* (needs you with
   approvals above zero), *failed* (needs you with none) or *quiet*. Ranking is
   approvals first, then the catalogue's order. No ages are claimed.
3. The queue replaces the *Needs you* group, one row per session; a session that
   is idle with a last message appears under *Ready to look at* with a one-line
   excerpt and no kind word.
4. `session_view/since` and `view/since`: the card from the lane's frames, from
   *since your last message*, with *older rows not loaded* when the window is
   short; the folded transcript bar; the landing rule for a link naming no
   session.
5. **Project tickets in the queue** where `[project]` is on: a ticket in a
   `person/*` stage becomes a row, from the board the page already polls every
   five seconds, with the board's own actions (below).

At 14:20 phase 0 shows *Needs you · 1* (the approval), three idle sessions under
*Ready to look at* with their last words, and the card with the peer message.
It does not show the two asks as asks, the stopped delegate, the review or the
finds, or any age. It is a better sidebar, a first card and a first landing, not
the inbox.

**Phase 1: attention records and the classifier.** Asks with options, finds
with severity, tasks. The dock answers items of the session on screen and, by
navigation, others. **Phase 2: the feed and the commands.** Items from every
session with ages (`waiting_since`), per-strand status, the answer, retry and
dismiss commands, and the durable catalogue summary so saved sessions are
counted. This is where the 18-press path is reached. **Phase 3: the review state
and the seen cursor**, and the card's boundary moving to the register.
**Phase 4: loose PRs**, a bounded read of watched PRs, only if the owner wants
them outside project mode.

## 11. Project mode

Project mode is unfinished work this concept completes, not a finished surface
it leans on. #1164 is on `main`; #1167 is paused, with its three branches pushed
and unreviewed, and its web slice was never pushed. D does not depend on the
template question. It needs `project/visible-failures` and nothing else of the
stack.

**Where things live.** A *project* is a workspace-level object and lives where it
does today, the home page's Projects section, owner only. Its **board** is that
section, and its `person/*` tickets are *also* queue rows, so the board is one
view of a set the queue shows another view of. A **ticket page** is the existing
home route, drawn in the same shell: the queue stays in the sidebar, and the
worker's session is one press away (`project.png`). D adds no route for a ticket.
A ticket that needs a person appears in the queue under its worker's session, so
the worker's row reads, for example, `check`.

**Absorbed from #1167's web slice, by phase.**

| Slice item | Phase | How |
|---|---|---|
| Answer a worker's question | 0 | the board's `CanAnswer`; in the dock once options exist (phase 1) |
| Close, stop, retry | 0 | the board's `actions`, two presses each, on the ticket page |
| The ticket's failure | 0 | the ticket's own failure sentence, as text |
| Check result and its output | 2 | from `visible-failures`: the check's sentence and its output (the last 4,000 characters, external text) drawn as one escaped text node in a box of its own |
| Recheck | 2 | `projects.recheck` from that branch, refused for a ticket whose check has not failed |
| Diff | 2 | stat on the page; the diff itself is the worker session's Changes tab, one press away |
| Publish | 3 | the board's `CanPublish`, drawn disabled with the daemon's own refusal sentence (*publishing is off for this project*) while it is off |
| Create a project, post a request | 3 | two small forms in the home Projects section, not in the queue |

**Drawing `person/check`.** On `visible-failures` the host classifies a failed
check as `test` or `environment`, and the engine hands a person only the ones
nobody is handling: an environment failure, a fourth failing head, or a worker
who came back idle at the same commit. That is the stage's own rule: *the check
failed at the head and nobody is handling it*. D draws it as an item whose
header is `Check failed · environment` and whose body is the check's sentence
and the first lines of its output as a text node, with *Recheck* first (the
cause may have been mended), then *Retry*, *Stop*, *Close*. The owner is told
whether the worker was told: a `handling: worker` failure is **not** a
queue item. It is a quiet line in *Ready to look at* (`lint failing · ticket`),
because the scenario's own `wp-j/vetting-lint` is `working`, 3 minutes into a
turn, with the worker told. The failure moves to *Needs you* only when the stage
becomes `person/check`. `project.png` draws the same ticket as it would read in
that stage (exit 127, `gleam: command not found`), and labels it as the variant,
because the scenario's ticket is the other case. The check's `at_ms` is a real
age for that stage, the only age any phase has before `waiting_since`.

PR #1261's two comments from Bob come from the GitHub source (§2.11) and are
drawn only where that source is on; the failing check is the ticket's own check
result. A PR outside project mode stays out (cut 3).

## 12. Risks, and the cheapest test that would prove the thesis wrong

**The risk the thesis runs.** D bets that a short digest and an answerable card
replace reading. If the owner unfolds the transcript bar, or opens the Changes
tab, in more than a third of the cases in which they act on an item, the page is
a better doorbell and the drag has moved one press later. The likeliest
failures: an ask that leans on earlier discussion, an approval whose reason is
not in the action, a stopped delegate whose error is not self-explanatory, and
every review.

**The cheapest test, before phase 1.** Phase 0 is enough. Log, per day, how
often the owner unfolds the transcript bar within a minute of landing, against
how often they act from the card and dock alone. The thesis is wrong if
unfolding exceeds a third of the other after a working week. The paper version:
take the last ten questions sessions asked the owner, cut each to its
280-byte excerpt, and ask whether the owner could have answered from the
excerpt. Fewer than seven in ten and the ask record's two-sentence cap is doing
more of the work than the interface.

**Other risks.** *Landing on a session the owner did not choose.* The landing
rule trades a surprise for the first item; the check is whether the owner ever
presses *Home* first. *The next item arriving on a press.* It mounts disarmed
for 600 ms with no focus, and a press never decides an item that was not on
screen when it armed; the phone is where to test it. *A calm page with more on
it.* With the queue empty and the card caught up, the page is A2 exactly.

## Revision

**What changed.**

1. **Arrival.** The owner lens's decisive finding was that D lands on a
   transcript. The page now binds to the session of the top-ranked item and
   opens in a returned state: the card and the item, the transcript folded to
   one bar, the right panel hidden. Seven regions on first sight became four.
   The peer message now rides the card of the session that received it, which
   also answered the context-digest problem without pairing by content.
2. **Approvals decide only where they live.** The daemon-proxied cross-session
   approval decision, and "Allow for session" on a remote dock card, are
   withdrawn. An approval from another session is read-only with a *Decide in
   …* button; the landing rule makes the first free. Where the note said
   "digest" it now says the full action text, wanted grants and seq.
3. **Review is not a signature.** *Accept* waits for *Open changes*; an unread
   accept is a labelled link.
4. **The sidebar scales.** Rows are per session, kinds as words, capped at five
   with a count, and a coordinator is one row however many delegates it has.
5. **Honest ages, saved sessions, and a stuck delegate.** Ranking by wait needs
   a new `waiting_since`, so phase 0 claims no ages; the stuck delegate is
   invisible to the activity row (main-only failure) and is phase 2; saved
   sessions are not counted today and the queue says so.
6. **No timed advance, no browser cursor, no "probably asking".** The next item
   arrives on the press that closed the last one; the card's boundary is the
   last owner message until a daemon register exists; the heuristic is cut.
7. **A project-mode section**, drawing `person/check` from the paused branch.

**What was rejected, and why.** The owner lens asked that the transcript never be
the first screen; D folds it but does not remove it, because the thesis is an
*attention layer on A2*, and a page with no transcript is a different concept.
The critique also asked for a single-line queue row; a row with the session name
and its kinds needs two short lines to avoid ellipsing the session name at 232 px,
so the row stayed two lines and the count fell by grouping per session. The Loom
lens suggested cutting the card's goal and ticket line; the line stays on a
coordinator's card because it is the only place the project's progress reaches
the owner without a ticket.

**The new press count, like for like.** 18 including the review read and PR #1261,
17 if the review is accepted unread. A's 15 and the earlier 14 are not
comparable: they excluded one or both. Two navigations (`fix/hashline-replay` and
the ticket), versus none before.

**What D now needs beyond the substrate.** `waiting_since` and an escalation
raised time; per-strand status on the feed; a durable catalogue summary so saved
sessions are counted; a resume-strand command; the seen register; the landing
rule at mint; and, from the paused stack, `project/visible-failures` for
`person/check`, its check result and `projects.recheck`.

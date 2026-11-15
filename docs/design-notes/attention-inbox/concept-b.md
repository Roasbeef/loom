# Concept B: the board by who acts next

**Status: a design concept for the attention-inbox bracket, not a
commitment.** The mockup is `concept-b/mockup.html`; open it with
`?theme=dark`, `?theme=light` or `?frame=phone`. Facts are cited from
`00-fact-sheet.md` as "fact sheet §n".

## 1. Thesis

The person looks first at a count and a board. The count is one sentence,
"4 agents need you", and the board under it holds one card per *agent*, a
session or a delegate strand, sorted into bands by whose move it is: **Your
move**, **Blocked**, **Ready to review**, **Working**, **Quiet**. An ask, a
find or an approval is never a row of its own. It is the status line of the
agent that raised it, or a chip on that agent's card, and it is answered on
that card. The unit is the agent because an agent is what the owner is
actually managing: the question "what does `coord/web-inbox` need" has one
answer, and the question "what are all the open items" has an answer that
changes shape every time an agent closes one. The same shape already exists
in two places in Loom. The projects board groups tickets by stages that are
literally "who acts next" (`person/answer`, `person/review`,
`person/blocked`, `person/failed`, fact sheet §2.5), and the session sidebar
groups sessions as Needs you / Working / Idle (fact sheet §1.4). Concept B is
those two surfaces made one: the same five words, applied to every session
and every delegate, on the page the owner lands on.

The hard part of a board of cards is density, so the design is mostly rules
about what a card may *not* show (section 3). The short form is the owner's
bar from A2: a card is a name and one status line.

## 2. The owner's return

It is 14:20. The owner opens the daemon's home page, which is now the board.
The first thing worth reading is the sentence at the top: **4 agents need
you**, and under it one quiet line: "3 to answer, 1 stopped. Read 6 live
sessions at 14:20; 14 saved sessions are not read." The bands below are the
other totals; there is no second row of counters repeating them. The last
clause of that line is a guard, explained in section 7.

Then the bands, in the order of how much they need a person.

**Your move** holds three cards: approvals first, then oldest first.
`storage/branch-index-repair` is an approval. Its face shows the kind and
the tool (`proc.run`), the grant it wants (write to `~/.loom`, network off),
and one context line in the peer colour: at 13:15 `runner/pod-reach` asked
whether the check needs the write grant at all. That line is on the face
because it is the one fact that argues against pressing the obvious button.
The face has no Approve button. Its one button, "Review and decide", opens
the real approval card (section 4), which is where the decision is made.
`runner/pod-reach` has waited three hours; its status line is the question,
and its action row offers the agent's recommendation as a single button, "Use
the scratch tmpfs", plus a quiet "2 other answers". `coord/web-inbox` asked
at 13:40; its card has the same shape and one folded line that says "3
delegates · mockup-b stuck · mockup-a working · fact-sheet settled".

**Blocked** holds `sub:mockup-b`, which stopped on a provider rate limit at
13:52. It is a delegate, so its crumb reads "of coord/web-inbox", and its
only action is Retry. No one is asking the owner a question; the agent
simply cannot move and nothing will move it. That is why it is not in Your
move even though it counts toward the 4.

**Ready to review** holds `fix/hashline-replay`: "+412 −88 across 7 files ·
`make check-core` exit 0, as reported by the agent", and one chip, "1 risk ·
1 idea"; the band header carries the total, "2 finds waiting". **Working** is
two single-line rows, `sub:mockup-a` and `wp-j/vetting-lint`. The second
carries "PR #1261: lint (R11) failing · 2 unresolved comments from Bob" and
one button, "Tell it to fix both". It stays in Working because the move is
the agent's, yet the owner can still act on it. **Quiet** is one folded
line naming `docs/threat-model` and `sub:fact-sheet`.

The presses: every control that decides arms on the first press and sends
on the second, after the 600 ms arming delay of the approval card (fact
sheet §5).

| Item | Presses | What they are |
|---|---|---|
| `runner/pod-reach` question | 2 | the recommended button, then Send |
| `coord/web-inbox` question | 2 | the recommended button, then Send |
| `storage/branch-index-repair` approval | 3 | Review and decide (opens the card), Approve, then Approve again to record |
| `sub:mockup-b` stuck | 2 | Retry, then Send |
| `fix/hashline-replay` review | 3 | Review (opens the card in place), Approve the review, Send |
| Risk find | 2 | Fix it, then Send |
| Idea find | 2 | Dismiss, then Send |
| PR #1261 on `wp-j/vetting-lint` | 2 | Tell it to fix both, then Send |

That is **18 presses on one page**, with no navigation and no transcript
opened, counting PR #1261 and counting the approval at three. The page is about one and a half screens tall at 1440×900 and the
owner scrolls it once. For a question, a find, Retry or the PR nudge the armed state says "Nothing
is sent until you press Send" and names the target; the message is then held
by the daemon for eight seconds with an Undo, and only afterwards does the
receipt read "Delivered to". For an approval the armed state prints the
full recorded action text, the grants and the request seq, and the receipt
says "recorded, no undo" (section 4). Choosing a non-recommended answer costs one press more, to open the card
and see every option with the agent's reason (`open-item.png`).

Eighteen is not small, and the arming rule is why: a flat list could not
lower it either. What the board saves is reading: the owner never opens a
session to learn what the page holds.

**On the phone** (`phone.png`, 390×844) the page is one column: the sentence
and its quiet line, then the Your move cards at full width with 40-px buttons,
then the same bands in the same order. The rail is gone and nothing scrolls
sideways. An open card expands in place, so there is no second screen to go
back from, and the existing `waiting` badge and tab-title count keep working
because the board's count comes from the same function.

## 3. Information architecture

The page has four regions. A **top bar** that already exists. A **left rail**
of 232 px that filters the board by workspace and shows, per workspace, "3
need you"; it also carries the link to saved sessions. A **masthead** that is
the sentence and its one quiet line. And the **board**, at most 780 px wide, the
same measure as the transcript in A2.

Ranking is by band, then one rule per band. Your move puts approvals first,
because an approval parks a call and carries a security consequence, then
oldest first. Blocked and Ready to review are oldest first, Working is
longest-running first, Quiet is most recent first and always folded. Every
"oldest" needs a time no existing signal carries: the activity row has no
timestamp, and an escalation's `asked` is a count of questions, not a time. The
design adds one field, `waiting_since` (the creation time of the oldest open
record or pending escalation), to the row and the feed head in phase 1. Until
then phase 0 draws no ages and orders Your move by kind and then listing
order; the mockup draws the target and says so in its footer.

What folds: Quiet is one line that opens to rows; Working and Your move show
five and then "N more"; a coordinator's delegates fold into one line; finds
fold into one chip. Everything else is in the open state.

The rules that keep a card calm are the substance of this concept.

1. **A card has four lines at most**: a header (name, place, age), one
   status line, at most one *context line*, and one action row. The context
   line exists for a single purpose: to carry a fact on file that argues
   against the obvious button, such as the unanswered peer message on an
   approval. No other card has one. Working and Quiet agents get a row, two
   lines, not a card. The louder the band, the larger the thing, and the
   size falls as need falls.
2. **One status line.** For an ask it is the question. For an approval it is the kind, the tool name and the grants wanted, never the action text. For Blocked it is the cause. For Ready to review it is the
   diff size and the agent-reported test result. For Working it is the
   agent's activity. If the line does not fit it is clipped, never wrapped
   to a second status line; the full text is in the open state.
3. **At most one chip**, and no counter rows. "1 risk · 1 idea" describes the
   agent; the board's totals live in the masthead sentence and the band
   headers, once each, and nowhere else.
4. **An action row has one recommended button.** The agent's recommendation
   is the button; every other answer is behind "N other answers".
5. **No colour carries state alone.** Each band's cards carry the state as a
   word ("Approval", "Stopped", "Done"). Your move has an amber tinted
   background and hairline; Blocked has a pink one; no left bars, no card
   shadows, A2 tokens throughout.

**Where the transcript went.** It is a drill-down at the foot of every open
card ("Open the transcript at this question"), landing on the existing session
page at the seq the record was raised at. The board reads no transcript text
except `last_message`, already on the wire, clipped to 280 bytes, drawn as a
text node.

**The session page's sidebar** stays and calls the same classifier, so the
two surfaces cannot disagree about whose move it is.

## 4. Item anatomy and lifecycle

The board draws agents, so "item" here means the thing hung on an agent. A
card's collapsed form was described above; this section is its open form and
how things end.

**An ask** (question with up to five options, one recommended, or free
text). Collapsed: the question as the status line and the recommendation as
the button. Open: every option with the agent's one-line reason, a free-text
box, "Explain" (which sends a request for more before deciding, as in the
Inbox plugin), the agent's last message as a quote, and the transcript link.
Actions: answer, explain, type a reply. Closes when answered; the card
returns to Working at once with a receipt line ("Fold under open · delivered
to `coord/web-inbox · main` at 14:21 · Undo"), and the record keeps how it
ended.

**A task** (something only a person can do, with steps). The status line is
the task; the open state lists the steps and a "Done" button that arms like any
decision. It closes when marked done or when the agent says so.

**An approval.** The board draws an approval in two steps, because the
decision binds to more than a summary can carry. The *face* shows the kind,
the tool name and the grants wanted, all bounded, which is all the feed head
carries. If an unanswered peer message exists it adds the one context line
described in section 3. The face has no Approve button; "Review and decide"
opens the *real approval card*, drawn from a per-record read, never from the
feed. That card shows the full recorded `action` text in a code block, the
grants wanted, the policy, the request's seq and the peer message in full.
The press echoes exactly what the gateway checks today: the escalation id,
the register seq, the full `action` string the owner was shown, and the
grants, which must be a subset of the record's `wanted` (`gateway.gleam`,
`echo_matches`). The armed state prints that same text ("Approve exactly
this: `proc.run sqlite3 …`, grant write `~/.loom`, network off, request seq
41. Recorded at once; an approval cannot be undone"). A stale seq answers
`stale_approval`. Several operators see the same request; the first decision
wins and the loser's card becomes the winner's receipt. Two consequences are
owned here. First, the page that draws the card is not bound to the target
session, and the only cross-session decide Loom has is `decide_relayed`
(protocol-change/089, 094). Until a decide command routed to the target
session's hub exists, "Review and decide" is a link to that session's own
approval card, which costs one navigation and the same three presses. Second,
an approval is never held and never undone; Undo is not offered on it.

**A find** (risk, bug or idea noticed outside the task) never raises an
agent's band by itself. It is a chip on the card and a row in the open state
with its severity as a word. Actions: Fix it, File issue, Dismiss. A *risk* on
an otherwise Quiet agent lifts it to Ready to review, because a risk on a
folded line is the surface failing; an *idea* never does.

**A review.** Ready to review is a classifier output, not a record: the last
run ended, the working tree differs from its base, nothing is pending
(section 7). The open state shows the agent's summary, the diff size with a
link into Changes, the finds, and "Approve the review" and "Send back". The
armed text says: "Sends 'reviewed, go ahead' to `fix/hashline-replay`.
Nothing is merged by this press." Approving sends that message and sets a
*reviewed* close mark on the strand, which clears the band until a later run
ends with a new diff. Loom has no merge command outside project mode (fact
sheet §0.5, §8); in project mode `person/delivery` and `CanPublish` are the
real delivery and the card shows that button instead. The summary is the
agent's own, and the card says so beside "open the diff".

**A stuck agent.** The word is "Stopped" and the line is the cause: the run
outcome and, when the provider says, the reason. Retry sends the fixed text
"continue", as the owner, to that strand only, and the open state says
exactly that. For a project ticket the same slot holds the ticket's own
`CanRetry`. Two presses, like everything that spends tokens.

**A nudge on a working agent.** `wp-j/vetting-lint` is working while its PR
has a failing check and two review comments. "Tell it to fix both" sends the
agent one owner message naming them, through the held-input queue
(fact sheet §2.12), so it is read when its turn allows.

**Receipts and undo.** Undo is a daemon-side hold: the daemon keeps the
message eight seconds before delivery, the card says "Holding ... sending in
8 s" with an Undo, and Undo before delivery cancels it. After delivery the
receipt reads "Delivered to", which, as with peer messages, proves durable
admission and not that the agent has read it (fact sheet §2.10). There is no
retraction after delivery. The hold never applies to an approval, whose
receipt is "recorded, no undo". A card that was answered leaves its band at
once and returns, with the reason, if the daemon refuses the send.

## 5. The coordinator story

Two things in Loom are coordinators, and the board treats them the same.

A **project-mode project** has a router session, a worker session per
ticket, a ledger, and stages that say who acts next (fact sheet §2.5). On the
board each worker is an agent card and the router is the coordinator. Section
5a says where the project, its board and the ticket page live, and what of
the paused web slice this concept takes.

A **session with delegate strands** (`agent_spawn`, fact sheet §2.9) is a
coordinator too, and this is `coord/web-inbox` in the scenario: its
delegates are `sub:fact-sheet`, `sub:mockup-a` and `sub:mockup-b`. Each
delegate is an agent with its own state and its own card or row.

The nesting rule is the one place the thesis could be read two ways.
**Every agent is one card, in the band of its own move.** A delegate carries
a crumb, "of `coord/web-inbox`", and if it is in a louder band than its
coordinator the coordinator's folded line says so: "3 delegates · mockup-b
stuck · mockup-a working · fact-sheet settled", a disclosure listing each with
a link to its card. When coordinator and delegates share a band the delegates
nest under it as indented rows. Nesting a stuck delegate inside a quieter
coordinator would hide the thing the owner must act on. The cost is that a
family can be spread over three bands; the crumb and roll-up hold it together.

A delegate's ask goes to the owner by default, because a child cannot get an
answer from a parent that is inside `agent_wait` (fact sheet §2.9). Whether a
coordinator may answer small reversible asks itself is a question for its
brief, not the board. The goal line (phase *build*, 3 of 5 milestones, 412k of
1.2M tokens) lives in the coordinator's open state.

## 5a. Project mode

Project mode is on `main` and opt-in; its web slice was never pushed and the
stack that would finish it (#1167) is paused. A critic read the first draft
as inheriting that slice by deleting the Projects section. The answer: **the
board takes only the card-control parts of the slice, one phase at a time, and
deletes nothing until its replacement works.** It takes nothing from the
template, settings or toolchain work, so it does not wait on the template
question.

*Where things live.* A **project** is a coordinator card on the board (its
router session) and a page, `Projects / web-inbox`, which is the same board
module scoped to that project's agents. A **ticket** is an agent card: its
worker session is the agent. The **ticket page** is that card held open at
full width (`project.png`): the stage word, the worker's question with its
answer controls, the diff stat with a link into Changes on the worker's
session, the check result, the failure output as a text node in a code block,
and the buttons. The home Projects section stays exactly as it is through
phases 0 and 1 and is removed only when the project page has shipped, as a
replacement and not before.

*What is absorbed from #1167's web slice, and when.* The board draws only the
buttons a ticket's own `actions` list names (`CanAnswer`, `CanClose`,
`CanRetry`, `CanPublish`, `CanStop`, which decode on `main`, and `CanRecheck`
once the branch below lands), so it invents no project command.

| Slice item | Phase | How |
|---|---|---|
| Answer, Close | 0 | existing, drawn on the ticket's card |
| Retry, Stop, Publish | 1 | buttons from `actions`; Publish greyed when publishing is off |
| Ticket with diff and failure output | 1 | card held open; diff links into Changes; `failure` text drawn |
| Recheck and the check result | 3 | needs `project/visible-failures` |
| Post a request | 2 | one owner command that submits a request to the router, held 8 s with Undo like any send |
| Create a project | 4 | the web form over `loom project init`; owner only; last because it writes to a repo |

*The `person/check` stage.* It comes from the paused `project/visible-failures`
branch and is the "stuck" signal a coordinator most needs. It lands in
**Blocked** as "Check failed", the status line carrying the branch's
classification ("Code, not environment" or the reverse) and a short cause; the
open state shows the command, outcome and the last lines of failure output;
the buttons are those `actions` offers, Recheck first. Before the branch
lands an unknown `person/…` stage already decodes as needing a person
(`project_board.gleam`); the board puts it in Blocked with the raw stage word,
so `main` is never wrong and the branch's arrival changes one decoder arm.
From that branch this concept needs three things: the stage, the
classification and `CanRecheck`; from `warm-template` and `project-settings`,
nothing.

## 6. Mapping to signals

| Item kind drawn | Source (fact sheet) | Status |
|---|---|---|
| Approval face (kind, tool, grants, peer line) | §2.1; head bounded, peer line from §2.10 | EXISTS for the record, PARTIAL for the peer line |
| Approval card with full action text and decide | §2.1, `echo_matches`; cross-session decide is `decide_relayed` only | EXISTS on the session page; NEW beyond substrate to decide from the board |
| Project worker question | §2.5 `question`; `options` always empty today | PARTIAL |
| Session ask, with options and recommendation | §0.1, §3; no tool exists | substrate addition (records) |
| Task for a person | §0.1, §3 | substrate addition (records) |
| Find with severity | §0.1, §3 | substrate addition (records) |
| Band for a session (you, working, quiet) | §1.5 `sessions.activity` words | EXISTS |
| Band for a session (blocked, ready to review) | §1.5, §2.2, §2.11 | substrate addition (classifier) |
| Stuck delegate, failure of a non-main strand | §2.2 per-strand status exists in the lane; `sessions.activity` reads main only | PARTIAL |
| Retry on a stuck strand | owner message to a strand exists as the composer path; a one-press command does not | NEW beyond substrate (small) |
| Ready-to-review band | §2.11 working-tree diff, read by the daemon, is a classifier input | substrate addition (classifier) |
| "Reviewed" close mark | a seen-style mark on the strand, not a record | substrate addition (close mark) |
| Age and "oldest first" | no timestamp on the row; `asked` is a count | NEW beyond substrate (`waiting_since`) |
| Approvals parked in saved sessions | `sessions.activity` never reads saved sessions | NEW beyond substrate (catalogue summary) |
| Ticket card, project page, answer/close | §2.5 | EXISTS |
| Ticket Retry/Stop/Publish, diff, failure | §2.5 `actions`, `failure` | EXISTS on `main`, web slice unbuilt |
| `person/check` and Recheck | paused `project/visible-failures` | NEW beyond substrate (needs that branch) |
| Post a request, create a project | web slice, unbuilt | NEW beyond substrate |
| Delegate roster and settled state | §2.9 `agent_roster`, strand status | PARTIAL |
| Delegate roll-up line | §1.5 `strands` and `working` counts, dropped at `client/daemon/server.gleam:6344` | PARTIAL |
| Status line from the agent's last message | §1.5 `last_message`, dropped at the same closure | PARTIAL |
| PR line and nudge on a plain session (#1261) | §0.5: PR awareness only inside project mode | NEW beyond substrate |
| Peer message as context on an approval | §2.10 `PeerMessage` rows; "unanswered" is not a state | PARTIAL |
| Goal line and milestones ("3 of 5") | §2.4 one objective; milestones §0.6 | PARTIAL; milestones NEW beyond substrate |
| "Bob is viewing" | §6 viewers, operator-only on a session page | PARTIAL |

The cost of this concept beyond the three substrate pieces: `waiting_since`
on the row and feed head; a durable catalogue summary so saved sessions count;
the Retry command; the reviewed close mark; a GitHub poll for plain sessions'
PRs; a decide command routed to the target session; and, for projects, the
three items from `visible-failures` plus two web commands. Goal milestones are
only a line in an open state and can be dropped without touching the board.

## 7. What changes where

**`session_view`** gains the classifier: a pure function from one agent's
state to a band, and a second that takes a set of agents and returns the
bands, their order, the masthead counts and the folds. Its inputs are listed
because the first draft left them implicit: the activity word, per-strand
statuses (not counts), open attention records, `waiting_since`, whether the
last run ended with a working tree that differs from its base, and a project
stage when there is one. Ready to review is the pure rule "run ended, diff
non-empty, nothing pending, not yet marked reviewed". The stage-to-band map
lives here, so `project_board`'s stage words become one input to it, and
`listing.bucket` becomes a caller. Both functions are portable and
property-tested with `statem`.

**`web_view`** gains a `board` module with card, row and masthead views, all
drawn from `session_view` values, and one new region whose path is a
load-bearing constant. Because the number of cards changes, `ui_socket` must
admit a click by region prefix and not by a fixed path, a rule to write once,
which admits nothing for an observer. Cards are keyed by the daemon's session
and strand identities and drawn only as text nodes. The two-press control is
the one `proposals` and `evolution` use, with the approval card's 600 ms
arming delay. The Projects section is kept until the project page replaces it
(section 5a).

**The daemon** gains the feed, a per-record read, the answer command, the
delivery hold (a weft timer, never applied to an approval) and a catalogue
summary. Nothing new runs in the harness VM; a record is inert data.

**The wire** needs three protocol changes, named and not decided here.

- *`protocol-change/NNN` attention feed and per-record read.* The feed
  carries identities, kind, band, `waiting_since`, per-strand state and a
  bounded head (for an approval: tool and grants wanted, never the action
  text). Content comes from a per-record read at a seq. It must decide: the
  unit of subscription given the 24-id ceiling; snapshot, delta and resume;
  role filtering (a member hears only of held sessions; an observer gets
  counts and heads, no decide-capable row, no approval text); coalescing; and
  its relation to the `Escalations` bus topic.
- *`protocol-change/NNN` answering a record, Retry and the reviewed mark.*
  One command family: answer an ask, close a task, dismiss or act on a find,
  retry a strand, mark a review. It binds to the record id and the seq drawn.
  It must decide the stale-record error and the daemon-side hold (eight
  seconds, before delivery, never retraction after it). Approvals are
  explicitly out of it.
- *`protocol-change/NNN` deciding an approval from outside its session.* It
  must decide: a command routed to the target session's hub on its single
  writer, as `decide_relayed` is, that echoes the escalation id, the seq, the
  exact `action` string and the grants, identically to the session page's
  decision; and the owner/operator gating with two presses. Until it exists
  the board links to the session's own card.

**Saved sessions.** `sessions.activity` never reads a saved session, so an
approval parked in one is in no count. The design avoids a silently low "N
need you" in two steps. Always, the masthead line states what was read ("Read
6 live sessions; 14 saved sessions are not read"). With a durable catalogue
summary (pending approvals and the oldest open record, written on change and
close), saved sessions with something pending appear as cards marked "Saved"
with "Resume to decide". The first test of any build is a daemon restart.

## 8. Roles

The **owner** on an operator page presses everything above. An owner on an
observer page (what `loom ui` mints without `--operate`) and an **observer**
see the same bands, counts and status lines and no action rows: a Your move
card says "Waiting on the owner" and its open state "Open as operator to
answer". The gateway refuses an observer's mutation as a second layer.

An **operator on one session**, such as Bob on `storage/branch-index-repair`,
sees the board for the sessions the daemon holds for him and no others (the
rule of the `sessions.activity` addendum). On his board that approval is in
Your move with its face; opening it draws the real card with buttons. He does
not see the aegis cards. When he or the owner decides first the other's card
becomes the receipt "Approved by Bob at 14:23". The two-press pattern and the
600 ms arming apply to everyone, and a card is never focused automatically.
An observer's feed rows carry no approval text at all.

## 9. Cut list

- **No cross-agent flat list of asks.** That is concept A; here six asks on
  six agents are six cards, the cost of the unit being the agent.
- **No bulk answer.** A decision binds to what was drawn; a bulk press does not.
- **No seen, snooze or priority.** The board ranks by band, kind and age;
  its one added mark is "reviewed". No drag, no pin.
- **No card for a PR.** A pull request is a line on its agent, with at most
  one nudge button, never a thing with its own place on the board.
- **No pill row.** The sentence and band headers are the totals, once each.
- **No decide from the feed.** A feed row never carries or echoes approval
  text; the decision is made on a card drawn from a per-record read.
- **No "since you last looked" digest.** The board says what is true now;
  that card is concept D's.
- **No inline diff review.** The card links into Changes; that is concept C.

## 10. Build phases

**Phase 0: the board from existing signals.** No substrate, and the unit is
the *session*: the headline reads "N sessions need you" until per-strand states
travel, because the activity row judges failure from main only and a stuck
delegate is invisible to it. Sessions are classified from the
`sessions.activity` words: `needs_you` with approvals is Your move,
`needs_you` without (a failed main) is Blocked, `working` is Working, `idle`
is Quiet. The daemon stops reducing each row to `#(id, state)` at
`client/daemon/server.gleam:6344`, a type change through `activity_states`,
`listed_sessions` and `Transport.sessions`. The status line is the clipped
`last_message`, except an approval's, which is "Approval pending" with a link
to the session's own card; the roll-up is "3 strands, 1 working". There are no
ages, so Your move orders approvals, failures, then listing order; no Ready to
review band except tickets in `person/review`; no finds, nudge or PR line.
Tickets appear as cards with the answer box and Close that exist today. Even
so, the owner reads "N need you" and why, which today takes opening every
session.

**Phase 1: the classifier, records and the first controls.** The classifier
moves into `session_view` with its full input list, gaining Blocked and Ready
to review; `waiting_since` joins the row, so ages and "oldest first" appear.
Attention records land and cards draw them. The answer command lands, so
asks, finds and Retry are answerable in place with the daemon hold. Approvals
still link to the session's card. Ticket Retry, Stop, Publish and the ticket
page as a held-open card land.

**Phase 2: the feed.** The push replaces the polls, with the per-record read
and the catalogue summary, so saved sessions count. "Post a request" lands.

**Phase 3: delegates, the coordinator and decide.** Per-strand states reach
the classifier, the headline becomes "agents", and the crumb, roll-up and
nesting land, with deciding an approval from the board and, if
`visible-failures` has landed, `person/check` and Recheck.

**Phase 4: PRs, create project and the phone.** PR state for plain sessions
and the nudge, the web "create a project", the phone's touch targets, and the
observer and operator filtering tested end to end.

## 11. Risks and the cheapest test that would prove the thesis wrong

**Risk: the card is a lie when an agent has many things.** The status line
shows one thing; the owner opens the card to see the rest. If most needing
agents have exactly one thing, card and item are the same. If many have three
or more, the board degrades into a list of cards you must open, which is the
transcript drag with a nicer header.

**Risk: the nesting rule spreads a family.** A coordinator with a stuck
delegate and a pending ask has pieces in two bands; the crumb and roll-up
must hold it together, or the owner reads six unrelated agents.

**Risk: density returns by accretion.** Every signal wants a chip. The rules
in section 3 need a view test that fails on a second status line or chip.

**The cheapest test.** It needs no build. Take a week of `sessions.activity`
rows for the owner's real sessions and, for every moment a session was
`needs_you`, count what was open on it: approvals from the register, project
tickets' questions, proposals, held inputs. If the median is one and the
ninetieth percentile is two or fewer, the thesis holds. If the ninetieth
percentile is four or more, the thesis is wrong for this owner and the
unit should be the item. After phase 0 ships, the same question has a
behavioural form: the share of card visits that end in "Open the
transcript". If more than a third of visits open the transcript, the status
line is not enough and the card is too thin.

## Revision

**What changed.** (1) The approval no longer asks for a decision on a summary:
its face shows kind, tool, grants and the peer message as one context line,
and the decision is made on the real card with the full recorded action text,
echoing the action string, grants and seq as the gateway checks them; the
feed carries heads only, and an approval has no hold or Undo. (2) The pill
row is gone; the sentence and band headers are the only totals. (3) The
failing PR has a button, "Tell it to fix both". (4) The Projects section is
not deleted: a project page and a ticket page are added as its replacement,
staged, taking only card-control parts of the paused slice, with `person/check`
in Blocked (section 5a). (5) Ages name their source (`waiting_since`, absent
from phase 0), saved sessions are named in the masthead, Undo is a
daemon-side hold, phase 0's unit is the session, and the harness-written
review record is dropped for a classifier output and a "reviewed" mark.

**Rejected.** Moving the PR into Ready to review: the agent is mid-turn and
the move is its own, and the band would mean two things. Keeping the
Projects section forever: two ticket surfaces would disagree about whose move
it is. A consequence line under every recommended button: it adds a line to
every ask, so the armed state prints the agent's reason instead. A "since you
last looked" card, a flat queue of asks, a staged outbox: concepts D, A, C.

**The press count, like for like: 18**, including PR #1261: two questions at
two each, the approval at three, Retry two, the review three, two finds at two
each, the PR nudge two. The first draft's 15 left out the PR and counted the
approval at two. Until a decide-from-the-board command exists, the
approval's three presses include one navigation.

**Needed beyond the substrate.** `waiting_since`; a catalogue summary for
saved sessions; per-strand state in the feed; the answer and Retry command
family with its hold; the reviewed mark; a decide command routed to the target
session; PR polling for plain sessions; for projects, `person/check`, its
classification and `CanRecheck` from the paused branch, a post-request command
and a create-project form.

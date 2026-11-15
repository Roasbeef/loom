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
about what a card is *not allowed* to show. Section 3 states them. The short
form is the owner's bar from A2: a card is a name and one status line.

## 2. The owner's return

It is 14:20. The owner opens the daemon's home page, which is now the board.
The first thing worth reading is the sentence at the top: **4 agents need
you**. Under it, seven small counters link to the bands: 3 to answer, 1
stuck, 1 to review, 2 finds, 1 PR with a failing check, 2 working, 2 quiet.
These are the scenario's totals, and the owner reads them without scrolling
or opening anything.

Then the bands, in the order of how much they need a person.

**Your move** holds three cards, oldest first. `runner/pod-reach` has waited
three hours; its status line is the question, and its action row offers the
agent's recommended answer as a single button, "Use the scratch tmpfs", plus
a quiet "2 other answers". `coord/web-inbox` asked at 13:40; its card has the
same shape and one extra line, folded, that says "3 delegates · mockup-b
stuck · mockup-a working · fact-sheet settled". `storage/branch-index-repair`
is an approval, and its status line is the whole request in the words the
decision binds to: the `sqlite3` integrity check, the write grant to
`~/.loom`, network off, with "Bob is viewing" beneath it.

**Blocked** holds `sub:mockup-b`, which stopped on a provider rate limit at
13:52. It is a delegate, so its crumb reads "of coord/web-inbox", and its
only action is Retry. No one is asking the owner a question; the agent
simply cannot move and nothing will move it. That is why it is not in Your
move even though it counts toward the 4.

**Ready to review** holds `fix/hashline-replay`: "+412 −88 across 7 files ·
`make check-core` exit 0, as reported by the agent", and one chip, "2 finds ·
1 risk". **Working** is two single-line rows, `sub:mockup-a` and
`wp-j/vetting-lint`; the second carries "PR #1261: lint (R11) failing · 2
unresolved comments from Bob" as its line and is not in a louder band
because the agent that has to fix it is already working. **Quiet** is one
folded line naming `docs/threat-model` and `sub:fact-sheet`.

The presses: every control that decides arms on the first press and sends
on the second, after the 600 ms arming delay of the approval card (fact
sheet §5).

| Item | Presses | What they are |
|---|---|---|
| `runner/pod-reach` question | 2 | the recommended button, then Send |
| `coord/web-inbox` question | 2 | the recommended button, then Send |
| `storage/branch-index-repair` approval | 2 | Approve, then Send |
| `sub:mockup-b` stuck | 2 | Retry, then Send |
| `fix/hashline-replay` review | 3 | Review (opens the card in place), Approve the review, Send |
| Risk find | 2 | Fix it, then Send |
| Idea find | 2 | Dismiss, then Send |

That is **15 presses on one page**, with no navigation and no transcript
opened. The page is about one and a half screens tall at 1440×900 and the
owner scrolls it once. The armed state says what will be sent and to whom
("Press again to send 'Approve' to `storage/branch-index-repair · main` with
write grant to `~/.loom`, network off"), and the receipt that replaces it
says "delivered to" the agent with an eight-second Undo, as the Inbox plugin
does. Choosing a non-recommended answer costs one press more, to open the
card and see every option with the agent's reason for it (`open-item.png`).

Fifteen is not a small number, and the arming rule is why: a flat list
could not lower it either, because deciding controls may not send on one
press. What the board saves is reading: the owner never opens a session to
learn what the page holds.

**On the phone** (`phone.png`, 390×844) the page is one column. The sentence
and a horizontally scrolling row of counters sit at the top; the Your move
cards follow, each full width with a 40-px minimum button height. The bands
are the same and in the same order; the rail and the right-hand space are
gone, nothing is added. The counters are the only thing that scrolls
sideways, and they are redundant with the bands below them. An open card
expands in place, so there is no second screen to go back from. The tab
title and the existing `waiting` badge on the menu button (fact sheet §6)
keep working, because the board's count is computed by the same function.

## 3. Information architecture

The page has four regions. A **top bar** that already exists. A **left rail**
of 232 px that filters the board by workspace and shows, per workspace, "3
need you"; it also carries the link to saved sessions. A **masthead** that is
the sentence and the counters. And the **board**, at most 780 px wide, the
same measure as the transcript in A2.

Ranking is by band, then inside a band by one rule per band, chosen so that
no kind of item outranks another by the classifier's opinion. Your move is
oldest first, because an ask that has waited three hours has cost more than
one that has waited one, and because "oldest first" can be explained in two
words and cannot be argued with. Blocked and Ready to review are also oldest
first. Working is longest-running first. Quiet is most recent first and is
always folded.

What folds: Quiet is a single line that opens to rows. Working shows at most
five rows and then "N more". Your move shows at most five cards and then
"N more waiting, oldest shown first". A coordinator's delegates fold into
one line on the coordinator's card. Finds fold into one chip. Everything
else in an agent's context is in the open state, one press away.

The rules that keep a card calm are the substance of this concept, so they
are stated as rules.

1. **A card has three lines at most**: a header (name, place, age), one
   status line, and one action row. Working and Quiet agents get a row, two
   lines, not a card. The louder the band, the larger the thing, and the
   size falls as need falls.
2. **One status line.** For an ask it is the question. For an approval it is
   the request. For Blocked it is the cause. For Ready to review it is the
   diff size and the agent-reported test result. For Working it is the
   agent's activity. If the line does not fit it is clipped, never wrapped
   to a second status line; the full text is in the open state.
3. **At most one chip.** "2 finds · 1 risk" or "PR #1261 failing", never
   both on a card; the other goes in the open state.
4. **An action row has one recommended button.** The agent's recommendation
   is the button; every other answer is behind "N other answers".
5. **No colour carries state alone.** Each band's cards carry the state as a
   word ("Approval", "Stopped", "Done"). Your move has an amber tinted
   background and hairline; Blocked has a pink one; no left bars, no card
   shadows, A2 tokens throughout.

**Where the transcript went.** It is a drill-down at the foot of every open
card: "Open the transcript at this question". The link goes to the existing
session page, at the sequence the record was raised at, so the owner arrives
at the exact message and not at the bottom of a long scroll. Nothing on the
board reads transcript text except the agent's `last_message`, which is
already on the wire, clipped to 280 bytes, and is drawn as a text node.

**Where the session page's sidebar went.** It stays, and it calls the same
classifier. On a session page the sidebar's groups become the board's bands
in miniature, so the two surfaces cannot disagree about whose move it is.

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
the task; the open state lists the steps with a "Done" button that arms like
any decision. It closes when marked done, or when the agent notices it is
done and says so.

**An approval.** The status line carries exactly what the decision binds to:
the program, the grant and the network posture. The open state adds the
policy, the sentence "the decision binds to this request as drawn; a changed
request asks again", and anything related. For `storage/branch-index-repair`
the related thing is the 13:15 peer message from `runner/pod-reach` asking
whether the check needs the write grant at all, which is the best context
the owner can have for the decision. The press carries the escalation id and
the sequence at which it was drawn, as the approval card does today, and a
stale sequence answers `stale_approval` (fact sheet §5). Several operators
see the same request; the first decision wins, and the loser's card turns
into the winner's receipt.

**A find** (risk, bug or idea noticed outside the task). A find never raises
an agent's band by itself. It is a chip on the agent's card and a row in the
open state, with its severity as a word. Actions: Fix it (sends the agent a
message to take it up), File issue, Dismiss. A *risk* find on an agent that
is otherwise Quiet lifts that agent to Ready to review, because a risk that
sits on a folded line is the surface failing at its job; an *idea* never
does. The masthead counts both kinds.

**A review.** The review is not a record the agent writes. It is the state of
an agent that has finished a run with a non-empty working-tree diff and
nothing pending. The open state shows the agent's summary, the diff size with
a link into the existing Changes view, the finds, and two actions: "Approve
the review" and "Send back". Approving closes the review and sends the agent
the owner's "reviewed, go ahead"; it does not merge anything, because Loom
has no merge command outside project mode (fact sheet §0.5, §8). In project
mode `person/delivery` and `CanPublish` are the real delivery, and the card
shows that button instead.

**A stuck agent.** The word is "Stopped" and the line is the cause: the run
outcome and, when the provider says, the reason. Retry sends the fixed text
"continue", as the owner, to that strand only; the open state says exactly
that. It is two presses like everything that spends tokens.

**Receipts and undo.** Every send ends in "delivered to", which, as with
peer messages, proves durable admission and not that the agent has read it
(fact sheet §2.10). Undo is eight seconds, and it recalls the message only if
the agent has not yet started a turn on it; past that the receipt loses the
Undo button and keeps its text. Answered cards leave the band they were in
immediately, without waiting for the feed to confirm, and come back if the
send fails, with the reason in the same place.

## 5. The coordinator story

Two things in Loom are coordinators, and the board treats them the same.

A **project-mode project** has a router session, a worker session per
ticket, a ledger, and stages that say who acts next (fact sheet §2.5). Its
tickets already carry a stage, a question and a pull request. On the board
each worker is an agent card, the router is the coordinator, and the stage
maps to a band by a pure function: `person/answer` to Your move,
`person/review` and `person/delivery` to Ready to review, `person/blocked`
and `person/failed` to Blocked, `working` to Working, `queued`, `idle` and
`ended/*` to Quiet. The existing Projects section and its answer box are the
degenerate case of this board; they are folded into it rather than kept as a
second surface, and the 5-second project board poll becomes a feed row.

A **session with delegate strands** (`agent_spawn`, fact sheet §2.9) is a
coordinator too, and this is `coord/web-inbox` in the scenario: its
delegates are `sub:fact-sheet`, `sub:mockup-a` and `sub:mockup-b`. Each
delegate is an agent with its own state and its own card or row.

The nesting rule, which is the one place the thesis could be read two ways,
is this. **Every agent is one card, in the band of its own move.** A delegate
is never hidden inside its coordinator. It carries a crumb, "of
`coord/web-inbox`", and, if it is in a louder band than its coordinator, the
coordinator's card says so in its one folded line: "3 delegates · mockup-b
stuck · mockup-a working · fact-sheet settled". The line is a disclosure; the
open state lists the delegates with a link to each one's own card. When a
coordinator and its delegates share a band, the delegates nest under the
coordinator as indented rows. The alternative, nesting a stuck delegate
inside a coordinator that is itself in a quieter band, would hide the thing
the owner has to act on, which is the failure the board exists to prevent.
The cost is that one agent's family can be spread over three bands; the
crumb and the roll-up line are what hold it together.

A delegate's ask goes to the owner by default, because a child cannot get an
answer from a parent that is inside `agent_wait` (the "designed-in hole" in
fact sheet §2.9). Whether a coordinator should be allowed to answer small
reversible asks itself, as Coordinator's decision policy does, is a question
for the coordinator's brief and not for the board; the board only draws the
ask when it reaches the owner. The goal line (ship the attention inbox,
phase *build*, 3 of 5 milestones, 412k of 1.2M tokens) lives in the
coordinator's open state, one line, and not on its card.

## 6. Mapping to signals

| Item kind drawn | Source (fact sheet) | Status |
|---|---|---|
| Approval card | §2.1, escalation register | EXISTS |
| Project worker question | §2.5 `question`; `options` always empty today | PARTIAL |
| Session ask, with options and recommendation | §0.1, §3; no tool exists | substrate addition (records) |
| Task for a person | §0.1, §3 | substrate addition (records) |
| Find with severity | §0.1, §3 | substrate addition (records) |
| Band for a session (you, working, quiet) | §1.5 `sessions.activity` words | EXISTS |
| Band for a session (blocked, ready to review) | §1.5, §2.2, §2.11 | substrate addition (classifier) |
| Stuck delegate, failure of a non-main strand | §2.2 per-strand status exists in the lane; `sessions.activity` reads main only | PARTIAL |
| Retry on a stuck strand | owner message to a strand exists as the composer path; a one-press command does not | NEW beyond substrate (small) |
| Ready-to-review state and "reviewed" close | §2.11 working-tree diff is read by the daemon; no durable mark | NEW beyond substrate (a harness-written record) |
| Delegate roster and settled state | §2.9 `agent_roster`, strand status | PARTIAL |
| Delegate roll-up line | §1.5 `strands` and `working` counts, dropped at `server.gleam:6356` | PARTIAL |
| Status line from the agent's last message | §1.5 `last_message`, dropped at the same closure | PARTIAL |
| Working row | §1.5, §2.2 strand `Working` | EXISTS |
| Project ticket stage as a band | §2.5 stages | EXISTS |
| PR chip on a project ticket | §2.5 `pull_request` | EXISTS |
| PR chip on a plain session (#1261) | §0.5: PR awareness only inside project mode | NEW beyond substrate |
| Peer message as context on an approval | §2.10 `PeerMessage` rows; "unanswered" is not a state | PARTIAL |
| Goal line | §2.4, one objective and a budget | PARTIAL |
| Goal milestones ("3 of 5") | §0.6 | NEW beyond substrate |
| "Bob is viewing" | §6 viewers, operator-only on a session page | PARTIAL |

Three entries need beyond-substrate work and are the cost of this concept:
the Retry command, the harness-written review record, and a GitHub poll for
plain sessions' PRs. Goal milestones are a fourth, but they are only a line
in an open state and can be dropped from the build without touching the
board.

## 7. What changes where

**`session_view`** gains the classifier: a pure function from one session's
state (activity word, per-strand statuses, open attention records, a
non-empty diff, a project stage when there is one) to a band, and a second
function that takes a set of agents and returns the bands, their order, the
masthead counts and the fold decisions. Both are portable and property-tested
with `statem`. The stage-to-band map above lives here, so `project_board`'s
stage words become one input to it and not a parallel vocabulary. The
sidebar's `listing.bucket` becomes a caller of it. This is the substrate's
second addition and the one this concept leans on hardest, because the board
is the classifier made visible.

**`web_view`** gains a `board` module and its card, row and masthead views,
all drawing from `session_view` values, and the home page's region tree gains
one region whose path is a new load-bearing constant. It draws only text
nodes and keys cards by the daemon's session and strand identities. The
two-press control is the one `proposals` and `evolution` already use, with
the 600 ms arming delay of the approval card; the board adds none of its
own logic. The projects section is deleted once the board draws tickets.

**The daemon** gains the feed (substrate three) and the answer path: the
page sends an answer to a record, the daemon checks the owner's role and the
sequence, and delivers it as the owner's message to that strand through the
existing input command. Nothing new is executed in the harness VM; a record
is inert data and its option text is only ever drawn.

**The wire** needs three protocol changes, named and not decided here.

- *`protocol-change/NNN` attention feed.* It must decide: the unit of
  subscription (a principal's whole visible set, or a list of ids, given the
  24-id ceiling of `sessions.activity`); the shape of a snapshot and a delta
  and how a reconnecting page resumes; what a row carries (band, the status
  line's source, counts, a record head) and what it must not (transcript
  text beyond the bounded last message); how role filtering works, so a
  member hears only of held sessions and an observer never receives a
  decide-capable row; coalescing, so a chatty session cannot flood a phone;
  and whether the feed replaces the `Escalations` bus topic or sits on it.
- *`protocol-change/NNN` answering an attention record.* It must decide: the
  command that closes a record from the page, what it binds to (record id and
  the sequence drawn), the stale-record error, how it relates to the
  approval decision's digest, and whether Undo is a retraction message or a
  separate command.
- *`protocol-change/NNN` harness-written records and strand resume.* It must
  decide: whether the harness, not the model, may write a review record when
  a run ends with a diff; its decoder; how it closes; and whether Retry is a
  named command or the composer path with a fixed text.

## 8. Roles

The **owner** on an operator page sees and presses everything above. An
owner on an observer page, which is what `loom ui` mints without `--operate`,
sees the same board, with the same bands, counts and status lines, and no
action rows: a Your move card shows the word "Waiting on the owner" where the
buttons would be and its open state reads "Open as operator to answer". An
**observer** is the same, and the page has no event handler except the ones
that open and fold cards. The gateway refuses a mutation from an observer
binding as a second layer, as today.

An **operator on one session**, such as Bob on `storage/branch-index-repair`,
sees the board for the sessions the daemon holds for him and no others (the
rule of the `sessions.activity` addendum). On his board that approval is in
Your move with buttons; he does not see the aegis cards. When he or the
owner decides first the other's card becomes the receipt "Approved by Bob at
14:23". The two-press pattern and the 600 ms arming apply to everyone, and a
card is never focused automatically, so a keystroke meant for something else
cannot arm it.

## 9. Cut list

- **No cross-agent flat list of asks.** A "show me every open question"
  view is concept A. Here a person with six asks open on six agents scrolls
  past six cards, which is the cost of the unit being the agent.
- **No bulk answer.** There is no "take every recommendation" button. A
  decision binds to what was drawn, and a bulk press does not.
- **No seen, snooze or per-item priority.** The fact sheet lists these as
  absent (§8) and the board ranks by band and age alone. No drag, no pin.
- **No card for a PR.** A pull request is a line on its agent, never a
  thing with its own place on the board.
- **No "since you last looked" digest.** The board says what is true now,
  not what changed. That is concept D's card.
- **No inline diff review.** The review card links into the Changes view
  and does not grow its own reviewer; that belongs to concept C.
- **No coordinator-answers-first policy in the UI.** A delegate's ask goes
  to the owner, and any auto-answering is the coordinator's brief.

## 10. Build phases

**Phase 0: the board from existing signals.** No substrate. The home page
gets the board over what already exists. Sessions are classified from the
`sessions.activity` words: `needs_you` with a non-zero approval count is
Your move, `needs_you` with none (a failed main) is Blocked, `working` is
Working, `idle` is Quiet. Project tickets are classified from their stage
and appear as cards with the answer box that already exists, so the owner's
project questions are answerable on the board from day one. The daemon stops
discarding `last_message`, `strands`, `working`, `approvals` and
`last_outcome` at `client/daemon/server.gleam:6356`, and the card's status
line is the clipped last message, the delegate roll-up is "3 strands, 1
working", and the counters are computed from the same rows. There is no
Ready to review band yet, except for project tickets in `person/review`, and
no finds. Approving is "Open", a link to the session's page, because
deciding from the board waits on the answer path. Even so, the owner opens
the home page and reads "N need you" and the reason for each, which today
takes opening every session. The page still polls (30 s for the list, 5 s
for the activity of the visible rows) and says "updated 14:20".

**Phase 1: the classifier and the records.** The classifier moves into
`session_view` and gains Blocked and Ready to review. Attention records
land (asks, tasks, finds), and cards draw them: the question becomes the
status line, the recommended option becomes the button, finds become the
chip. The answer command and its protocol change land with them, so Your move
is answerable in place for the first time.

**Phase 2: the feed.** The daemon-level push replaces the polls. The page
stops saying "updated" and the masthead counts move as events arrive.

**Phase 3: delegates and the coordinator.** Per-strand states reach the
classifier, so a stuck delegate is an agent in Blocked rather than invisible
to `sessions.activity`. The crumb, the roll-up line and the nesting rule
land. The harness-written review record and Retry land here.

**Phase 4: PRs and the phone.** PR state for plain sessions, the phone's
touch targets and sticky counters, and the observer and operator filtering
tested end to end.

## 11. Risks and the cheapest test that would prove the thesis wrong

**Risk: the card is a lie when an agent has many things.** The status line
shows one thing. An agent with one question, one find and a failing PR is
one card with one line, and the owner will open it to see the rest. If most
needing agents have exactly one thing, the card and the item are the same
and the unit does not matter. If many have three or more, the board hides
what the owner needs, and the design degrades into "a list of cards you must
open", which is the transcript drag again with a nicer header.

**Risk: the nesting rule spreads a family.** A coordinator with a stuck
delegate and a pending ask has pieces in two bands. The crumb and the
roll-up are meant to hold it together, and if they do not the owner will
read the board as six unrelated agents.

**Risk: density returns by accretion.** Every future signal wants a chip.
The rules in section 3 are the defence and need a lint-like test: a view
test that fails if a card draws a second status line or a second chip.

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

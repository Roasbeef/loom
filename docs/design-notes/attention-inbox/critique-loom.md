# Critique, lens 2: does it fit Loom

**Status: one critic's review of the four attention-inbox concepts, through
the single lens of "does it fit Loom".** It judges against `03-brief.md` and
the rubric in `04-critique.md`, and checks the load-bearing claims against the
tree. The owner's-experience lens is judged elsewhere and is not covered here.
Scores run 1 to 5, and 5 is the best fit (for protocol cost and build cost,
5 means cheapest and least contested). The concepts' self-reports are treated
as claims. Where a claim was checked in code, the file is named.

## What was verified in the tree, because several findings rest on it

- `sessions.activity` rows carry `state`, `strands`, `working`, `approvals`,
  `last_outcome`, `model`, `last_message` and `glances`, and **no timestamp of
  any kind** (`peer_mail.gleam` around 1443-1447 and 1685; protocol-change/050).
  Nothing in a row says how long a session has waited. Nor does the escalation
  record: its `asked` field is a **count** of questions put to a human
  (`runtime/escalation.gleam` 176-190), not a time, so no existing signal gives
  the age of a pending approval at all. A first draft of this review assumed
  otherwise; the earlier unmerged redesign note (PR #1158, section 2.1) states
  the same gap correctly.
- `needs_you` is `approvals > 0 || (failed && !main_running)`
  (`peer_mail.gleam` around 1519). The failure half reads **main's** last run
  only. A failed delegate strand is invisible to the activity row, so no
  poll-only phase 0 can show `sub:mockup-b` as stopped.
- The daemon's page-side reduction (`client/daemon/server.gleam:6344-6390`, `activity_states`)
  is an `@internal pub` function returning `#(id, Activity)`. Carrying more
  than the state word widens that return type and every caller up through
  `listed_sessions` and the `Transport.sessions` capability. That is small,
  but it is a type change across `client` and `web_view`, not a one-line
  closure edit.
- An approval decision binds more than "id, seq and digest". The gateway
  compares the **whole `action` string** the human was shown against the
  stored record, checks the echoed grants are a subset of the stored `wanted`
  diff, and compares the register seq (`gateway.gleam`, `echo_matches`,
  `pending_escalation_cell`). "Digest" in the brief and the notes is the
  action text echoed back, not a hash, and it is not bounded by the 2,400-byte
  activity row.
- Cross-session decide exists in exactly one shape today: `gateway.decide` and
  `decide_relayed` (protocol-change/089, 094), judged inside the **target
  session's own hub**, on its single writer, with the spawner's approval
  ceiling. There is no path that lets a page not bound to a session decide a
  local session's approval.
- The project board's `CanRetry` exists for tickets (fact sheet §2.5). A
  one-press retry of a delegate strand does not exist.
- A server component dispatches only events attached in the last render, the
  observer registers no attribute or property channel, and the dock
  "drops every key pressed inside the region of approval cards"
  (`docs/lustre.md` §2 "What the browser can send", §3 "Client components").

## Score table

Questions as numbered in the rubric: Q1 phase 0 honesty, Q2 logic placement,
Q3 roles and consent, Q4 substrate discipline, Q5 protocol cost, Q6
server-component realism, Q7 build cost.

| Q | A: inbox is home | B: board by who acts | C: threads like mail | D: layer on A2 |
|---|---|---|---|---|
| 1 | **2** Sorts and shows waiting time in phase 0 from a row that has no time | **3** Honest that approve is "Open"; "oldest first" and the PR line still need data it lacks | **2** Ranks by wait and says "no protocol change" while adding a page kind | **4** Names its own weakness ("3 sessions", not 4 items); cursor channel and heuristic are the gaps |
| 2 | **4** `attention` model in `session_view`, ranking tested without processes | **5** Stage-to-band map and band ordering in the classifier; sidebar becomes a caller | **3** Right package, but a four-state outbox machine and thread projection is a lot of session logic to own | **3** `attention` and `since` are placed right; the 1.6 s advance and cursor sync are page logic |
| 3 | **4** Approval never decided from a row; batch only for recommended asks; role gating clear | **3** The press carries "escalation id and seq" only, and the status line is a paraphrase | **4** Thread read plus revision is the right binding; one compound send is the worry | **2** Proxy decide from another session's dock, "Allow for session" included, plus auto-advance into the next card |
| 4 | **3** PR observer, milestones, away marker, routing field; all named, two argued | **3** Retry, harness-written review record, PR poll, milestones; flagged and phased | **2** A fourth record kind with sections and line comments, a thread read, a revision rule | **3** Cursor and context digest argued; five feed commands are the real cost |
| 5 | **3** One feed change, one addendum; the answer command folded into the feed | **2** Three protocol documents, one touching harness-written records | **2** Three documents, the review schema the most contested | **2** Records, a feed with five commands, a cursor register and a 051 addendum |
| 6 | **4** Rows, a pane, "Next item"; nothing needs a client component | **4** Expand-in-place cards; optimistic leave is server-side state | **2** Line-anchored comments, staged outbox with drafts, sticky outbox, auto-advance | **3** Dock slot is cheap; a client element with a cursor and a timed advance are not |
| 7 | **3** Phase 0 about 4 PRs, phase 1 about 10 | **3** Phase 0 about 4, phase 1 about 9 | **1** Phase 0 about 5, phase 1 about 12, phase 2 about 10 | **4** Phase 0 about 4 and each later phase is small; phase 2 is the heavy one |

## Concept A: the inbox is the home

**Finding A1, severe.** *Place: section 4 "Receipts and undo", section 10
phase 0.* The phase-0 queue is ranked "longest waiting first" and each row
shows "the waiting time from the activity row". The activity row has no
timestamp. The home view's 30 s and the sidebar's 5 s polls give "since the
page first saw it", which is wrong after a reload and wrong for anything
asked while the page was closed. The rule that the whole concept argues for
(a ranking the owner can predict) cannot be computed until a record carries a
creation time; escalations do not, so approvals need a new field too. *Harm:* the first build either sorts by
something else and breaks its own subtitle, or invents a "first seen"
clock, which is a seen cursor by another name. *Fix:* say so in phase 0.
Rank phase 0 by kind and by session list order, drop the ages, and bring in
"longest waiting first" with the records (phase 1), which can carry a
creation time. Approvals need a time added to the escalation record or the
feed (phase 2).

**Finding A2.** *Place: section 5, rule 1, and section 7 "An addendum to the
record schema".* "A delegate's ask goes to its parent first" is the
coordinator thesis, and it depends on a routing field and on someone
deciding which party sets it. The note says the inbox "is correct under
either" and then draws nothing that depends on it. That is incidental scope
dressed as an open question: a routing field changes who may *answer* a
record, which is a consent matter, not a display matter. *Harm:* records ship
without the field, the first coordinator with forty delegates floods the
owner, and the field arrives later as a schema change to a durable store.
*Fix:* decide in the records proposal that an ask is addressed to
`owner` or to a named strand, defaulting to `owner`, with the strand's
parent chain on the record. Then the classifier can fold a parent-addressed
ask out of the owner's queue with no further rule. A took the cleanest line
on this (the rule is stated), but it must be written into substrate 1 and
not left as an addendum.

**Finding A3.** *Place: section 6 rows "Review, a PR", "Goal line", "Peer
message", "Away since"; section 10 phase 3.* The scenario's PR #1261 and
"3 of 5" are drawn in the mockup but fall in phase 3 or later, and the
"unanswered peer message" derivation is a heuristic: a peer message has no
reply link, so "unanswered" is inferred from what follows it in a
transcript. *Harm:* the default view the owner is shown is one the first
three phases cannot produce, so the screenshot overstates what ships. And
"unanswered" over transcript order is exactly the inference from message
content the brief should refuse. *Fix:* label the mockup's phase-3 rows, and
define "unanswered" structurally or cut it (an ask record, not a peer
message, is the thing that can be unanswered).

What A gets right for Loom: it is the only concept that keeps approvals out of
the row. "Review" opens the existing card, which makes phase 0 safe and keeps
the digest rule intact in phase 2. The `attention` module name avoids the
`session_view/inbox.gleam` collision explicitly. Its "no smart ranking" cut is a
decision a gate can enforce with a property test.

## Concept B: the board by who acts next

**Finding B1, severe.** *Place: section 4 "An approval", section 7 "answering
an attention record".* The approval's status line "carries exactly what the
decision binds to" in words (the `sqlite3` check, the write grant to
`~/.loom`, network off), and the press "carries the escalation id and the
sequence at which it was drawn". The gateway checks the echoed action string
and the wanted-grant subset too, and a paraphrase composed by the page or the
feed is not the action string. If the line is a summary, the human consented
to a summary. If it is the action string, it does not fit the activity row's
2,400 B bound and cannot ride the feed head. *Harm:* the one security
invariant the rubric names ("never binds to something other than the
record's digest and drawn sequence") is weakened by a design choice that
looks like a convenience. *Fix:* the card collapsed shows kind, tool name and
age only and a "Review" press opens the real card from a per-record read;
the decide command echoes `escalation_id`, `seq`, the exact `action` and the
grants, exactly as the session page does today. B's own protocol list asks
"how it relates to the approval decision's digest"; the answer must be
"identically", and the note should say so rather than ask.

**Finding B2.** *Place: sections 6 and 7, the third protocol change.* Three
protocol documents is the highest count among the lighter concepts, and the
third ("harness-written review record and strand resume") lets the harness,
not the model, write an attention record when a run ends with a diff. That is
a new class of writer in a store the brief defined as model-callable and
inert, and "Retry sends the fixed text `continue` as the owner" is a
synthesized owner message on the delegate's strand. *Harm:* a record written
by the harness is not a bad idea (it is the only way "ready to review"
becomes durable), but putting it in the same proposal as Retry mixes a
data-model decision with a command, and the first is contested. *Fix:* split
them. "Ready to review" does not need a record: it is a classifier output
from "run ended, diff non-empty, nothing pending", a pure function in
`session_view`, and the owner's "reviewed" is a seen mark on the strand, not
a record. Then only Retry and the answer command remain, and Retry can reuse
the project board's `CanRetry` shape for strands.

**Finding B3.** *Place: section 5 nesting rule, section 10 phase 3.* Every
agent is a card in its own band, and the stuck delegate shows in Blocked
ahead of a quieter coordinator. That needs per-strand state in the classifier
input, and the activity row has strand **counts**, not states
(`strands`, `working`). B places it in phase 3, correctly, but then
phases 0 to 2 draw a board whose Blocked band can only hold sessions whose
main failed. *Harm:* in phases 0 to 2 the "4 agents need you" headline is
the same wrong number D reports as "3 sessions need you", while the
page's masthead promises agents. *Fix:* state in phase 0 that the unit is the
session, and adopt the agent unit when the per-strand states travel in the
feed. The stage-to-band function B writes for project tickets is the one
piece to start with, because tickets already carry a real stage.

What B gets right for Loom: it is the thesis that is most nearly just the
classifier made visible, which puts the most logic where the repo wants it
(`session_view`) and the least in `web_view`. Folding the Projects section
into the board is a net deletion.

## Concept C: threads you answer like mail

**Finding C1, severe.** *Place: section 6 "What the concept needs beyond the
three substrate pieces", section 7, the review-record proposal.* The thesis
is a review surface, and the review surface is a new record kind carrying an
ordered list of sections, bounded summaries, file paths with line ranges and
a revision, plus annotations (per-line comments, a verdict) attached to a
revision, plus a "thread read" and a "send" that carries a revision. That is
a schema and two commands larger than the three substrate pieces, argued
only as "without it the thread degrades". *Harm:* it is the largest
unreviewed attack surface in the bracket. Section titles and summaries are
model text drawn into a reading pane next to a diff, and the page composes
one message to the owner's agent out of staged verdicts, comments and
instructions. A compound message built from several records is a place where
model-supplied text can reach the owner's voice. *Fix:* ship the thread read
and revision rule (they are good) for asks, approvals and finds, and draw the
review as the worktree file list plus the agent's final message and finds
until the review record is argued on its own with a prototype. Do not add
line annotations to a server component in the same pass (finding C3).

**Finding C2.** *Place: section 10 phase 0 and the opening of section 2.*
Phase 0 is described as "a new bound-to-nothing page kind" with "no new
interfaces and no protocol change", and the owner's return begins "Back at
14:20. Away since 11:05", which needs the feed and a seen cursor. A new page
kind needs its own minted ticket, its own admitted click paths in
`ui_socket` and a 051 addendum, even though Home is a precedent. The "away
since" line is a seen cursor, not an existing signal, and its home is
unspecified. *Harm:* the phase-0 claim is the least honest of the four, and
the note's own cut list ("no seen state") disagrees with its opening line.
*Fix:* either make the inbox a region of Home (which exists, is
bound to no session and is owner-only) and say so, or list the page kind and
its admission as a phase-0 addendum. Drop "away since" until a cursor is
designed.

**Finding C3.** *Place: section 2 "The review", section 4 "Nothing reaches the
agent until you send".* Line-anchored comments, a sticky outbox with staged
items from several threads, drafts held in `localStorage`, "Changed since you
opened it" disabling Send on a feed change, and a pane that advances by
itself after a send. Each of these is a stateful client behaviour. Under a
server component every keystroke in a comment box is a message that runs
`view` and a diff of the whole tree, and a line-number click needs a handler
path per line, which makes the tree large (an opened diff section is
hundreds of attached handlers) and region paths even more load-bearing. The
existing composer is a client component for this reason. *Harm:* either the
design needs a second client component the size of the composer (a diff
annotator with a text-selection model), or it fires input events per
keystroke through the daemon. The auto-advance puts a different card under
the pointer in the position of the Send just pressed, which meets the
"no focus near an approval card" rule at a distance. *Fix:* comments as one
free-text field per section (a handler per section, not per line), anchored
by `(revision, path, line)` data the daemon issued; no auto-advance (the
explicit "Next" press of concept A is enough); drafts stay out until the
composer-style client element exists.

What C gets right for Loom: the **thread read plus revision** is the best
consent mechanism in the bracket. A decision names the revision it was drawn
at, the daemon re-reads, and a stale revision is refused with a word. It is
the same shape as `stale_approval` generalized to every kind, and it answers
the feed-size problem (the feed carries identities, the read carries
content). The "Delivered, not Read" wording is also correct against what the
store proves.

## Concept D: an attention layer on A2

**Finding D1, severe.** *Place: section 7 "The wire", fourth risk in section
11, phase 2.* D asks the daemon to *proxy* approval decisions from another
session's dock and names this "the hard part". It is, and it is the most
security-sensitive request in the bracket. Today a decision is judged inside
the target session's hub on its single writer. A daemon command that decides
from a page not bound to the session must (a) take the principal's role *per
session* from the grants table, not from the page's own binding, (b) carry
the exact action string, wanted grants and seq the human saw, so the feed
must hold or fetch the full action rather than a 2,400 B preview, and (c)
refuse "Allow for session" from any page not bound to that session, because
a remembered grant is wider than "this card". D lists `decide` among five
commands in one proposal and offers "fall back to a navigating row" only as
a risk note. *Harm:* a proxy that gets (a) or (b) wrong lets the home
page decide something the binding would have refused; (c) is not mentioned
at all, and "Allow for session" is drawn on the dock card. *Fix:* take the
fallback as the design. Approvals open the target session (or its card via a
per-record read, as in concept A) and decide there; the proxy is a separate
protocol document with its own review and the three rules above. Everything
else in D, and D's phases 0 and 1, stands without it.

**Finding D2.** *Place: section 6, row "Ask, phase 0 stand-in", and section
10 phase 0 item 2.* "Probably asking" is a classification of a session as
needing the owner when its idle last message ends in a question mark. It lives
in `session_view/attention`, which is where a rule about what a session's
state means belongs, and it is labelled as a guess. It is nevertheless an
inference from model text into the queue's membership: a model, or a document
it was handed, can put a session at the top of the owner's queue by ending a
sentence with a question mark, and a status line that says "Probably" trains
the owner to discount the word. *Harm:* low in damage (it cannot grant
anything) but it is exactly the sort of heuristic the house rules resist, and
it will be hard to remove once the owner has seen it work. *Fix:* acceptable
only as a phase-0 stopgap, ranked *below* every record-backed item, capped by
the 280-byte excerpt, a pure total function with a property test, carrying
an explicit removal condition ("deleted when ask records land"). Better:
cut it, and show an idle session with a recent last message in "Ready to look
at", where the owner reads one line and decides.

**Finding D3.** *Place: section 3 "The session on screen", section 4 "The
since card's lifecycle", section 7 `loom-since`, risk "Auto-advance under a
finger".* Three client-state ideas share one change: a browser cursor in
`localStorage` published to the server element, a card computed from the
lane's committed entries, and a dock that mounts the next item 1.6 s after a
receipt. The cursor needs a property or attribute channel from the browser,
and the observer component registers none. That is a 051 addendum, so
phase 0 is not "no protocol". The card is a fold over the **loaded** lane
window, and after three hours on a busy coordinator the window may not reach
the cursor, so the card is silently incomplete unless it says "older not
loaded". The timed advance can mount an approval card under a pointer.
*Harm:* the card is the continuity feature the thesis is built on and it is
the least reliable; the advance is a consent hazard. *Fix:* the card states
what it could not see when the window is short; the cursor is either a daemon
register from the start (a small one, per principal and session, which D
already designs for phase 3) or phase 0 carries no cursor and the card is
"since the last committed owner message" (a structural boundary in the lane,
needing no storage); drop the timed advance and use an explicit "Next" like
concept A's.

What D gets right for Loom: it is the only concept whose phase 0 changes no
page's region tree except one sidebar group and one card above the transcript,
and whose unchanged parts (the dock, the A2 shell, the observer's admitted
paths) are the parts the security tests already cover. It adds no route. The
"marker-without-handler" scroll-to-row reuses an existing mechanism rather than
adding an admitted path.

## Phase 0 honesty, concept by concept

| Phase-0 claim | Needs |
|---|---|
| A: "waiting time from the activity row", "longest waiting first" | an age the row lacks; falls out to records or a first-seen clock |
| A: project tickets as rows with an answer box | existing, owner-only, behind `[project]`; fine |
| A: approval row text "Approval pending" | existing (`approvals` count); fine |
| A: "Stopped" for a delegate | per-strand state, not in the row; main-only today |
| B: Your move ordered "oldest first" | an age the row lacks |
| B: card status line for an approval | request content is not in the row; the line can only be `last_message` |
| B: "PR #1261: lint (R11) failing" as a Working row's line | PR state outside project mode (absent); drawn in the mockup, not buildable |
| B: "3 strands, 1 working" roll-up | existing counts; fine |
| C: rank by operator-slot then by wait | wait is absent from the row |
| C: new page kind, "no protocol change" | a 051 addendum and a ticket route |
| C: "Away since 11:05" | a seen cursor |
| C: tab-title count on a page bound to no session | `title_rule` extended; small; fine |
| D: queue of 3 sessions with `last_message` | widened `activity_states` return type; honest |
| D: "Probably asking" | a heuristic over model text, in `session_view` |
| D: `since` card with localStorage cursor | a browser-to-server property channel (a 051 addendum) |
| D: ranking "with age omitted" | nothing; honest |

## Anything beyond the three substrate pieces: argued or incidental

- **Seen cursors.** D argues it (continuity) and designs the register; C and A
  mention "away since" in passing. Argued in D, incidental in A and C.
- **Review records.** C argues it as the thesis; B has a harness-written
  variant; A and D use the classifier output only. C's is the most
  contested; B's is avoidable (finding B2).
- **PR observation outside project mode.** A, B, D draw PR #1261 as a
  phase-3 or phase-4 poll of GitHub. None argues it past "the scenario has a
  PR". Every concept needs the same piece, so it should be a substrate
  decision made once (a bounded read for watched PRs, pinned to
  `github.com` as project mode already pins), not four.
- **Goal milestones.** All four draw "3 of 5". Only D says plainly that Loom
  has none and substitutes "tickets ended". The others should do the same or
  cut the line.
- **Context digests.** B, C and D draw the 13:15 peer message on the approval
  it bears on. The *pairing* is the problem: the only structural pairing is
  same session, same strand, adjacent in time. A pairing by content is not
  acceptable. Treat it as a bounded "recent peer messages to this strand"
  list on the per-record read, with no claim of relevance.
- **Delivery holds.** A, B, C, D all add an 8 s, 8 s, 5 s or 5 s hold for
  Undo. A hold is daemon state with a timer (a weft timer whose handler checks
  for a stale fire, per `docs/weft.md`), and it delays delivery. A and D
  place it daemon-side (correct: closing the tab must not lose or double an
  answer); B and C leave it open "client-side or daemon". It must be
  daemon-side, and must not apply to approvals (A and D agree, B and C do not
  say).
- **Routing fields.** Only A names one. Needed by all four for the delegate
  story (see A2).

## Rich client interaction under a server component

C is the only concept whose thesis depends on it (line-anchored comments,
staged drafts, auto-advance). D has one timed behaviour and a client element.
A and B ask for rows that expand and a pane, which is what the Lustre runtime
does cheaply: attach one handler per row carrying a daemon id, keyed by that
id so paths survive a reorder. Two details still apply to everyone. A list of
rows whose count changes means `ui_socket` admits clicks by region prefix and
not by a fixed constant, which is a new admission rule to write once, with
the observer admitting none of it. And the whole tree is re-rendered and
diffed on every message, so a feed that fires per record change on twenty
sessions needs the coalescing every concept mentions and no concept sizes.

## Steal list

| Concept | The one idea a winner should take |
|---|---|
| A | Approvals are never decided from a row; "Review" opens the real card. Plus: the ranking rule is printed in the group's subtitle, and "Next item" is explicit. |
| B | The stage-to-band function in the classifier, with `listing.bucket` and the project board's stages becoming callers of it, so there is one vocabulary of "whose move". |
| C | The thread read with a revision: a decision names the revision it was drawn at and a stale one is refused. It generalizes `stale_approval` to every kind and keeps the feed to identities. |
| D | Phase 0 as a replaced sidebar group plus one card, and the honest "3 sessions need you" statement. Keep the A2 shell and the dock as the answer surface for the session on screen. |

## Ranking

1. **D**, with conditions. It is the cheapest, the most honest about its own
   phase 0, and the only concept that leaves the approved shell and the
   security-tested observer surface alone. Its two defects are separable: take
   the approval-proxy fallback (finding D1) and drop the timed advance and
   the localStorage cursor (finding D3), and what remains is a four-PR first
   step and a small second. It loses on protocol load in phase 2 (five
   commands in one proposal).
2. **A**, close behind. Its security stance is the best (no decision from a
   row, one explicit card), its `attention` module is the right shape, and it
   needs exactly the three substrate pieces plus one routing field. It is
   third on cost only because it replaces the home route and its phase 0
   promises an ordering the row cannot compute (A1). If the owner wants an
   inbox page at all, this is the page to build.
3. **B**. The classifier-first thesis is the one most aligned with the
   repo's logic placement, and folding the Projects section into the board
   deletes code. It ranks third because the agent-as-unit needs per-strand
   state that does not reach `sessions.activity`, because three protocol
   documents are one more than the others, and because the approval line
   weakens the binding (B1).
4. **C**. The thread read with a revision is the best consent mechanism, and
   the outbox's honesty about "Delivered" is right. But its thesis is the
   review surface, which means a new record kind with sections and
   annotations, a client-heavy annotator, and three protocol documents, all
   before the first review thread works. It is a good second project that
   should borrow the revision rule and wait for a review-record proposal.

A hybrid in lens-2 terms: A's page or D's sidebar as the surface; B's
classifier as the substrate; C's thread read and revision as the decide
mechanism; D's phase 0 as the first build.

## Substrate corrections

1. **The feed must not carry decision content.** The brief says approvals bind
   to "the escalation's digest and drawn sequence". In code the binding is the
   full `action` string, the wanted-grant subset and the register seq
   (`gateway.gleam`, `echo_matches`), and none of those fits the 2,400 B row
   bound of `050`. Substrate 3 should say that the feed carries identities,
   kind, state and a bounded head, and that content is fetched by a per-record
   read at a seq, which is the object the decide command echoes. Say
   "action text", not "digest", wherever the binding is described.
2. **The feed needs an answer command, or it is a read-only inbox.** Every
   concept needs a command to answer, decide, dismiss or retry, and the
   brief's substrate 3 names a push only. Three concepts then put the command
   in three different protocol documents. Make the answer command the second
   half of substrate 3, decided once, with approvals explicitly out of it
   until a cross-session decide has its own proposal (see finding D1).
3. **The classifier needs ages and per-strand state.** `sessions.activity`
   has no timestamp and judges failure from main only. "Whose move" without
   "since when" cannot support the ranking rules all four concepts print.
   Substrate 2 should list its inputs, and the row should gain
   `waiting_since` (a time that escalations do not carry today, and the oldest
   open record's creation), and the feed should carry per-strand status rather than counts.
4. **Substrate 1 is missing three fields every concept assumes.** A routing
   field (owner or a named strand), a transcript anchor (a seq the record
   points at, which A's "nearest rows" and every "open at this point" link
   needs), and the strand's parent chain for the coordinator story. Add them
   to the records proposal rather than as per-concept addenda.
5. **Ownership of "ready to review" is unstated.** Concepts disagree on
   whether it is a record (B, C) or a classifier output (A, D). Decide in
   substrate 2: it is a pure function of "run ended, diff non-empty, nothing
   pending" in `session_view`, and "reviewed" is a close mark, not a record
   the model writes.
6. **Role scope of the feed is under-specified.** `sessions.activity` is
   owner-only and members are served through a held-sessions addendum. The
   brief's "across the sessions a principal may see" must say what an observer
   and an owner on an observer page receive: counts and heads, no decide-capable
   row, no approval action text (today's observer page draws no approval cards).
7. **Hold semantics.** Undo is daemon state with a weft timer. State once
   that it is daemon-side, never applies to an approval, and is a hold before
   delivery and not a retraction.
8. **Saved sessions hold pending approvals the feed cannot see.** The earlier
   redesign note (PR #1158, section 2.1) records that `sessions.activity` never
   reads a saved session, so an escalation parked in a session that is saved
   (after a restart, say) is in no count and in no feed built from activity.
   That changes the substrate: the feed's source of truth for "needs a person"
   must include a durable catalogue summary (pending approvals, oldest open
   record) written on change or on close, and the brief should say which. It
   also means the owner's "4 need you" can be silently low after a daemon
   restart, for every concept, and the first test should be a restart. The
   same note's open choice 2 (jump to the card versus decide on the row)
   supports the fallback recommended in finding D1.

## Project mode as the coordinator: what is built, what is paused

The fact sheet and brief call project mode "draft PR #1164". That is stale:
#1164 merged on 2026-11-02 and project mode is on main, opt-in. The remaining
work is tracked in issue #1167, which the owner paused on 2026-11-05 over a
concern that it was over-engineered. Three stacked branches are pushed and
unreviewed (`project/warm-template`, `project/visible-failures`,
`project/project-settings`), and the web-page slice of project mode was never
pushed: the project ticket page with diff, check result and failure output, and
answer, recheck, retry, stop, close and publish, does not exist as reviewed
work. `visible-failures` also adds a `person/check` stage that no concept maps.
The question for each concept is whether its coordinator story survives if
project mode stays opt-in and its web slice must be built as part of this work.

- **A** survives best on the surface it needs: tickets map to Question, Review
  and Stopped rows, and the rail's Projects view keeps today's board, so the
  inbox draws tickets with the existing home section's answer box and owes the
  ticket page nothing. Its coordinator story for plain sessions (a coordinator
  session with delegate strands) does not need project mode at all.
- **D** also survives: tickets are queue rows and the existing Projects section
  stays untouched ("the home section can stay as it is"). Delegates are strands,
  not tickets. It needs no unfinished surface.
- **B** is the most exposed. It folds the Projects section into the board and
  deletes it "once the board draws tickets", and it maps every ticket stage
  (including `person/delivery`) to a band. That makes the board responsible for
  the ticket page that #1167 paused, and for stages `visible-failures` is still
  changing. Fix: keep the Projects section, map only the four `person/*` stages
  that exist on main, and add `person/check` when that branch lands.
- **C** is exposed in the other direction: it draws a `person/review` ticket as
  a review thread "with the ticket's pull request as its subject", which needs
  the ticket page's diff and check output, the paused slice. Fix: a ticket
  thread links to the existing board and shows only its stage, question and PR
  address until the web slice exists.

Credit therefore goes to A and D, which give the ticket a home that already
exists, and a mild penalty to B and C, which would have to build or depend on
the paused slice. This does not change the ranking, and it strengthens the
placement of A and D above B and C.

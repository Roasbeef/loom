# Concept C: threads you answer like mail

**Status: one entry in the attention-inbox bracket, written from
`03-brief.md` under thesis C.** It is a proposal for the owner to compare, not
a commitment. The mockup is `concept-c/mockup.html`; open it with
`?theme=dark`, `?frame=phone`, `?open=hash&demo=staged` (the review with a
reply half-written) or `?open=pod` (an ask).

## 1. Thesis

The person looks first at a list that is the same list every time they come
back: a pinned amber band, **Needs you**, with one row per thread in which an
agent has stopped for a decision; below it, **To review** and **Finds**; and
below those, one folded line each for what is moving and what is quiet. Each
row is a thread, and opening it puts the whole question and the evidence for
it in a reading pane: the approval's exact command and digest, the ask's
options with the recommended one first, the finished session's diff cut into
ordered sections with the agent's own summary above each. Nothing reaches an
agent until the person presses Send, and a send ends in a receipt, "Delivered
to `fix/hashline-replay · main`", so the person can leave the page. The bet is
that the drag the owner named comes from *reconstructing* a question out of a
transcript, and that a thread which arrives already reconstructed, with its
context attached and an answer that can be composed in one place, is cheaper
than any amount of transcript navigation made faster. Mail's weakness is that
reading is not handling; this design therefore breaks the mail metaphor in
exactly one place, which section 3 argues: reading a thread never clears it.

## 2. The owner's return

It is 14:20. The owner opens the page. It is one URL, not bound to a session;
the daemon's attention feed (substrate 3) has told it everything that changed
since the page last held a connection, and the rail says so in its first line:
"Back at 14:20. Away since 11:05, three hours fifteen."

**What they see, in order.** The top bar carries five counts, the first one
amber and the only one that is: *4 need you · 2 to review · 2 finds · 2
working · 2 quiet*. The browser tab reads `(4) Loom inbox`. The list's first
band is amber and sticky, so it stays pinned to the top of the list pane
however far the list scrolls. Under it sit four rows, ranked: the approval on
`storage/branch-index-repair` (1 h 22 m), the ask on `runner/pod-reach`
(3 h 00 m), the coordinator's ask on `coord/web-inbox` (40 m) and the stuck
delegate `sub:mockup-b` (28 m). The ranking rule is stated once and printed
in the band's hint: a parked run that holds an operator slot comes first,
because it is the one whose decision can go stale under someone else's hand
(Bob is on that session); then idle asks by how long they have waited; then
failures. The reading pane has already opened the first thread, so the first
thing on screen is not an empty pane but the question.

**The walk.** The approval thread shows the command, the network setting, the
write grant outside the workspace, the policy in force, and the digest the
decision will bind to. Under the heading "In this thread" it also shows the
13:15 peer message from `runner/pod-reach` asking whether the integrity check
needs the write grant at all, because that message is about this very
approval and a reader who sees only one of the two will answer wrongly. The
owner presses **Deny** (press 1, which stages it and holds what was drawn),
then **Send decision** (press 2; the button is disabled for 600 ms after a
choice, which is the existing arming delay). A five second Undo runs, the
receipt appears, and the pane advances by itself to the next row in the band.

The ask on `pod-reach` is next: the agent's last message, quoted as untrusted
text, three options with option 1 recommended. One press on the option, one on
Send. The coordinator's ask is the same, with the coordinator's goal,
milestones (3 of 5), tokens (412k of 1.2M) and its three delegates drawn
above the options so the question can be answered with the project in view.
The stuck delegate offers two staged messages, "Retry the last step" and "Tell
the coordinator to take it back"; the exact words are printed on the option,
because what the owner is about to put in a strand's mouth must be readable
before it is sent. One press, one Send.

**The review.** The `fix/hashline-replay` thread is the design's main surface
and `open-item.png` shows it. At its head are the stat pills (+412, −88, 7
files, 4 sections) and the agent's claim that `make check-core` exited 0,
labelled as the agent's report rather than a fact the page verified. Next, a
compact card, "Noticed along the way", holds the two finds with their
actions. Below it come the four sections in the order the agent says to read
them, each a one-line header with its own stat and one file count, folded
except the section that carries the behaviour change. An opened section shows
the agent's summary of it in a paragraph, then the hunk. The Risk find is
*pinned in place*, at line 99, the unchanged line that skips an empty digest,
with the agent's note beside it; so the person reading §2 meets the risk at
the line it is about, and not only in a list. A click on a line number
opens a comment on that line. The owner's one comment, "Name the entry's
index in the message too", is drawn under line 100 and joins the outbox. At
the bottom the outbox always says what will be sent and to whom: *To
`fix/hashline-replay · main` · 4 staged: Approve · Fix the risk first ·
Dismiss the idea · Comment 1 on line 100*. Nothing has gone yet.

The owner presses **Approve** (1), **Fix in this branch** on the Risk (2) and
**Dismiss** on the Idea (3), then **Send to main** (4). One message goes to the
agent's main strand carrying the verdict, the comment, the instruction and the
dismissal, which is how Plannotator's annotations travel, and the receipt
reads "Delivered to `fix/hashline-replay · main` · 14:2x". All three records
close together: the review as approved, the Risk as "sent to fix", the Idea as
"dismissed", each keeping how it ended.

**The count.** Eight items in the scenario's own terms (four that need the
owner, the review, the two finds, and no more) clear in **12 presses**: eight
for the four urgent threads (stage, send, each), and four for the review with
both finds. Including PR `#1261`, whose one action "Address all three"
is stage and send, the total is **14**. The owner never leaves the page, so
there is one screen throughout, and none of those presses is a navigation:
after each send the pane advances to the next unhandled thread in rank order.
That figure is the best case in two ways. Taking threads out of rank order
costs one press each, since a row must then be opened; and typing the comment
in the review is not a press. It is also honest to say that the two presses
per ask are the two-press arming rule, not slowness: the first press holds the
words exactly as drawn, the second sends exactly those.

**The phone.** The 390 px layout drops the rail and the reading pane's
second column. It is the list, full height, with the amber band first, so
that all four urgent rows are above the fold of the first screen and need no
scroll. A tap opens a thread over the list with a back arrow; the thread is
the same content in one column, and the outbox is sticky at the bottom of the
screen, with its Send within the thumb's reach. This is Plannotator's point:
the owner sits on the sofa at 14:30, reads the review slowly, comments on two
lines and sends, and the receipt is the evidence it landed.

## 3. Information architecture

The page has three columns and no fourth. The **rail** (200 px) lists folders
with counts; the **list** (388 px) holds threads; the **reading pane** takes
the rest and is the only place that decides anything. The rail's job is
filtering, not navigation: "Everything, by need" is the default and the only
view in which the four urgent rows are guaranteed, and the other folders
(Needs you, To review, Finds, Moving, Quiet, Sent, Closed, and the two
workspaces) are narrowings of it. This is the calm ruling applied: the
default shows eight rows and two folded lines, not twenty-four sessions.

**Rank, and what folds.** The list is grouped by *what each thread needs from
the person*, which is the classifier's answer for its source session or
strand: *you* gives Needs you, *ready to review* gives To review, finds
form their own group, and *agent* and *quiet* fold into one line each at the
bottom ("Moving", "Quiet"), each naming its members in one sentence, so that
the owner can see that nothing is hidden and need not be shown it. A group
header says in four words who is stopped: "agents stopped for you". Folded
lines are not rows; they cannot be selected, they carry no unread mark, and
they exist only so the totals in the top bar can be audited against
something.

**The hardest requirement: urgent items must be impossible to miss in a
medium whose point is reading at your own pace.** Mail fails at this because
mail's urgent and ordinary messages differ only in their sender. Five rules
hold it.

1. *Needs you is a pinned group, not a filter.* It sits first, is sticky at
   the top of the list while the list scrolls, and cannot be folded. The only
   way a row leaves it is to be answered, or for the agent to stop needing the
   person.
2. *Reading is not handling.* A thread has two independent marks. The blue
   dot is mail's: unread. The amber band is need: unsent. Opening a thread
   clears the dot and does nothing to the band. The rail says so in a line of
   its own, "Reading a thread does not clear it", because the mail habit of
   opening and walking away is the very failure to prevent. A row that has
   been read but not answered keeps its hollow dot and its age, and its age
   turns amber and heavy once it passes an hour.
3. *The page opens on the first urgent thread*, not on a blank pane or the
   last thing read. A person who only glances sees a question.
4. *The count lives outside the page.* The tab title, the top bar's amber
   count, and the rail's amber badge all say 4; the first two are visible
   from a different tab, and the existing `waiting` and title mechanisms
   (`wc/title_rule.gleam`) are what carry them, extended from one session to
   the feed.
5. *Other folders keep the band.* If the person narrows the view to Finds
   at 14:25, the top bar still shows the amber count. The count is not part of
   the list, so a filter cannot hide it.

**Where the transcript went.** It is a drill-down from a thread's context,
never a place to read first. The ask thread carries the agent's last message,
quoted as untrusted text, and a single link, "Open the transcript at this
point", which opens the session page at the message the quote came from. The
review carries the diff and the agent's summary, which replace the
transcript for the question "was this done well". For an approval the
transcript is not offered at all, since the record, not the text around it,
is what the decision binds to. The measure of the design is how seldom that
link is pressed.

## 4. Item anatomy and lifecycle

**A row** is two lines in a 388 px pane: the session name (bold while unread)
and the time it has waited; then a kind chip (*Approval*, *Ask*, *Stuck*,
*Review*, *PR*, *Risk*, *Idea*) and a one-line subject cut by the page, not
by the agent. No colour bar and no shadow: the selected row takes the raised
background and a hairline border, and the amber band's tint is a background
on the group header only. The chip pairs a word with a tint, so colour never
carries state alone.

**A thread** has one shape for every kind: an eyebrow (kind, session, strand,
workspace, since when), a title that is the question in the agent's words
(drawn as text, never as markup), then *what it asks for or shows*, then *in
this thread* (related items: the peer message on the approval, the delegates on
the coordinator's ask, the finds on the review), then *your response*, and a
sticky **outbox** that is always visible. The outbox has exactly three states:
*not sent* (names the staged items and the destination), *sending*, with an
Undo for five seconds, and *delivered*, which carries the receipt.

**Actions per kind.**

| Kind | Staged by | Sent with | Closes as |
|---|---|---|---|
| Approval | Deny (first), Allow once, Allow for this session (owner's page only) | Send decision, bound to escalation id, seq and digest | approved, rejected, consumed |
| Ask | an option (recommended first), or free text, or Explain | Send answer | answered, with the option's text |
| Stuck | a drafted nudge, text shown in full | Send | sent, then the strand's own state takes over |
| Review | Approve, Request changes, per-line comments, per-find actions | Send to main | approved, changes requested |
| Find | Fix in this branch, File issue, Dismiss (Idea: Dismiss) | rides the thread's send, or its own | fixed, filed, dismissed |
| PR | Address all, or per blocker | Send | follows GitHub: a fix button disappears when the blocker does |

**Receipts and what they claim.** "Delivered" means what the store says it
means: the message was admitted durably to the target strand, which is exactly
what the existing peer receipt proves (`async-collaboration.md`, "Peers have
separate authority"). It does not mean the agent has read it. The page says
*Delivered*, never *Read* or *Received by the agent*, and when the target is
mid-turn it says *Queued behind the current turn*, which is what a held input
is. An approval's receipt is stronger and says so: it names the decision, the
seq and the digest it bound to, since the gateway checked them.

**Undo.** A five-second hold between Send and the wire, shown in the outbox,
lets a person recall a message. It is a hold, not a retraction: after the
window the send is final, and the page then says "Delivered".

**Nothing reaches the agent until you send** has a cost that must be stated:
a staged reply that sits overnight is stale, and a staged approval is the
hazard. The page therefore keeps drafts only in the browser's local storage as
per-viewer convenience; and when the feed says a thread's subject has changed
(the agent edited a plan it had sent, an approval's digest moved, the delegate
retried on its own), the outbox shows *Changed since you opened it* and
disables Send until the pane is redrawn. This is Plannotator's rule, that the
inbox opens the version that was sent, and it is Loom's rule, that consent
binds what was shown.

**Closure** keeps the row where it was, struck through, with its receipt line
in place of its subject, and moves it to *Closed* on the next visit; the
folding is Inbox's, and it keeps context at no cost.

## 5. The coordinator story

The coordinator is project mode and sub-agent strands; this concept adds no
third mechanism. A coordinator's delegates are strands (`sub:*`) or, in
project mode, worker sessions per ticket. A delegate's ask, failure or
finished work becomes an attention record on that strand, and the feed carries
it to the page with the strand's parent chain attached. The page then does two
things with that chain.

First, each delegate item is a thread in its own right, in the same list,
ranked with every other, with its parent named in the eyebrow (`sub:mockup-b ·
under coord/web-inbox`). The owner can answer a delegate without opening the
coordinator, which is the point of the surface. Second, the coordinator's own
thread carries its delegates: the ask at 13:40 shows the coordinator's goal,
milestones and tokens (project mode's ledger and, once built, the goal's
milestones), and a three-line table of its delegates, the stuck one linked to
its own thread. That is the one place the page draws a parent and its
children together, and it draws them as context for a question, never as a
board.

Two rules keep this from becoming a fleet view. A delegate that is working or
settled does not appear in the list at all, only on the coordinator's thread
and in the folded lines; and when the coordinator has received a delegate's
question and will ask the person itself, the person sees only the coordinator's
ask. That is Coordinator's decision policy: small, reversible choices stay
below, and what changes what gets built, costs money or is a matter of taste
reaches the person.

For project mode the mapping is direct, since a ticket's stage already says
whose move it is: `person/answer` is an ask thread, `person/review` a review
thread with the ticket's pull request as its subject, `person/blocked` a stuck
thread and `person/failed` a failed thread. The board that exists today
(`wv/view/projects.gleam`) remains the project's own page; the inbox draws the
same tickets as threads so the person need not visit it.

## 6. Mapping to signals

| Item kind | Source (fact sheet) | Status |
|---|---|---|
| Approval thread | §2.1 escalation register, digest-bound card | EXISTS per session; **a cross-session read of its content is new** (only a count crosses sessions today, §4 item 3) |
| Peer message in an approval thread | §2.10 `PeerMessage` row, `origin_checked` | PARTIAL: stored text; "unanswered" is derived by the page's classifier, and the pairing with an approval is new |
| Ask (options, recommended) | §3, §8 | substrate addition (attention records); the project worker's `options` field exists but is always empty (§2.5) |
| Ask free-text reply, Explain | §2.5 answer box; held inputs §2.12 | EXISTS (a message to a strand) |
| Stuck delegate | §2.2 strand `Failed`/`Waiting`, §2.9 | PARTIAL: status exists; no rate-limit or "has not retried" signal (§2.2); classifier addition |
| Stuck nudge ("Retry the last step") | §2.12, `agent_send` | EXISTS as a message; **"Resume" as a command is not assumed** |
| Coordinator context (goal, tokens) | §2.4 goal, §2.5 ledger | PARTIAL: one objective and a budget exist; **milestones are ABSENT** (§2.4), so "3 of 5" needs project mode's ledger or a goal field |
| Delegate table | §2.9 `agent_roster`, strands tab | PARTIAL |
| Review thread (diff, files, stats) | §2.11 worktree read | PARTIAL: working tree and commits exist for owner and operator only (not observers); **ordered sections and per-section summaries are NEW** |
| Agent summary and "tests green" | agent's final message; goal check §2.4 | PARTIAL: the final text exists; a structured summary per section is a new field on a review record |
| Line comments, verdict | none | NEW beyond substrate (a review record that accepts annotations as inert data) |
| Find: Risk, Idea | §3 | substrate addition (attention records, kind *find*) |
| PR thread | §2.5, §2.11 | PARTIAL: project mode only; CI and review state are ABSENT as data outside it |
| Receipts | §2.10 peer receipt; approval seq | EXISTS (durable admission); "queued behind the turn" is derived |
| Needs-you ranking, band | §1.4, §6; classifier | substrate addition (classifier) |
| Folded Moving and Quiet lines | `sessions.activity` words | EXISTS |
| Tab title and count | `wc/title_rule.gleam` | EXISTS for one session; the feed extends it |

**What the concept needs beyond the three substrate pieces.** One thing: a
**review record**, a fourth attention kind next to ask, task and find. It is
inert data with a total decoder, written by the agent when it finishes and
carrying an ordered list of sections, each with a title, a bounded summary, and
file paths with line ranges, and referring to the diff by revision and not by
copy. The diff itself is read from the worktree on demand, as the Changes tab
does today. The cost is stated in section 7; without the record, the review
thread degrades to the worktree's file list plus the agent's last message,
which is still better than the transcript but is not the thesis.

## 7. What changes where

**`session_view`** gains the attention classifier (pure; *you, agent, blocked,
ready to review, quiet*) and a thread projection, `thread.gleam`: from a
record and its related records to the eyebrow, the title, the sections and the
outbox's state. The outbox state machine, *not sent, sending, delivered,
changed since opened*, is a pure function here, so the terminal can read the
same answer, in the portable subset (R6): no `@external`, no process. The
rank rule is also here, one function, so both hosts rank identically.

**`web_view`** gains `inbox_page.gleam` (a new page kind, bound to no
session, beside Home), with the list, the reading pane and the outbox as three
regions at fixed tree paths. Because a region's path is load-bearing, the click
paths for staging, sending and undo are added to `ui_socket`'s admitted set
for owner and operator pages only and, as for every deciding control, to no
observer path. Staged text is held in the page's own state and sent as one
command; no handler is built from session content.

**Daemon.** The attention feed (substrate 3), plus two things it implies: a
*thread read* that returns one record with its related records and its digest,
so the page does not assemble context from per-session lanes, and a *send*
command that takes a thread id, the revision the thread was drawn at and the
staged items, and returns a receipt. The send's revision is the page's proof
that it is answering what it showed.

**Wire and protocol changes.**

- `protocol-change/NNN-attention-feed.md` (substrate 3). It must decide: the
  subscription's scope and per-principal filtering (a member sees held
  sessions only); whether it carries records or only a "this thread changed"
  hint with a read behind it; resumption after a gap (a cursor, or a full
  re-read); the maximum rate and row bounds beside the 2,400 B per row in
  `050`; and how an observer's view of an approval is redacted.
- `protocol-change/NNN-thread-send.md`. It must decide: the send command's
  shape (one message carrying a verdict, comments and per-find actions, or
  several commands under one receipt); what "delivered" is allowed to claim;
  the stale-revision refusal and its error word; and the undo hold, either
  client-side or a short-lived pending state on the daemon.
- `protocol-change/NNN-review-record.md`. It must decide: the section schema
  and its bounds; whether a revision of a review is a new record or a version
  of one; and how comments are bounded and attached to a revision rather than
  to text.

These are three documents because they have three different owners and
lifetimes; a reader of the feed protocol need not decide how comments are
stored.

## 8. Roles

An **operator or owner** sees everything above: staging controls, the outbox
and its Send, Undo. "Allow for this session" is drawn on the owner's page only,
as `approval.rememberable` has it today. Every deciding control uses the
two-press pattern: the first press stages and holds what was drawn, and the
second, on Send, sends exactly that; the approval's Send also waits 600 ms and
never takes focus, and Enter never sends.

An **observer** sees the same list, the same counts and the same threads for
the sessions they hold, and none of the three things that act: no staging
buttons, no outbox, no comment affordance. Where an operator's page has the
outbox, the observer's has one line: "An owner or operator decides this."
Approval content is redacted for an observer to the tool name and the fact
that a decision is pending, because today's observer page draws no approval
cards at all and this concept does not widen that; an observer reads a review
in full, since the Changes tab's worktree read is the one that is withheld
from observers, and this is stated as a dependency rather than glossed (§2.11:
the worktree read is owner and operator only), so an observer's review thread
shows the agent's summaries and stats but not the hunks until that ruling
changes. Bob, an operator on `storage/branch-index-repair`, sees the same
approval and the same band; when either of them decides, the other's thread
becomes *Decided by Bob, 14:23* and its outbox goes quiet, because the first
decision wins.

## 9. Cut list

1. **No unified timeline or "since you last looked" digest of everything.**
   The inbox lists what is asked, not what happened; the Moving and Quiet
   lines carry the rest in one sentence each.
2. **No plan or prototype documents in the first build.** The thesis names
   plans annotated in place, and the review's annotation machinery is that
   machinery; but Loom has no plan-submission tool in the tree, and a plan
   thread is cut until a tool exists to produce one.
3. **No bulk actions.** No "approve all", no select-many and no keyboard-only
   mass answer. Two presses per thread is the price of each decision having
   been seen.
4. **No snooze, no assignment, no reordering by hand.** Rank is a function
   of need and age. A thread the owner is not ready for stays where it is and
   stays amber.
5. **No transcript preview in the list or the pane.** A thread has one quoted
   message and a link. A reading surface that included the transcript would
   rebuild the drag it exists to remove.
6. **No read receipts and no typing indicators from agents.** "Delivered" is
   all the store can prove.
7. **No merge button.** A PR thread can send a fix to the session; merging
   stays in GitHub or project mode, whose ticket stage owns it.

## 10. Build phases

**Phase 0, existing signals only.** The inbox page exists and is built from
what is on the wire today: a new bound-to-nothing page kind that polls
`sessions.activity` (five seconds, 24 sessions) and reads, for owner pages,
the project board. It already shows the amber **Needs you** band, because
today's word *needs you* (a pending escalation, or main failed while idle) is
the classifier's seed; it already shows the rank, the folded Moving and Quiet
lines, the tab count, and a thread for each row with the data the row already
has: `last_message` (the 280 bytes the page throws away today, §0 item 2),
the approval count, the `last_outcome`. Approval content is not available
across sessions, so an approval thread in phase 0 opens as a row with the
session link and "Decide in the session", which is today's behaviour with a
better front door; project tickets already carry a real answer box and so are
fully answerable in place. The value delivered is that the owner reads one
list of eight things rather than opening six sessions, and every thread's
context is the agent's own last message instead of a scroll. No new
interfaces and no protocol change.

**Phase 1, the substrate.** Attention records (ask, task, find) with their
decoders; the classifier in `session_view`; the feed with its protocol change.
The list stops polling. Asks and finds become real threads with options and a
recommendation. The outbox, staging, Send and the receipt arrive with the
thread-send change, so every ask and every approval is answerable in place.

**Phase 2, the review surface.** The review record, section rendering with
agent summaries, line comments, the verdict, and the revision rule (open the
version that was sent). The review row moves from "worktree files and the last
message" to the full thread. This is the phase that carries the thesis; it is
third because it is the largest new schema and because phases 0 and 1 already
clear six of the eight scenario items.

**Phase 3.** Project-mode and strand parentage in the eyebrow and the
coordinator's context card; PR threads for project tickets; drafts and
reconnect hardening on the phone; then plans, if a plan tool has appeared.

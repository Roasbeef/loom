# Concept C: threads you answer like mail

**Status: one entry in the attention-inbox bracket, written from
`03-brief.md` under thesis C and revised once after the two critiques.** It is
a proposal for the owner to compare, not a commitment. The mockup is
`concept-c/mockup.html`; open it with `?theme=dark`, `?frame=phone`,
`?open=hash&demo=staged` (the review with a reply half-written), `?open=pod`
(an ask) or `?view=projects&open=pr` (a project ticket). The last section,
*Revision*, says what the second pass changed.

## 1. Thesis

The person looks first at one list that is the same list every time they come
back: a pinned amber band, **Needs you**, with one row per thread in which an
agent has stopped for a decision; below it, **To review** and **Finds**; and
below those, one folded line each for what is moving and what is quiet. Each
row is a thread, and opening it puts the whole question and the evidence for
it in a reading pane: the approval's exact command and the grant it wants, the
ask's options with the recommended one first, a finished session's diff with
the agent's own last message above it, a project ticket's check output beside
its diff. Nothing reaches an agent until the person presses Send, and a send
ends in a receipt, "Delivered to `fix/hashline-replay · main`", so the person
can leave the page. The bet is that the drag the owner named comes from
*reconstructing* a question out of a transcript, and that a thread which
arrives already reconstructed, with its context attached and an answer that
can be composed in one place, is cheaper than any amount of transcript
navigation made faster. Mail's weakness is that reading is not handling; the
design therefore breaks the mail metaphor in one place, which section 3
argues: reading a thread never clears it.

## 2. The owner's return

It is 14:20. The owner opens the inbox. It is a region of Home, which is bound
to no session, so the page needs no session ticket; section 10 explains why
that choice is the honest phase 0. The rail's first line says "Back at 14:20.
Last seen 11:05." That line is the one thing in the first screen that needs a
seen cursor, and phase 0 does not draw it (section 10).

**What they see, in order.** The top bar carries one count, amber: *4 need
you*. The browser tab reads `(4) Loom inbox`. The list's first band is amber
and sticky, so it stays pinned to the top of the list pane however far the list
scrolls. Under it sit four rows, ranked: the approval on
`storage/branch-index-repair` (1 h 22 m), the ask on `runner/pod-reach`
(3 h 00 m), the coordinator's ask on `coord/web-inbox` (40 m) and the stuck
delegate `sub:mockup-b` (28 m). The ranking rule is printed once, in the
band's hint, and it has two parts: a parked run holding an operator slot
comes first, because its decision can go stale under someone else's hand (Bob
is on that session); then idle asks and failures by how long they have waited.
The second part needs a time that no signal carries today, and section 7 names
the field. The reading pane has already opened the first thread, so the first
thing on screen is a question and not an empty pane. The pane is drawn quietly
on purpose: one neutral card and one row of buttons, no coloured box, so the
eye returns to the list.

**The walk.** The approval thread shows the command, the network setting, the
write grant outside the workspace, the policy in force, and what the decision
binds to: the full action text as shown, the wanted grant and the register
seq, which is what the gateway compares (`echo_matches`). Under "In this
thread" it also lists the 13:15 peer message from `runner/pod-reach`, because
the daemon returns, with an approval, the recent peer messages sent to that
strand; the page makes no claim that the message is relevant, but the reader
sees it, and here it is: it asks whether the check needs the write grant at
all. The owner presses **Deny** (press 1, which stages it and holds what was
drawn) and then **Send decision** (press 2; the button is disabled for 600 ms
after a choice, the existing arming delay). A decision has no undo and no hold:
it is delivered at once and the receipt names the seq it bound to. Because an
approval must never move the page under the pointer, the pane stays put and
offers **Next thread** as a third, explicit press.

The ask on `pod-reach` is next: the agent's last message, quoted as untrusted
text, and three options with option 1 recommended. One press on the option,
then **Send & next**, whose label names its consequence: the answer is held
five seconds on the daemon, the pane opens the next thread, and the row shows
"Sending, held 5 s" with Undo until it becomes "Delivered 14:2x". The
coordinator's ask is the same, with the coordinator's goal, token use and its
three delegates drawn above the options. The stuck delegate offers two staged
messages whose exact words are printed on the option, because what the owner is
about to put in a strand's mouth must be readable before it is sent.

**The review.** `fix/hashline-replay` is the design's showpiece and
`open-item.png` shows it. At the head are the stat pills (+412, −88, 7 files),
the agent's claim that `make check-core` exited 0, labelled as the agent's
report and not a fact the page verified, and the agent's last message, quoted.
**Approve** sits directly under them, above every long read, so reading the
diff is a choice and not a toll. Next, "Noticed along the way" holds the two
finds with their actions. Then come the seven files, ordered source, then
tests, then docs, by a rule that is a pure function of the paths. The one file
that carries the behaviour change is open: its hunk, with the Risk find marked
at the unchanged line 99 that skips an empty digest, so the owner meets the
risk at the line it is about. Under the hunk is one comment field for the
file. The owner's comment, "Name the entry index in the error message too", is
typed there and joins the outbox. The outbox always says what will be sent and
to whom: *To `fix/hashline-replay · main` · 3 staged: Approve, after the fix ·
Dismiss the idea · Comment on core/hashline.gleam*.

The first revision let the owner stage "Approve" beside "Fix the risk first",
which tells the agent two things. They are now one: if both are staged the
outbox shows the single thing the agent will do, "Approve, after the fix".
Approve alone, "Request changes" and "Fix in this branch" are the other legal
combinations, and Request changes cannot be staged with Approve.

The owner presses **Fix in this branch** (1), **Approve** (2) and **Dismiss**
on the Idea (3), then **Send & next** (4). One message goes to the agent's main
strand, composed by the daemon from the staged items as inert fields, never by
the page from session text, and the receipt reads "Delivered to
`fix/hashline-replay · main`". All three records close together: the review as
approved, the Risk as "sent to fix", the Idea as "dismissed".

**The count.** In scenario terms, the four urgent items, the review and the two
finds clear in **13 presses**: the approval takes 3 (choose, Send decision,
Next thread), each of the three asks and the stuck delegate takes 2, so 3 + 2 +
2 + 2 = 9, and the review takes 4, which makes 13. Including PR `#1261`, whose
thread is now a project ticket and whose one action "Send back to the worker"
is choose and send, the total is **15**. The owner never leaves the page, so
there is one screen throughout. Taking threads out of rank order costs one
press each, and typing the comment is not a press. The two presses per ask are
the two-press arming rule, not slowness: the first holds the words exactly as
drawn, the second sends exactly those.



**The phone.** The 390 px layout drops the rail. It is the list, full height,
with the amber band first, so all four urgent rows are above the fold of the
first screen. A tap opens a thread over the list with a back arrow; the thread
is the same content in one column and the outbox is sticky at the bottom with
its Send under the thumb. This is Plannotator's point: the owner reads the
review on the sofa at 14:30, comments on one file and sends, and the receipt is
the evidence it landed.

## 3. Information architecture

The page has three columns and no fourth. The **rail** (176 px) holds five
entries: Everything by need, Needs you, To review, Finds and Projects. The
**list** (388 px) holds threads; the **reading pane** takes the rest and is the
only place that decides anything. The rail narrows the list and nothing more.
"Everything, by need" is the default and the only view in which the four urgent
rows are guaranteed. The first version also drew a Mail group (Sent, Closed), a
Workspaces group, a paragraph of help, five chips in the top bar and four tints
of kind tag. The owner's critique called that the most on screen of the four,
which the brief ruled out, and all of it is cut: one count in the bar, one tint
(amber, for need), and kind tags that are a word in a hairline outline. Sent and
Closed hold nothing until the person has sent something, and they appear then
as one line in the list's fold, not as folders.

**Rank, and what folds.** The list is grouped by *what each thread needs from
the person*, which is the classifier's answer for its source session or strand:
*you* gives Needs you, *ready to review* gives To review, finds form their own
group, and *agent* and *quiet* fold into one line each at the bottom, each
naming its members so the owner can see that nothing is hidden and need not be
shown it. Folded lines are not rows; they cannot be selected and carry no unread
mark.

**The hardest requirement: urgent items must be impossible to miss in a medium
whose point is reading at your own pace.** Mail fails at this because mail's
urgent and ordinary messages differ only in their sender. Five rules hold it.

1. *Needs you is a pinned group, not a filter.* It sits first, is sticky at the
   top of the list, and cannot be folded. A row leaves it only when answered or
   when the agent stops needing the person.
2. *Reading is not handling.* A thread has two independent marks: the blue dot
   is mail's, unread; the amber band is need, unsent. Opening a thread clears
   the dot and does nothing to the band. A read but unanswered row keeps a
   hollow dot and an age that turns heavy amber after an hour.
3. *The page opens on the first urgent thread*, not on a blank pane or the last
   thing read. The critique noted that the large pane then draws the eye before
   the list does; the answer is not to open nothing but to draw the pane in the
   same neutral tones as the list.
4. *The count lives outside the page.* The tab title and the one top-bar chip
   say 4; they are the existing `title_rule` mechanism extended from one session
   to the feed.
5. *Other folders keep the count.* Narrowing the list to Finds does not remove
   the bar's chip, since the chip is not part of the list.

**A count that is honest.** The number 4 is a claim about everything the person
may see, and today `sessions.activity` never reads saved sessions, so an
approval parked in a saved session, after a daemon restart for example, is in
no count (fact sheet §4, item 2). The design does not hide this. In phase 0 the
chip reads "4 need you in running sessions" whenever the catalogue holds saved
sessions, with "N saved, not checked" beside it, and the count is a lower bound
by its own words. From phase 1 the source of truth is a durable catalogue
summary written on change: per session, the number of pending approvals and the
oldest open record's creation time, so a saved session is counted without being
woken. The first test of phase 1 is a restart: stop the daemon with an approval
pending, start it, and compare the count against the escalation register.

**Where the transcript went.** It is a drill-down from a thread's context,
never a place to read first. The ask thread carries the agent's last message,
quoted as untrusted text, and one link, "Open the transcript at this point",
which uses the transcript anchor on the record. For an approval the transcript
is not offered, since the record, not the text around it, is what the decision
binds to.

## 4. Item anatomy and lifecycle

**A row** is two lines: the session name (bold while unread) and the time it has
waited; then a kind word in a hairline outline (*Approval*, *Ask*, *Stuck*,
*Review*, *Ticket*, *Risk*, *Idea*) and a one-line subject cut by the page, not
by the agent. No coloured bar and no shadow: the selected row takes the raised
background and a hairline border.

**A thread** has one shape for every kind: an eyebrow (kind, session, strand,
workspace, since when), a title that is the question in the agent's words
(drawn as text, never as markup), then what it asks for or shows, then "in this
thread" (related items), then the person's response, and a sticky **outbox**
with three states: *not sent* (naming the staged items and the destination),
*sending*, with an Undo, and *delivered*, which carries the receipt.

| Kind | Staged by | Sent with | Closes as |
|---|---|---|---|
| Approval | Deny (first), Allow once, Allow for this session (owner's page only) | Send decision, echoing action text, grants and seq; no hold | approved, rejected, consumed |
| Ask | an option (recommended first), or free text | Send & next | answered, with the option's text |
| Stuck | a drafted nudge, text shown in full | Send & next | sent; the strand's own state takes over |
| Review | Approve, Request changes, Fix, File issue, Dismiss, a comment per file | Send & next | approved, changes requested |
| Find | Fix in this branch, File issue, Dismiss | rides the review's send | fixed, filed, dismissed |
| Ticket | Send back to the worker, Recheck, Retry, Stop, Close | Send | follows the ticket's stage |

**Receipts and what they claim.** "Delivered" means what the store proves: the
message was admitted durably to the target strand, which is what the peer
receipt proves (`async-collaboration.md`, "Peers have separate authority"). It
does not mean read. The page says *Delivered*, never *Read*, and when the target
is mid-turn it says *Queued behind the current turn*. An approval's receipt is
stronger, and says so: it names the decision and the seq the gateway checked.

**Undo.** For everything except an approval, Send starts a hold of five seconds
that lives on the daemon, as a weft timer whose handler checks for a stale
fire, so closing the tab neither loses nor doubles the message. The hold delays
delivery; it is not a retraction, and after it the page says "Delivered". An
approval is never held: its decision is delivered on Send, because a decision
that can be recalled for five seconds is a decision a second operator could
race, and the first decision wins.

**Nothing reaches the agent until you send** has a cost: a staged reply that
sits overnight is stale. The page does not keep drafts in the browser; a staged
item lives in the page's server-side state and goes when the page does. And
when a thread's subject changes under the person (an approval's action text
moved, a delegate retried on its own), the send names the revision the thread
was drawn at and is refused with a word, "changed since you opened it", exactly
as `stale_approval` is today, and the pane redraws. This revision rule is the
design's best borrowing from Plannotator, which opens the version that was sent,
and it is Loom's own rule that consent binds what was shown.

**Closure** keeps the row struck through with its receipt line, and folds it on
the next visit.

## 5. The coordinator story

The coordinator is project mode and sub-agent strands; this concept adds no
third mechanism. A coordinator's delegates are strands (`sub:*`) or, in project
mode, worker sessions per ticket. A delegate's ask, failure or finished work
becomes an attention record on that strand, and the feed carries it to the page
with the strand's parent chain.

Each delegate item is a thread in its own right, in the same list, ranked with
every other, with its parent in the eyebrow (`sub:mockup-b · under
coord/web-inbox`), so the owner answers a delegate without opening the
coordinator. The coordinator's own thread carries its delegates: the 13:40 ask
shows its goal, its token use and a three-line table of delegates, the stuck one
linked to its own thread. That is the one place the page draws a parent with its
children, and it draws them as context for a question, never as a board. The
"3 of 5 milestones" line of the scenario is drawn only if project mode's ledger
supplies it; goals have no milestones (§2.4), so otherwise the card says
"tickets ended: 6".

A delegate that is working or settled does not appear as a row, only on the
coordinator's thread and in the folded lines; and when the coordinator has
received a delegate's question and will ask the person itself, the person sees
only the coordinator's ask. That is Coordinator's decision policy: small,
reversible choices stay below, and what changes what gets built, costs money or
is a matter of taste reaches the person.

## 6. Project mode

Project mode is the coordinator the brief asked for, and it is unfinished. This
concept gives it a home and absorbs the web slice that #1167 never pushed, so the
ticket page is the inbox's review surface and not a second page.

**Where things live.** The rail's **Projects** entry opens a *project view* in
the same list pane: the project's name, a "New request" button (owner only), then
its tickets grouped by stage, those that need a person first, working next, ended
folded. A ticket opens in the same reading pane as every other thread, so a
ticket is a thread with a different body, and a ticket that needs a person also
appears in the main list under its group (a `person/review` or `person/check`
ticket under To review, a `person/answer` ticket under Needs you). There is no
separate project page and no board of cards; the Projects section of Home goes
on working until the inbox region replaces it, and is deleted only then. The
mockup's `project.png` draws it.

**The ticket thread** is the review surface for work that has a worktree and a
branch, which is every project ticket. It shows the stage and its reason, the
diff stat and the diff (read from the ticket's worktree, as the Changes tab
does), the check result with its failure output, the unresolved review comments
(project mode's GitHub source already reads comments), and the moves the ticket
offers. The moves are the actions the board already carries (`CanAnswer`,
`CanClose`, `CanRetry`, `CanPublish`, `CanStop`) plus recheck and "send back to
the worker", staged and sent like any thread. A move the ticket does not offer
is not drawn; Publish is drawn disabled with its reason while publishing is off.

**`person/check`.** On the paused `project/visible-failures` branch this stage
means a ticket's check failed and a person must look; failures are classified as
environment or code, with retry and recheck. The inbox draws it as a thread whose
title says the class: "The check failed on the code" or "The check could not run
here". For *code* the recommended move is "Send back to the worker" and Recheck
is offered but not recommended; for *environment* Recheck is recommended and
sending back is not. The failure output is the check's own text, drawn as text in
a bounded block and labelled untrusted. Until that branch lands, a stage the
page does not know is decoded as `UnknownStage` (as the board already does) and
drawn as a thread whose title is the stage word and whose moves are those the
ticket's `actions` list names; so the page needs no change when the branch
merges, only a mapping row. The design does not depend on the template
question: it draws whatever failure the check reports, in an environment where a
template exists or where the owner checks with network on.

**Which of #1167's web-slice items are absorbed, and when.**

| Item | Phase | Note |
|---|---|---|
| ticket thread with answer and close | 1 | exists on the board today; moves into the thread |
| retry, stop, recheck | 1 | `CanRetry` and `CanStop` exist; recheck arrives with `visible-failures` |
| ticket diff, check result, failure output | 2 | the ticket's worktree read plus the check record |
| publish | 2 | behind the project's own publishing setting; two-press, owner only |
| post a request | 3 | a form in the project view, owner only, creates a ticket through the existing router path |
| create a project | 3 | the same form kind; refused for observers and operators |

Create and post-request come last: they decide nothing for an agent that is
waiting, and are small once the project view exists.

## 7. Mapping to signals

| Item kind | Source (fact sheet) | Status |
|---|---|---|
| Approval thread | §2.1 escalation register; decision echoes the full `action` string, wanted grants and seq (`echo_matches`) | EXISTS per session; **a per-record read of its content from a page bound to no session is new**; the feed carries identity and head only |
| Peer message in an approval thread | §2.10 `PeerMessage`, `origin_checked` | PARTIAL: stored text; the per-record read lists recent peer messages to that strand, with no claim of relevance |
| Ask (options, recommended) | §3, §8 | substrate addition (attention records) |
| Ask free text, Explain | §2.5 answer box; §2.12 held inputs | EXISTS (a message to a strand) |
| Stuck delegate | §2.2, §2.9 strand `Failed` | PARTIAL: **main-only today** (`needs_you` judges failure from main), so a failed delegate is invisible until the classifier reads per-strand status |
| Stuck nudge | §2.12, `agent_send` | EXISTS as a message; "resume" as a command is not assumed |
| Wait time ("1h 22m", "3h 00m") | none | **NEW field**: `waiting_since` on the activity row (the oldest open record's creation, or for an escalation a new `asked_at`; its `asked` is a count) |
| Review thread: stats, files, hunks | §2.11 worktree read | PARTIAL: owner and operator only; not for observers |
| Review ordering (source, tests, docs) | none | classifier-side pure function over paths; no record |
| Agent's last message on a review | final assistant text | EXISTS (cut to 280 bytes in the activity row; full text by per-record read) |
| Review verdict, per-file comment | none | NEW beyond substrate, small: part of the thread-send command, no new record kind |
| Find: Risk, Idea | §3 | substrate addition; carries an optional path and line for the in-place mark |
| Ticket thread: stage, diff, check, output | §2.5, §2.11 | PARTIAL: stage and actions exist; diff and check output are the paused web slice |
| `person/check` | `project/visible-failures` | paused branch; drawn as UnknownStage until it lands |
| PR comments on a ticket | project mode's GitHub source | PARTIAL: owner only, project mode only |
| Receipts | §2.10 peer receipt; approval seq | EXISTS (durable admission) |
| Need-you rank and band | classifier | substrate addition |
| Folded Moving and Quiet | `sessions.activity` words | EXISTS |
| Tab title and count | `web_client/title_rule.gleam` | EXISTS for one session; the feed extends it |

**What the concept needs beyond the three substrate pieces.** Three small things
and no new record kind. First, `waiting_since` and per-strand status on the
classifier's inputs. Second, a **per-record read at a revision** and a **thread
send** command that takes the revision. Third, an optional path and line on a find
for the in-place mark. The first version also proposed a *review record* with
ordered sections and agent summaries per section; it is cut from phases 0 to 2 and
kept only as a candidate for phase 4, to be prototyped first (section 10).

## 8. What changes where

**`session_view`** gains the attention classifier (pure; *you, agent, blocked,
ready to review, quiet*, with *ready to review* a function of "run ended, diff
non-empty, nothing pending") and a thread projection: from a record and its
related records to the eyebrow, the title, the staged items and the outbox
state. The outbox state machine and the rank rule are pure functions here, so the
terminal reads the same answers, in the portable subset (R6).

**`web_view`** gains an inbox region of Home with the list, the reading pane
and the outbox at fixed tree paths. Click paths for staging and sending are added
to `ui_socket`'s admitted set for owner and operator only, by region prefix and
keyed by daemon identities, and to no observer path. Staged text is held in the
page's state and sent as one command. The first version also wanted line-anchored
comments, drafts in local storage and a pane that advanced by itself; a server
component pays for each (a handler per diff line, a message per keystroke,
a card appearing under the pointer), so they are cut: one comment field per file
(one handler per file), anchored by the revision and path the daemon issued; no
local drafts; and advance only on the explicit "Send & next" or "Next thread"
press.

**Daemon.** The attention feed, which carries **identities, kind, state and a
bounded head, never content**; the per-record read; the thread-send command; the
hold timer; and the durable catalogue summary of section 3.

**Protocol changes.**

- `protocol-change/NNN-attention-feed.md` (substrate 3). It must decide: scope and
  per-principal filtering; that rows carry heads and content is read per record at
  a seq; resumption after a gap; row and rate bounds beside `050`'s 2,400 B; the
  durable catalogue summary and its restart behaviour; and the observer's
  redaction.
- `protocol-change/NNN-thread-send.md`. It must decide: the command's shape, one
  message composed by the daemon from staged fields; what "delivered" may claim;
  the stale-revision refusal; the five-second hold, which is daemon-side and never
  applies to an approval; and the approval path, which stays the gateway's
  `decide`, judged in the target session's own hub, with a cross-session path
  needing its own proposal before the inbox can decide a local session's request.
- The review record of the first version is not proposed.

## 9. Roles

An **operator or owner** sees everything above: staging controls, the outbox and
Send, Undo. "Allow for this session" is drawn on the owner's page only. Every
deciding control uses two presses: the first stages and holds what was drawn,
the second sends exactly that; the approval's Send also waits 600 ms and never
takes focus.

An **observer** sees the same list, counts and threads for the sessions they
hold, and none of the three things that act: no staging buttons, no outbox, no
comment field. Where the outbox is, one line: "An owner or operator decides
this." Approval content is redacted to the tool name and the fact that a decision
is pending, because today's observer page draws no approval cards. A review's
hunks are withheld from observers (§2.11), so an observer sees the stats, the
agent's last message and the finds, and the file list without diffs. Bob, an
operator on `storage/branch-index-repair`, sees the same approval and the same
band; when either of them decides, the other's thread becomes "Decided by Bob,
14:23" and its outbox goes quiet, because the first decision wins.

## 10. Cut list

1. **No unified timeline or "since you last looked" digest.** The inbox lists what
   is asked, not what happened; the folded lines carry the rest.
2. **No plan or prototype documents in the first build.** Loom has no
   plan-submission tool in the tree; a plan thread waits for one.
3. **No bulk actions.** No approve-all or select-many.
4. **No snooze, assignment or hand reordering.** Rank is a function of need and
   age.
5. **No transcript preview in the list or the pane, and no read receipts.**
   One quoted message and a link; "Delivered" is all the store can prove.
6. **No merge button.** A ticket can be published or sent back; merging stays in
   GitHub.
7. **No line-anchored comments, no local drafts and no automatic advance.** The
   first two cost a client component the size of the composer; the third moves a
   different card under the pointer after a press.
8. **No review record and no per-section agent summaries** until a prototype
   shows an agent can write them and an owner prefers them to the diff.

## 11. Build phases

**Phase 0, existing signals, and honest about it.** A region of Home, which is
bound to no session, owner-only and already admitted by `ui_socket`; it needs no
new page kind and no session ticket, and its added click paths are a small
addendum to protocol-change/051 (listed here, not hidden). It reads
`sessions.activity` (5 s, 24 sessions) and, for the owner, the project board.
What it can show is less than the scenario: the amber band holds the sessions
whose word is *needs you*, which today is a pending escalation (so
`storage/branch-index-repair`) or main failed while idle. The stuck delegate is
invisible, because failure is judged from main only; the two idle asks are
`idle` sessions with a `last_message`, which the page throws away today and now
shows, so they appear in a "Waiting" group as sessions, not as asks with options,
and are not ranked above anything. **There is no waiting time**, since the row has
none; rows are ordered needs-you word first, then name, and the band's hint says
"agents stopped for you" with no age. The headline therefore reads "1 session
needs you", not 4, with "3 idle with a question" beside it, and the chip says "in
running sessions" because saved sessions are not read. Project tickets with a
stage that needs a person are real, answerable rows with the existing answer box.
The value is that the owner reads one list instead of opening six sessions, and
sees each idle session's last message without opening it. The "Back at 14:20" line
is not drawn.

**Phase 1, the substrate and the first threads.** Attention records (ask, task,
find, with a routing field, a transcript anchor, the parent chain and an optional
path and line), the classifier with per-strand status, `waiting_since`, the feed
with its protocol change and the durable catalogue summary, and the thread-send
command with the hold. Asks and finds become real threads, ranking by wait time
works, the stuck delegate appears, and approvals are decidable in place through
the per-record read. Project tickets' answer, close, retry and stop move into
tickets-as-threads. The restart test runs.

**Phase 2, the review surface.** The review thread for finished sessions (stats,
the agent's last message, the file list and hunks from the worktree read, finds
pinned, verdict, per-file comment), and for tickets the diff, check result,
failure output, recheck and publish. The ticket thread is built first, since the
web slice is owed anyway, and the session review reuses its body.

**Phase 3.** The project view with "New request" and "Create project";
`person/check` mapping when its branch lands; the coordinator's context card;
drafts and reconnect hardening on the phone. **Phase 4, optionally:** a review
record with ordered sections, if the prototype in section 12 passes; then plans.

## 12. Risks, and the cheapest test that would prove the thesis wrong

**Risk: the pane is a second transcript.** *Cheapest test:* in phase 0, count how
often the owner opens the session from a thread. If more than about one thread in
three needs the transcript link to be answered, the context attached to an ask is
not sufficient, and the thesis is wrong for asks.

**Risk: the review is not worth reading.** The owner's critique put it plainly:
a diff reviewed file by file is a long read for one item in eight. The design
answers by lifting Approve above the long read; the test is whether owners press
Approve without opening any file, in which case the review is a signature on the
agent's own message and the pane should say so on the button ("Accept the agent's
account").

**Risk: the mail metaphor makes the owner relax.** Section 3's five rules are the
defence. *Cheapest test:* leave the page open with four urgent rows; if the
median wait is longer than under today's counting sidebar, urgent items belong
in the tab's foreground, not in the list.

## Revision

**What changed.** Seven things, in order of consequence.

1. *The page is calmer.* The top bar's five chips became one; the rail's Mail,
   Workspaces and help text were removed and a Projects entry added; the kind
   tags, the pink approval box and the purple peer box became one neutral
   treatment. The reading pane is drawn quietly so the list still leads.
2. *The review can no longer contradict itself.* "Approve" and "Fix the risk"
   merge into the single staged line "Approve, after the fix"; Approve moved above
   the sections so a long read is optional.
3. *The review record is gone.* Ordered, agent-summarised sections and line
   comments were the thesis's costliest piece and the critique's most severe
   finding. The review now reads the worktree (stats, the agent's last message,
   files ordered by path, hunks) with one comment field per file. The ticket
   thread, whose diff and check output are owed by #1167's web slice anyway, is
   built first and the session review reuses its body.
4. *Phase 0 is honest.* It is a region of Home, not a new page kind; it shows 1
   session in the amber band and not 4; it has no waiting time, no stuck delegate
   and no "away since" line; and the saved-session blind spot is stated in the
   chip and fixed by a durable catalogue summary in phase 1.
5. *Binding and feed are corrected.* A decision echoes the full action text, the
   wanted grants and the seq, not a digest; the feed carries identities and heads
   and content comes from a per-record read; ranking by wait needs a new
   `waiting_since` field; undo is a daemon-side hold and never applies to an
   approval.
6. *Project mode has a home.* A Projects view in the same panes; the ticket thread
   with diff, check result and failure output; a table of #1167's web-slice items
   by phase; and `person/check` drawn with its environment-or-code recommendation,
   falling back to `UnknownStage` until the branch lands.
7. *Auto-advance became an explicit press.* "Send & next" names its consequence;
   an approval never advances and offers "Next thread" instead.

**What I rejected.** Opening on nothing instead of the first urgent thread: the
fix is a quieter pane. Shipping the review record with a prototype in the same
pass: it is cut instead. Keeping line comments while dropping drafts: both cost
a client component. Another concept's board or row buttons: the thread with its
outbox and receipt is what this option offers.

**New press count, like for like, including PR #1261.** **15** (the first version
said 14). The approval 3 (choose, Send decision, Next thread); the pod-reach ask,
the coordinator's ask and the stuck delegate 2 each; the review 4 (Fix, Approve,
Dismiss, Send & next); the ticket for PR #1261 2 (Send back, Send). Without the
ticket it is 13. The cost over the first version is the explicit Next press after
the approval, which is the price of never moving the page after a decision.

**Needed beyond the substrate.** `waiting_since` and per-strand status on the
classifier's inputs; the per-record read at a revision and the thread-send command
with its daemon-side hold; an optional path and line on a find; the durable
catalogue summary for saved sessions; and, from the paused stack, the
`person/check` stage and the check record, which the ticket thread draws.

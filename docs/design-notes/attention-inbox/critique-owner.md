# Critique, lens 1: the owner at 14:20

**Status: one critic's review of the four attention-inbox concepts, through
the owner's eyes.** The reviewer plays the person in `04-critique.md`: six
to twenty sessions, three hours away, a standing dislike of busy pages and
of reading transcripts. Screenshots were read first and notes second. The
other lens (fit with Loom) is reviewed separately and is not covered here.

## What I read in ten seconds, before reading any note

- **A.** "4 need you", in amber, then a row of totals that match the scenario
  (1 review, 1 PR, 2 finds, 2 working, 2 quiet). Four rows, longest waiting
  first: the pod question (3 h), the approval, the fold question, the stopped
  delegate. Every row carries a button. I could say what, how many, and which
  first without scrolling.
- **B.** "4 agents need you", then seven pill counters. Below them "Your move 3"
  and "Blocked 1". The pills say "3 to answer" while the headline says 4, so I
  paused to reconcile them. The bands answer the question, but I had to read
  two layers of counting to see that the stopped delegate is the fourth. The
  review sits at the fold, partly cut off.
- **C.** A three-column mail layout. The top bar says "4 need you" in amber
  and the list has a "Needs you · 4" band, so the count is clear. But my eye
  went first to the large pane on the right, a pink box about the approval, not
  to the list. I read the approval before I had decided it was first.
- **D.** I read a coordinator's transcript. The sidebar says "Needs you 4" and
  the amber badge on the menu button says 4, but the middle of the page is a
  card titled "Since you last looked" over a conversation. I could say that
  the coordinator wants a ruling on folding and that something stopped; I could
  not say, in ten seconds, which of the four is first, or that the first item
  in the sidebar (the approval) is not what the page is showing me.

## Score table

Scores run from 1 (fails the owner) to 5 (does it well). Questions: Q1
ten-second read, Q2 answer without context, Q3 calm, Q4 presses and screens,
Q5 scale, Q6 phone, Q7 trust.

| Concept | Q1 | Q2 | Q3 | Q4 | Q5 | Q6 | Q7 |
|---|---|---|---|---|---|---|---|
| **A** inbox is the home | 5: heading, totals and four ranked rows with buttons, nothing else | 3: questions answerable on the row, but a button invites a blind answer; approval and review need the pane | 4: three regions by default, amber on one word per row, one blue for actions | 4: 15 holds against the mockup; Retry as one press is a fair call | 3: "Needs you" grows to twenty rows; the five-row cap is the only brake | 4: recommended answer is two taps on the row; Review and Open review go to a sheet | 4: armed button names the send; batch panel lists both answers; pane says where it lands |
| **B** board by who acts next | 4: sentence is clear; pills duplicate the bands and disagree with the headline | 3: Approve sits on the card with only the command line; the peer message hides behind "Why it needs this" | 3: cards, tinted backgrounds, pills and a rail; 1.5 screens tall | 4: 15 holds; expansion in place saves navigation | 3: one status line per agent is the right instinct, but a family spread over three bands will read as unrelated agents | 3: cards are long; counters scroll sideways; the approval is below the fold | 4: armed state names target and grant; receipt with Undo; Bob shown as present |
| **C** threads you answer like mail | 4: counts and a ranked amber band are right; the open pane steals the eye | 5: each thread brings its own context, consequence text and, for the approval, the peer message and the digest | 2: three columns, top-bar chips, a rail, coloured kind tags, a pink box; the most on screen of the four | 4: 12 or 14 holds, but the review stages "Approve" next to "Fix the risk first" | 4: a sticky ranked list with folds scales like mail does | 4: all four urgent rows fit the first phone screen; thread is one column; sticky outbox | 5: "Not sent" bar always names what, to whom and the digest; receipt closes the loop |
| **D** attention layer on A2 | 2: lands on a transcript; the queue is a sidebar the eye does not go to | 3: ask and approval cards are strong; the review is a rubber stamp and the stopped delegate shows no error text | 2: seven regions at once (top bar, sidebar, card, transcript, ask card, dock, strand panel) | 3: 14 holds, but it excludes the PR (16 like for like) and the review is unread | 2: a queue of twenty in a 232 px sidebar, two lines a row, beside a per-session card | 3: the stepper makes one-handed clearing possible; the first screen is still a transcript | 3: arming is named; auto-advance after 1.6 s moves the target under a thumb |

## A: the inbox is the home

**Finding 1 (severity: high). The row button invites a blind answer.** Place:
the "Needs you" group in `desktop-light.png`, "Use scratch tmpfs" and "Fold
under open", and the group-header link "Send the recommended answer to 2
questions…". The button names a choice but not what it costs, and the batch
link takes both recommendations without the owner seeing why either is
recommended. The consequences are in the open pane (`open-item.png`: "Writes
land in the jail's scratch mount…") but the fastest path skips the pane. At
14:20 a tired owner will use the fastest path, and an answer sent to an agent
cannot be recalled once its turn starts. Fix: show one clause of consequence
under each row's recommended button, or make the batch panel print each
option's consequence line next to the question. The batch panel already lists
the two answers; add the line there.

**Finding 2 (severity: medium). The queue is calm only because there are
eight items.** Place: note section 3 (five-row cap) and section 11's own
first risk. With twenty sessions and three coordinators, "Needs you" is a
list of twenty rows, longest waiting first, and the approval that matters may
sit at row 11 because a question is older. The note says as much. Fix: keep
the rule but let a security-bearing kind (approval) sit above the age order,
as C does, and state it in the group subtitle. Add a per-coordinator collapse
so three coordinators' delegates do not each add rows.

**Finding 3 (severity: medium). The approval is the one item that cannot be
decided from the page.** Place: the Approval row, whose only button is "Review".
That costs three presses and a pane while the others cost one or two. It is
the right call for safety, but the row text ("Run sqlite3 … with a write grant
to ~/.loom") gives the owner nothing to weigh, and the peer message that
bears on it appears only inside the pane. Fix: add the sentence "runner/pod-reach
asked whether this needs the write grant" to the row's meta line, so the owner
knows before opening it that the pane holds a reason to deny.

## B: the board by who acts next

**Finding 1 (severity: high). The approval card asks for a decision on a
command and nothing else.** Place: the "storage/branch-index-repair" card in
`desktop-light.png`, with Approve and Reject beside "Why it needs this". The
13:15 peer message, which asks whether the grant is needed at all, is behind
that link and the note (section 4) treats it as optional context. Of the four
concepts this is the one where the owner is most likely to press Approve on a
write grant outside the workspace without having seen the one fact that argues
against it. Fix: draw the peer message on the card, one line, whenever one is
unanswered; make "Why it needs this" the policy, not the context.

**Finding 2 (severity: medium). Two counting systems on one screen.** Place:
the pill row under the heading ("3 to answer", "1 stuck", "1 to review", "2
finds", "1 PR with a failing check", "2 working", "2 quiet") against the
bands below ("Your move 3", "Blocked 1", "Ready to review 1", "Working 2",
"Quiet 2"). They repeat each other and use different words, and the pills
are the part that scrolls sideways on the phone. The owner pays for the
duplication in reading time and gains only the finds count, which the bands do
not show. Fix: delete the pills; put "2 finds" in the Ready to review band
header, and let the bands be the totals.

**Finding 3 (severity: medium). The failing PR is demoted into Working.**
Place: the `wp-j/vetting-lint` row in `full-light.png`. The scenario lists PR
#1261 under review with blockers and the owner's totals count it. B draws it as
a quiet line in Working with no button, on the argument that the agent is
already working. The owner cannot tell from the row whether the agent knows
about the failing check or Bob's two comments, and cannot nudge it. Fix: give
the row a "Tell it to fix both" action, or move it into Ready to review beside
`fix/hashline-replay`.

## C: threads you answer like mail

**Finding 1 (severity: high). It shows the most at once, against the
brief's central ruling.** Place: `desktop-light.png`. Count: a top bar with
five chips, a rail with nine entries and a paragraph of help text, a list
with four bands, and a reading pane with a headline, a pink request box, a
dashed peer-message box and a decision row. Colours carrying meaning: amber,
pink/red, green, purple, blue unread dots, and tinted kind tags in four hues. This
is the density the owner rejected in September, and the note's section 3
defence ("one list, one pane") does not change what the screenshot looks like.
Fix: drop the top-bar chips (the rail's "Needs you 4" says the same), drop the
rail's Mail group while Sent and Closed hold zero, and use one tint for all
kind tags with the word doing the work.

**Finding 2 (severity: high). The review thread's staged message can
contradict itself.** Place: `open-item.png`, the outbox "4 staged: Approve ·
Fix the risk first · Dismiss the idea · Comment 1 on line 100". A review that
is approved and also sends "fix the risk first" tells the agent two things,
and the note (section 2) says one message carries all four. The owner does
not know whether the agent will read this as "merge it" or "do this first".
Fix: make Approve and "Fix the risk first" mutually exclusive in the outbox,
with the verdict becoming "Approve after fix" when both are chosen, so the
outbox line says what the agent will do.

**Finding 3 (severity: medium). The review surface is where the owner reads
transcripts again.** Place: `open-item.png`, the section list with hunks and
line comments, and the note's phase 2 ("the phase that carries the thesis").
The owner wants to surface decisions, and a diff reviewed in four sections
asks for a long read for one item of eight. It is optional, which is why this
is medium, but nothing in the default view says so. Fix: show the agent's
one-line verdict and the two finds first, with "Approve" available above the
sections, so a long read is a choice. The mockup already puts finds above the
sections; lift Approve there too.

## D: an attention layer on A2

**Finding 1 (severity: high). The first screen is a transcript, which is the
thing the owner named as the drag.** Place: `desktop-light.png`. The page
opens on the coordinator because that is where the owner left it. The queue is
a column on the left; the centre is a conversation, a card and a dock. The
note (section 2) says the owner "knows" what is wanted "without scrolling",
but that is the coordinator's ask and the coordinator's delegate; the approval
that has waited 1 h 22 and the pod question that has waited three hours are
named only in the card's last line ("2 more asks and 1 approval need you").
Fix: when the queue is non-empty and the owner has just returned, land on the
first queue item's card, with the "Since" card above it, not on the last
session viewed.

**Finding 2 (severity: high). The review is decided without seeing it.**
Place: the note's press table, step 5, "Mark reviewed, confirm", against the
"honest additions" paragraph: reading the diff costs two more presses and a
navigation to the Changes tab. The pressing path is 2 presses for a review
that has not been read, and the 14 excludes the PR. Like for like, D is 16
presses against A's 15 and B's 15, and the 2 it spends on the review are a
signature on a summary the agent wrote about itself. Fix: the review card
should show the diff stat and the two finds and have no "Mark reviewed" until
the Changes tab has been opened once; or relabel the button "Accept the
agent's summary".

**Finding 3 (severity: medium). The sidebar queue does not survive twenty
sessions.** Place: the "Needs you" block in the left rail of
`desktop-light.png` and `phone-drawer.png`. Titles there are short paraphrases
("Scratch tmpfs, emptyDir, or …", "Fold closed items, or a Done list?") that
the note says come from the ask record, and the first four rows already fill
a third of the rail. With twenty sessions and three coordinators, two lines
per row would push "Working" and "Idle" off the screen, and the owner would
scroll a sidebar to find the first thing that needs them. Fix: cap the block
at five rows with a count, as A does, and give a row a single line.

## Steal list

- **A:** the heading "4 need you" with its quiet totals line and one rule for
  order, printed as the group subtitle ("longest waiting first"). It is the
  only first screen that answered Q1 in ten seconds.
- **B:** the one-line roll-up under a coordinator ("3 delegates · mockup-b
  stuck · mockup-a working · fact-sheet settled"), which is how three
  coordinators stay readable, and the rule that a stuck delegate is its own
  card with a crumb to its parent.
- **C:** the outbox bar at the bottom of the pane ("Not sent. Choose a
  decision. Nothing reaches the agent until you send"), paired with the
  approval thread's inclusion of the peer message and the digest it binds to.
  It is the best answer to Q7 and to "do I have what I need to decide".
- **D:** the "Since you last looked" card, with its two sections (asked of you,
  happened) and one line pointing at the queue. It is the cheapest way to
  turn three hours away into something readable, and it can sit above any of
  the other three layouts.

## Ranking and reasons

**1. A. 2. C. 3. B. 4. D.**

A is the only concept whose default screen does what the owner asked for: it
says "4 need you", puts four rows under it in an order the page states, and
lets the common case, a question with a recommendation, be answered from the
row. It is also the calmest, with the fewest regions and one meaning for each
colour. Its weaknesses are real (the blind-answer button, the age-only
ranking at scale, an approval that takes three presses), but each has a
small fix and none changes the shape of the page.

C is the best at everything after the first glance. Its threads give the
context a decision needs, its outbox is the clearest trust signal of the four,
and its phone layout clears the scenario best. It ranks second because the
default screen carries the most at once, which the brief named as failure,
and because the review surface is a large build whose value the owner has not
asked for. If its chips and rail were cut to A's weight, it would take first
place on the strength of the thread.

B's unit, the agent, is right for a coordinator, and its roll-up line is the
best handling of delegates in the bracket. But the page repeats its own
counts, hides the one fact that argues against the approval, and demotes a
failing PR the owner counts as a blocker. Those are fixable, which is why it
sits above D, but it is a slightly busier A with a harder question about
what a card is.

D wins on cost and loses on the owner's actual complaint. The page it
produces on return is a transcript with a better sidebar, and the review is
confirmed on trust. Its "Since you last looked" card is worth taking, and its
phase 0 is the most honest about what ships first, but as a place the owner
lands at 14:20 it is the least likely to remove the drag.

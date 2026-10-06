# protocol-change/071: a settled turn is a summary on the page, and its steps are read when its fold opens

**Status**: ACCEPTED 2026-10-06 · **Affects**: the web view's page socket
(what a divider's press causes, not which events are admitted) and the way
the web view uses the lane's `history` read · **Raised by**: the web UI
critique of r6e (F150, F151, F152) · **Implemented**: session view, web view

Amended by [072](072-strand-history-read.md): the scan below reads the strand's
ancestry through its own parent links (`history_lineage`) and no longer through
intervals of the session's sequence. What 071 and its addenda say of a scan's
intervals, its barren reads (`scan_floor`) and the sequence a press resumes from
(`View.resume`) is superseded; the rest stands.

## Problem

[070](070-web-lazy-folds.md) made a settled turn draw only its prompt, its
answer and a divider. The page still held every record of every turn it drew,
in a history window bounded at 600 records and 16 MiB, and "Load older" read
a hundred sequence numbers at a time into that window. Three things followed.

A turn of 570 calls is over a thousand records. It never fit the window, so
once it settled its prompt was not on the page, "Load older" showed nothing
new, and the turns before it were out of reach. After a reload the divider
counted the records the window happened to hold, `44 steps` for a turn of
570, and the number grew by five to ten at each press of "Load older".

Three turns of 110 calls are 666 records, so the first of them left the
window as the third settled, though each of them was only a divider.

A divider's figures were a property of what the page had read, and not of the
turn.

## Considered

**Raise the window's bound.** The window is projected on every capture, and
its bound is what keeps that work in proportion to what is drawn. A bound big
enough for the turns people run makes every capture pay for them.

**Count steps in the daemon and send them.** The daemon's descriptors carry an
identity, a sequence and a size, and nothing about what a record is, so a
count needs every payload decoded. That is a new read in the gateway, a new
decoder in the client protocol and a loop in an actor that serves every
attachment, to give the page a number it can compute from records the gateway
already sends.

**Keep the records of closed turns and cut them by turn.** It makes the window
turn-aware and leaves the cost where it was: the records of a turn of 570
calls are still on the page.

**Summarise a turn once, when it closes, and read its records again only when
asked.** The page already reads history in bounded intervals, authorized per
frame on its own lane. A closed turn keeps the pieces the page draws for it,
and the records are dropped.

## Decision

**Accepted.**

*What the page keeps of a closed turn.* A turn closes when every record of it
is in the history window and nothing will be added to it: every turn but the
newest, and the newest once its strand settles. The page keeps its summary
(`session_view/turn_ledger.Sealed`): the pieces it draws with the fold closed
(prompt, divider, answer), the cost of those pieces in rows, the sequence of the
turn's first record and the identity of the record before it, the identity and
sequence of its last record, and what its records added to the Changes and Trace
boards. The window is trimmed to the records after the newest closed turn's
last, so it holds the running turn and nothing older. The divider's figures are
counted from every record of the turn when it closes, so they are the same
whenever and however the page opened.

*The scan.* The history window has a second, transient read beside it
(`history_view.scan`). It starts at one record, reads the strand's ancestry
downward through the lane's `history` read in the same intervals of at most a
hundred sequences, and holds what it read apart from the window. It starts from
the records the page already holds, the newest cut and the window, so a turn
closed a moment ago is often answered without a read. It is bounded at 4,096
records and 32 MiB. A scan that reaches either is unreadable, and one a page
would take past them keeps its newest end, the one it started at. When the page has
what it wanted, or the read was refused, the scan and everything it read are
dropped. The window is the same value after a scan as before it, so a read
through a turn of thousands of records cannot evict the live end.

*What the page reads.* One read at a time, in this order:

1. The start of the turn the window began inside. A page opened on a settled
   session holds the newest hundred records, which are the end of a turn. Until
   its input is read the page draws nothing for it, and it draws the turn once,
   with the right figures.
2. The newest steps of a fold the reader opened that the page does not hold. The
   read starts at the turn's last record, which the page holds, and stops when
   the newest `fold_budget.fold_rows` (100) rows of steps are in hand or the
   turn's input is reached. The divider reads "Reading the steps…" until they
   arrive. Closing the fold drops its steps.
3. The turns below the oldest the page holds, after a press of "Load older".
   The read starts at the parent of the oldest closed turn's first record and
   stops at the first page that holds ten whole turns, at the strand's first
   record, or at the scan's bound. A press loads turns and not records, and
   draws the turns it found, not a number of rows.

*When a turn closes.* The records cannot always say that nothing more will be
added: an operation can lag the record that opens its turn, and a turn can go on
with no new input (a provider retry, a restart). Records that arrive after a
closed turn with no input of their own are therefore read as the end of a turn
whose start the page does not hold, and the whole turn is closed again in place
of the partial summary. A page that watched a turn and a page opened after it
draw the same divider once the turn settles. A read that ends before the turn's
input, at a bound, closes nothing and leaves the page's older closed turns
alone. A closed turn whose start the window did not hold is keyed by its first
record, not by the window's start.

*What the page retains.* Rows bound what the page draws; the summaries are also
held to 16 MiB of text (`fold_budget.sealed_bytes`, the size of the window they
replace), counting the text of the pieces and of the boards, since one row can
be as long as a record may be. A page over either drops its oldest closed turns.

*Authority.* Every read is the lane's `history` read, which the gateway admits
for an observer's attachment as for an operator's, and which the page's relay
authorizes at each frame (`ui_relay.while_open`) exactly as it does for "Load
older" today. A press names nothing to read. The divider's handler carries the
number of its fold, fixed when the page was drawn (`turns.Work.id`), and the
page applies it only when the number is the id of a fold of a turn it draws; the
record the read starts at is read from the page's own summary of that turn. No
value of the browser's event reaches a read.

*The socket.* The observer's page socket admits the same events at the same
paths as under 070 (`component.fold_click` and `older_path`, with the strip's
chips and the Home button). A press of a divider now causes a read where 070
said it read nothing; the admitted events are unchanged, and `page_events_test`
still fails if the view moves the button.

*The daemon's protocol.* Nothing on the wire changes. The client protocol, the
gateway and the daemon's page socket are as they were.

*What the page draws.* A closed turn is its prompt, its answer and one divider.
The row limit counts what is drawn, so the limit holds that many turns rather
than that many records, and the turns the page holds are the newest within it,
as under 070. A turn whose own prompt or answer is longer than the limit is
drawn whole. A running turn alone over the limit is drawn from its newest
blocks, as before, and the closed turns are kept for when it settles. The
Changes and Trace tabs are folded from each turn once when it closes and
joined, so a turn that has been closed still shows its edits and programs; the
boards cover the turns the page holds.

## Costs

A press on a divider waits one or more round trips, and the divider says it is
reading. A page that opens on a long settled turn draws nothing for it until the
turn's start has been read, which is about a tenth of a second for each hundred
sequence numbers on a local daemon. A fold read that stops early says how many
earlier steps it did not reach by the divider's count of the turn's steps, so
the number is the divider's and not a count of rows. Find in page does not see a
closed fold's steps, as under 070. A turn of more than 4,096 records
cannot be read whole: it is drawn as far as it is known, as a turn of its own,
and "Load older" reads what is below it.

The page's history window no longer holds closed turns, so anything that drew
from it beyond the transcript now draws from the summaries: the Changes and
Trace boards and the sequence of the newest tool result, which says when the
workspace is read again. A cache miss noticed after its turn closed is drawn
after that turn's pieces.

## Addendum 2026-10-06: four rules the first live review corrected

No wire protocol changes. These adjust rules above that the first review of an
implementation found wrong.

*A fold never draws a result without its call.* The read that fills a fold
stops at an interval of a hundred sequences, and a model that issues its calls
in one message and gets the results as one record each can leave the read
between the two. The results it holds name no call, so the fold does not draw
them, and they do not count toward the hundred rows that fill it: the read goes
on until it holds a hundred rows of whole steps, or cannot go further. The
number of earlier steps a fold says it does not show is the divider's count of
the turn's steps less the steps it draws.

*A scan stops at a record it cannot load.* A record over the presentation limit
reaches the page as a descriptor with no payload, and the parent a scan is
missing is then a record no read below it will prove. A scan that holds that
descriptor is not readable, so it ends there and does not walk every sequence
beneath it to the strand's first.

*A refused read gives up on one lead.* `completion: Spent` stops the page from
asking again for the lead it could not complete. It lasts until that lead has
been closed; records that arrive afterwards with no input of their own are a
lead that has not been tried, and are read.

*A page a running turn crowded is paged again when the turn settles.* A paged
page that had to cut a turn is full, as above. When the cut is the running
turn's own rows, drawn open, the page is `Crowded` and says the same while the
turn runs, and is `Paged` again when it settles into one divider and the cut is
gone. A cut by the bytes of the closed turns stays full, since a summary never
shrinks.

Two rules about words follow from the same review. The divider says
`interrupted` for a turn in which a command was stopped on request (a tool
result whose details say `cancelled` and not `timed_out`), as it does for an
aborted response. A stop the provider could not confirm is worded for the
reader, with no part of the harness named.

## Addendum 2026-10-06: a window with none of the strand, and the advisor's feed

No wire protocol changes. Two rules about what the page reads, found by the
second live review.

*A window that holds none of the strand's records is read, not taken for an
empty strand.* A gateway's cut is the newest records of the whole session. When
another strand wrote past a settled one (the advisor's review of a turn that
just ended, when it is long), the strand's leaf is below the cut, the window holds
none of its records, and the page had nothing to complete and nothing to offer: it
said the conversation began, over no prompt, divider or answer. The page now reads
the strand's newest turns from its leaf, once, when no turn is closed and the leaf
names a record the window lacks, in the same bounded intervals and with the same
stopping rule as the turns below the window. While it reads, the lane says it is
loading. A read that is refused is not repeated (`completion: Spent`); the lane
then offers "Load older", whose press reads from the leaf again. A cut that names
no leaf is still the beginning.

*A feed sent to the advisor opens a turn.* The advisor's strand receives one kind
of message, and each of its runs answers one. Classified as outside any turn, the
strand had no input at all, so completing its newest turn by reading back to its
input could end only at the strand's first record, which on a long session was
hundreds of reads in a row. A feed and a goal feed are inputs, so each review is
a turn and the newest is completed by reading back to its feed.

*A scan that finds none of its records stops, and the press goes on.* Every
history read is an interval of a hundred sequences of the whole session, and the
scan keeps only the records of its own ancestry. A strand sparse among the
session's sequences (the main strand after sub-agents wrote thousands of records,
the advisor after a long main turn) would be read one interval after another down
to the first sequence. A scan now stops after eight reads in a row that add
nothing (`history_view.scan_floor`), is given up as a refused read is, and the
page remembers the sequence it got to (`View.resume`), so a press of "Load older"
starts below it and each press goes further. A scan that is finding its records
never reaches the limit. A strand's first read starts below the cut's lowest
sequence and not at its cursor, so the cut is not read again.

*Not covered.* A strand whose newest record is over the presentation limit reaches
the page as a descriptor with no payload, and the page cannot read its parent
from it, so such a strand still opens as the beginning with no "Load older". The
descriptor would have to carry the parent; that is a wire change and is not made
here. The advisor's feed change is to `session_view/turns`, which the web view
draws from; the terminal does not use it.

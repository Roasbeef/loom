# protocol-change/071: a settled turn is a summary on the page, and its steps are read when its fold opens

**Status**: ACCEPTED 2026-10-06 · **Affects**: the web view's page socket
(what a divider's press causes, not which events are admitted) and the way
the web view uses the lane's `history` read · **Raised by**: the web UI
critique of r6e (F150, F151, F152) · **Implemented**: session view, web view

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
records and 32 MiB, and the page stops it before the bound. When the page has
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
closed fold's steps, as under 070. A turn of more than 4,096 records is closed
as far as the scan reaches and its remainder is a turn of its own, which
"Load older" reads.

The page's history window no longer holds closed turns, so anything that drew
from it beyond the transcript now draws from the summaries: the Changes and
Trace boards and the sequence of the newest tool result, which says when the
workspace is read again. A cache miss noticed after its turn closed is drawn
after that turn's pieces.

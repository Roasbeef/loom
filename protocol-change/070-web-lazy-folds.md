# protocol-change/070: a settled turn's steps are drawn on request, over a page event

**Status**: ACCEPTED 2026-10-05 · **Affects**: the web view's page socket (the
observer's accepted events) and the lane's markup · **Raised by**: the web UI
critique of r6b and r6c (F123, F139) · **Implemented**: web view, session view,
client daemon page socket

## Problem

The page holds a limited number of transcript rows because Lustre's server
runtime retains every element it rendered (#587). A settled turn's work was a
`<loom-fold>` that opened and closed in the browser, so the server rendered
every step inside it whether or not anyone opened it, and the row limit counted
all of them. One turn of 170 calls was over the 150-row limit alone. The page
then kept only the newest blocks of that turn and nothing before it: the
turn's prompt and its divider were cut, the turns before it were unreachable,
and "Load older" was refused as full. The reader saw a lone `done` row.

## Considered

**Count a folded turn as one row but still render its steps.** The limit exists
to bound what the runtime retains, and the steps would still be retained. The
count would be wrong in the direction that matters.

**Render the steps in a second page-wide element on demand from the browser.**
The browser could ask for a turn's steps with a request of its own, and the
server would answer outside the lane. That is a new request type, a second
retention path and a new thing to authorize.

**Keep the browser-side fold and trim older steps from the page.** Nothing says
which steps the reader will open, and a trimmed step cannot come back without
a read.

**Open the fold on the server.** The page already holds the turn's records. A
press on the divider asks the page to draw that turn's steps from them, the
runtime retains them only while the fold is open, and closing drops them. This
costs one round trip on a press, and adds one event to the observer's socket.

## Decision

**Accepted.**

*What the page draws.* A settled turn is drawn as its prompt, its answer and one
divider (`Worked 52s · 80 steps`), a button. Its steps are not drawn. The row
limit counts what is drawn, so such a turn costs the page the rows of its
prompt, its answer and one divider, and a page holds the turns around a turn of
two hundred calls. Opening a fold adds its steps to the count. When that pushes
the page past its limit, the folds opened before it are closed, oldest first,
until the page fits or one fold is left. A fold that does not fit alone draws
its newest steps that do, and a line says how many earlier ones are not shown.
The running turn is drawn open as before, and counted by every row.

*The event.* The divider is a button with one `click` handler. Its message
carries the fold's number: the sequence of the first record the turn's work
folds, a number the daemon assigned (`turns.Work.id`). The message is fixed
when the page's tree is drawn, and the browser's event names only a path, so no
browser-supplied value reaches the page. The page applies it only when it is
reading a session (the condition "Load older" needs) and only when the number
is the id of a fold of a turn the page holds; any other number changes nothing.
It reads nothing new and sends no command: the steps come from records the page
already holds, never from the event.

*Which turns are held.* The turns a page holds are chosen as if every fold were
closed, so a press never changes where the page is cut, trims its history or
fills a paged page. The rows those turns leave over, plus a reserve of 100 rows that belongs to the
folds alone, go to the open folds (so what a page draws is bounded by its limit plus 100), most
recently opened first. A fold that does not fit whole, if it is the most recent
that did not, draws its newest steps that do; a fold opened before it that does
not fit is closed. While a running turn is alone over the limit the page keeps
loaded older records in its window untrimmed, and draws them once the turn
settles.

*Admission.* The observer's page socket admits a `click` at the divider's exact
path and no other event there (`component.fold_click`), as it admits the older
button's, the home button's and a chip's. The path is the lane's keyed list,
the piece's key, the row's body, the work's element and the divider. A keyed
child's path segment is its key, so the key is checked: `work:` followed by a
sequence and an index that are whole numbers as `int.to_string` writes them, or
`work:window-start`. A path to any other child of the row, a step beneath an
open fold, or any other piece is dropped before it reaches the component, as are
a submit, another event at the divider, and a batch. `page_events_test` and the
socket's tests fail if the view moves the button.

*Security rules held.* Session text reaches the divider only as a text node, and
the divider's attributes are fixed words and the fold's open state. The fold's
number is an integer the daemon assigned. The key of a piece is the engine's, as
before. The page socket still admits one kind of event from an observer, a
click, at four places.

*The browser.* `<loom-follow>` tells a click on a divider from any other click
in the lane by a fixed `data-loom-fold` marker, as it does the older button's,
and takes the press as the reader's own move so the growth that follows does not
scroll the page past it. `<loom-fold>` stays, for the todo board's own fold,
which is a single line of text and opens locally.

## Costs

A press waits one round trip before the steps appear. The steps of a closed fold
are not in the page, so a browser's find-in-page does not see them. A fold the
reader opened is closed by the page when a later fold needs the room. A page
that had been left reading a turn of 2,000 steps shows its newest steps that fit
and says how many it left out; the terminal shows all of them.

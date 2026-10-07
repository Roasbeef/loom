# protocol-change/075: the context figure opens a breakdown, over one more page event

**Status**: ACCEPTED 2026-10-06 · **Affects**: the web view's page socket (the
observer's accepted events), the top bar's markup, and the rule that refreshes
the context board · **Raised by**: the owner, after a 24 minute turn showed
`ctx ~3%` while the real figure was 11% · **Implemented**: session view, web
view, client daemon page socket

## Problem

Two things were wrong with the context figure.

The board behind `ctx ~N%` was read when a session was first captured, when
the strand or its configuration changed, and when the active strand's operation
settled. A long turn therefore showed the reading from when it began. The rule
was written that way on purpose: a read costs the server a branch scan, and a
rule keyed on the leaf had cost a thirty-tool turn about sixty of them.

And the figure was only a number. The terminal's context panel says what fills
the window (the pinned prompt, the tools, the messages, the compaction
boundary, an item inventory) and the web page said none of it.

## Considered

**Refresh on every committed entry again.** It fixes the figure and brings back
the branch scan per tool call.

**Refresh on a timer while the strand runs.** It needs a clock of its own in a
package that owns none, and it reads when nothing changed.

**Refresh when a usage row lands, paced.** A provider usage row commits once per
generation, which is the moment the provider's own count of the context
changes. The usage ledger the cache watch already keeps records the highest row
admitted for each strand, so a row landing is a changed entry there and costs
nothing to detect. A tool result admits no row and starts no read. The rate is
bounded by a constant interval.

**Open the breakdown with a server event.** An observer's page admits one
`click` kind at four places already, and each admitted place is a security
surface. A native `<details>` opens in the browser and needs none.

## Decision

**Accepted.**

*The refresh rule.* In addition to the four transitions that already refresh the
board, a usage row landing on the live active strand starts a read when the last
automatic read of this selection is at least `surfaces.usage_refresh_interval_ms`
(30 seconds) old. The instant of an automatic read is kept on
`context_view.State` (`marked_ms`) and begins again with the selection. A row
inside the interval is not remembered (see the addendum): the next row after it, or the settling
edge, reads. A stale figure is therefore at most one generation and one interval
old. A tool result, streaming text and an unrelated capture start no read, as
before.

*The breakdown.* The top bar's context figure is a `<details>` whose summary is
the figure and whose body is `view/context_breakdown`: the headline
`Context window ~U / W (N%)`, the basis in words, one stacked bar, rows for the
pinned prompt, the tools, the messages, whatever the provider counted beyond
them, the compaction reserve and free space, the tokens until the session
compacts itself, a note that the rows are estimated one by one and need not add
up, and a closed list of the tools by name and the messages by kind, each
bounded at eight rows. It is drawn from the board the shared record already
holds, so it adds no wire field and no read. Tool names and message kinds are
text nodes; the one `style` attribute per segment is an integer percentage the
module computed.

*Two buttons.* Refresh marks the board stale and lets the shared step send the
read, as the terminal's `r` does. Compact now runs `/compact` through the shared
step's control arm (`component.CompactStrand`), which is the path a typed
`/compact` takes. The operator's page draws it. The observer's page does not
draw it, and its socket does not admit a click there.

*Admission.* The observer's socket admits a `click` at the Refresh button's
exact path (`component.context_refresh_path`), which asks only for a fresh read
of a board the page already draws and which the observer's lane makes at the end
of every turn. Compact now is the next sibling and is not admitted for an
observer. `page_events_test` and `ui_socket_test` fail if the view moves either.

## What it costs

At most one extra branch scan per thirty seconds of a live turn, for a page that
is attached. A page whose Refresh is pressed repeatedly coalesces behind the read
in flight. The panel is opened and closed by the browser, so an element
replacement by the runtime resets it to closed. The rows are estimates and the
panel says so; where the provider's count exceeds them the difference is drawn as
its own row and not spread across the others.

## Addendum (2026-10-06): a row inside the interval is deferred

The live critique of the batch (F180) found the header stuck at an earlier
turn's figure for over two minutes. A usage row that landed inside the
interval was dropped, so the header changed only if another row landed after
the interval ended, and a turn whose last generation fell inside it never
did. The rule above is amended: a row inside the interval is deferred to the
end of the interval. `context_view.State` carries that instant
(`deferred_until_ms`), the first transition at or after it starts the read,
and the web page arms its one timer for the earlier of the lane's due reading
and that instant. A strand that stops running drops the deferral, because the
settling edge reads the final figure. The read rate is unchanged: at most one
automatic read per interval.

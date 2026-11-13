# protocol-change/112 — page the strand roster out of the cut's cells

**Status**: PROPOSED, not implemented · **Affects**: the session lane's
snapshot metadata (`cells`, `strands`) and `session_view/snapshot_view` ·
**Raised by**: terminal scale measurement

## Problem

A client learns a session's strands from the register cells of one cut, and
`snapshot_view.decode` refuses a cut of more than 1024 cells ("too many
captured cells"). A strand owns about five cells (configuration, leaf, state,
operation metadata, and operation state or last result), so a session with
more than about 200 strands cannot be attached at all: the terminal reports a
refused capture instead of drawing a slow roster. The bound is why the
terminal's per-strand costs were measured at 150 strands and not 100,000, and
no client-side change can raise it. Every capture also carries every strand,
so the lane pays the roster's cost on each pushed notice however few strands
changed.

## What was considered

Raising the 1024-cell bound only moves the wall and makes every cut larger.
Sending the active strands' cells and a count for the rest keeps the cut
small but needs the client to ask for a strand it has not been sent.

## Proposal

The cut carries cells only for the strands a client can currently show: the
active strand, strands with a live operation, and strands with a pending
approval, at most 64. A new read, `strands_page` (offset, limit), returns the
remaining strands as `{id, name, phase, leaf_seq}` rows, a total count, and
the cut's `next_seq` it is consistent with. The client lists the rest from
those rows and requests a strand's cells by name when the operator opens it.

## Cost

A frozen snapshot shape changes, the web view and the terminal both read it,
and the gateway needs a paged read with the same cut-consistency rule as
`history`. The client side is ready for it: roster projections read cells by
identity from an index, so a cut with fewer cells costs less without further
change.

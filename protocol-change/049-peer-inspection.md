# Protocol 049: inspect exact peer grants through owner control

**Status**: Proposed implementation · **Affects**: v2 daemon control · **Raised by**: #485, #488

## Problem

Protocol 048 lets the owner grant, revoke and send through the control socket.
It does not let an operator read the resulting grants. The model's
`peer_roster` is bound to a running strand, so a CLI or terminal cannot use it
to inspect authority before changing it. An operator also cannot tell whether
an unavailable recipient still has a grant after source-side unlink.

## Decision

Add owner-only `peers.inspect` on the existing v2 control socket. The request
names one canonical resident session and exact strand, plus the current daemon
epoch:

```json
{"v":2,"id":1,"cmd":"peers.inspect","body":{"source_session":"<canonical-id>","source_strand":"main","epoch":"<current-epoch>"}}
```

The response body contains `source_session`, `source_strand`, source catalogue
`metadata`, `outgoing`, `incoming`, and `next`. Each outgoing row contains the
exact target `session`, `target_strand`, its catalogue `metadata`, and the
recipient's effective `wake` permission for that strand. It does not repeat
the recipient's other exported strands. An unavailable recipient remains in
the outgoing list with `wake: null`. Each incoming row names the source session
and strand, exact target strand, source catalogue metadata, and the
recipient-owned `wake` permission.

The initial request omits `after`. A non-null `next` is an opaque cursor; the
owner repeats the request with `"after":"<next>"` until `next` is `null`.
Rows are ordered by direction and exact endpoint coordinates, and the cursor
advances across both outgoing and incoming rows. Every page repeats source
metadata. The server budgets the complete serialized v2 reply to 60,000
bytes, below the protocol's 65,536-byte limit. A single row that cannot fit
is refused as `metadata_too_large`. Each page is a fresh observation, not a
snapshot: concurrent grant changes can appear or disappear between pages.

The server authenticates the owner and checks the epoch before resolving the
source. It reads the resident source's outgoing index and incoming grants
through harness-owned endpoints. It never opens a saved session. A saved or
unavailable source is refused. Subsequent send and link calls still check
current authority.

## Cost

The recipient Agency gains a read-only `Grants` endpoint command. Operators
can see incoming source coordinates and wake policy. A saved recipient cannot
report its current grant, so its outgoing row labels the recipient unavailable
rather than inventing a wake policy. This extension does not create wildcard
links, general session activation, or a second transport.

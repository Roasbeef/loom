# protocol-change/110: placed blobs and outcomes larger than a frame on the untrusted link

**Status**: PROPOSED 2026-11-06, built in the PR that adds this file.
**Affects**: the untrusted executor wire of [109](109-untrusted-executors.md)
(`untrusted_wire.version` 1 to 2): one new frame, three new requests and their
replies. `untrusted_gateway.Config` gains `blobs`, and `untrusted_link` gains
`start_placing`, which answers the subject blobs are placed through beside the
process. The remote node vocabulary of 078 (`client/remote/protocol`) and its
`version` are unchanged, and so is a trusted executor's wire.
**Raised by**: aegis, protocol-change/068 of that repository ("the jail runner as
a loom untrusted executor"), which found two things missing before its runner
can move onto 109: a carrier for large bytes that are not a Git state (its ask
L1), and a way to return a call's outcome when it is larger than one frame (its
ask L2).
**Builds on**: 107 (repository states moved in pieces, pulled and never pushed),
109 (the link, the gateway, bindings).

## Problem

An untrusted executor has no network egress and holds no credentials, so it can
fetch nothing for itself. Everything a session needs there has to come from the
orchestrator, once, and after that only what changed. 109 carries three kinds of
traffic: tool calls, owner callbacks, and 107's repository states. Two of
aegis's workloads do not fit any of them.

- **Bytes that are not a Git state.** A review job needs the Go module archives
  of the commit under review, about 200 MiB, and a proof needs a module cache of
  up to 1 GiB. These are tar archives, not repositories, and they are larger than
  a frame (32 MiB) several times over. Carrying them in a tool call's arguments
  would mean reassembling them inside the plane, which is a second copy of 107
  written by every integration.
- **Outcomes larger than a frame.** A fix proof returns up to 48 MiB of
  `go test -json` transcripts in one outcome. The gateway encodes every
  response as one frame, so an outcome whose encoding passes 32 MiB is sent as a
  frame the orchestrator's socket refuses. The orchestrator then closes the
  connection, sends the call again on the next one, and gets the same frame: the
  link never makes progress.

The checkout itself is a Git state and already has a carrier. A full bundle of
any commit of any repository applies into an executor's scope tree, whose
repository need not share any history with it; a later state can be thin
against the tip the executor was sent. This proposal does not change 107. The
test `untrusted_state_test` shows the case over the link (see "Tests"). Three
conditions come with it, none of them new:

- A capture's tip is `HEAD`. To send commit C, the orchestrator captures a
  checkout of C: a scratch clone or a detached worktree.
- The executor's workspace repository must have a commit, because the scope's
  tree is made with `git worktree add -b loom/<session> HEAD`. An empty
  `git init` has no tree to apply into. A runner seeds its workspace
  repository with one commit of its own; the checkout's history need not share
  it.
- Nothing reports which commits the executor holds. The orchestrator keeps the
  tips it sent and offers the newest as the thin basis; the apply refuses a
  thin state whose base the executor lacks, and the orchestrator falls back to
  a full one.

## What was considered

### Carry blobs as repository states (rejected)

A tar archive could be committed into a scratch repository and moved as a
bundle. It would then be applied into a workspace tree, which is the wrong
place for a module cache, it would be checked out through the sandboxed Git,
and the plane would have to know to find it there. A blob is simpler than a
state: it has no tip, no base and no apply.

### Let the plane carry chunks in tool calls (rejected)

This is aegis's alternative in its 068. It needs no change here, but every
integration would write its own reassembly, its own digest check and its own
disk bound, and the bytes would pass through the ledger as call arguments.

### Make blobs part of 078's vocabulary (rejected for now)

`StateChunk` is a `HostMessage`, so a trusted executor serves states too. A blob
could be the same, with a blob endpoint on every host. That changes
`protocol.version` and every trusted deployment for a carrier only the untrusted
mode has asked for. The executor's half of this proposal is a service the
gateway holds; adding a host endpoint later reuses it unchanged.

### Stream an oversized response as frames of one reply (rejected)

The gateway could split one encoded response into consecutive frames. The
orchestrator would then have to hold a half-received reply across a reconnect,
and a dropped connection would lose it with nothing to resume from. A fetch by
offset is resumable for free, as 107's `state_fetch` is.

### Keep the oversized response at the executor (rejected)

The gateway could keep the encoded outcome until the orchestrator has fetched
it. That is memory per response with an eviction rule, and an evicted entry
needs a way back. The executor's ledger already holds the outcome, durably, until
the orchestrator acknowledges it, so a piece can be cut from what a `Query`
answers.

## Decision

### Wire version

`untrusted_wire.version` goes from 1 to 2. The new frame and requests are
refused by a version 1 peer at the handshake, as 109 refuses any mismatch.

### Placed blobs

A **blob** is a sequence of bytes named by the lower-case hex SHA-256 of its
contents, with its size. The orchestrator places a blob for a session; the
executor keeps it, checks it, and hands the session's plane the verified file.

| Request | Reply |
|---|---|
| `blob_status` (binding, digest) | `Result(Stage, String)`: `absent`, `partial(held)` or `complete` |
| `blob_put` (binding, piece) | a verdict: `accepted(held)`, `stored`, `out_of_order(expected)`, `refused(reason)` or `failed(reason)` |

A piece carries the blob's digest and size, its offset and its bytes, so the
executor keeps no announcement and a resumed transfer sends the same words as
the first. A piece is between one byte and `untrusted_wire.max_piece_bytes`
(16 MiB), which with the base64 growth fits a frame; the orchestrator sends
pieces of `blob_transfer.piece_bytes` (8 MiB).

**Direction.** Only the orchestrator sends blob bytes. The executor answers a
status or a put and nothing else: there is no request by which it sends blob
bytes to the orchestrator, and nothing it can send names a blob. This is 107's
rule for states with the fetch half left out, because nothing has asked for it.

**The sender** (`blob_transfer.place`, run in the caller's process) hashes the
file first (`describe`), asks for the blob's stage, and sends the piece at the
offset the executor holds. `complete` ends the placement with no bytes sent, so
placing the same blob again, for this session or another, costs one exchange.
Each verdict says where to continue. The loop is bounded by the pieces the blob
needs plus `blob_transfer.max_resyncs` (8) corrections, and stops as stalled
beyond that. `refused` is final. `failed` and silence end the attempt, and the
next attempt resumes at what the executor holds.

**The receiver** (`blob_service`, one process that owns the store's directory)
judges each piece before the disk is touched:

1. The binding must be one this orchestrator's connection holds in the
   gateway's book (109's bindings, keyed by the pin the handshake admitted).
   The book answers the binding's session. Any other binding is refused.
2. The digest must be 64 lower-case hex digits, the size at least 1 and at most
   `size_limit`, and the piece must lie inside the size.
3. The binding **claims** the blob: from the first piece it sends that passes
   step 2, or from a status that finds it complete, the blob counts against the binding's and the
   orchestrator's bounds (below). A claim that would pass a bound is refused.
4. A piece at the offset held is appended. A piece wholly inside what is held is
   a repeat and is answered with the bytes held. A piece past it, or one that
   overlaps its end, is answered `out_of_order` with the bytes held.
5. The piece that reaches the size triggers the check: the half-written file is
   hashed in pieces and its size and SHA-256 compared with the description. A
   mismatch removes it and answers `refused`. A match renames it to
   `<digest>.blob`. A blob exists, by name, only after its bytes were checked.

**The plane's handle.** `blob_service.open(service, session, digest)` answers
the path of a held blob when a live binding of that session has claimed it. The
first `open` of a blob after the service starts hashes the whole file again,
because a rename is not a flush and a crash can leave a short file; later opens
use the result. The file is read-only to the plane by convention, and the
directory is masked from every jail like the state store (`placed-blobs` under
the state root, `workspace_policy.established_masks`). An integration whose
plane needs the blob extracts or copies it from there, with its own strict
extractor: the executor checks that the bytes are the ones the orchestrator
named, not that an archive is safe to unpack.

**Lifetime.** A claim lasts as long as its binding on the executor. A binding
retires when its session attaches again with a new owner port, which the book
already handled, and, new here, when the host carries out a close of its scope.
The book retires the binding only if it was made by an attach of the same
incarnation, so a late close never retires a newer open's binding, and the
proxy and its claims go with it. Claims are kept in
memory, so an executor restart loses them along with every binding, and the
orchestrator places again after its next attach. The status answers `complete`
and no bytes move. A placement sent after the restart and before the session
attaches again names a binding the executor no longer holds, and is declined
with that reason; it is final for that binding, not for the blob. A blob no binding claims stays on disk for `retain_s` (a
day) from when it was finished, so a second job that needs the same archives
finds them; a half-written file that has not grown for an hour is removed.

### Bounds and disk accounting

| Bound | Default | Counted as |
|---|---|---|
| One blob | 1 GiB (`size_limit`) | the declared size |
| The directory | 8 GiB (`total_cap`) | every file on disk, finished or half-written |
| One binding | 16 blobs and 2 GiB | the declared sizes of the blobs it claims |
| One orchestrator (one link) | 64 blobs and 4 GiB | the declared sizes its bindings claim |

A blob two bindings claim is one file on disk and counts against both bindings'
bounds, because each binding is asking for the room to use it. The directory's
cap is the only bound on disk; the per-binding and per-orchestrator bounds keep
one session, or one of the up to 32 orchestrators an executor serves, from
taking all of it. Nothing is evicted to make room: a blob some binding claims is
never swept, and one that does not fit is refused with a reason that names the
bound.

### Outcomes larger than a frame

When the gateway's encoded response to a request would exceed
`max_frame_bytes`, it sends a new frame instead:

| Frame | From | Carries |
|---|---|---|
| `oversized` | executor | the request id, and the size and SHA-256 of the encoded outcome |

and the orchestrator fetches the outcome in pieces with a new request:

| Request | Reply |
|---|---|
| `outcome_piece` (key, offset) | `served(size, digest, offset, bytes)` or `not_held(reason)` |

The executor answers `outcome_piece` by asking its host `Query(key)`, the
ledger's read that never starts or joins a call. A `Terminal` outcome is encoded
the same way every time (`untrusted_codec.encode_outcome_bytes`), and the piece
at the offset, at most `max_piece_bytes`, goes back with the size and digest of
that encoding. Anything else is `not_held`.

The orchestrator's link:

1. Accepts `oversized` only for an id it issued and holds, whose request is a
   `run`, `query` or `query_or_fence` and so names a key. For any other request,
   and for a size above `untrusted_wire.max_outcome_bytes` (96 MiB), it answers
   the asker with the lost form of its reply (`RunLost` for a run, `Unknown` for
   a lookup, an `ExecutorFault` refusal for anything else) and logs it. The
   executor did run the call, so the answer is never one that invites a re-run.
2. Fetches at most two outcomes at once. A further `oversized` waits for a place.
3. Asks for the piece at the bytes it holds. A piece of another size or digest
   than the fetch began with restarts the fetch from that piece's description,
   at most three times. A piece at another offset than the one asked is asked
   for again. The steps one fetch may take are bounded, so an executor that
   never converges ends the fetch with the lost answer.
4. When the bytes held reach the size, compares the SHA-256 with the digest and
   only then decodes the outcome, with the codec's total decoder, and delivers
   it to the asker as `RunFinished` or `Terminal`.

**The host must hold the outcome.** An outcome only reaches the wire if the
executor's host kept it: the host replaces a result larger than its
`max_result_bytes` with a "too large" outcome before the ledger stores it, and
`loomd`'s host keeps the default of 16 MiB, under a frame. An integration that
returns larger outcomes, as aegis's proofs do, starts its host with
`max_result_bytes` raised to what it returns (at most `max_outcome_bytes`).
`loomd` has no key for it yet, because no plane of Loom's own returns more.

**Requests and answers the link sends** are held to the same bound. A request
whose frame would pass `max_frame_bytes` is refused to its asker at once
(`Invalid`) and never kept, and an owner's answer that would is replaced by
the callback's failure. Kept, either would close the connection on every send
and be sent again on every reconnect.

**Same behaviour as `run`.** The original request stays outstanding while its
outcome is fetched, with its asker's monitor, so:

- *Idempotency.* A piece is cut from the ledger's stored outcome by key and
  offset. Asking twice gets the same bytes.
- *Cancellation.* When the asker dies, the link drops the request and cancels
  the original id and the piece in flight. The gateway kills their waiters. The
  call has already ended, so nothing is aborted.
- *Partition.* Piece requests belong to one connection and are not re-sent. The
  original request is, as 109 re-sends every outstanding request, and the
  executor answers it again with `oversized`. A fetch that holds bytes for the
  same size and digest continues from them; one for a different digest starts
  over.

A fetching request no longer counts as a call in flight for the callback checks
of 109 (check 3), because its call has ended.

## Threat model

The executor is assumed wholly hostile, as in 109.

**What a hostile executor can do with a blob request.**

- Read the blob. It was sent to be used there.
- Lie in its answers: claim a blob is `complete` that it never stored, accept
  pieces it throws away, refuse every piece. The effect stays on that executor
  and its sessions, which already depend on it for everything.
- Steer the sender's offset with `out_of_order` and `partial`. Each answer makes
  the orchestrator read and send at most one piece of the file it chose to send;
  the offset is checked to lie inside the blob, and the corrections are bounded
  by `max_resyncs`. It cannot make the orchestrator read any other file, or any
  byte outside the blob.
- Answer slowly, or not at all. The sender's exchanges are bounded by the
  caller's wait.

**What it cannot do with one.** Push a blob, or any bytes, to the orchestrator:
there is no request for it. Name a file on the orchestrator: the orchestrator
chose the path, and the executor only sees a digest. Make the orchestrator hold
more than one piece of a blob in memory per placement.

**What a hostile executor can do with an outcome fetch.**

- Return an outcome of its choosing, as it can for any call; the digest proves
  only that the bytes are the ones it described.
- Make the orchestrator receive up to `max_outcome_bytes` per fetch and hold up
  to two fetches at once, about 192 MiB in all, then decode one outcome of up to
  96 MiB. That is three times one frame's decoded cost of 109's residual risks.
- Force restarts and repeats. Both are bounded, and the end is the lost answer.

**What it cannot do with one.** Send outcome bytes for a request the
orchestrator did not make, or before it asks: `oversized` is accepted only for a
held id, and pieces only as replies to the link's own `outcome_piece`. Get a
re-run: every way a fetch can fail answers the asker with the lost form.

**What an orchestrator can do to an executor** is bounded by the table above.
Each orchestrator is pinned, so this protects the executor's other orchestrators
and sessions from one that misbehaves, not from an attacker.

**Residual risks.**

- Claims are in memory. An executor that restarts forgets them and the
  orchestrator must place again; until it does, the plane's `open` refuses.
  Placing again moves no bytes.
- `open` hashes a blob once per service lifetime. A process on the executor that
  can write the store's directory after that can change a blob under the plane.
  On an untrusted executor that process already owns the plane.
- One outcome of up to 96 MiB is decoded in full on the orchestrator. Breadth is
  as unbounded as it is for one frame (109, "One frame's decoded size").
- A claim can outlive its binding. The gateway asks its book for a binding's
  session and then hands the piece to the keeper; a re-attach or a close that
  retires the binding in between releases its claims first, and the piece then
  claims the blob again for a binding no `release` will name. The leaked claim
  counts against that orchestrator's own bounds until the executor restarts.
  Closing it needs the keeper to remember retired bindings, which is more
  machinery than a re-attach in the middle of a placement warrants.
- An orchestrator that never comes back keeps its bindings, as 109's proxies
  already do, and now its claims: up to `link_bytes` that the sweep may not
  remove until the executor restarts. Releasing them when its connection drops
  would take a blob from a plane in the middle of a partition. Two such
  orchestrators fill the default directory, and later placements are refused
  with a reason naming the cap.

## What it costs

About 2,500 lines with tests: a blob store and its service on the executor, the
sender's loop and the outcome fetch on the orchestrator, and three requests, one
frame and their codecs. Every placement hashes its file once on each side. An
oversized outcome is encoded once for the frame that would not fit and once per
piece, and its ledger row is read once per piece: for a 48 MiB transcript of
four pieces that is a few seconds, beside an hour's proof.

## Tests

`untrusted_codec_test` round-trips the new frame, requests and replies and
refuses malformed digests, sizes and offsets. `blob_service_test` drives the
receiver over a real directory: a wrong digest, an oversized piece, a gap, a
repeat, each bound, a claim's release and a restart. `untrusted_link_test` adds
a hostile executor that answers a blob put with a backwards offset, an outcome
fetch with a wrong digest, an oversized piece, a piece nobody asked for, a
replayed `oversized` and an `oversized` for an id never issued, a cancel after
a reconnect, and a fetch's place freed by a whole answer, which goes to the
waiting fetch; each is refused or bounded and the link survives. It also
refuses a request larger than a frame instead of keeping it.
`untrusted_end_to_end_test` places a blob through the real link and gateway and
opens it on the executor, and returns a 40 MiB outcome through a real host.
`untrusted_state_test` sends a full bundle of a repository the executor's
workspace shares no history with, then a thin one, through the link, and
applies both into the scope's tree.

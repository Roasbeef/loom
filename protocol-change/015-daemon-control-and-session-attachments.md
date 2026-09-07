# protocol-change/015: separate daemon control from session attachments

**Status**: ACCEPTED 2026-09-05 · **Affects**: Part 1.6 client protocol ·
**Raised by**: single-daemon and multiplayer execution ruling · **Implementation**: daemon and TUI implemented; independent review and release acceptance remain open

## Problem

The current listener captures one gateway in its request handler. Its
`/v1/ws` endpoint cannot list saved sessions, explicitly open a closed one,
or distinguish a replacement runtime from the runtime a client previously
used. A token authorizes that whole gateway, without a server-owned
principal or a session role.

One daemon needs two distinct connections: a control connection for saved
metadata and lifecycle requests, and a conversation connection bound to one
resident session. Listing must remain usable while a session starts or
drains. Reconnecting must not silently restart work after a daemon crash.

## Proposal

Replace `/v1/ws` with two authenticated WebSocket endpoints on one listener:

```
/v2/control
/v2/sessions/<canonical-session-id>/ws

c→s: {v:2, id:<positive integer>, cmd:<name>, body:<object>}
s→c: {v:2, reply_to?:<id>, event:<name>, seq?:<session seq>, body:<object>}
```

The daemon and TUI ship together. There is no v1 adapter or separate legacy
server mode. Unsupported versions fail clearly; existing user databases
are not deleted or rewritten merely because their launcher record is old.

### Control requests

The server authenticates the HTTP upgrade before constructing connection
state. Its initial `hello` event identifies protocol version 2, daemon
epoch, authenticated principal, and advertised limits. A cleartext listener
binds only loopback. Remote deployment requires TLS at a trusted endpoint;
an invitation never permits bearer credentials over unprotected TCP.

| Command | Body | Result |
|---|---|---|
| `status` | `{}` | Daemon epoch, readiness, and capacity counts. |
| `sessions.list` | `{after:"", revision?:N}` | At most 100 authorized records, catalogue revision, and continuation ID. |
| `sessions.get` | `{session_id}` | Authorized metadata and current lifecycle status. |
| `sessions.default` | `{workspace}` | Owner-only workspace default lookup; never opens it. |
| `sessions.set_default` | `{workspace,session_id}` | Owner-only durable selection; never opens it. |
| `sessions.create` | `{request_key,workspace,name,configuration}` | Owner-only reservation and explicit initialization/open operation. |
| `sessions.open` | `{session_id,epoch}` | Explicit open or the already accepted operation/incarnation. |
| `sessions.stop` | `{session_id,epoch}` | Owner-only stop request, with database preserved. |
| `operations.get` | `{session_id,operation,epoch}` | Current authorized observation of that lifecycle operation. |
| `daemon.shutdown` | `{epoch}` | Owner-only daemon drain request. |

The server assigns database paths beneath its private session directory.
Client labels never become filenames. Creation keys are durable: a retry
recovers the original identity, path, and creation time before allocating
anything. Reusing a key with different metadata returns `conflict`.
An incomplete reservation survives restart and requires an explicit create
retry; ordinary open refuses it until initialization has completed.

List and default responses read metadata only. The server never opens a
conversation database to answer them. Catalogue invalidations carry a
revision, contain no unauthorized session identifiers, and are hints rather
than durable events. A client subscribes before its first page, restarts a
listing when revisions differ, and relists after reconnect.

Opening, resident, stopping, and recovery-blocked states are live registry
observations, not claims persisted in the catalogue. Concurrent opens share
one operation. Stop retains capacity until the original cleanup witness
confirms retirement. A caller timeout does not cancel cleanup or free a slot.
Operation IDs contain the daemon epoch and a unique opening nonce. A request
for an old operation cannot observe a replacement as though it were the old
one; it returns `stale_operation` or `stale_epoch`.

### Session attachment

The session route resolves only a resident, authorized gateway. Opening is
a separate control request. The attachment identifies the session ID,
daemon epoch, incarnation, principal, role, and a fresh connection ID.
Neither a command body nor an old resume cursor can retarget that socket.

The existing prompt, steer, follow-up, abort, approval, strand, model, and
schedule command vocabulary remains, now under version 2. The server
checks session membership when admitting every command. An observer may
subscribe, catch up, and read state; mutations return `forbidden` before a
durable write or effect dispatch. A session invitation grants no catalogue
management, shutdown, or cross-session authority.

Revocation is ordered with admission at the gateway. Commands admitted
before the revocation may finish; later commands are refused and affected
attachments close. Revocation cannot undo an already completed external
effect. Authentication determines the principal; a client-supplied display
name or origin never changes that authority.

### Bounded snapshot transfer

Replace the single unbounded full-snapshot frame with a transfer tied to one
snapshot ID, incarnation, and durable high-water:

```
snapshot_begin {snapshot_id, session_id, incarnation, next_seq, ...metadata}
snapshot_chunk {snapshot_id, index, entries:[...bounded records...]}
snapshot_end   {snapshot_id, chunks}
snapshot_next {snapshot_id, index}
```

The gateway fixes the durable high-water before the first chunk. Each
`snapshot_next` requests the next chunk; it does not cause historical rows
to accumulate in a socket mailbox. Durable writes after that cut are read
through bounded catch-up before live delivery. Sparse sequence numbers are
valid, so a numeric gap does not by itself imply lost events.

Each connection retains at most one transfer. A transfer expires after 30
seconds without progress, and a mismatched ID/index returns
`stale_snapshot`. Entries too large for one frame require bounded record
fragments with explicit total length; the receiver rejects a total above
the advertised record limit before allocating it.

Control and observer frames/messages are limited to 64 KiB. Operator
frames/messages are limited to 32 MiB, which accommodates the existing
20 MiB total image-attachment allowance after base64 encoding. Outbound
snapshot chunks are limited to 256 KiB and reassembled records to 32 MiB.
These are per-connection limits; admission must also bound aggregate
connection and parser memory before enabling the default. Chunking alone
is not a transport memory bound.

The TUI adopts a replacement view only after authenticated metadata and a
complete snapshot. Each attempt owns its inbox and deadline. Failed or
superseded attempts cannot alter the current view. Reconnect to a new
daemon epoch discards ephemeral state and requires an explicit open or
selection before any saved work resumes.

### Multiplayer events and mutation outcomes

An attachment snapshot includes the server-owned principal, session role,
and transient roster. Presence events distinguish connections belonging to
the same principal. Reconnect replaces the roster; joins and leaves are
not conversation entries.

Successful shared configuration changes broadcast their authoritative
value to all attached clients. Approval and denial compete through the
existing conditional durable transition; exactly one wins, and the loser
receives a conflict naming the resolved request. Durable human origin must
travel through user turns, queued steers, and approval resolutions. The
corresponding frozen durable/API type additions require their own proposal
before implementation; this transport proposal does not silently add them.

A lost mutation reply leaves an unknown outcome. The client reconciles
durable state and does not automatically resend prompts, steers, forks, or
approvals. Creation is the exception because its request key is durable.
No claim of exactly-once external execution follows from either rule.

## Impact

The listener, gateway, TUI protocol codec, connection handshake, bootstrap,
and session selector move together. Protocol fixtures and real-WebSocket
tests must use v2. The catalogue uses generated SQL; no runtime SQL strings
implement control requests. Release/bootstrap tests must prove that two
workspaces reuse one daemon, then prove metadata-only restart followed by
explicit lazy opening.

Multiplayer verification uses independent TUI drivers against real sockets
and SQLite: two operators on one session, another session, an observer,
configuration convergence, approval races, reconnect, and membership
isolation. The final live Herdr drive complements these tests.

## Alternatives considered

One multiplexed socket was considered. Separate connections keep a session
stream bound to one incarnation and let replacement handshakes finish before
the old view is detached. Routing every conversation frame through the
manager was rejected because slow session work would then share the daemon's
admission queue. Automatically reopening on reconnect was rejected by the
owner's restore-catalogue/lazy-open ruling.

## Decision

**Accepted.** The owner approved this protocol and the required transport
dependency extension on September 5. Separate control and session sockets
preserve explicit lifecycle admission and atomic view replacement. The
rejected multiplexed and implicit-reopen alternatives are recorded above.

## Addendum: credited reconciliation and record fragments

**Accepted 2026-09-05.** The owner delegated this in-scope wire decision to
the primary after critique. A connection uses stop-and-wait delivery for its
initial snapshot, catch-up and subsequent live reconciliation. Every command
receives at most one bounded response. The socket waits for admission on its
original gateway subject before reading another frame; a missing response or
timeout closes the socket and never retries a mutation.

`subscribe` and `catch_up` begin a transfer. `snapshot_begin` carries its ID,
canonical session, epoch, incarnation, durable cut and limits, including the
authenticated attachment identity. `snapshot_next {snapshot_id,index}` grants
one response. Each `snapshot_chunk` carries one base64 fragment with its kind
(`metadata` or `entry`), record ID, total byte length and byte offset. Metadata
is fragmented too: a bounded one-MiB capture is not a valid observer frame.
`snapshot_end` closes the transfer. An idle client requests another catch-up
periodically; this costs a bounded metadata capture even when no entries moved.

The initial window is explicitly partial: at most 100 recent descriptors, not
the parent closure or the whole history. `complete_history` is false, and
unknown parents remain unloaded. `history {after_seq,before_seq}` requests one
ascending page between exclusive bounds; `more_after` permits another page.
Every chunk carries `record_seq`: null for metadata, the descriptor's durable
sequence for entries. A client may retain a bounded unloaded placeholder for
a record it cannot materialize, without decoding its entire body. Idle clients
request reconciliation every 250 milliseconds while no transfer is active.

Immutable entries travel in their raw core-codec form. They belong to the
shared conversation tree, not to an invented single strand. Captured strand
leaves and live operations describe strand state; clients index entries by ID
and parent rather than accepting the old first-branch attribution heuristic.
Usage is the cumulative total from the coherent cut. Configuration values,
their origin cells and pending escalation sequences come from that same cut.
Presence is transient and is not claimed to share the storage transaction.

After completing a cut, catch-up scans entries between the previous and new
high-water, in ascending bounded descriptor pages. A client deduplicates entry
IDs/sequences and replaces metadata only after completing the transfer. It
must still reconcile when the entry high-water has not moved: metadata-only
changes are meaningful. Writes during transfer remain above its fixed cut
and belong to the next reconciliation, never to an unbounded live backlog.
The interval is `[old.next_seq,new.next_seq)`: the reader's exclusive lower
bound is therefore `old.next_seq - 1`, not `old.next_seq`.

A connection retains only one transfer. Its absolute deadline is 30 seconds
from capture and does not reset with fragments. Admission checks the deadline,
and one Weft heartbeat also expires retained state by scanning the bounded
connection book, so there are no per-client timer handles. A slow transfer
therefore fails explicitly and requires a new request rather than adopting a
partial view.

Reader exchanges wait at most five seconds and, for continuations, no longer
than the remaining transfer budget. A continuation is never funded below the
reader minimum: when the transfer has less than that left, the step answers
an exhausted refusal instead of issuing a read, so a client cannot turn its
own deadline into evidence about the reader. Timeout is not cancellation: the
original SQLite request may remain queued or running. Only a reader that was
given its whole budget and did not answer, or an unavailable reader, is
treated as wedged; that permanently poisons the gateway, closes attachments
and requests an atomic stop of its original incarnation. A timeout on a
caller-paced remainder answers that request with `snapshot_failed`, drops
that one transfer and touches nothing else. The callback acknowledges
`Stopping` and never waits for its own retirement, because the original
custody must drain before reopen; lost proof retains `RecoveryBlocked` rather
than starting a fresh reader.

Mutation responses distinguish admission from completion. Lost responses have
unknown outcomes and must not cause automatic mutation retries. Durable
results are reconciled through the credited stream. Any retained ephemeral
provider fragment is bounded and reports truncation; it is not a durable
delivery promise. Authentication is checked at each request and response.

Network gateways subscribe to neither writer commit hints nor event-bus hints.
The provider relay forwards every authoritative delta to its real consumer in
order, but offers only one optional preview while its observer callback is
busy. Further preview observations are therefore omitted; the terminal is
retained and never reordered or dropped.

Each observer acquires one of sixteen leases on the original gateway, and an
expired admission request allocates nothing. Each lease allows one outstanding
synchronous payload of at most 24 KiB, and a timeout stops future sends from
that source. Its original monitor remains until observer death or acknowledged
ordered release, so queued payloads cannot overlap a replacement lease.
Metadata's optional `stream_preview` contains revision, operation, text and
`discontinuous:true`, so clients display it as a standalone preview and never
concatenate nonadjacent fragments.

These observation bounds do not claim to bound the provider-to-relay mailbox
in bytes of BEAM memory. The built-in SSE parser separately caps cumulative
raw response bytes at 16 MiB per attempt. Arbitrary injected providers and term
overhead are outside that raw-byte guarantee.

Aggregate admission must account for retained capture, encoded metadata,
descriptor page, raw fragment, encoded response and any ephemeral slot, in
addition to the parser's inbound message budget. Bounds on encoded metadata
must account for JSON escaping before serialization. These are accounted
payload limits, not a claim about exact BEAM resident memory.
The root reserves an additional 8 MiB delivery allowance for each session
connection. The copy envelope includes old/new coherent captures, bounded
encoded metadata (2 MiB maximum each), one 190-KiB backend fragment, one 64-KiB
reply, descriptors and one preview slot. The sixteen-source ingress allowance
is another 384 KiB within this envelope, not sixteen uncharged payload queues.

`escalations_get {ids:[...]}` reads one to eight exact escalation keys through
the same bounded reader. Its transfer has `window:"escalations"` and no history
descriptors. Metadata contains found cells, including each current sequence
and resolution origin, and an explicit `missing` list. The receiver updates
only those questions; it does not replace its history cursor or full pending
projection. Exact selection avoids prefix neighbors and never captures the
unbounded history of every resolved question. A missing record does not name
an author. Authorization, gateway-failure behavior and continuation limits are unchanged.

Verification must include metadata larger than 64 KiB, fragmented large
entries, forbidden whole-history reads, a blocked receiver, writes during a
transfer, metadata-only changes, stale continuation IDs, absolute expiration,
and authorization or incarnation loss. The default network path has no v1
or unbounded snapshot fallback.

## Addendum: owner-managed member access

Accepted after independent review: every administration operation reauthenticates
the owner's credential, compares the daemon epoch, and performs its durable
mutation in one serialized registry dispatch. A check in the WebSocket handler
alone is insufficient because credential state can change before dispatch.
Draining daemons refuse these mutations.

The bounded control commands are:

- `sessions.invite {session_id,principal_id,name,role,epoch}` creates a member,
  its first credential, and one session membership atomically. Role is
  `operator` or `observer`, never owner.
- `sessions.set_role {session_id,principal_id,role,epoch}` changes one
  membership. `sessions.revoke {session_id,principal_id,epoch}` removes it.
- `credentials.rotate {principal_id,epoch}` revokes every active credential
  belonging to that member and inserts one replacement in the same transaction.
  `credentials.revoke {principal_id,epoch}` revokes them without replacement.

Owner credentials are excluded from these member operations: the private
owner-token file has a separate lifetime. An invitation grants no membership in
other sessions, even within the same workspace. Shared-memory authorization is
a separate policy decision, not an implied consequence of invitation.

The caller chooses and retains the bounded principal ID before sending an
invitation. IDs remain reserved after revocation. Repeating an invitation is an
explicit conflict, not a new credential or an implicit membership update. If
the successful reply is lost, the caller can recover that known identity by
explicitly rotating its credentials. A timeout is an unknown outcome; clients
must not retry secret-producing mutations automatically.

Only a successful invitation or rotation reply contains the fresh bearer,
alongside `principal_id` and `name`. Other successful administration replies
contain those nonsecret identity fields without a bearer. The catalogue stores
SHA-256 digests only, and revoked digests remain tombstoned. Logs, errors,
status, and listings must never contain bearers. An insertion failure during
rotation rolls back the preceding revocations.

The terminal administration entrypoint is `loomd access`. It connects to an
existing local daemon through the private endpoint and owner-token records;
it neither starts a daemon nor opens a conversation. It shares the existing
Stratus/Weft transport with the TUI. Remote administration is not an implicit
cleartext fallback; a future remote entrypoint must enforce trusted TLS.

Authorization changes take effect at the next command, transfer continuation,
or delivery check. An attachment closes when its original role changes or its
credential or membership is revoked. A command already admitted before that
boundary may finish; revocation is not cancellation of previously admitted work.

## Accepted addendum: explicit private and session-only domains

The catalogue records a domain independently of its running sessions. Each
record fixes its workspace, configuration reference, memory path, index path,
and scope. A session-to-domain mapping survives daemon restart without opening
any of those files. The configuration reference is captured at creation,
including an explicit no-configuration choice; the first session opened cannot
choose or replace another session's domain configuration.

`sessions.create` accepts optional `domain_scope`: `workspace_private` (the
default) preserves the owner's workspace aggregate, while `session_only`
selects fresh per-session memory and index paths. Existing workspace mappings,
including imported paths, remain authoritative. Owner metadata exposes the
scope, not private file paths. There is no wider shared-domain enrollment API.

Both `sessions.invite` and the membership-upserting `sessions.set_role` require
`session_only`. The manager checks this in the same serialized dispatch as
owner authentication, epoch validation, and the mutation. A private mapping
returns `isolation_required`; being a member of another session in the same
workspace grants no access here. Credential revocation and rotation do not
require isolation.

An owner can send `sessions.isolate` with `session_id`, `epoch`, and the exact
acknowledgement `transcript: "share_existing"`. No retained runtime slot may
exist, including a stopping or recovery-blocked slot. Isolation preserves the
conversation and its configuration reference, creates only fresh domain
metadata, and copies no aggregate memory or index files. Repeating the request
returns the same mapping without rotating paths. The CLI spelling is
`loomd access isolate SESSION --share-existing-transcript`.

Isolation is prospective, not sanitization. The existing transcript may already
contain private recalled text or assistant output derived from it. The explicit
acknowledgement authorizes sharing that transcript; it does not claim to remove
past information. Independent review rejected both implicit workspace sharing
and filtering history after aggregate summaries had already been shared. It
also rejected creation-only collaboration because it would prevent intentional
sharing of existing sessions.

Domain source enumeration includes only saved registrations, with that filter
applied before pagination. Reserved registrations are not maintenance inputs:
opening their missing paths could create conversations that were never admitted.
Actual memory/history resource wiring must enforce the mapped scope as well;
the metadata invitation guard alone is not a claim of complete recall isolation.

The internal assembly capability receives the immutable domain record captured
by the registry before host preparation. No catalogue handle reaches the builder.
Managed settings retain exact memory/index paths rather than deriving them from
a workspace directory. This internal composition change implements this addendum;
it does not add a conversation-wire fallback or change the frozen Storage API.

### Correction: runtime configuration is not domain configuration

The initial assembly ruling incorrectly applied the domain's configuration to
every member session. That would make a second session ignore its own explicit
provider/tool configuration and use whichever session first established the
workspace domain. Review found this reachable path before resource integration.

Session runtime resolution therefore remains independent: an explicit
`Registration.configuration` wins; an empty registration retains the existing
daemon session-default behavior. The domain configuration instead belongs to
shared maintenance services and must be resolved exactly, with empty meaning no
configuration file. This change does not claim to freeze runtime defaults at
session creation. A resolution regression uses valid session-B configuration
and an invalid domain-A configuration while preserving the domain's exact paths.

### Implementation correction: empty creation configuration

The runtime-default rule above also applies to `sessions.create` on the
control wire. Its `configuration` field is required bounded text, but may be
empty; request keys, workspaces and names remain nonempty. The TUI encoder
and daemon decoder incorrectly rejected that existing representation. The
daemon also tried to canonicalize it as a filesystem path. The repair accepts
empty configuration unchanged and retains the 4,096-byte bound for explicit
paths. No envelope version, catalogue schema or stored record format changes.

Local clients resolve their trusted default catalogue before creation, even
when attaching to an existing daemon. They never select a workspace catalogue
implicitly. An empty reference remains available when no trusted file exists
or a remote owner client requests the daemon's defaults.

## Accepted addendum: retained domain ownership and status

The registry admits at most one resource owner for each retained domain. Its
domain capacity equals its session capacity. Preparing, running, quiescing,
closing, and blocked domains all occupy that capacity; waiting sessions also
occupy session slots. Listing the catalogue still opens no domain resources.

Each domain publishes shared history and optional maintenance cleanup before
beginning those effects. Sessions receive the original shared history capability
and send session-bound commit notifications. They do not acquire a second index
owner or start a separate maintenance cadence. History resolves the bounded
source list afresh and authorizes sources before ranking or exact reads.

A session's normal custody retirement permits its clean-close notification.
After the last dependent session retires, the registry quiesces maintenance,
waits for the current and already-coalesced work, then cancels the domain host.
Normal domain retirement releases capacity. Failed cleanup retains the original
reservation; a caller timeout does not establish retirement. Normal daemon
shutdown drains sessions before domains. A later admission may create a fresh
domain owner and perform another cursor-based maintenance pass.

The control `status` response adds three nonnegative integer fields:
`domain_capacity`, `domain_occupied`, and `domain_blocked`. The existing session
counters keep their meaning. `domain_occupied` counts every retained domain slot,
including a normally
retired domain whose dependent sessions have not yet retired. `domain_blocked`
counts slots with a reported failure or lost cleanup proof; ordinary preparation,
quiescing, and closing do not count as blocked. An already-observed normal domain
retirement never becomes blocked because a late result or fault arrives.

These counters explain why admission can be refused when session occupancy is
zero. They expose no domain identifiers or paths and remain observations, not
admission permissions. In particular, `Saved` proves session retirement, not
domain retirement. A caller awaiting all shared cleanup must also observe zero
domain occupancy or the original normal daemon shutdown witness.

The catalogue reserves the derived `loom-memory.digest` sidecar alongside each
domain's memory and index paths. Cross-column conflicts are checked in the same
metadata transaction, so importing an index path cannot overwrite another
domain's digest. Isolation copies none of these files.

Public-custody tests exercise cancellation while two sessions wait, last-close
cleanup, retained failures, and domain capacity. A real two-session SQLite test
checks that one original history owner survives the first session's close and
retires before normal daemon shutdown completes. The exact ordering in which
normal witness delivery precedes a builder result is source-reviewed, not a
deterministically scheduled test: the two messages have different senders.

A joined manager/cadence test holds the initial real pass, closes two sessions,
then holds the coalesced final pass. Both original domain resource owners remain
alive until that final pass settles. Only then does the original custody witness
retire normally and domain occupancy reach zero.

## Addendum: reader timeouts are classified by whose budget expired

The independent review of the pinned daemon slice found that a continuation
could fund a reader exchange with the last few milliseconds of its own
transfer budget, and that the resulting timeout was treated as a wedged
reader. An observer could stop an operator's session by timing one frame.
The rule above now names the floor and the two classes: a read below the
reader minimum is not issued, a timeout on the reader's full budget poisons,
and a timeout on a caller-paced remainder fails only that request. The wire
shape is unchanged; only the server's classification narrowed.

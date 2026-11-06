# protocol-change/109: untrusted executors over a non-distribution link

**Status**: PROPOSED 2026-11-06. Slice 1 is built in the PR that adds this file:
the link, the gateway, the wire and its codec, the configuration, and the tests
named under "Tests". Background code mode, remote evolution and the commands
that non-tool callers run through the executor's broker are not carried yet; see
"Slices".
**Affects**: `loom.toml` (one new table on each side, and three keys on
`[executors.<name>]`), a new framed wire between an orchestrator and an
executor that is not Erlang distribution, and two new processes, one on each
side. The remote node vocabulary of [078](078-distributed-runtime.md)
(`client/remote/protocol`) is unchanged, and so is its `version`: the link
carries those messages, it does not change them. No Part 1 interface and no
client control protocol command changes.
**Raised by**: aegis, a security-review service built on Loom, whose jails run
model-written proof-of-concept tests and agent Go commands against pull
requests from outside contributors. Its owner ruled that those jails run in a
pod that holds no credentials and is never a distribution peer (aegis ADR-003,
addendum 2), so aegis built its own copy of the executor plane over HTTP. The
copy keeps producing bugs that Loom's plane does not have; the latest dropped
every hit of a remote `search_text` because the runner's output paths were
never mapped back.
**Builds on**: 078 (the cut at `ToolSurface.run`, the executor host, the owner
port), [107](107-state-transport.md) (repository states moved in pieces).
**Issue**: loom #1196.

## Problem

Loom's executors join their orchestrators over TLS Erlang distribution and are
mutually trusted (`docs/architecture/distributed.md`, "Trust and transport"). A
connected node has the full privileges of an Erlang peer: it can spawn processes
and call any function on the other node. Compromising an executor's VM
therefore compromises every orchestrator it talks to, and the operator accepts
that when enrolling a machine.

Some deployments cannot accept it. An executor that runs attacker-influenced
code all day has to be assumed compromised sooner or later, and a jail escape
there must gain nothing beyond the sessions that were placed on it: not the
orchestrator's provider keys, its session store, its hook trust record, other
sessions, or the means to run code on the orchestrator. Distribution cannot
express that, because there is no such thing as a partly trusted Erlang peer.

## What was considered

### Harden distribution (rejected)

Erlang distribution can be narrowed with a custom `-proto_dist` module that
filters control messages, but `spawn_request` and `exit` signals are part of the
protocol itself, the atom cache lets a peer create atoms, and every term a peer
sends is decoded by the emulator before any Loom code sees it. A filter would be
a second protocol implementation with the first one still underneath it.

### HTTP/2 over mTLS (rejected for now)

HTTP/2 gives multiplexed streams and flow control, and a gRPC-shaped service is
familiar to operators. But the conversation here is not request and response in
one direction: the executor calls back into the orchestrator in the middle of a
tool call, and the executor must never dial. HTTP/2 would need the executor's
callbacks to ride as long-lived server-to-client streams, or the orchestrator to
poll. Neither the tree nor its dependencies hold an HTTP/2 server that verifies a
pinned client certificate, so the choice would add a dependency and a server to
the executor's attack surface for a property (multiplexing) the frames below get
by carrying an identifier.

### A typed RPC per filesystem operation (rejected)

This is what aegis built and what 078 rejected as PR #819: it puts paths on the
wire, and the mapping between the two machines' paths is where aegis's bugs
live. The cut stays at `ToolSurface.run`.

### A framed stream over mutual TLS, carrying 078's vocabulary (accepted)

One TCP connection, dialled by the orchestrator, TLS 1.3 with a certificate on
each side, and length-prefixed frames of JSON in both directions. The frames
carry the requests and replies that 078 already defines, with every `Subject`
removed and replaced by a number or a binding the orchestrator chose. Both ends
reuse what exists: the orchestrator's surface, scope record and owner port, and
the executor's host, ledger and workspace plane, none of which can tell that
their peer is across a link rather than across distribution.

## Decision

### Trust is per executor

`[executors.<name>]` gains `trust`, which is `"trusted"` (the default, and
today's behaviour) or `"untrusted"`. An untrusted executor is reached at
`address` (`host:port`) and its certificate must hash to `pin`. It has no
`node`. A deployment can mix the two: a build box enrolled as a trusted
distribution peer and a review pod reached as an untrusted executor, each
chosen per session as placement chooses today.

The trusted mode keeps everything it has: the distribution membership, the
ledger, sessions moving between orchestrators, the full vocabulary. Nothing in
this proposal changes a trusted executor's wire.

### The transport

The orchestrator dials the executor's listener. The executor never dials.

- **TLS 1.3, both directions verified.** Each side presents a certificate and
  verifies the other's against the configured CA, as distribution does, and in
  addition requires the SHA-256 of the peer's leaf to equal a configured pin.
  The orchestrator holds one pin per untrusted executor; the executor holds
  the pins of the orchestrators it serves, at most 32. There is no node name,
  no cookie and no `epmd`. The executor's daemon starts no distribution at all.
- **Frames.** A frame is a four-byte big-endian length and that many bytes.
  The TLS socket is set to `{packet, 4}` with a `packet_size` of
  `max_frame_bytes` (32 MiB), so an oversized frame is refused by the socket
  before it is buffered, and the connection closes. The body is one UTF-8 JSON
  document, read by `core/json.parse`, which is total, bounds nesting at 256
  and refuses duplicate keys. Bytes (tokens, bindings, state pieces, hook files,
  msgpack capability arguments, the sandbox policy) are base64 strings. No
  Erlang term crosses: nothing on either side calls `binary_to_term`, so a peer
  cannot create an atom, a pid, a reference or a function.
- **One frame at a time.** Each side reads with `{active, once}` and decodes a
  frame before asking for the next, so one connection costs at most one
  decoded frame at a time.
- **Handshake.** The orchestrator's first frame is `hello` with the wire
  version (`untrusted_wire.version`, 1) and `protocol.version`. The executor
  answers `welcome` with its own two numbers, or closes. The orchestrator
  closes on any mismatch, and the session open reports it as the attach's
  `VersionMismatch`. The executor closes a connection that sends no `hello`
  inside ten seconds.

### Frames

| Frame | From | Carries |
|---|---|---|
| `hello` | orchestrator | the two versions |
| `welcome` | executor | the two versions |
| `request` | orchestrator | an id and a request |
| `cancel` | orchestrator | an id |
| `response` | executor | an id and the reply |
| `callback` | executor | a binding, an id and an owner request |
| `answer` | orchestrator | a binding, an id and the owner's answer |

### How 078's requests map onto it

A `HostMessage` carries a `Subject` for its reply. The link keeps the subject on
the orchestrator and sends a request id in its place. Ids are minted by the
orchestrator's link, start at 1 and are never reused for the life of the link,
so a reply names exactly one request.

| `HostMessage` | Request | Reply |
|---|---|---|
| `Attach` | `attach`, with a binding in place of `owner_port` | `Result(Attached(census), Refusal)` |
| `Run` | `run` | `RunAnswer` |
| `Query` | `query` | `Result(Lookup, Refusal)` |
| `QueryOrFence` | `query_or_fence` | `Result(Lookup, Refusal)` |
| `ListUnacked` | `list_unacked` | `Result(Unacked, Refusal)` |
| `Ack` | `ack` | none |
| `Close` | `close` | `Result(CloseOutcome, Refusal)` |
| `StateCapture` | `state_capture` | `Result(Option(State), Refusal)` |
| `StateApply` | `state_apply` | `Result(String, Refusal)` |
| `StateChunk` | `state_chunk` | `Verdict` |
| `StateStatus` | `state_status` | `Result(Stage, String)` |
| `StateFetch` | `state_fetch` | `Fetched` |
| `StartExecution`, `StopExecution`, the eight `Evolution*` | not carried in slice 1 | answered on the orchestrator with `Invalid` (or the type's refusal), never sent |

The orchestrator decodes a `response` against the kind of reply its request
expects. A response for an id the link never issued, a body that does not decode
as the expected kind, or any frame the orchestrator does not accept from an
executor (`hello`, `request`, `answer`, `cancel`) is a protocol violation: the
link logs it and closes the connection. A response for an id it issued but no
longer holds (its caller was killed, or it was already answered) is dropped,
because a cancel and an answer can cross.

The orchestrator's surface is unchanged. Its `Reach` names the link: the address
is a name registered on the orchestrator's own node by the link process, and
`connect` asks the link to reach the executor. So `surface.attach`, `run`,
`recover`, `ack` and the owner port's reconciler send the same `HostMessage`s
they send to a trusted executor.

### Cancellation and partitions

078 has no cancel message: the host monitors the process that owns each `Run`'s
reply subject, and a `DOWN` with any reason but `noconnection` cancels. The link
keeps that rule on both sides.

- On the orchestrator, the link monitors the process that sent each request.
  When it dies, the link drops the request and, if the connection is up, sends
  `cancel` with its id.
- On the executor, the gateway gives every request a waiter process that owns
  the reply subject the host sees. `cancel` kills that waiter, so the host's
  monitor fires with a reason other than `noconnection` and cancels the call as
  it would have.
- When the connection drops, each of its waiters exits with the reason
  `noconnection`, which the host reads as a partition and never as an abort,
  exactly as it reads a dropped distribution connection. The run finishes, its
  outcome waits in the ledger, and the orchestrator's re-send on the next
  connection gets a new waiter. Because the old waiter is gone, a cancel sent
  after the re-send kills the only waiter left, and the host aborts the call.

### Re-sending

The surface re-sends a request whenever the executor's host goes away, and
every request above is idempotent by key, token or offset; 078 depends on that
already. The link therefore keeps each outstanding request's encoded bytes and
sends them again on the next connection. While the link has an outstanding
request or a live binding and no connection, it redials with a pause that
doubles from 50 ms to 2 s. The surface's own repair loop then only runs when
the link process itself is gone.

Over distribution an unreachable executor is a `DOWN` at once, and the
surface's bounded exchanges (an attach within `attach_within_ms`, the
reconciler's listing) give up on their own. The link stays alive while it
redials, so when a dial fails it refuses its outstanding listings with
`Unreachable` at once, and its outstanding attaches once the pause between
dials has grown to its longest, a few seconds of consecutive failures, so a pod
that restarts during an open is tolerated. A close is not refused: its asker
bounds its own wait, and a session move retries a close that went unanswered
but abandons one that was refused. A run, a lookup and the state transport's
requests keep waiting, as they would for a partitioned peer.

### Callbacks ride the orchestrator's connection

A workspace plane needs its owner while it runs: an escalation, a reserved
fact, a notice, a capability whose state is the conversation's. In 078 the
`Attach` carries the subject of the session's owner port and the executor sends
`OwnerMessage`s to it. Here the `attach` request carries a **binding** instead:
sixteen random bytes the orchestrator's link mints for that one attach and
records with the session and the owner port.

On the executor the gateway gives each binding a proxy, a process whose subject
it passes to the host as the `owner_port`, so the plane is built exactly as for
a trusted orchestrator. The proxy turns each `OwnerMessage` into a `callback`
frame on the current connection of the orchestrator that opened the binding,
with an id that increases by one per callback, and answers its caller from the
`answer` frame. When that orchestrator has no connection, the proxy answers at
once with the in-band failure the message's type allows (the same table as
`owner_link`: an escalation settles as refused, a fact fails with `owner
unavailable`, a capability is denied with `owner_unavailable`), and it answers
every callback still outstanding the same way when the connection drops. The
executor never dials and holds no credential for the orchestrator.

The orchestrator checks every callback before its owner port sees it:

1. **The binding is one this link minted**, for an attach it sent to this
   executor, and has not retired. A binding retires when the session attaches
   again with a new owner port (a re-sent attach keeps its binding) and when
   its owner port dies, which every close does. A callback on any other binding
   is refused in band.
2. **The id is greater than every id accepted on that binding.** The counter
   survives a reconnect, so a replayed callback, from this connection or an
   earlier one, is refused in band.
3. **The callback is about this binding's work.** Four kinds name a tool call,
   and the link requires that call to be a `run` it has outstanding for the
   binding's session:
   - `escalate`: the refusal's operation, step and source index, and also its
     strand, tool name and arguments, must equal that `run`'s. The operator is
     asked about the call the orchestrator sent, not about one the executor
     describes.
   - `capability`: the operation, step, source index and strand must be a
     `run` in flight. Owner-bound capabilities are therefore reachable only
     while a foreground call of the session is running, with that call's
     strand.
   - `holds`: the caller's operation, step and source index.
   - `tail`: the run's key.

   Facts, notices, wakes, strand activity, the MCP plan and the Git identity
   need only the binding: background jobs legitimately send them after the
   `run` that started them has ended, and the owner port fences them to the
   session (`owner_services` serves only the reserved fact prefixes).
4. **Bounds.** A binding has at most 64 callbacks outstanding and a link at
   most 1024; beyond that a callback is refused in band.

A refused callback is answered with the failure its type allows and logged with
the binding's session and the reason; it never reaches the owner port. A
callback that is accepted is run by a task that sends the `OwnerMessage` to the
owner port with a fresh reply subject, waits for the answer or the port's
`DOWN`, and hands the encoded answer back to the link. The link itself never
waits on an owner.

### State transport is pulled, never pushed

107's pieces already move only when the orchestrator asks: `state_chunk` sends
a piece to the executor, `state_status` asks how much it holds and
`state_fetch` asks it for a piece. A capture on an untrusted executor is
therefore fetched by the orchestrator, piece by piece, and every piece is
checked by the existing receiver (`state_transfer.take`), which verifies the
whole bundle's size and SHA-256 against the description before a state exists.
The executor has no way to put bytes into the orchestrator's store that the
orchestrator did not ask for. A piece is at most the frame limit, less the
envelope.

### The census

`Attached` carries the plane's census. Its `broker` field is a subject, which
cannot cross, and the orchestrator puts a broker handle there whose every call
is refused as unavailable. That refuses, for an untrusted executor in slice 1,
the commands non-tool callers run through the executor's broker: project hooks,
goal checks, Git observation and the worktree diff. Its `evolution` field is set
by the orchestrator to `Uncompiled` with a reason naming this mode, so the
orchestrator never sends an evolution request. Everything else in the census is
data, decoded totally, and is used as it is today: as untrusted text for the
system prompt and as the executor's own description of its tools. The
orchestrator renders guidance files and checks hook bytes against its own trust
record exactly as it does for a trusted executor.

### Configuration

On the orchestrator:

```toml
[executor_link]
ca = "/etc/loom/link/ca.pem"
certificate = "/etc/loom/link/orchestrator.pem"
key = "/etc/loom/link/orchestrator.key"

[executors.review-pod]
trust = "untrusted"
address = "review-pod.internal:7443"
pin = "<64 lower-case hex digits: SHA-256 of the pod's leaf, DER>"
```

On the executor:

```toml
[executor_listener]
listen = "0.0.0.0:7443"
ca = "/etc/loom/link/ca.pem"
certificate = "/etc/loom/link/executor.pem"
key = "/etc/loom/link/executor.key"
orchestrators = ["<pin of each orchestrator that may connect>"]
```

An untrusted executor must not have a `[distribution]` table, and the daemon
refuses one beside `[executor_listener]`, because the point of the mode is that
the machine is never an Erlang peer. `[executor_link]` is required on an
orchestrator that names any untrusted executor, and an untrusted executor
refuses `node`, while a trusted one refuses `address` and `pin`.

## Threat model

Assume the executor's VM, its jails and its listener are wholly the attacker's.

**What it can do.**

- Anything to the sessions placed on it, within their bindings: return any
  tool outcome, lose or refuse calls, lie in its census (its tools'
  descriptions, its guidance files, its platform), fill its own ledger. These
  arrive as data and are read by the model as tool output and workspace
  guidance, which is how an untrusted repository's contents already arrive.
- Read everything the orchestrator sends it for those sessions: the calls and
  their arguments, each call's stored authority (directory additions and
  standing grants, which are policy and not secrets), the operator's Git
  identity, and the source of the MCP façades the session uses.
- Make the owner-bound callbacks of a session it holds: ask the operator about
  a call that is in flight (with the call's own arguments; see check 3), read
  and write the reserved fact prefixes, notify and wake the session's strands,
  and call `strand.*`, `notes.*`, `schedule.*` and `peer.*` while a `code_mode`
  call of the session is running, with that call's strand. That is what a
  program the model wrote could do through the same call; the owner applies the
  same tool-list check and the same refusals.
- Deny service: refuse every call, hold every connection, close it.

**What it cannot do.**

- Run code on the orchestrator, create atoms there or send it an Erlang term:
  there is no distribution connection and the frames are JSON.
- Dial the orchestrator, or reach any orchestrator that has not dialled it.
- Read a provider key, the session store, the hook trust record, clearance or
  approvals: none of them is ever sent. Clearance runs on the orchestrator
  before a call is sent, and approvals park there.
- Act on a session that was not placed on it, on a session's earlier open
  after it attached again, or on a scope after it closed: the binding is the
  only handle, and the orchestrator retires it.
- Ask the operator about a call that is not in flight, or describe an in-flight
  call with other arguments.
- Replay a callback or a reply, answer a request that was not sent, or answer
  one request with another's kind.
- Exhaust the orchestrator's memory with outstanding callbacks (64 per binding,
  1024 per link) or requests, or crash the link with a malformed frame:
  decoding is total, and a violation closes that connection and nothing else.
  A frame is at most 32 MiB with bounded nesting; see the residual risks for
  what one decoded frame can cost.
- Put a repository state in the orchestrator's store that the orchestrator did
  not ask for, or one whose bytes do not match the description it fetched.

**Residual risks.**

- A compromised executor sees everything a session puts on it, including the
  arguments of every call and whatever the model writes into the workspace.
  Secrets a session pastes into a tool call reach the executor. This is the
  same as running the checkout there at all.
- The capability callbacks act as the session's strand. A hostile executor that
  waits for a `code_mode` call can send `peer.*` messages or schedule work as
  that strand while the call runs. Narrowing that further needs the
  orchestrator to know which capabilities the program asked for, which only the
  executor knows; slice 1 does not try.
- **One frame's decoded size.** The frame bound is on bytes, and nesting is
  bounded, but breadth is not: a 32 MiB array of small integers decodes to
  several hundred megabytes of terms for as long as the frame is being read.
  The link reads one frame at a time, so this is a transient cost per
  connection, and a small orchestrator can still be pushed into an allocation
  failure by a hostile executor. A count of values in the decoder would bound
  it; slice 1 does not add one.
- **The grant an escalation asks for is the executor's.** The link checks that
  an escalation describes the call in flight exactly, but its `denial`, the
  access the call says it was refused, comes from the executor's broker, which
  the orchestrator cannot re-evaluate. An operator who approves "for this
  session" remembers that grant on the orchestrator, and it applies to the
  session's later calls wherever they run. The operator sees the grant before
  deciding; a later slice can refuse the remembered decision for an escalation
  that arrived over this link.
- TLS and the pins are the authentication. A stolen orchestrator key lets its
  holder dial the executor as that orchestrator, which, the executor being
  untrusted anyway, gains it the executor's sessions and nothing on the
  orchestrator.

## What it costs

A second transport for the same vocabulary, about 3,000 lines with its codec
and tests, and one Erlang FFI module for the TLS socket, which neither the
standard library nor `gleam_erlang`, `gleam_otp` or weft can express. Every
reply and callback costs a JSON encode and a total decode on top of the term
copy distribution does, and pieces and outcomes grow by a third as base64. A
tool call's outcome of 16 MiB is roughly 22 MiB on the wire. For the sessions
this mode is for, a review pod's tool calls, that is noise beside the call.

## Slices

1. **This PR.** The link and the gateway, the wire and its codec, the
   configuration, tool calls with their recovery, owner callbacks with the
   per-binding checks, and state transport. Background code mode, remote
   evolution and non-tool callers are refused with reasons naming this mode.
2. **Background code mode.** `StartExecution`, `StopExecution`,
   `LaunchExecution` and `InteractExecution`, with the capability check of
   check 3 extended to an execution the binding's session has running.
3. **A broker tunnel for non-tool callers**, so project hooks, goal checks,
   Git observation and the worktree diff run on an untrusted executor. The
   broker's vocabulary streams output, so this needs streamed frames.
4. **Remote evolution**, if a deployment wants candidates compiled on an
   untrusted machine.

## Tests

`untrusted_codec_test` round-trips every request, reply, callback and answer
and refuses malformed bodies, unknown kinds, wrong kinds and absurd sizes.
`untrusted_link_test` drives the real link against a hostile executor written
in the test, which forges callbacks for another session and for an unknown
binding, describes an in-flight call with other arguments, replays callback
ids, answers requests it was never sent, answers with the wrong kind, sends
malformed, backwards and oversized frames, and presents a leaf from another
authority or with another pin under the same one; each is refused, the owner
port never sees it, and the link survives. It also covers the backlog re-sent on
a new connection, a dead asker's cancel, and an attach to an executor nobody
answers for. `untrusted_gateway_test` drives the real gateway and host as an
orchestrator by hand: a dropped connection does not cancel a call, a cancel
after the re-send on a new connection does, and an orchestrator pin the gateway
does not list is refused. `untrusted_end_to_end_test` runs a real orchestrator
surface and owner port through the link and the gateway into a real host, with
certificates minted by `client_pki_ffi`.

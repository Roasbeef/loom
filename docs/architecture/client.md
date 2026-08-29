# The client plane

A session is a supervision tree inside one BEAM node: a writer holding
the session file's lease, one driver actor per strand, a broker with a
pool of jailed helpers behind it. A person is none of those things. They
sit at a terminal outside the node and want to watch a run happen, read
what the model wrote, and change its mind halfway through. This plane is
how they do that without becoming part of the tree.

It has four parts. A **hub** actor, one per served session, turns
durable writes into a stream of events and turns client commands into
ordinary admissions. A **websocket transport** authenticates an upgrade
and pipes text frames between a socket and that hub. A **frozen JSON
protocol** is what the two ends agree on, down to the byte. And
`loom-tui` is a Go terminal client that speaks it and depends on nothing
else in the tree. What follows is those parts as built, in the `client`
and `tui` packages, through to the scripted acceptance that drives a
whole session — prompt, tools, a subagent, an escalation, fork,
navigate, compact, reconnect — through the protocol and nothing else.

## What a client is trusted with

A client is not a strand, not a process in the supervision tree, not a
party to any commit. It holds no durable state: every fact the terminal
shows arrived in a snapshot or an event, and closing it loses nothing.
The server owns the session file and its writer lease; the client owns a
view. That asymmetry is the design — one server, any number of clients,
several terminals or an editor plugin or a phone, each catching up by
sequence number.

The trust boundary is an authentication fence, not a capability model.
**One session is one gateway is one bearer token is one trust domain.**
A client that presents the token may prompt, steer, or abort any strand
in that session, read the whole transcript, fork the tree, and change
model configuration. There is no per-strand principal to enforce
against, and the code does not pretend there is one. That follows the
project's threat model, which defends against accidents, prompt
injection, and malicious generated code, and explicitly does not defend
against a hostile user on their own machine (design §5.1).

Three things the plane does defend:

- **Without the token, nothing.** Every upgrade that fails the bearer
  check is answered `401` before any websocket state exists.
- **A client cannot widen a sandbox policy past what the harness
  offered.** An `approve` command is checked against the *server-stored*
  denial, structurally, and only the validated subset is handed on.
- **A client cannot reach a second session.** One hub serves one session
  id over one store handle; a `subscribe` naming any other session is
  refused, and every seq a client sends is interpreted against that one
  store.

What is deliberately not defended is an authenticated client behaving
badly toward its own session. The server sets no inbound frame-size
limit and no rate limit on `catch_up`, so a client holding the token can
make the hub do transcript-sized work per frame and stall event
delivery for the session's other connections. The M3 review found
both; the triage accepted them without change on the same reasoning as
the analogous provider case — a client that authenticated already holds
the session.

## The hub

The hub is one actor per served session, registered under a process
name so the composition seams can address it before it starts. It is
transport-agnostic on purpose: **a connection is a sink function**, a
`fn(String) -> Nil` the transport registers with `attach` and gets an
integer id back. Inbound frames arrive as text through `handle_text`,
every reply and broadcast leaves through the sinks, and nothing in the
module knows what a socket is. The websocket server is therefore one
module thick, and a second transport would be a new module rather than a
hub change.

Four kinds of message reach it. Client frames arrive as `FromClient`.
The runtime writer's post-commit publication arrives as `CommitHint`,
bridged by a tiny forwarder actor whose subject is handed to `api.open`
in `subscribers`, so the writer re-registers it on every tree restart.
An events-bus publication arrives as `BusHint` when a bus is configured
— `serve` configures none today, so the writer is production's only hint
source. And `ProviderDelta` arrives from the streaming tap described
below.

**Events are hints; pulls are truth.** Neither hint carries content.
Both do exactly one thing: trigger a read of everything in storage above
the hub's high-water seq. A lost hint costs latency and never an event,
because the next hint, or the next command, pulls the same range. This
is the doorbell doctrine the orchestration plane uses between strands,
applied at the session's outward edge.

### The seq is the storage seq

The single decision the rest of the hub falls out of: **the envelope
`seq` on a durable event is the storage seq of the write that produced
it.** Storage assigns strictly increasing seqs to every write in a
session — entries, usage rows, and register sets share one space — so
the event stream needs no materialized side index, is durable across
gateway restarts by construction, and can be rebuilt from scans at any
time.

One pull assembles four sources and merges them:

```
pull(high_water = hw)
  ├─ entries       per-strand branch scans above hw, then a
  │                completeness pass over scan_entries(hw+1..)
  ├─ usage         scan_usage(hw+1..), attributed via the entry cache
  ├─ registers     strand.state phase, strand.last_result, and the
  │                "done" transition when the state register cleared
  └─ escalations   fact.custom cells under the reserved escalation/ prefix
        │
        └─ filter seq > hw · sort by seq · dedupe · broadcast
```

The high-water advances only to the greatest seq actually emitted, never
to the store's tail. Register writes that produce no event — leaf moves,
queue bookkeeping — may sit above it, which is harmless because every
source gates on its own row or cell seq exceeding the high-water.
Advancing further would race a commit landing between two of the reads
and drop its events silently.

Two consequences follow from reading registers rather than a log, and
both are documented protocol behavior rather than bugs to fix later.
**Immutable rows replay exactly**: `entry` and `usage` events are
scanned by seq range, so a resume reproduces them one for one.
**Register-backed events replay as current state at current seq**:
registers keep no history, so a superseded `op_transition` is not
reconstructible. A client that missed an intermediate phase still
converges, because phases are display labels and the snapshot carries
the live state; the truth about an operation is `op.state`, which the
orchestration plane owns.

Attribution is where the pull earns its complexity. An entry knows its
parent, not its strand, so the hub scans each strand's branch from its
leaf and claims what it finds, caching entry id to strand; a
completeness pass then sweeps whatever no leaf covered — a branch
summary left behind by a navigation, say — and attributes it through the
parent chain, falling back to the first strand. Usage rows are
attributed through that same cache by their entry id.

Escalation records need no scan at all: `runtime/escalation.Escalation`
carries a `CallScope` recording the exact `{operation, strand, step,
source index, call id}` a denial was raised for, and the hub reads
`op`/`strand` straight off it. Both are empty exactly when the record
names no call — an escalation raised through the unscoped door — which
is a different statement from the guess this replaced
(`protocol-change/007`, issue #67), which named whichever single strand
had an operation open for *every* record and named neither when zero or
several did.

**The hub commits nothing of its own.** Its reads go straight at the
store handle, but every write it causes goes through the session's one
writer: through `runtime/api` for prompt, steer, follow-up, abort, and
the escalation decisions, and — for compaction and navigation, which
have no api entry point yet — as a `machine/acceptance` plan committed
through `runtime/writer`, the same pattern the conformance simulation
runner uses. Strand seeding for `fork` and `create_strand` writes its
three registers in one compare-and-swap-guarded transaction through that
same writer, because the api's creation path always takes a task brief
and the protocol wants idle strands.

The hub itself is a plain actor started by `serve`, not a child of the
session supervision tree, and nothing restarts it. It is linked to the
process that booted it, so a hub crash takes the server down rather than
leaving connections attached to a corpse.

## The wire

Transport is websocket, text frames, one JSON envelope per frame, at
`/v1/ws`. The envelope is frozen by the implementation spec Part 1.6;
the bodies under it are defined by
`packages/tui/internal/proto/protocol.md`, which both implementations
build to.

```
c→s  {"v":1, "id":<uint>, "cmd":<name>, "body":{...}}
s→c  {"v":1, "reply_to":<uint>?, "event":<name>, "seq":<uint>?, "body":{...}}

cmd    subscribe, catch_up, prompt, steer, follow_up, abort,
       approve, deny, fork, navigate, compact, create_strand,
       models, set_config
event  snapshot, entry, op_transition, stream_delta, usage,
       escalation, strand_result, error
```

**Decoding is strict on the envelope and tolerant on names.** `v` must
be `1`; the discriminator must be present; a command `id` must be
present and positive. An unrecognized `cmd` or `event` *name* decodes
successfully, keeping its raw body, so the receiver answers in band — a
server replies `error` with code `unsupported`, a client ignores the
event and survives a newer server. Unknown *fields* inside known bodies
are ignored by both sides, which is what makes a new optional field an
additive change within v1. Everything in the Gleam `protocol` module is
pure and total: a malformed frame yields a `ProtocolFault` value —
`MalformedFrame`, `BadEnvelope`, or `BadBody` — that the hub answers,
never a crash. `core/json` bounds nesting at 256 levels, so a deeply
nested frame is a corruption report rather than a stack overflow.

Fourteen commands ship; the spec's Part 1.6 list names thirteen.
`models` arrived with the model catalogue and the spec text was never
amended, so the built protocol is one command wider than the frozen
contract says.

Every command gets exactly one reply on the issuing connection: an event
with `reply_to` set, or `error` with `reply_to` on failure.

| cmd | success reply |
|---|---|
| `subscribe`, `catch_up` | `snapshot` (`full` or `resume`) |
| `prompt`, `steer`, `follow_up` | `entry` |
| `abort` | `op_transition` (`cancel_requested`) |
| `approve` / `deny` | `escalation` (`approved` / `rejected`) |
| `fork`, `create_strand`, `navigate` | `snapshot` (`strands`) |
| `compact` | `op_transition` (`compacting`) |
| `models` | `snapshot` (`models`) |
| `set_config` | `snapshot` (`config`) |

Where the reply is *also* a durable-stream event — the `entry` acking a
`prompt` — the hub suppresses that one connection's broadcast copy and
sends it as the reply instead, carrying both `reply_to` and the same
`seq`. Every other connection receives the ordinary broadcast. A client
therefore sees each durable event exactly once whether or not it issued
the command.

Error codes are `bad_request`, `unknown_session`, `unknown_strand`,
`unknown_escalation`, `not_pending`, `conflict`, `unsupported`, and
`internal`. The set is open and clients display unknown codes verbatim,
as they do unknown `op_transition` phases — a useful tolerance, since
the hub already emits two labels protocol.md does not list
(`checkpoint`, from a run's durable decision point, and `navigating`).

### Pinned to the byte

The two implementations are not kept compatible by discipline. **Golden
fixtures under `packages/tui/internal/proto/testdata/` pin the canonical
text of every command and event shape**, thirty-five files; the Go
package decodes and re-encodes each one and compares, and the Gleam
package's conformance test does the same against the same files. Either
side drifting fails a test rather than a session.

Three details in those fixtures differ from what `core/codec` produces,
and the wire follows the fixtures while the harness keeps the codec's
canonical form; the protocol module adapts in both directions. Assistant
`toolCall` blocks nest the call under a `toolCall` key where the codec
inlines its fields. `thinking` blocks always carry `redacted`, where the
codec omits the default `false`. And floats print positionally the way
Go's `encoding/json` does — `0.00027`, not the BEAM's shortest form
`2.7e-4` — which is why the module ships `to_wire_text` rather than
using `core/json.to_string`. Both forms parse to the same number; the
fixtures pin the bytes.

Everything else that already has a durable JSON form in the harness —
entries, messages, usage — crosses **verbatim** in the core codec's
vocabulary, pi field names and camelCase, nested inside snake_case
gateway fields. A client treats those as a nested document. The nested
`seq` inside an entry is that entry's storage seq, which for an `entry`
event is also the envelope's seq — a coincidence of this design, not a
rule a client should lean on.

## Attach, stream, steer

A connection scopes itself to a session with its first and only
`subscribe`. With no `from_seq`, or zero, the reply is a **full
snapshot**: the session id, `next_seq`, every strand with its leaf and
open operation, a recent window of entries (fifty by default, oldest
first), the pending escalations, and the session's running usage total.
The client rebuilds from scratch and sets its stream position to
`next_seq - 1`.

With `from_seq > 0` — a client that was at `from_seq - 1` and
reconnected — the reply is `snapshot {mode: "resume", next_seq}`,
followed by the durable events in `[from_seq, high_water]` replayed in
order with their original seqs, after which live events continue. If
`from_seq` is out of range, meaning zero, negative, or past the
high-water, the hub answers a full snapshot instead and the client
discards its state. `catch_up {from_seq}` is the same machinery on an
already-subscribed connection, which is what a client sends when it
notices a gap. Overlap is legal and expected; clients deduplicate by
seq. Because event seqs *are* storage seqs, that same path pages
arbitrarily far back through the transcript — though no client uses it
that way yet.

```mermaid
sequenceDiagram
    participant T as loom-tui (outside the node)
    participant W as websocket transport
    participant H as gateway hub
    participant A as runtime api / writer
    participant S as session store

    T->>W: upgrade + Authorization: Bearer
    Note over W: constant-time compare;<br/>401 before any socket state
    W->>H: attach(sink) → connection id
    T->>H: subscribe {session}
    H->>S: scans + register reads
    H-->>T: snapshot full (reply_to, no seq)

    T->>H: prompt {strand, text}
    H->>A: api.prompt → acceptance commit
    H->>S: pull above high-water
    H-->>T: entry (reply_to + seq)
    H-->>T: op_transition, usage … (seq, broadcast)

    A-->>H: provider deltas (tapped surface)
    H-->>T: stream_delta (ephemeral, never seq'd)

    T->>H: steer {strand, text}
    H->>A: api.steer → queue commit
    H-->>T: entry ack (reserved id, no seq)
    Note over H,S: the placed entry broadcasts later,<br/>with its real parent and seq
```

The commands themselves are thin. They map onto the operation model the
orchestration plane already has, and the hub adds no conversational
logic of its own: `prompt` is an acceptance on an idle strand, `steer`
and `follow_up` are queue admissions drained at a checkpoint and at a
`MayFinish` boundary respectively, `abort` routes a cancellation marker
through the strand driver. Refusals come back as the api's own reasons,
translated: a busy strand is `conflict`, an unknown strand is
`unknown_strand`, a lost seq race that four retries could not win is
`conflict` again.

Two ack shapes describe something other than a placed entry. **A steer or
follow-up ack describes a durably queued item, not a placed entry.** The
queue admission mints a reserved entry id and writes the payload to a
pending register; the tree entry appears only when the run consumes it.
So the ack carries that reserved id and the message with no parent and
no envelope seq, and the placed entry broadcasts later with both. **An
abort ack is connection-scoped**: the hub replies `op_transition {phase:
"cancel_requested"}` immediately, while the durable cancel-requested
transition broadcasts with its seq when its commit lands.

The gateway answers three questions protocol.md left open, and a client
can depend on the answers. A `follow_up` on an idle strand starts a run
rather than being refused, mirroring the api's own idle path. `fork`
forks **in place** under both scopes — a new strand cursor over the
shared tree, seeded at the source strand's current leaf — because the
reply is a `strands` snapshot of *this* session and cannot name a
separate session file; forking into a new file stays an admin surface.
And `strand_result` is emitted for every operation kind, runs and
compactions and navigations alike, since all three publish
`strand.last_result`.

### Streaming without persisting

Streamed deltas never touch storage. `tap_provider` wraps the injected
`runtime/effects.ProviderSurface` so that each request's stream runs
through a relay process: the relay forwards every event to the effect
process that asked for it, unchanged and in order, and tees the deltas
to the hub on the way past. The hub broadcasts them to subscribed
connections as `stream_delta` events with `ephemeral: true`, no seq, no
replay, wholly superseded by the settled `entry` for the same operation.

The relay is also an ownership boundary. Its returned handle forwards
explicit cancellation to the inner provider handle, and the relay monitors
its direct consumer so an effect killed by abort or driver restart cancels
the inner stream without waiting for either timeout. If the relay itself
dies, the provider pump observes that consumer death and tears down the
transport. Thus the tap preserves both event order and the cancellation chain;
it is not another independently-lived request.

`client/provider_relay.wrap` holds that mechanism once for both the delta tap
and the summary recorder. Its observer runs before it forwards an event, so
sharing ownership machinery does not weaken the summary recorder's stricter
record-before-terminal order.

The tap lives entirely in the composition seam, so the orchestration
plane is untouched by it: `serve` builds the effects record, then
replaces its provider field with the wrapped one before `api.open`. If
the inner provider dies first, the relay forwards the in-band failure exactly
as before.

### Escalations, and the one check that matters

When the broker refuses a tool call under the session's policy, the
refusal comes back as an ordinary in-band tool result:
`tool.refusal_outcome` renders a `PolicyRefused` as an `is_error` outcome
whose `details` carry the denial's **wanted grants** — the exact set that
would satisfy it. Nothing consumes them. **No production path
raises an escalation from that result**, or from anywhere else:
`api.raise_escalation` and `api.raise_escalation_for` have callers only
in `client/demo.gleam` and the simulation surface under `conformance`.
The wanted grants are preserved and go no further, and
`docs/spec-gaps.md` under "From WP-L" is where the gap is recorded.

Everything below the missing raiser is built and exercised. Given a
durable escalation record, the hub surfaces pending escalations in the
full snapshot and as `escalation` events, decoding the runtime's opaque
stored JSON into typed `broker/policy.Grant` values and re-encoding them
in the protocol's `type`-discriminated vocabulary. The terminal shows the
wanted diff verbatim — "wants: network to registry.npmjs.org" — because a
policy widening a human cannot read is a policy a human cannot judge.

The approval path is the highest-stakes surface the client plane has,
and the whole of its defense is one comparison. `approve` may carry a
subset of grants, or none at all to mean everything wanted. The wanted
list is read from the server-stored record — never from the command —
and every submitted grant must appear in it under **structural
equality** on the entire grant value. There is no prefix logic, no path
normalization, no ordering of network modes by looseness. A crafted
`/work/../etc`, or a `NetworkFull` where the denial wanted a proxy, is
simply not in the list and comes back `bad_request`. Only the validated
subset is re-encoded and stored, so the consume path hands the single
re-execution exactly what was approved — and the broker and the kernel
enforce it again regardless, since this check is the first layer, not
the only one.

## Authentication and the token

The spec asked for unix-socket peer credentials locally and bearer
tokens remotely. `mist`, the Gleam ecosystem's websocket server, listens
on TCP interfaces only and has no unix-socket listener, so peer
credentials are not implementable there today. What ships instead moves
the same check into the filesystem: bind loopback, mint a bearer token
at startup, and write it to a mode-`0600` file next to the session. A
local client reads that file — which only the same user can — and
presents `Authorization: Bearer <token>` on the upgrade, exactly as a
remote client would. One code path, one header, and if `mist` ever grows
unix listeners the token file can be replaced without touching the
protocol.

Three mechanisms make that story hold, all of them the result of an
adversarial review that found the first two versions wanting.

**The token is 128 bits of CSPRNG.** `mint_token` draws four values from
the injected entropy function and keeps the low 32 bits of each as eight
hex characters. `serve` injects `unique * 2^64 + random64`, where the
random limb comes from `crypto:strong_rand_bytes`; because `2^64` is
congruent to zero mod `2^32`, the predictable monotonic limb is masked
away entirely rather than weakly mixed in, and each of the four words is
an independent CSPRNG draw. The monotonic limb still does its real job
on the id-seed path, where uniqueness rather than unpredictability is
what matters.

**The token file is never briefly readable, and never followed.** The
bytes are created at an unpredictable temporary name in the destination
directory, exclusively (`O_EXCL`, so a symlink or an existing file there
is refused rather than followed or truncated) and then restricted to
`0600`, and only then moved onto the real path with a single atomic
rename. A rename replaces whatever sits at the destination without
reading through it, so a symlink pre-planted at the well-known token
path is refused the same way a plain race is: the destination's contents
never influence what gets written. A failed rename deletes the
temporary. The earlier shape — write at the final path, chmod on the
next line — left the token world-readable for a window at a boot time an
attacker could predict; a test now asserts both the `0600` mode and that
a symlinked target is left untouched.

**The comparison is constant time in content and in length.** The
presented bytes go to `crypto:hash_equals` rather than `==`, which
short-circuits at the first differing byte and turns response latency
into an oracle on the secret. One wrinkle distinguishes this from the
broker's capability tokens: there both operands are always exactly 32
bytes, so a length check leaks nothing, while here the presented side is
attacker-controlled and `hash_equals`'s length-mismatch fast path would
leak the token's length. The shim therefore hashes both operands with
SHA-256 first, so every call — right or wrong, long or short — compares
two 32-byte digests and never branches on length at all. Only the
`Bearer ` prefix check runs before it, and that branches on a public
scheme name.

What this buys is narrower than "the session is authenticated," and the
difference matters. It authenticates *a user account* on the machine:
reading a mode-`0600` file proves you are the user who runs the server,
which is the peer-credential check relocated. It does not authenticate a
program, so any process running as that user can read the file and
attach. It is not transport security: there is no TLS anywhere in the
client plane, so a token sent to a non-loopback address crosses the
network in the clear and is replayable by anyone who sees it. Loopback
is a default and a documented invariant on
`server.Config`, not something the code enforces — nothing stops a
caller binding a public interface under `LocalAuth`. And the token is
all-or-nothing: whoever holds it holds the session.

The pre-auth surface is deliberately bare. `/v1/ws` runs the bearer
check before the upgrade, so a `401` is emitted with no websocket state
in existence; `/healthz` answers a static `ok` with no session, version,
or build information in it; every other path is a static `404`. No path
reaches the websocket handler without passing the check.

## The terminal client

`loom-tui` is a standalone Go binary on the bubbletea stack — `bubbles`
for the text area and viewport, `lipgloss` for layout and style,
`glamour` for markdown, `coder/websocket` for the wire. It is the one
piece of Loom deliberately written outside Gleam, for two reasons the
spec gives and the code bears out. Terminal UI is where Go's ecosystem
is strongest, and bubbletea's pure `Model`/`Update`/`View` shape maps
onto protocol events with no impedance at all: an event becomes a
message, a key press becomes a command. And writing it outside the tree
proves the protocol is a real boundary rather than a shared-memory
convention — the module imports no Loom package. Its entire coupling to
the harness is the protocol document and the golden fixtures.

The connection actor is where the seq discipline lives. `Run` dials,
subscribes, and pumps until its context is cancelled, reconnecting with
exponential backoff from 100ms to 5s with ±25% jitter. A single reader
goroutine decodes each frame, resolves any `Request` waiting on that
`reply_to`, then applies four rules:

- an event at or below the last seq is a duplicate from catch-up overlap
  and is dropped;
- an event more than one past it, once a full snapshot has been applied,
  triggers exactly one `catch_up` from `last+1` and is *not* applied —
  the replay redelivers it in order;
- a full snapshot resets the position to `next_seq - 1`, since everything
  below is already in the snapshot body; a resume snapshot resets
  nothing, because its replay carries the original seqs;
- events with no seq — snapshots, deltas, errors — never move the
  position.

**Reconnects resume, they do not restart**, but only once a full
snapshot has been applied; before that a reconnect re-subscribes from
zero. A malformed frame is reported as a message and the connection
survives. In-flight requests fail loudly with `ErrDisconnected` rather
than hanging when their connection drops, and sends after close fail
with `ErrClosed`. The read limit is 16 MiB, which is the one direction
of this protocol that has a frame cap.

The bubbletea model keeps `Update` pure: every send leaves as a
`tea.Cmd` closure rather than touching the socket inline, which is what
makes the entire interaction surface table-testable without a terminal.
Typed text is a `prompt` on an idle strand and a `steer` when the active
strand has a live operation — the client decides which from the strand
list it already holds. Tab cycles strands, `ctrl+t` toggles thinking
blocks, and a `:` prefix opens a small palette: `:fork`, `:compact`,
`:abort`, `:strand`, `:models`, `:quit`.

Two modals stack above the transcript. The escalation prompt is the
higher one and swallows keys until decided: it prints the denial's
reason and every wanted grant verbatim, and `y` approves with exactly
that wanted list while `n` denies and `esc` defers it until `ctrl+e`
calls it back. The `:models` picker is the lower one. `:models` sends
the `models` command; the reply is a `models` snapshot listing one row
per catalogue entry — name, dialect, the provider's own model id, and
the roles whose fallback chain lists the entry with a star on the ones
it currently heads — and the picker
opens on that list with the cursor on the active strand's current model
where the client knows it. Enter sends `set_config {strand, config:
{model_name}}`, the gateway resolves the name against the catalogue it
was booted with, and the `config` snapshot that acks it carries the
catalogue name back, which the client pins into the status bar. A
gateway with no catalogue answers an empty list and says so.

An in-memory `fake` gateway speaks the same protocol backed by
in-process state — snapshot on subscribe, resume with replay, per-command
replies, the escalation lifecycle, in-band errors. It is the substrate
for the client's tests and for `loom-tui --demo`, which runs a canned
session with no server and no network. It exists because the Go side was
built before the Gleam gateway landed, and it carries a standing hazard
worth naming: where the fake diverges from `protocol.md`, the tests are
testing fiction.

Two features the work package lists are not built. There is no diff
viewer — the escalation overlay renders the policy diff, but nothing
renders a file diff. And there is no transcript browser: the snapshot
carries a recent window, the viewport pages within what the client has,
and nothing pulls older entries, even though `catch_up` over storage
seqs would serve that today.

## What the acceptance actually proves

`client/demo` drives the entire M3 flow **through the protocol alone**,
against a real session, a real runtime with scripted provider effects,
and a served gateway: subscribe, prompt with a tool round-trip and
streamed deltas, a subagent strand created and briefed, a durable report
travelling back to the parent, an escalation raised and approved over
the wire and consumed as typed grants, fork, navigate, compact, a
catch-up replay, and a final snapshot. It runs as a test inside `make
check-client` and as a narrated command-line program. Nothing in it
reaches around the wire.

Underneath that sit the narrower proofs. The conformance test decodes
and re-encodes all thirty-five golden fixtures byte for byte in both
directions. The transport tests assert the token file's mode, that a
pre-planted symlink is left untouched, and that a wrong token of the
right length and one of the wrong length are both refused while the
exact one passes. The hub tests walk the refusal surface — malformed
frames, a wrong version, unknown commands, commands before `subscribe`,
a wrong session, a steer at idle, unknown strands, escalations,
`set_config` keys, and model names. And boot is smoke-tested end to end:
`serve.boot` over a temporary session file, `/healthz` answered, and a
real websocket `subscribe` returning a snapshot.

## Where the code lives

| Path | What it holds |
|---|---|
| `client/protocol.gleam` | The Part 1.6 envelope and every body shape as total codecs; the grant wire vocabulary; `to_wire_text`. |
| `client/gateway.gleam` | The hub actor: attach/detach/handle_text, the pull, command dispatch, snapshots and replay, `commit_forwarder` and `tap_provider`. |
| `client/server.gleam` | The `mist` websocket transport on `/v1/ws`: routing, the bearer check, token minting, the atomic token file. |
| `client/serve.gleam` | The `loom-server` entry point: flags, environment, boot order, `SIGTERM` shutdown. |
| `client/catalog.gleam` | The `loom.toml` model catalogue: strict parser, role chains, the provider-gateway builder, name lookups. |
| `client/grants.gleam` | The bridge between the runtime's stored escalation JSON and typed `broker/policy.Grant`; `first_unwanted`, the approval subset check. |
| `client/wiring.gleam` | The production effect seam over the real provider gateway, broker, and tool registry. |
| `client/demo.gleam` | The M3 acceptance flow, driven through the protocol only. |
| `client/internal/ffi_crypto.gleam`, `.../ffi_file.gleam`, `.../ffi_os.gleam`, `client_ffi.erl` | Every external the package has, confined: constant-time compare, exclusive private file creation, clock, entropy, `PATH` lookup, the `SIGTERM` relay, and the documented halt. |
| `internal/proto/` | The Go protocol types, the name constants, the entry parse tree, and `protocol.md` — the normative body document. |
| `internal/proto/testdata/` | The golden fixtures both implementations are pinned against. |
| `internal/client/client.go` | The connection actor: dial, subscribe, reconnect, seq discipline, request/reply correlation. |
| `internal/ui/` | The bubbletea program: pure `Update`, the transcript, the escalation overlay, the models picker. |
| `internal/fake/` | The in-memory gateway behind the TUI's tests and `--demo`. |
| `cmd/loom-tui/main.go` | The binary. |

Each Gleam path is relative to its package's source root —
`client/gateway.gleam` is `packages/client/src/client/gateway.gleam` —
and each Go path is relative to `packages/tui`. For the operation model
the commands admit into, see `docs/architecture/orchestration.md`; for
seqs, write-once rows, and why the event stream needs no side index,
`docs/architecture/durability.md`; for the policy vocabulary an
escalation carries and the jail that enforces it,
`docs/architecture/effects.md`. For intent and contracts,
`docs/loom-design.md` §8.5 covers thin clients and session mobility and
§5.1 the threat model this plane's trust posture follows,
`docs/loom-implementation-spec.md` Part 1.6 holds the frozen envelope
and WP-L the scope, `docs/review/m3-gateway.md` is the adversarial review
behind the token hardening with `docs/review/m3-triage.md` recording what
was fixed and what was accepted, and `docs/spec-gaps.md` under "From
WP-L" records where the implementation refined the spec.

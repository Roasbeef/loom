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
`loom` is a native Gleam terminal client that speaks it and depends on nothing
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
the bodies under it are defined by `packages/client/protocol.md`, which both
the gateway and native client build to.

```
c→s  {"v":1, "id":<uint>, "cmd":<name>, "body":{...}}
s→c  {"v":1, "reply_to":<uint>?, "event":<name>, "seq":<uint>?, "body":{...}}

cmd    subscribe, catch_up, prompt, prompt_content, steer,
       follow_up, abort, approve, deny, fork, navigate, compact,
       create_strand, models, set_config, schedules,
       schedule_cancel
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

Seventeen commands ship, and the spec's Part 1.6 list names all
seventeen. It did not always: `models` arrived with the model catalogue
and the spec text was never amended, which a documentation pass caught
and `protocol-change/003` ratified. `prompt_content` (`011`) and the two
schedule commands (`012`) were proposed before they shipped, which is
the order the ground rules ask for.

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
| `schedules`, `schedule_cancel` | `snapshot` (`schedules`) |

Where the reply is *also* a durable-stream event — the `entry` acking a
`prompt` — the hub suppresses that one connection's broadcast copy and
sends it as the reply instead, carrying both `reply_to` and the same
`seq`. Every other connection receives the ordinary broadcast. A client
therefore sees each durable event exactly once whether or not it issued
the command.

`set_config`'s `active_tools` is checked against the live tool registry,
which is why the registry the hub holds must be the one the effect wiring
dispatches through. That registry is built at boot from an ordered list
of **contributions** (`client/contributions.gleam`), each naming its
origin: the harness's own built-ins, or an installed extension. Within one contribution a repeated name is the
author overriding themselves and the later tool wins; *between*
contributions a repeated name is refused outright and takes the boot down
with it, naming both origins. That asymmetry is the seam's whole security
argument — an extension that could register `bash` would silently
redefine what the model's `bash` call does, and every sandbox argument in
the tree would be about the wrong function. Each tool may also carry a
one-line `prompt_snippet`; the registry's snippets, in registration
order, are the available-tools index in the system prompt, and a tool
without one is absent from the index while staying perfectly callable
through the wire tool array. Like the tool array itself, that index is
fixed at session creation: the prompt is rendered once and pinned, and
`active_tool_names` is seeded from the same registry at the same moment,
so installing an extension changes what the *next* session sees rather
than growing the one already running.

Error codes are `bad_request`, `unknown_session`, `unknown_strand`,
`unknown_escalation`, `not_pending`, `conflict`, `unsupported`, and
`internal`. The set is open and clients display unknown codes verbatim,
as they do unknown `op_transition` phases — a useful tolerance, since
the hub already emits two labels protocol.md does not list
(`checkpoint`, from a run's durable decision point, and `navigating`).

### Pinned to the byte

The two implementations are not kept compatible by discipline. **Golden
fixtures under `packages/client/testdata/protocol/` pin the canonical text of
every command and event shape**, thirty-nine files; the gateway conformance
test and the native client's total decoders are held against that vocabulary.
Either side drifting fails a test rather than a session.

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
    participant T as loom (outside the node)
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

The relay is also an ownership boundary, split deliberately into three small
processes. A minimal public custodian owns the returned handle but performs no
provider or callback work. It releases the guard only after that public witness
exists, then adopts the guard, the callback observer, and the inner stream
owner before each begins work. The guard remains the inner stream's direct
consumer. Explicit cancellation and effect death travel through it to the
inner handle. A guard or observer crash becomes an in-band transport failure
only after the inner owner drains. A silent inner owner is bounded by one fixed
timer and reported honestly as terminal `CancellationUnconfirmed`, not
fabricated `ProviderCancelled`; the custodian remains alive until the complete
registered subtree exits. Thus the tap preserves both event order and the
transitive cancellation chain; it is not another independently-lived request.

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

`loom` is the native Gleam client in `packages/tui`. Etui owns raw
terminal input and frame diffs, Mork parses CommonMark into a structured tree,
and Stratus owns the websocket actor. One immutable model keeps durable records,
transient stream fragments, overlays, prompt state, scroll position, and the
server-reported usage ledger separate. `view` is pure; socket messages and keys
reduce the model before the next frame.

The protocol remains a real boundary even though both ends use Gleam. The TUI
imports the portable `core` package only to decode durable entry bodies. It
hand-writes the frozen ClientGateway envelope and event union, and both ends
decode the same golden corpus under `packages/client/testdata/protocol`.

Typed text is a `prompt` on an idle strand and a `steer` while that strand has
a live operation. Tab changes a live draft into a queued `follow_up`. Typing
`/` opens the command palette; `/model`, `/agents`, `/notes`, `/strand`,
`/fork`, `/compact`, `/abort`, `/details`, and `/quit` own the rest of the
surface. The model selector searches catalogue names and provider identities.
The agent inspector is a projection of server strands and operation phases,
not a second lifecycle registry.

Durable records and transient streams never alias. The client caches wrapped
durable rows by strand, width, and detail mode, and rewraps only the changing
stream fragments. When the durable assistant entry arrives, it clears that
strand's fragments and becomes the sole transcript authority. Model-authored
terminal controls are replaced before Mork or etui sees them; source blocks
retain their bytes and indentation without executing ANSI or HTML.

`loom --demo` runs a canned local model without a server or network. Plain
`loom` resolves the private session for the current workspace and starts or
reuses `loomd`. Manual attachment instead requires `--addr`, `--session`, and
`--token-file` or `--token`. The release is a separate Erlang shipment rather
than part of the server archive. It does not carry a second ERTS, so the
terminal host needs compatible Erlang/OTP 29 on `PATH`.

## Recording and replaying a session

`--record <path>` qualifies any interactive launch and writes one JSON line
per event as it arrives: every key, paste, resize and wheel notch, and every
message the websocket inbox delivered, each with its monotonic offset from
the start of the run. Ticks and the mouse events `update` ignores are left
out, because replaying them would change nothing. A gateway frame is stored
as the gateway's own bytes; the three connection lifecycle messages, which
are not wire frames, carry a tag of their own.

`loom replay <path>` plays that file back through `tui/virtual_backend` — an
etui backend whose `poll` answers a script instead of a file descriptor —
and prints a frame as plain text. It installs no terminal state and opens no
socket, so an agent with no terminal can see what the client would have
drawn. `--all` prints every frame with its index, `--at <n>` picks one,
`--width` and `--height` set the screen until the recording's own first
resize supersedes them. An unreadable or undecodable recording exits
non-zero naming the file and the line; so does a frame index the recording
does not reach. The replay's footer shows a fixed `replay` workspace,
because a recording carries none and a frame that changed with the shell it
was replayed from would be a poor answer.

**A replay reproduces inbound traffic and rendering, and never an outbound
effect.** It writes to no socket, starts no daemon, reads no local session
catalogue, and invents no line the live client would have been sent.
`tui.Peer` is what makes that structural rather than remembered: `Attached`
carries the websocket and sends, `Preview` is `--demo` and answers a prompt
with its canned echo, and `Replaying` performs only the local half of the
live path — the draft clears, the strand is marked submitting, the notice
changes — while the turn the server echoed arrives from the recording as an
ordinary entry. Every submit and command site enumerates the three. The
footer's tokens-per-second follows the same rule: the window it reports is
this client's own clock from a request going out to its settlement, and a
replay spends that window reading a file, so a replay leaves it unset rather
than reporting its own speed. The catalogue goes the same way: a connected
client empties the demo models the launcher seeds, so a replay does too, and
one whose recording carried no models snapshot opens the empty selector the
live client opened.

`/sessions` is the one place a replay knowingly draws what no live client
could. The command reads the local launcher catalogue, which a replay must
not touch and a recording does not carry, so it answers with a notice saying
the command is not replayed — where the live client either opened the
selector or said the command is local-only. The alternative is to invent one
of those two answers, which is the thing `Peer` exists to prevent, so the
divergence is deliberate and is recorded here rather than hidden.

Only the last frame of a replay is reproducible across runs. The client
renders a paced event's frame or leaves the previous one on screen depending
on how long ago it last drew, so which of the two `--at` and `--all` show for
a key press depends on the machine; the settling tick that ends a replay is a
flush point, so that frame is always the current one. Making every frame
reproducible needs an injected clock, which is separate work.

Two protocol behaviors remain deliberately incomplete. Pending escalations are
visible, but the native client does not yet send protocol-change/007's exact
action-and-grant echo, so it cannot approve or deny. A dropped websocket ends
the current connection; automatic reconnect and sparse-sequence catch-up remain
follow-up work. The server's approval and replay contracts are unchanged, and
the client never claims either operation succeeded locally.

## Installing an extension

`loomd` grew its first subcommand with `loom ext`, and it is an operator
surface rather than a model one: `install`, `list`, `remove`, `verify`,
no daemon, no hot install. The session server reads the install records
at boot and nothing re-reads them while it runs — the same
restart-to-change posture `client/catalog` takes toward `loom.toml`, with
the one difference the extension ruling names, that here the approval is
*recorded* rather than implied by an edit.

Every failure names the layer it came from, and there are six of them —
fetch, extract, manifest, vetting, compile, record — over a pipeline that
resolves the source, fetches it (or copies a local directory), extracts
it, prunes it to the extension's own tree, decodes the manifest, vets the
package, compiles it, and writes the record.
Naming the layer is the point of the type rather than a nicety. An
extension is somebody else's repository, and the person reading the
refusal is usually not the person who can fix it, so "vetting:
src/w/nif.gleam: an `@external` is not permitted" is forwardable and
"install failed" is not.

Three properties are worth stating on their own.

**The record is written last and the tree is renamed into place after
it.** Everything happens under `<root>/.staging/<random>/`, so a
directory under `~/.loom/extensions` is either a complete install or
absent, and there is no state in which a half-installed extension is
discoverable. Every failure removes its staging directory, including the
ones that happen after a build has written megabytes into it. A name
already taken is refused rather than overwritten: replacing an install is
remove-then-install, so nobody loses a working extension to a failed
reinstall.

**The install is content-addressed from the moment it is recorded.** The
record carries the digest of the *installed* tree — what survives the
prune, not what the archive carried — the manifest hash, the allowlist
and the net policy the source was vetted against, and the resolved
revision. `client/extension/installed` re-derives each of them from
disk on every read and refuses the extension when any disagrees — so one
edited byte under `src/` refuses it until it is reinstalled, whatever the
remote did afterwards. The allowlist is *stored* rather than recomputed
for the same reason: recomputing it would mean an operator's yes silently
followed the harness's current idea of the seam, and storing it turns a
widened seam into a question.

**The compile is the code-mode build, not a second one.**
`serve.start_build_plane` is the boot's own helper ladder, helper pool,
broker, toolchain discovery and seed verification, factored out so the
installer calls it rather than reimplementing it: two implementations
would be two answers to "may this build run", and the whole point of the
hermetic build is that there is one. The extension's own `gleam.toml`
never reaches the compiler — the build root's is generated from
`compile.default_dependencies` — so a dependency an author named would
fail the build rather than enter it, and vetting refuses it before that
anyway.

The terminal client forwards rather than reimplements: `loom ext …`
locates `loomd` by the same ladder an implicit local session uses, runs
it, streams its output through and exits with its status. Two ladders
would mean installing an extension into one server's world and then
starting another.

`docs/architecture/extensions.md` is the whole of it from the extension's
side: the two tiers, the seam, the manifest, brokered egress and the
secret bindings, and what stands built against what is still planned —
including phase 3's persistent satellite, which is what the section below
dispatches onto.

## Dispatching an extension

The install is half of it. The other half is a boot that finds what was
installed and a tool call that spends a jailed node.

`serve.assemble` reads `installed.discover(record.root_for(Settings.home))`
before it builds the registry. A `Refused` is logged under
`extension.refused` and registers nothing — an operator who installed
something and then sees nothing has no way to tell "it is broken" from "I
imagined installing it". A `Ready` on a host with no code-mode toolchain
is logged too and registers nothing, because no `erl` means no satellite
to boot and a tool definition that can only fail still renders into the
provider's cached byte prefix on every request. Everything else becomes
one `contributions.Contribution(Extension(name), tools)`, appended after
the built-ins, and a repeated name refuses the boot.

A call to one of those tools is **one invocation of a satellite the
session already holds open**. `client/extension/hosts` is a supervised
per-session actor keeping at most one `satellite.Host` per installed
extension, launched lazily on that extension's first use, and
`client/extension/dispatch` asks it rather than starting a node itself.
The host's work directory is keyed on the extension's *name*
(`client/codemode.host_root`) rather than on the `{op_id, step_id,
source_index}` a `code_mode` execution uses, because a host outlives all
three — and the two key spaces stay disjoint, so an extension call and a
`code_mode` call in one assistant message still cannot share a socket or
a token file. Latency is one node launch per extension per session and no
build, because the build happened at install.

Authority does not follow the node. The host mints a token bound to the
invocation's `{op_id, step_id}`, sends it on the `hook_call`, and revokes
it when the `hook_result` comes back, so an actor an extension kept alive
between calls is refused `unauthorized` if it reaches for a capability.
The registry serialises invocations on its own mailbox — deliberately
session-wide rather than per-extension, since an extension tool is
`tool.Exclusive` anyway — and a host the satellite lost is `Gone` for the
rest of the session rather than quietly restarted.

The router an invocation runs behind is
`docs/architecture/code-mode.md`'s "Dispatching an extension": the
extension arm answering `net.request` over the workspace bridge over
`satellite.default_router`. Two things about it belong here rather than
there. The `Ctx.grants` an escalation approval attributed to
*this call* are deliberately **not** composed onto the run phase: an
operator approved an extension once, at install, having read a manifest,
and a grant approved mid-run would widen the jail past the terms of that
approval. A `code_mode` call is the opposite case — the model wrote that
program in this turn and the human approved this turn's widening — and
does compose them. And the secret bindings' values are read by
`broker/egress` through the same `env_text` lookup `api_key_env` uses,
inside the request, and appear in no `Tool`, no frame, no `LaunchSpec`
environment and no log line.

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
| `client/serve.gleam` | The `loomd` entry point: flags, environment, boot order, `SIGTERM` shutdown. |
| `client/catalog.gleam` | The `loom.toml` model catalogue: strict parser, role chains, the provider-gateway builder, name lookups. |
| `client/grants.gleam` | The bridge between the runtime's stored escalation JSON and typed `broker/policy.Grant`; `first_unwanted`, the approval subset check. |
| `client/wiring.gleam` | The production effect seam over the real provider gateway, broker, and tool registry. |
| `client/contributions.gleam` | The tool registry as an ordered list of contributions, and the collision that refuses a boot. |
| `client/extension/manifest.gleam` | The total `extension.toml` decoder: tools, hooks, the net policy and its secret *names*. |
| `client/extension/record.gleam` | The install record and the `Root` value that says where installs live. |
| `client/extension/install.gleam` | The pipeline and its six named layers, the prune that runs first, the staging discipline, and the generated satellite entry. |
| `client/extension/installed.gleam` | Discovery: the five re-derivations that decide whether an install is still what was approved — the tree digest, the manifest, the vetting, the recorded allowlist and the artifact's own content address. |
| `client/extension/cli.gleam` | `loom ext install|list|remove|verify`, and the build seam over a started plane. |
| `client/extension/policy.gleam` | The manifest's `[net]` table as an `egress.Policy`, the per-invocation ceilings, and the refusal vocabulary. |
| `client/extension/seam.gleam` | The `net.request` router arm: msgpack in, msgpack out, no policy. |
| `client/extension/hosts.gleam` | The session's satellite registry: one host per installed extension, started lazily, serialising invocations, reaped on the way out. |
| `client/extension/dispatch.gleam` | An install record as `tool.Tool`s, and the invocation of the session's host for that extension. |
| `client/demo.gleam` | The M3 acceptance flow, driven through the protocol only. |
| `client/internal/ffi_crypto.gleam`, `.../ffi_file.gleam`, `.../ffi_os.gleam`, `client_ffi.erl` | Every external the package has, confined: constant-time compare, exclusive private file creation, clock, entropy, `PATH` lookup, the `SIGTERM` relay, and the documented halt. |
| `packages/client/protocol.md` | The normative ClientGateway body document. |
| `packages/client/testdata/protocol/` | The golden fixtures both implementations are pinned against. |
| `packages/tui/src/tui.gleam` | The terminal model, update loop, transcript, overlays, and command dispatch. |
| `packages/tui/src/tui/connection.gleam` | The websocket-owning actor and terminal inbox. |
| `packages/tui/src/tui/protocol.gleam` | Total event decoding and outbound command encoding. |

Each unqualified Gleam path is relative to its package's source root —
`client/gateway.gleam` is `packages/client/src/client/gateway.gleam`. For the operation model
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

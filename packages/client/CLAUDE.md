# client

## Purpose

The ClientGateway and the session server: the outward face of a live
session. It owns the Part 1.6 websocket protocol as total Gleam codecs,
a per-session hub actor that speaks it to any number of attached
connections, the `mist` websocket transport under that hub, the bridge
that decodes stored escalation JSON back into typed broker grants, the
scripted end-to-end demo that drives the whole M3 flow through the
protocol alone — and, as the tree's host package, the production wiring
adapter (`client/wiring`, promoted from conformance) plus the
`loom-server` entry point (`client/serve`) that boots the whole stack
over one session file. WP-L.

## Key Types

- `client/protocol.{CommandEnvelope, Command}` — the client→server
  envelope `{v, id, cmd, body}` and its fourteen commands (`Subscribe`,
  `CatchUp`, `Prompt`, `Steer`, `FollowUp`, `Abort`, `Approve`, `Deny`,
  `Fork`, `Navigate`, `Compact`, `CreateStrand`, `ListModels` (wire
  name `models`), `SetConfig`) plus `UnknownCommand`, which keeps an
  unrecognized name as data.
- `client/protocol.{EventEnvelope, Event}` — the server→client envelope
  `{v, reply_to?, event, seq?, body}` and its events (`SnapshotEvent`,
  `EntryEvent`, `OpTransitionEvent`, `StreamDeltaEvent`, `UsageEvent`,
  `EscalationEvent`, `StrandResultEvent`, `ErrorEvent`, `UnknownEvent`),
  with `Snapshot`, `Strand`, `LiveOp`, `EntryRecord`, `EscalationRecord`,
  `Denial`, and `ModelInfo` as the body shapes (`ModelsSnapshot` is the
  `models` command's reply).
- `client/protocol.ProtocolFault` — what a malformed frame decodes to;
  nothing here crashes.
- `client/gateway.{Gateway, Options, Message, start}` — the hub actor,
  one per served session, over a `runtime/api.Runtime`.
- `client/gateway.{attach, detach, handle_text}` — the transport seam: a
  connection is a `fn(String) -> Nil` sink, inbound frames arrive as
  text, and nothing in the module knows about sockets.
- `client/gateway.{commit_forwarder, tap_provider}` — the two
  composition-layer seams: the runtime writer's post-commit publication
  becomes a pull hint, and an injected `effects.ProviderSurface` is
  wrapped so provider deltas tee to the hub while the runtime's effect
  process consumes the stream unchanged.
- `client/server.{Config, Auth, Server, serve}` — the `mist` websocket
  transport on `/v1/ws`; `LocalAuth(token_path)` mints a startup token
  into a `0600` file, `BearerAuth(token)` is the caller-supplied one.
- `client/grants` — decoding the runtime's opaque escalation JSON back
  into `broker/policy.Grant`, and encoding it again. Pure and total.
- `client/catalog.{Catalog, CatalogModel, Dialect, parse, gateway}` —
  the model catalogue: a total, strict parser for the `loom.toml`
  format (via the `tom` TOML package; `docs/examples/loom.toml` is the
  worked example) and the builder that turns a catalogue into the
  provider gateway's registry — one provider per entry, named by the
  entry (so durable identities store `{catalogue-name, model_id}`),
  one route per `[roles]` row. The hub serves it as the `models`
  listing and resolves `set_config`'s `model_name` against it; `serve`
  loads it from `--config` or shapes a one-entry catalogue from the
  `LOOM_*` environment.
- `client/demo.run` — the M3 acceptance flow end to end, executed as a
  test and runnable as `gleam run -m client/demo`.
- `client/wiring.{Config, build_effects}` — the production effect seam:
  a `runtime/effects.Effects` over the real provider gateway, broker,
  and tool registry (promoted from `conformance/wiring`; spec-gaps M2
  item 7). The conformance wiring/e2e suites still prove it.
- `client/serve.{Settings, boot, shutdown, main}` — the server entry
  point (`gleam run -m client/serve`, `bin/loom-server` via the erlang
  shipment): flags/env in, session + helper pool + broker + runtime +
  hub + websocket server up, one startup line out, `SIGTERM` closes the
  runtime so the lease is released. `client.main` delegates here for
  the shipment's entrypoint.

## Relationships

- **Depends on**: `core` (json, codec, entries, messages), `session`,
  `runtime` (`api`, `effects`, `escalation`, `supervisor`, `writer`),
  `events` (the bus as a hint source), `storage` (catch-up scans),
  `machine` (`acceptance`, `queue`, `codec` — the commands with no api
  entry point build their own plans), `broker` (`policy.Grant`,
  `escalation` vocabulary), `provider` (`stream.Delta` for the tap),
  `mist` + `gleam_http` (the websocket transport), `simplifile` (the
  token file).
- The spec DAG (§0.1) writes `L → A,C,E,K`. The `B`, `D`, `F`, and `G`
  edges are real and load-bearing — catch-up scans storage directly,
  compaction and navigation build `machine/acceptance` plans, the delta
  tap types against `provider/stream`, and grants are broker policy
  values — and are worth knowing about rather than papering over. The
  wiring promotion added `tools` (the registry and per-call `Ctx`);
  `client/serve` added `argv` (flags); `client/catalog` added `tom`
  (the pure-Gleam TOML parser behind `--config`).
- **Depended on by**: `conformance`, whose wiring and e2e suites import
  `client/wiring` (legal — T depends on all). `packages/tui` is its Go
  client, coupled only through the protocol and the golden fixtures.
- **FFI**: `client/internal/ffi_os` over `client_ffi.erl`, serve-only:
  wall clock, unique entropy, `PATH` lookup, the SIGTERM relay, and the
  documented exit-code halt. Test-side, `client_test_ffi.erl` is a
  minimal websocket probe for the boot smoke.

## Traffic

- **Actor messages**: `gateway.Message` — `Attach(sink, reply)` (a call,
  returning the connection id), `Detach(connection)`,
  `FromClient(connection, text)`, `CommitHint`, `BusHint(published)`, and
  `ProviderDelta(operation, delta)` (casts). Senders: `client/server`'s
  socket handlers, `commit_forwarder` (from `runtime/writer.Event`),
  `events/bus` subscriptions, and `tap_provider`'s wrapper.
- **Commits**: the hub commits nothing of its own except through the
  session's one writer. Commands map onto `runtime/api`
  (prompt/steer/follow-up/abort, escalation approve/deny, strand
  creation); `compact` and `navigate`, which have no api entry point yet,
  build a `machine/acceptance` plan and commit it through
  `runtime/writer` — the same pattern the conformance simulation runner
  uses. Nothing bypasses the writer.
- **Registers**: reads `strand.*` (configuration, leaf, state, last
  result) and `op.meta`/`op.state` through the session's typed accessors
  to build snapshots and detect terminals; reads the runtime's escalation
  records under `fact.custom`'s reserved `escalation/` prefix. Strand
  seeding for protocol `fork` and `create_strand` writes `strand.config`
  / `strand.leaf` / `strand.state` (the api's creation path always takes
  a task brief, so the gateway seeds idle strands itself).
- **Wire**: JSON text frames over websocket. The envelope `seq` **is the
  storage seq** of the write that produced the event, so the durable
  stream needs no side index and `catch_up` rebuilds it with
  `scan_entries` / `scan_usage` plus register reads.

## Invariants

- **Envelope decoding is strict; name decoding is tolerant.** `v` must be
  `1`, the discriminator must be present, and a command `id` must be
  present and positive. Unknown `cmd`/`event` *names* survive as
  `UnknownCommand` / `UnknownEvent` so the receiver can answer in band;
  unknown *fields* inside known bodies are ignored (forward compatibility
  within v1).
- **Everything in `protocol` is pure and total.** Malformed input is a
  `ProtocolFault` value, never a crash.
- **Durable JSON crosses verbatim.** Gateway-defined field names are
  `snake_case`, but values that already have a durable form in the
  harness — entries, messages, usage — are carried in `core/codec`'s
  vocabulary (pi field names, camelCase) rather than re-rendered.
- **The wire form is pinned by the Go golden fixtures** under
  `packages/tui/internal/proto/testdata/`, which this package decodes and
  re-encodes byte for byte. Three details differ from `core/codec` and
  the wire follows the fixtures: `toolCall` blocks nest under a
  `toolCall` key, `thinking` blocks always carry `redacted`, and floats
  print positionally (`0.00027`, not `2.7e-4` — see
  `protocol.to_wire_text`). Changing either side is a protocol change,
  never silent drift.
- **Immutable rows replay exactly; register-backed events replay as
  current state.** `entry` and `usage` events are scanned by seq range,
  so a resume reproduces them; `op_transition`, `escalation`, and
  `strand_result` are read from registers, which keep no history, so a
  superseded phase is not reconstructible. Events are hints and the
  snapshot carries live state, so a client that missed an intermediate
  phase still converges — overlap and gaps are resolved by seq dedup, as
  the protocol already requires.
- **Live materialization is a pull, never an apply.** Both the writer's
  post-commit publication and any bus publication merely trigger a pull
  from storage above the hub's high-water seq; a lost hint costs latency,
  never an event.
- **Stream deltas are ephemeral.** They are broadcast without a seq,
  never persisted, and the tap lives entirely in the composition seam —
  the runtime is untouched by it.
- **Every upgrade without the exact bearer token is answered `401`**
  before any websocket state exists. `LocalAuth` binds loopback and puts
  the token in a `0600` file next to the session, moving the
  peer-credential check into the filesystem, because `mist` has no
  unix-socket listener to carry `SO_PEERCRED`.
- **Approved grants are validated structurally against the wanted diff**
  before being stored back in the runtime's internal vocabulary, so the
  consume path hands a re-execution exactly what was approved.

## Deep Docs

- [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md)
  — the runtime surface the hub dispatches onto.
- [docs/architecture/durability.md](../../docs/architecture/durability.md)
  — seqs, write-once rows, and why the event stream needs no side index.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-L (`client`)":
  escalation attribution, the missing compaction/navigation api entry
  points, brief-less strand creation, protocol fork forking in place,
  fixture-versus-codec drift, queued-versus-placed acks, and the provider
  delta tap.
- [packages/tui/CLAUDE.md](../tui/CLAUDE.md) — the other end of the wire.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.

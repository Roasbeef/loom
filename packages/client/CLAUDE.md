# client

## Purpose

The ClientGateway and the session server: the outward face of a live
session. It owns the Part 1.6 websocket protocol as total Gleam codecs,
a per-session hub actor that speaks it to any number of attached
connections, the `mist` websocket transport under that hub, the bridge
that decodes stored escalation JSON back into typed broker grants, the
scripted end-to-end demo that drives the whole M3 flow through the
protocol alone — and, as the tree's host package, the production wiring
adapter (`client/wiring`, promoted from conformance), the system
prompt's assembly and its durable pin (`client/system_prompt`), the two
seams that give a model other agents and code mode (`client/agency`,
`client/codemode`), plus the
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
  `with_catalog` and `with_registry` supply the two things `set_config`
  validates against: the model catalogue behind `model_name`, and the
  live tool registry behind `active_tools` (the same registry the
  effect wiring dispatches through; without one, active-set changes are
  refused in band).
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
- `client/agency.{Config, Message, seam, start, reaping_hooks,
  child_name, is_subagent, frame_message, frame_brief}` — the Agency:
  `tools/agent`'s messaging seam implemented over a live runtime. `seam`
  closes over a process *name* so it can be built before `api.open`;
  `start` puts the returned runtime behind that name. Everything with
  teeth lives here — the descendant-only addressing rule, the depth and
  fan-out caps, the multi-handle wait loop, the lineage ledger's four
  reconciliation branches, the lazy deadline reap, and the framing that
  marks another agent's text as data.
- `client/codemode.{Config, Toolchain, seam, discover, default_config,
  execute, exec_config, build_config, exec_root, execution_policy,
  translate, pooled_budget}` — code mode: `tools/codemode`'s seam
  implemented over the real pipeline, the other package this one exists
  to join (`tools` cannot see `codemode`, which already depends on it).
  `discover` locates `gleam`, `erl` and a verified build seed or says
  what is missing; `seam` closes over a `Config` and needs no process
  name, because the broker it dispatches through already exists;
  `execute` prepares a per-execution directory, drives vet → compile →
  run under the caller's own `{op_id, step_id}`, drains the enforcement
  reports and removes the directory again.
- `client/system_prompt.{Host, Rendered, Assembled, Origin, assemble,
  render_pack, pack_source, guidance, pinned_in, pinned, pin}` — the I/O
  half of the pure `prompt` package. `Host` is every `pack.Environment`
  field gathered from a real source; `pack_source` picks the shipped pack
  or the one `LOOM_PROMPT_PACK` names; `render_pack` renders it or
  refuses; `assemble` chooses between the `LOOM_SYSTEM_PROMPT` override,
  the pinned cell and a fresh render; `pinned_in`/`pinned`/`pin` are the
  two ends of the reserved `prompt/` cell. Nothing here is called per
  turn — the whole module runs once, at boot.
- `client/wiring.{Config, build_effects}` — the production effect seam:
  a `runtime/effects.Effects` over the real provider gateway, broker,
  and tool registry (promoted from `conformance/wiring`; spec-gaps M2
  item 7). The conformance wiring/e2e suites still prove it.
- `client/serve.registry(Option(Agency), Option(CodeMode))` — the tool
  registry: five core tools, plus the six `agent_*` tools only when a
  messaging plane exists, plus `code_mode` only when this host wired a
  code-mode pipeline.
- `client/serve.Booted` — what `shutdown` takes apart, plus
  `prompt: system_prompt.Assembled`: the exact bytes this boot handed the
  wiring, so a test can prove the pinned prompt is the one on the wire
  and the startup line can name its digest.
- `client/serve.{Settings, boot, shutdown, main}` — the server entry
  point (`gleam run -m client/serve`, `bin/loom-server` via the erlang
  shipment): flags/env in, session + helper pool + broker + system
  prompt + runtime + hub + websocket server up, one startup line out,
  `SIGTERM` closes the runtime so the lease is released. `client.main`
  delegates here for the shipment's entrypoint.
- `client/serve.{shell_path, base_policy, degraded, helper_probe_ms}` —
  the host facts the system prompt and the jail must agree on: the shell
  jailed commands run under, the session's composed base policy, and the
  one question the prompt has no other source for — whether a helper's
  hello advertises `degraded`, asked once at open by borrowing from the
  pool the session will use anyway.

## Relationships

- **Depends on**: `core` (json, codec, entries, messages), `session`,
  `runtime` (`api`, `effects`, `escalation`, `supervisor`, `writer`),
  `events` (the bus as a hint source), `storage` (catch-up scans),
  `machine` (`acceptance`, `queue`, `codec` — the commands with no api
  entry point build their own plans), `broker` (`policy.Grant`,
  `escalation` vocabulary), `provider` (`stream.Delta` for the tap),
  `prompt` (the pack, its decoder and its renderer),
  `codemode` (the vetting policy, the hermetic compile service, the
  production builder and launcher, and the satellite host — the pipeline
  `client/codemode` fills the `tools/codemode` seam with),
  `mist` + `gleam_http` (the websocket transport), `simplifile` (the
  token file, the pack file, and the workspace's `CLAUDE.md`).
- The spec DAG (§0.1) writes `L → A,C,E,K`. The `B`, `D`, `F`, and `G`
  edges are real and load-bearing — catch-up scans storage directly,
  compaction and navigation build `machine/acceptance` plans, the delta
  tap types against `provider/stream`, and grants are broker policy
  values — and are worth knowing about rather than papering over. The
  wiring promotion added `tools` (the registry and per-call `Ctx`);
  `client/serve` added `argv` (flags); `client/catalog` added `tom`
  (the pure-Gleam TOML parser behind `--config`); `client/system_prompt`
  added `prompt`, whose purity is why the I/O had to live on this side.
- **Depended on by**: `conformance`, whose wiring and e2e suites import
  `client/wiring` (legal — T depends on all). `packages/tui` is its Go
  client, coupled only through the protocol and the golden fixtures.
- **FFI**: `client/internal/ffi_os` over `client_ffi.erl`, serve-only:
  wall clock, unique entropy, `PATH` lookup, `os:type`/machine
  architecture for the prompt's platform line, the SIGTERM relay, and the
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
  records under `fact.custom`'s reserved `escalation/` prefix, and the
  assembled system prompt under the reserved `prompt/` prefix — read off
  the session store directly before `api.open`, written back through
  `api.put_reserved_fact` after it. Strand
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
- **A strand's durable `active_tool_names` is canonical: sorted, with
  duplicates collapsed, and every name registered.** The list renders
  into the request's tool array, which sits ahead of the system prompt
  in the provider's render order, and prompt caching matches on an
  exact byte prefix — so a reordering costs both cache-head writes on
  every subsequent turn. The hub canonicalizes at the `set_config`
  boundary and `client/wiring.tool_specs` sorts again at render.
  Neither moves the authorization line: `wiring.clear` admits a call by
  `list.contains` on this same list, and set membership is blind to
  order and multiplicity.
- **The system prompt is assembled once, at a session's first open, and
  pinned.** Every later boot sends the pinned bytes rather than deriving
  them again — the agent may have edited `CLAUDE.md`, the kernel may have
  changed under a restart, a flag may differ, and a prompt re-derived
  from moved inputs is a full one-hour cache write on the first turn
  after every restart. The pin lives in the reserved `prompt/` cell, so
  no model-reachable `put_fact` can rewrite the operator's channel.
- **The pin is read before `api.open` and written after it.**
  `wiring.Config.system` must hold the string before the open, and the
  open is what stands the writer up — so the cell is read straight off
  the session store while nothing owns it, and written back through
  `api.put_reserved_fact` once there is a writer to journal it. Same knot
  as the Agency's, solved by ordering rather than by a name because the
  value is data, not a process.
- **Nothing volatile may enter `system_prompt.Host`.** No clock, date,
  elapsed time, token count, cost, git state, id, strand name or random
  value — and no numeric field at all, which is the shape all of those
  arrive in. The list fields are sorted and de-duplicated by
  `pack.environment` before they can reach the bytes, for the same reason
  the tool array is sorted: both sit inside the cached prefix.
- **A prompt pack refuses loudly or serves; it never disappears.** A pack
  file that cannot be read, does not decode, or renders to nothing stops
  the boot with a worded message naming the file and the fault — a
  silently-empty system prompt is the failure this seam exists to end. A
  pack that merely trips `pack.problems` (a dropped section, a misspelled
  placeholder) warns on stderr and serves: `decode` accepts more than
  `problems` approves by design, and a thin prompt beats a dead server.
- **The Agency is reached through a name, never through a captured
  runtime.** `api.open` takes the `Effects` record and returns the
  `Runtime`, and `Runtime` *contains* `effects` — so a closure reachable
  from `Effects` that captures the `Runtime` is a value cycle, not an
  ordering problem. `agency.seam` closes over a minted process name (the
  same indirection `gateway.commit_forwarder` uses) and `agency.start`
  stands a holder up under it after the open. The holder answers exactly
  one message and answers it with the runtime *value*: the tools do the
  work on their own effect process, because a holder that did the work
  would serialize every agent call in the session behind whichever one
  was inside a wait.
- **A strand may wait only on a descendant and address only its parent or
  a descendant** — decided from the durable lineage ledger, never from
  anything a model says. A strand with no lineage cell is a root and is
  nobody's descendant: "no lineage fact" fails closed. That is what makes
  the wait graph acyclic and a blocking `agent_wait` safe.
- **A reap does one thing on the driver process: `spawn_unlinked`.**
  `Hooks.run_end` fires inside `drive_loop`, on the driver, before any
  `actor.continue` — so a hook that read a register would be a
  `call_forever` from the driver and a hook that waited would stop it
  serving `Nudge`, `RequestAbort` and `PollTick`, which is exactly the
  property that makes a blocking tool safe. Every read, abort and commit
  a reap performs happens on the spawned process. The hook carries no
  strand and does not need one: a lineage cell records the *operation*
  that minted it, so "reap what this run spawned" is a ledger predicate.
- **A reap's intent is durable and its abort is re-issued.** `api.abort`
  is a no-op when no driver is registered, so a reap that landed
  mid-restart would otherwise evaporate and the child would run until the
  session closed. The mark is written once and every later observation
  re-issues the abort.
- **The blackboard is clamped on both sides.** `agent_note` writes under
  `agent/{caller}/`; `agent_notes` with no prefix reads `agent/` and not
  the whole non-reserved fact namespace, which is what
  `api.facts(prefix: None)` would hand back.
- **A report into a *finished* parent is refused.** `api.send_to_strand`
  accepts a fresh run when the target is idle, which would wake a
  finished parent with no human present — the exact property auto-
  enqueued child results were rejected over. The refusal is upward only:
  a parent giving an idle child more work is a live agent's explicit
  decision inside its own run.
- **A code-mode execution runs under the calling strand's own
  `{op_id, step_id}`.** The hermetic build, the jailed `erl`, and every
  capability call the running program makes are dispatched under that one
  pair, which *is* the execution identity the broker pools budget under —
  so the compile and the run share one ledger and one wall deadline
  rather than minting a second budget, and `broker.abort` on the
  operation reaches the build and the node alike. The pooled
  outstanding-effect cap is never below two: the node holds one for its
  whole life.
- **The only thing the code-mode wiring adds to a session base is two
  environment *names*.** `LOOM_CAP_SOCK` and `LOOM_CAP_TOKEN_FILE` are
  set by the launcher and cannot be shadowed by a caller's `env`, but
  policy composition takes the meet — so a base that does not name them
  composes them away and the satellite cannot find the channel it exists
  to speak on. `execution_policy` adds exactly those two and leaves every
  other dimension untouched; it is one small named function so it stays
  auditable rather than diffusing into the wiring.
- **An execution's files live in their own directory inside the
  workspace,** named for `{op_id, step_id}` and removed when the
  execution settles. Inside the workspace, so the session base already
  makes it writable and nothing has to be widened to build there; unique
  per execution, so two strands running code mode at once cannot share a
  build root. The directory's name is a short digest of that pair rather
  than the pair itself, because the cap socket sits inside it and an
  AF_UNIX path is capped near 108 bytes — a socket that would exceed the
  limit is refused in band, naming the workspace, instead of failing as an
  opaque `einval` from `listen`.
- **Registration is gated on the seam, for both families.** A host with
  no messaging plane ships no `agent_*` tools and a host with no
  toolchain or no prepared build seed ships no `code_mode` — the boot
  says which is missing, once, on stderr. The wire tool array is the byte
  prefix of the provider's cached region, so a permanently-refusing
  definition would be paid for on every request of every strand for the
  life of the session.
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
- [docs/design-notes/agent-comms-and-system-prompt.md](../../docs/design-notes/agent-comms-and-system-prompt.md)
  — Part B: the pack's sections, the stability contract, and why
  the prompt is pinned rather than re-derived.
- [docs/review/m5-agent-comms-judgment.md](../../docs/review/m5-agent-comms-judgment.md)
  — change items 5 and 6, which the sandbox wording and the
  pin-around-the-lease ordering follow.
- [docs/architecture/code-mode.md](../../docs/architecture/code-mode.md) —
  the pipeline `client/codemode` wires, and what each layer confines.
- [packages/codemode/CLAUDE.md](../codemode/CLAUDE.md) — the pipeline's
  own package.
- [packages/prompt/CLAUDE.md](../prompt/CLAUDE.md) — the pure half:
  the pack format, the renderer, and what `Environment` may never grow.
- [packages/tui/CLAUDE.md](../tui/CLAUDE.md) — the other end of the wire.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.

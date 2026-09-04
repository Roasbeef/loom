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
prompt's assembly and its durable pin (`client/system_prompt`), the four
seams that give a model other agents, code mode, recall over the
repository's own history and a memory that outlives a session
(`client/agency`, `client/codemode`, `client/history`, `client/memory`),
the distillation pipeline that fills that memory
(`client/distill`, a second entry point), plus the
`loomd` entry point (`client/serve`) that boots the whole stack
over one session file. WP-L.

## Key Types

- `client/protocol.{CommandEnvelope, Command}` — the client→server
  envelope `{v, id, cmd, body}` and its seventeen commands (`Subscribe`,
  `CatchUp`, `Prompt`, `PromptContent`, `Steer`, `FollowUp`, `Abort`,
  `Approve`, `Deny`, `Fork`, `Navigate`, `Compact`, `CreateStrand`,
  `ListModels` (wire name `models`), `SetConfig`, `ListSchedules` (wire name
  `schedules`), `CancelSchedule` (wire name `schedule_cancel`)) plus `UnknownCommand`,
  which keeps an unrecognized name as data.
- `client/protocol.{EventEnvelope, Event}` — the server→client envelope
  `{v, reply_to?, event, seq?, body}` and its events (`SnapshotEvent`,
  `EntryEvent`, `OpTransitionEvent`, `StreamDeltaEvent`, `UsageEvent`,
  `EscalationEvent`, `StrandResultEvent`, `ErrorEvent`, `UnknownEvent`),
  with `Snapshot`, `Strand`, `LiveOp`, `EntryRecord`, `EscalationRecord`,
  `Denial`, and `ModelInfo` as the body shapes (`ModelsSnapshot` is the
  `models` command's reply).
- `client/protocol.{ListSchedules, CancelSchedule, SchedulesSnapshot,
  ScheduleInfo, ScheduleWake}` — the operator's scheduling surface,
  `protocol-change/013`. `schedules` `{}` lists every schedule the
  session holds — operator `[[schedule]]` tables first, then every live
  model-created cell — as a `snapshot` mode `schedules`; `schedule_cancel`
  `{target, name}` retires one model-created schedule and replies with
  **the listing as it stands after the cancel**, so a client re-renders
  from one round trip. A row is `{name, target, owner, when, wake, fired,
  body}`, every field always present: `{target, name}` is a schedule's
  durable identity, which is why both are required on a cancel; `owner`
  is the wire string a client renders (`"operator"`, or the owning
  strand's name) rather than a discriminated type, because the host knows
  which kind a row is and a client cannot; `when` is
  `scheduleseam.describe_timing`'s rendering, printed verbatim and never
  parsed; `wake` is the wire's one boolean here, and in Gleam it is
  `ScheduleWake { WakesIdle | SteersOnly }` with the boolean confined to
  the codec — 012 declined the "frozen contract" escape for a `Bool`
  while the field was still being minted. Refusals: an operator table is
  `conflict` naming the configuration file and the restart; nothing live
  is `bad_request` (a name never used and one already cancelled are the
  same absence, since the store keeps no tombstone); a hub with no
  scheduling plane answers `schedules` with an empty listing on the
  `models` posture and `schedule_cancel` with `unsupported`, because a
  cancel that cancelled nothing must never read as one that worked.
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
  wrapper forwards explicit cancellation and monitors that effect process;
  either cancellation or consumer death tears down the inner handle. The
  forwarder registers under a name and the writer subscribes to that
  name, which is what lets it be supervised and restarted without the
  writer noticing.
- `client/provider_relay.{prepare, wrap}` — the shared provider-wrapper
  ownership seam: `prepare` returns a minimal public custodian before it
  releases the guard, while `wrap` is the prepare-and-begin compatibility
  facade. The
  guard remains the inner surface's direct consumer, and a separately
  monitored observer runs the synchronous callback before each event is
  forwarded. The guard installs its drain monitor on the inner owner before
  `begin`, and the custodian
  adopts the guard, leaf observer, and transitive inner stream owner before
  each begins work. A terminal is not forwarded until that original monitor
  reports a normal exit. Cancel travels inward, an unacknowledged cancel
  becomes terminal `CancellationUnconfirmed` after one fixed grace, and the
  custodian remains alive until the registered subtree drains. Guard or
  observer death becomes a prompt in-band transport failure only after that
  drain is proved.
  The guard itself is a **`weft/state_machine`**, started `sm.unlinked` by the
  consumer it serves so a guard crash reaches the custodian's worker adoption
  rather than the consumer's link. Its state ADT is `Phase` — `Parked` (the
  wait for the begin permit), `Forwarding`, `Cancelling`, and the three ways
  this relay ends (`ProvingTerminal` holding the terminal the observer has
  already seen, `ProvingFailure` bounding the drain wait after the relay's own
  worker failed, `Proving` waiting out an answer already sent or deliberately
  withheld). Its data is `Awaiting` before the permit and `Relaying` after it,
  which is where everything that moves per event lives: the outstanding
  observation, the events queued behind it, and the inner owner's drain proof.
  Both deadlines are therefore structural rather than scheduled: the
  cancellation grace is a **state timeout** on `Cancelling`, which is what
  makes it one fixed proof deadline a flood of late deltas cannot renew, and
  the request deadline is an **event timeout** re-armed by each forwarding
  step that leaves the guard waiting on the inner stream. A parked guard
  selects three things — the permit, the control subject, its consumer's
  monitor — because the stream's own channels are created by the work the
  permit authorises, in that process; the same step that grants the permit and
  transitions to `Forwarding` or `Cancelling` widens the mailbox with
  `sm.with_selector`.
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
  `loom` binary against a real `serve.boot`, in a real terminal
  (`tmux` on a private socket, declared geometry, every wait a predicate
  over pane content with a deadline). The only test in the tree with a
  fake on *neither* side of the protocol; only the model is scripted.
  Skips — loudly — when `tmux` or `go` is absent.
- `client/agency.Config.subagent_model` — the host's `subagent` route,
  resolved, as a closure: `Ok(#(identity, thinking))` seeds a spawned
  child with that model and that level, `Error(Nil)` inherits the parent
  wholesale. A closure for the same reason `clock` and `rest` are — the
  Agency is built before `api.open`.
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
  inside them. `owns(runtime, ancestor:, strand:)` is the addressing rule
  exposed for a seam outside the messaging plane —
  `client/scheduleseam` asks it whether a schedule's target is a strand
  the caller spawned — and it fails closed at every step: an unreadable
  ledger, a strand with no cell and a cell that will not decode all
  answer `False`, and the relation is strict, so a caller meaning "itself
  or a descendant" says so at its own door. `is_subagent` is not a
  substitute: it says a name was minted by *an* Agency, not by whom, and
  a sibling's name is shaped exactly like a child's.
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
- `client/codemode.{workspace_seam, over_scratch, into_blobs,
  blob_directory}` — the harness-side capability bridge (issue #16), and
  the half of it that lives on this side of the seam. `workspace_seam`
  builds the eight closures `codemode/workspace`'s router calls: `fs_read`
  and `fs_list` over `tools/fs.resolve_real` and `fs.read_text_file`,
  `fs_write` and `fs_edit` over `fs.resolve_writable` —
  the harness's *own* path boundary and *own* large-file guard, never a
  second resolution — `kv_*` over the session's `client/scratch` store,
  and `emit` over the session's blob root. `blob_directory` is the one
  place `.blobs` is written down, read by both this module and
  `client/serve`, so an artifact a program emits and an oversized `bash`
  output that overflowed land in one store under one address. Listing is
  the one operation with no counterpart in the tool set — `tool.FileSystem`
  has no primitive for it — so the enumeration is `simplifile`'s, on a
  path `resolve_real` has already contained, bounded before it is
  classified and answered with lstat semantics so a symlink is never
  called a directory.
- `client/history.{Config, Message, index_file, default_timeout_ms,
  index_beside, probe, over_session, sqlite_generation, start, supervised,
  stop, poke, synchronize, seam, commit_pull, supervised_commit_pull}` —
  the one process that owns this repository's `events/search` index, and
  the seams that reach it. Addressed by process name, like the Agency and
  the scratch store, so the tool seam is built before the holder exists
  and a restart under the same name reopens the index file. `probe` is
  the boot question: an index that will not open registers no
  `history_search` tool and logs one worded line, never a boot refusal.
  `over_session` binds the holder to one open session's store and takes
  its rewrite generation as a **thunk** (`sqlite_generation`), called
  fresh on every pull, because a precise rewrite bumps it underneath a
  long-lived holder — and a generation that cannot be read skips the sync
  rather than guessing zero.
- `client/notes.{max_digest_bytes, fence, digest_hooks, digest, cells,
  try_cells, strand_of}` — the `agent/` notes digest injected at run
  start, and the board read `client/checkpoint` shares. `cells` reads an
  unreadable store as an empty board — right for a digest, which a run
  is never held up for — and `try_cells` is the `Result` form the
  checkpoint asks, because publishing "you wrote no notes" over a store
  that did not answer would be a durable falsehood.
  `digest_hooks` **wraps** an existing `run_start` rather than setting it
  (`hooks.with_run_start` replaces, so a setter would silently drop a
  previous layer), resolves the strand from the `OpId` through the
  durable `op.meta` cell, reads the strand's `agent/{strand}/` fact cells
  straight off the session store — hooks are built before `api.open`, so
  there is no runtime handle and no Agency to ask — and renders them
  newest-written-first by register seq, capped at 4096 bytes, fenced and
  attributed. A strand with no notes gets nothing at all.
- `client/memory.{max_sidecar_bytes, digest_reader}` — the two halves of
  bounding the sidecar read, which the lifecycle producer moved onto the
  strand driver's hot path: `max_sidecar_bytes` (four times the render
  cap) is asked of the *file* by one `stat` before a byte is read, so a
  file that could not have come from `render_digest` costs nothing and is
  refused whole rather than clipped to a plausible prefix, while a file
  merely over the render cap is still read and clipped as before.
  `digest_reader` is the reader a server installs — the one that carries
  a logger, so a refusal says `memory.digest_oversize` instead of looking
  exactly like a repository that has never distilled. `read_digest` stays
  the silent door.
- `client/memory.{memory_file, digest_file, store_beside, digest_beside,
  directory_of, fact_type, lesson_type, preference_type, pipeline_types,
  type_named, short_name, max_digest_bytes, max_distillates,
  max_row_chars, lease_ttl_ms, run_lease_ttl_ms, head_key, cursor_key,
  notes_cursor_key,
  note_count_key, Cursor, cursor_from, cursor_value, MemoryFault, Opened,
  open, close, probe, SourceRef, Provenance, no_provenance, Distillate,
  distillate_of, provenance_of, provenance_by_id, names_source,
  append_distillates, head, head_rows, advance_head, replace_head,
  advance_cursors, NotesRewind, Rewind, no_rewind, cursor_rewind,
  cell, notes_after, safe_text, remember_seam, fence, render_digest,
  read_digest, write_digest, reconcile_digest, digest_hooks, wrapped}` —
  the memory plane: the
  `loom-memory.db` session beside the session files (the fold
  `client/history` established, deliberately *not* the workspace), the
  `loom-memory.digest` sidecar the server injects from, and the host side
  of the `remember` door. Opened with the ordinary writer lease and
  `session.ensure_id` called by hand, because nothing here goes through
  `runtime/api` — which is also why its bookkeeping cells need no
  reserved prefix. **The TTL is the caller's**, and the two callers are
  nothing alike: a `remember` write covers one commit, while a run's
  commits are separated by whole provider turns and it takes
  `run_lease_ttl_ms` so no opener can steal the file out from under a
  model turn (the `rewrite_lease_ttl_ms` precedent, and a constant rather
  than a renewal timer because a command has no supervision tree to hang
  one on). **`append_distillates` and `advance_head` are separate
  on purpose**: rows commit first, the head-and-cursors CAS commits last,
  and a run killed between them leaves the previous head, cursors and
  sidecar standing over inert orphan rows. `render_digest` writes the
  body only — scrubbed, byte-capped, truncation marked — and `wrapped`
  builds the fence and the attribution at injection time, so the file
  cannot forge its own provenance.
  The **erasure cascade's** reading surface is here too (#115).
  `provenance_of` is the total decoder of the `{text, sources, derived_from}`
  payload — anything it cannot read is `no_provenance`, which names
  nothing and is therefore *kept*, so one malformed row can never empty
  memory. `provenance_by_id` pairs each head id with what its row
  records, **one pair per id including ids the store cannot resolve**, so
  an unresolvable head id survives the rewrite rather than vanishing from
  it. `names_source` is the match, at session grain because provenance is
  batch-level. `replace_head` is the write: the head cell and the cursor
  rewind in one CAS, no rows, sharing `advance_head`'s expectation so the
  head only ever moves under a CAS. `cursor_rewind` computes that rewind
  (#124) — every `distill/cursor/*` cell wound back to seq zero under the
  generation it recorded, plus the notes cursor when a consolidation has
  consumed anything. Those cells *are* the pipeline's record of what it
  has read, so the prefix scan sees sources a directory walk at cascade
  time could not: a file a live server holds the lease on, a file since
  moved away. `no_rewind` is the empty one, which is what an ordinary
  head replacement passes.
- `client/distill.{Answer, Distiller, Candidate, Extract, Harvest, Report,
  Cascade, CascadeMode, Config, default_scan_limit, max_extract_chars,
  max_notes_per_run,
  default_timeout_ms, distill_owner, extractable, extraction_input,
  extraction_prompt, consolidation_prompt, parse_candidates, config_for,
  with_logger, run, cascade, no_distiller, source_files, target,
  gateway_distiller, main}` — the
  distillation pipeline, runnable as `gleam run -m client/distill --
  --config loom.toml [--session-dir <dir> | --session <path.db>]`. It
  walks the session directory's `*.db` files, skips every one whose
  writer lease is held (**that is the live-session rule, entire**), reads
  each above a `{seq, rewrite generation}` cursor, extracts, consolidates
  against the current head and the `remember` notes, and re-renders the
  sidecar. `extractable` is the anti-feedback exclusion and is a rule
  about types: settled assistant text (`client/rules.scannable_text`,
  shared with the rule scanner) plus compaction and branch summaries, and
  nothing from a user turn or a `CustomEntry`. `Distiller` is the whole
  provider surface, so a test scripts both model turns; `target` picks the
  `Summarize` route when the catalogue has one and the resolved main
  identity when it does not, the summary path's own arrangement.
  Two properties of the pass shape are load-bearing rather than
  incidental. **Only the sources extraction got an answer for** drive the
  cursors and the provenance: advancing a failed source's cursor would
  lose its entries permanently and silently, and naming it in provenance
  would over-claim a contribution #115's cascade would act on. And the
  consolidation turn is dispatched on what extraction **produced**, not
  on what it was offered — a repository whose sources all honestly answer
  `nothing` commits a cursors-only transaction, leaves the head alone,
  and does not re-pay the same extraction turns on every run forever.
  Every run, that one included, ends by reconciling the sidecar against
  the head.
  **`--cascade <source-session-id>` is the second command behind the same
  entry point** (`cascade`, issue #115): the first-order erasure cascade,
  run by the operator *after* `session/repo` has rewritten that source.
  It drops from the head every distillate whose provenance names the
  session and re-renders the sidecar without them. Five things about it
  are load-bearing. It **needs no `--config`** and runs under
  `no_distiller`, because it dispatches no model turn. It **writes no
  rows** — every survivor is already durable — so the pipeline's write
  order holds trivially, and it takes the *short* lease rather than
  `run_lease_ttl_ms`, since nothing slow sits between its commits. A
  cascade that drops rows **rewinds the cursors in the same CAS**
  (#124): a head is uniform in provenance, so an effective cascade
  empties it, and re-reading the surviving sources is the only rebuild
  there is, so `memory.cursor_rewind`'s cells ride inside
  `memory.replace_head`'s transaction. One transaction is the point — a
  crash between an emptied head and a separate cursor write would leave
  the head empty above high-water cursors, which is the unrecoverable
  state the issue described. The next ordinary pass re-extracts every
  readable source and folds the notes in again, which costs one
  extraction request per source plus one consolidation and is the only
  rebuild on offer; `distill_test`'s
  `an_emptying_cascade_rewinds_so_the_next_pass_rebuilds` drives the
  whole loop. **`CascadeMode` is the fifth**: `Preview` (`--dry-run`)
  computes the same answer — dropped, kept, rewound, notes — reports it
  and writes nothing at all, no CAS and no sidecar, so an operator sees
  the wipe and its price before paying either. And a cascade that
  drops nothing **does not CAS at all**, because writing the identical id
  list back would still bump the cell's seq and lose a concurrent run's
  expectation — so it rewinds nothing either. First-order: a row whose `derived_from` names a dropped
  row is not chased, and within one head that is vacuous rather than
  deferred. The induction is written out at `memory.replace_head` and
  needs **both** head writers: `advance_head` mints a fresh batch whose
  ids are disjoint from what its `derived_from` names, and `replace_head`
  writes a *subset* of an existing head, which preserves that
  disjointness. A third head writer introducing new ids would void it
  silently. The `Cascade` report carries an `unreadable` count — rows
  kept because their provenance would not decode, which is the one place
  the command under-deletes. `docs/spec-gaps.md`'s M2
  item 9 carries the boundary and the over-deletion it implies.
- `client/distillpass.{Cadence, Options, Pass, Config, Message,
  default_wall_ms, default_options, no_pass, parse, start, supervised,
  settled,
  started_event, completed_event, failed_event, expired_event,
  off_event}` — the distillation pass in the *session lifecycle* (#149):
  the supervised worker that makes `client/distill` run without a source
  checkout, a cron job or an operator. A `weft/state_machine` with two
  states — `Running` while the pass is in flight, `Idle(pass)` for the
  rest of the boot — started under the service tier by
  `serve.with_distill_pass`, which is *after* the session's own writer
  lease is held, so the live session is skipped by the pipeline's
  existing lease rule rather than by a new one. The pass itself runs on
  a `weft` scope bounded by `Options.wall_ms` and relayed back onto the
  machine's own subject, so the machine stays able to answer while it
  runs; `settled` is that answer, and a question asked mid-pass is
  `postpone`d and replayed on the transition rather than polled for. It
  **never re-arms**: one pass per boot is the whole cadence, and the whole
  retry policy is "the next boot reads the same material again", which is
  safe because the pipeline moves no cursor until it succeeds. `parse` is
  the total decoder for the `[memory]` table (`distill = "on-boot" |
  "off"`, `distill_wall_ms`), whose key must also be in `client/catalog`'s
  allowed top-level list — the obligation `[[rule]]` and `[schedules]`
  carry. `default_wall_ms` **is** `memory.run_lease_ttl_ms` and is also
  the ceiling: nothing renews the memory lease but a commit, so a pass
  cannot usefully outlive it, and a larger configured value is refused
  rather than clamped. `Cadence` is a two-variant type rather than a flag because the
  opt-out is a posture an operator takes deliberately.
- `client/scratch.{Bounds, Message, Scratch, start, supervised, stop, seam,
  none, stat, default_bounds}` — the ephemeral scratch store `cap/kv`
  reads and writes: a session-scoped actor, addressed by process name the
  way the Agency is, holding string keys to bytes. Three bounds, each on
  a different way to grow: 256 KiB per entry (refused in band), 8 MiB
  total and 1024 entries (both **evicted**, least-recently-written, which
  is what `cap/kv`'s "may be evicted or reset between calls" contract
  asks for). `Bounds` is a plain record, so `start` passes every one
  through `coherent` first — each field floored at 1, the per-entry
  bound never looser than the total — because a `max_entries` of 0 makes
  the store evict everything it is handed, which a program reads as
  unrelenting eviction and loops on rather than failing. Clamped rather
  than refused: this is a cache whose contract already says values may
  vanish. Gone on restart, deliberately — a store a program can write
  across sessions is a channel from one execution's model output into a
  later execution's input. `none()` is the seam a host with no store
  hands out, and it *refuses* rather than silently succeeding: a `set`
  answering `Ok` into nothing reads to a program as an eviction and it
  loops.
- `client/rules.{Rule, parse, fires_on, scannable_text, injection,
  fired_key, cursor_key, fired_value, cursor_value, cursor_seq,
  max_rules, max_triggers, max_name_length, max_trigger_length,
  max_body_length}` — the triggered project rule store (issue #27,
  design §8). A rule is `{name, triggers, body}` read from `[[rule]]`
  tables in the same `loom.toml` the catalogue comes from, parsed by the
  same strict, total discipline: unknown keys refused, empty and
  oversized fields refused, duplicate names refused, all in words an
  operator can act on. Rules are **operator configuration and never
  model-writable** — a rule is text the harness injects into a model's
  own context, so a store a model could write would be durable prompt
  injection with a delivery mechanism attached. Triggers are literal,
  case-sensitive substrings, any-of per rule, matched over an assistant
  entry's visible text through `events/search.entry_text` — no regex,
  because an operator-supplied pattern reached from model output is an
  unbounded computation driven by the thing being matched. `injection`
  is the fenced, attributed text a fire actually commits.
- `client/rulescan.{Options, default_options, with_logger, start,
  supervised, default_scan_limit, default_checkpoint_every}` — the
  session-scoped scanner actor. Its mailbox *is* `runtime/writer.Event`,
  so it is the writer's second named subscriber beside the commit
  forwarder; on each hint it re-reads the store above a durable cursor
  and never trusts the hint for anything. A fire is one
  `api.steer_marking` — the injection and the rule's write-once
  fired-mark in one transaction — so injected-never-twice is a property
  of the commit rather than of the actor's memory (at-most-once in
  full: the abort corner is `docs/spec-gaps.md`'s item 8). A rule that trips on an
  **idle** strand is *held*, not dropped and not started: the cursor
  stays frozen so the next run finds it again. A held strand the
  `runtime/lineage` ledger says was reaped is judged provably dead
  (issue #113) and **abandoned** rather than retried forever: the
  in-memory `Progress` gets a third state beside held-and-not, the
  pending rules stay unfired (nothing lies about what happened), and the
  transition is logged once, `rule.hold_abandoned`. A terminal
  `strand.last_result` alone is deliberately *not* this signal — see the
  next invariant — so the ledger read happens once per strand per
  incarnation, on the pass a hold begins, and costs nothing before or
  after.
- `client/schedule.{Schedule, Owner, Timing, Expiry, Wake, Lateness,
  Origin, Policy,
  parse, parse_policy,
  default_policy, policy_opens_the_door, wake_under, build,
  encode, decode, config_key, config_key_prefix, strand_prefixes,
  parse_instant, render_instant, parse_utc_offset, render_utc_offset,
  max_utc_offset_s, min_utc_offset_s, fired_key,
  fired_key_prefix, fired_value, seen_key, seen_value, decode_seen,
  injection, origin_of, interval_occurrence,
  interval_late, recurring_expired, cron_occurrence, cron_late,
  cron_next_delay_ms, relative_instant, max_schedules, max_model_schedules,
  min_interval_s,
  max_name_length, max_body_length, max_target_length,
  default_max_fires, max_max_fires, default_expires_after_s,
  max_expires_after_s, min_in_seconds, max_in_seconds}` — scheduled heartbeats (`docs/design-notes/
  scheduled-heartbeats.md`), the time-triggered sibling of `client/rules`:
  a `[[schedule]]` fires on a clock instead of on a literal match, parsed
  from the same `loom.toml` by the same strict, total discipline. A
  schedule reaches the scanner from one of **two** stores and is the same
  value either way: the operator's `[[schedule]]` tables, and the model's
  own `schedule/config/…` reserved cells created through
  `tools/schedule` (`encode`/`decode`/`config_key`). `Policy` is the
  operator's say over that second door — `off`/`steer`/`wake` from a
  `[schedules]` table — and `default_policy` is **`ModelSchedulesSteer`**: the
  tools are registered and a model may create schedules, but none of
  them can wake an idle strand until the operator writes `"wake"`. The
  design note's addendum has the whole history — the feature shipped
  operator-only, reopened with an open default on the strength of the
  per-schedule expiry, and settled on `steer` once #161 showed that
  expiry bounds a schedule and not a session (a fresh name is a fresh
  clock), which under the priority order makes unsupervised liveness an
  opt-in. `build` is the constructor the model-facing door and `decode`
  share: it enforces exactly what `parse` enforces, through the same
  predicates and constants, so the two creation paths word refusals
  differently and can never disagree about what is allowed. A schedule is
  exactly one of three: `Interval(seconds, expiry)`, aligned to a fixed
  grid (`slot = floor(now_s / seconds)`); `Cron(expression, offset_s,
  expiry)`, a five-field calendar expression parsed by `client/cron` and
  read against a UTC clock shifted by `offset_s`; or
  `OneShot(at)`, a single RFC3339 UTC instant. Never two, never none, and
  still **no timezones anywhere** — the design note cut cron as a swamp,
  and what changed is that the swamp is the *timezone* half rather than
  the syntax half.
  **`offset_s` is a fixed offset and emphatically not a zone**, which is
  the whole of what the addition costs and what every description a model
  or an operator reads has to say. A zone is a function from an instant
  to an offset — Berlin is +01:00 in January and +02:00 in July — and
  answering which needs the IANA database this tree will not carry, so a
  schedule written `+02:00` in summer fires an hour off its author's own
  clock all winter. What it buys is the thing an operator actually asks
  for: "09:00 my time", which a UTC-read expression cannot say at all.
  Written `utc_offset = "+02:00"` in TOML (`[+-]HH:MM`, allowed **only**
  beside `cron` and refused in words beside `every`/`at`), carried as
  `utc_offset_s: Int` in the config cell (absent → 0, so every cell
  written before the offset existed decodes unchanged), and parsed by the
  one `parse_utc_offset` all three doors share. The bound is
  `min_utc_offset_s`..`max_utc_offset_s`, ±14 hours, held by
  `parse_utc_offset` *and* by `build`, because `decode` reaches the
  constructor with a number that never passed through the parser.
  **The shift is a reading of the clock, never a change to an
  occurrence's identity**: an occurrence at UTC epoch `t` matches when
  `cron.matches(expression, at_s: t + offset_s)`, and the three search
  functions shift in and shift straight back out — so every occurrence id
  they return is a **UTC** epoch second and `fired_key`, `seen_key` and
  `config_key` are byte-identical to what they were. Storing ids in
  shifted time instead would have made an edited offset unread the whole
  fire history and re-fire everything. `cron` buys the one thing an interval cannot say at all:
  a **phase**. The interval grid is aligned to the epoch, so `every =
  "86400s"` is always 00:00 UTC and `0 9 * * 1-5` is the only way to ask
  for 09:00 on weekdays. It needs no `min_interval_s` check, and that is
  a property of the grammar rather than an omission — cron's finest grain
  is a minute, so `* * * * *` is already exactly at the floor.
  **`Interval` and `Cron` answer "what is due" differently, on purpose.**
  An interval fires the slot `now_s` falls in whether or not that slot
  began before the schedule existed, because a heartbeat grid has no
  wall-clock meaning and "the current slot" is the only honest reading of
  *now*. A cron occurrence *is* an instant somebody named, so
  `cron_occurrence` answers with the last match at or before `now_s`
  (`cron.previous_occurrence(before_s: now_s + 1)`) **and only if that
  match is at or after `since_s`** — the observation instant from the
  seen cell. A `0 9 * * *` schedule created at 15:00 therefore does not
  fire this morning's 09:00; it waits for tomorrow's. `cron_late` follows
  the same instant: the preceding occurrence has to have been *owed*
  (`>= since_s`) and unmarked for a fire to be `Late`, which is what
  makes a first fire on time. `cron_next_delay_ms` is the re-arm, floored
  at a second like the interval one, and `None` — no match within
  `cron.search_horizon_days` — is a schedule that will not fire again.
  All three take `offset_s`, search in shifted time and answer in UTC;
  `cron_next_delay_ms` in particular shifts the match back *before* it
  meets `now_ms`, since shifting only one of the two would arm a delay
  wrong by the whole offset.
  Both recurring shapes carry a
  mandatory `Expiry`: `max_fires` and `expires_after_s` are both always
  active, defaulted when unset, and whichever is reached first ends the
  schedule — the guardrail that caps one schedule's durable fire-mark
  footprint at exactly 1,000 rows and makes `WakesIdle` (below) safe to
  offer at all. The two bounds read two different durable facts.
  `max_fires` counts the fired-marks; `expires_after_s` is measured from
  `since_s`, **the instant the scanner first observed the schedule**,
  which it records once in the cell `seen_key` names (`seen_value`,
  `decode_seen`) — a third corner of `schedule/`, disjoint from the
  `fired/` marks and the `config/` cells by its second segment, and
  unreachable by `put_fact` like both. Measuring age from the earliest
  fired-mark, which is how this shipped, gave a schedule that never
  landed a fire no clock at all: a steer-only heartbeat on a strand
  nobody opens a run on ticked for the life of the session while
  `expires_after_s` read to an operator as a week (issue #157). The
  cancellation tombstone is gone with it — `cancelled_value` no longer
  exists, because cancelling a model-created schedule now deletes its
  config cell (`api.delete_reserved_fact`), which is what keeps
  `config_key_prefix` a list of live schedules. `Wake` is `WakesIdle | SteersOnly` and `Lateness` is
  `OnTime | Late`: both are two-variant types rather than the `Bool`s
  they were, because each is read at one end and written at another and
  neither name carries its own polarity. The TOML `wake` key, the stored
  config cell and the tool result all stay booleans on the wire, and
  each boundary writes that translation down once.
  `relative_instant` (with `min_in_seconds`/`max_in_seconds`) turns a
  model's "in N seconds" into the absolute epoch second a `OneShot`
  needs, refusing anything outside 1..604800 in words. It exists because
  **the model has no clock**: the system prompt carries neither the date
  nor the time, so a model asked to check back in 45 minutes cannot
  compute the instant `at` wants, and the model-facing one-shot was
  unusable in practice for the case it is most wanted in. The caller
  supplies `now_s` rather than this module reading one, because this
  module performs no I/O — `client/scheduleseam` reads the injected
  `runtime/effects.clock`.
  `interval_occurrence`/`interval_late`/`recurring_expired`/
  `cron_occurrence`/`cron_late`/`cron_next_delay_ms`
  are pure functions over the occurrence arithmetic — deliberately
  factored out of the actor that drives them so a fencepost error gets a
  direct, deterministic test rather than one hidden behind a timer
  harness.
  **A schedule has an `Owner` as well as a `target`, and the pair is
  what bounds its life** (#163, #154). `Owner` is `OperatorOwned |
  StrandOwned(strand)`: a `[[schedule]]` table parses to the first, a
  model-created cell always carries the second, and `decode` has **no
  path** to `OperatorOwned` — a cell with no `owner` field reads as
  `StrandOwned(target)`, which is what every cell an earlier build wrote
  actually was, and the absent field can therefore only ever name the
  strand the schedule already fires onto. Ownership decides who may
  `list` and `cancel`; the target decides whose context a fire lands in.
  Keying cancellation on the creator is the fix: a schedule used to be
  cancellable only by the strand it fired onto, so a subagent's own
  heartbeat became uncancellable the moment that subagent settled and
  held a ceiling slot for the rest of the session. What ownership
  deliberately does *not* touch is a schedule's **identity**, which
  stays `{target, name}` — config, seen and fired keys are unchanged and
  name uniqueness is still per target across both stores, because an
  occurrence is a fact about a strand's timeline and two schedules
  sharing that pair would share a mark whoever owned them.
  `strand_prefixes(strand)` is the one place a strand's whole durable
  scheduling footprint is written down — the config, seen and fired
  prefixes, each ending in `/` so a reap cannot reach a
  similarly-named neighbour — and it is what `client/scheduleseam`
  retires on a run end. `Origin` gained a third variant with the owner:
  `OperatorConfigured | SelfScheduled | OwnerScheduled(owner)`, derived
  from the value by `origin_of` rather than paired on by the scanner,
  and the third one exists because text a parent scheduled onto a child
  must not reach the child as "a heartbeat *you* scheduled" — it names
  the owner and says the instruction is worth what a steer from that
  strand is worth, and no more.
- `client/scheduleseam.{Wiring, Door, seam, door, limits,
  describe_timing, cell}` — the host half of the model-facing scheduling
  door, filling `tools/schedule`'s seam the way `client/memory` fills
  `tools/remember`'s and for the same reason (`tools` may not reach a
  session). It is the **only** enforcer of three things: the operator's
  `Policy` (applied through `schedule.wake_under`, which caps `wake`
  rather than vetoing the call, so the tool can tell the model what it
  actually got), the `max_model_schedules`
  ceiling, and the shared bounds via `client/schedule.build`.
  `requested_timing` maps the door's four `RequestedTiming` shapes onto
  one `Timing`, and it is the seam's job rather than the door's because
  everything it needs is on this side: the one RFC3339 parser, the one
  cron grammar (`client/cron.parse`), the defaulted `Expiry` a recurring
  schedule always gets, and — for the relative one-shot `In(seconds)` —
  the session's injected `runtime/effects.clock`, read through
  `core/clock.read` exactly as the scanner reads it, never a wall-clock
  call of its own. `In` is the only arm that reads a clock, and it is the
  reason the argument exists at all: the model is told no date, so it
  cannot compute an `at`. `requested_expiry` defaults `max_fires` and
  `expires_after_s` and checks *neither* — both go on to
  `schedule.build`, whose `checked_expiry` is the same ceiling a
  `[[schedule]]` table meets, so this door holds no second copy of a
  bound. `describe_timing` is the one rendering both `create` and `list`
  use, and a cron reads back as `cron "0 9 * * 1-5" UTC+02:00, at most N
  times` — the clock said out loud, because a caller reading
  `0 9 * * 1-5` has no other way to know which 09:00 it got. A schedule
  with no offset still renders bare `UTC`
  (`schedule.render_utc_offset(0)`), because most have none and spelling
  `UTC+00:00` out every time would train a reader to skip the clause that
  matters on the rare one that does. `requested_timing`'s cron arm parses
  the door's `utc_offset` through `schedule.parse_utc_offset` — the same
  parser the operator's TOML key uses, so a model and an operator cannot
  disagree about `+05:30` — and an absent argument is plain UTC, which is
  what every request meant before the argument existed. `Wiring`
  carries `operator_schedules` for one reason worth knowing: both stores
  feed one scanner, which derives a fired-mark from `{target, name}`
  alone, so a model name colliding with an operator's would make two
  schedules share a mark and suppress each other — and this is the only
  place that check can live. `Wiring.runtime` is a **borrow closure**,
  not a runtime: the registry this seam joins is threaded into
  `api.open`, so it is built before a runtime exists, and it reads the
  session's one holder through `agency.borrow_runtime` rather than
  standing up a second actor. `Door` is the same three operations keyed
  on the **caller's** strand name, which is what `client/codemode` serves
  `schedule.*` over — one implementation behind both doors, so a program
  and a tool call cannot disagree about what this session's schedules
  are. `list(caller)` answers every cell whose *owner* is the caller,
  child-targeting ones included, and `cancel(caller, name, target)` finds
  `{target or caller, name}` and requires the owner to match, else
  `NotFound` — the same answer a name that does not exist gets, so a
  caller guessing at a sibling's name learns nothing from the
  difference.
  Both of its writes are guarded rather than blind: `create` commits the
  config cell with `api.put_reserved_fact_expecting(expected: None)`, so
  a name belongs to whichever writer commits first and the loser is
  answered `NameTaken` rather than having its schedule replaced — which
  is what makes "creating never silently replaces" a property of the
  commit instead of the tool door's `Exclusive` serialization, an
  argument that never covered the code-mode door's per-plan processes
  (#162). `cancel` deletes the cell through `api.delete_reserved_fact`
  instead of writing a tombstone over it, both because every scanner
  tick and every seam call reads the whole `schedule/config/` prefix
  (#164) and because, once `create` commits on the cell's absence, a
  tombstone would hold the name against every later create for the life
  of the session. The pre-checks stay — `name_is_free` is the only thing
  that can catch an operator's `{target, name}`, which has no cell for a
  claim to collide with — and the ceiling stays inexact under a
  code-mode fan-out, which can over-admit by up to `max_outstanding`;
  nothing rests on the exact count, so it is documented rather than
  fixed.
- `client/cron.{Expression, parse, source, matches, next_occurrence,
  previous_occurrence, max_expression_length, search_horizon_days}` —
  standard five-field cron: the parsed expression, what it refuses in
  words, and pure occurrence arithmetic over a UTC calendar. `Expression`
  is opaque because its value sets carry invariants only `parse`
  establishes (sorted, deduplicated, in range, `7` folded to `0` in
  day-of-week), so `client/schedule` stores the **source text** and
  re-parses on `decode` rather than storing an expansion. `parse` is
  total and its error is prose, because the only thing a caller does with
  it is put it in front of whoever wrote the expression. Both searches
  are strictly-greater/strictly-less and bounded by
  `search_horizon_days` — a legal expression need not recur (`0 0 30 2 *`
  asks for the thirtieth of February), so an unbounded search would not
  return. The one rule a reimplementation gets wrong is in here and
  documented at length: **when both day fields are restricted they are
  ORed, not ANDed**, so `0 9 1 * 1` fires on the first of the month *and*
  on every Monday. This module holds **no offset and no timezone
  handling at all**, and that stayed true when `client/schedule` grew a
  fixed `utc_offset`: the shift is applied by the caller, which adds
  `offset_s` to the instant it asks about and subtracts it from the
  answer, so nothing here reads a clock or knows an offset exists. No seconds field, no names, and
  `L`/`W`/`?`/`#` refused by name. Performs no I/O and reads no clock:
  the scanner supplies the instant.
- `client/scheduleadmin.{Admin, Row, CancelRefusal, admin}` — the
  operator's door onto the scheduling store, opposite
  `client/scheduleseam`'s model-facing one: it lists **everything** (an
  operator watching a session watches all of it) and cancels only what a
  strand wrote. A `[[schedule]]` table has no durable cell — it is
  configuration, parsed at boot, and the file is the record, the posture
  `client/rulescan` takes toward `[[rule]]` — so naming one is refused
  with the reason rather than ignored. Cancellation reuses
  `scheduleseam.retire` and then `schedulescan.poke`: one deletion order
  for both doors, because the order (marks, seen cell, config cell last)
  *is* the crash story, and a second order written here would be a
  second chance to get it wrong. `gateway.with_schedules` takes the
  `Admin`, and `client/serve` builds it over the very
  `scheduleseam.Wiring` the model's door uses, so `None` there means no
  admin.
- `client/schedulescan.{Options, ModelDoor, Message, max_timer_delay_ms,
  default_options, with_logger, with_model_door_open, poke, start,
  supervised}` — the
  scheduled-heartbeat scanner, and a **`weft/state_machine`**
  (loom#165). One state, `Watching`, which the machine never leaves; the
  data is the parsed operator list plus the runtime and nothing else; and
  the whole of its liveness is one **named** timeout under a single
  constant name, re-armed by every scan for the soonest boundary any
  still-active schedule needs. A scan that finds nothing active and has
  `DoorShut` `sm.cancel_timeout`s that name instead, so every path
  through a scan says what should be armed under it and the timer belongs
  to the machine rather than to a phase (`docs/weft.md` rule 8). The
  first arming is a zero-delay one made by `sm.on_enter`, which runs
  exactly once because the machine has one state — an injected
  `sm.continuing(Rescan)` would have scanned inside `start`'s own
  continuation, and "the first tick is armed and has not run" is a state
  the fixtures hold still and step through. Neither `weft/actor` nor a
  periodic timeout: the delay is *recomputed per scan* from the store,
  which neither a state timeout (cancelled by a transition this machine
  never makes) nor a fixed cadence can carry. It arms through
  `sm.with_timer_source(timer.Injected(after: runtime.effects.timers.after))`,
  so a simulated session's heartbeats still run on logical time and
  `schedulescan_test`'s fake wheel still drives them by hand — that
  injectable source (weft 0.4.2) is the thing whose absence kept this
  module hand-rolled. With it the generation tag `Message` used to carry
  is gone: `Message` is `Tick | Rescan`, arming under one name supersedes
  the previous arming, and a superseded wake dies in weft's own timer
  book rather than in a guard written here. `start` and `supervised`
  keep `gleam/otp/actor`'s `StartResult` and
  `supervision.ChildSpecification` — weft returns upstream's own types —
  so `client/serve` needed no change at the boundary.
  Every tick unions the operator's fixed
  list with the model's config cells read fresh from the store, never a
  cached list: a cell can appear or be cancelled between any two ticks
  and this actor is restartable, so a cache would be a second source of
  truth. The union is an append and nothing more, because a schedule now
  carries its own `client/schedule.Owner`: whose text a fire is comes
  from `schedule.origin_of` rather than from a pairing this actor used to
  carry, and a config cell can never decode as the operator's.
  `poke` is what the seam rings after a write so a new schedule
  starts on time rather than at the next armed deadline; it checks the
  name is registered first, because a send to an unregistered name
  raises and the caller is a tool body. `with_model_door_open` sets
  `Options.model_door` to `DoorOpen`, which keeps a slow rescan floor
  when the model may create schedules, so a lost poke self-heals within
  one `min_interval_s` instead of stalling forever.
  `process_schedule` dispatches the three timings, and `process_cron`
  mirrors `process_interval` step for step — read the marks
  (`marked_occurrences`, shared), settle the observation instant
  (`observed_since`), test `schedule.recurring_expired`, fire what is
  due, re-arm. The cron-specific arithmetic is all in `client/schedule`,
  so this half stays a scanner. Two differences are worth knowing. The
  seen cell is claimed by this actor as it always was, so `since_s` is
  available on a schedule's very first tick — which is exactly the tick
  that decides whether anything is owed, since a cron occurrence
  predating `since_s` was never asked for. And a cron expression with no
  next match inside `cron.search_horizon_days` is `Expired` for the
  tick, with a `schedule.cron_never_matches` warning: `0 0 30 2 *` is
  legal, will never fire, and must not leave the machine waking up over
  it forever. Unlike
  `client/rulescan` it is driven by its own named timeout on the injected
  `runtime/effects.Timers` clock, never by a writer hint, and it
  holds no progress state across ticks: every tick re-derives which
  schedules are due or expired from a bounded scan of the write-once
  fired-marks already in the store, read straight off `storage`
  (`client/schedule.fired_key_prefix`) rather than through the writer's
  mailbox — the same isolation `client/rulescan`'s direct reads give it,
  for the same reason: a slow tick must never queue in front of a
  settlement. The one fact the marks cannot supply is when a schedule's
  `expires_after_s` window opened — a schedule that never fired has no
  earliest mark — so the scanner is also the **single writer** of that
  schedule's `client/schedule.seen_key` cell, and claiming it is its only
  write besides the fire itself. `observed_since` reads the cell off the
  store like a mark and, finding it absent, claims it with
  `api.put_reserved_fact_expecting(expected: None)`; a `FactConflict`
  means another incarnation won the gap, so the winner's instant is read
  back rather than assumed. The cell is written at most once per
  `{strand, name}` — the invariant every reader of it rests on — and a
  store fault that leaves it unrecorded logs `schedule.seen_unrecorded`
  and measures that one tick from `now`, which expires nothing: a fault
  must neither shorten a schedule's life nor lengthen it. The same "durable-derived beats durable-stored" argument
  keeps `client/rulescan`'s cursor a checkpoint rather than a source of
  truth.
  **A settled target ends the schedule, and the check is a subagent's
  only.** Before any timing arithmetic, a schedule whose target is a
  subagent asks whether that strand has stopped: dead when its lineage
  cell carries the `reaped` mark, or when its `brief` has a terminal
  result (`api.await_strand_result(within_ms: 0)`, one immediate store
  read) — exactly the pair `client/agency.is_live` and `reap` decide
  from. A dead target's schedule is `Expired` for that tick: no fire, no
  re-arm, and no wake whoever configured it, which is the belt to
  `client/scheduleseam.reaping_hooks`' braces (#163). It **fails
  closed**: a `sub:` target with no lineage cell, or one whose cell will
  not decode, reads as finished — the opposite direction from
  `client/rulescan`'s hold, deliberately, because a held rule costs a
  tick while a fired schedule may open a run. A root strand answers
  `False` without a read at all: `main` is idle between runs rather than
  finished, so a terminal result there says the last prompt ended and
  nothing about the next one.
  A fire is one `api.steer_marking` when `Schedule.wake` is `SteersOnly`
  — the injection and the occurrence's write-once fired-mark in one
  transaction, exactly `client/rulescan`'s at-most-once argument, held on
  an idle strand rather than dropped or started. `WakesIdle` opts into
  `api.send_to_strand_marking` instead, which may start a fresh run on an
  idle strand: the one behavior a triggered rule is never allowed, safe
  here only because a schedule's mandatory expiry bounds how long it can
  keep a session alive. A session closed through a missed window catches
  up to **at most one** late fire per schedule at the next tick, never a
  replay of the backlog: an occurrence is judged late by whether the
  *immediately preceding* slot's fired-mark is missing, never by
  comparing the current time against a boundary computed from that same
  current time, which is always trivially on-time by construction.
- `client/codemode.{over_mcp, seam_allowlist, seam_caps_on}` — what a
  configured MCP server does to the seam a model is offered. One
  `Config.mcp` field, for the reason `surface` is one field: a server
  widens the workspace seam's *allowlist*, its rendered *description*,
  the *generated table* the hermetic build takes, and the capability
  *router*, and a host that could set those apart would eventually set
  them apart. The orchestration seam is widened by none of it, ever —
  which capabilities travel together is the whole of what the split buys.
- `client/codemode.{Surface, Seams, serving, orchestrating,
  surface_seams, surface_seam, seam_policy, seam_caps, tool_seam,
  vetting_seam}` — which code-mode seams this host serves.
  `Surface` is `Workspace`, `Orchestration(agency, spawn_ceiling)` or
  `Both(...)`: one field, because the vetting allowlist, the capability
  router and the admission ceilings have to agree and a host that could
  set them apart would eventually set them apart. `Seams`
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
- `client/mcp.{Layer, Server, Refusal, Options, none, serving, start,
  stop, routing, allowed_imports, surfaces, generated, serviced_caps,
  listings, sha256_hex}` — the MCP layer (#106): the configured servers
  this host actually reached. `start` fans every `catalog.McpServer`'s
  bring-up out over a `weft` run — one task per server, bounded by the
  catalogue's own length — rather than folding them one at a time, so an
  N-server boot pays one shared clock for every handshake timeout rather
  than N consecutive ones; `weft.start` hands outcomes back sorted by
  input position, so zipping them against the unchanged `servers` list is
  what restores catalogue order regardless of which server answers first.
  Each task still spawns its server over `mcp/transport.PortTransport`,
  hand-shakes, lists its tools and generates its `cap/mcp/<server>`
  façade, keeping the client **running** for the session because dispatch
  is the same client; each failing step refuses *that* server with a
  worded `Refusal` and the boot goes on without it, and a `Crashed` weft
  worker becomes a worded `Refusal` too rather than taking the boot down.
  `routing` is the capability arm: a cap under `mcp.` is answered as
  `satellite.ServedHere` — no `CallSpec`, no jail, no policy — and
  everything else is handed to the router beneath untouched. The client
  actors are started from a throwaway unlinked process on purpose, two
  `process.spawn_unlinked` calls below `start_one` itself, so a
  third-party server's client cannot fell the server; that isolation does
  not depend on which process runs `start_one` — a weft worker moves who
  calls it, not how the actor is severed from its caller, so bring-up
  needed no re-link back to the boot's own process and no accessor onto
  `mcp/client.Client` to do one. `Layer` is then the only handle on the
  clients, and `serve.shutdown` is what stops them.
- `client/system_prompt.{Host, Rendered, Assembled, Origin, assemble,
  render_pack, pack_source, guidance, pinned_in, pinned, pin}` — the I/O
  half of the pure `prompt` package. `Host` is every `pack.Environment`
  field gathered from a real source; `pack_source` picks the shipped pack
  or the one `LOOM_PROMPT_PACK` names; `render_pack` renders it or
  refuses; `assemble` chooses between the `LOOM_SYSTEM_PROMPT` override,
  the pinned cell and a fresh render; `pinned_in`/`pinned`/`pin` are the
  two ends of the reserved `prompt/` cell. Nothing here is called per
  turn — the whole module runs once, at boot.
- `client/system_prompt.{GuidanceFile, GuidanceOrigin, discover, guidance,
  render_file, origin_name, agents_file, claude_file,
  user_default_directories, max_guidance_file_bytes}` — the session's
  instruction files and the fence they reach the model behind. `discover`
  fills three slots in render order: the operator's global `AGENTS.md`
  (under `~/.agents` then `~/.loom`, first found wins), the workspace's
  `AGENTS.md`, and the workspace's `CLAUDE.md`. `guidance` joins them into the one string
  `Host.guidance` carries, each file inside an `<instructions>` fence
  naming its path and its `origin_name` — `workspace` or `user-default` —
  which is the vocabulary the pack's framing prose is written against.
  The home directory is a parameter rather than a `HOME` read, so the
  whole lookup is testable without a process environment; `serve` reads
  `HOME` and passes it in.
- `client/wiring.{request_target, resolved_target, strand_thinking_level,
  thinking_level}` — the model-routing half of the seam: which role (if
  any) a captured identity is on and therefore whether the dispatch walks
  a chain, the `ForResolved`-only target every deferred poll and every
  off-route generation takes, and the two directions of the map between
  the machine's seven-point thinking scale and the provider's four-point
  one — `thinking_level` collapsing for a dispatch, `strand_thinking_level`
  lifting an entry's declared level to seed a strand.
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
- `client/wiring.{run_tool, terminates}` — the tool-dispatch boundary and
  the one conversion across it. `run_tool` always settles as
  `effects.ToolCompleted`, and its `terminate` is now the outcome's own
  `tool.Terminate` rather than the hardcoded `False` it was: `terminates`
  is where `TerminateRun` becomes the `Bool` the frozen effect type
  carries, and it is the only place the polarity is written down.
- `client/wiring.{compaction_hooks, strand_window, resolution}` — live
  compaction's host half, separable so a host with its own provider
  surface can run the real hooks. `compaction_hooks` builds the whole
  `effects.Hooks` record through `runtime/hooks`: real admission from
  the gateway's resolved model facts, threshold and overflow over the
  strand's durable projection, the notes checkpoint as every structural
  decision (`VerdictSupplied`, no usage; a branch summary and an
  unbuildable checkpoint decline), and the near-limit reminder on the
  `context` slot. `strand_window` is the window a strand is measured
  against — its own catalogue entry, else the fallback — exposed so
  `serve` can build the `context_remaining` seam from the same rule
  before the config exists. `resolution` asks whether the configured
  role still routes. There is no summary request, no sink and no
  progress hook: no summarizer serves this host, and a `SummaryRequest`
  reaching `dispatch` is refused terminally.
- `client/checkpoint.{Recall, Closed, Checkpoint, max_notes_bytes,
  header_prefix, instructions_fence, reminder_prefix, for_operation,
  render, reminder_point, reminder, reminder_text, remaining_seam}` —
  the context checkpoint: what replaces the older half of a strand's
  context when its window fills. `for_operation` builds it from durable
  state alone — the operation's frozen preparation, the strand its
  `op.meta` names, that strand's `agent/{strand}/` cells newest first,
  the compactions already on its branch (the window ordinal) — and
  `render` is the text: a `[loom]` header naming the window, the counts
  and where the cut messages went (`history_search` when `Recall` says
  the host registered it), the notes quoted as data under
  `max_notes_bytes`, and an operator's `compact` instructions quoted in
  their own fence. `reminder_point` is one reserve below the threshold's
  cut, `reminder` the user message the `context` slot appends past it.
  `remaining_seam` fills `tools/context`'s seam from the same projection
  and token fold the threshold reads. `docs/architecture/compaction.md`
  carries the argument for a checkpoint over a summary.
- `client/serve.{default_reserve_tokens, default_keep_recent_tokens}` —
  pi's compaction defaults, and the only place they are stated.
  `LOOM_COMPACTION`, `LOOM_COMPACTION_RESERVE` and
  `LOOM_COMPACTION_KEEP_RECENT` override them; settings that cannot
  describe a working compaction disable it rather than firing a
  threshold that prepares nothing.
- `client/contributions.{Origin, Contribution, Collision}` — who
  contributed a tool (`BuiltIn` | `Extension(name)`), one origin's
  ordered tool list, and the refusal when two contributions claim one
  name. `code_mode` is `BuiltIn` and gated on its plane, exactly as
  `history_search`, `remember` and the `schedule_*` tools are.
- `client/contributions.built_in(Option(Agency), Option(CodeMode),
  Option(History), Option(Memory), Option(Schedules), Option(Context))`
  — the host's own single contribution: five core tools, plus the six
  `agent_*` tools only when a messaging plane exists, plus `code_mode`
  only when this host wired a code-mode pipeline, plus `history_search`
  only when its search index opened, plus `remember` only when the
  memory session beside the session file opened, plus the three
  `schedule_*` tools only when the schedule store did, plus
  `context_remaining` over `client/checkpoint.remaining_seam` — the one
  seam every served session has, so its `Option` is for a registry built
  with no session behind it. A plane that is absent contributes nothing
  at all.
- `client/contributions.registry(List(Contribution)) ->
  Result(Registry, Collision)` — the seam an installed extension enters
  the registry through. Last-registration-wins survives *inside* one
  contribution; a name two contributions both claim is refused, so an
  extension can shadow neither a built-in nor a peer. `serve.boot`
  turns a `Collision` into a boot refusal through
  `contributions.collision_message`, which names both origins.
  `contributions.deactivate(contributions, names)` runs first and drops
  those names from the **built-in** contribution only, which is the whole
  of how an extension's tool comes to stand in for a built-in one: an
  active built-in still collides, a deactivated one leaves its name free.
  `serve.Settings.deactivated_tools` fills it from `LOOM_DISABLE_TOOLS`. What a
  registry produces reaches a session once: the prompt index and
  `active_tool_names` are both fixed at session creation, so an
  extension installed later is seen by the next session, not this one.
- `client/serve.protecting_index(SandboxPolicy, String)` — the base
  policy with the search index added to `protected`. A security property,
  not hygiene: snippets from that index are read back into *future*
  sessions' contexts, so an index a model can write is a channel from one
  execution's output into a later execution's input. `protected` bars
  writes and leaves reads alone, which is exactly the asymmetry wanted.
  `assemble` composes it before `base_policy_fault` validates, so the
  addition is checked by the same gate every other path is.
- `client/serve.protecting_memory(SandboxPolicy, String, String)` — the
  same bargain one step along, over `loom-memory.db` (with its WAL
  family) and `loom-memory.digest`. More direct than the index's: a
  search snippet reaches a later session only if a model searches for it,
  while the digest is injected into **every** run of every session on the
  repository, unasked. Both paths are conditional on a writable root
  reaching their directory — not a refinement but a requirement, since
  neither file exists until a distillation run has happened and the jail
  refuses to mask a *missing* protected path under a read-only parent.
  The two functions share one `protecting(always:, where_writable:)`
  mechanism rather than each carrying a copy.
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
  owned by whichever process called `boot`; `helper_path`, the
  `loom-exec` the ladder settled on, carried so the listening line can
  name the binary that will enforce every jail this session builds; and
  `rulescan`, the triggered-rule scanner's *name* — `None` on a boot
  that configured no rules and therefore started no scanner, which is
  the `codemode.unavailable` posture applied to a second optional
  plane; and `schedulescan`, the same posture applied to a third —
  scheduled heartbeats — carried the same way for the same reason,
  though this scanner answers to no writer subscription at all.
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
  point (`gleam run -m client/serve`, `bin/loomd` via the erlang
  shipment): flags/env in, session + helper pool + broker + system
  prompt + runtime + service supervisor + websocket server up, one
  startup line out, and either `SIGTERM` or a fatal fault runs the same
  `shutdown` so the lease is released rather than left to its TTL.
  `client.main` delegates here for the shipment's entrypoint.
- `client/serve.Settings.demand` — the broker's enforcement contract.
  `main` selects `PlatformEnforcement` by default, which is strict on Linux
  and admits only ADR-006's three reported Darwin gaps. The
  `--full-enforcement` flag asks for Linux-equivalent containment on every
  platform; `--best-effort` explicitly accepts any honest degradation. The
  two flags are mutually exclusive.
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
- `client/serve.Settings.home` — the operator's home directory, where the
  global `AGENTS.md` is looked for and carried ahead of the workspace's
  files.
  `resolve` fills it from `HOME` and `None` records that `HOME` was
  unset. A field for the same reason `base_policy` is one: a boot that
  reached into the process environment for it would make every test that
  stands a server up read the developer's own `~/.agents/AGENTS.md`.

## Extensions

`client/extension/*` is the install *and dispatch* halves of the
extension design (`docs/design-notes/extension-architecture.md`,
"Hardening the install" and "Tool registration and dispatch"). Three
rulings shape it: an install fetches a **tree, not a git session**, so
there is no git client anywhere in the path; the tree it fetches is
**untrusted input read outside any jail**, so every reader here is
total; and every tool call is answered by a **jailed satellite**, so
nothing an extension ships ever runs in the harness VM.

Phase 3 changed the third of those from "one jailed execution per call"
to "one jailed satellite per session" (`protocol-change/012`, ADR-007
Decision 3). An extension's artifact is compiled once at install, so a
node boot per call was paying for nothing, and an extension could keep no
state at all between calls. `client/extension/hosts` now holds one
`codemode/satellite.Host` per installed extension for the life of the
session and sends each call to it as a `hook_call`. Holding a node open
widens nothing: the satellite host mints a token per invocation and
revokes it on the answer, so an extension may keep actors between calls
and may not reach a capability between them.

- `client/extension/source` — the grammar of what an operator may type.
  `Source` is `LocalPath | ArchiveUrl | GitHub`; `parse` refuses
  `git://`, `ssh://`, `git+ssh://`, the scp-style `git@host:path`,
  `file://` and `http://` by name, with a message that states the three
  accepted forms. `archive_url` derives codeload's
  `https://codeload.github.com/<owner>/<repo>/tar.gz/<rev>` (`HEAD` when
  no revision was named) and refuses a revision paired with an archive
  URL, because an archive URL already names exactly one tree. `host`
  extracts the lowercase host the fetch policy allows, refusing userinfo
  rather than stripping it.
- `client/extension/archive` — the total tar.gz reader, the local
  directory walker, and the tree digest. `extract` inflates through
  `client/internal/ffi_zlib` under `Caps.max_total_bytes`, abandoning
  the stream the moment it goes over, so a decompression bomb is never
  materialised; the ustar reader then admits only regular files,
  directories and pax headers, refusing links, devices, fifos and GNU
  long-name extensions by name. `from_directory` pushes a real directory
  through the same collector, additionally refuses a symlink (the root
  included — `path` is lstat'd before the walk) and a non-regular file,
  and skips a directory named exactly `.git` so that a working checkout
  reads as its export. `digest` is
  lowercase hex SHA-256 (via `tools/blob.ref_for`, the tree's one
  SHA-256) over a length-prefixed encoding of the sorted files, and is
  independent of `Tree.root` and `Tree.commit` — which is what lets an
  install record be re-verified against a tree staged anywhere.

The exact path subset, and why the space and the invisible formatting
code points are outside it, is stated in `archive`'s module doc.

The rest of the path is phase 1's own, and each module is one question:

- `client/extension/manifest` — the total `extension.toml` decoder.
  `Manifest` carries `[extension]`, the `[[tool]]` list (name,
  description, `prompt_snippet`, `parameters`, `entry`, `timeout_ms`),
  the `[[hook]]` list, and `[net]` with its `[[net.secret]]` bindings.
  Unknown keys are errors in *every* table, which is what refuses the
  `[client]` table the design note reserves for a later ruling without a
  special case for it. `tier` decodes only `"jailed"`. Three rules need
  the tree beside the manifest, so `decode` takes a `Surroundings`: a
  tool's `parameters` must be a path under `schema/` that exists and
  parses as JSON, its `entry` must name a module `src/` ships, and a
  secret's `host` must be one of `[net].hosts`. A secret carries the
  *name* of an environment variable and never a value, the rule
  `api_key_env` set one layer out.
- `client/extension/record` — the install record, JSON with a total
  decoder, and the `Root` value that says where installs live.
  `root_for(home)` is `<home>/.loom/extensions`; the root is a value
  resolved from `Settings.home` (or `--home`) rather than an environment
  read inside the pipeline. The record stores the *terms* of the
  approval — the tree digest, the manifest hash, the allowlist, the net
  policy with secret names only, and (format 2) the `#(event, entry)`
  hooks — because recomputing them at load would mean an operator's yes
  silently followed the harness's current idea of the seam. A format-1
  record is refused rather than read with an empty hook list: it cannot
  say whether hooks were approved, and the honest answer is to ask.
  `readable(text)` is the door discovery uses, and it decodes the
  version *first* — the full decoder would otherwise reach a format-1
  file before the version check and report a missing `hooks` field when
  the fact an operator needs is the version skew.
- `client/extension/install` — the pipeline, as six steps each returning
  a `Failure` naming its layer: `Fetch`, `Extract`, `Manifest`,
  `Vetting`, `Compile`, `Record`. The fetch and the jailed build are
  both injected (`Fetcher`, `Build`), so the module holds no HTTP client
  and no broker, and a test drives the whole thing with a fetcher that
  was never called.
  **`installed_tree` runs first and everything after sees only what it
  kept.** A repository is not an installed extension — it has tests, a
  `.gitignore`, `.github/`, docs, Gleam's resolved `manifest.toml` and a
  `build/` directory — so `codemode/vet/package.installed_subset` prunes
  it to `src/**/*.gleam`, `schema/**`, `skills/**`, `extension.toml`,
  `gleam.toml`, `README*`, `LICENSE*` before the UTF-8 decode, the
  manifest, the vetting, the digest and `write_tree`. That ordering is
  what makes the recorded digest a claim about the *installed* tree, and
  it is why the UTF-8 refusal reaches only installed files: a screenshot
  under `docs/` is pruned, and one under `schema/` is refused.
  `entry_source(tools, hooks)` generates the `loom_satellite` module that
  imports each registration's entry module and calls
  `ext/runtime.serving(tools:, hooks:)` — a call that runs for the life
  of the satellite rather than serving once. A `[[tool]]`'s entry module
  must expose `pub fn run` (`entry_function`) and a `[[hook]]`'s must
  expose `pub fn on_event` (`hook_function`): two names rather than one
  because a module may serve both, and generated code that named them the
  same would not compile — in the worst place for a compile error, since
  nobody wrote the file. The aliases are positional and per distinct
  module, because two tools may share an entry module, a tool and a hook
  may too, and importing one twice is a compile error in generated code.
- `client/extension/installed` — `discover(root)` and `one(root, name)`,
  each returning `Ready` or `Refused`. Five things are re-derived from
  disk and compared with the record: the tree digest, the artifact's
  content address (with `build.fingerprint_directory`, the function the
  build itself used), the manifest, the vetting, and the allowlist.
  **Nothing is pruned here**, and that is the point: the install already
  narrowed the repository to the extension's own tree and wrote exactly
  that, so what is under `<name>/src/` *is* the installed tree and a file
  dropped in afterwards must change the digest. Pruning again at load
  would forgive exactly the tampering the digest exists to catch. A
  refusal is a *value* rather than a shorter list, because an operator
  who installed something and sees nothing cannot tell "it is broken"
  from "I imagined it".
- `client/extension/cli` — `install`, `list`, `remove`, `verify`, the
  first subcommand surface in the tree. The verb is the first argument
  and the rest is the flat-recursion flag parse `client/serve` uses.
  `build_for` is the install's build seam over a started `BuildPlane`.

Phase 3 added the hook bus, and it hangs off the same satellites the
tools reach:

- `client/extension/hooks` — two `weft/event_manager`s per session, one
  handler per installed extension that declares a `[[hook]]` on each, the
  handler's state its name, the events it declared and its `Invoker`.
  Two managers because a manager's mailbox is a queue: the four
  notify-only events are cast onto the notice manager and the three
  answering ones are `sync_notify`ed on the other, so a slow `usage`
  handler cannot spend the `tool_call` gate's fan-out budget and turn a
  second extension's block into an `Allow`. `subscribers(bus, on:
  Answering | Notifying)` is per manager for the same reason a drop is:
  `event_manager` removes a handler from the inside and offers no handle
  onto its twin.
  `Invoker = fn(String, String, MsgPackValue, Int) -> Result(MsgPackValue,
  HookFailure)` is the seam onto the persistent satellite host, injected
  so the bus is drivable with functions and so the host lands in one
  place; `HookFailure` is `Unhandled | Refused(reason) | Crashed(reason)
  | Deadline | Gone`, of which the last three cost a handler its place
  and the first two do not. The one implementation a session builds is
  `hosts.invoker(hosts, at:)`, so a hook event and a tool call reach the
  same node; `unwired()` — every call `Gone` — is now only what a test
  drives the bus with. Seven events fan out (`session_start`,
  `before_agent_start`, `tool_call`, `agent_end`, `agent_settled`,
  `before_compact`, `usage`), the three that need an answer through
  `sync_notify` plus a drained reply subject — on a weft-bounded worker, never on the caller, because
  `sync_notify` is a `call` and a `call` that is not answered in time
  panics its caller, and the callers are strand drivers sharing one
  answering manager. An unanswered fan-out is an empty list: no injection, and no
  block on a call the built-in clearance already cleared. `context` and
  `tool_result` are chained transforms and so are
  `fold_context`/`fold_tool_result` over the same ordered list, not bus
  events. `wire(effects, bus, session, clock)` composes the bus into a
  built `Effects` by *wrapping* seven slots, the pattern
  `notes.digest_hooks` and `agency.reaping_hooks` set. `injection` and
  `note_block` are the `<extension name=…>` fences a run-start injection
  and a compaction note are rendered in — the harness writes them, never
  the extension, for the reason `system_prompt.render_file` gives about
  instruction files. The module documentation is the normative table of
  all nine wire shapes; the extension's side of the same wire is
  `ext/hook`.
- `client/extension/hooks.{compaction_notes, usage}` — phase 4c's two
  events. `compaction_notes(bus, op, cue)` fans `before_compact` out and
  gathers every note in load order, rendered through `note_block` and
  bounded cumulatively by `context_growth_tokens`; a note that would
  overrun the allowance is dropped whole rather than truncated, because
  half a note says something its author did not. It rides on
  `effects.Hooks.compaction_note` and it is **not a veto** — the
  compaction is already decided when the event fires, which is the
  non-vetoing form of the `session_before_*` hooks the design note
  refused. `usage(bus, op, row)` is a plain `notify` on
  `effects.Hooks.usage`, carrying the ledger row's numbers and
  coordinates and never its `details`.

Phase 2 added the dispatch half and phase 3 the session's hosts, as
four modules — three pure or stateless, plus the one actor that owns
the nodes:

- `client/extension/policy` — pure. `egress_for(net, trust:)` turns the
  manifest's `[net]` table into `Egress`: `Reaches(egress.Policy)` or
  `ReachesNothing` for a manifest that named no table. `hosts`,
  `methods`, `max_response_bytes` and the `[[net.secret]]` bindings are
  the manifest's verbatim; `redirects` (`SameHost(2)`), `timeout_ms` and
  `trust` are this module's, because none of the three is something an
  extension author should be able to state about themselves.
  `ceilings(net)` is `requests_per_call` on `net.request` and nothing
  else — the `ext.call` ceiling went with the capability
  (`protocol-change/012`), and the tally is now reset per *invocation* by
  `satellite.Invoking`, which is what makes `requests_per_call` mean per
  call on a node that outlives the call. `denial(refusal)` sorts every `egress.Refusal` onto the
  side of `cap/net.map_error`'s split it belongs on — a request the
  policy would never have permitted carries a `NetDenied` code
  (`not_allowed`, or `network_off` for no `[net]` at all, or `policy`
  for the ceiling), and a permitted request that failed on the wire
  carries `net_failed`, which is `NetFailed`. Filing one on the wrong
  side is the difference between an author retrying and an author
  reinstalling.
- `client/extension/seam` — the router arm, msgpack in and msgpack out,
  holding no policy at all. `routing(extension, over: inner)` answers
  `net.request` (through `Egress.perform`, an injected function with the
  policy, the credential lookup and the refusal mapping closed over) and
  the two memory arms, `ext.remember` and `ext.recall` (through
  `Memory`'s two closures, with the durability behind them), and hands
  every other name down. `serviced_caps` is those three names; the
  `ext.call` arm with its `Call`/`call_value` shapes went with the
  capability. The memory arms check the *leaf* key they are sent —
  `checked_key`: non-empty, no `/`, at most `max_key_length` — and the
  value against `max_value_bytes`, and nothing more: which subtree a cell
  lands in is bound by `client/extension/dispatch` from the install
  record, so this module never learns an extension's name. `Ask`/`Answer` restate `cap/net`'s
  `Request`/`Response` rather than naming `broker/egress`'s, so a test
  drives the whole arm with a function and no socket. Every inbound field
  is decoded totally; a malformed request is refused by the *plan*, so it
  consumes no ordinal and no admission.
- `client/extension/memory` — the durable half of those two arms, and
  the same split `client/scheduleseam` fills for `tools/schedule`: the
  seam owns the wire, this owns the store. `Cell(extension:, key:)` and
  `key(cell)` are the one composition of `ext/<name>/<key>`, so the
  confinement is a line rather than a convention; `door(Wiring(runtime:))`
  borrows the live runtime through the Agency's holder
  (`for_session(agency_config)`, because the runtime does not exist until
  `api.open` has returned the registry these tools are in);
  `shut(reason)` is what a host with no session hands the dispatch, so
  the capability is routed and refuses with a sentence. A write is
  `put_reserved_fact` — blind, latest-wins, no compare-and-set — and a
  read is the plain `fact`, which never consulted the reservation. The
  value is parsed with `core/json.parse` on the way in and rendered on
  the way out, so a cell holds a document rather than a quoted string.
- `client/extension/hosts` — the session's satellites, held open and
  handed out. One supervised actor per session keeps at most one
  `satellite.Host` per installed extension, starts it lazily on that
  extension's first use, and stops every one of them when the session
  ends. `invoke` and `invoke_event` are the two entry points, over a
  `Hosts` seam closed over the actor's registered *name* rather than a
  subject (the `client/scratch.seam` pattern: the seam is built while the
  registry is assembled and the actor starts later, under a supervisor);
  `none()` is the seam a session with no registry hands out, refusing
  every invocation in band. `Coordinates` is where an invocation sits —
  `{op_id, step_id, strand, workspace, base_policy, demand, env}` — one
  record because a tool dispatch fills it from `tool.Ctx` and a hook fills
  it from the strand the event fired on, and a positional signature they
  both have to get right is one either can get wrong silently.
  `Extension` is the recipe: a name plus `start`/`invoking` *functions*,
  because a host is launched under the coordinates of whichever call was
  first and an invocation is judged under its own. `HookFailure`
  (`Unhandled | Refused | Crashed | Deadline | Gone`) is deliberately
  smaller than `satellite.InvokeError`: what a caller does depends on
  whether the extension answered, died mid-answer, ran out of time, or is
  not there any more. **The actor performs each invocation on its own
  timeline, so its mailbox is the queue** and a second caller waits rather
  than reading `Busy` — which makes it a session-wide serialiser rather
  than a per-extension one, a deliberate simplification whose only cost is
  two *different* extensions invoked from two strands at the same moment.
  A host the satellite lost is `Departed` for the rest of the session, and
  every later call on that extension is `Gone`.
  `invoker(hosts, at:)` is `invoke_event` curried into a
  `hooks.Invoker`, with `bus_failure` restating this module's
  `HookFailure` in the bus's; it is what makes a hook and a tool call
  land on the same node. It satisfies the bus's contract by
  construction rather than by care: the host arms the invocation's
  deadline as the state timeout of the `Answering` state it belongs to,
  and every step of `invoke` is a `Result`, so a wedged registry
  degrades to `Gone` where a `process.call` would have exited the strand
  driver. `client/serve` builds one such invoker per session, under
  coordinates it mints an operation for: the bus's `Invoker` carries
  none, because a hook fires on the harness's own timeline rather than
  inside a run whose `{op_id, step_id}` it could borrow, so a hook's
  reads are attributable to the session's hooks and never to whichever
  run was in flight.
- `client/extension/dispatch` — `tools(config, record, manifest,
  sources:, artifact:)` turns one `installed.Ready` into `tool.Tool`
  values (`prompt_snippet` from the manifest, schema read from the
  installed `schema/` file, `replay: tool.Never`, `execution_mode:
  tool.Exclusive` — neither declared by the manifest, because both are
  judgements about what the harness may do with a call), and `hosting`
  turns the *same* record and the *same* configuration into the
  `hosts.Extension` the registry launches from, in the same call, so a
  host and a tool cannot end up describing different extensions.
  `Config.hosts` is the registry seam. Each `run` builds this
  invocation's `coordinates(ctx)` and hands them to `hosts.invoke` with
  the model's arguments as JSON text in the `{args, strand}` envelope
  `ext/runtime` reads; the answer goes through `settle`, which now takes a
  `Result(MsgPackValue, hosts.HookFailure)` and is still public because it
  is the one part of a dispatch a test can hold still. **No work directory
  is prepared or removed per call**: a host's socket and token file live
  under `codemode.host_root(config, extension:)`, keyed on the extension
  because they outlive every call. The router is two layers now rather
  than three — `seam.routing` over `codemode.workspace_seam_for`'s bridge
  over `satellite.default_router` — and it, the ceilings and the clearance
  identity are all built per invocation. A call's wall budget is `within`,
  the manifest's `timeout_ms` clamped to the operator's `max_within_ms` —
  an extension tool is `Exclusive`, so the call holds the strand's
  exclusive slot for the whole of it, and an install is not a way to raise
  a host's ceiling. The *node's* own budget deadline is
  `host_lifetime_ms` (twelve hours): the backstop a runaway satellite dies
  against, far longer than a session and far shorter than forever, and
  nothing anybody tunes. There is no MCP arm: `cap/mcp` is on no seam, so
  an extension cannot name it. `Ctx.grants` are **not** composed onto an
  invocation — an extension runs at exactly what its install approved,
  where a `code_mode` call is the model's own program in this turn and
  does compose them.

**The credential path, stated once.** A `[[net.secret]]` names an
environment variable, a host and a header. The *name* travels into
`egress.Policy`; the value is read by `broker/egress` through the
`secrets` function `serve` injects (`env_text`, the same store
`api_key_env` reads), after the origin and the method are judged, and
goes straight on the matching hop. It is in no `Tool`, no `seam.Answer`,
no `egress.Refusal` (no variant has a field for one), no `node_env` and
no `env_allow`, and `policy.summary` counts bindings rather than naming
values. `client/extension_e2e_test` reads the `LaunchSpec` and taps every
frame in both directions and asserts the value appears in neither.

**Boot registration is in `serve.assemble`.** `extension_contributions`
reads `installed.discover(record.root_for(Settings.home))`, logs each
`Refused` under `extension.refused` (an operator who sees nothing cannot
tell "broken" from "I imagined it"), logs `extension.unavailable` for a
`Ready` on a host with no toolchain — no `erl` means no satellite, and
registering tools that can only fail would put them in the provider's
cached byte prefix — and returns *both* halves of one discovery: the
`contributions.Contribution` per extension, appended after the built-ins,
and the `hosts.Extension` recipe the satellite registry launches from.
One pass rather than two, because deriving them separately is how a host
and a tool come to describe different extensions. A repeated name refuses
the boot in `contributions.registry`.

**The satellite registry follows the scratch store's two-name pattern.**
`assemble` mints `loom_ext_hosts` before the tool registry is built, hands
`extension_hosts.seam(name, margin_ms:)` to the dispatch configuration,
and adds `extension_hosts.supervised(name, extensions.hosting)` to the
*services* supervisor — that tier because a registry restart costs exactly
what a satellite crash costs, which extensions are already written to
meet: every host it held is `Gone` to its next caller, the tools stay
registered, and each lost node is reaped by the launcher's own janitor.
`extension_host_margin_ms` (30 s) is the slack a caller's wait has over
the invocation's own deadline, so a caller never reports a wedged registry
for an invocation that was merely being timed out properly.

**The TCB freeze is a test in this package.**
`client/test/client/extension/freeze_test.gleam` is #33's record in code:
the compile-time half walks the package graph (`packages/ext` names only
`cap`, `cap` only `core`, `core` none), the resolved `manifest.toml`,
`codemode/seed.default_vendored`, and every import in `packages/ext/src`
and `packages/cap/src`; the runtime half pins `policy.extension()` and
`policy.resident()` as exact sets and shows both disjoint from every
module the TCB packages ship, walked from the tree so a new module under
`storage/` is covered the day it lands. It lives here rather than in
`codemode` because only this package can see both the seams and the tree
without a new dependency. The loader (#32) is deferred;
`docs/review/extension-zone.md` says why and carries the measurement a
loader would inherit.

**The verb split lives in `client.gleam`, not `serve.main`.** The
installer needs the boot's own effect plane, so `extension/cli` imports
`client/serve`; putting the dispatch in `serve` would be an import cycle.
`client.gleam`'s module doc says so, so the next reader does not move it
back.

**`serve.start_effect_plane` and `serve.start_build_plane` are the boot's
own, factored out.** An install runs the same jailed, network-off `gleam
build` a code-mode program is built by, against the same seed, under the
same base policy, found by the same helper and seed ladders. Two
implementations would be two answers to "may this build run". The
`writable` and `workspace` arguments are separate questions and a boot
only ever asks them of one directory: the seed ladder looks in the
checkout, and the jail may write only where the build root is, which for
an install is under the extensions root.

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
  `mcp` (the JSON-RPC codecs, the stdio client actor, the façade
  generator and the value interchange `client/mcp` wires into code mode),
  `telemetry` (the JSON handler this entry point installs, and the
  logger it injects into `api.Options`),
  `mist` + `gleam_http` (the websocket transport), `simplifile` (the
  token file, the pack file, and the session's instruction files),
  `weft` (the bounded concurrent run `client/mcp.start` fans server
  bring-up out over).
- The spec DAG (§0.1) writes `L → A,C,E,K`. The `B`, `D`, `F`, and `G`
  edges are real and load-bearing — catch-up scans storage directly,
  compaction and navigation build `machine/acceptance` plans, the delta
  tap types against `provider/stream`, and grants are broker policy
  values — and are worth knowing about rather than papering over. The
  wiring promotion added `tools` (the registry and per-call `Ctx`);
  `client/serve` added `argv` (flags); `client/catalog` added `tom`
  (the pure-Gleam TOML parser behind `--config`); `client/system_prompt`
  added `prompt`, whose purity is why the I/O had to live on this side;
  `client/schedule` added `gleam_time` as a direct dependency — already
  resolved transitively through `tom`, and its total
  `gleam/time/timestamp.parse_rfc3339` is what a one-shot schedule's
  `at` field parses with, rather than a second RFC3339 parser or TOML's
  own bare datetime literal.
- **Depended on by**: `conformance`, whose wiring and e2e suites import
  `client/wiring` (legal — T depends on all). `packages/tui` is its
  native client, coupled only through the protocol and the golden fixtures.
- **`client/internal/timebase`** is the one non-FFI module under
  `internal/`: it adapts a `core/clock.Clock` and a seam's injected `rest`
  into the `weft/poll.Clock` the two foreground waits run on
  (`escalate.park`, `agency.wait_loop`). Its module doc carries the ruling
  a reader will otherwise re-derive — the successor clock `clock.read`
  hands back is discarded, because `from_function` returns itself and
  re-calls the injected function on every read, and `clock.stepping`
  cannot serve a loop that holds one clock value across many reads. A wait
  built on a clock whose `now` does not move never expires; every fixture
  in this tree that drives one of these waits is a `from_function` over a
  counter actor for that reason.
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
  `events/bus` subscriptions, and `tap_provider`'s wrapper. The hub's bus
  subscription is keyed by the session's **canonical id**
  (`bus.key(of: api.session_id(runtime))`), never by the caller-supplied
  display name; `client/serve` supplies no bus, so nothing exercises it
  today, but a host whose hint sources are not all its own writer needs
  the key that identified publishers actually use
  (`protocol-change/008`).
- `history.Message` — `Pull` (a cast: a commit landed, go sync),
  `Synchronize(reply)` (a call, for a test or an operator), `Query(text,
  limit, scope, reply)` (a call, from the tool seam), and `Stop`.
  Senders: `commit_pull`, the writer's *second* subscriber, which is what
  makes recall a commit-driven projection rather than a scheduled sweep;
  and `client/history.seam`, from a live tool call's own effect process.
  Both reach the holder by name, and both degrade an absent or wedged
  holder to an in-band refusal rather than to a dead caller.
- **Commits**: the hub commits nothing of its own except through the
  session's one writer. Commands map onto `runtime/api`
  (text or ordered-content prompt/steer/follow-up/abort, escalation approve/deny, strand
  creation); `compact` and `navigate`, which have no api entry point yet,
  build a `machine/acceptance` plan and commit it through
  `runtime/writer` — the same pattern the conformance simulation runner
  uses. Nothing bypasses the writer.
- **Registers**: reads `strand.*` (configuration, leaf, state, last
  result) and `op.meta`/`op.state` through the session's typed accessors
  to build snapshots and detect terminals; reads the runtime's escalation
  records under `fact.custom`'s reserved `escalation/` prefix, and the
  assembled system prompt and its enforcement identity under the reserved
  `prompt/` prefix — read off the session store directly before `api.open`,
  written back through `api.put_reserved_fact` after it. The rule scanner
  owns the reserved
  `rule/` prefix: `rule/fired/<strand>/<name>` write-once marks, committed
  with the injection they authorize, and `rule/cursor/<strand>`
  checkpoints, written lazily. Every one of the scanner's *reads* goes
  straight to the session store, never through the writer's mailbox, so
  a scan can never sit in front of a settlement; the fire itself is an
  ordinary queue admission through the writer, on the scanner's own
  process. Strand
  seeding for protocol `fork` and `create_strand` writes `strand.config`
  / `strand.leaf` / `strand.state` (the api's creation path always takes
  a task brief, so the gateway seeds idle strands itself).
- **Search index**: `client/history` writes only to the repository's own
  `loom-search.db`, beside the session file and never inside it, through
  `events/search.sync`. Index rows and the advanced cursor commit in one
  transaction, so a crash mid-batch re-runs the batch into the same
  state; a lost poke costs latency and never a row.
- **Memory**: the boot's own probe still opens nothing — it reads the
  store's header lease-free (`storage/sqlite.generation`), and an absent
  store is the ordinary state of a repository that has never remembered
  anything — but the *server* now writes the store, through the
  supervised `client/distillpass` worker every ordinary boot starts
  (#149). It reads `loom-memory.digest` at **every run start** through
  `memory.digest_hooks`, which takes a thunk rather than bytes for
  exactly that reason: this host runs the producer as well, and a digest
  captured at boot would hold every session one pass behind its own
  pipeline. Memory therefore lands on *run* boundaries rather than
  session boundaries, which costs the same rolling tail write it always
  did — the digest rides messages, never the pinned head — and nothing
  can touch a run already open. The writers are `client/distill` (the
  pipeline, holding the memory session's writer lease for its whole run
  under `run_lease_ttl_ms` — or under the short one for a `--cascade`
  pass, which has no model turn between its commits), reached either from
  the lifecycle worker or from the command line, and the `remember` seam
  (one open per call under the short `lease_ttl_ms`, refused in band
  while a run holds the lease). Usage rows for both model turns land in
  the memory session's own ledger.
- **Wire**: JSON text frames over websocket. The envelope `seq` **is the
  storage seq** of the write that produced the event, so the durable
  stream needs no side index and `catch_up` rebuilds it with
  `scan_entries` / `scan_usage` plus register reads.

## Invariants

- **A linked git worktree widens the session base to its git directories.**
  `serve.widening_linked_worktree` reads `<workspace>/.git`; when it is a
  `gitdir:` file, the named directory and the main repository's `.git`
  its `commondir` points at join `writable_roots`, because a jailed
  `git commit` must write the index lock and objects there and both sit
  outside the workspace. It is the trust a primary checkout's `.git`
  already has. A primary checkout, a non-repository, or an unreadable
  `.git` file leaves the base untouched.
- **A jailed child's environment is three names, built once per session.**
  `serve.session_environment` gives every tool shell, satellite and hook
  host the same `PATH` (the code-mode toolchain's when one was found, so
  `gleam` and `erl` resolve in the shell as they do for the compiler),
  `HOME` (`<workspace>/.codemode/home`, so `bash -l` reads no operator
  dotfiles and what a toolchain writes to its home — macOS makes a
  `Library/Caches` — stays out of the operator's tree) and `TMPDIR`
  (`<workspace>/.codemode/tmp`, the one root the jail lets a tool write;
  the host's temp directory is not reachable from inside). The
  session base policy grants `TMPDIR` for the same reason the code-mode
  builder grants it on its derived base: the policy meet keeps only the
  names the base allows.
- **The `[tools]` table is the only thing that widens either.**
  `catalog.parse_tools` reads an operator's `network = "off" | "full"`
  (off is the default and what an absent table means) plus `env` names
  read from the host at boot and `[tools.set]` literals;
  `serve.tool_environment` appends them *after* the three server-owned
  names, and `serve.under_tools_config` puts the chosen network on the
  session base and every configured name on its `env_allow`. Both halves
  are load-bearing and neither implies the other: the meet takes the
  narrower network, which is why `bash` and `grep` ask for the base's
  (`tool.asking_base_network`) rather than stating off, and the meet also
  intersects `env_allow`, which is why a name in the environment but not
  on the allowlist is a narrowing refusal rather than a variable. `PATH`,
  `HOME` and `TMPDIR` are refused from both lists by the parser, so the
  ordering in `tool_environment` is the second lock rather than the only
  one. A configured name the host has not set is skipped with one
  `tools.env_unset` warning, never a boot failure.
- **Envelope decoding is strict; name decoding is tolerant.** `v` must be
  `1`, the discriminator must be present, and a command `id` must be
  present and positive. Unknown `cmd`/`event` *names* survive as
  `UnknownCommand` / `UnknownEvent` so the receiver can answer in band;
  unknown *fields* inside known bodies are ignored (forward compatibility
  within v1).
- **Everything in `protocol` is pure and total.** Malformed input is a
  `ProtocolFault` value, never a crash.
- **A content prompt is admitted atomically.** The gateway decodes every
  block through `core/codec`, validates image base64 and non-empty MIME types,
  and refuses an empty or partly malformed list before `runtime/api` sees it.
  A successful command appends one `UserMessage` in the original block order.
- **Durable JSON crosses verbatim.** Gateway-defined field names are
  `snake_case`, but values that already have a durable form in the
  harness — entries, messages, usage — are carried in `core/codec`'s
  vocabulary (pi field names, camelCase) rather than re-rendered.
- **The wire form is pinned by the golden fixtures** under
  `packages/client/testdata/protocol/`, which this package decodes and
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
- **The system prompt is assembled at a session's first open and pinned
  with its enforcement demand.** Every later boot at the same demand sends
  the pinned bytes rather than deriving them again — the agent may have
  edited `CLAUDE.md`, the kernel may have changed under a restart, and a
  prompt re-derived from moved inputs is a full one-hour cache write on the
  first turn after every restart. The demand is the one deliberate cache
  break: a changed flag or a legacy pin with no demand identity renders and
  pins once, because keeping bytes that claim stronger enforcement than the
  broker now demands would trade truth for cache stability. Both cells live
  under the reserved `prompt/` prefix, so no model-reachable `put_fact` can
  rewrite the operator's channel.
- **The pin is read before `api.open` and written after it.**
  `wiring.Config.system` must hold the string before the open, and the
  open is what stands the writer up — so the cells are read straight off
  the session store while nothing owns it, and written back through
  `api.put_reserved_fact` once there is a writer to journal it. Same knot
  as the Agency's, solved by ordering rather than by a name because the
  value is data, not a process.
- **Nothing volatile may enter `system_prompt.Host`.** No clock, date,
  elapsed time, token count, cost, git state, id, strand name or random
  value — and no numeric field at all, which is the shape all of those
  arrive in. The list fields are sorted and de-duplicated by
  `pack.environment` before they can reach the bytes, for the same reason
  the tool array is sorted: both sit inside the cached prefix. The one
  exception is `available_tools`, the prompt's tool index, which is
  de-duplicated but not sorted: its order is the registry's registration
  order, which is fixed for the session and is what a reader wants.
- **A prompt pack refuses loudly or serves; it never disappears.** A pack
  file that cannot be read, does not decode, or renders to nothing stops
  the boot with a worded message naming the file and the fault — a
  silently-empty system prompt is the failure this seam exists to end. A
  pack that merely trips `pack.problems` (a dropped section, a misspelled
  placeholder) warns on stderr and serves: `decode` accepts more than
  `problems` approves by design, and a thin prompt beats a dead server.
- **The operator's instructions layer under the workspace's, and only a
  file that is not there lets the global lookup move on.** Slot one is
  the operator's global `AGENTS.md` — `~/.agents/AGENTS.md`, then
  `~/.loom/AGENTS.md`, first found wins — carried into every session;
  slot two is the workspace's `AGENTS.md` and slot three its `CLAUDE.md`,
  neither of which has a fallback. A workspace `AGENTS.md` that exists
  but is oversize or unreadable warns and leaves its slot empty rather than
  falling
  through to the operator's defaults: serving standing operator
  instructions in place of a project file that happened to be unreadable
  would swap one set of instructions for another behind everyone's back.
  Every one of these reads warns and continues; none of them can stop a
  boot. `HOME` unset is the launcher's hard failure degraded to a
  warning, because a missing instruction file must never cost a session.
- **The fence around an instruction file is the harness's, and its
  `origin` attribute is a claim only the harness can make truthfully.**
  At most one `user-default` block exists and it is always the first,
  which is what the pack's prose tells the model to check; the bytes
  inside a block are otherwise verbatim, and framing a hostile file does
  not make it safe — it stops it speaking with the operator's voice, and
  the residual risk is accepted and named, exactly as it was for the
  single-file case.
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
- **The bound with an answer fires first.** Two capabilities this package
  services answer on bounds of their own, and both must sit *below*
  `client/codemode.default_call_timeout_ms` (120 s): `client/mcp`'s
  `default_call_timeout_ms` (60 s) and `agency.default_config`'s
  `max_wait_ms` (30 s), the ceiling one `agent_wait`/`strand.wait` is
  clamped to. A `ServedHere` call the satellite host gives up on is
  answered `unsettled` and its worker killed, so inverting either ordering
  would trade a real answer for that refusal on *every* call. The
  constants live in three modules and nothing but a test can hold them in
  relation, so each is pinned by one:
  `the_mcp_call_timeout_wins_the_race_test` and
  `the_wait_ceiling_wins_the_race_test`.
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
- **The rule scanner's "provably dead" is the ledger's `reaped` mark,
  never a terminal `strand.last_result` alone** (issue #113). The
  asymmetry above is exactly why: since a live ancestor may still hand
  an idle *child* fresh work — never refused, unlike the upward case —
  a finished strand is not a dead one, and `client/rulescan` would
  silence an operator's rule on a strand that might fire again tomorrow
  if it treated "finished" as "will never run again". Only
  `client/agency`'s own decision to end a child (an overdue deadline, or
  its parent's run ending undetached — `reap`, in `client/agency`) is
  durable and deliberate enough to trust, and even that is a named
  residual rather than a mechanical guarantee: nothing stops a live
  ancestor that still remembers the child's name from addressing it
  after the reap. `client/rulescan`'s module doc has the full argument
  and the FAIL OPEN branches (no cell, a cell that will not decode).
- **A schedule is owned by the strand that created it and lives no
  longer than the strand it fires onto.** Those are two rules and both
  are needed. Ownership is what makes a schedule retirable: cancellation
  and listing are keyed on the creator, so a parent can cancel a
  heartbeat it set onto a child that has already settled — which nobody
  could do while a schedule was cancellable only by its target (#163).
  The target's lifetime is what makes it bounded: `client/scheduleseam`'s
  `run_end` reap retires every schedule keyed to a strand whose brief
  just ended, and `client/schedulescan` refuses to fire onto a target
  the lineage ledger says is reaped or whose brief has settled, so
  neither a lost reap nor an operator's `[[schedule]]` can keep a
  finished child's clock running. A target may only ever be the caller
  or a strand it spawned, decided from the ledger through
  `agency.owns` — the addressing rule above, narrowed — and no schedule
  onto a subagent may wake it, whatever the operator's policy permits,
  because a subagent has one run and a fresh one after its work ended
  would extend a child's life outside its parent's spawn budget. What
  ownership does not move is a schedule's identity: the config, seen and
  fired keys stay `{target, name}`, because an occurrence is a fact
  about the target's timeline.
- **A code-mode submission is judged against the seam it named, and
  routed by the seam the host wired.** The two halves are read from
  different places on purpose. The allowlist follows the *submission*
  (`exec_config` takes its vetting policy from `Request.seam`), so a
  refusal the model reads is about the surface it asked for. The router
  and the admission ceilings follow the *surface*, so a host serving one
  seam hands out that seam's router whatever a request names and no
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
  pair, which is the *batch* identity the broker pools budget on —
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
- **The harness-side capability bridge builds no clearance, and
  re-derives no authorization.** `fs.read`, `fs.list`, `kv.*` and
  `report.emit` are answered as `satellite.ServedHere` — no
  `broker.CallSpec`, no jail, no composed policy — because none of them
  leaves the VM and a policy whose enforcer is not present is not a
  check (issue #16). What contains them instead is `tools/fs`'s own
  `resolve_real`, called by the injected closure: the *same* function
  `fs_read` calls, so a symlink planted inside the workspace and pointing
  out of it is refused for the bridge exactly as it is for the model's
  own tool. Writing a second resolution here would be a second boundary
  to keep correct, and the one that got it wrong would be the one nobody
  was reading. The write arms are wired through the same discipline:
  `fs.write` resolves through `resolve_writable`, so a satellite program
  meets the protected-path refusal (#105) exactly where the model's own
  `fs_write` does, and `fs.edit` is read-apply-write inside one served
  call under `codemode/workspace.apply_replacements`' exactly-once
  find/replace ruling — the tightest window the seam can offer, and a
  strictly tighter one than the two-round-trip composition a program
  would otherwise hand-roll.
  The write itself is `fs.write_whole`, which is what `fs_write` calls,
  so **both doors create missing parents** and `new_dir/file.txt` means
  one thing whichever door it came through. A `fs.list` of a
  non-directory is `NotADirectory` under the `not_a_directory` code
  rather than an errno sentence, because it is the one listing failure a
  program can act on — `fs.read` was the call it wanted — and
  `readdir`'s own `ENOTDIR` brings the special files (FIFO, socket,
  device node) under the same honest name.
- **A base policy the sandbox cannot enforce is a boot failure.**
  `Settings.base_policy` is a field, so a host may hand `boot` any
  policy value it can construct, and `assemble` asks
  `base_policy_fault` before a directory is made, a lease is taken or a
  helper is spawned. The case that motivated it: a relative `protected`
  entry is refused by the jail as `RelativePath` and covers nothing in
  the harness's own path checks, so an operator who wrote
  `protected: [".git"]` would otherwise get a session protecting nothing
  and learn about it from the first tool call of it. The check is
  `broker/policy.validate`'s — the same one every composed policy passes
  immediately before dispatch — so what refuses here is exactly what
  would refuse there. Pure and separate from `boot`, because it is a
  decision about a value and should be testable as one.
- **A blob is established by a rename, never by a write.** `report.emit`
  writes through `blob.write_addressed`: the bytes are staged under a
  temporary name in the blob root and renamed into place, so a crash
  mid-write can never leave a partial file at an address whose SHA-256
  name vouches for the whole of it. The staging name carries eight
  random bytes off `Config.entropy`, because two concurrent first
  emissions of identical bytes are precisely the pair a content address
  cannot separate and a shared staging name is where they interleave.
  Idempotency is untouched: the destination is the address either way,
  and the `is_file` probe still skips the work.
- **`report.emit` is one mechanism on two seams, and the one workspace
  capability with a ceiling.** `cap/report` is the only module both
  vetting allowlists carry, so both routers answer `emit` — from the same
  closure, into the same blob root, under the same content address and
  the same 64-per-execution ceiling (`codemode/artifact`). It earns a
  ceiling where `fs.*` and `kv.*` do not because every admitted call
  writes something that *outlives the execution*, which is
  `satellite.CapCeiling`'s test; the scratch store is bounded store-side
  by bytes with eviction instead, which is the right instrument for
  something that must not grow rather than something that must not be
  called often. So the workspace seam's ceiling list is no longer empty,
  and the comment saying it was is gone.
- **The only thing the code-mode wiring adds to a session base is two
  environment *names*.** `LOOM_CAP_SOCK` and `LOOM_CAP_TOKEN_FILE` are
  set by the launcher and cannot be shadowed by a caller's `env`, but
  policy composition takes the meet — so a base that does not name them
  composes them away and the satellite cannot find the channel it exists
  to speak on. `execution_policy` adds exactly those two and leaves every
  other dimension untouched; it is one small named function so it stays
  auditable rather than diffusing into the wiring.
- **An execution's files live in their own directory inside the
  workspace,** named for `{op_id, step_id, source_index}` and removed
  when the execution settles. Inside the workspace, so the session base already
  makes it writable and nothing has to be widened to build there; unique
  per execution, so neither two strands running code mode at once nor two
  `code_mode` calls in one batch can share a build root. The third field
  is what makes the second true: `code_mode` is `tool.Exclusive`, which
  forbids a concurrent *start* and nothing more, so one batch may hold two
  `code_mode` calls that run back to back under one operation and one
  step. Keyed on the pair they would build in one directory, bind one cap
  socket and write one token file — and the launcher's janitor runs
  teardown asynchronously after the host dies, on ordinary exits too, so
  the first execution's cleanup could unlink the second's live socket and
  token, while `prepare_root`'s recursive delete races the same janitor
  the other way (issue #87). The name is a short digest of that triple
  rather than the triple itself, because the cap socket sits inside it and
  an AF_UNIX path is capped near 108 bytes — a socket that would exceed
  the limit is refused in band, naming the workspace, instead of failing
  as an opaque `einval` from `listen`.
- **MCP reaches a model through code mode, and a host with no code mode
  starts no MCP server.** A server's tools are a *module* a program may
  import, never a registered tool, so a host that registers no
  `code_mode` has nothing that could ever call one — and spawning
  third-party server processes for it would be cost and attack surface
  bought for no capability. One `mcp.unavailable` line says so, naming
  the servers that were skipped. Per server, every failing step —
  a missing executable, a refused handshake, an unset `api_key_env`, a
  listing the generator will not accept — is one more `mcp.unavailable`
  line and no boot failure, and it is the only thing anybody will ever
  see about it: a refused server has no module, so a program importing it
  is refused by vetting with no word about why the module is absent. A
  working layer logs `mcp.ready` with each server's name and tool count.
- **An `api_key_env` is a variable name, and the value is read at spawn
  and never held.** It is resolved from the harness's own environment
  through the same `provider/secret` seam every other configured secret
  goes through, put into the child's environment under the same name, and
  never stored in a record, a log line, or a refusal message. A
  configured variable that is unset refuses that server *before* anything
  is spawned.
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
- **A claim's checks and its commit are the same read.** The park's probe
  reads an `api.EscalationCell` and spends through
  `api.consume_escalation_at`, which CASes at that seq, so a claim
  landing between the scope-and-action checks and the consume loses the
  commit instead of passing unseen (#68). The cell travels through the
  `weft/poll` loop as the probe's own value, so moving the loop onto the
  primitive did not put a re-read between the decision and the CAS.
- **Both foreground waits make a first attempt immediately and a last one
  at the deadline.** That is `weft/poll`'s contract, not this package's,
  and it changed one behaviour worth knowing: `park` used to check its
  deadline *before* reading the record, so a window already shut settled
  without a read. It now costs one read, and an approval landing exactly
  on the deadline is honoured rather than missed. `agency.wait_loop` folds
  the map of already-settled handles from one attempt to the next, so a
  slice never re-asks the store about a child that answered on the first
  pass, and expiry hands that map back (`poll.RanOut`) so the settled
  children are still reported `Ready`.
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
- **Provider wrappers inherit stream ownership.** `gateway.tap_provider` and
  `wiring.recording_summaries` each return a prepared provider surface. Each
  wrapper publishes a minimal custodian while its guard is parked; only after
  the parent adopts that owner does the guard prepare and adopt the inner
  stream, then grant its begin permit. The guard
  remains the inner stream's direct consumer; only each synchronous observer
  call moves to a monitored worker. The custodian adopts both and the inner
  owner, while the guard retains its own pre-begin drain monitor. It forwards
  cancellation inward and bounds missing acknowledgement with
  `CancellationUnconfirmed`, then stays alive until the registered subtree
  exits. An abnormal transitive Down becomes terminal `DrainProofLost`, never
  retry permission. This keeps the chain continuous from driver reaper to runtime
  custodian, relay custodian and guard, gateway custodian, guard and pump, and
  the native HTTP owner plus its dedicated handler; no wrapper may turn
  consumer death into a detached request.
- **Named helper traffic binds observation and delivery to one incarnation.**
  Ephemeral commit hints, provider deltas, hub casts, and holder calls resolve
  a registered name once, then send its tagged envelope directly to that PID.
  If an optional hub unregisters before resolution its hint is dropped; if it
  exits afterward the PID send is a no-op or the caller's existing monitor
  reports unavailability. Re-resolving the name inside `process.send` would
  leave a race that converts an ordinary restart into a caller crash, or asks a
  replacement while still monitoring its predecessor.
- **Wrapper comments narrate ownership handoffs.** The module story names why
  the guard, observer, and custodian are separate; comments at publication and
  adoption say what becomes safe after each acknowledgement. Do not reduce
  this to comments which merely restate a `spawn`, `send`, or monitor call.
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
- **Compaction is answered by these seams, with the strand's own notes,
  and no provider is asked.** `compaction_hooks` answers every
  compaction's structural decision `VerdictSupplied` with the checkpoint
  `client/checkpoint` builds — the window header, the `agent/{strand}/`
  cells, the operator's instructions — and no usage, because nothing was
  billed. It declines a branch summary (notes say nothing about an
  abandoned branch, and nothing asks for one) and a checkpoint whose
  registers would not read (a declined threshold compaction leaves the
  run alive; publishing a false "no notes" would not be recoverable).
  `VerdictGenerate` is never selected: the machine's generate path is a
  frozen contract the simulation still drives, and a `SummaryRequest`
  reaching `dispatch` is refused terminally, since no prompt exists to
  make one with. The M3 demo installs *these* hooks over its scripted
  provider — it has no `demo_hooks` of its own — so the `CompactionEntry`
  it asserts on is the hook-supplied checkpoint production code
  published.
- **The reminder and the tool read the threshold's own numbers.** The
  `context` slot appends the notes reminder once a strand's context
  passes `checkpoint.reminder_point` — one reserve below the cut — and
  `context_remaining` answers from `checkpoint.remaining_seam`; both
  re-project the strand through `runtime/hooks.project` and price it
  with `hooks.context_tokens`, never from the message list in hand,
  because the fold has to skip what a compaction carried or it reads the
  pre-compaction usage and fires forever. The window is
  `wiring.strand_window`'s, the strand's own. Asked and told are one
  number.
- **The reminder is transient.** It is a transform on one request's
  messages, never an entry: a crash re-projects and re-decides, and the
  tree never holds it. `a_near_limit_request_carries_the_notes_reminder_test`
  pins both halves — that the request carries it inside the band and
  that the durable projection does not.
- **Role follows identity, and the role is derived at dispatch.** An
  `effects.RequestSpec` carries no strand name and one wiring config
  serves every strand, so `wiring.request_target` asks the *captured
  identity* which role it is on: the first routable role in canonical
  order (`main`, then `subagent`) whose usable chain **head** equals it,
  ties to `main`. A match dispatches `ForRole`, so the gateway walks that
  chain inside the one attempt and a rate-limited head costs a fallback
  rather than the machine's retry ladder. No match dispatches
  `ForResolved` on exactly the captured identity. Both answers are a pure
  function of durable state and boot configuration, which is what makes a
  post-crash re-attempt choose what the original attempt chose — recovery
  orphans an in-flight request and re-attempts it, it never re-dispatches
  one. There is deliberately no per-request rerouting, no mutable role
  registry, no health tracking and no sticky chain position: the head is
  tried first, every time.
- **A deferred poll is always `ForResolved`.** The handle belongs to the
  identity that minted it and ORCH-L4 validates the settlement against
  exactly the captured `{provider, model_id, api}`, so a poll that walked
  a chain would fetch a continuation nobody issued. The mirror cost is
  written down in `protocol-change/009`: a *generation* settled by a
  fallback target that returned `Deferred` fails the same check and drains
  as failure. Nothing settles `Deferred` today.
- **A catalogue entry's `thinking` seeds a strand; it never overrides a
  dispatch.** The per-turn level is absolute at dispatch and travels as
  the walk's overlay onto *every* target attempted, so a fallback cannot
  answer at a smaller reasoning budget than the head was asked for.
  Where the entry's level does take effect is strand *creation*, at all
  three points and by one lift (`wiring.strand_thinking_level`):
  `serve.seed_thinking` for `main`, `gateway.seeded_thinking` for
  `fork`/`create_strand`, and `agency.child_configuration` for a spawned
  child. `set_config model_name` deliberately leaves `thinking_level`
  alone — switching model is not a request to un-raise a budget somebody
  raised.
- **A spawned child's model is chosen once, at creation.**
  `agency.Config.subagent_model` is the host's `subagent` route resolved;
  `client/serve` fills it from the gateway. An unrouted subagent role
  inherits the parent wholesale rather than refusing, which is what every
  child did before the role reached the seam.
- **Model facts follow the identity, not the configured role.**
  `wiring.Config.facts` is an `identity -> #(ResolvedModel, api)` seam
  `client/serve` builds from the catalogue, and it is what makes a strand
  switched off-route honest: admission is answered **per query** from the
  query's own configuration, the compaction threshold's window is the
  *strand's*, and an off-route dispatch target carries the switched-to
  entry's counts. The api half matters as much as the counts — it is
  captured durably into the generation intent and is what ORCH-L4 later
  validates a deferred handle against, so a boot-frozen answer named the
  main entry's dialect for a strand switched to the other one. Only an
  identity the catalogue does not know falls back to `Config.api` and the
  two `fallback_*` counts.
- **A checkpoint never publishes a blank.** A strand with no notes is
  told, in the checkpoint, that it wrote none and where notes go; a
  checkpoint whose inputs would not read is declined rather than
  rendered from an empty board. Neither shape can replace a window with
  nothing, or with a false record of nothing.
- **The `before_compact` note lands in the checkpoint.**
  `runtime/strand_runtime` asks `Hooks.compaction_note` at the structural
  decision and appends every block after the harness's own text and the
  strand's notes; `extension/hooks.note_block` frames it for the model
  reading its next window, not for a summarizer. Still never a veto, and
  still under the replay rule: the decision is transient until the
  publication commits it.
- **The operator's `compact` instructions reach the checkpoint from the
  operation's durable state**, not from the preparation:
  `StructuralPreparation` has no field for them, because the preparation
  is the *input* the decision hook froze and the instructions are a
  property of the operation that asked. They are quoted in the
  operator's own words, in their own fence.
- **A manual `compact` cuts where an automatic one cuts.** The hub's
  preparation goes through `runtime/hooks.preparation` — the same
  builder the threshold and overflow hooks use — against the run's own
  settings snapshot.
- **The server has two supervision tiers, and the line between them is
  reachability.** A child under `Booted.services` — the commit
  forwarder, the Agency holder, the escalation holder, the scratch
  store, the rule scanner, the scheduled-heartbeat scanner, the
  search-index holder and its commit subscriber, the gateway hub —
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
- **A plane nobody configured costs nothing, and says so.** A
  `loom.toml` with no `[[rule]]` starts no scanner at all — not a
  scanner holding an empty list — and logs `rules.none`; a configured
  one logs `rules.loaded` with the count and the names. A `loom.toml`
  with no `[[schedule]]` takes the identical posture: `schedules.none`
  or `schedules.loaded`, no scanner started or a supervised one holding
  exactly the configured list. This is the `codemode.unavailable` line's
  reasoning applied again: an operator who configured something and
  sees no effect must have a line to reason from, and a host that
  configured nothing must run exactly the processes it ran before the
  feature existed.
- **A dormant rule is byte-absent from a context, not merely cheap.**
  Rules live in the configuration file, fired-marks and cursors live in
  reserved registers, and neither is an entry — so nothing a rule
  contains can reach a projection until the scanner commits an
  injection. The projection tests assert exactly that, in both
  directions.
- **Recall is a projection with no authority, and the wiring says so
  three times.** An index that will not open costs the `history_search`
  tool and one log line, never the boot. A holder that crashes is
  restarted and reopens the file. A sync that fails leaves the durable
  cursor where it was, so the next commit's poke retries it. Nothing
  about a session's correctness depends on the index being right, which
  is what lets every one of those failures be quiet.
- **The distillation pass runs once per boot, skips the live session by
  its lease, and retries by being run again next boot.** Each clause is
  load-bearing. *Once*, because the material it may read does not change
  while this server runs — a live session's own lease is what puts it out
  of reach — so a timer or a per-turn hook would buy re-reads and model
  turns for nothing. *By the lease*, because the worker starts in the
  service tier, after `assemble` has taken the session's writer lease, so
  the skip is a property of the ordering rather than of a check. *Next
  boot*, because the pipeline's write order (rows, head-and-cursors CAS,
  sidecar) means a pass killed anywhere moved no cursor. The one residue
  is the memory lease a killed pass cannot release: the store is
  consistent, and a boot inside the ten-minute run TTL logs
  `memory.distill.failed` naming the holder rather than distilling.
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
- [docs/architecture/memory.md](../../docs/architecture/memory.md) — the
  store, the pipeline, the lease rules, the lifecycle worker, the digest
  injection and the erasure cascade's rewind-on-drop (#124).
- [docs/design-notes/compaction-and-memory.md](../../docs/design-notes/compaction-and-memory.md)
  — Stage C0: which seams were inert, what each hook now decides from,
  and the cache arithmetic the summary request's shape follows.
- [packages/prompt/CLAUDE.md](../prompt/CLAUDE.md) — the pure half:
  the pack format, the renderer, the summarization pack, and what
  `Environment` may never grow.
- [packages/tui/CLAUDE.md](../tui/CLAUDE.md) — the other end of the wire.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.

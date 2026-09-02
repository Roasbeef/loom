//// The ClientGateway hub: one actor per served session that speaks the
//// Part 1.6 protocol to any number of attached connections.
////
//// ## Shape
////
//// The hub is transport-agnostic: a connection is a sink function the
//// transport registers with `attach` (the websocket server sends each
//// encoded frame down its socket; the demo and the tests collect them
//// in a subject). Inbound frames arrive as text through `handle_text`;
//// every reply and broadcast leaves through the sinks. Nothing in this
//// module knows about sockets.
////
//// ## The durable event stream (protocol.md open question 4)
////
//// The envelope `seq` **is the storage seq** of the write that produced
//// the event. Storage assigns strictly increasing seqs to every write —
//// entries, usage rows, and register sets share one per-session space —
//// so the gateway's stream needs no materialized side-index: it is
//// durable across gateway restarts by construction, and `catch_up`
//// rebuilds it with `scan_entries`/`scan_usage` plus register reads.
//// Two consequences, both documented protocol behavior:
////
//// - `entry` and `usage` events replay exactly (their rows are
////   immutable, scanned by seq range);
//// - register-backed events (`op_transition`, `escalation`,
////   `strand_result`) replay as *current state at current seq* —
////   registers keep no history, so a superseded phase is not
////   reconstructible. Events are hints and the snapshot carries the
////   live state, so a client that missed an intermediate phase still
////   converges; overlap and gaps are resolved by seq dedup as
////   protocol.md already requires.
////
//// Live materialization follows "events are hints; pulls are truth":
//// the runtime writer's post-commit publication (bridged in by the
//// composition layer via `commit_forwarder`) and any events-bus
//// publications both merely trigger a pull from storage above the hub's
//// high-water seq. A lost hint costs latency, never an event.
////
//// ## Command dispatch
////
//// Commands map onto `runtime/api` (prompt/steer/follow-up/abort,
//// escalation approve/deny, strand creation) and — for compaction and
//// navigation, which have no api entry point yet — onto
//// `machine/acceptance` plans committed through the session's one
//// writer, the same pattern the conformance simulation runner uses.
//// Nothing bypasses the writer.
////
//// ## Deliberate v1 interpretations (see the WP-L report)
////
//// - `fork` (both scopes) forks **in place**: a new strand whose leaf
////   is the source strand's current leaf. The protocol's reply is a
////   `strands` snapshot of *this* session, which cannot name a separate
////   forked session file; `session/repo.fork` stays an admin surface.
//// - `steer`/`follow_up` acks: the queued item is durable as a pending
////   register, not yet a placed tree entry, so the ack `entry` event
////   carries the reserved id and the message with no envelope seq; the
////   placed entry is broadcast (with its real parent and seq) when the
////   run consumes it.
//// - `follow_up` on an idle strand starts a run (protocol.md open
////   question 7 answered queue-as-prompt, matching `send_to_strand`'s
////   idle behavior).
//// - `strand_result` is emitted for every operation kind — runs,
////   compactions, navigations — because all three publish
////   `strand.last_result`.
//// - Escalation `op`/`strand` come off the record's own `CallScope` —
////   the operation, strand, step, source index, and call id the denial
////   was raised for. A record raised through a door that names no call
////   reaches the client with both fields empty; nothing is inferred
////   from which strand happens to be busy.
////
//// ## Stream deltas
////
//// `tap_provider` wraps an injected `runtime/effects.ProviderSurface`
//// so provider deltas are teed to the hub (broadcast as ephemeral
//// `stream_delta` events, never persisted, never seq'd) while the
//// runtime's effect process consumes the stream unchanged. The tap
//// lives entirely in the composition seam — the runtime is untouched.

import broker/escalation as broker_escalation
import broker/policy.{type Grant}
import client/catalog
import client/grants
import client/protocol.{
  type Command, type EntryRecord, type Event as WireEvent, type EventEnvelope,
  EntryRecord, EventEnvelope, LiveOp, Strand,
}
import client/provider_relay
import client/wiring
import core/clock
import core/entry.{type Entry, type UsageRow}
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage, type UserBlock}
import core/register
import core/tx
import events/bus
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import machine/acceptance
import machine/codec as machine_codec
import machine/operation
import machine/planner
import machine/queue
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import runtime/escalation as runtime_escalation
import runtime/hooks
import runtime/internal/ffi_sup
import runtime/writer
import session/session
import storage/storage
import tools/tool.{type Registry}

/// A running gateway hub, addressed by name so the provider tap and the
/// commit forwarder can reach it before it starts.
pub type Gateway {
  Gateway(name: Name(Message))
}

/// Hub configuration.
///
/// Constructor invariants: `session_id` is the name clients subscribe
/// with; `runtime` is an open session runtime whose writer was given the
/// `commit_forwarder` subject (so commit hints reach the hub);
/// `recent_entries` bounds the full snapshot's entry window; `bus`, when
/// present, adds events-bus publications as extra pull hints; `catalog`,
/// when present, backs the `models` command and `set_config`'s
/// `model_name` key (without one the listing is empty and name switches
/// are refused in-band); `registry` is the same tool registry the
/// effect wiring dispatches through, and backs `set_config`'s
/// `active_tools` key (without one, changes to the active set are
/// refused in-band — the hub will not write a tool name it cannot
/// check).
pub type Options {
  Options(
    session_id: String,
    runtime: api.Runtime,
    recent_entries: Int,
    /// An extra hint source. `None` is the production answer and
    /// `client/serve` supplies none: a one-session server's writer sits
    /// in the same VM as its hub, so `commit_forwarder` already carries
    /// every commit's hint, and a bus subscription would only make the
    /// same pull happen twice. The field stays for the host the bus was
    /// designed for — one whose hint sources are *not* all its own
    /// writer (a projection, a second node's session, telemetry) — and
    /// `events/bus.bridge` is the seam that feeds it.
    bus: Option(bus.Bus),
    catalog: Option(catalog.Catalog),
    registry: Option(Registry),
  )
}

/// Sensible defaults: a 50-entry snapshot window, no bus, no catalogue,
/// no tool registry.
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime)
/// ```
///
pub fn default_options(session_id: String, runtime: api.Runtime) -> Options {
  Options(
    session_id:,
    runtime:,
    recent_entries: 50,
    bus: None,
    catalog: None,
    registry: None,
  )
}

/// Supplies the model catalogue the hub serves and switches by name.
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime)
/// // |> gateway.with_catalog(catalogue)
/// ```
///
pub fn with_catalog(options: Options, catalog: catalog.Catalog) -> Options {
  Options(..options, catalog: Some(catalog))
}

/// Supplies the tool registry `set_config`'s `active_tools` validates
/// against. Pass the very registry the effect wiring was built with:
/// the durable active list is meaningless against any other one.
///
/// ## Examples
///
/// ```gleam
/// // gateway.default_options("sess-01", runtime)
/// // |> gateway.with_registry(the_registry_the_effect_wiring_holds)
/// ```
///
pub fn with_registry(options: Options, registry: Registry) -> Options {
  Options(..options, registry: Some(registry))
}

/// Messages understood by the hub. Opaque in spirit: callers use the
/// wrapper functions below (the constructors are exported only through
/// them).
pub opaque type Message {
  Attach(sink: fn(String) -> Nil, reply: Subject(Int))
  Attached(reply: Subject(Int))
  Detach(connection: Int)
  FromClient(connection: Int, text: String)
  CommitHint
  BusHint(published: bus.Published)
  ProviderDelta(operation: OpId, delta: stream.Delta)
}

type Connection {
  Connection(sink: fn(String) -> Nil, subscribed: Bool)
}

type State {
  State(
    session_id: String,
    runtime: api.Runtime,
    recent_entries: Int,
    connections: Dict(Int, Connection),
    next_connection: Int,
    high_water: Int,
    // strand → open operation id (as text), for terminal detection.
    live: Dict(String, String),
    // entry id (text) → strand attribution cache.
    entry_strand: Dict(String, String),
    // The model catalogue, when the host configured one.
    catalog: Option(catalog.Catalog),
    // The tool registry, when the host configured one.
    registry: Option(Registry),
  )
}

// One materialized durable event: its storage seq plus the wire event.
type Emit {
  Emit(seq: Int, event: WireEvent)
}

/// Starts the hub registered under `name`. The initial high-water is the
/// store's current tail, so a fresh gateway (or a restarted one) never
/// re-broadcasts history on its first hint — reconnecting clients pull
/// history explicitly with `catch_up`.
///
/// ## Examples
///
/// ```gleam
/// // gateway.start(gateway.default_options("sess-01", runtime), name)
/// ```
///
pub fn start(
  options: Options,
  name: Name(Message),
) -> actor.StartResult(Gateway) {
  actor.new_with_initialiser(5000, fn(subject) {
    let selector = case options.bus {
      Some(bus) -> {
        // Keyed by the session's *canonical* id, never by the
        // caller-supplied display name. The two key spaces are disjoint
        // by construction (`protocol-change/008`), so a hub keyed by
        // name would sit in a group no identified publisher ever
        // reaches — and the index is repository-wide, which is exactly
        // where a file-derived name collides with nothing to notice it.
        // `Options.session_id` stays the protocol's `session` field: a
        // display name, and only that.
        //
        // `client/serve` supplies no bus, so nothing exercises this
        // today; it is correct for the host the field exists for — one
        // whose hint sources are not all its own writer.
        bus.subscribe_all(
          bus,
          session: bus.key(of: api.session_id(options.runtime)),
        )
        process.new_selector()
        |> process.select(subject)
        |> bus.select_published(BusHint)
      }
      None ->
        process.new_selector()
        |> process.select(subject)
    }
    let state =
      State(
        session_id: options.session_id,
        runtime: options.runtime,
        recent_entries: options.recent_entries,
        connections: dict.new(),
        next_connection: 1,
        high_water: 0,
        live: dict.new(),
        entry_strand: dict.new(),
        catalog: options.catalog,
        registry: options.registry,
      )

    // Prime: advance past everything already in the store, and learn
    // the live operations so the next pull sees changes, not history.
    let #(state, _emits) = pull(state)
    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(Gateway(name:))
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// Registers a connection sink and returns its connection id. The sink
/// is called from the hub process with each encoded frame; it must not
/// block (send to the transport process, do not write sockets inline).
///
/// ## Examples
///
/// ```gleam
/// // gateway.attach(gateway, fn(frame) { process.send(out, frame) })
/// ```
///
pub fn attach(gateway: Gateway, sink: fn(String) -> Nil) -> Int {
  process.call(
    process.named_subject(gateway.name),
    waiting: 5000,
    sending: Attach(sink, _),
  )
}

/// How many connections are attached right now.
///
/// The honest answer to "is a human there?", which is what an escalation
/// seam needs before it holds a tool call open for a decision: a session
/// nobody is watching must record a refusal and settle it, not park on a
/// prompt that will never be answered. It is a question rather than a
/// flag so a client that disconnects mid-park is noticed at the next
/// poll.
///
/// A hub that is gone answers zero — a server without a gateway is by
/// definition not being watched — and so does a hub that does not answer
/// in a second, or that dies while being asked. That is a deliberate
/// degradation rather than a lost error: the only caller is an escalation
/// seam polling once a second from a *parked tool call's* effect process,
/// and `process.call` exits its caller on timeout rather than returning
/// one, so a hub busy behind a long pull would kill the very call it is
/// being asked about. "Nobody answered, so assume nobody is there"
/// un-parks the call and settles it in band, which is exactly what the
/// seam's doc promises happens when a client goes away.
///
/// ## Examples
///
/// ```gleam
/// // gateway.attached(gateway) == 0
/// ```
///
pub fn attached(gateway: Gateway) -> Int {
  case process.named(gateway.name) {
    Error(Nil) -> 0
    Ok(owner) -> {
      let monitor = process.monitor(owner)
      let reply_to = process.new_subject()

      // The monitored PID is the incarnation this question belongs to. Sending
      // through the name would resolve it again and could crash or ask a
      // replacement which the monitor does not describe.
      ffi_sup.send_to_pid(owner, #(gateway.name, Attached(reply: reply_to)))
      let answer =
        process.new_selector()
        |> process.select(reply_to)
        |> process.select_specific_monitor(monitor, fn(_down) { 0 })
        |> process.selector_receive(within: 1000)
      process.demonitor_process(monitor)
      result.unwrap(answer, 0)
    }
  }
}

/// Removes a connection; a no-op for unknown ids.
///
/// ## Examples
///
/// ```gleam
/// // gateway.detach(gateway, connection)
/// ```
///
pub fn detach(gateway: Gateway, connection: Int) -> Nil {
  send_if_alive(gateway.name, Detach(connection))
}

/// Feeds one inbound text frame from a connection into the hub.
///
/// ## Examples
///
/// ```gleam
/// // gateway.handle_text(gateway, connection, "{\"v\":1,...}")
/// ```
///
pub fn handle_text(gateway: Gateway, connection: Int, text: String) -> Nil {
  send_if_alive(gateway.name, FromClient(connection, text))
}

/// Starts a forwarder that turns the runtime writer's post-commit
/// publication into hub pull hints, registered under `as_name`.
///
/// Subscribe the writer to `process.named_subject(as_name)` rather than
/// to the returned subject: the forwarder holds no state worth keeping,
/// so it is the one piece of the composition layer that can simply be
/// restarted, and a subscription made by *name* survives that restart
/// while one made to a pid does not. The writer skips a subscriber whose
/// name is momentarily unregistered, so the restart window costs hints,
/// never the commit path.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(_started) = gateway.commit_forwarder(to: name, as_name: forwarder)
/// // api.Options(..options, subscribers: [process.named_subject(forwarder)])
/// ```
///
pub fn commit_forwarder(
  to name: Name(Message),
  as_name as_name: Name(writer.Event),
) -> actor.StartResult(Subject(writer.Event)) {
  actor.new(Nil)
  |> actor.on_message(fn(_state, _event: writer.Event) {
    send_if_alive(name, CommitHint)
    actor.continue(Nil)
  })
  |> actor.named(as_name)
  |> actor.start
}

/// The commit forwarder as a supervision child, so a crash restarts it
/// under the same name instead of ending the server.
///
/// ## Examples
///
/// ```gleam
/// // sup.add(builder, gateway.supervised_commit_forwarder(to: name, as_name: forwarder))
/// ```
///
pub fn supervised_commit_forwarder(
  to name: Name(Message),
  as_name as_name: Name(writer.Event),
) -> ChildSpecification(Subject(writer.Event)) {
  supervision.worker(fn() { commit_forwarder(to: name, as_name:) })
}

/// Wraps a provider surface so every streamed delta is teed to the hub
/// as an ephemeral `stream_delta` broadcast while the runtime's effect
/// process consumes the stream unchanged (same events, same terminal,
/// same timeout discipline). The shared relay forwards explicit
/// cancellation and consumer death to the inner stream.
///
/// ## Examples
///
/// ```gleam
/// // effects.Effects(..effects,
/// //   provider: gateway.tap_provider(effects.provider, to: name))
/// ```
///
pub fn tap_provider(
  surface: effects.ProviderSurface,
  to name: Name(Message),
) -> effects.ProviderSurface {
  effects.PreparedProviderSurface(
    timeout_ms: effects.provider_timeout_ms(surface),
    request: fn(spec) {
      provider_relay.wrap(surface, spec, observe_provider(name, spec))
    },
    prepare: fn(spec) {
      provider_relay.prepare(surface, spec, observe_provider(name, spec))
    },
  )
}

// Constructing the callback from the durable operation id in one place keeps
// the immediate facade and the prepared production path observationally
// identical.
fn observe_provider(
  name: Name(Message),
  spec: effects.RequestSpec,
) -> fn(stream.StreamEvent) -> Nil {
  let operation = case spec {
    effects.GenerationRequest(operation:, ..) -> operation
    effects.PollRequest(operation:, ..) -> operation
    effects.SummaryRequest(operation:, ..) -> operation
  }
  fn(event) {
    case event {
      stream.Delta(delta:) ->
        send_if_alive(name, ProviderDelta(operation:, delta:))
      stream.Settled(..) | stream.Failed(..) -> Nil
    }
  }
}

// Resolve the hub name once, then send the tagged envelope straight to that
// PID. A second name lookup would leave an unregistration race which turns a
// lost stream hint into an observer crash and provider cancellation.
fn send_if_alive(name: Name(Message), message: Message) -> Nil {
  case process.named(name) {
    Ok(pid) -> ffi_sup.send_to_pid(pid, #(name, message))
    Error(Nil) -> Nil
  }
}

// --- the hub loop ----------------------------------------------------------

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Attach(sink:, reply:) -> {
      let id = state.next_connection
      process.send(reply, id)
      actor.continue(
        State(
          ..state,
          connections: dict.insert(
            state.connections,
            id,
            Connection(sink:, subscribed: False),
          ),
          next_connection: id + 1,
        ),
      )
    }
    Attached(reply:) -> {
      process.send(reply, dict.size(state.connections))
      actor.continue(state)
    }
    Detach(connection:) ->
      actor.continue(
        State(..state, connections: dict.delete(state.connections, connection)),
      )
    FromClient(connection:, text:) ->
      actor.continue(dispatch(state, connection, text))
    CommitHint -> actor.continue(pull_and_broadcast(state))
    BusHint(published: _) -> actor.continue(pull_and_broadcast(state))
    ProviderDelta(operation:, delta:) -> {
      broadcast_delta(state, operation, delta)
      actor.continue(state)
    }
  }
}

// --- materializing the durable stream --------------------------------------

fn pull_and_broadcast(state: State) -> State {
  let #(state, emits) = pull(state)
  broadcast(state, emits)
  state
}

// Reads everything above the high-water from storage and returns it as
// seq-ordered emits, advancing the high-water. Read-only; never
// commits.
fn pull(state: State) -> #(State, List(Emit)) {
  let hw = state.high_water
  let strands = strand_names(state)

  // 1. New entries reachable from each strand's leaf, plus a
  //    completeness pass for entries no leaf covers (e.g. a branch
  //    summary left behind by a navigation).
  let #(entry_strand, entry_emits) =
    new_entries(state, strands, hw, state.entry_strand)

  // 2. New usage-ledger rows.
  let usage_emits = new_usage(state, entry_strand, hw)

  // 3. Operation transitions and terminal results from the strand
  //    registers.
  let #(live, register_emits) = register_events(state, strands, hw)

  // 4. Escalation records.
  let escalation_emits = escalation_events(state, hw)
  let emits =
    [entry_emits, usage_emits, register_emits, escalation_emits]
    |> list.flatten
    |> list.filter(fn(emit) { emit.seq > hw })
    |> list.sort(fn(a, b) { int.compare(a.seq, b.seq) })
    |> dedupe_by_seq

  // The high-water advances only to the greatest seq actually emitted.
  // Register writes that produce no event (leaf moves, queue
  // bookkeeping) may sit above it — harmless, because every event
  // source is gated on its own cell/row seq exceeding the high-water,
  // so nothing re-emits and nothing is skipped. Advancing further
  // (e.g. to a register tail read *after* the scans) would race a
  // commit landing between the reads and silently drop its events.
  let high_water =
    list.fold(emits, hw, fn(highest, emit) { int.max(highest, emit.seq) })
  #(State(..state, high_water:, live:, entry_strand:), emits)
}

fn dedupe_by_seq(emits: List(Emit)) -> List(Emit) {
  emits
  |> list.fold(#([], -1), fn(accumulator, emit) {
    let #(kept, last) = accumulator
    case emit.seq == last {
      True -> #(kept, last)
      False -> #([emit, ..kept], emit.seq)
    }
  })
  |> fn(accumulator) { list.reverse(accumulator.0) }
}

fn strand_names(state: State) -> List(String) {
  case
    storage.list_registers(
      state.runtime.session.store,
      register.StrandConfig,
      None,
    )
  {
    Ok(cells) ->
      cells
      |> list.map(fn(cell) { cell.0 })
      |> list.sort(string.compare)
    Error(_) -> []
  }
}

fn new_entries(
  state: State,
  strands: List(String),
  hw: Int,
  cache: Dict(String, String),
) -> #(Dict(String, String), List(Emit)) {
  let store = state.runtime.session

  // Per-strand branch scans above the high-water attribute entries to
  // the strand whose branch they extend.
  let #(cache, claimed) =
    list.fold(strands, #(cache, []), fn(accumulator, strand) {
      claim_branch(store, strand, hw, accumulator)
    })

  // Completeness pass: whatever the leaves missed, attributed through
  // the parent chain (fallback: the first strand).
  let fallback = case strands {
    [first, ..] -> first
    [] -> "main"
  }
  case
    storage.scan_entries(
      store.store,
      storage.entry_scan()
        |> storage.entry_seq_range(Some(hw + 1), None),
    )
  {
    Error(_) -> #(cache, claimed)
    Ok(rows) ->
      list.fold(rows, #(cache, claimed), fn(accumulator, row) {
        claim_by_parent(accumulator, row, fallback)
      })
  }
}

// One strand's branch scan above the high-water, folded into the
// running cache/emits pair. A strand with no leaf, or a leaf whose scan
// fails, contributes nothing.
fn claim_branch(
  store: session.Session,
  strand: String,
  hw: Int,
  accumulator: #(Dict(String, String), List(Emit)),
) -> #(Dict(String, String), List(Emit)) {
  case session.strand_leaf(store, strand) {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      case
        storage.scan_branch(
          store.store,
          storage.branch_scan(from: leaf)
            |> storage.branch_order(storage.OldestFirst)
            |> storage.branch_cursor(hw),
        )
      {
        Ok(rows) ->
          list.fold(rows, accumulator, fn(accumulator, row) {
            claim_row(accumulator, strand, row)
          })
        Error(_) -> accumulator
      }
    _ -> accumulator
  }
}

// Claims one row for `strand` unless the cache already has it (a row
// another strand's branch already attributed).
fn claim_row(
  accumulator: #(Dict(String, String), List(Emit)),
  strand: String,
  row: Entry,
) -> #(Dict(String, String), List(Emit)) {
  let #(cache, emits) = accumulator
  let id = ids.entry_id_to_string(entry_id_of(row))
  case dict.has_key(cache, id) {
    True -> #(cache, emits)
    False -> #(dict.insert(cache, id, strand), [
      entry_emit(strand, row),
      ..emits
    ])
  }
}

// Claims one row the branch scans missed, by walking its parent's
// attribution (or the fallback strand when the parent is unattributed
// too).
fn claim_by_parent(
  accumulator: #(Dict(String, String), List(Emit)),
  row: Entry,
  fallback: String,
) -> #(Dict(String, String), List(Emit)) {
  let #(cache, emits) = accumulator
  let id = ids.entry_id_to_string(entry_id_of(row))
  case dict.has_key(cache, id) {
    True -> #(cache, emits)
    False -> {
      let strand = case entry_parent_of(row) {
        Some(parent) ->
          case dict.get(cache, ids.entry_id_to_string(parent)) {
            Ok(strand) -> strand
            Error(Nil) -> fallback
          }
        None -> fallback
      }
      #(dict.insert(cache, id, strand), [entry_emit(strand, row), ..emits])
    }
  }
}

fn entry_emit(strand: String, row: Entry) -> Emit {
  Emit(
    seq: entry_seq_of(row),
    event: protocol.EntryEvent(record: EntryRecord(strand:, entry: row)),
  )
}

fn new_usage(
  state: State,
  entry_strand: Dict(String, String),
  hw: Int,
) -> List(Emit) {
  let store = state.runtime.session.store
  case
    storage.scan_usage(
      store,
      storage.usage_scan()
        |> storage.usage_seq_range(Some(hw + 1), None),
    )
  {
    Error(_) -> []
    Ok(rows) ->
      list.map(rows, fn(row: UsageRow) {
        let strand = case row.entry_id {
          Some(id) ->
            case dict.get(entry_strand, ids.entry_id_to_string(id)) {
              Ok(strand) -> strand
              Error(Nil) -> single_live_strand(state)
            }
          None -> single_live_strand(state)
        }
        let op = case dict.get(state.live, strand) {
          Ok(op) -> Some(op)
          Error(Nil) -> None
        }
        Emit(
          seq: row.seq,
          event: protocol.UsageEvent(strand:, op:, usage: row.usage),
        )
      })
  }
}

// The strand best positioned to own an unattributable record: the one
// with a live operation when exactly one has one, else the first.
fn single_live_strand(state: State) -> String {
  case dict.to_list(state.live) {
    [#(strand, _)] -> strand
    _ ->
      case strand_names(state) {
        [first, ..] -> first
        [] -> "main"
      }
  }
}

fn register_events(
  state: State,
  strands: List(String),
  hw: Int,
) -> #(Dict(String, String), List(Emit)) {
  let store = state.runtime.session
  list.fold(strands, #(state.live, []), fn(accumulator, strand) {
    let #(live, emits) = accumulator
    let #(current, state_seq) = current_operation(store, strand)
    let emits =
      terminal_result_emits(store, strand, current, state_seq, hw, emits)
    open_operation_phase(store, strand, current, live, emits, hw)
  })
}

fn current_operation(
  store: session.Session,
  strand: String,
) -> #(Option(String), Int) {
  case session.strand_state(store, strand) {
    Ok(Some(session.Cell(value:, seq:))) -> #(
      option.map(value.current_operation, ids.op_id_to_string),
      seq,
    )
    _ -> #(None, 0)
  }
}

// A terminal result that landed since the last pull. Keyed on the
// `strand.last_result` register's own seq — never on the live-op diff,
// because a fast operation can open and settle entirely between two
// pulls.
fn terminal_result_emits(
  store: session.Session,
  strand: String,
  current: Option(String),
  state_seq: Int,
  hw: Int,
  emits: List(Emit),
) -> List(Emit) {
  case session.last_result(store, strand) {
    Ok(Some(session.Cell(value:, seq:))) if seq > hw -> {
      let #(op, status, error) = result_view(value)

      // The state register clearing the operation is the `done` display
      // transition (only while no successor operation has already
      // claimed the register).
      let emits = case current, state_seq > hw {
        None, True -> [
          Emit(
            seq: state_seq,
            event: protocol.OpTransitionEvent(op:, strand:, phase: "done"),
          ),
          ..emits
        ]
        _, _ -> emits
      }
      [
        Emit(
          seq:,
          event: protocol.StrandResultEvent(strand:, op:, status:, error:),
        ),
        ..emits
      ]
    }
    _ -> emits
  }
}

// The open operation's current phase.
fn open_operation_phase(
  store: session.Session,
  strand: String,
  current: Option(String),
  live: Dict(String, String),
  emits: List(Emit),
  hw: Int,
) -> #(Dict(String, String), List(Emit)) {
  case current {
    None -> #(dict.delete(live, strand), emits)
    Some(op_text) -> {
      let live = dict.insert(live, strand, op_text)
      case ids.parse_op_id(op_text) {
        Error(_) -> #(live, emits)
        Ok(op_id) ->
          case session.op_state(store, op_id) {
            Ok(Some(session.Cell(value:, seq:))) if seq > hw -> #(live, [
              Emit(
                seq:,
                event: protocol.OpTransitionEvent(
                  op: op_text,
                  strand:,
                  phase: phase_of(value),
                ),
              ),
              ..emits
            ])
            _ -> #(live, emits)
          }
      }
    }
  }
}

fn escalation_events(state: State, hw: Int) -> List(Emit) {
  let store = state.runtime.session.store
  case
    storage.list_registers(
      store,
      register.FactCustom,
      Some(runtime_escalation.key_prefix),
    )
  {
    Error(_) -> []
    Ok(cells) ->
      list.filter_map(cells, fn(cell) {
        let #(_key, storage.Register(value:, seq:)) = cell
        case seq > hw {
          False -> Error(Nil)
          True ->
            case runtime_escalation.decode(value.payload) {
              Error(_) -> Error(Nil)
              Ok(record) -> Ok(Emit(seq:, event: escalation_event(record)))
            }
        }
      })
  }
}

fn escalation_event(record: runtime_escalation.Escalation) -> WireEvent {
  protocol.EscalationEvent(record: escalation_view(record))
}

// One durable record as the protocol carries it — the single place the
// two shapes are bridged, so an event, a snapshot row, and the record a
// refused approval hands back can never disagree about the same record.
//
// The denial rides only on a pending record: on any other status there
// is nothing left to decide, and a client that showed the diff again
// would be inviting an answer to a closed question.
fn escalation_view(
  record: runtime_escalation.Escalation,
) -> protocol.EscalationRecord {
  let #(op, strand) = escalation_attribution(record)
  protocol.EscalationRecord(
    escalation_id: record.id,
    op:,
    strand:,
    status: escalation_status(record.status),
    tool: option.unwrap(record.tool, ""),
    action: option.unwrap(record.action, ""),
    preview: option.unwrap(record.preview, ""),
    asked: record.asked,
    denial: case record.status {
      runtime_escalation.Pending -> denial_view(record.denial)
      runtime_escalation.Approved
      | runtime_escalation.Rejected
      | runtime_escalation.Consumed -> None
    },
  )
}

// The operation and strand a record names, off its own `CallScope`.
//
// This used to guess from the hub's live map, which returned whichever
// single operation was open for *every* record and two empty strings
// otherwise — so in a two-strand session a refusal raised on `sub:1`
// was presented as `main`'s (#67). The scope has been on the record
// since it started carrying one, and a record that names no call is
// the only thing that answers empty now.
fn escalation_attribution(
  record: runtime_escalation.Escalation,
) -> #(String, String) {
  case record.scope {
    None -> #("", "")
    Some(scope) -> #(ids.op_id_to_string(scope.operation), scope.strand)
  }
}

fn escalation_status(status: runtime_escalation.Status) -> String {
  case status {
    runtime_escalation.Pending -> "pending"
    runtime_escalation.Approved -> "approved"
    runtime_escalation.Rejected -> "rejected"
    runtime_escalation.Consumed -> "consumed"
  }
}

fn denial_view(denial: JsonValue) -> Option(protocol.Denial) {
  case grants.decode_denial(denial) {
    Error(_) -> None
    Ok(decoded) ->
      Some(protocol.Denial(
        reason: decoded.reason,
        source: case decoded.source {
          broker_escalation.PolicyDenial -> "policy"
          broker_escalation.ExecutionDenial(enforcement: _) -> "execution"
        },
        enforcement: None,
        wanted: decoded.wanted,
      ))
  }
}

// --- entry field access ----------------------------------------------------

fn entry_id_of(row: Entry) -> EntryId {
  case row {
    entry.MessageEntry(id:, ..) -> id
    entry.CompactionEntry(id:, ..) -> id
    entry.BranchSummaryEntry(id:, ..) -> id
    entry.CustomEntry(id:, ..) -> id
  }
}

fn entry_seq_of(row: Entry) -> Int {
  case row {
    entry.MessageEntry(seq:, ..) -> seq
    entry.CompactionEntry(seq:, ..) -> seq
    entry.BranchSummaryEntry(seq:, ..) -> seq
    entry.CustomEntry(seq:, ..) -> seq
  }
}

fn entry_parent_of(row: Entry) -> Option(EntryId) {
  case row {
    entry.MessageEntry(parent:, ..) -> parent
    entry.CompactionEntry(parent:, ..) -> parent
    entry.BranchSummaryEntry(parent:, ..) -> parent
    entry.CustomEntry(parent:, ..) -> parent
  }
}

// --- display views of machine state ----------------------------------------

// The display phase label of an operation state (protocol.md's open
// label set; `op.state` stays the truth).
fn phase_of(state: operation.OperationState) -> String {
  case state {
    operation.RunState(control:, phase:, ..) ->
      case control, phase {
        operation.CancelRequested(..), _ -> "cancel_requested"
        operation.Running, operation.Starting -> "starting"
        operation.Running, operation.Checkpoint(..) -> "checkpoint"
        operation.Running, operation.Assistant(..) -> "assistant"
        operation.Running, operation.Tools(..) -> "tools"
        operation.Running, operation.Compacting(..) -> "compacting"
        operation.Running, operation.AwaitingDeferred(..) -> "awaiting_deferred"
        operation.Running, operation.FailureDrain(..) -> "failure_drain"
      }
    operation.CompactionState(control:, ..) ->
      case control {
        operation.CancelRequested(..) -> "cancel_requested"
        operation.Running -> "compacting"
      }
    operation.NavigationState(control:, ..) ->
      case control {
        operation.CancelRequested(..) -> "cancel_requested"
        operation.Running -> "navigating"
      }
  }
}

// The strand_result view of a terminal result: operation id text,
// status, and the error for failures.
fn result_view(
  last: operation.LastResult,
) -> #(String, String, Option(protocol.ResultError)) {
  case last {
    operation.RunLastResult(operation: op, outcome:, ..) -> {
      let op = ids.op_id_to_string(op)
      case outcome {
        operation.RunCompleted(..) -> #(op, "done", None)
        operation.RunAborted -> #(op, "aborted", None)
        operation.RunFailed(error:) -> #(
          op,
          "failed",
          Some(protocol.ResultError(code: error.code, message: error.message)),
        )
      }
    }
    operation.CompactionLastResult(operation: op, outcome:, ..) ->
      structural_view(op, outcome)
    operation.NavigationLastResult(operation: op, outcome:, ..) ->
      structural_view(op, outcome)
  }
}

fn structural_view(
  op: OpId,
  outcome: operation.StructuralOutcome,
) -> #(String, String, Option(protocol.ResultError)) {
  let op = ids.op_id_to_string(op)
  case outcome {
    operation.StructuralCompleted -> #(op, "done", None)
    operation.StructuralDeclined -> #(op, "done", None)
    operation.StructuralAborted -> #(op, "aborted", None)
    operation.StructuralFailed(error:) -> #(
      op,
      "failed",
      Some(protocol.ResultError(code: error.code, message: error.message)),
    )
  }
}

// --- sending ---------------------------------------------------------------

// Broadcasts durable emits to every subscribed connection.
fn broadcast(state: State, emits: List(Emit)) -> Nil {
  broadcast_except(state, emits, -1, None)
}

// Sends one event to one connection.
fn send_to(state: State, connection: Int, envelope: EventEnvelope) -> Nil {
  case dict.get(state.connections, connection) {
    Ok(link) -> link.sink(protocol.encode_event(envelope))
    Error(Nil) -> Nil
  }
}

fn reply(state: State, connection: Int, id: Int, event: WireEvent) -> Nil {
  send_to(
    state,
    connection,
    EventEnvelope(reply_to: Some(id), seq: None, event:),
  )
}

fn reply_error(
  state: State,
  connection: Int,
  id: Int,
  code: String,
  message: String,
) -> Nil {
  reply(
    state,
    connection,
    id,
    protocol.ErrorEvent(code:, message:, details: None),
  )
}

fn broadcast_delta(state: State, operation: OpId, delta: stream.Delta) -> Nil {
  let op_text = ids.op_id_to_string(operation)
  let strand = case
    dict.to_list(state.live)
    |> list.find(fn(pair) { pair.1 == op_text })
  {
    Ok(#(strand, _)) -> strand
    Error(Nil) ->
      case session.op_meta(state.runtime.session, operation) {
        Ok(Some(session.Cell(value:, ..))) -> value.strand
        _ -> single_live_strand(state)
      }
  }
  let event = case delta {
    stream.TextDelta(index: _, text:) ->
      protocol.StreamDeltaEvent(
        strand:,
        op: op_text,
        kind: protocol.TextKind,
        text: Some(text),
        call_id: None,
        tool_name: None,
        arguments_fragment: None,
      )
    stream.ThinkingDelta(index: _, thinking:) ->
      protocol.StreamDeltaEvent(
        strand:,
        op: op_text,
        kind: protocol.ThinkingKind,
        text: Some(thinking),
        call_id: None,
        tool_name: None,
        arguments_fragment: None,
      )
    stream.ToolCallDelta(index: _, call_id:, name:, arguments_json:) ->
      protocol.StreamDeltaEvent(
        strand:,
        op: op_text,
        kind: protocol.ToolCallKind,
        text: None,
        call_id: Some(call_id),
        tool_name: Some(name),
        arguments_fragment: Some(arguments_json),
      )
  }
  let frame =
    protocol.encode_event(EventEnvelope(reply_to: None, seq: None, event:))
  dict.each(state.connections, fn(_id, link: Connection) {
    case link.subscribed {
      True -> link.sink(frame)
      False -> Nil
    }
  })
}

// --- command dispatch ------------------------------------------------------

// The hub's own error-channel combinator: run `then` on success, or send
// `id` an error frame built from the `(code, message)` failure and leave
// `state` unchanged. Mirrors `machine/planner`'s `or_fault` and
// `tools/tool`'s `or_outcome` — the shape a command handler's error arm
// always was (`reply_error` then return `state`), pulled out so a chain
// of fallible steps reads as a chain rather than a staircase.
//
// ## Examples
//
// ```gleam
// // use record <- or_reply(find_escalation(state, id), state, connection, id)
// ```
//
fn or_reply(
  result: Result(a, #(String, String)),
  state: State,
  connection: Int,
  id: Int,
  then: fn(a) -> State,
) -> State {
  case result {
    Ok(value) -> then(value)
    Error(#(code, message)) -> {
      reply_error(state, connection, id, code, message)
      state
    }
  }
}

fn dispatch(state: State, connection: Int, text: String) -> State {
  case protocol.decode_command(text) {
    Error(protocol.MalformedFrame(report:)) -> {
      send_to(
        state,
        connection,
        EventEnvelope(
          reply_to: None,
          seq: None,
          event: protocol.ErrorEvent(
            code: protocol.code_bad_request,
            message: "malformed frame: expected " <> report.expected,
            details: None,
          ),
        ),
      )
      state
    }
    Error(protocol.BadEnvelope(reason:, id:)) -> {
      send_to(
        state,
        connection,
        EventEnvelope(
          reply_to: id,
          seq: None,
          event: protocol.ErrorEvent(
            code: protocol.code_bad_request,
            message: "bad envelope: expected " <> reason,
            details: None,
          ),
        ),
      )
      state
    }
    Error(protocol.BadBody(id:, cmd:, reason:)) -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_bad_request,
        cmd <> ": " <> reason,
      )
      state
    }
    Ok(protocol.CommandEnvelope(id:, command:)) ->
      run_command(state, connection, id, command)
  }
}

fn run_command(
  state: State,
  connection: Int,
  id: Int,
  command: Command,
) -> State {
  let subscribed = case dict.get(state.connections, connection) {
    Ok(Connection(subscribed:, ..)) -> subscribed
    Error(Nil) -> False
  }
  case command, subscribed {
    protocol.UnknownCommand(cmd:, ..), _ -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_unsupported,
        "unknown command: " <> cmd,
      )
      state
    }
    protocol.Subscribe(session:, from_seq:), False ->
      subscribe(state, connection, id, session, from_seq)
    protocol.Subscribe(..), True -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_conflict,
        "this connection is already subscribed",
      )
      state
    }
    _, False -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_bad_request,
        "subscribe before sending commands",
      )
      state
    }
    protocol.CatchUp(from_seq:), True -> {
      let state = pull_and_broadcast(state)
      replay(state, connection, id, from_seq)
      state
    }
    protocol.Prompt(strand:, text:), True ->
      prompt(state, connection, id, strand, text)
    protocol.PromptContent(strand:, content:), True ->
      prompt_content(state, connection, id, strand, content)
    protocol.Steer(strand:, text:), True ->
      steer(state, connection, id, strand, text)
    protocol.FollowUp(strand:, text:), True ->
      follow_up(state, connection, id, strand, text)
    protocol.Abort(strand:), True -> abort(state, connection, id, strand)
    protocol.Approve(escalation_id:, grants:, action:), True ->
      approve(state, connection, id, escalation_id, grants, action)
    protocol.Deny(escalation_id:), True ->
      deny(state, connection, id, escalation_id)
    protocol.Fork(strand:, scope: _, name:), True ->
      fork(state, connection, id, strand, name)
    protocol.Navigate(strand:, to_entry:), True ->
      navigate(state, connection, id, strand, to_entry)
    protocol.Compact(strand:, instructions:), True ->
      compact(state, connection, id, strand, instructions)
    protocol.CreateStrand(name:), True ->
      create_strand(state, connection, id, name)
    protocol.ListModels, True -> list_models(state, connection, id)
    protocol.SetConfig(strand:, config:), True ->
      set_config(state, connection, id, strand, config)
  }
}

// --- subscribe, snapshots, replay ------------------------------------------

fn subscribe(
  state: State,
  connection: Int,
  id: Int,
  session_name: String,
  from_seq: Option(Int),
) -> State {
  use <- bool.lazy_guard(when: session_name != state.session_id, return: fn() {
    reply_error(
      state,
      connection,
      id,
      protocol.code_unknown_session,
      "this gateway serves session " <> state.session_id,
    )
    state
  })
  let state = pull_and_broadcast(state)
  let state = mark_subscribed(state, connection)
  case from_seq {
    Some(from) if from > 0 && from <= state.high_water + 1 -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.ResumeSnapshot(
          next_seq: state.high_water + 1,
        )),
      )
      replay_events(state, connection, from)
      state
    }
    _ -> {
      reply(state, connection, id, full_snapshot(state))
      state
    }
  }
}

fn mark_subscribed(state: State, connection: Int) -> State {
  case dict.get(state.connections, connection) {
    Error(Nil) -> state
    Ok(link) ->
      State(
        ..state,
        connections: dict.insert(
          state.connections,
          connection,
          Connection(..link, subscribed: True),
        ),
      )
  }
}

// `catch_up` on a subscribed connection: resume marker plus replay
// (protocol.md open question 5: because event seqs are storage seqs,
// this same path pages arbitrarily far back through the transcript).
fn replay(state: State, connection: Int, id: Int, from_seq: Int) -> Nil {
  case from_seq > 0 && from_seq <= state.high_water + 1 {
    True -> {
      reply(
        state,
        connection,
        id,
        protocol.SnapshotEvent(protocol.ResumeSnapshot(
          next_seq: state.high_water + 1,
        )),
      )
      replay_events(state, connection, from_seq)
    }
    False -> reply(state, connection, id, full_snapshot(state))
  }
}

// Rebuilds the durable events with `from_seq <= seq <= high_water` from
// storage scans and current registers, and sends them in seq order.
fn replay_events(state: State, connection: Int, from_seq: Int) -> Nil {
  let store = state.runtime.session
  let strands = strand_names(state)
  let range_top = state.high_water
  let entry_emits = replay_entry_emits(state, strands, from_seq, range_top)
  let usage_emits = replay_usage_emits(state, strands, from_seq, range_top)
  let register_emits =
    replay_register_emits(store, strands, from_seq, range_top)
  let escalation_emits = replay_escalation_emits(state, from_seq, range_top)
  [entry_emits, usage_emits, register_emits, escalation_emits]
  |> list.flatten
  |> list.sort(fn(a, b) { int.compare(a.seq, b.seq) })
  |> dedupe_by_seq
  |> list.each(fn(emit) {
    send_to(
      state,
      connection,
      EventEnvelope(reply_to: None, seq: Some(emit.seq), event: emit.event),
    )
  })
}

// Rebuilds entry events in `[from_seq, range_top]`, attributed from the
// cache when known, otherwise located by branch membership.
fn replay_entry_emits(
  state: State,
  strands: List(String),
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  case
    storage.scan_entries(
      state.runtime.session.store,
      storage.entry_scan()
        |> storage.entry_seq_range(Some(from_seq), Some(range_top)),
    )
  {
    Error(_) -> []
    Ok(rows) ->
      list.map(rows, fn(row) {
        let id_text = ids.entry_id_to_string(entry_id_of(row))
        let strand = case dict.get(state.entry_strand, id_text) {
          Ok(strand) -> strand
          Error(Nil) -> locate_entry(state, strands, entry_id_of(row))
        }
        entry_emit(strand, row)
      })
  }
}

fn replay_usage_emits(
  state: State,
  strands: List(String),
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  case
    storage.scan_usage(
      state.runtime.session.store,
      storage.usage_scan()
        |> storage.usage_seq_range(Some(from_seq), Some(range_top)),
    )
  {
    Error(_) -> []
    Ok(rows) -> list.map(rows, replay_usage_row(state, strands, _))
  }
}

fn replay_usage_row(
  state: State,
  strands: List(String),
  row: UsageRow,
) -> Emit {
  let strand = case row.entry_id {
    Some(entry_id) ->
      case dict.get(state.entry_strand, ids.entry_id_to_string(entry_id)) {
        Ok(strand) -> strand
        Error(Nil) -> locate_entry(state, strands, entry_id)
      }
    None -> single_live_strand(state)
  }
  Emit(
    seq: row.seq,
    event: protocol.UsageEvent(strand:, op: None, usage: row.usage),
  )
}

// Register-backed events replay as current state at current seq.
fn replay_register_emits(
  store: session.Session,
  strands: List(String),
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  list.flat_map(strands, fn(strand) {
    let op_emit = replay_op_transition(store, strand, from_seq, range_top)
    let result_emit = replay_strand_result(store, strand, from_seq, range_top)
    list.append(op_emit, result_emit)
  })
}

fn replay_op_transition(
  store: session.Session,
  strand: String,
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  case session.strand_state(store, strand) {
    Ok(Some(session.Cell(value:, ..))) ->
      case value.current_operation {
        Some(op) ->
          case session.op_state(store, op) {
            Ok(Some(session.Cell(value: op_state, seq:)))
              if seq >= from_seq && seq <= range_top
            -> [
              Emit(
                seq:,
                event: protocol.OpTransitionEvent(
                  op: ids.op_id_to_string(op),
                  strand:,
                  phase: phase_of(op_state),
                ),
              ),
            ]
            _ -> []
          }
        None -> []
      }
    _ -> []
  }
}

fn replay_strand_result(
  store: session.Session,
  strand: String,
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  case session.last_result(store, strand) {
    Ok(Some(session.Cell(value:, seq:)))
      if seq >= from_seq && seq <= range_top
    -> {
      let #(op, status, error) = result_view(value)
      [
        Emit(
          seq:,
          event: protocol.StrandResultEvent(strand:, op:, status:, error:),
        ),
      ]
    }
    _ -> []
  }
}

fn replay_escalation_emits(
  state: State,
  from_seq: Int,
  range_top: Int,
) -> List(Emit) {
  case
    storage.list_registers(
      state.runtime.session.store,
      register.FactCustom,
      Some(runtime_escalation.key_prefix),
    )
  {
    Error(_) -> []
    Ok(cells) ->
      list.filter_map(cells, fn(cell) {
        let #(_key, storage.Register(value:, seq:)) = cell
        case seq >= from_seq && seq <= range_top {
          False -> Error(Nil)
          True ->
            case runtime_escalation.decode(value.payload) {
              Error(_) -> Error(Nil)
              Ok(record) -> Ok(Emit(seq:, event: escalation_event(record)))
            }
        }
      })
  }
}

// Attributes an entry outside the cache by branch membership.
fn locate_entry(
  state: State,
  strands: List(String),
  entry_id: EntryId,
) -> String {
  let store = state.runtime.session
  case list.find(strands, entry_in_branch(store, _, entry_id)) {
    Ok(strand) -> strand
    Error(Nil) ->
      case strands {
        [first, ..] -> first
        [] -> "main"
      }
  }
}

// Whether `entry_id` sits on `strand`'s branch: its leaf's scan, stopped
// at that id, actually reached it.
fn entry_in_branch(
  store: session.Session,
  strand: String,
  entry_id: EntryId,
) -> Bool {
  case session.strand_leaf(store, strand) {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      case
        storage.scan_branch(
          store.store,
          storage.branch_scan(from: leaf)
            |> storage.branch_stop_at_id(entry_id)
            |> storage.branch_limit(1),
        )
      {
        Ok([row]) -> entry_id_of(row) == entry_id
        _ -> False
      }
    _ -> False
  }
}

fn full_snapshot(state: State) -> WireEvent {
  let store = state.runtime.session
  let strands = list.map(strand_names(state), strand_view(store, _))
  let entries = recent_entries(state)
  let escalations = pending_escalations(state)
  let usage = case storage.stats(store.store) {
    Ok(storage.SessionStats(usage:, ..)) -> usage
    Error(_) -> effects.zero_usage()
  }
  protocol.SnapshotEvent(protocol.FullSnapshot(
    session: state.session_id,
    next_seq: state.high_water + 1,
    strands:,
    entries:,
    escalations:,
    usage:,
  ))
}

// One strand's snapshot row: its leaf (as text) and its live operation,
// when it has either.
fn strand_view(store: session.Session, strand: String) -> protocol.Strand {
  let leaf = case session.strand_leaf(store, strand) {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      Some(ids.entry_id_to_string(leaf))
    _ -> None
  }
  let live_op = strand_live_op(store, strand)
  Strand(id: strand, name: Some(strand), leaf:, live_op:)
}

fn strand_live_op(
  store: session.Session,
  strand: String,
) -> Option(protocol.LiveOp) {
  case session.strand_state(store, strand) {
    Ok(Some(session.Cell(value:, ..))) ->
      case value.current_operation {
        Some(op) -> {
          let phase = case session.op_state(store, op) {
            Ok(Some(session.Cell(value: op_state, ..))) -> phase_of(op_state)
            _ -> "starting"
          }
          Some(LiveOp(op: ids.op_id_to_string(op), phase:))
        }
        None -> None
      }
    _ -> None
  }
}

fn recent_entries(state: State) -> List(EntryRecord) {
  let store = state.runtime.session.store
  case
    storage.scan_entries(
      store,
      storage.entry_scan()
        |> storage.entry_order(storage.NewestFirst)
        |> storage.entry_limit(state.recent_entries),
    )
  {
    Error(_) -> []
    Ok(rows) ->
      rows
      |> list.reverse
      |> list.map(fn(row) {
        let id_text = ids.entry_id_to_string(entry_id_of(row))
        let strand = case dict.get(state.entry_strand, id_text) {
          Ok(strand) -> strand
          Error(Nil) ->
            locate_entry(state, strand_names(state), entry_id_of(row))
        }
        EntryRecord(strand:, entry: row)
      })
  }
}

fn pending_escalations(state: State) -> List(protocol.EscalationRecord) {
  case api.escalations(state.runtime) {
    Error(_) -> []
    Ok(records) ->
      records
      |> list.filter(fn(record) { record.status == runtime_escalation.Pending })
      |> list.map(escalation_view)
  }
}

// --- the conversational commands -------------------------------------------

fn strand_exists(state: State, strand: String) -> Bool {
  case session.strand_configuration(state.runtime.session, strand) {
    Ok(Some(_)) -> True
    _ -> False
  }
}

fn user_message(state: State, text: String) -> AgentMessage {
  content_message(state, [message.UserText(text:, text_signature: None)])
}

fn content_message(state: State, content: List(UserBlock)) -> AgentMessage {
  let #(now, _clock) = clock.read(state.runtime.effects.clock)
  message.UserMessage(content:, timestamp: now)
}

fn prompt(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  text: String,
) -> State {
  prompt_message(state, connection, id, strand, user_message(state, text))
}

fn prompt_content(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  content: List(UserBlock),
) -> State {
  prompt_message(state, connection, id, strand, content_message(state, content))
}

fn prompt_message(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  prompt: AgentMessage,
) -> State {
  use <- known_strand(state, connection, id, strand)
  let target = api.on_strand(state.runtime, strand)
  use _op <- or_reply(
    result.map_error(api.prompt(target, [prompt]), describe_api_error(_, strand)),
    state,
    connection,
    id,
  )
  reply_with_matched(state, connection, id, fn(emit) {
    case emit.event {
      protocol.EntryEvent(record: EntryRecord(strand: on, entry:)) ->
        on == strand && is_user_entry(entry)
      _ -> False
    }
  })
}

fn is_user_entry(row: Entry) -> Bool {
  case row {
    entry.MessageEntry(message: message.UserMessage(..), ..) -> True
    _ -> False
  }
}

// Pulls, broadcasts, and replies with the *last* emit the matcher
// accepts (carrying its seq); replies `internal` if nothing matched.
fn reply_with_matched(
  state: State,
  connection: Int,
  id: Int,
  matcher: fn(Emit) -> Bool,
) -> State {
  let #(state, emits) = pull(state)
  let matched =
    list.fold(emits, None, fn(found, emit) {
      case matcher(emit) {
        True -> Some(emit)
        False -> found
      }
    })
  broadcast_except(state, emits, connection, matched)
  case matched {
    Some(emit) ->
      send_to(
        state,
        connection,
        EventEnvelope(
          reply_to: Some(id),
          seq: Some(emit.seq),
          event: emit.event,
        ),
      )
    None ->
      reply_error(
        state,
        connection,
        id,
        protocol.code_internal,
        "the command committed but its event was not materialized",
      )
  }
  state
}

// Broadcasts emits to all subscribed connections, except that the
// issuing connection's copy of the matched emit is suppressed (it
// arrives as the reply instead, with `reply_to` and the same seq).
fn broadcast_except(
  state: State,
  emits: List(Emit),
  connection: Int,
  matched: Option(Emit),
) -> Nil {
  list.each(emits, fn(emit) {
    let frame =
      protocol.encode_event(EventEnvelope(
        reply_to: None,
        seq: Some(emit.seq),
        event: emit.event,
      ))
    dict.each(state.connections, fn(link_id, link: Connection) {
      let suppressed = link_id == connection && Some(emit) == matched
      case link.subscribed && !suppressed {
        True -> link.sink(frame)
        False -> Nil
      }
    })
  })
}

fn known_strand(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  continue: fn() -> State,
) -> State {
  case strand_exists(state, strand) {
    True -> continue()
    False -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_unknown_strand,
        "unknown strand: " <> strand,
      )
      state
    }
  }
}

fn steer(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  text: String,
) -> State {
  use <- known_strand(state, connection, id, strand)
  let target = api.on_strand(state.runtime, strand)
  let message = user_message(state, text)
  use entry_id <- or_reply(
    result.map_error(api.steer(target, message), steer_error(_, strand)),
    state,
    connection,
    id,
  )
  reply(state, connection, id, queued_entry(strand, entry_id, message))
  pull_and_broadcast(state)
}

// `steer`'s error mapping: a strand with no live run gets a wording of
// its own (there is nothing to steer), everything else falls through to
// the shared `describe_api_error` table.
fn steer_error(error: api.ApiError, strand: String) -> #(String, String) {
  case error {
    api.QueueRejected(reason: queue.NoActiveRun) -> #(
      protocol.code_conflict,
      "strand " <> strand <> " has no live operation to steer",
    )
    _ -> describe_api_error(error, strand)
  }
}

// The ack for a queued (not yet placed) steer/follow-up item: the
// reserved entry id and the message, with no parent and no storage seq
// (the placed entry broadcasts later with both).
fn queued_entry(
  strand: String,
  entry_id: EntryId,
  message: AgentMessage,
) -> WireEvent {
  protocol.EntryEvent(record: EntryRecord(
    strand:,
    entry: entry.MessageEntry(
      id: entry_id,
      parent: None,
      seq: 0,
      ts: message_timestamp(message),
      message:,
      terminate: False,
    ),
  ))
}

fn message_timestamp(message: AgentMessage) -> Int {
  case message {
    message.UserMessage(timestamp:, ..) -> timestamp
    message.AssistantMessage(timestamp:, ..) -> timestamp
    message.ToolResultMessage(timestamp:, ..) -> timestamp
    message.CustomMessage(..) -> 0
  }
}

// Open question 7, answered: a follow-up on an idle strand starts a
// run, mirroring `send_to_strand`'s idle path.
fn follow_up(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  text: String,
) -> State {
  use <- known_strand(state, connection, id, strand)
  let target = api.on_strand(state.runtime, strand)
  let message = user_message(state, text)
  case api.follow_up(target, message) {
    Ok(entry_id) -> {
      reply(state, connection, id, queued_entry(strand, entry_id, message))
      pull_and_broadcast(state)
    }
    Error(api.QueueRejected(reason: queue.NoActiveRun)) ->
      prompt(state, connection, id, strand, text)
    Error(error) -> {
      let #(code, description) = describe_api_error(error, strand)
      reply_error(state, connection, id, code, description)
      state
    }
  }
}

fn abort(state: State, connection: Int, id: Int, strand: String) -> State {
  use <- known_strand(state, connection, id, strand)
  case session.strand_state(state.runtime.session, strand) {
    Ok(Some(session.Cell(
      value: machine_strand.StrandState(current_operation: Some(op), ..),
      ..,
    ))) -> {
      api.abort(api.on_strand(state.runtime, strand))

      // The durable cancel_requested transition broadcasts when its
      // commit lands; the ack is connection-scoped.
      reply(
        state,
        connection,
        id,
        protocol.OpTransitionEvent(
          op: ids.op_id_to_string(op),
          strand:,
          phase: "cancel_requested",
        ),
      )
      state
    }
    _ -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_conflict,
        "strand " <> strand <> " has no live operation to abort",
      )
      state
    }
  }
}

// --- escalations -----------------------------------------------------------

// One approval, decided against one read.
//
// An approval used to be a statement about a record id: `grants: None`
// meant "whatever this record wants", resolved when the commit ran
// (#72). A claim refreshes a pending record's denial from the call
// that took the claim, so between the diff a human read and the diff
// that got committed there was a mutable value and no check — a human
// answering `wants: wall_s 60` could commit `wants: wall_s 600`.
//
// So the client now says what it rendered, and this reads the record
// **once** — the cell, carrying the seq of the write that put it there
// — checks the echoed diff and the echoed action digest against that
// value, and commits the approval CAS-guarded at that same seq. The
// shared read is the whole mechanism, not a tidiness: a claim is
// exactly the event that changes what a record wants, it bumps the
// register seq when it lands, and a claim landing between the check
// and the commit therefore loses the commit instead of passing unseen.
// Read twice and the check would be about a record the commit never
// touched.
fn approve(
  state: State,
  connection: Int,
  id: Int,
  escalation_id: String,
  echoed: List(Grant),
  action: String,
) -> State {
  use cell <- or_refuse(
    pending_escalation_cell(state, escalation_id),
    state,
    connection,
    id,
  )
  let api.EscalationCell(record:, seq:) = cell
  use wanted <- or_refuse(wanted_diff(record), state, connection, id)
  use Nil <- or_refuse(
    echo_matches(record, wanted, echoed, action),
    state,
    connection,
    id,
  )
  use Nil <- or_refuse(
    commit_approval(state, record, seq, echoed),
    state,
    connection,
    id,
  )
  reply_with_matched(state, connection, id, fn(emit) {
    escalation_emitted(emit, escalation_id, "approved")
  })
}

// The record and the seq it was read at, refused unless it is still
// pending. The point read, not the listing `deny` uses: the seq of
// *this* record is what the commit has to assert, and a listing throws
// every seq away.
fn pending_escalation_cell(
  state: State,
  escalation_id: String,
) -> Result(api.EscalationCell, WireEvent) {
  use cell <- result.try(
    api.escalation_cell(state.runtime, escalation_id)
    |> result.map_error(fn(_error) {
      refusal(
        protocol.code_unknown_escalation,
        "unknown escalation: " <> escalation_id,
      )
    }),
  )
  use <- bool.lazy_guard(
    when: cell.record.status != runtime_escalation.Pending,
    return: fn() {
      Error(refusal(
        protocol.code_not_pending,
        "escalation "
          <> escalation_id
          <> " is "
          <> escalation_status(cell.record.status),
      ))
    },
  )
  Ok(cell)
}

fn wanted_diff(
  record: runtime_escalation.Escalation,
) -> Result(List(Grant), WireEvent) {
  grants.decode_denial(record.denial)
  |> result.map(fn(decoded) { decoded.wanted })
  |> result.map_error(fn(report) {
    refusal(
      protocol.code_internal,
      "the stored denial is unreadable: " <> report.expected,
    )
  })
}

// Whether the answer is about the record in hand.
//
// Two echoes, two different jobs. The action digest is the link this
// series was missing: a spend-time check binds execution to what the
// record held at approval, and this binds the record at approval to
// what the human was shown. The diff is the older rule — a client may
// narrow an approval below what was asked for and never widen it past
// it — and it is a check on staleness for free, because a refreshed
// denial names magnitudes the rendered one did not.
//
// The narrowing direction stays legal on purpose: a record that has
// come to want *more* than was rendered still approves, for exactly
// the grants the human read and no others.
fn echo_matches(
  record: runtime_escalation.Escalation,
  wanted: List(Grant),
  echoed: List(Grant),
  action: String,
) -> Result(Nil, WireEvent) {
  use <- bool.lazy_guard(
    when: option.unwrap(record.action, "") != action,
    return: fn() {
      Error(stale_approval(
        record,
        "the action this approval names is not the one the record now "
          <> "carries; the request changed between the prompt and the answer",
      ))
    },
  )
  case grants.first_unwanted(echoed, wanted:) {
    None -> Ok(Nil)
    Some(_grant) ->
      Error(stale_approval(
        record,
        "the approved grants are not a subset of the denial's wanted diff",
      ))
  }
}

// The approval itself: written straight through the session's one
// writer rather than through `api.approve_escalation`, which reads the
// record again for itself and would leave the checks above standing on
// a value the commit never saw.
fn commit_approval(
  state: State,
  record: runtime_escalation.Escalation,
  seq: Int,
  echoed: List(Grant),
) -> Result(Nil, WireEvent) {
  let key = runtime_escalation.register_key(record.id)
  let approved =
    runtime_escalation.approve(record, list.map(echoed, grants.encode))
  let plan_tx =
    tx.Tx(
      writes: [
        tx.SetRegister(
          ns: register.FactCustom,
          key:,
          value: register.value(runtime_escalation.encode(approved)),
        ),
      ],
      expected: [tx.Expect(ns: register.FactCustom, key:, seq: Some(seq))],
    )
  case
    writer.commit(process.named_subject(state.runtime.tree.writer), plan_tx)
  {
    Ok(_) -> Ok(Nil)

    // The record moved under the answer that named it. Not a retry:
    // committing against a re-read would approve a record nobody read.
    Error(tx.StaleExpectation(..)) ->
      Error(moved_under_the_answer(state, record.id))
    Error(_other) ->
      Error(refusal(protocol.code_internal, "the approval commit was refused"))
  }
}

fn refusal(code: String, message: String) -> WireEvent {
  protocol.ErrorEvent(code:, message:, details: None)
}

// A refusal that hands the record back, so the client re-renders the
// prompt from the answer to its own command instead of waiting for a
// pull to catch up.
fn stale_approval(
  record: runtime_escalation.Escalation,
  message: String,
) -> WireEvent {
  protocol.ErrorEvent(
    code: protocol.code_stale_approval,
    message:,
    details: Some(protocol.stale_approval_details(escalation_view(record))),
  )
}

// The same refusal after a lost compare-and-set, where the record in
// hand is by definition the stale one and the fresh copy has to be
// read again. A failed re-read leaves the client the code alone, which
// still says the answer had no effect.
fn moved_under_the_answer(state: State, escalation_id: String) -> WireEvent {
  let message =
    "the escalation record changed while this approval was being committed"
  case api.escalation(state.runtime, escalation_id) {
    Ok(record) -> stale_approval(record, message)
    Error(_error) -> refusal(protocol.code_stale_approval, message)
  }
}

// `or_reply`'s sibling for the escalation door, where a refusal may
// carry the record it is about: the error side is a whole event rather
// than a code and a message.
//
// ```gleam
// use cell <- or_refuse(pending_escalation_cell(..), state, conn, id)
// ```
fn or_refuse(
  result: Result(a, WireEvent),
  state: State,
  connection: Int,
  id: Int,
  then: fn(a) -> State,
) -> State {
  case result {
    Ok(value) -> then(value)
    Error(event) -> {
      reply(state, connection, id, event)
      state
    }
  }
}

fn deny(
  state: State,
  connection: Int,
  id: Int,
  escalation_id: String,
) -> State {
  use _record <- or_reply(
    find_escalation(state, escalation_id),
    state,
    connection,
    id,
  )
  use Nil <- or_reply(
    result.map_error(
      api.deny_escalation(state.runtime, escalation_id),
      describe_api_error(_, ""),
    ),
    state,
    connection,
    id,
  )
  reply_with_matched(state, connection, id, fn(emit) {
    escalation_emitted(emit, escalation_id, "rejected")
  })
}

fn escalation_emitted(
  emit: Emit,
  escalation_id: String,
  status: String,
) -> Bool {
  case emit.event {
    protocol.EscalationEvent(record:) ->
      record.escalation_id == escalation_id && record.status == status
    _ -> False
  }
}

fn find_escalation(
  state: State,
  escalation_id: String,
) -> Result(runtime_escalation.Escalation, #(String, String)) {
  use records <- result.try(
    result.map_error(api.escalations(state.runtime), fn(_error) {
      #(protocol.code_internal, "the escalation records are unreadable")
    }),
  )
  use record <- result.try(
    result.map_error(
      list.find(records, fn(record) { record.id == escalation_id }),
      fn(_nil) {
        #(
          protocol.code_unknown_escalation,
          "unknown escalation: " <> escalation_id,
        )
      },
    ),
  )
  case record.status {
    runtime_escalation.Pending -> Ok(record)
    _ ->
      Error(#(
        protocol.code_not_pending,
        "escalation "
          <> escalation_id
          <> " is "
          <> escalation_status(record.status),
      ))
  }
}

// --- strand management -----------------------------------------------------

fn fork(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  name: Option(String),
) -> State {
  use <- known_strand(state, connection, id, strand)
  let store = state.runtime.session
  let configuration = case session.strand_configuration(store, strand) {
    Ok(Some(session.Cell(value:, ..))) -> Some(value)
    _ -> None
  }
  let leaf = case session.strand_leaf(store, strand) {
    Ok(Some(session.Cell(value:, ..))) -> value
    _ -> None
  }
  use configuration <- or_reply(
    option.to_result(configuration, #(
      protocol.code_internal,
      "the source strand's configuration is unreadable",
    )),
    state,
    connection,
    id,
  )
  let new_name =
    unique_name(state, case name {
      Some(name) -> name
      None -> strand <> "-fork"
    })
  seed_and_reply(state, connection, id, new_name, configuration, leaf)
}

fn create_strand(
  state: State,
  connection: Int,
  id: Int,
  name: Option(String),
) -> State {
  let strands = strand_names(state)
  let configuration = case
    session.strand_configuration(state.runtime.session, "main")
  {
    Ok(Some(session.Cell(value:, ..))) -> Some(value)
    _ ->
      case strands {
        [first, ..] ->
          case session.strand_configuration(state.runtime.session, first) {
            Ok(Some(session.Cell(value:, ..))) -> Some(value)
            _ -> None
          }
        [] -> None
      }
  }
  use configuration <- or_reply(
    option.to_result(configuration, #(
      protocol.code_internal,
      "no existing strand to copy a configuration from",
    )),
    state,
    connection,
    id,
  )
  let new_name =
    unique_name(state, case name {
      Some(name) -> name
      None -> "strand-" <> int.to_string(list.length(strands) + 1)
    })
  seed_and_reply(state, connection, id, new_name, configuration, None)
}

fn unique_name(state: State, wanted: String) -> String {
  let existing = strand_names(state)
  case list.contains(existing, wanted) {
    False -> wanted
    True -> unique_name_loop(existing, wanted, 2)
  }
}

fn unique_name_loop(existing: List(String), base: String, n: Int) -> String {
  let candidate = base <> "-" <> int.to_string(n)
  case list.contains(existing, candidate) {
    False -> candidate
    True -> unique_name_loop(existing, base, n + 1)
  }
}

// Seeds a briefless strand (the api's `create_strand` always accepts a
// task-brief run; protocol fork/create_strand make idle strands) through
// `api.create_idle_strand`: the same three-register CAS-guarded commit
// the api's own `create_strand` seeds with, then the driver via the
// factory — just without a brief run accepted on top.
fn seed_and_reply(
  state: State,
  connection: Int,
  id: Int,
  name: String,
  copied: machine_strand.StrandConfiguration,
  leaf: Option(EntryId),
) -> State {
  let configuration = seeded_thinking(state, copied)
  case
    api.create_idle_strand(state.runtime, named: name, configuration:, at: leaf)
  {
    Error(api.StrandExists(name:)) -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_conflict,
        "a strand named " <> name <> " already exists",
      )
      state
    }
    Error(api.UnknownForkPoint(..))
    | Error(api.SeedFailed(..))
    | Error(api.BriefRejected(..)) -> {
      reply_error(
        state,
        connection,
        id,
        protocol.code_internal,
        "seeding the strand failed",
      )
      state
    }

    // The registers are durable; the booter starts the driver on the
    // next tree boot even if `start_driver` could not right now. Report
    // nothing in-band — the strand exists (mirrors `create_strand`'s own
    // seed-then-start split: a start failure never unwinds a seed that
    // already landed).
    Ok(Nil) | Error(api.StartFailed(..)) -> {
      let state = pull_and_broadcast(state)
      reply(state, connection, id, strands_snapshot(state))
      state
    }
  }
}

// A seeded strand's per-turn thinking level comes from the catalogue
// entry its identity names — the entry in force for the model it will
// dispatch to — and not from the level the source strand happened to be
// sitting at when it was copied.
//
// The two differ for a reason worth keeping: a strand's per-turn level is
// a property of the conversation someone was having on it, raised or
// lowered mid-run through `set_config`, while a *new* strand has had no
// conversation yet. Seeding from the entry is the same rule `client/serve`
// applies to `main` and `client/agency` applies to a spawned child, so all
// three creation points agree. An identity the catalogue does not know —
// or a hub serving no catalogue at all — keeps what was copied, because
// there is nothing better to say.
fn seeded_thinking(
  state: State,
  configuration: machine_strand.StrandConfiguration,
) -> machine_strand.StrandConfiguration {
  case entry_in_force(state, configuration.model.provider) {
    Ok(entry) ->
      machine_strand.StrandConfiguration(
        ..configuration,
        thinking_level: wiring.strand_thinking_level(entry.thinking),
      )
    Error(Nil) -> configuration
  }
}

fn entry_in_force(
  state: State,
  provider: String,
) -> Result(catalog.CatalogModel, Nil) {
  use catalogue <- result.try(option.to_result(state.catalog, Nil))
  catalog.find(catalogue, provider)
}

fn strands_snapshot(state: State) -> WireEvent {
  case full_snapshot(state) {
    protocol.SnapshotEvent(protocol.FullSnapshot(strands:, ..)) ->
      protocol.SnapshotEvent(protocol.StrandsSnapshot(strands:))
    other -> other
  }
}

// --- navigation and compaction ---------------------------------------------

fn navigate(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  to_entry: String,
) -> State {
  use <- known_strand(state, connection, id, strand)
  use target <- or_reply(
    result.replace_error(ids.parse_entry_id(to_entry), #(
      protocol.code_bad_request,
      "to_entry is not an entry id",
    )),
    state,
    connection,
    id,
  )
  use op <- or_reply(
    result.map_error(
      api.navigate(
        api.on_strand(state.runtime, strand),
        to: Some(target),
        summarize: False,
        label: None,
        custom_instructions: None,
        preparation: None,
      ),
      describe_api_error(_, strand),
    ),
    state,
    connection,
    id,
  )

  // Unsummarized navigation involves no provider round-trip; wait
  // briefly so the reply's strand list shows the moved leaf.
  let _result =
    api.await_result(api.on_strand(state.runtime, strand), op, within_ms: 3000)
  let state = pull_and_broadcast(state)
  reply(state, connection, id, strands_snapshot(state))
  state
}

fn compact(
  state: State,
  connection: Int,
  id: Int,
  strand: String,
  instructions: Option(String),
) -> State {
  use <- known_strand(state, connection, id, strand)
  use op <- or_reply(
    result.map_error(
      api.compact(
        api.on_strand(state.runtime, strand),
        custom_instructions: instructions,
        preparation: compaction_preparation(state, strand),
      ),
      describe_api_error(_, strand),
    ),
    state,
    connection,
    id,
  )
  let op_text = ids.op_id_to_string(op)
  reply_with_matched(state, connection, id, fn(emit) {
    case emit.event {
      protocol.OpTransitionEvent(op: emitted, ..) -> emitted == op_text
      _ -> False
    }
  })
}

// The compaction preparation a manual `compact` command summarizes
// from: the strand's durable projection through the *same* builder the
// threshold and overflow hooks use (`runtime/hooks.preparation`), so an
// operator-requested compaction cuts where an automatic one cuts, keeps
// what an automatic one keeps, and carries a previous summary forward
// the same way. The run's own settings snapshot supplies the budget.
fn compaction_preparation(
  state: State,
  strand: String,
) -> Option(operation.StructuralPreparation) {
  let projected = hooks.project(state.runtime.session, strand)
  let settings = state.runtime.settings.compaction
  case
    hooks.preparation(
      projected,
      operation.CompactionSettings(..settings, enabled: True),
      hooks.estimate_message,
      tokens_before: hooks.context_tokens(projected, hooks.estimate_message),
    )
  {
    planner.Prepared(preparation:) -> Some(preparation)
    planner.EmptyPreparation -> None
  }
}

// Shared with `describe_api_error`: an `AcceptRejected` carries one of
// these, whether it came from `api.compact`, `api.navigate`, or a run
// acceptance.
fn describe_reject(reason: acceptance.RejectReason) -> #(String, String) {
  case reason {
    acceptance.StrandBusy -> #(
      protocol.code_conflict,
      "the strand already has a live operation",
    )
    acceptance.InvalidMessage(reason:) -> #(protocol.code_bad_request, reason)
    acceptance.NothingToCompact -> #(
      protocol.code_conflict,
      "there is nothing to compact",
    )
    acceptance.InvalidNavigation(reason:) -> #(
      protocol.code_bad_request,
      reason,
    )
    acceptance.UnknownTarget -> #(
      protocol.code_bad_request,
      "the navigation target does not exist",
    )
    acceptance.QueueCorruption(report:) -> #(
      protocol.code_internal,
      "queue corruption: " <> report.expected,
    )
  }
}

// --- the model catalogue ---------------------------------------------------

// `models`: the catalogue as a `models` snapshot. A hub without a
// configured catalogue answers an empty listing — the honest shape for
// "there is nothing to pick from", and the same reply a client gets
// either way, so it needs no special case.
fn list_models(state: State, connection: Int, id: Int) -> State {
  let models = case state.catalog {
    None -> []
    Some(catalogue) -> catalog_listing(catalogue)
  }
  reply(
    state,
    connection,
    id,
    protocol.SnapshotEvent(protocol.ModelsSnapshot(models:)),
  )
  state
}

// One wire row per catalogue entry: its identity facts plus which role
// chains list it and which it currently heads (and therefore resolves
// for — every catalogue entry is a registered provider).
fn catalog_listing(catalogue: catalog.Catalog) -> List(protocol.ModelInfo) {
  list.map(catalogue.models, fn(entry) {
    protocol.ModelInfo(
      name: entry.name,
      dialect: catalog.dialect_to_string(entry.dialect),
      model_id: entry.model_id,
      roles: catalog.routed_roles(catalogue, entry.name),
      active: catalog.active_roles(catalogue, entry.name),
    )
  })
}

// --- set_config ------------------------------------------------------------

// The accepted key set (protocol.md open question 3, answered):
// `queue_mode` ("consume_all" | "one_at_a_time"), `tool_execution`
// ("sequential" | "parallel") — session-wide run settings captured into
// subsequent acceptances — `model_name` (a catalogue name, resolved
// server-side; with a `strand` it switches that strand, without one it
// switches every strand) — and, with a `strand`, the durable
// per-strand configuration keys `model` ({provider, model_id}),
// `thinking_level`, and `active_tools` (validated against the
// configured tool registry and stored canonically — see
// `canonical_tool_names`). Unknown keys are refused (`bad_request`)
// and nothing is applied.
fn set_config(
  state: State,
  connection: Int,
  id: Int,
  strand: Option(String),
  config: JsonValue,
) -> State {
  use fields <- or_reply(config_fields(config), state, connection, id)
  use state <- or_reply(
    result.map_error(apply_config(state, strand, fields), fn(message) {
      #(protocol.code_bad_request, message)
    }),
    state,
    connection,
    id,
  )
  reply(
    state,
    connection,
    id,
    protocol.SnapshotEvent(
      protocol.ConfigSnapshot(config: effective_config(state, strand)),
    ),
  )
  state
}

fn config_fields(
  config: JsonValue,
) -> Result(List(#(String, JsonValue)), #(String, String)) {
  case config {
    json.Object(fields) -> Ok(fields)
    _ -> Error(#(protocol.code_bad_request, "config must be an object"))
  }
}

fn apply_config(
  state: State,
  strand: Option(String),
  fields: List(#(String, JsonValue)),
) -> Result(State, String) {
  // Validate everything before applying anything: a refused key must
  // leave no partial effect.
  use changes <- result.try(
    list.try_map(fields, fn(field) { validate_config_key(state, strand, field) }),
  )
  list.fold(changes, Ok(state), fn(state, change) {
    use state <- result.try(state)
    change(state)
  })
}

type ConfigChange =
  fn(State) -> Result(State, String)

fn validate_config_key(
  state: State,
  strand: Option(String),
  field: #(String, JsonValue),
) -> Result(ConfigChange, String) {
  let #(key, value) = field
  case key {
    "queue_mode" ->
      case value {
        json.String("consume_all") ->
          Ok(set_queue_mode(_, operation.ConsumeAll))
        json.String("one_at_a_time") ->
          Ok(set_queue_mode(_, operation.OneAtATime))
        _ -> Error("queue_mode must be consume_all or one_at_a_time")
      }
    "tool_execution" ->
      case value {
        json.String("sequential") ->
          Ok(set_tool_execution(_, operation.Sequential))
        json.String("parallel") -> Ok(set_tool_execution(_, operation.Parallel))
        _ -> Error("tool_execution must be sequential or parallel")
      }
    "model" ->
      case strand, value {
        None, _ -> Error("model requires a strand")
        Some(strand), json.Object(model_fields) ->
          model_change(strand, model_fields)
        Some(_), _ -> Error("model must be an object")
      }

    // The by-name variant of `model`: the catalogue resolves the name
    // into the durable identity, so clients never handle raw provider
    // facts. Scoped to one strand when named, to every strand (the
    // session's model) otherwise.
    "model_name" ->
      case value {
        json.String(name) -> model_name_change(state, strand, name)
        _ -> Error("model_name must be a string (a catalogue model name)")
      }
    "thinking_level" ->
      case strand, value {
        None, _ -> Error("thinking_level requires a strand")
        Some(strand), json.String(level_text) ->
          thinking_level_change(strand, level_text)
        Some(_), _ -> Error("thinking_level must be a string")
      }

    // Every name is checked against the live registry and the list is
    // stored canonically; see `canonical_tool_names`.
    "active_tools" ->
      case strand, value {
        None, _ -> Error("active_tools requires a strand")
        Some(strand), json.Array(items) ->
          active_tools_change(state, strand, items)
        Some(_), _ -> Error("active_tools must be an array of tool names")
      }
    other -> Error("unknown config key: " <> other)
  }
}

fn model_change(
  strand: String,
  model_fields: List(#(String, JsonValue)),
) -> Result(ConfigChange, String) {
  use provider <- result.try(config_string(model_fields, "provider"))
  use model_id <- result.try(config_string(model_fields, "model_id"))
  Ok(
    update_configuration(_, strand, fn(configuration) {
      machine_strand.StrandConfiguration(
        ..configuration,
        model: machine_strand.ModelIdentity(provider:, model_id:),
      )
    }),
  )
}

fn thinking_level_change(
  strand: String,
  level_text: String,
) -> Result(ConfigChange, String) {
  use level <- result.try(parse_thinking_level(level_text))
  Ok(
    update_configuration(_, strand, fn(configuration) {
      machine_strand.StrandConfiguration(..configuration, thinking_level: level)
    }),
  )
}

fn active_tools_change(
  state: State,
  strand: String,
  items: List(JsonValue),
) -> Result(ConfigChange, String) {
  use names <- result.try(list.try_map(items, json_string_item))
  use names <- result.try(canonical_tool_names(state, names))
  Ok(
    update_configuration(_, strand, fn(configuration) {
      machine_strand.StrandConfiguration(
        ..configuration,
        active_tool_names: names,
      )
    }),
  )
}

fn json_string_item(item: JsonValue) -> Result(String, String) {
  case item {
    json.String(name) -> Ok(name)
    _ -> Error("active_tools entries must be strings")
  }
}

// `model_name`'s change: the catalogue entry's identity, applied to one
// strand's configuration when named, or to every strand's otherwise.
//
// **It does not touch `thinking_level`,** even though the entry declares
// one. A catalogue's `thinking` seeds a strand at creation; the per-turn
// level afterwards belongs to whoever is having the conversation, and
// switching model mid-run is not a request to un-raise a reasoning budget
// somebody deliberately raised. A client that wants both sends both keys.
fn model_name_change(
  state: State,
  strand: Option(String),
  name: String,
) -> Result(ConfigChange, String) {
  use catalogue <- result.try(option.to_result(
    state.catalog,
    "no model catalogue is configured",
  ))
  use entry <- result.try(
    result.map_error(catalog.find(catalogue, name), fn(_nil) {
      "unknown model name: " <> name
    }),
  )
  let identity =
    machine_strand.ModelIdentity(provider: entry.name, model_id: entry.model_id)
  let change = fn(configuration) {
    machine_strand.StrandConfiguration(..configuration, model: identity)
  }
  case strand {
    Some(strand) -> Ok(update_configuration(_, strand, change))
    None -> Ok(update_all_configurations(_, change))
  }
}

// The durable form of an active-tools list: every name checked against
// the live registry, then sorted with duplicates collapsed.
//
// The sort is load-bearing, not tidiness. This list is what
// `client/wiring.tool_specs` renders into a request's tool array, which
// sits ahead of the system prompt in the provider's render order; the
// prompt cache matches on an exact byte prefix, and the Anthropic
// adapter hangs one breakpoint on the last tool definition and another
// on the system block. A client that re-sends the same set in a new
// order would move those bytes and pay both cache writes again, every
// turn. `tool_specs` sorts too — belt and braces, since a durable list
// can be written by other paths — but a strand's stored configuration
// is the honest place for the canonical form, and it is what the
// `config` snapshot echoes back.
//
// Neither the sort nor the dedup moves the authorization line:
// `wiring.clear` decides what may run by `list.contains` on this same
// list, and set membership is blind to order and multiplicity.
//
// An unregistered name refuses the whole command, in band and by name,
// the way an unknown `model_name` does — a tool that does not exist has
// no business in durable configuration, and silently dropping it would
// leave the client believing it had enabled something.
fn canonical_tool_names(
  state: State,
  names: List(String),
) -> Result(List(String), String) {
  case state.registry {
    None -> Error("no tool registry is configured")
    Some(registry) -> {
      use _known <- result.try(
        list.try_map(names, fn(name) {
          case tool.lookup(registry, name) {
            Ok(_registered) -> Ok(name)
            Error(Nil) -> Error("unknown tool name: " <> name)
          }
        }),
      )
      Ok(
        names
        |> list.sort(string.compare)
        |> list.unique,
      )
    }
  }
}

fn config_string(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(text)
    _ -> Error(key <> " must be a string")
  }
}

fn set_queue_mode(
  state: State,
  mode: operation.QueueMode,
) -> Result(State, String) {
  let settings =
    operation.RunSettings(
      ..state.runtime.settings,
      steering_mode: mode,
      follow_up_mode: mode,
    )
  Ok(State(..state, runtime: api.Runtime(..state.runtime, settings: settings)))
}

fn set_tool_execution(
  state: State,
  mode: operation.ToolExecution,
) -> Result(State, String) {
  let settings =
    operation.RunSettings(..state.runtime.settings, tool_execution: mode)
  Ok(State(..state, runtime: api.Runtime(..state.runtime, settings: settings)))
}

fn update_configuration(
  state: State,
  strand: String,
  change: fn(machine_strand.StrandConfiguration) ->
    machine_strand.StrandConfiguration,
) -> Result(State, String) {
  case session.strand_configuration(state.runtime.session, strand) {
    Ok(Some(session.Cell(value:, seq:))) -> {
      let updated = change(value)
      let plan_tx =
        tx.Tx(
          writes: [
            tx.SetRegister(
              ns: register.StrandConfig,
              key: strand,
              value: register.value(machine_codec.encode_configuration(updated)),
            ),
          ],
          expected: [
            tx.Expect(ns: register.StrandConfig, key: strand, seq: Some(seq)),
          ],
        )
      case
        writer.commit(process.named_subject(state.runtime.tree.writer), plan_tx)
      {
        Ok(_) -> Ok(state)
        Error(_) -> Error("the configuration commit was refused")
      }
    }
    _ -> Error("unknown strand: " <> strand)
  }
}

// The session-wide variant: the same durable update applied to every
// strand with a configuration register. Validation ran before any
// change (apply_config's contract), so a mid-fold commit refusal is a
// writer-level failure, reported as such.
fn update_all_configurations(
  state: State,
  change: fn(machine_strand.StrandConfiguration) ->
    machine_strand.StrandConfiguration,
) -> Result(State, String) {
  list.fold(strand_names(state), Ok(state), fn(state, strand) {
    use state <- result.try(state)
    update_configuration(state, strand, change)
  })
}

fn parse_thinking_level(
  text: String,
) -> Result(machine_strand.ThinkingLevel, String) {
  case text {
    "off" -> Ok(machine_strand.ThinkingOff)
    "minimal" -> Ok(machine_strand.ThinkingMinimal)
    "low" -> Ok(machine_strand.ThinkingLow)
    "medium" -> Ok(machine_strand.ThinkingMedium)
    "high" -> Ok(machine_strand.ThinkingHigh)
    "xhigh" -> Ok(machine_strand.ThinkingXHigh)
    "max" -> Ok(machine_strand.ThinkingMax)
    other -> Error("unknown thinking level: " <> other)
  }
}

fn effective_config(state: State, strand: Option(String)) -> JsonValue {
  let base = base_config_fields(state)
  case strand {
    None -> json.Object(base)
    Some(strand) ->
      case session.strand_configuration(state.runtime.session, strand) {
        Ok(Some(session.Cell(value:, ..))) ->
          json.Object(list.flatten([base, strand_config_fields(state, value)]))
        _ -> json.Object(base)
      }
  }
}

// The session-wide fields: present in every `config` snapshot, strand or
// none.
fn base_config_fields(state: State) -> List(#(String, JsonValue)) {
  let settings = state.runtime.settings
  [
    #("queue_mode", json.String(queue_mode_text(settings.steering_mode))),
    #(
      "tool_execution",
      json.String(tool_execution_text(settings.tool_execution)),
    ),
  ]
}

fn queue_mode_text(mode: operation.QueueMode) -> String {
  case mode {
    operation.ConsumeAll -> "consume_all"
    operation.OneAtATime -> "one_at_a_time"
  }
}

fn tool_execution_text(mode: operation.ToolExecution) -> String {
  case mode {
    operation.Sequential -> "sequential"
    operation.Parallel -> "parallel"
  }
}

// The per-strand fields, spliced onto the session-wide base.
fn strand_config_fields(
  state: State,
  value: machine_strand.StrandConfiguration,
) -> List(#(String, JsonValue)) {
  list.flatten([
    [
      #(
        "model",
        json.Object([
          #("provider", json.String(value.model.provider)),
          #("model_id", json.String(value.model.model_id)),
        ]),
      ),
    ],
    // The catalogue name rides along whenever the identity is one the
    // catalogue knows, so clients can display and re-select by the same
    // handle they switched with.
    catalog_name_of(state, value.model),
    [
      #(
        "thinking_level",
        json.String(thinking_level_text(value.thinking_level)),
      ),
      #(
        "active_tools",
        json.Array(list.map(value.active_tool_names, json.String)),
      ),
    ],
  ])
}

// The catalogue name behind a durable identity, when there is one: the
// entry whose name is the identity's provider and whose model id
// matches. Zero or one field, spliced into the effective config.
fn catalog_name_of(
  state: State,
  identity: machine_strand.ModelIdentity,
) -> List(#(String, JsonValue)) {
  case state.catalog {
    None -> []
    Some(catalogue) ->
      case catalog.find(catalogue, identity.provider) {
        Ok(entry) if entry.model_id == identity.model_id -> [
          #("model_name", json.String(entry.name)),
        ]
        _ -> []
      }
  }
}

fn thinking_level_text(level: machine_strand.ThinkingLevel) -> String {
  case level {
    machine_strand.ThinkingOff -> "off"
    machine_strand.ThinkingMinimal -> "minimal"
    machine_strand.ThinkingLow -> "low"
    machine_strand.ThinkingMedium -> "medium"
    machine_strand.ThinkingHigh -> "high"
    machine_strand.ThinkingXHigh -> "xhigh"
    machine_strand.ThinkingMax -> "max"
  }
}

// --- error mapping ---------------------------------------------------------

fn describe_api_error(
  error: api.ApiError,
  strand: String,
) -> #(String, String) {
  case error {
    api.AcceptRejected(reason:) -> describe_reject(reason)
    api.QueueRejected(reason: queue.NoActiveRun) -> #(
      protocol.code_conflict,
      "strand " <> strand <> " has no live operation",
    )
    api.ReadFailed(reason:) -> #(protocol.code_internal, reason)
    api.CommitFailed(error: _) -> #(
      protocol.code_internal,
      "the admission commit failed",
    )

    // A conflict, not an internal error: the session is gone from this
    // process's hands and the caller's remedy is to reopen it, which is
    // exactly what a conflict code tells a client to consider.
    api.SessionStolen(held_by: Some(owner)) -> #(
      protocol.code_conflict,
      "the session's write lease is now held by " <> owner,
    )
    api.SessionStolen(held_by: None) -> #(
      protocol.code_conflict,
      "the session's write lease was lost",
    )
    api.RaceLost -> #(
      protocol.code_conflict,
      "the admission kept losing its seq race",
    )
    api.ReservedFactKey(key:) -> #(
      protocol.code_bad_request,
      "reserved fact key: " <> key,
    )
    api.UnreservedFactKey(key:) -> #(
      protocol.code_bad_request,
      "not a reserved fact key: " <> key,
    )
    api.EscalationExists(id:) -> #(
      protocol.code_conflict,
      "escalation " <> id <> " already exists",
    )
    api.EscalationNotFound(id:) -> #(
      protocol.code_unknown_escalation,
      "unknown escalation: " <> id,
    )
    api.EscalationWrongStatus(id:, status:) -> #(
      protocol.code_not_pending,
      "escalation " <> id <> " is " <> escalation_status(status),
    )
    api.FactConflict(key:) -> #(
      protocol.code_conflict,
      "the fact " <> key <> " moved under the write",
    )
  }
}

/// Whether the hub process is currently alive — diagnostics only.
///
/// ## Examples
///
/// ```gleam
/// // gateway.is_alive(gateway)
/// ```
///
pub fn is_alive(gateway: Gateway) -> Bool {
  case process.subject_owner(process.named_subject(gateway.name)) {
    Ok(pid) -> process.is_alive(pid)
    Error(Nil) -> False
  }
}

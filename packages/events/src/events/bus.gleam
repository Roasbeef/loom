//// The EventBus: typed, per-session topics over an OTP `pg` scope
//// (design §3.6). Every commit-side actor can publish typed events;
//// projections, UIs, and telemetry subscribe.
////
//// **Events are hints; pulls are truth.** Delivery is best-effort plain
//// sends to the local members of a `pg` group: a subscriber that was
//// down, slow to join, or on another node simply misses events, and
//// that is legal by design. Anything that must be correct converges by
//// pulling from storage (`scan_*` from a persisted high-water seq — see
//// `events/projection`); the bus only makes convergence prompt.
////
//// Groups are keyed `#(session, topic)` inside one node-global scope,
//// so lookups are local-speed ETS reads and per-session isolation needs
//// no per-session processes. Cross-node fan-out (clustered `pg`) is
//// follow-up track 4 and changes nothing here but the member list.
////
//// The writer bridge: the runtime's StorageWriter publishes its own
//// minimal `Committed` pub/sub today. `bridge` is the adoption seam —
//// it turns any subscription-shaped event source into bus publishes
//// without this package importing the runtime (the mapping closure is
//// written by the composition layer, which knows both types).

import core/ids.{type EntryId, type OpId, type Seq, type UsageId}
import events/internal/ffi_pg.{type Scope}
import gleam/erlang/process.{type Selector, type Subject}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}

/// A handle on the running event bus (the `pg` scope).
///
/// Constructor invariants: the scope process is running when the handle
/// was obtained from `start` or `supervised`; all handles refer to the
/// same node-global scope.
pub opaque type Bus {
  Bus(scope: Scope)
}

/// The typed topics of a session's event stream. One event belongs to
/// exactly one topic (`topic_of`), so a subscriber joined to several
/// topics never receives duplicates.
pub type Topic {
  /// Entry appends (`EntryAdded`).
  Entries
  /// Operation state transitions (`OpTransition`).
  Operations
  /// Usage-ledger appends (`UsageAdded`).
  Usage
  /// Strand terminal results (`StrandResult`).
  Strands
  /// Escalations awaiting approval (`Escalation`).
  Escalations
  /// Whole-commit notifications (`Committed`).
  Commits
}

/// One event on a session's stream. Payloads are deliberately thin —
/// ids and seqs, never content — because an event is only a hint that
/// something changed; the durable store is read for the truth. Losing
/// any event is legal.
pub type Event {
  /// An entry was appended. Hint: re-scan entries from your high-water.
  EntryAdded(id: EntryId, seq: Seq)
  /// An operation's durable state advanced. `phase` is a display label,
  /// not a machine input — the `op.state` register is the truth.
  OpTransition(op: OpId, phase: String)
  /// A usage-ledger row was appended.
  UsageAdded(id: UsageId, seq: Seq)
  /// A strand settled a terminal result. The `strand.last_result`
  /// register is the truth.
  StrandResult(strand: String)
  /// An effect escalated for approval. `description` is display text;
  /// the durable escalation entry is the truth.
  Escalation(op: OpId, description: String)
  /// A transaction committed, carrying its storage-assigned seqs. The
  /// coarsest hint — what the runtime writer's post-commit publication
  /// maps onto (see `bridge`).
  Committed(seqs: List(Seq), ts: Int)
}

/// One delivered event: the session it belongs to plus the event, so a
/// subscriber joined to groups of several sessions can tell them apart.
///
/// Constructor invariants: `session` is the session key the event was
/// published under; `event`'s topic is the group topic it was sent to.
pub type Published {
  Published(session: String, event: Event)
}

/// The topic an event belongs to — the group key `publish` sends it to.
///
/// ## Examples
///
/// ```gleam
/// assert bus.topic_of(bus.Committed(seqs: [1], ts: 0)) == bus.Commits
/// ```
///
pub fn topic_of(event: Event) -> Topic {
  case event {
    EntryAdded(..) -> Entries
    OpTransition(..) -> Operations
    UsageAdded(..) -> Usage
    StrandResult(..) -> Strands
    Escalation(..) -> Escalations
    Committed(..) -> Commits
  }
}

/// All topics, for whole-stream subscribers.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(bus.all_topics()) == 6
/// ```
///
pub fn all_topics() -> List(Topic) {
  [Entries, Operations, Usage, Strands, Escalations, Commits]
}

/// Starts the bus (idempotently — an already-running scope is success)
/// and returns a handle. Use this from tests and simple compositions;
/// use `supervised` to own the scope in a supervision tree.
///
/// ## Examples
///
/// ```gleam
/// // let bus = bus.start()
/// ```
///
pub fn start() -> Bus {
  ffi_pg.start(ffi_pg.LoomEvents)
  Bus(scope: ffi_pg.LoomEvents)
}

/// The bus scope as a supervision child. The scope process is
/// node-global state, so this belongs near the top of the node's tree,
/// not inside per-session trees.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(builder, bus.supervised())
/// ```
///
pub fn supervised() -> ChildSpecification(Bus) {
  supervision.worker(fn() {
    case ffi_pg.start_link(ffi_pg.LoomEvents) {
      Ok(pid) -> Ok(actor.Started(pid:, data: Bus(scope: ffi_pg.LoomEvents)))
      Error(Nil) -> Error(actor.InitFailed("pg scope already started"))
    }
  })
}

/// Publishes an event on a session's stream, fire-and-forget: it is
/// delivered to the current local subscribers of `#(session,
/// topic_of(event))` and to no one else. There are no acks and no
/// buffering — a missed event is caught by the subscriber's next pull.
///
/// ## Examples
///
/// ```gleam
/// // bus.publish(bus, "session-1", bus.Committed(seqs: [4, 5], ts: now))
/// ```
///
pub fn publish(bus: Bus, session session: String, event event: Event) -> Nil {
  ffi_pg.publish(
    bus.scope,
    #(session, topic_of(event)),
    Published(session:, event:),
  )
}

/// Subscribes the *calling process* to one topic of one session.
/// Membership is per-process and cleaned up automatically when the
/// process dies. Receive the events by folding `select_published` into
/// the process's selector.
///
/// Idempotent per `{session, topic}`: a process already subscribed that
/// subscribes again stays a single member. `pg` itself counts
/// multiplicity — two joins from the same pid deliver every event
/// twice, and one `unsubscribe` would only undo one of them — so this
/// checks membership before joining rather than relying on `pg` to
/// dedup.
///
/// ## Examples
///
/// ```gleam
/// // bus.subscribe(bus, session: "session-1", topic: bus.Commits)
/// ```
///
pub fn subscribe(bus: Bus, session session: String, topic topic: Topic) -> Nil {
  let group = #(session, topic)
  case ffi_pg.is_member(bus.scope, group) {
    True -> Nil
    False -> ffi_pg.join(bus.scope, group)
  }
}

/// Subscribes the calling process to every topic of one session. Events
/// still arrive exactly once each — an event is published to its one
/// topic group only.
///
/// ## Examples
///
/// ```gleam
/// // bus.subscribe_all(bus, session: "session-1")
/// ```
///
pub fn subscribe_all(bus: Bus, session session: String) -> Nil {
  subscribe_all_loop(bus, session, all_topics())
}

fn subscribe_all_loop(bus: Bus, session: String, topics: List(Topic)) -> Nil {
  case topics {
    [] -> Nil
    [topic, ..rest] -> {
      subscribe(bus, session:, topic:)
      subscribe_all_loop(bus, session, rest)
    }
  }
}

/// Removes the calling process from one topic of one session; a no-op
/// if it never subscribed.
///
/// ## Examples
///
/// ```gleam
/// // bus.unsubscribe(bus, session: "session-1", topic: bus.Commits)
/// ```
///
pub fn unsubscribe(
  bus: Bus,
  session session: String,
  topic topic: Topic,
) -> Nil {
  ffi_pg.leave(bus.scope, #(session, topic))
}

/// The number of local subscribers on one topic of one session — an
/// ETS lookup. Useful for tests and diagnostics; never for correctness
/// (membership changes concurrently).
///
/// ## Examples
///
/// ```gleam
/// // bus.subscriber_count(bus, session: "session-1", topic: bus.Commits)
/// ```
///
pub fn subscriber_count(
  bus: Bus,
  session session: String,
  topic topic: Topic,
) -> Int {
  ffi_pg.member_count(bus.scope, #(session, topic))
}

/// Extends a selector to receive the bus events this process subscribed
/// to, mapped into the process's own message type. Add this to an
/// actor's selector in its initialiser, after calling `subscribe`.
///
/// ## Examples
///
/// ```gleam
/// // process.new_selector()
/// // |> process.select(subject)
/// // |> bus.select_published(Hint)
/// ```
///
pub fn select_published(
  selector: Selector(message),
  map: fn(Published) -> message,
) -> Selector(message) {
  ffi_pg.select_published(selector, map)
}

/// Starts a bridge actor: a subject that republishes everything sent to
/// it onto the bus, through the caller's mapping. This is the writer
/// adoption seam — the composition layer subscribes this subject to the
/// runtime StorageWriter's post-commit publication and maps its
/// `Committed(ordinal, seqs, ts)` events to `bus.Committed`, replacing
/// the writer's subscriber-facing story without a package dependency in
/// either direction.
///
/// The bridge inherits the bus's loss semantics: if it dies, events are
/// missed until it is restarted, and that is legal — subscribers
/// converge by pulling. `map` is caller-supplied and runs inside the
/// bridge actor, so it must be total: `actor.start` links the new
/// process to its caller the way every OTP start does, and a `map` that
/// crashes would otherwise take the starter down with it. `bridge`
/// unlinks immediately after a successful start so that crash stays
/// local to the bridge, exactly as the "missed until restarted" promise
/// above already assumes.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(started) =
/// //   bus.bridge(bus, session: "session-1", map: fn(event) {
/// //     let writer.Committed(seqs:, ts:, ..) = event
/// //     bus.Committed(seqs:, ts:)
/// //   })
/// // writer.subscribe(writer, started.data)
/// ```
///
pub fn bridge(
  bus: Bus,
  session session: String,
  map map: fn(incoming) -> Event,
) -> actor.StartResult(Subject(incoming)) {
  case
    actor.new(Nil)
    |> actor.on_message(fn(_state, incoming) {
      publish(bus, session:, event: map(incoming))
      actor.continue(Nil)
    })
    |> actor.start
  {
    Ok(started) -> {
      process.unlink(started.pid)
      Ok(started)
    }
    Error(error) -> Error(error)
  }
}

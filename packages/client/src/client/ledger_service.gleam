//// The `loom_ledger` process: one node's copy of the membership ledger, kept
//// current by exchanging heads with the peers it is connected to
//// (protocol-change/086, section 6.1).
////
//// A node holds the ledger in memory and in its file, and this process owns
//// both. Entries reach it from two places: an operator's tool offers a line
//// directly, and a peer that holds more entries says so. The process applies
//// either through the same acceptance procedure, appends the line to the file
//// before anything else learns of it, and then tells its observers and its
//// peers. It never trusts the sender. The signature and the chain are the
//// trust, so a line is as good from a stranger's relay as from the operator.
////
//// ## Why one process owns the file and the peers
////
//// The order of three things must not depend on timing: the file holds an
//// entry before a peer or the TLS callback acts on it, a revoke is applied
//// before the next node-up is judged, and two lines never extend the chain at
//// once. One process handling one message at a time gives all three for free.
//// Observers are called inside that process, synchronously, between the
//// durable append and the next message, which is how a later slice publishes
//// the pin table and disconnects revoked nodes without a race.
////
//// ## The wire vocabulary
////
//// Peers speak two messages. `Head` says what the sender holds and where to
//// answer. `Pull` asks for the entries after a sequence number and names the
//// subject to answer on. There is no push: the node that is behind always
//// pulls, whichever end dialed. 086 sketches `Head` without a sender. A
//// receiver has to know whom to pull from, and a message sent to a registered
//// name does not say who sent it, so `Head` carries the sender's inbox as a
//// `Subject`. The messages hold integers, bytes and subjects only; no atom or
//// function comes from a peer.
////
//// ## Flow
////
//// 1. `start` takes a `Store` the caller opened. The process registers its
////    wire name, hands the loaded ledger to the observers, and asks the VM
////    for node-up notices.
//// 2. `Start` is the first event. It arms the periodic tick and sends a `Head`
////    to every peer already connected.
//// 3. A node-up sends a `Head` to that peer. Each tick sends one to every
////    connected peer, which repairs a message that was lost.
//// 4. A `Head` from a peer is compared with this node's head by `plan`. A
////    peer ahead is pulled from. A peer at the same sequence number with a
////    different identity is pulled for that one entry, which surfaces the
////    fork as a refusal. Anything else is only recorded.
//// 5. A pull makes the machine `Pulling` until the entries arrive, the
////    deadline passes, or the peer drops. A `Head` that would start another
////    pull waits, postponed, until the machine is `Quiet` again.
//// 6. `Delivered` entries go through `offer_line` one at a time. If the head
////    moved and the peer has more, `delivered` requests the next batch.
////    Otherwise the machine is `Quiet`, and the new head is announced to
////    every peer but the source.
////
//// ## Refusals
////
//// A line that fails the acceptance procedure is refused and recorded as the
//// last refusal (086 section 6.3). The process keeps its ledger and keeps
//// applying lines that extend it. A refusal is not relayed and does not
//// change what the node says in its next `Head`. A peer that answers with
//// garbage therefore costs one recorded refusal and one batch, and the
//// machine returns to `Quiet`.

import client/internal/ffi_nodes
import client/internal/ffi_remote
import client/membership_entry.{type SignedEntry, type Verifier}
import client/membership_ledger.{type Ledger}
import client/membership_store.{type Store}
import gleam/dict.{type Dict}
import gleam/erlang/node.{type Node}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string
import host/bootstrap
import telemetry/field.{type Field}
import telemetry/log.{type Logger}
import weft/state_machine as sm

// The name the process registers under on every node, which a peer addresses
// as `{loom_ledger, node}`.
const wire_name = "loom_ledger"

/// The most lines a `Pull` is answered with, and the most a puller asks for.
pub const max_batch = 64

/// The most bytes of lines a `Pull` is answered with.
pub const max_reply_bytes = 262_144

/// How long a pull waits for its entries before the machine gives up on it.
pub const default_pull_within_ms = 5000

/// How often a node sends its head to every connected peer.
pub const default_tick_ms = 60_000

// --- the vocabulary peers speak ------------------------------------------------

/// A message from a peer's `loom_ledger`. The vocabulary is closed and matched
/// without a catch-all: a constructor added later halts an older node, and both
/// ends are upgraded together.
pub type Message {
  /// What the sender holds, and where to pull from it.
  Head(
    /// The sequence number of the sender's newest applied entry.
    seq: Int,
    /// The identity of that entry, 32 bytes.
    id: BitArray,
    /// The sender's inbox. A receiver that is behind sends its `Pull` here.
    from: Subject(Message),
  )

  /// A request for the entries after `after`.
  Pull(
    /// The sequence number the asker holds.
    after: Int,
    /// The most lines wanted, clamped to 1 through `max_batch`.
    limit: Int,
    /// Where the answer goes.
    reply: Subject(Entries),
  )
}

/// Lines in answer to a `Pull`, or to a local read.
pub type Entries {
  Entries(
    /// The lines, oldest first, from `after + 1`.
    lines: List(BitArray),
    /// The sequence number of the answerer's newest entry, so the asker knows
    /// whether to ask again.
    head_seq: Int,
  )
}

// --- what callers see ------------------------------------------------------------

/// What happened to a line offered to the process.
pub type Offered {
  /// The line extended the chain, is in the file, and the observers have run.
  Accepted(head: membership_ledger.Head)

  /// The ledger already holds this entry.
  AlreadyHeld

  /// The line is more than one past the head and was ignored. `head` says what
  /// to send first.
  Behind(head: membership_ledger.Head)

  /// The line failed the acceptance procedure. The ledger is unchanged.
  Refused(refusal: membership_ledger.Refusal)

  /// The line is valid and the file could not take it, so the ledger is
  /// unchanged. Nothing was told to a peer or an observer.
  NotDurable(reason: String)
}

/// The last line this node refused.
pub type Rejected {
  Rejected(
    /// The sequence number the line claimed, when it was readable far enough
    /// to have one.
    seq: Option(Int),
    /// The step that failed and, for a fork, both identities.
    refusal: membership_ledger.Refusal,
  )
}

/// The last head a peer reported.
pub type Reported {
  Reported(
    /// The peer's node name.
    node: String,
    /// The sequence number it reported.
    seq: Int,
    /// The identity it reported.
    id: BitArray,
    /// Milliseconds on this node's own clock since the report arrived.
    ms_since: Int,
  )
}

/// A read of everything the process knows, for `ledger.status`.
pub type Status {
  Status(
    /// The ledger as it stands.
    ledger: Ledger,
    /// The last refusal, or `None` if the node has refused nothing.
    last_refusal: Option(Rejected),
    /// The peers that have reported a head, ordered by node name.
    reported: List(Reported),
  )
}

/// What an observer is told, in the process, before it handles another message.
pub type Observation {
  /// The ledger the node started with. Delivered once, before `start` returns,
  /// so a table can exist before the first handshake.
  Loaded(ledger: Ledger)

  /// An entry was applied and is durable. `ledger` is the state after it.
  Extended(ledger: Ledger, entry: SignedEntry)

  /// A peer connected. A later slice judges the peer against the pin table.
  Connected(node: String)
}

/// A function the process calls for each observation. It runs in the process,
/// so it must be quick and must not call the service it observes.
pub type Observer =
  fn(Observation) -> Nil

/// One peer this node can send to.
pub type Reach {
  Reach(
    /// The peer's node name.
    node: String,
    /// Sends it a message. A peer that is gone or runs no ledger drops it.
    deliver: fn(Message) -> Nil,
  )
}

/// Where the peers come from.
pub type Peers {
  /// The nodes of this VM's Erlang distribution: those connected when the
  /// process starts, and each that connects later. A delivery goes to the
  /// process registered under the service's name on that node.
  Distributed

  /// A set the caller supplies and changes. Nothing is learned from the VM,
  /// and `meet` introduces a peer that has just connected. The protocol tests
  /// use it to run two services in one VM.
  Supplied(reach: fn() -> List(Reach))
}

/// How a service starts.
pub type Config {
  Config(
    /// The opened ledger file.
    store: Store,
    /// The ledger the file replayed to.
    ledger: Ledger,
    /// The authority's verifier, as `membership_signing` builds it.
    verifier: Verifier,
    /// Functions told of each observation, in order.
    observers: List(Observer),
    /// Where peers come from.
    peers: Peers,
    /// The name a peer addresses first contact to. `default_name` in
    /// production.
    name: Name(Message),
    /// Milliseconds between heads sent to every peer.
    tick_ms: Int,
    /// Milliseconds a pull waits for its entries.
    pull_within_ms: Int,
    /// This node's clock for the age of a report. It is never sent.
    now_ms: fn() -> Int,
    /// Where refusals and timeouts are logged.
    logger: Logger,
  )
}

/// Why a service did not start.
pub type StartError {
  /// The name is already registered, or the machine would not start.
  NotStarted(reason: String)
}

/// A running service.
pub opaque type Service {
  Service(control: Subject(Event), wire: Subject(Message), pid: Pid)
}

/// The service could not be reached in time.
pub type Unreachable {
  Unreachable
}

// --- the machine ------------------------------------------------------------------

// Quiet and Pulling are the phases of an exchange. Pulling carries the peer
// being pulled from and where to send its next request, and neither changes
// while the machine stays in the phase, which is what lets the phase own the
// deadline.
type Phase {
  Quiet
  Pulling(source: String, via: Subject(Message))
}

// What the machine handles. `Wire` is a peer's message. `Delivered` is the
// answer to a pull. `Changed` is a node-up or node-down from the VM. The rest
// are local.
type Event {
  Start
  Tick
  Wire(Message)
  Delivered(Entries)
  Changed(ffi_nodes.Change)
  Met(Reach)
  PullTimedOut
  Offer(line: BitArray, reply: Subject(Offered))
  ReadHead(reply: Subject(membership_ledger.Head))
  Read(after: Int, limit: Int, reply: Subject(Entries))
  ReadStatus(reply: Subject(Status))
}

type Data {
  Data(
    store: Store,
    ledger: Ledger,
    verifier: Verifier,
    observers: List(Observer),
    peers: Peers,
    name: Name(Message),
    pull_within_ms: Int,
    tick_ms: Int,
    now_ms: fn() -> Int,
    logger: Logger,
    wire: Subject(Message),
    answers: Subject(Entries),
    last_refusal: Option(Rejected),
    reported: Dict(String, Report),
  )
}

type Report {
  Report(seq: Int, id: BitArray, at: Int)
}

// What a `Head` asks of this node.
type Plan {
  // The peer holds nothing this node lacks.
  Nothing

  // The peer is ahead: ask for everything after this sequence number.
  CatchUp(after: Int)

  // The peer is at this node's sequence number with another identity: ask for
  // that one entry, so the refusal that follows records the fork.
  Compare(after: Int)
}

/// The production name, `loom_ledger`, for a daemon to register under and for
/// peers to address.
///
/// ## Examples
///
/// ```gleam
/// ledger_service.default_name() == ledger_service.default_name()
/// ```
pub fn default_name() -> Name(Message) {
  ffi_remote.fixed_name(wire_name)
}

/// A configuration for a service in production: peers from the VM, the fixed
/// name, the documented tick and pull deadline and the real clock.
///
/// ## Examples
///
/// ```gleam
/// ledger_service.configuration(store, ledger, verifier, [], logger)
/// ```
pub fn configuration(
  store: Store,
  ledger: Ledger,
  verifier: Verifier,
  observers: List(Observer),
  logger: Logger,
) -> Config {
  Config(
    store:,
    ledger:,
    verifier:,
    observers:,
    peers: Distributed,
    name: default_name(),
    tick_ms: default_tick_ms,
    pull_within_ms: default_pull_within_ms,
    now_ms: bootstrap.monotonic_time_ms,
    logger:,
  )
}

/// Starts the process, linked to the caller. The observers have seen `Loaded`
/// by the time this returns.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(service) = ledger_service.start(config)
/// ```
pub fn start(config: Config) -> Result(Service, StartError) {
  sm.new_with_initialiser(5000, fn(control) { initialise(config, control) })
  |> sm.on_event(handle)
  |> sm.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(error) { NotStarted(describe_start(error)) })
}

fn describe_start(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "the ledger process did not initialise in time"
    actor.InitFailed(reason) -> reason
    actor.InitExited(_) -> "the ledger process exited while starting"
  }
}

fn initialise(
  config: Config,
  control: Subject(Event),
) -> Result(sm.Initialised(Phase, Data, Event, Service), String) {
  let wire = process.new_subject()
  let answers = process.new_subject()
  let pid = process.self()
  use Nil <- result.try(
    process.register(pid, config.name)
    |> result.replace_error("the name `loom_ledger` is already registered"),
  )
  use Nil <- result.try(watch(config.peers))
  let data =
    Data(
      store: config.store,
      ledger: config.ledger,
      verifier: config.verifier,
      observers: config.observers,
      peers: config.peers,
      name: config.name,
      pull_within_ms: config.pull_within_ms,
      tick_ms: config.tick_ms,
      now_ms: config.now_ms,
      logger: config.logger,
      wire:,
      answers:,
      last_refusal: None,
      reported: dict.new(),
    )
  tell(data, Loaded(ledger: config.ledger))
  let selector =
    process.new_selector()
    |> process.select(control)
    |> process.select_map(process.named_subject(config.name), Wire)
    |> process.select_map(wire, Wire)
    |> process.select_map(answers, Delivered)
    |> ffi_nodes.select_changes(Changed)
  Ok(
    sm.initialised(Quiet, data)
    |> sm.selecting(selector)
    |> sm.returning(Service(control:, wire:, pid:))
    |> sm.continuing(Start),
  )
}

// A process asks the VM for node-up notices only when its peers are the VM's.
fn watch(peers: Peers) -> Result(Nil, String) {
  case peers {
    Distributed ->
      ffi_nodes.watch()
      |> result.replace_error("the VM would not report node changes")
    Supplied(_) -> Ok(Nil)
  }
}

// --- talking to a running service ----------------------------------------------------

/// The subject a peer sends its first `Head` to. In production a peer reaches
/// the process by its registered name; a test that supplies its own peers
/// sends here.
///
/// ## Examples
///
/// ```gleam
/// process.send(ledger_service.wire(service), Head(seq: 3, id:, from:))
/// ```
pub fn wire(service: Service) -> Subject(Message) {
  service.wire
}

/// The process, for a caller that links to or monitors it.
///
/// ## Examples
///
/// ```gleam
/// process.is_alive(ledger_service.pid(service))
/// ```
pub fn pid(service: Service) -> Pid {
  service.pid
}

fn ask(
  service: Service,
  within_ms: Int,
  make: fn(Subject(reply)) -> Event,
) -> Result(reply, Unreachable) {
  let reply = process.new_subject()
  process.send(service.control, make(reply))
  process.receive(reply, within_ms) |> result.replace_error(Unreachable)
}

/// Offers one line, as an operator's tool or a test does, and waits for the
/// verdict. A line that is applied is announced to every connected peer.
///
/// ## Examples
///
/// ```gleam
/// ledger_service.offer(service, line, 5000) // -> Ok(Accepted(head))
/// ```
pub fn offer(
  service: Service,
  line: BitArray,
  within_ms: Int,
) -> Result(Offered, Unreachable) {
  ask(service, within_ms, Offer(line, _))
}

/// The head of the ledger.
///
/// ## Examples
///
/// ```gleam
/// ledger_service.head(service, 1000) // -> Ok(Head(seq: 3, ..))
/// ```
pub fn head(
  service: Service,
  within_ms: Int,
) -> Result(membership_ledger.Head, Unreachable) {
  ask(service, within_ms, ReadHead)
}

/// The entries after `after`, clamped like a peer's `Pull`. It is the local
/// twin of `Pull` that the operator's tool reads before it signs.
///
/// ## Examples
///
/// ```gleam
/// ledger_service.entries(service, 7, 64, 1000)
/// // -> Ok(Entries(lines: [line8], head_seq: 8))
/// ```
pub fn entries(
  service: Service,
  after: Int,
  limit: Int,
  within_ms: Int,
) -> Result(Entries, Unreachable) {
  ask(service, within_ms, Read(after, limit, _))
}

/// The ledger, the last refusal and the heads peers reported.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(status) = ledger_service.status(service, 1000)
/// ```
pub fn status(service: Service, within_ms: Int) -> Result(Status, Unreachable) {
  ask(service, within_ms, ReadStatus)
}

/// Sends this node's head to every connected peer now, as each tick does.
///
/// ## Examples
///
/// ```gleam
/// ledger_service.announce(service)
/// ```
pub fn announce(service: Service) -> Nil {
  process.send(service.control, Tick)
}

/// Introduces a peer that has just connected, as a node-up does: the process
/// sends it a `Head`.
///
/// ## Examples
///
/// ```gleam
/// ledger_service.meet(service, Reach(node: "b", deliver: send_to_b))
/// ```
pub fn meet(service: Service, reach: Reach) -> Nil {
  process.send(service.control, Met(reach))
}

// --- handling events ----------------------------------------------------------------

fn handle(
  phase: Phase,
  data: Data,
  event: Event,
) -> sm.Next(Phase, Data, Event) {
  case event {
    // The first event, handled before anything in the mailbox. The tick is
    // armed here and nowhere else, so it belongs to the machine and not to a
    // phase.
    Start -> {
      broadcast(data, except: None)
      sm.keep(data)
      |> sm.with_periodic_timeout(
        name: "tick",
        every: data.tick_ms,
        sending: Tick,
      )
    }

    Tick -> {
      broadcast(data, except: None)
      sm.keep(data)
    }

    Met(reach) -> met(data, reach)
    Changed(change) -> changed(phase, data, change)
    Wire(message) -> wired(phase, data, message)
    Delivered(entries) -> delivered(phase, data, entries)
    PullTimedOut -> timed_out(phase, data)

    Offer(line:, reply:) -> {
      let #(data, offered) = offer_line(data, line)
      process.send(reply, offered)
      case offered {
        Accepted(_) -> broadcast(data, except: None)
        AlreadyHeld | Behind(_) | Refused(_) | NotDurable(_) -> Nil
      }
      sm.keep(data)
    }

    ReadHead(reply:) -> {
      process.send(reply, membership_ledger.head(data.ledger))
      sm.keep(data)
    }

    Read(after:, limit:, reply:) -> {
      process.send(reply, entries_after(data, after, limit))
      sm.keep(data)
    }

    ReadStatus(reply:) -> {
      process.send(reply, status_of(data))
      sm.keep(data)
    }
  }
}

// A peer connected: the observers may judge it, and it is told the head.
fn met(data: Data, reach: Reach) -> sm.Next(Phase, Data, Event) {
  tell(data, Connected(node: reach.node))
  send_head(data, reach)
  sm.keep(data)
}

// A node joined or left the VM's distribution. Only the drop of the peer being
// pulled from changes the phase: waiting out the deadline for entries that
// cannot come would hold every other peer's head back.
fn changed(
  phase: Phase,
  data: Data,
  change: ffi_nodes.Change,
) -> sm.Next(Phase, Data, Event) {
  case change {
    ffi_nodes.Joined(node:) -> met(data, reach_of(data, node))
    ffi_nodes.Garbled -> sm.keep(data)
    ffi_nodes.Parted(node:) ->
      case phase {
        Quiet -> sm.keep(data)
        Pulling(source:, ..) ->
          case source == ffi_nodes.name(node) {
            True -> sm.transition(to: Quiet, data:)
            False -> sm.keep(data)
          }
      }
  }
}

// The deadline of the pull that made the machine Pulling. A fire in Quiet
// cannot be handled, because leaving Pulling cancels the state timeout, so
// the Quiet arm only keeps the match total.
fn timed_out(phase: Phase, data: Data) -> sm.Next(Phase, Data, Event) {
  case phase {
    Quiet -> sm.keep(data)
    Pulling(source:, ..) -> {
      log.warn(data.logger, "ledger.pull_timed_out", [
        field.text("node", source),
      ])
      sm.transition(to: Quiet, data:)
    }
  }
}

fn wired(
  phase: Phase,
  data: Data,
  message: Message,
) -> sm.Next(Phase, Data, Event) {
  case message {
    Pull(after:, limit:, reply:) -> {
      process.send(reply, entries_after(data, after, limit))
      sm.keep(data)
    }

    Head(seq:, id:, from:) ->
      case phase {
        Quiet -> heard(data, seq, id, from)

        // A head that would start another pull waits for this one to end and
        // is judged again then, against the head the pull produced. A head
        // that asks nothing is only recorded.
        Pulling(..) ->
          case plan(data, seq, id) {
            Nothing -> sm.keep(remember(data, seq, id, from))
            CatchUp(_) | Compare(_) -> sm.keep(data) |> sm.postpone
          }
      }
  }
}

// A head heard while Quiet: recorded, and answered with a pull when the peer
// holds something this node lacks.
fn heard(
  data: Data,
  seq: Int,
  id: BitArray,
  from: Subject(Message),
) -> sm.Next(Phase, Data, Event) {
  let data = remember(data, seq, id, from)
  case plan(data, seq, id) {
    Nothing -> sm.keep(data)
    CatchUp(after:) -> pull(data, from, after, max_batch)
    Compare(after:) -> pull(data, from, after, 1)
  }
}

// Asks the peer behind `via` for lines and waits, Pulling, for the answer. A
// peer whose inbox has no owner cannot be named, so it is not asked.
fn pull(
  data: Data,
  via: Subject(Message),
  after: Int,
  limit: Int,
) -> sm.Next(Phase, Data, Event) {
  case owner_of(via) {
    Error(Nil) -> sm.keep(data)
    Ok(source) -> {
      process.send(via, Pull(after:, limit:, reply: data.answers))
      sm.transition(to: Pulling(source:, via:), data:)
      |> sm.with_state_timeout(
        after: data.pull_within_ms,
        sending: PullTimedOut,
      )
    }
  }
}

// The node a peer's inbox lives on, which names the peer. A subject with no
// owner process cannot be pulled from or recorded.
fn owner_of(from: Subject(Message)) -> Result(String, Nil) {
  process.subject_owner(from) |> result.map(ffi_nodes.owner_name)
}

fn remember(
  data: Data,
  seq: Int,
  id: BitArray,
  from: Subject(Message),
) -> Data {
  case owner_of(from) {
    Error(Nil) -> data
    Ok(node) ->
      Data(
        ..data,
        reported: dict.insert(
          data.reported,
          node,
          Report(seq:, id:, at: data.now_ms()),
        ),
      )
  }
}

// What a peer's head asks of this node. Only the head's sequence number and
// identity are compared; the entries themselves are checked when they arrive.
fn plan(data: Data, seq: Int, id: BitArray) -> Plan {
  let ours = membership_ledger.head(data.ledger)
  case int.compare(seq, ours.seq) {
    order.Gt -> CatchUp(after: ours.seq)
    order.Lt -> Nothing
    order.Eq ->
      case id == membership_entry.id_to_bytes(ours.id) {
        True -> Nothing
        False -> Compare(after: seq - 1)
      }
  }
}

// Entries arrived. They are applied whoever sent them, because the signature
// and the chain are the trust. While Pulling, the head having moved and the
// peer having more asks for the next batch; a batch that moved nothing ends
// the exchange, which is what stops a peer that answers with old or invalid
// lines from holding the machine in a loop.
fn delivered(
  phase: Phase,
  data: Data,
  entries: Entries,
) -> sm.Next(Phase, Data, Event) {
  let before = membership_ledger.head(data.ledger).seq
  let data = apply_lines(data, list.take(entries.lines, max_batch))
  let after = membership_ledger.head(data.ledger).seq
  let moved = after > before
  case phase {
    Quiet -> {
      spread(data, from: before, to: after, except: None)
      sm.keep(data)
    }

    Pulling(source:, via:) -> {
      spread(data, from: before, to: after, except: Some(source))
      case moved && entries.head_seq > after {
        True -> {
          process.send(via, Pull(after:, limit: max_batch, reply: data.answers))
          sm.keep(data)
          |> sm.with_state_timeout(
            after: data.pull_within_ms,
            sending: PullTimedOut,
          )
        }
        False -> sm.transition(to: Quiet, data:)
      }
    }
  }
}

// Lines in order, up to the first that cannot be applied. A line already held
// is skipped, since an offer may have raced the pull.
fn apply_lines(data: Data, lines: List(BitArray)) -> Data {
  case lines {
    [] -> data
    [line, ..rest] -> {
      let #(data, offered) = offer_line(data, line)
      case offered {
        Accepted(_) | AlreadyHeld -> apply_lines(data, rest)
        Behind(_) | Refused(_) | NotDurable(_) -> data
      }
    }
  }
}

// The acceptance procedure for one line, with its effects. The order is the
// point: the fold decides, the file takes the line, and only then do the
// observers and the ledger in memory move. A line the file cannot take leaves
// the node exactly as it was, so what a peer hears is never ahead of the disk.
fn offer_line(data: Data, line: BitArray) -> #(Data, Offered) {
  case membership_entry.read(line, data.verifier) {
    Error(error) ->
      refuse(data, None, membership_ledger.Unreadable(error: error))
    Ok(signed) ->
      case membership_ledger.apply(data.ledger, signed) {
        Error(refusal) -> refuse(data, refused_seq(data, refusal), refusal)
        Ok(membership_ledger.Duplicate) -> #(data, AlreadyHeld)
        Ok(membership_ledger.Gap(head:)) -> #(data, Behind(head:))
        Ok(membership_ledger.Applied(ledger:, entry:)) ->
          extend(data, ledger, entry)
      }
  }
}

fn extend(data: Data, ledger: Ledger, entry: SignedEntry) -> #(Data, Offered) {
  case membership_store.append(data.store, entry) {
    Error(membership_store.Unwritable(reason:)) -> {
      log.error(data.logger, "ledger.not_durable", [
        field.count("seq", entry.entry.seq),
        field.text("reason", reason),
      ])
      #(data, NotDurable(reason:))
    }
    Ok(store) -> {
      let data = Data(..data, store:, ledger:)
      log.info(data.logger, "ledger.applied", [
        field.count("seq", entry.entry.seq),
      ])
      tell(data, Extended(ledger:, entry:))
      #(data, Accepted(head: membership_ledger.head(ledger)))
    }
  }
}

// The sequence number a refused line claimed, when the claim is known. An
// unreadable line has none; a chain or fold failure is at the successor of
// the head, since the procedure reaches those steps only there.
fn refused_seq(data: Data, refusal: membership_ledger.Refusal) -> Option(Int) {
  case refusal {
    membership_ledger.Unreadable(..) -> None
    membership_ledger.Fork(seq:, ..) -> Some(seq)
    membership_ledger.Chain | membership_ledger.Invalid(..) ->
      Some(membership_ledger.head(data.ledger).seq + 1)
  }
}

// Records the refusal in place of the last one, and logs it. Nothing else
// changes: a refusal never makes the node refuse the next line.
fn refuse(
  data: Data,
  seq: Option(Int),
  refusal: membership_ledger.Refusal,
) -> #(Data, Offered) {
  log.warn(data.logger, "ledger.refused", [
    field.text("step", membership_ledger.step(refusal)),
    ..seq_field(seq)
  ])
  #(
    Data(..data, last_refusal: Some(Rejected(seq:, refusal:))),
    Refused(refusal:),
  )
}

fn seq_field(seq: Option(Int)) -> List(Field) {
  case seq {
    Some(seq) -> [field.count("seq", seq)]
    None -> []
  }
}

// --- the peers --------------------------------------------------------------------------

fn reaches(data: Data) -> List(Reach) {
  case data.peers {
    Distributed -> list.map(ffi_nodes.connected(), reach_of(data, _))
    Supplied(reach:) -> reach()
  }
}

fn reach_of(data: Data, node: Node) -> Reach {
  let name = data.name
  Reach(node: ffi_nodes.name(node), deliver: fn(message) {
    ffi_remote.send(to: node, name:, message:)
  })
}

fn send_head(data: Data, reach: Reach) -> Nil {
  let head = membership_ledger.head(data.ledger)
  reach.deliver(Head(
    seq: head.seq,
    id: membership_entry.id_to_bytes(head.id),
    from: data.wire,
  ))
}

// The head to every connected peer but one. The one is the peer the news came
// from, which already has it.
fn broadcast(data: Data, except source: Option(String)) -> Nil {
  list.each(reaches(data), fn(reach) {
    case Some(reach.node) == source {
      True -> Nil
      False -> send_head(data, reach)
    }
  })
}

// A head is announced only when the ledger moved.
fn spread(
  data: Data,
  from before: Int,
  to after: Int,
  except source: Option(String),
) -> Nil {
  case after > before {
    True -> broadcast(data, except: source)
    False -> Nil
  }
}

fn tell(data: Data, observation: Observation) -> Nil {
  list.each(data.observers, fn(observer) { observer(observation) })
}

fn entries_after(data: Data, after: Int, limit: Int) -> Entries {
  Entries(
    lines: membership_store.lines_after(
      data.store,
      after,
      int.clamp(limit, min: 1, max: max_batch),
      max_reply_bytes,
    ),
    head_seq: membership_ledger.head(data.ledger).seq,
  )
}

fn status_of(data: Data) -> Status {
  let now = data.now_ms()
  Status(
    ledger: data.ledger,
    last_refusal: data.last_refusal,
    reported: dict.to_list(data.reported)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.map(fn(entry) {
        let #(node, report) = entry
        Reported(
          node:,
          seq: report.seq,
          id: report.id,
          ms_since: now - report.at,
        )
      }),
  )
}

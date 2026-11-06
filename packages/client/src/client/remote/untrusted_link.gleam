//// The orchestrator's end of the link to one untrusted executor
//// (protocol-change/109).
////
//// A trusted executor is an Erlang peer, and the orchestrator's surface sends
//// `HostMessage`s to its host by name across distribution. An untrusted
//// executor is never a peer. This process stands where its host would be: it
//// registers a name on the orchestrator's own node, takes the same
//// `HostMessage`s the surface would send across, and carries them over one TLS
//// connection it dialled, as frames of `client/remote/untrusted_wire`. The
//// surface, the scope record and the owner port cannot tell the difference,
//// because the address they hold names this process and the replies arrive on
//// their own subjects as before.
////
//// ## What it keeps
////
//// - **Outstanding requests**, by an id this process mints and never reuses,
////   each with its encoded bytes, its typed reply subject and a monitor on the
////   process that asked. A response is decoded against the kind of reply its
////   request waits for, and handed to that subject. The death of the asker
////   removes the request and, on a live connection, sends `cancel`, which the
////   executor turns into the same abort a trusted host sees.
//// - **Bindings**: the random bytes minted for each attach in place of the
////   owner port's subject, with the session, the port and the highest
////   callback id accepted. A binding retires when its session attaches again,
////   when its owner port dies, and on a successful close.
////
//// ## Re-sending
////
//// Every request the link carries is idempotent by key, token or offset, and
//// 078's surface already re-sends after a lost connection. So the link keeps
//// each request's bytes and sends every outstanding one again on the next
//// connection, and the surface's own repair loop runs only if this process
//// dies. While there is an outstanding request or a live binding and no
//// connection, it redials with a pause that doubles from 50 ms to 2 s.
////
//// ## Callbacks
////
//// The executor names a binding on each callback. A callback reaches the
//// owner port only if the binding is one this link minted and has not
//// retired, its id is greater than any accepted on the binding, the call it
//// names is a `run` this link has in flight for the binding's session (for an
//// escalation, a capability, a tool-list check and a tail), and the binding
//// and the link are under their bounds. Otherwise it is answered with the
//// failure its type allows and logged. An accepted callback runs in a weft
//// task against the owner port, so the link never waits on an owner.
////
//// ## Violations
////
//// A frame that does not decode, a response for an id the link never issued,
//// a response of the wrong kind, and any frame an orchestrator does not accept
//// close the connection. The outstanding requests stay and are sent again on
//// the next one.
////
//// ## Flow
////
//// `start` → `name_for` → `address` → `running` → `handle` → `received` →
//// `admitted`
////
//// 1. `start` registers the name and starts the machine idle; `name_for` is
////    the production name, `address` the `Address` a session's `Reach` holds
////    and `running` the function the `Reach` reconnects with.
//// 2. `handle` is the machine's event handler: a `HostMessage` becomes an
////    outstanding request, a dial's result opens or rests the connection, and
////    a frame goes to `received`.
//// 3. `received` dispatches one executor frame, and `admitted` is the check
////    every callback passes before an owner sees it.
////
//// <!-- transitions: untrusted_link.Phase -->
//// | From | Event | To |
//// | --- | --- | --- |
//// | `Idle` | a request to send, or a binding to keep | `Dialing` |
//// | `Dialing` | the dial lands, or fails | `Greeting`, or `Resting` |
//// | `Greeting` | a welcome of the same versions, or anything else and ten seconds of silence | `Open`, or `Resting` |
//// | `Open` | the connection ends or a violation | `Resting` |
//// | `Resting` | the pause ends | `Dialing` or `Idle` |

import broker/broker
import broker/internal/ffi_crypto
import client/internal/ffi_remote
import client/internal/ffi_tls_stream.{type Stream}
import client/remote/address.{type Address}
import client/remote/protocol.{type HostMessage, type OwnerMessage}
import client/remote/remote_census.{type RemoteCensus}
import client/remote/untrusted_bridge.{type Reply}
import client/remote/untrusted_codec
import client/remote/untrusted_wire.{type Answer, type Callback, type Request}
import core/corruption
import core/ids
import core/json
import gleam/dict.{type Dict}
import gleam/erlang/node
import gleam/erlang/process.{type Monitor, type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import runtime/effects
import telemetry/field
import telemetry/log.{type Logger}
import weft
import weft/state_machine as sm

/// How to reach one untrusted executor.
pub type Config {
  Config(
    /// The executor's name in `[executors]`, for logs.
    executor: String,
    /// The name this process registers on the local node, which the session's
    /// `Reach` addresses. Made once per configured executor.
    name: Name(HostMessage(RemoteCensus)),
    /// The executor's listener host.
    host: String,
    /// The executor's listener port.
    port: Int,
    /// The SHA-256 of the executor's leaf certificate.
    pin: BitArray,
    /// This orchestrator's certificate, key and authority.
    credentials: ffi_tls_stream.Credentials,
    /// Mints a binding: `strong_binding` in production, a counter in a test.
    mint: fn() -> BitArray,
    /// Where violations, refusals and connection changes are logged.
    logger: Logger,
  )
}

/// Whether the link has a connection, and how far its handshake has got.
pub type Phase {
  /// No connection, and nothing waits for one.
  Idle

  /// A dial is running.
  Dialing

  /// Connected; `hello` sent and `welcome` awaited.
  Greeting(stream: Stream)

  /// Connected and greeted: requests and callbacks flow.
  Open(stream: Stream)

  /// The last connection failed; the pause runs before the next dial.
  Resting
}

/// What the link receives.
pub opaque type Message {
  /// A `HostMessage` a session sent to the registered name.
  Host(message: HostMessage(RemoteCensus))

  /// A dial's run reported.
  Dialed(pulled: weft.Pulled(Stream, ffi_tls_stream.Failure))

  /// The connection delivered something.
  Inbound(inbound: ffi_tls_stream.Inbound)

  /// A monitored asker or owner port went down.
  Down(down: process.Down)

  /// A callback's forwarding task reported.
  Forwarded(
    binding: BitArray,
    id: Int,
    callback: Callback,
    pulled: weft.Pulled(Option(Answer), Nil),
  )

  /// The greeting took too long.
  GreetingExpired

  /// The pause before a redial ended.
  PauseEnded
}

/// The machine's data.
type Data {
  Data(
    config: Config,
    /// The local subject the machine's own events arrive on.
    dials: Subject(weft.Pulled(Stream, ffi_tls_stream.Failure)),
    /// The handle an attach's census gets in place of the plane's broker.
    broker: Subject(broker.Msg),
    /// The next request id.
    next_id: Int,
    /// Requests sent or waiting to be sent, by id.
    outstanding: Dict(Int, Pending),
    /// Live bindings, by their bytes.
    bindings: Dict(BitArray, Binding),
    /// Each session's current binding.
    sessions: Dict(String, BitArray),
    /// What each monitor watches.
    watched: Dict(Monitor, Watched),
    /// Callbacks being answered by an owner, each with its task's sink.
    forwarding: Dict(#(BitArray, Int), Forwarding),
    /// The pause before the next redial.
    pause_ms: Int,
  )
}

/// One request the link holds.
type Pending {
  Pending(
    /// The request, for the callback checks.
    request: Request,
    /// The encoded frame, sent again on each new connection.
    frame: BitArray,
    /// Where the response goes.
    reply: Reply,
    /// The monitor on the asker, when it could be found.
    monitor: Option(Monitor),
  )
}

/// Whether a forwarded callback has been answered on the wire yet.
type Answering {
  /// The owner has not answered.
  Unanswered

  /// The answer, or the failure for a lost task, has been sent.
  Answered
}

/// One binding the link minted.
type Binding {
  Binding(
    /// The session it was minted for.
    session: String,
    /// That session's owner port.
    port: Subject(OwnerMessage),
    /// The monitor on the owner port.
    monitor: Option(Monitor),
    /// The highest callback id accepted.
    last_id: Int,
    /// Callbacks being answered now.
    open: Int,
  )
}

/// One callback an owner is answering.
type Forwarding {
  Forwarding(
    /// The callback, for the failure it is answered with if its task fails.
    callback: Callback,
    /// Where its task reports.
    sink: Subject(weft.Pulled(Option(Answer), Nil)),
    /// Whether its answer has gone out.
    answering: Answering,
  )
}

/// What a monitor is for.
type Watched {
  /// The process that sent request `id`.
  Asker(id: Int)

  /// The owner port of `binding`.
  Port(binding: BitArray)
}

/// The most requests one link holds. Beyond it a request is refused at once,
/// so a session that floods the link cannot grow it without bound.
pub const max_outstanding = 1024

/// The most callbacks one binding has with an owner at once.
pub const max_binding_callbacks = 64

/// The most callbacks one link has with owners at once.
pub const max_link_callbacks = 1024

// How long a dial and its TLS handshake may take.
const dial_within_ms = 10_000

// How long the executor has to answer `hello`.
const greeting_ms = 10_000

// The first and the longest pause between dials.
const first_pause_ms = 50

const longest_pause_ms = 2000

/// Sixteen bytes from the operating system's strong source, for a binding.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_link.Config(.., mint: untrusted_link.strong_binding)
/// ```
pub fn strong_binding() -> BitArray {
  ffi_crypto.strong_random_bytes(untrusted_wire.binding_bytes)
}

/// Starts the link, registered under `config.name`, idle until the first
/// request arrives. It is linked to the caller.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(pid) = untrusted_link.start(config)
/// ```
pub fn start(config: Config) -> Result(Pid, String) {
  sm.new_with_initialiser(1000, fn(_subject) { initialise(config) })
  |> sm.on_event(handle)
  |> sm.start
  |> result.map(fn(started) { started.pid })
  |> result.map_error(fn(_error) {
    "the link to executor " <> config.executor <> " did not start"
  })
}

/// The address a session's `Reach` holds for this executor: the link's name
/// on this node.
///
/// ## Examples
///
/// ```gleam
/// // workspace.Reach(address: untrusted_link.address(untrusted_link.name_for("review-pod")), ..)
/// ```
pub fn address(
  name: Name(HostMessage(RemoteCensus)),
) -> Address(HostMessage(RemoteCensus)) {
  address.Address(node: node.self(), name:)
}

/// The name the link to `executor` registers in production. An executor's
/// name is the operator's, from `[executors.<name>]`, checked against the
/// executor grammar and read once at start, so the atoms made here are as few
/// as the configured executors and none comes from a peer.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_link.name_for("review-pod")
/// ```
pub fn name_for(executor: String) -> Name(HostMessage(RemoteCensus)) {
  ffi_remote.fixed_name("loom_untrusted_executor_" <> executor)
}

/// The `connect` of a session's `Reach`. The link dials by itself whenever it
/// has work, so reaching the executor means only that the link is running;
/// the surface calls this after the link's `DOWN`.
///
/// ## Examples
///
/// ```gleam
/// // workspace.Reach(.., connect: fn() { untrusted_link.running(name, "review-pod") })
/// ```
pub fn running(
  name: Name(HostMessage(RemoteCensus)),
  executor: String,
) -> Result(Nil, String) {
  // A name with no process behind it is a link that is not running.
  case process.named(name) {
    Ok(_pid) -> Ok(Nil)
    Error(Nil) ->
      Error("the link to executor " <> executor <> " is not running")
  }
}

/// Registers the name, makes the refusing broker handle and the dial sink,
/// and starts idle.
fn initialise(
  config: Config,
) -> Result(sm.Initialised(Phase, Data, Message, Nil), String) {
  use Nil <- result.try(
    process.register(process.self(), config.name)
    |> result.map_error(fn(_taken) { "the link's name is already registered" }),
  )
  use broker <- result.try(refusing_broker())
  let dials = process.new_subject()
  let data =
    Data(
      config:,
      dials:,
      broker:,
      next_id: 1,
      outstanding: dict.new(),
      bindings: dict.new(),
      sessions: dict.new(),
      watched: dict.new(),
      forwarding: dict.new(),
      pause_ms: first_pause_ms,
    )
  Ok(sm.initialised(Idle, data) |> sm.selecting(selector_of(data)))
}

/// A broker subject whose owner has already exited. `broker.clear_call` makes
/// a monitored call, so every call on it is refused as unavailable at once;
/// that is how the commands non-tool callers would run through the executor's
/// broker are refused on an untrusted executor in slice 1.
fn refusing_broker() -> Result(Subject(broker.Msg), String) {
  let handed = process.new_subject()
  process.spawn(fn() { process.send(handed, process.new_subject()) })
  process.receive(handed, 1000)
  |> result.replace_error("the link could not make its broker handle")
}

/// Everything the machine receives: the registered name, its own sinks, its
/// monitors, the connection, and one sink per callback being forwarded.
fn selector_of(data: Data) -> process.Selector(Message) {
  let base =
    process.new_selector()
    |> process.select_map(process.named_subject(data.config.name), Host)
    |> process.select_map(data.dials, Dialed)
    |> process.select_monitors(Down)
    |> ffi_tls_stream.select(Inbound)
  dict.fold(data.forwarding, base, fn(selector, at, forwarding) {
    let #(binding, id) = at
    let callback = forwarding.callback
    process.select_map(selector, forwarding.sink, fn(pulled) {
      Forwarded(binding:, id:, callback:, pulled:)
    })
  })
}

/// The machine's event handler. Each arm names the phase an event is
/// meaningful in; an event that arrives in any other phase is stale (the
/// connection it belonged to is gone) and changes nothing.
fn handle(
  phase: Phase,
  data: Data,
  message: Message,
) -> sm.Next(Phase, Data, Message) {
  // A request is taken in every phase, and a monitor or a forwarder reports
  // whatever the connection is doing; the rest belong to one phase each.
  case phase, message {
    _, Host(message:) -> hosted(phase, data, message)
    Dialing, Dialed(pulled:) -> dialed(data, pulled)
    _, Dialed(pulled:) -> stale_dial(data, pulled)
    Greeting(stream:), Inbound(inbound:) -> greeted(stream, data, inbound)
    Open(stream:), Inbound(inbound:) -> received(stream, data, inbound)
    _, Inbound(..) -> sm.keep(data)
    _, Down(down:) -> went_down(phase, data, down)
    _, Forwarded(binding:, id:, callback:, pulled:) ->
      forwarded(phase, data, binding, id, callback, pulled)
    Greeting(stream:), GreetingExpired ->
      rest(stream, data, "the executor did not answer hello")
    _, GreetingExpired -> sm.keep(data)
    Resting, PauseEnded -> rested(data)
    _, PauseEnded -> sm.keep(data)
  }
}

/// A `HostMessage` from a session: answered at once if slice 1 does not carry
/// it, otherwise made an outstanding request and sent, or held for the next
/// connection.
fn hosted(
  phase: Phase,
  data: Data,
  message: HostMessage(RemoteCensus),
) -> sm.Next(Phase, Data, Message) {
  let bind = fn(session, port) { binding_for(data, session, port) }

  // An ack has no reply and is not kept: a lost one is found again by the
  // owner port's reconciler, so it goes out only on an open connection.
  case untrusted_bridge.outbound(message, bind) {
    untrusted_bridge.Answered -> sm.keep(data)
    untrusted_bridge.Send(request:, reply: None, requester: _, port: _) ->
      acked(phase, data, request)
    untrusted_bridge.Send(request:, reply: Some(reply), requester:, port:) ->
      held(phase, data, request, reply, requester, port)
  }
}

/// The binding an attach carries: the session's current one when its owner
/// port is the same, because the surface re-sends one attach while the
/// executor builds the plane and the callbacks of that build name the first
/// send's binding; a fresh one for a new port.
fn binding_for(
  data: Data,
  session: String,
  port: Subject(OwnerMessage),
) -> BitArray {
  let current =
    dict.get(data.sessions, session)
    |> result.try(fn(binding) { dict.get(data.bindings, binding) })

  // Only the same port reuses a binding; a new open's port is a new binding.
  case current {
    Ok(held) if held.port == port ->
      dict.get(data.sessions, session) |> result.lazy_unwrap(data.config.mint)
    Ok(_other) | Error(Nil) -> data.config.mint()
  }
}

/// Sends an ack if the connection is open, under an id of its own.
fn acked(
  phase: Phase,
  data: Data,
  request: Request,
) -> sm.Next(Phase, Data, Message) {
  let id = data.next_id
  let data = Data(..data, next_id: id + 1)

  // An ack that cannot go now is dropped; see `hosted`.
  case phase {
    Open(stream:) ->
      sent(stream, data, encoded(untrusted_wire.Request(id:, request:)))
    Idle | Dialing | Greeting(..) | Resting -> sm.keep(data)
  }
}

/// Keeps a request until its response, sending it now when the connection is
/// open and dialling when the link is idle.
fn held(
  phase: Phase,
  data: Data,
  request: Request,
  reply: Reply,
  requester: Option(Pid),
  port: Option(#(String, Subject(OwnerMessage))),
) -> sm.Next(Phase, Data, Message) {
  // A full link refuses rather than grows, in the type the asker waits for.
  case dict.size(data.outstanding) >= max_outstanding {
    True -> {
      untrusted_bridge.refuse(
        reply,
        protocol.Unreachable(
          "the link to executor "
          <> data.config.executor
          <> " holds too many requests",
        ),
      )
      sm.keep(data)
    }
    False -> queued(phase, data, request, reply, requester, port)
  }
}

/// Records the request, its asker's monitor and an attach's binding, then
/// sends it or waits for a connection.
fn queued(
  phase: Phase,
  data: Data,
  request: Request,
  reply: Reply,
  requester: Option(Pid),
  port: Option(#(String, Subject(OwnerMessage))),
) -> sm.Next(Phase, Data, Message) {
  let id = data.next_id
  let frame = encoded(untrusted_wire.Request(id:, request:))
  let #(data, monitor) = watch(data, requester, Asker(id))
  let data = bound(data, request, port)
  let pending = Pending(request:, frame:, reply:, monitor:)
  let data =
    Data(
      ..data,
      next_id: id + 1,
      outstanding: dict.insert(data.outstanding, id, pending),
    )

  // An open link sends now; an idle one dials; the others send everything on
  // the next welcome.
  case phase {
    Open(stream:) -> sent(stream, data, frame)
    Idle -> dial(data)
    Dialing | Greeting(..) | Resting -> sm.keep(data)
  }
}

/// Records the binding an attach carries, retiring the session's previous one
/// when this attach has a new port.
fn bound(
  data: Data,
  request: Request,
  port: Option(#(String, Subject(OwnerMessage))),
) -> Data {
  // Only an attach carries a binding; every other request leaves the book.
  case request, port {
    untrusted_wire.AttachRequest(binding:, ..), Some(#(session, port)) ->
      case dict.get(data.sessions, session) == Ok(binding) {
        True -> data
        False -> {
          let data = retire_session(data, session)
          let #(data, monitor) =
            watch(
              data,
              process.subject_owner(port) |> option.from_result,
              Port(binding),
            )
          let held = Binding(session:, port:, monitor:, last_id: 0, open: 0)
          Data(
            ..data,
            bindings: dict.insert(data.bindings, binding, held),
            sessions: dict.insert(data.sessions, session, binding),
          )
        }
      }
    _, _ -> data
  }
}

/// Monitors `pid`, when there is one, recording what the monitor is for.
fn watch(
  data: Data,
  pid: Option(Pid),
  watched: Watched,
) -> #(Data, Option(Monitor)) {
  // A subject whose owner cannot be found has no death to read; its request
  // is answered or kept like any other.
  case pid {
    None -> #(data, None)
    Some(pid) -> {
      let monitor = process.monitor(pid)
      #(
        Data(..data, watched: dict.insert(data.watched, monitor, watched)),
        Some(monitor),
      )
    }
  }
}

/// Retires a session's current binding, if it has one.
fn retire_session(data: Data, session: String) -> Data {
  // A session that never attached through this link has nothing to retire.
  case dict.get(data.sessions, session) {
    Error(Nil) -> data
    Ok(binding) -> retire(data, binding)
  }
}

/// Retires a binding: its callbacks are refused from now on.
fn retire(data: Data, binding: BitArray) -> Data {
  // A binding already retired leaves the book as it is.
  case dict.get(data.bindings, binding) {
    Error(Nil) -> data
    Ok(held) -> {
      let data = unwatch(data, held.monitor)

      // The session forgets the binding only if it is still the current one;
      // a newer attach has already replaced it otherwise.
      let sessions = case dict.get(data.sessions, held.session) == Ok(binding) {
        True -> dict.delete(data.sessions, held.session)
        False -> data.sessions
      }

      Data(..data, bindings: dict.delete(data.bindings, binding), sessions:)
    }
  }
}

/// Drops a monitor and its record.
fn unwatch(data: Data, monitor: Option(Monitor)) -> Data {
  // Demonitoring flushes a `DOWN` that may already be queued.
  case monitor {
    None -> data
    Some(monitor) -> {
      process.demonitor_process(monitor)
      Data(..data, watched: dict.delete(data.watched, monitor))
    }
  }
}

/// Sends one frame on an open connection, resting the link when the send
/// fails. Outstanding requests stay and are sent again on the next one.
fn sent(
  stream: Stream,
  data: Data,
  frame: BitArray,
) -> sm.Next(Phase, Data, Message) {
  // A failed send is a dead connection.
  case ffi_tls_stream.send(stream, frame) {
    Ok(Nil) -> sm.keep(data)
    Error(_failure) -> rest(stream, data, "a send failed")
  }
}

/// Starts a dial in a weft run whose task connects, runs the handshake and
/// hands the stream to this process before it ends.
fn dial(data: Data) -> sm.Next(Phase, Data, Message) {
  let config = data.config
  let owner = process.self()
  let _relay =
    weft.new([
      fn() {
        use stream <- result.try(ffi_tls_stream.connect(
          config.host,
          config.port,
          config.credentials,
          config.pin,
          untrusted_wire.max_frame_bytes,
          dial_within_ms,
        ))
        ffi_tls_stream.hand_to(stream, owner)
        |> result.replace(stream)
        |> result.map_error(fn(failure) {
          ffi_tls_stream.close(stream)
          failure
        })
      },
    ])
    |> weft.deadline(dial_within_ms + 1000)
    |> weft.start_relayed(to: data.dials)
  sm.transition(to: Dialing, data:)
}

/// A dial's report while dialling: a stream starts the greeting, anything else
/// rests the link.
fn dialed(
  data: Data,
  pulled: weft.Pulled(Stream, ffi_tls_stream.Failure),
) -> sm.Next(Phase, Data, Message) {
  // Only a completed task holds a stream; every other outcome and a run lost
  // without one is a failed dial.
  case pulled {
    weft.PulledOutcome(outcome: weft.Completed(value: stream, ..)) ->
      greet(stream, data)
    weft.PulledOutcome(outcome: weft.Failed(..))
    | weft.PulledOutcome(outcome: weft.Crashed(..))
    | weft.PulledOutcome(outcome: weft.Abandoned(..))
    | weft.PulledOutcome(outcome: weft.NeverStarted(..))
    | weft.PulledOutcome(outcome: weft.DrainProofLost(..))
    | weft.PulledOutcome(outcome: weft.CancellationUnconfirmed(..))
    | weft.AllDelivered
    | weft.RunLost(..) -> resting(data, "the executor could not be reached")
    weft.NotYet -> sm.keep(data)
  }
}

/// A dial's report after the link has moved on: a stream it delivered is
/// closed, because nothing will read it.
fn stale_dial(
  data: Data,
  pulled: weft.Pulled(Stream, ffi_tls_stream.Failure),
) -> sm.Next(Phase, Data, Message) {
  // Only a delivered stream holds a resource.
  case pulled {
    weft.PulledOutcome(outcome: weft.Completed(value: stream, ..)) -> {
      ffi_tls_stream.close(stream)
      sm.keep(data)
    }
    weft.PulledOutcome(..)
    | weft.AllDelivered
    | weft.RunLost(..)
    | weft.NotYet -> sm.keep(data)
  }
}

/// Sends `hello` and waits for the executor's `welcome`.
fn greet(stream: Stream, data: Data) -> sm.Next(Phase, Data, Message) {
  let hello =
    encoded(untrusted_wire.Hello(
      wire: untrusted_wire.version,
      protocol: protocol.version,
    ))
  let armed =
    ffi_tls_stream.send(stream, hello)
    |> result.try(fn(_sent) { ffi_tls_stream.arm(stream) })

  // A connection that cannot take the greeting is already gone.
  case armed {
    Ok(Nil) ->
      sm.transition(to: Greeting(stream), data:)
      |> sm.with_state_timeout(after: greeting_ms, sending: GreetingExpired)
    Error(_failure) -> rest(stream, data, "the greeting could not be sent")
  }
}

/// The executor's first frame: a `welcome` of the same versions opens the
/// link and sends every outstanding request; anything else rests it.
fn greeted(
  stream: Stream,
  data: Data,
  inbound: ffi_tls_stream.Inbound,
) -> sm.Next(Phase, Data, Message) {
  // The envelope is read before anything is believed; a well-formed welcome
  // of other versions refuses everything that waits, because none of it can
  // be answered by this executor.
  case inbound {
    ffi_tls_stream.Received(frame:) ->
      case untrusted_codec.decode_envelope(frame) {
        Ok(untrusted_codec.WelcomeEnvelope(wire:, protocol: theirs))
          if wire == untrusted_wire.version && theirs == protocol.version
        -> opened(stream, data)
        Ok(untrusted_codec.WelcomeEnvelope(protocol: theirs, ..)) ->
          rest(
            stream,
            refuse_all(data, protocol.VersionMismatch(supported: theirs)),
            "the executor speaks another version",
          )
        Ok(_other) -> violation(stream, data, "the first frame was not welcome")
        Error(report) -> violation(stream, data, corruption.describe(report))
      }
    ffi_tls_stream.Ended | ffi_tls_stream.Broken ->
      rest(stream, data, "the connection closed during the greeting")
  }
}

/// Opens the link: every outstanding request goes out in the order it was
/// made, and the next frame is asked for.
fn opened(stream: Stream, data: Data) -> sm.Next(Phase, Data, Message) {
  let frames =
    dict.to_list(data.outstanding)
    |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
    |> list.map(fn(entry) { { entry.1 }.frame })
  let written =
    list.try_each(frames, fn(frame) { ffi_tls_stream.send(stream, frame) })
    |> result.try(fn(_sent) { ffi_tls_stream.arm(stream) })
  log.info(data.config.logger, "untrusted_link.open", [
    field.text("executor", data.config.executor),
    field.count("resent", list.length(frames)),
  ])

  // A connection that drops while the backlog goes out is rested like any
  // other; the backlog stays for the next one.
  case written {
    Ok(Nil) ->
      sm.transition(
        to: Open(stream),
        data: Data(..data, pause_ms: first_pause_ms),
      )
    Error(_failure) -> rest(stream, data, "the backlog could not be sent")
  }
}

/// Answers every outstanding request with `refusal` and forgets them.
fn refuse_all(data: Data, refusal: protocol.Refusal) -> Data {
  dict.fold(data.outstanding, data, fn(data, id, pending) {
    untrusted_bridge.refuse(pending.reply, refusal)
    let data = unwatch(data, pending.monitor)
    Data(..data, outstanding: dict.delete(data.outstanding, id))
  })
}

/// One frame from an open connection.
fn received(
  stream: Stream,
  data: Data,
  inbound: ffi_tls_stream.Inbound,
) -> sm.Next(Phase, Data, Message) {
  // An executor sends responses and callbacks and nothing else; any other
  // frame, and any frame that does not decode, closes the connection.
  case inbound {
    ffi_tls_stream.Received(frame:) ->
      case untrusted_codec.decode_envelope(frame) {
        Ok(untrusted_codec.ResponseEnvelope(id:, body:)) ->
          responded(stream, data, id, body)
        Ok(untrusted_codec.CallbackEnvelope(binding:, id:, body:)) ->
          called_back(stream, data, binding, id, body)
        Ok(untrusted_codec.HelloEnvelope(..))
        | Ok(untrusted_codec.WelcomeEnvelope(..))
        | Ok(untrusted_codec.RequestEnvelope(..))
        | Ok(untrusted_codec.CancelEnvelope(..))
        | Ok(untrusted_codec.AnswerEnvelope(..)) ->
          violation(
            stream,
            data,
            "an executor sent a frame only an orchestrator sends",
          )
        Error(report) -> violation(stream, data, corruption.describe(report))
      }
    ffi_tls_stream.Ended | ffi_tls_stream.Broken ->
      rest(stream, data, "the connection closed")
  }
}

/// A response: for an id never issued it is a violation; for one no longer
/// held (cancelled, or already answered) it is dropped; otherwise it is
/// decoded against the kind its request waits for and delivered.
fn responded(
  stream: Stream,
  data: Data,
  id: Int,
  body: json.JsonValue,
) -> sm.Next(Phase, Data, Message) {
  let issued = id >= 1 && id < data.next_id

  // A cancel and a response can cross, so a held id that is gone is not a
  // violation; an id this link never minted is.
  case issued, dict.get(data.outstanding, id) {
    False, _ -> violation(stream, data, "a response to a request never sent")
    True, Error(Nil) -> armed(stream, data)
    True, Ok(pending) ->
      case
        untrusted_codec.decode_response(
          untrusted_bridge.kind_of(pending.reply),
          body,
        )
      {
        Error(report) -> violation(stream, data, corruption.describe(report))
        Ok(response) -> {
          let _delivered =
            untrusted_bridge.deliver(pending.reply, response, data.broker)
          armed(stream, settle(data, id, pending, response))
        }
      }
  }
}

/// Forgets an answered request, and retires the binding of a scope that
/// closed.
fn settle(
  data: Data,
  id: Int,
  pending: Pending,
  response: untrusted_wire.Response,
) -> Data {
  let data = unwatch(data, pending.monitor)
  let data = Data(..data, outstanding: dict.delete(data.outstanding, id))

  // A scope that closed takes no more callbacks; any other answer leaves the
  // bindings as they are.
  case pending.request, response {
    untrusted_wire.CloseRequest(session:, ..),
      untrusted_wire.CloseAnswered(Ok(_closed))
    -> retire_session(data, session)
    _, _ -> data
  }
}

/// A callback: decoded, then checked against its binding, then either
/// answered with a refusal or handed to a task that asks the owner.
fn called_back(
  stream: Stream,
  data: Data,
  binding: BitArray,
  id: Int,
  body: json.JsonValue,
) -> sm.Next(Phase, Data, Message) {
  // A callback that does not decode is a violation; one that decodes and
  // fails a check is refused in band, because a cancel and a callback can
  // cross and an honest executor can send one late.
  case untrusted_codec.decode_callback(body) {
    Error(report) -> violation(stream, data, corruption.describe(report))
    Ok(callback) ->
      case admitted(data, binding, id, callback) {
        #(data, Error(reason)) -> {
          log.warn(data.config.logger, "untrusted_link.callback_refused", [
            field.text("executor", data.config.executor),
            field.text("reason", reason),
          ])
          answered(
            stream,
            data,
            binding,
            id,
            untrusted_bridge.refused_answer(callback, reason),
          )
        }
        #(data, Ok(port)) -> forward(stream, data, binding, id, port, callback)
      }
  }
}

/// The checks every callback passes before an owner sees it (protocol-change
/// 109, "Callbacks ride the orchestrator's connection"): the binding is held,
/// the id is fresh, the callback is about a call in flight for the binding's
/// session where it names one, and the bounds hold. A fresh id is recorded
/// even when a later check refuses, so it can never be used again.
fn admitted(
  data: Data,
  binding: BitArray,
  id: Int,
  callback: Callback,
) -> #(Data, Result(Subject(OwnerMessage), String)) {
  // The binding is looked up first, so a forged one learns nothing else.
  case dict.get(data.bindings, binding) {
    Error(Nil) -> #(data, Error("the binding is not one this link holds"))
    Ok(held) if id <= held.last_id -> #(
      data,
      Error("the callback id was already used on this binding"),
    )
    Ok(held) -> {
      let held = Binding(..held, last_id: id)
      let data =
        Data(..data, bindings: dict.insert(data.bindings, binding, held))
      #(data, checked(data, held, callback))
    }
  }
}

/// The checks after the binding and the id.
fn checked(
  data: Data,
  held: Binding,
  callback: Callback,
) -> Result(Subject(OwnerMessage), String) {
  use Nil <- result.try(about_work(data, held.session, callback))
  use Nil <- result.try(within_bounds(data, held, callback))
  Ok(held.port)
}

/// The four callbacks that name a tool call must name a `run` this link has
/// outstanding for the session, and an escalation must describe that call
/// exactly, so the operator is asked about the call the orchestrator sent.
fn about_work(
  data: Data,
  session: String,
  callback: Callback,
) -> Result(Nil, String) {
  // The other kinds are sent by background jobs after their call ended, and
  // the owner port fences them to the session.
  case callback {
    untrusted_wire.EscalateCall(refused:, ..) ->
      in_flight(data, session, fn(key, run) {
        key.op == ids.op_id_to_string(refused.operation)
        && key.step == refused.step_id
        && key.source_index == refused.source_index
        && run.strand == refused.strand
        && run.call.id == refused.call_id
        && run.call.name == refused.tool
        && run.arguments == refused.arguments
      })
    untrusted_wire.CapabilityCall(call: asked) ->
      in_flight(data, session, fn(key, run) {
        key.op == ids.op_id_to_string(asked.op_id)
        && key.step == asked.step_id
        && key.source_index == asked.source_index
        && run.strand == asked.strand
      })
    untrusted_wire.HoldsCall(caller:, ..) ->
      in_flight(data, session, fn(key, run) {
        key.op == ids.op_id_to_string(caller.operation)
        && key.step == caller.step_id
        && key.source_index == caller.source_index
        && run.strand == caller.strand
      })
    untrusted_wire.TailCast(run: tailed, ..) ->
      in_flight(data, session, fn(key, _run) {
        key == protocol.key_of(session, tailed)
      })
    untrusted_wire.FactGetCall(..)
    | untrusted_wire.FactPutCall(..)
    | untrusted_wire.FactPutBlindCall(..)
    | untrusted_wire.FactDeleteCall(..)
    | untrusted_wire.FactListCall(..)
    | untrusted_wire.NotifyCall(..)
    | untrusted_wire.StrandActivityCall(..)
    | untrusted_wire.WakeCall(..)
    | untrusted_wire.McpPlanCall
    | untrusted_wire.GitIdentityCall -> Ok(Nil)
  }
}

/// Whether a `run` of `session` that `matches` is outstanding on this link.
fn in_flight(
  data: Data,
  session: String,
  matches: fn(protocol.Key, effects.ToolRun) -> Bool,
) -> Result(Nil, String) {
  let found =
    dict.values(data.outstanding)
    |> list.any(fn(pending) {
      case pending.request {
        untrusted_wire.RunRequest(key:, run:, ..) ->
          key.session == session && matches(key, run)
        _other -> False
      }
    })

  // A callback about a call this link is not running for the session is
  // either late or forged, and in both cases it is not the owner's business.
  case found {
    True -> Ok(Nil)
    False -> Error("no call of this session in flight matches the callback")
  }
}

/// A tail is a cast and costs no forwarder; every other callback must fit
/// the binding's and the link's bounds.
fn within_bounds(
  data: Data,
  held: Binding,
  callback: Callback,
) -> Result(Nil, String) {
  let crowded =
    held.open >= max_binding_callbacks
    || dict.size(data.forwarding) >= max_link_callbacks

  // Only callbacks with an answer hold a forwarder.
  case untrusted_wire.answer_kind(callback), crowded {
    None, _ -> Ok(Nil)
    Some(_kind), False -> Ok(Nil)
    Some(_kind), True -> Error("too many callbacks are waiting for the owner")
  }
}

/// Hands an admitted callback to its owner: a tail at once, anything else in
/// a weft task whose answer comes back as `Forwarded`.
fn forward(
  stream: Stream,
  data: Data,
  binding: BitArray,
  id: Int,
  port: Subject(OwnerMessage),
  callback: Callback,
) -> sm.Next(Phase, Data, Message) {
  // A tail is a send to the port and nothing else, so it needs no task.
  case untrusted_wire.answer_kind(callback) {
    None -> {
      let _cast = untrusted_bridge.owner_answer(port, callback)
      armed(stream, data)
    }
    Some(_kind) -> {
      let sink = process.new_subject()
      let _relay =
        weft.new([fn() { Ok(untrusted_bridge.owner_answer(port, callback)) }])
        |> weft.start_relayed(to: sink)
      let forwarding = Forwarding(callback:, sink:, answering: Unanswered)
      let data = opened_callback(data, binding, id, forwarding)
      armed(stream, data)
      |> sm.with_selector(selector_of(data))
    }
  }
}

/// Records a callback being answered, against its binding and the link.
fn opened_callback(
  data: Data,
  binding: BitArray,
  id: Int,
  forwarding: Forwarding,
) -> Data {
  // The binding was found by `admitted` in this same event, so the miss arm
  // only keeps the book unchanged.
  let bindings = case dict.get(data.bindings, binding) {
    Ok(held) ->
      dict.insert(data.bindings, binding, Binding(..held, open: held.open + 1))
    Error(Nil) -> data.bindings
  }

  Data(
    ..data,
    bindings:,
    forwarding: dict.insert(data.forwarding, #(binding, id), forwarding),
  )
}

/// A forwarder's report. Its answer goes out on an open connection; on a
/// closed one the executor's proxy has already failed the callback. A task
/// that ended without an answer is answered with the callback's failure, and
/// the run's last word frees its place.
fn forwarded(
  phase: Phase,
  data: Data,
  binding: BitArray,
  id: Int,
  callback: Callback,
  pulled: weft.Pulled(Option(Answer), Nil),
) -> sm.Next(Phase, Data, Message) {
  let lost =
    untrusted_bridge.refused_answer(callback, "the owner's answer was lost")

  // The outcome is answered once; the run's end, which follows it, closes
  // the entry, and answers too if no outcome came first.
  case pulled {
    weft.PulledOutcome(outcome: weft.Completed(value: answer, ..)) -> {
      let #(data, frame) = answer_once(data, binding, id, answer)
      send_on_open(phase, data, frame)
    }
    weft.PulledOutcome(outcome: weft.Failed(..))
    | weft.PulledOutcome(outcome: weft.Crashed(..))
    | weft.PulledOutcome(outcome: weft.Abandoned(..))
    | weft.PulledOutcome(outcome: weft.NeverStarted(..))
    | weft.PulledOutcome(outcome: weft.DrainProofLost(..))
    | weft.PulledOutcome(outcome: weft.CancellationUnconfirmed(..)) -> {
      let #(data, frame) = answer_once(data, binding, id, lost)
      send_on_open(phase, data, frame)
    }
    weft.NotYet -> sm.keep(data)
    weft.AllDelivered | weft.RunLost(..) -> {
      let #(data, frame) = answer_once(data, binding, id, lost)
      let data = closed_callback(data, binding, id)
      send_on_open(phase, data, frame)
      |> sm.with_selector(selector_of(data))
    }
  }
}

/// Marks a forwarded callback answered and gives the frame that answers it,
/// the first time only.
fn answer_once(
  data: Data,
  binding: BitArray,
  id: Int,
  answer: Option(Answer),
) -> #(Data, Option(BitArray)) {
  let at = #(binding, id)

  // An entry already answered, or gone, sends nothing more.
  case dict.get(data.forwarding, at), answer {
    Ok(Forwarding(answering: Unanswered, ..) as forwarding), Some(answer) -> #(
      Data(
        ..data,
        forwarding: dict.insert(
          data.forwarding,
          at,
          Forwarding(..forwarding, answering: Answered),
        ),
      ),
      Some(encoded(untrusted_wire.Answer(binding:, id:, answer:))),
    )
    Ok(Forwarding(answering: Unanswered, ..)), None
    | Ok(Forwarding(answering: Answered, ..)), _
    | Error(Nil), _
    -> #(data, None)
  }
}

/// Removes a forwarder whose run has ended, and frees its binding's place.
fn closed_callback(data: Data, binding: BitArray, id: Int) -> Data {
  // A binding retired while its callback was out has no place to free.
  let bindings = case dict.get(data.bindings, binding) {
    Ok(held) ->
      dict.insert(
        data.bindings,
        binding,
        Binding(..held, open: int.max(0, held.open - 1)),
      )
    Error(Nil) -> data.bindings
  }

  Data(
    ..data,
    bindings:,
    forwarding: dict.delete(data.forwarding, #(binding, id)),
  )
}

/// Sends a frame, when there is one and the connection is open. It is not a
/// read, so it does not ask for the next frame.
fn send_on_open(
  phase: Phase,
  data: Data,
  frame: Option(BitArray),
) -> sm.Next(Phase, Data, Message) {
  // Nothing to send, or no connection to send it on, keeps the data.
  case frame {
    Some(frame) ->
      on_open(phase, data, fn(stream) { sent(stream, data, frame) })
    None -> sm.keep(data)
  }
}

/// Runs `then` with the stream when the link is open, and keeps the data
/// otherwise.
fn on_open(
  phase: Phase,
  data: Data,
  then: fn(Stream) -> sm.Next(Phase, Data, Message),
) -> sm.Next(Phase, Data, Message) {
  // Only an open connection carries frames other than the greeting.
  case phase {
    Open(stream:) -> then(stream)
    Idle | Dialing | Greeting(..) | Resting -> sm.keep(data)
  }
}

/// A monitored process went down: an asker's death drops its request and, on
/// an open connection, cancels it at the executor; an owner port's retires
/// its binding.
fn went_down(
  phase: Phase,
  data: Data,
  down: process.Down,
) -> sm.Next(Phase, Data, Message) {
  // Only a process monitor is one this link made.
  let found = case down {
    process.ProcessDown(monitor:, ..) ->
      dict.get(data.watched, monitor)
      |> result.map(fn(watched) { #(monitor, watched) })
    process.PortDown(..) -> Error(Nil)
  }

  // A monitor the book no longer holds was dropped on purpose.
  case found {
    Error(Nil) -> sm.keep(data)
    Ok(#(monitor, Asker(id))) -> {
      let data =
        Data(
          ..data,
          watched: dict.delete(data.watched, monitor),
          outstanding: dict.delete(data.outstanding, id),
        )
      on_open(phase, data, fn(stream) {
        sent(stream, data, encoded(untrusted_wire.Cancel(id)))
      })
    }
    Ok(#(monitor, Port(binding))) ->
      sm.keep(retire(
        Data(..data, watched: dict.delete(data.watched, monitor)),
        binding,
      ))
  }
}

/// Sends an answer, when there is one, and asks for the next frame.
fn answered(
  stream: Stream,
  data: Data,
  binding: BitArray,
  id: Int,
  answer: Option(Answer),
) -> sm.Next(Phase, Data, Message) {
  // A tail has no answer to send.
  let sent = case answer {
    Some(answer) ->
      ffi_tls_stream.send(
        stream,
        encoded(untrusted_wire.Answer(binding:, id:, answer:)),
      )
    None -> Ok(Nil)
  }

  // The answer and the arm are one step: either failing is a dead connection.
  case result.try(sent, fn(_sent) { ffi_tls_stream.arm(stream) }) {
    Ok(Nil) -> sm.keep(data)
    Error(_failure) -> rest(stream, data, "an answer could not be sent")
  }
}

/// Asks for the next frame.
fn armed(stream: Stream, data: Data) -> sm.Next(Phase, Data, Message) {
  // A connection that cannot be read any more is rested.
  case ffi_tls_stream.arm(stream) {
    Ok(Nil) -> sm.keep(data)
    Error(_failure) -> rest(stream, data, "the connection could not be read")
  }
}

/// A frame the protocol does not allow: logged, and the connection closed.
fn violation(
  stream: Stream,
  data: Data,
  reason: String,
) -> sm.Next(Phase, Data, Message) {
  log.warn(data.config.logger, "untrusted_link.violation", [
    field.text("executor", data.config.executor),
    field.text("reason", reason),
  ])
  rest(stream, data, "the executor broke the protocol")
}

/// Closes the connection and rests before the next dial.
fn rest(
  stream: Stream,
  data: Data,
  reason: String,
) -> sm.Next(Phase, Data, Message) {
  ffi_tls_stream.close(stream)
  resting(data, reason)
}

/// Rests for the current pause, doubling it for the next time.
fn resting(data: Data, reason: String) -> sm.Next(Phase, Data, Message) {
  log.info(data.config.logger, "untrusted_link.resting", [
    field.text("executor", data.config.executor),
    field.text("reason", reason),
    field.count("pause_ms", data.pause_ms),
  ])
  let pause = data.pause_ms
  let data =
    Data(..data, pause_ms: int.min(longest_pause_ms, data.pause_ms * 2))
  sm.transition(to: Resting, data:)
  |> sm.with_state_timeout(after: pause, sending: PauseEnded)
}

/// The pause ended: dial again if anything waits on a connection, or go idle.
fn rested(data: Data) -> sm.Next(Phase, Data, Message) {
  let waiting =
    !dict.is_empty(data.outstanding) || !dict.is_empty(data.bindings)

  // A live binding needs the connection even with no request outstanding,
  // because its plane can call back at any time and the executor never dials.
  case waiting {
    True -> dial(data)
    False -> sm.transition(to: Idle, data:)
  }
}

/// A frame's bytes.
fn encoded(frame: untrusted_wire.Frame) -> BitArray {
  untrusted_codec.encode_frame(frame)
}

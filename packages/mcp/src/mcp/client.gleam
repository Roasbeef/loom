//// The MCP client actor: one explicitly owned long-lived process owning one
//// MCP server peer over the stdio transport, driving the initialize
//// lifecycle and serving typed calls — list every tool, call a tool.
////
//// The actor is written against `mcp/transport.Transport`, so whether
//// the server process is a real child on an Erlang port or an
//// in-process test peer is the injector's decision; see that module for
//// why the seam exists and for the security posture of spawning.
////
//// ## The v1 posture (issue #106)
////
//// **No restart, no reconnect.** A dead peer — the process exited, the
//// transport closed, a framing fault poisoned the line stream — settles
//// every in-flight call as `Unavailable` and latches the client dead
//// for the session; later calls answer `Unavailable` in-band without
//// crashing anything. The supervised substrate grows reconnection teeth
//// in phase 5 (the LSP client, issue #25), not here.
////
//// **No server-initiated anything.** This client declares an empty
//// capabilities object (see `mcp/protocol.initialize_request` for why
//// that is a security decision), so a server-initiated *request* —
//// sampling, roots, elicitation, whatever else — is answered in-band
//// with JSON-RPC method-not-found (-32601), and a server *notification*
//// is decoded and dropped.
////
//// ## Faults are values, and the envelope decides which are fatal
////
//// The posture mirrors the cap channel's: a line that is not a
//// well-formed JSON-RPC message, a byte stream that is not UTF-8, and a
//// line past `mcp/stdio.max_line_bytes` are channel-fatal — every
//// in-flight call settles at once and the client latches dead — while
//// well-formed messages this client merely does not act on (an unknown
//// or forgotten response id, a notification) are dropped and the
//// channel stays open. Nothing here panics; every fault is a value.
////
//// ## Callers are never killed by a slow or dead actor
////
//// Every public call is a monitored send-and-select (the
//// `broker/internal/call.try_call` shape), never `process.call`, which
//// panics on a timeout and on a dead callee. A dead client answers
//// `Unavailable`; a wedged one answers `Unavailable` after the call's
//// own deadline plus a small margin. Each in-flight call carries its
//// own deadline inside the actor too: at expiry the caller gets a typed
//// `CallTimedOut` and the actor forgets the id, so a late response to a
//// forgotten id is dropped silently.
////
//// `prepare` parks the owner before transport opening. After external custody
//// is published, `connect` opens the transport in that same owner. Stopping
//// settles calls immediately but retains the exact port until native exit.
//// Typed `shutdown` then consumes explicit retirement proof and observes the
//// original normal actor DOWN. A deadline or unexpected owner death cannot
//// substitute for either proof.

import core/corruption
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import mcp/jsonrpc.{type Id}
import mcp/protocol.{type CallToolResult, type ToolDescriptor}
import mcp/stdio
import mcp/transport.{type Transport}
import weft/poll
import weft/state_machine as sm

/// How long parked actor preparation or transport opening may take before
/// the caller reports startup failure.
///
/// Preparation and opening each use this budget; the handshake uses
/// `Options.handshake_timeout_ms`. The convenience `start` wrapper also
/// spends this budget verifying cleanup when startup fails.
pub const init_timeout_ms = 5000

/// Slack added to a call's own deadline before the caller gives up
/// waiting for the actor to answer: the actor enforces the real deadline
/// with a typed `CallTimedOut`, so this only guards against a wholly
/// wedged client.
const reply_margin_ms = 1000

/// The default `initialize` → `initialized` handshake budget.
pub const default_handshake_timeout_ms = 10_000

/// The most `tools/list` pages `list_tools` will follow before refusing
/// with `TooManyPages`: a hostile server re-issuing a `nextCursor`
/// forever must not loop the harness.
pub const max_tool_pages = 64

/// JSON-RPC's method-not-found code, the in-band answer to every
/// server-initiated request.
pub const method_not_found_code = -32_601

/// An opaque handle to a started client actor. Sendable across
/// processes; every public function takes one.
pub opaque type Client {
  Client(subject: Subject(Msg), owner: process.Pid)
}

/// Why a shutdown could not establish both transport retirement and actor exit.
pub type RetirementError {
  /// The caller's reporting budget elapsed; the owner still retains custody.
  RetirementTimedOut

  /// The owner disappeared before returning explicit retirement evidence.
  RetirementUnconfirmed
}

type RetirementProof {
  NoNativeResource
  NativeExited(reason: String)
}

type Phase {
  Prepared
  Serving
  Closing
  Retired(proof: RetirementProof)
}

type Custody {
  Held
  Lost
}

/// Options for `start`.
///
/// Constructor invariants: `handshake_timeout_ms` is a positive
/// millisecond budget for the whole `initialize` round trip;
/// `client_version` is Loom's own version, carried verbatim in
/// `clientInfo`.
pub type Options {
  Options(client_version: String, handshake_timeout_ms: Int)
}

/// Options with the default handshake budget.
///
/// ## Examples
///
/// ```gleam
/// assert client.options("0.1.0").handshake_timeout_ms
///   == client.default_handshake_timeout_ms
/// ```
///
pub fn options(client_version: String) -> Options {
  Options(client_version:, handshake_timeout_ms: default_handshake_timeout_ms)
}

/// Overrides the handshake budget.
///
/// ## Examples
///
/// ```gleam
/// assert client.options("0.1.0")
///   |> client.with_handshake_timeout(500)
///   == client.Options(client_version: "0.1.0", handshake_timeout_ms: 500)
/// ```
///
pub fn with_handshake_timeout(options: Options, ms: Int) -> Options {
  // Clamped to at least one millisecond: a non-positive delay would
  // reach process.send_after, which raises on negatives.
  Options(..options, handshake_timeout_ms: int.max(ms, 1))
}

/// Why a call produced no usable result. Plain data, always in-band:
/// no variant here is ever a caller's crash.
pub type ClientError {
  /// The client (or the server it owned) is not available: the peer
  /// died, the transport closed, a framing fault latched the client
  /// dead, or the actor itself is gone. `reason` names which.
  Unavailable(reason: String)

  /// The call did not complete within its own deadline. The id is
  /// forgotten; a response arriving later is dropped silently.
  CallTimedOut(after_ms: Int)

  /// The server answered the call with a JSON-RPC error.
  ServerError(code: Int, message: String)

  /// The server's result was well-formed JSON-RPC but not the shape the
  /// method promises; `reason` names the field that broke it.
  ResultMalformed(reason: String)

  /// `tools/list` pagination did not exhaust within `max_tool_pages`
  /// pages; `cap` restates the ceiling that was hit.
  TooManyPages(cap: Int)
}

/// Why startup produced no serving client. Staged startup retains the owner
/// after a refusal so its published custodian can verify native retirement.
pub type StartError {
  /// The transport could not open — the server executable did not
  /// spawn, or the actor could not start.
  TransportFailed(reason: String)

  /// The `initialize` exchange itself failed: a server error, a
  /// malformed result, a closed transport, or the handshake deadline.
  HandshakeFailed(error: ClientError)

  /// The server negotiated a protocol revision this client cannot
  /// speak. Carries both sides so the refusal can be worded without
  /// re-asking.
  VersionUnsupported(server: String, supported: List(String))

  /// The server did not declare the tools capability, and tools are the
  /// only thing this client exists to reach.
  ToolsNotDeclared

  /// Startup failed and retirement is uncertain; retain this client's custody.
  CleanupUnconfirmed(client: Client)
}

/// The client actor's message set. Opaque: only this module constructs
/// these, so nothing can inject a forged response or expiry.
pub opaque type Msg {
  /// Opens the already-published client transport, exactly once.
  Open(reply: Subject(Result(Nil, StartError)))

  /// The preparer disappeared before admitting native work.
  PreparerGone

  /// The published cleanup owner can no longer claim retirement evidence.
  CustodianGone

  /// Requests retirement proof before the owning actor may stop normally.
  Retire(reply: Subject(RetirementProof))

  /// One outbound request: `build` receives the actor-minted id and
  /// returns the full JSON-RPC message; the correlated result (or the
  /// typed error) is sent to `reply`.
  Request(
    build: fn(Id) -> JsonValue,
    deadline_ms: Int,
    reply: Subject(Result(JsonValue, ClientError)),
  )

  /// One outbound notification, fire-and-forget.
  Notify(message: JsonValue)

  /// Inbound bytes or the close, from the port selector or a test peer.
  FromTransport(event: transport.TransportEvent)

  /// A call's deadline lapsed; if the id is still in flight the caller
  /// is answered `CallTimedOut` and the id is forgotten.
  Expire(id: Int)

  /// Requests termination and settles calls, retaining the native-exit proof
  /// until `Retire` transfers it to the custodian.
  Shutdown
}

type InFlight {
  InFlight(reply: Subject(Result(JsonValue, ClientError)), deadline_ms: Int)
}

type State {
  State(
    transport_spec: Option(Transport),
    inbound: Subject(transport.TransportEvent),
    selector: process.Selector(Msg),
    connection: transport.Connection,
    buffer: stdio.Buffer,
    // The held tail of an incomplete UTF-8 sequence between chunks; at
    // most `transport.max_held_tail_bytes` bytes.
    tail: BitArray,
    next_id: Int,
    inflight: Dict(Int, InFlight),
    // `Some(reason)` once the peer is gone: no response can arrive, so
    // new calls are refused in-band rather than waiting out deadlines.
    dead: Option(String),
    commands: Subject(Msg),
    custody: Custody,
  )
}

// --- public API -------------------------------------------------------------

/// Starts the client: opens the transport (spawning the server, for a
/// port transport), performs `initialize` → `notifications/initialized`
/// against `protocol.requested_version`, and refuses a server negotiating a version outside
/// `protocol.supported_versions()` or one not declaring the tools
/// capability. The whole handshake is bounded by
/// `options.handshake_timeout_ms`. Refusal retires the actor only after
/// explicit transport evidence; otherwise `CleanupUnconfirmed` returns its
/// handle so the caller cannot discard uncertain cleanup ownership.
///
/// ## Examples
///
/// ```gleam
/// // client.start(transport.PortTransport(spawn), client.options("0.1.0"))
/// ```
///
pub fn start(
  transport_spec: Transport,
  options: Options,
) -> Result(Client, StartError) {
  use client <- result.try(prepare(transport_spec))
  case connect(client, options) {
    Ok(Nil) -> Ok(client)
    Error(error) -> {
      case shutdown(client, within: init_timeout_ms) {
        Ok(Nil) -> Error(error)
        Error(_) -> Error(CleanupUnconfirmed(client))
      }
    }
  }
}

/// Prepares an actor without opening a transport or executing third-party code.
/// Publish its cleanup capability before calling `connect`.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(client) = client.prepare(transport)
/// // publish(fn() { client.shutdown(client, within: 5000) })
/// ```
@internal
pub fn prepare(transport_spec: Transport) -> Result(Client, StartError) {
  prepare_owned(transport_spec, process.self())
}

/// Prepares a client whose cleanup lifetime belongs to a separate custodian.
/// A dead builder cannot discard the parked client's no-resource proof.
///
/// ## Examples
///
/// ```gleam
/// // client.prepare_owned(transport, instance_owner)
/// ```
@internal
pub fn prepare_owned(
  transport_spec: Transport,
  custodian: process.Pid,
) -> Result(Client, StartError) {
  start_actor(transport_spec, custodian)
  |> result.map_error(fn(error) {
    TransportFailed(reason: describe_start_error(error))
  })
}

/// Opens a published client and negotiates its MCP handshake.
/// A refusal leaves the client in the caller's cleanup census.
///
/// ## Examples
///
/// ```gleam
/// // client.connect(prepared, client.options("0.1.0"))
/// ```
@internal
pub fn connect(client: Client, options: Options) -> Result(Nil, StartError) {
  use Nil <- result.try(
    exchange(client.subject, init_timeout_ms, Open)
    |> result.map_error(fn(error) { HandshakeFailed(error) })
    |> result.flatten,
  )
  case handshake(client, options) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      stop(client)
      Error(error)
    }
  }
}

/// Returns the actor whose normal retirement follows explicit transport proof.
///
/// ## Examples
///
/// ```gleam
/// // process.monitor(client.pid(prepared))
/// ```
@internal
pub fn pid(client: Client) -> process.Pid {
  client.owner
}

/// Retires a client after explicit no-resource or native-exit evidence.
/// The monitor is installed before requesting proof, so a later normal DOWN
/// belongs to this retirement attempt. Missing evidence never becomes success.
/// Both receives share one monotonic deadline.
///
/// ## Examples
///
/// ```gleam
/// // client.shutdown(prepared, within: 5000)
/// ```
@internal
pub fn shutdown(
  client: Client,
  within within: Int,
) -> Result(Nil, RetirementError) {
  let clock = poll.monotonic()
  let deadline = clock.now() + int.max(within, 0)
  let watch = process.monitor(client.owner)
  let proofs = process.new_subject()
  process.send(client.subject, Retire(proofs))

  // The first event must carry the owner's explicit resource evidence.
  // Actor death by itself says nothing about the native process it owned.
  let proof =
    process.new_selector()
    |> process.select_map(proofs, Ok)
    |> process.select_specific_monitor(watch, fn(_) {
      Error(RetirementUnconfirmed)
    })
    |> process.selector_receive(int.max(deadline - clock.now(), 0))
    |> result.replace_error(RetirementTimedOut)
    |> result.flatten
  let answer = case proof {
    Error(error) -> Error(error)
    Ok(NoNativeResource) | Ok(NativeExited(_)) -> {
      process.new_selector()
      |> process.select_specific_monitor(watch, fn(down) {
        case down.reason {
          process.Normal -> Ok(Nil)
          process.Abnormal(_) | process.Killed -> Error(RetirementUnconfirmed)
        }
      })
      |> process.selector_receive(int.max(deadline - clock.now(), 0))
      |> result.replace_error(RetirementTimedOut)
      |> result.flatten
    }
  }
  process.demonitor_process(watch)
  answer
}

/// Lists every tool the server declares, following `nextCursor`
/// pagination to exhaustion. `timeout_ms` bounds each page's round
/// trip; the page count is bounded by `max_tool_pages`, so the whole
/// listing is bounded even against a hostile server.
///
/// ## Examples
///
/// ```gleam
/// // client.list_tools(client, 5000)
/// ```
///
pub fn list_tools(
  client: Client,
  timeout_ms: Int,
) -> Result(List(ToolDescriptor), ClientError) {
  // Transient memory is bounded but not small: up to `max_tool_pages`
  // pages of up to `stdio.max_line_bytes` each accumulate before the
  // listing flattens — a ceiling near a gigabyte, documented as the
  // decision rather than hidden. `timeout_ms` is clamped to at least
  // one millisecond; process.send_after raises on negatives.
  list_pages(client, int.max(timeout_ms, 1), None, [], max_tool_pages)
}

/// Calls one tool by its server-declared name. `arguments` is passed
/// through raw; the caller owns conformance to the tool's input schema.
///
/// ## Examples
///
/// ```gleam
/// // client.call_tool(client, "echo", json.Object([]), 5000)
/// ```
///
pub fn call_tool(
  client: Client,
  name: String,
  arguments: JsonValue,
  timeout_ms: Int,
) -> Result(CallToolResult, ClientError) {
  // Clamped for the same reason as list_tools: send_after raises on a
  // negative delay, and a config typo should not kill the client.
  use value <- result.try(
    request(client, int.max(timeout_ms, 1), protocol.call_tool_request(
      _,
      name,
      arguments,
    )),
  )
  protocol.decode_call_tool_result(value)
  |> result.map_error(malformed)
}

/// Requests transport termination and settles calls as `Unavailable`.
/// The actor retains native-exit evidence until typed `shutdown` retires it.
/// Sending this request alone does not establish cleanup completion.
///
/// ## Examples
///
/// ```gleam
/// // client.stop(client)
/// // client.shutdown(client, within: 5000)
/// ```
pub fn stop(client: Client) -> Nil {
  process.send(client.subject, Shutdown)
}

// --- the handshake ----------------------------------------------------------

fn handshake(client: Client, options: Options) -> Result(Nil, StartError) {
  use value <- result.try(
    request(client, options.handshake_timeout_ms, protocol.initialize_request(
      _,
      options.client_version,
    ))
    |> result.map_error(fn(error) { HandshakeFailed(error:) }),
  )
  use init <- result.try(accept_initialize(value))
  use _tools <- result.try(case init.tools {
    Some(tools) -> Ok(tools)
    None -> Error(ToolsNotDeclared)
  })
  process.send(client.subject, Notify(message: protocol.initialized()))
  Ok(Nil)
}

fn accept_initialize(
  value: JsonValue,
) -> Result(protocol.InitializeResult, StartError) {
  case protocol.decode_initialize_result(value) {
    Ok(init) -> Ok(init)
    Error(protocol.UnsupportedVersion(server:, supported:)) ->
      Error(VersionUnsupported(server:, supported:))
    Error(protocol.BadResult(reason:)) ->
      Error(HandshakeFailed(error: ResultMalformed(reason:)))
  }
}

// --- the caller side --------------------------------------------------------

// Follows tools/list pagination, newest page prepended, flattened once
// at exhaustion. `remaining` counts down from `max_tool_pages`.
fn list_pages(
  client: Client,
  timeout_ms: Int,
  cursor: Option(String),
  pages: List(List(ToolDescriptor)),
  remaining: Int,
) -> Result(List(ToolDescriptor), ClientError) {
  use <- bool.guard(
    when: remaining <= 0,
    return: Error(TooManyPages(cap: max_tool_pages)),
  )
  use value <- result.try(
    request(client, timeout_ms, protocol.list_tools_request(_, cursor)),
  )
  use page <- result.try(
    protocol.decode_tools_page(value)
    |> result.map_error(malformed),
  )
  let pages = [page.tools, ..pages]
  case page.next_cursor {
    None -> Ok(list.flatten(list.reverse(pages)))
    Some(next) ->
      list_pages(client, timeout_ms, Some(next), pages, remaining - 1)
  }
}

// One correlated request through the actor. The wait is the call's own
// deadline plus a margin: the actor answers `CallTimedOut` at the
// deadline itself, so the margin only guards against a wedged actor.
fn request(
  client: Client,
  timeout_ms: Int,
  build: fn(Id) -> JsonValue,
) -> Result(JsonValue, ClientError) {
  exchange(client.subject, timeout_ms + reply_margin_ms, fn(reply) {
    Request(build:, deadline_ms: timeout_ms, reply:)
  })
  |> result.flatten
}

// A `process.call` that answers instead of crashing — the
// `broker/internal/call.try_call` shape, reproduced here because this
// package deliberately does not depend on the broker. The caller of a
// tool call holds a verdict its death would lose; a dead or wedged
// client must answer `Unavailable`, never exit the asker. The cost of
// not crashing is one stale message: a reply arriving after the wait
// sits in the caller's mailbox as an inert term, bounded by the number
// of faulty exchanges.
fn exchange(
  subject: Subject(Msg),
  waiting: Int,
  make: fn(Subject(reply)) -> Msg,
) -> Result(reply, ClientError) {
  // A subject whose owner is gone has nobody to answer; the monitor
  // below covers the owner dying after this check.
  case process.subject_owner(subject) {
    Error(Nil) -> Error(Unavailable(reason: "mcp client is not running"))
    Ok(owner) -> {
      let reply_subject = process.new_subject()
      let monitor = process.monitor(owner)
      process.send(subject, make(reply_subject))
      let answer =
        process.new_selector()
        |> process.select_map(reply_subject, Ok)
        |> process.select_specific_monitor(monitor, fn(_down) {
          Error(Unavailable(reason: "mcp client is not running"))
        })
        |> process.selector_receive(waiting)

      // Demonitoring flushes a DOWN that arrived after the wait, so the
      // only thing this exchange can leave behind is a late reply.
      process.demonitor_process(monitor)
      result.lazy_unwrap(answer, fn() {
        Error(Unavailable(reason: "mcp client did not answer"))
      })
    }
  }
}

fn malformed(fault: protocol.ProtocolFault) -> ClientError {
  case fault {
    protocol.BadResult(reason:) -> ResultMalformed(reason:)

    // Unreachable outside `initialize` (only its decoder checks the
    // version), but the type is shared, so it settles as data too.
    protocol.UnsupportedVersion(server:, ..) ->
      ResultMalformed(reason: "unsupported protocol version " <> server)
  }
}

fn describe_start_error(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "mcp client initialiser timed out"
    actor.InitFailed(reason) -> reason
    actor.InitExited(_) -> "mcp client exited during initialisation"
  }
}

// --- the actor --------------------------------------------------------------

fn start_actor(
  transport_spec: Transport,
  custodian: process.Pid,
) -> Result(Client, actor.StartError) {
  let preparer = process.self()
  sm.new_with_initialiser(init_timeout_ms, fn(commands) {
    let inbound = process.new_subject()
    let base =
      process.new_selector()
      |> process.select(commands)
      |> process.select_map(inbound, FromTransport)
      |> process.select_specific_monitor(process.monitor(preparer), fn(_) {
        PreparerGone
      })
      |> process.select_specific_monitor(process.monitor(custodian), fn(_) {
        CustodianGone
      })
    let state =
      State(
        transport_spec: Some(transport_spec),
        inbound:,
        selector: base,
        connection: inert_connection(),
        buffer: stdio.new(),
        tail: <<>>,
        next_id: 1,
        inflight: dict.new(),
        dead: None,
        commands:,
        custody: Held,
      )
    sm.initialised(Prepared, state)
    |> sm.selecting(base)
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.on_event(handle)
  |> sm.unlinked
  |> sm.start
  |> result.map(fn(started) {
    Client(subject: started.data, owner: started.pid)
  })
}

fn handle(phase: Phase, state: State, msg: Msg) -> sm.Next(Phase, State, Msg) {
  case phase, msg {
    Prepared, Open(reply) -> open_transport(state, reply)
    Prepared, PreparerGone | Prepared, Shutdown ->
      sm.transition(
        Retired(NoNativeResource),
        State(..state, transport_spec: None, dead: Some("mcp client stopped")),
      )

    // A parked client owns no native process. Once neither builder nor
    // custodian can use it, retaining its empty proof would leak an actor.
    Prepared, CustodianGone | Retired(_), CustodianGone -> sm.stop()
    Serving, CustodianGone ->
      begin_close(State(..state, custody: Lost), "mcp custodian stopped")
    Closing, CustodianGone -> sm.keep(State(..state, custody: Lost))
    Prepared, Retire(reply) -> {
      process.send(reply, NoNativeResource)
      sm.stop()
    }
    Serving, PreparerGone | Closing, PreparerGone | Retired(_), PreparerGone ->
      sm.keep(state)
    Serving, Open(reply) | Closing, Open(reply) | Retired(_), Open(reply) -> {
      process.send(reply, Error(TransportFailed("mcp client already opened")))
      sm.keep(state)
    }
    Serving, Shutdown -> begin_close(state, "mcp client stopped")
    Closing, Shutdown | Retired(_), Shutdown -> sm.keep(state)
    Serving, Retire(_) ->
      begin_close(state, "mcp client stopped") |> sm.postpone
    Closing, Retire(_) -> sm.keep(state) |> sm.postpone
    Retired(proof), Retire(reply) -> {
      process.send(reply, proof)
      sm.stop()
    }
    Prepared, Request(reply:, ..) -> {
      process.send(reply, Error(Unavailable("mcp client has not opened")))
      sm.keep(state)
    }
    Prepared, Notify(_) | Prepared, FromTransport(_) | Prepared, Expire(_) ->
      sm.keep(state)
    Serving, other | Closing, other | Retired(_), other ->
      handle_opened(state, other)
  }
}

// The actor owns the port from its first native instruction. This handler
// runs only after the caller has published custody for every parked client.
fn open_transport(
  state: State,
  reply: Subject(Result(Nil, StartError)),
) -> sm.Next(Phase, State, Msg) {
  let opened = case state.transport_spec {
    Some(spec) ->
      transport.open(spec, state.inbound, state.selector, FromTransport)
    None -> Error("mcp transport specification already consumed")
  }

  // Environment values are needed only for spawn. Do not retain the original
  // specification in the resident client after success or failure.
  let state = State(..state, transport_spec: None)
  case opened {
    Error(reason) -> {
      process.send(reply, Error(TransportFailed(reason)))
      sm.transition(
        Retired(NoNativeResource),
        State(..state, dead: Some(reason)),
      )
    }
    Ok(#(connection, selector)) -> {
      process.send(reply, Ok(Nil))
      sm.transition(Serving, State(..state, connection:))
      |> sm.with_selector(selector)
    }
  }
}

fn handle_opened(state: State, msg: Msg) -> sm.Next(Phase, State, Msg) {
  case msg {
    Request(build:, deadline_ms:, reply:) ->
      handle_request(state, build, deadline_ms, reply)
    Notify(message:) -> handle_notify(state, message)
    FromTransport(transport.TransportData(bytes:)) -> handle_data(state, bytes)
    FromTransport(transport.TransportClosed(reason:)) ->
      handle_closed(state, reason)
    Expire(id:) -> handle_expire(state, id)
    Open(_) | PreparerGone | CustodianGone | Retire(_) | Shutdown ->
      sm.keep(state)
  }
}

// A caller asked for one request. A dead client refuses in-band at
// once; otherwise the id is minted, the call tracked with its own
// deadline, and the frame written — a failed write is the peer gone.
fn handle_request(
  state: State,
  build: fn(Id) -> JsonValue,
  deadline_ms: Int,
  reply: Subject(Result(JsonValue, ClientError)),
) -> sm.Next(Phase, State, Msg) {
  case state.dead {
    Some(reason) -> {
      process.send(reply, Error(Unavailable(reason:)))
      sm.keep(state)
    }
    None -> {
      let id = state.next_id
      let message = build(jsonrpc.IdInt(id))
      let inflight =
        dict.insert(state.inflight, id, InFlight(reply:, deadline_ms:))
      let state = State(..state, next_id: id + 1, inflight:)
      case state.connection.send(stdio.frame(message)) {
        Ok(Nil) -> {
          let _ = process.send_after(state.commands, deadline_ms, Expire(id:))
          sm.keep(state)
        }

        // The call was tracked before the write, so `die` settles this
        // caller along with every other in-flight one.
        Error(Nil) -> begin_close(state, "mcp transport write failed")
      }
    }
  }
}

fn handle_notify(
  state: State,
  message: JsonValue,
) -> sm.Next(Phase, State, Msg) {
  case state.dead {
    Some(_) -> sm.keep(state)
    None ->
      case state.connection.send(stdio.frame(message)) {
        Ok(Nil) -> sm.keep(state)
        Error(Nil) -> begin_close(state, "mcp transport write failed")
      }
  }
}

// Inbound bytes: reassemble UTF-8 across chunk boundaries, frame into
// lines, and act on each complete line. A stream that is not UTF-8 or a
// line past the framing cap is channel-fatal. A dead client drains the
// wire without acting on it.
fn handle_data(state: State, bytes: BitArray) -> sm.Next(Phase, State, Msg) {
  case state.dead {
    Some(_) -> sm.keep(state)
    None -> feed_chunk(state, bytes)
  }
}

fn feed_chunk(state: State, bytes: BitArray) -> sm.Next(Phase, State, Msg) {
  case transport.utf8_prefix(bit_array.append(state.tail, bytes)) {
    Error(Nil) -> begin_close(state, "mcp server bytes are not utf-8")
    Ok(#(text, tail)) -> {
      let state = State(..state, tail:)
      case stdio.push(state.buffer, text) {
        Error(stdio.LineTooLong(limit:, seen:)) ->
          begin_close(
            state,
            "mcp server line exceeded "
              <> int.to_string(limit)
              <> " bytes ("
              <> int.to_string(seen)
              <> " seen)",
          )
        Ok(#(buffer, lines)) -> feed_lines(State(..state, buffer:), lines)
      }
    }
  }
}

fn handle_closed(state: State, reason: String) -> sm.Next(Phase, State, Msg) {
  // The peer is already gone: replace the connection with an inert one
  // before `die` closes it, so a port close never chases the exited
  // child's (possibly recycled) OS pid with a kill.
  let state = die(State(..state, connection: inert_connection()), reason)
  case state.custody {
    Held -> sm.transition(Retired(NativeExited(reason)), state)
    Lost -> sm.stop()
  }
}

fn inert_connection() -> transport.Connection {
  transport.Connection(send: fn(_) { Error(Nil) }, close: fn() { Nil })
}

fn begin_close(state: State, reason: String) -> sm.Next(Phase, State, Msg) {
  sm.transition(Closing, die(state, reason))
}

fn handle_expire(state: State, id: Int) -> sm.Next(Phase, State, Msg) {
  case dict.get(state.inflight, id) {
    // Already answered (or already settled by a death) — the timer is
    // stale and the expiry means nothing.
    Error(Nil) -> sm.keep(state)
    Ok(call) -> {
      process.send(call.reply, Error(CallTimedOut(after_ms: call.deadline_ms)))
      sm.keep(State(..state, inflight: dict.delete(state.inflight, id)))
    }
  }
}

fn feed_lines(state: State, lines: List(String)) -> sm.Next(Phase, State, Msg) {
  case lines {
    [] -> sm.keep(state)
    [line, ..rest] ->
      case handle_line(state, line) {
        Ok(state) -> feed_lines(state, rest)
        Error(reason) -> begin_close(state, reason)
      }
  }
}

// One complete line. `Error(reason)` is channel-fatal; everything the
// client merely does not act on settles as `Ok` with the line dropped.
fn handle_line(state: State, line: String) -> Result(State, String) {
  case jsonrpc.decode(line) {
    Error(jsonrpc.MalformedMessage(report:)) ->
      Error("mcp server sent a malformed line: " <> corruption.describe(report))
    Error(jsonrpc.BadMessage(reason:)) ->
      Error("mcp server sent a line that is not json-rpc: wanted " <> reason)
    Ok(jsonrpc.Response(id:, outcome:)) ->
      Ok(settle_response(state, id, outcome))
    Ok(jsonrpc.ServerRequest(id:, ..)) -> refuse_server_request(state, id)

    // v1 subscribes to nothing, so every notification is decoded (so
    // nothing hostile hides in one) and dropped.
    Ok(jsonrpc.Notification(..)) -> Ok(state)
  }
}

// A response arrived. Correlation is by the exact minted integer id; a
// string id (never minted here) or an id no longer in flight — already
// expired, already settled — is dropped silently.
fn settle_response(
  state: State,
  id: Id,
  outcome: Result(JsonValue, jsonrpc.RpcError),
) -> State {
  case id {
    jsonrpc.IdString(_) -> state
    jsonrpc.IdInt(id) ->
      case dict.get(state.inflight, id) {
        Error(Nil) -> state
        Ok(call) -> {
          process.send(call.reply, outcome_to_result(outcome))
          State(..state, inflight: dict.delete(state.inflight, id))
        }
      }
  }
}

// A server-initiated request is answered in-band with method-not-found:
// this client declared no capabilities, so nothing a server asks of it
// is a thing it does. The write can fail only when the peer is gone,
// which is channel-fatal like any other failed write.
fn refuse_server_request(state: State, id: Id) -> Result(State, String) {
  case state.connection.send(stdio.frame(method_not_found_response(id))) {
    Ok(Nil) -> Ok(state)
    Error(Nil) -> Error("mcp transport write failed")
  }
}

// The JSON-RPC error response `mcp/jsonrpc` has no encoder for, built
// here because answering server requests is the client actor's job
// (the protocol layer only decodes them).
fn method_not_found_response(id: Id) -> JsonValue {
  json.Object([
    #("jsonrpc", json.String(jsonrpc.version)),
    #("id", encode_id(id)),
    #(
      "error",
      json.Object([
        #("code", json.Int(method_not_found_code)),
        #("message", json.String("method not found")),
      ]),
    ),
  ])
}

fn encode_id(id: Id) -> JsonValue {
  case id {
    jsonrpc.IdInt(value:) -> json.Int(value)
    jsonrpc.IdString(value:) -> json.String(value)
  }
}

fn outcome_to_result(
  outcome: Result(JsonValue, jsonrpc.RpcError),
) -> Result(JsonValue, ClientError) {
  case outcome {
    Ok(value) -> Ok(value)
    Error(jsonrpc.RpcError(code:, message:, data: _)) ->
      Error(ServerError(code:, message:))
  }
}

// Latches the client dead: answers every in-flight caller
// `Unavailable(reason)`, closes the transport, and records the reason
// so later calls fail fast the same way. Idempotent — a client already
// dead stays dead with its first reason.
fn die(state: State, reason: String) -> State {
  case state.dead {
    Some(_) -> state
    None -> {
      list.each(dict.to_list(state.inflight), fn(entry) {
        let InFlight(reply:, ..) = entry.1
        process.send(reply, Error(Unavailable(reason:)))
      })
      state.connection.close()
      State(..state, inflight: dict.new(), dead: Some(reason))
    }
  }
}

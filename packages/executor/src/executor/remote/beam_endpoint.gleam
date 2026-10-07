//// One node-wide rendezvous binds authenticated peers to concrete scoped services.
////
//// Local registration is the only enrollment path. Four data and two control
//// credits bound all scopes together; each credit owns its stable service reply
//// subject. Caller death joins transport work but cannot release a queued ask.
//// Once an ask reaches service custody, reuse requires its actual answer and
//// AllDelivered. A handoff carries its run reference; an unconsumed handoff
//// arriving after reuse is discarded before touching the new registration. Lost or
//// uncertain custody permanently retains its original assignment. Idle actor loss
//// reduces capacity without charging a scope. Six canonical records are the only
//// allocation state; no fence, DOWN or timeout returns assigned capacity.
//// The host must treat this subtree as Temporary and separately drain native
//// effects before replacing it. No endpoint death establishes native retirement.
////
//// ## Flow
////
//// `registration` and `compile_registration` derive concrete authority;
//// `configure_server`, `start` and `register` own bounded local enrollment.
//// `monitored_row` watches each local scope owner; `fence` permanently closes its
//// row. `inspect_drain` uses `drain_snapshot` and `exact_row` to observe scoped
//// custody. `handle` retains normal credit loss and `available_count` counts only
//// canonical Available records. Scope owner DOWN applies the same row fence.
//// `attach_launch` checks original shared resource custody before publication.
//// `exchange`, `workspace_exchange`, `compile_exchange` and `launch_exchange` enter `owner_exchange`;
//// `bind_launch` enters `owner_bind`; `serve_bind` retains a checked finite
//// installation answer until `receive_acceptance` acknowledges its door.
//// `exchange_command` preserves the complete original physical command route.
//// `reserve` assigns one stable credit. `begin_credit` starts managed transport;
//// `admit` hands off one decoded operation to its concrete service.
//// `native_replied`, `workspace_replied`, `compile_replied` and `launch_replied` settle asks;
//// `network_finished` checks any selectable exact-run handoff before
//// `available` restores capacity; late old handoffs cannot enter a reused credit.
//// `serve` receives bounded content and waits for the stable service answer;
//// `receive_chunks` and `returned_chunks` consume a single acknowledged frame.
////
//// Payloads are closed canonical bytes, transferred one acknowledged chunk at
//// a time. Process references correlate exchanges but never replace durable
//// operation IDs. Distribution is a trusted full-node membership boundary.

import broker/enrollment
import core/command
import core/workspace as cw
import executor/internal/ffi_distribution
import executor/remote/compile_service as compile
import executor/remote/compile_wire
import executor/remote/distribution
import executor/remote/identity
import executor/remote/internal/beam_protocol as protocol
import executor/remote/launch_beam
import executor/remote/launch_service as launch
import executor/remote/launch_wire
import executor/remote/resource_journal as resources
import executor/remote/service
import executor/remote/wire
import executor/remote/workspace_journal as journal
import executor/remote/workspace_service as workspace
import executor/remote/workspace_transfer as transfer
import gleam/bit_array
import gleam/bool
import gleam/dynamic
import gleam/erlang/node
import gleam/erlang/process
import gleam/erlang/reference
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tools/workspace as tw
import tools/workspace_codec as codec
import weft
import weft/actor

/// Closed workspace command exported through the endpoint boundary.
pub type WorkspaceCommand =
  protocol.WorkspaceCommand

/// Exact authenticated executor destination and immutable authority.
pub type Config {
  /// One exact provisioned destination with a finite whole exchange deadline.
  Config(
    /// Peer resolved from boot-time membership.
    peer: distribution.Peer,
    /// Provisioned owner label.
    owner: String,
    /// Provisioned executor label.
    executor: String,
    /// Original authority scope.
    scope: identity.Scope,
    /// Exact transport incarnation.
    generation: Int,
    /// Whole exchange deadline in milliseconds.
    within_ms: Int,
  )
}

/// Failures never authorize reminting an admitted operation.
pub type Error {
  /// Configuration cannot represent an exact finite binding.
  InvalidConfiguration

  /// Canonical input or operation does not match its scope.
  InvalidInvocation

  /// A scope already has a concrete service binding.
  ConflictingRegistration

  /// Delivery or service custody cannot be proved.
  Uncertain

  /// The concrete whole-Compile route is not installed.
  UnsupportedCommand
}

/// Trusted local binding; no network message can construct this value.
pub opaque type Registration {
  /// Checked association unavailable to network enrollment.
  Registration(
    /// Authenticated original owner peer, checked against the actual reply PID.
    owner: distribution.Peer,
    /// Exact labels, authority epochs and transport generation.
    binding: protocol.Binding,
    /// Concrete native endpoint; Compile derives this from its whole owner.
    native: service.Service,
    /// Optional concrete semantic filesystem owner for the same scope.
    workspace: Option(workspace.Service),
    /// Optional concrete whole Compile owner retaining original live Claims.
    compile: Option(compile.Service),
    /// Concrete whole Launch owner on this same original registration.
    launch: Option(launch.Service),
    /// Concrete local scope owner; its applied DOWN permanently fences this row.
    lifetime_owner: process.Pid,
  )
}

/// Checked bounded initial registrations and transport lifetime.
pub opaque type ServerConfig {
  /// One bounded enrollment table and transport lifetime.
  ServerConfig(
    /// Finite immutable initial enrollment, reused by dynamic local checks.
    registrations: List(Registration),
    /// Whole managed transport lifetime, independent of native retirement.
    within_ms: Int,
  )
}

/// Local administrative handle, separate from the fixed network rendezvous.
pub opaque type Server {
  /// A local administrator door attached to one concrete rendezvous PID.
  Server(
    /// Private local administrative door, never registered as a network route.
    subject: process.Subject(Message),
    /// Concrete rendezvous lifetime owned by the embedding supervisor.
    pid: process.Pid,
  )
}

/// Remaining shared credits and occupied lifetime registration slots.
pub type Capacity {
  /// Gauges over the shared finite table and free transport credits.
  Capacity(
    /// Registered concrete scopes, at most sixteen.
    registrations: Int,
    /// Available first-admission and input credits, at most four.
    data: Int,
    /// Available observer and receipt credits, at most two.
    control: Int,
  )
}

type Gate {
  Open
  Closed
}

/// Scoped transport custody after an exact permanent registration fence.
/// Native retirement, semantic continuations and journal release remain separate.
pub type DrainState {
  /// The row is active or an original assigned credit still owns its work.
  Busy

  /// The row is fenced and no credit retains its original assignment.
  Drained

  /// A lost credit permanently retains an unresolved original assignment.
  DrainUncertain
}

type RowGate {
  Active
  Fenced
}

type Row {
  Row(registration: Registration, owner_monitor: process.Monitor, gate: RowGate)
}

type Assignment {
  Assignment(registration: Registration, correlation: reference.Reference)
}

type Disposition {
  Available
  Assigned(Assignment)
  Unusable(Option(Assignment))
}

type CreditRecord {
  CreditRecord(
    lane: protocol.Lane,
    subject: process.Subject(CreditMessage),
    monitor: process.Monitor,
    disposition: Disposition,
  )
}

type State {
  State(rows: List(Row), credits: List(CreditRecord), gate: Gate)
}

type Message {
  Reserve(Reservation)
  Released(process.Subject(CreditMessage), Assignment)
  Down(process.Down)
  Register(Registration, process.Subject(Result(Nil, Error)))
  Fence(Registration, process.Subject(Result(Nil, Error)))
  InspectDrain(Registration, process.Subject(Result(DrainState, Error)))
  Inspect(process.Subject(Capacity))
  Quiesce
  Stop
}

type Reservation {
  Reservation(
    header: BitArray,
    correlation: reference.Reference,
    caller: process.Pid,
    reply: process.Subject(Reply),
  )
}

type Reply {
  Granted(reference.Reference, process.Subject(Frame))
  Consumed(reference.Reference, Int)
  Returned(reference.Reference, Int, BitArray)
  WorkspaceStatus(reference.Reference, BitArray)
  BindReturned(reference.Reference, BitArray, launch_beam.Door)
}

type Frame {
  Input(reference.Reference, Int, BitArray)
  ReplyConsumed(reference.Reference, Int)
  StatusConsumed(reference.Reference)
  BindInput(reference.Reference, BitArray, launch_beam.Door)
}

type Request {
  BindRequest(
    launch_beam.Offer,
    process.Subject(Result(launch_beam.Acceptance, Nil)),
  )
  LaunchRequest(
    launch_wire.Command,
    resources.Input,
    Option(BitArray),
    process.Subject(Result(BitArray, Nil)),
  )
  NativeRequest(wire.Envelope, process.Subject(Result(BitArray, Nil)))
  CompileRequest(
    compile_wire.Command,
    resources.Input,
    process.Subject(Result(BitArray, Nil)),
  )
  CommandRequest(wire.CommandEnvelope, process.Subject(Result(BitArray, Nil)))
  WorkspaceRequest(
    WorkspaceCommand,
    BitArray,
    process.Subject(Result(BitArray, Nil)),
  )
}

type Pending {
  NoAsk
  LaunchAsk(command.ServiceKey, process.Subject(Result(BitArray, Nil)))
  CompileAsk(command.ServiceKey, process.Subject(Result(BitArray, Nil)))
  CommandAsk(command.CommandRef, process.Subject(Result(BitArray, Nil)))
  NativeHello(wire.Envelope, process.Subject(Result(BitArray, Nil)))
  NativeAsk(process.Subject(Result(BitArray, Nil)))
  WorkspaceAsk(process.Subject(Result(BitArray, Nil)))
}

type CreditMessage {
  Begin(Registration, protocol.Route, Reservation)
  Request(reference.Reference, Request)
  NativeReply(Result(wire.Body, service.Error))
  WorkspaceReply(Result(journal.Status, workspace.Error))
  CompileReply(Result(compile.Reply, compile.Error))
  LaunchReply(Result(launch.Reply, launch.Error))
  NetworkReport(weft.Pulled(Nil, Nil))
  ServiceDown
  CloseCredit
}

type Credit {
  Credit(
    parent: process.Subject(Message),
    lane: protocol.Lane,
    within_ms: Int,
    subject: process.Subject(CreditMessage),
    requests: process.Subject(#(reference.Reference, Request)),
    native_reply: process.Subject(Result(wire.Body, service.Error)),
    workspace_reply: process.Subject(Result(journal.Status, workspace.Error)),
    compile_reply: process.Subject(Result(compile.Reply, compile.Error)),
    launch_reply: process.Subject(Result(launch.Reply, launch.Error)),
    selector: process.Selector(CreditMessage),
    network: Option(process.Subject(weft.Pulled(Nil, Nil))),
    registration: Option(Registration),
    pending: Pending,
    monitors: List(process.Monitor),
    correlation: Option(reference.Reference),
  )
}

/// Derives labels and scope from the concrete native service.
///
/// ## Examples
/// `registration(owner_peer, native_service, Some(workspace_service), process.self())`
/// binds both to their concrete local lifetime owner.
pub fn registration(
  owner: distribution.Peer,
  native: service.Service,
  semantic: Option(workspace.Service),
  lifetime_owner: process.Pid,
) -> Result(Registration, Error) {
  use <- bool.guard(
    ffi_distribution.pid_node(lifetime_owner) != node.self(),
    Error(InvalidConfiguration),
  )
  let config = service.configuration(native)
  let binding =
    protocol.Binding(
      config.owner,
      config.executor,
      config.generation,
      config.scope,
    )
  use <- bool.guard(
    case semantic {
      None -> False
      Some(value) -> semantic_scope(binding.scope) != Ok(workspace.scope(value))
    },
    Error(InvalidConfiguration),
  )
  Ok(Registration(owner, binding, native, semantic, None, None, lifetime_owner))
}

/// Derives native and enrollment authority from the concrete whole Compile owner.
///
/// ## Examples
/// `compile_registration(owner_peer, whole, None, process.self())` retains native authority.
pub fn compile_registration(
  owner: distribution.Peer,
  whole: compile.Service,
  semantic: Option(workspace.Service),
  lifetime_owner: process.Pid,
) -> Result(Registration, Error) {
  use row <- result.try(registration(
    owner,
    compile.native_service(whole),
    semantic,
    lifetime_owner,
  ))
  use <- bool.guard(
    semantic_scope(row.binding.scope) != Ok(compile.scope(whole)),
    Error(InvalidConfiguration),
  )
  Ok(Registration(..row, compile: Some(whole)))
}

/// Attaches a concrete Launch owner without creating a second same-scope row.
///
/// ## Examples
///
/// ```gleam
/// beam_endpoint.attach_launch(original_row, whole_launch) // -> Ok(same_row).
/// ```
pub fn attach_launch(
  row: Registration,
  whole: launch.Service,
) -> Result(Registration, Error) {
  use <- bool.guard(
    row.launch != None
      || row.native != launch.native_service(whole)
      || semantic_scope(row.binding.scope) != Ok(launch.scope(whole)),
    Error(InvalidConfiguration),
  )
  use <- bool.guard(
    case row.compile {
      None -> False
      Some(compiled) ->
        compile.resource_owner(compiled) != launch.resource_owner(whole)
        || enrollment.matches(
          compile.enrolled(compiled),
          launch.enrolled(whole),
        )
        != Ok(Nil)
    },
    Error(InvalidConfiguration),
  )
  Ok(Registration(..row, launch: Some(whole)))
}

/// Checks the same finite table used by later local registrations.
///
/// ## Examples
/// `configure_server([], 5000)` creates an empty dynamically enrolled endpoint.
pub fn configure_server(
  registrations: List(Registration),
  within_ms: Int,
) -> Result(ServerConfig, Error) {
  use <- bool.guard(
    within_ms < 100 || within_ms > 30_000,
    Error(InvalidConfiguration),
  )
  use checked <- result.try(list.try_fold(registrations, [], add_registration))
  Ok(ServerConfig(checked, within_ms))
}

/// Starts six stable credits and publishes one fixed rendezvous.
///
/// ## Examples
/// `start(config)` returns the local administrative handle.
pub fn start(config: ServerConfig) -> Result(Server, Error) {
  use started <- result.try(
    builder(config) |> actor.start |> result.replace_error(InvalidConfiguration),
  )
  let server = Server(started.data, started.pid)
  case distribution.register_endpoint(started.pid) {
    Ok(Nil) -> Ok(server)
    Error(_) -> {
      stop(server)
      Error(InvalidConfiguration)
    }
  }
}

/// Enrolls a concrete local scope once; no removal can erase unresolved custody.
///
/// ## Examples
/// `register(server, registration)` refuses a duplicate scope.
pub fn register(
  server: Server,
  registration: Registration,
) -> Result(Nil, Error) {
  let reply = process.new_subject()
  process.send(server.subject, Register(registration, reply))
  process.receive(reply, 1000) |> result.unwrap(Error(Uncertain))
}

/// Permanently fences the exact original row before services stop.
/// The acknowledgement proves application of the fence, never transport drain.
/// Registration and cleanup fencing must be sent in order by the same owner.
///
/// ## Examples
/// `fence(server, original_row)` is idempotent for that exact registration.
pub fn fence(server: Server, exact_row: Registration) -> Result(Nil, Error) {
  let reply = process.new_subject()
  process.send(server.subject, Fence(exact_row, reply))
  process.receive(reply, 1000) |> result.unwrap(Error(Uncertain))
}

/// Scans six original credit dispositions for an exact permanently enrolled row.
/// Active rows report Busy. Unusable original assignments take precedence over
/// busy ones. A timeout or endpoint loss cannot manufacture a Drained answer.
///
/// ## Examples
/// `inspect_drain(server, original_row)` returns Ok(Drained) only after fencing.
pub fn inspect_drain(
  server: Server,
  exact_row: Registration,
) -> Result(DrainState, Error) {
  let reply = process.new_subject()
  process.send(server.subject, InspectDrain(exact_row, reply))
  process.receive(reply, 1000) |> result.unwrap(Error(Uncertain))
}

/// Observes the bounded table and shared free credits.
///
/// ## Examples
/// `inspect(server)` reports at most four data and two control credits.
pub fn inspect(server: Server) -> Result(Capacity, Error) {
  let reply = process.new_subject()
  process.send(server.subject, Inspect(reply))
  process.receive(reply, 1000) |> result.replace_error(Uncertain)
}

/// Stops admission without claiming effect retirement.
///
/// ## Examples
/// `quiesce(server)` precedes the host's separate native drain.
pub fn quiesce(server: Server) -> Nil {
  process.send(server.subject, Quiesce)
}

/// Stops transport actors; the host retains responsibility for native custody.
///
/// ## Examples
/// `stop(server)` does not permit journal deletion.
pub fn stop(server: Server) -> Nil {
  process.send(server.subject, Stop)
}

/// Returns the supervised endpoint process.
///
/// ## Examples
/// `pid(server)` can be monitored by its embedding host.
pub fn pid(server: Server) -> process.Pid {
  server.pid
}

/// Validates direct Config construction before any network action.
///
/// ## Examples
/// `validate(config)` checks labels, authority and a finite deadline.
pub fn validate(config: Config) -> Result(Nil, Error) {
  client_binding(config) |> result.map(fn(_) { Nil })
}

/// Exchanges one canonical native request under one whole deadline.
///
/// ## Examples
/// `exchange(config, wire.Hello)` checks exact peer, scope and generation.
pub fn exchange(config: Config, body: wire.Body) -> Result(wire.Body, Error) {
  use binding <- result.try(client_binding(config))
  use lane <- result.try(
    protocol.lane(body) |> result.replace_error(InvalidInvocation),
  )
  use bytes <- result.try(
    wire.encode(protocol.envelope(binding, wire.Owner, body))
    |> result.replace_error(InvalidInvocation),
  )
  bounded(config.within_ms, fn() {
    use bytes <- result.try(owner_exchange(
      config,
      binding,
      protocol.Native(lane),
      bytes,
    ))
    protocol.native(binding, wire.Executor, bytes)
    |> result.map(fn(envelope) { envelope.body })
  })
}

/// Routes each physical command through its matching retained whole-service owner.
///
/// ## Examples
/// `exchange_command(config, original_reference, body)` retains the live Claim route.
pub fn exchange_command(
  config: Config,
  ref: command.CommandRef,
  body: wire.Body,
) -> Result(wire.Body, Error) {
  use binding <- result.try(client_binding(config))
  use lane <- result.try(
    protocol.lane(body) |> result.replace_error(InvalidInvocation),
  )
  use envelope <- result.try(
    wire.command_envelope(ref, protocol.envelope(binding, wire.Owner, body))
    |> result.replace_error(InvalidInvocation),
  )
  use bytes <- result.try(
    wire.encode_command(envelope) |> result.replace_error(InvalidInvocation),
  )
  bounded(config.within_ms, fn() {
    use returned <- result.try(owner_exchange(
      config,
      binding,
      protocol.NativeCommand(lane),
      bytes,
    ))
    use answer <- result.try(
      wire.decode_command(
        returned,
        wire.Executor,
        binding.owner,
        binding.executor,
        binding.scope,
      )
      |> result.replace_error(Nil),
    )
    use exact <- result.try(
      wire.encode_command(answer) |> result.replace_error(Nil),
    )
    let native = wire.native_envelope(answer)
    use <- bool.guard(
      wire.command_ref(answer) != ref
        || native.generation != binding.generation
        || exact != returned,
      Error(Nil),
    )
    Ok(native.body)
  })
}

/// Exchanges canonical Compile input and returns unchanged bounded reply segments.
/// The consumer checks enrollment, full key and semantic completion.
///
/// ## Examples
/// `compile_exchange(config, compile_wire.Query, canonical_input)` observes history.
pub fn compile_exchange(
  config: Config,
  operation: compile_wire.Command,
  bytes: BitArray,
) -> Result(#(BitArray, Option(BitArray)), Error) {
  use binding <- result.try(client_binding(config))
  use _ <- result.try(
    compile_wire.encode_command(operation)
    |> result.replace_error(InvalidInvocation),
  )
  bounded(config.within_ms, fn() {
    use returned <- result.try(owner_exchange(
      config,
      binding,
      protocol.Compile(operation),
      bytes,
    ))
    decode_segments(returned)
  })
}

/// Exchanges finite Launch control data without creating a live channel.
///
/// ## Examples
///
/// ```gleam
/// beam_endpoint.launch_exchange(config, launch_wire.Query, canonical_input)
/// ```
pub fn launch_exchange(
  config: Config,
  operation: launch_wire.Command,
  bytes: BitArray,
) -> Result(#(BitArray, Option(BitArray)), Error) {
  use binding <- result.try(client_binding(config))
  use _ <- result.try(
    launch_wire.encode_command(operation)
    |> result.replace_error(InvalidInvocation),
  )
  bounded(config.within_ms, fn() {
    use returned <- result.try(owner_exchange(
      config,
      binding,
      protocol.Launch(operation),
      bytes,
    ))
    decode_segments(returned)
  })
}

/// Installs the original Launch host through one finite control credit.
/// A lost answer remains uncertain and must not cause a new bind attempt.
/// Socket acceptance and stream drain belong to the returned bridge actor.
///
/// ## Examples
/// `bind_launch(config, launch_beam.offer(owner))` returns its checked acceptance.
pub fn bind_launch(
  config: Config,
  offered: launch_beam.Offer,
) -> Result(launch_beam.Acceptance, Error) {
  use binding <- result.try(client_binding(config))
  bounded(config.within_ms, fn() { owner_bind(config, binding, offered) })
}

/// Exchanges one exact semantic invocation and validates any completion.
///
/// ## Examples
/// `workspace_exchange(config, query(), invocation_bytes)` recovers its status.
pub fn workspace_exchange(
  config: Config,
  operation: WorkspaceCommand,
  bytes: BitArray,
) -> Result(journal.Status, Error) {
  use binding <- result.try(client_binding(config))
  use invocation <- result.try(
    checked_invocation(binding, bytes)
    |> result.replace_error(InvalidInvocation),
  )
  bounded(config.within_ms, fn() {
    use returned <- result.try(owner_exchange(
      config,
      binding,
      protocol.Workspace(operation),
      bytes,
    ))
    use status <- result.try(protocol.decode_status(returned))
    case status {
      journal.Finished(completion) -> {
        use _ <- result.try(
          codec.decode_completion(tw.request(invocation), completion)
          |> result.replace_error(Nil),
        )
        Ok(status)
      }
      journal.Accepted
      | journal.Unknown
      | journal.Acknowledged(_)
      | journal.Cancelled -> Ok(status)
    }
  })
}

fn client_binding(config: Config) -> Result(protocol.Binding, Error) {
  use _ <- result.try(
    identity.executor_id(config.owner)
    |> result.replace_error(InvalidConfiguration),
  )
  let #(_, _, executor, _, _) = identity.scope_fields(config.scope)
  use <- bool.guard(
    config.executor != executor
      || config.generation < 1
      || config.generation > 2_147_483_647
      || config.within_ms < 1
      || config.within_ms > 30_000,
    Error(InvalidConfiguration),
  )
  Ok(protocol.Binding(
    config.owner,
    config.executor,
    config.generation,
    config.scope,
  ))
}

fn add_registration(
  rows: List(Registration),
  row: Registration,
) -> Result(List(Registration), Error) {
  use <- bool.guard(
    list.any(rows, fn(old) { old.binding.scope == row.binding.scope }),
    Error(ConflictingRegistration),
  )
  use <- bool.guard(list.drop(rows, 15) != [], Error(InvalidConfiguration))
  Ok([row, ..rows])
}

fn semantic_scope(scope: identity.Scope) -> Result(cw.Scope, Nil) {
  let #(session, workspace, executor, session_epoch, workspace_epoch) =
    identity.scope_fields(scope)
  cw.scope_from_fields(
    session,
    workspace,
    executor,
    session_epoch,
    workspace_epoch,
  )
  |> result.replace_error(Nil)
}

fn builder(
  config: ServerConfig,
) -> actor.Builder(State, Message, process.Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    use data <- result.try(
      list.try_map(list.repeat(Nil, 4), fn(_) {
        start_credit(subject, protocol.Data, config.within_ms)
        |> result.replace_error("data credit startup failed")
      }),
    )
    use control <- result.try(
      list.try_map(list.repeat(Nil, 2), fn(_) {
        start_credit(subject, protocol.Control, config.within_ms)
        |> result.replace_error("control credit startup failed")
      }),
    )
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(rendezvous(process.self()), Reserve)
      |> process.select_monitors(Down)
    Ok(
      actor.initialised(State(
        list.map(config.registrations, monitored_row),
        list.append(data, control),
        Open,
      ))
      |> actor.selecting(selector)
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle)
  |> actor.trapping_exits(True)
}

fn rendezvous(pid: process.Pid) -> process.Subject(Reservation) {
  process.unsafely_create_subject(
    pid,
    dynamic.string("loom.executor.endpoint/1"),
  )
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Reserve(reservation) -> reserve(state, reservation)
    Released(subject, original) -> {
      // Only this concrete actor's current original assignment can restore it.
      let credits =
        list.map(state.credits, fn(credit) {
          case credit.subject == subject, credit.disposition {
            True, Assigned(current) if current == original ->
              CreditRecord(..credit, disposition: Available)
            _, _ -> credit
          }
        })
      actor.continue(State(..state, credits: credits))
    }
    Down(process.ProcessDown(monitor, _, _)) -> {
      // Idle loss removes capacity without inventing a scope obligation. Busy
      // loss preserves the original row and correlation for the entire lifetime.
      let credits =
        list.map(state.credits, fn(credit) {
          case credit.monitor == monitor, credit.disposition {
            True, Available ->
              CreditRecord(..credit, disposition: Unusable(None))
            True, Assigned(original) ->
              CreditRecord(..credit, disposition: Unusable(Some(original)))
            _, _ -> credit
          }
        })
      let rows =
        list.map(state.rows, fn(row) {
          case row.owner_monitor == monitor {
            True -> Row(..row, gate: Fenced)
            False -> row
          }
        })
      actor.continue(State(..state, rows: rows, credits: credits))
    }
    Down(process.PortDown(_, _, _)) -> actor.continue(state)
    Register(row, reply) -> {
      let added = case state.gate {
        Open ->
          add_registration(
            list.map(state.rows, fn(row) { row.registration }),
            row,
          )
        Closed -> Error(InvalidConfiguration)
      }
      case added {
        Ok(_) -> {
          // Monitoring precedes eligibility. An already-dead owner queues DOWN;
          // reservations racing before its applied fence can still lose capacity.
          let next = State(..state, rows: [monitored_row(row), ..state.rows])
          process.send(reply, Ok(Nil))
          actor.continue(next)
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }
    Fence(exact, reply) -> {
      case exact_row(state, exact) {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(_) -> {
          let rows =
            list.map(state.rows, fn(row) {
              case row.registration == exact {
                True -> Row(..row, gate: Fenced)
                False -> row
              }
            })
          let next = State(..state, rows: rows)
          process.send(reply, Ok(Nil))
          actor.continue(next)
        }
      }
    }
    InspectDrain(exact, reply) -> {
      process.send(reply, drain_snapshot(state, exact))
      actor.continue(state)
    }
    Inspect(reply) -> {
      process.send(
        reply,
        Capacity(
          list.length(state.rows),
          available_count(state.credits, protocol.Data),
          available_count(state.credits, protocol.Control),
        ),
      )
      actor.continue(state)
    }
    Quiesce -> actor.continue(State(..state, gate: Closed))
    Stop -> {
      list.each(state.credits, fn(credit) {
        process.send(credit.subject, CloseCredit)
      })
      actor.stop()
    }
  }
}

fn monitored_row(registration: Registration) -> Row {
  Row(registration, process.monitor(registration.lifetime_owner), Active)
}

fn exact_row(state: State, exact: Registration) -> Result(Row, Error) {
  list.find(state.rows, fn(row) { row.registration == exact })
  |> result.replace_error(InvalidConfiguration)
}

fn drain_snapshot(
  state: State,
  exact: Registration,
) -> Result(DrainState, Error) {
  use row <- result.try(exact_row(state, exact))
  case row.gate {
    Active -> Ok(Busy)
    Fenced -> {
      let lost =
        list.any(state.credits, fn(credit) {
          case credit.disposition {
            Unusable(Some(original)) -> original.registration == exact
            Available | Assigned(_) | Unusable(None) -> False
          }
        })
      let assigned =
        list.any(state.credits, fn(credit) {
          case credit.disposition {
            Assigned(original) -> original.registration == exact
            Available | Unusable(_) -> False
          }
        })
      case lost, assigned {
        True, _ -> Ok(DrainUncertain)
        False, True -> Ok(Busy)
        False, False -> Ok(Drained)
      }
    }
  }
}

fn available_count(credits: List(CreditRecord), lane: protocol.Lane) -> Int {
  list.fold(credits, 0, fn(count, credit) {
    case credit.lane == lane && credit.disposition == Available {
      True -> count + 1
      False -> count
    }
  })
}

fn reserve(
  state: State,
  reservation: Reservation,
) -> actor.Next(State, Message) {
  let admitted = case
    state.gate == Open
    && process.subject_owner(reservation.reply) == Ok(reservation.caller)
  {
    False -> Error(Nil)
    True ->
      list.find_map(state.rows, fn(row) {
        let registration = row.registration
        use <- bool.guard(
          row.gate != Active
            || !distribution.owns(registration.owner, reservation.caller),
          Error(Nil),
        )
        protocol.decode_header(registration.binding, reservation.header)
        |> result.map(fn(route) { #(registration, route) })
      })
  }
  case admitted {
    Error(_) -> actor.continue(state)
    Ok(#(row, route)) -> {
      let lane = protocol.route_lane(route)
      case
        list.find(state.credits, fn(credit) {
          credit.lane == lane && credit.disposition == Available
        })
      {
        Error(_) -> actor.continue(state)
        Ok(selected) -> {
          // Record original custody before publishing Begin. Neither a fence nor
          // DOWN can later return this assignment without its matching release.
          let original = Assignment(row, reservation.correlation)
          let credits =
            list.map(state.credits, fn(credit) {
              case credit.subject == selected.subject {
                True -> CreditRecord(..credit, disposition: Assigned(original))
                False -> credit
              }
            })
          let next = State(..state, credits: credits)
          process.send(selected.subject, Begin(row, route, reservation))
          actor.continue(next)
        }
      }
    }
  }
}

fn start_credit(
  parent: process.Subject(Message),
  lane: protocol.Lane,
  within_ms: Int,
) -> Result(CreditRecord, actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let requests = process.new_subject()
    let native_reply = process.new_subject()
    let workspace_reply = process.new_subject()
    let compile_reply = process.new_subject()
    let launch_reply = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(
        requests,
        fn(handoff: #(reference.Reference, Request)) {
          Request(handoff.0, handoff.1)
        },
      )
      |> process.select_map(native_reply, NativeReply)
      |> process.select_map(workspace_reply, WorkspaceReply)
      |> process.select_map(compile_reply, CompileReply)
      |> process.select_map(launch_reply, LaunchReply)
    Ok(
      actor.initialised(Credit(
        parent,
        lane,
        within_ms,
        subject,
        requests,
        native_reply,
        workspace_reply,
        compile_reply,
        launch_reply,
        selector,
        None,
        None,
        NoAsk,
        [],
        None,
      ))
      |> actor.selecting(selector)
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle_credit)
  |> actor.trapping_exits(True)
  |> actor.start
  |> result.map(fn(started) {
    CreditRecord(lane, started.data, process.monitor(started.pid), Available)
  })
}

fn handle_credit(
  state: Credit,
  message: CreditMessage,
) -> actor.Next(Credit, CreditMessage) {
  case message {
    Begin(row, route, reservation) ->
      begin_credit(state, row, route, reservation)
    Request(correlation, request) -> {
      // Retirement may overtake a handoff from another sender. Its exact run
      // reference must still own this credit before service admission begins.
      case state.correlation == Some(correlation) {
        True -> admit(state, request)
        False -> actor.continue(state)
      }
    }
    NativeReply(reply) -> native_replied(state, reply)
    WorkspaceReply(reply) -> workspace_replied(state, reply)
    CompileReply(reply) -> compile_replied(state, reply)
    LaunchReply(reply) -> launch_replied(state, reply)
    NetworkReport(weft.AllDelivered) -> network_finished(state)
    NetworkReport(weft.RunLost(_)) | ServiceDown | CloseCredit -> actor.stop()
    NetworkReport(weft.PulledOutcome(_)) | NetworkReport(weft.NotYet) ->
      actor.continue(state)
  }
}

fn begin_credit(
  state: Credit,
  row: Registration,
  route: protocol.Route,
  reservation: Reservation,
) -> actor.Next(Credit, CreditMessage) {
  case state.network, state.pending {
    None, NoAsk -> {
      let reports = process.new_subject()
      let requests = state.requests
      let native_monitor = process.monitor(service.pid(row.native))
      let selector =
        state.selector
        |> process.select_map(reports, NetworkReport)
        |> process.select_specific_monitor(native_monitor, fn(_) { ServiceDown })
      let #(selector, monitors) = case row.workspace {
        None -> #(selector, [native_monitor])
        Some(semantic) -> {
          let monitor = process.monitor(workspace.pid(semantic))
          #(
            process.select_specific_monitor(selector, monitor, fn(_) {
              ServiceDown
            }),
            [monitor, native_monitor],
          )
        }
      }

      let #(selector, monitors) = case row.compile {
        None -> #(selector, monitors)
        Some(whole) -> {
          let monitor = process.monitor(compile.pid(whole))
          #(
            process.select_specific_monitor(selector, monitor, fn(_) {
              ServiceDown
            }),
            [monitor, ..monitors],
          )
        }
      }

      let #(selector, monitors) = case row.launch {
        None -> #(selector, monitors)
        Some(whole) -> {
          let monitor = process.monitor(launch.pid(whole))
          #(
            process.select_specific_monitor(selector, monitor, fn(_) {
              ServiceDown
            }),
            [monitor, ..monitors],
          )
        }
      }

      // Stable credit subjects own service custody; managed tasks own only transport.
      weft.new_prepared([
        weft.managed(fn(_) { serve(row, route, reservation, requests) }),
      ])
      |> weft.deadline(state.within_ms)
      |> weft.cancel_when_exits(process.self())
      |> weft.cancel_when_exits(reservation.caller)
      |> weft.start_relayed(reports)
      actor.continue(
        Credit(
          ..state,
          network: Some(reports),
          registration: Some(row),
          selector: selector,
          monitors: monitors,
          correlation: Some(reservation.correlation),
        ),
      )
      |> actor.with_selector(selector)
    }
    _, _ -> actor.stop()
  }
}

fn admit(state: Credit, request: Request) -> actor.Next(Credit, CreditMessage) {
  case state.registration, state.pending, request {
    Some(row), NoAsk, BindRequest(offered, reply) -> {
      case row.launch {
        None -> {
          process.send(reply, Error(Nil))
          available(state)
        }
        Some(whole) -> {
          // Only the finite local Installed acknowledgement runs in this credit.
          // The original stream actor owns socket acceptance and its deadline.
          case launch_beam.serve(whole, row.owner, row.binding, offered) {
            Ok(executor) -> {
              process.send(reply, Ok(launch_beam.acceptance(executor)))
              available(state)
            }
            Error(launch_beam.Invalid) -> {
              process.send(reply, Error(Nil))
              available(state)
            }
            Error(launch_beam.Uncertain) -> {
              process.send(reply, Error(Nil))

              // Installation may have reached original owner custody. Actor loss
              // retains this assignment after the network worker retires.
              actor.stop()
            }
          }
        }
      }
    }
    Some(row), NoAsk, NativeRequest(envelope, reply) -> {
      service.send_exchange(
        row.native,
        protocol.envelope(row.binding, wire.Owner, wire.Hello),
        state.native_reply,
      )
      actor.continue(Credit(..state, pending: NativeHello(envelope, reply)))
    }
    Some(row), NoAsk, WorkspaceRequest(operation, bytes, reply) ->
      case row.workspace {
        None -> {
          process.send(reply, Error(Nil))
          available(state)
        }
        Some(semantic) -> {
          let operation = case operation {
            protocol.Submit -> workspace.SubmitOperation
            protocol.Query -> workspace.QueryOperation
            protocol.Acknowledge(digest) ->
              workspace.AcknowledgeOperation(identity.digest_bytes(digest))
          }
          workspace.send_operation(
            semantic,
            operation,
            bytes,
            state.workspace_reply,
          )
          actor.continue(Credit(..state, pending: WorkspaceAsk(reply)))
        }
      }
    Some(row), NoAsk, CompileRequest(operation, original, reply) ->
      case row.compile {
        None -> {
          process.send(reply, Error(Nil))
          available(state)
        }
        Some(whole) -> {
          let key = original.key
          let operation = case operation {
            compile_wire.ChallengeRequest -> compile.ChallengeRequest(key)
            compile_wire.Submit(nonce, budget) ->
              compile.Submit(original, nonce, budget)
            compile_wire.Query -> compile.Query(key)
            compile_wire.Cancel -> compile.Cancel(original)
            compile_wire.Acknowledge(digest) -> compile.Acknowledge(key, digest)
          }
          let scope = compile.scope(whole)
          let caller =
            compile.Caller(
              wire.Owner,
              row.binding.owner,
              row.binding.executor,
              row.binding.generation,
              scope,
            )
          compile.send_operation(whole, caller, operation, state.compile_reply)
          actor.continue(Credit(..state, pending: CompileAsk(key, reply)))
        }
      }
    Some(row), NoAsk, LaunchRequest(operation, original, token, reply) -> {
      case row.launch {
        None -> {
          process.send(reply, Error(Nil))
          available(state)
        }
        Some(whole) -> {
          let key = original.key
          let operation = case operation, token {
            launch_wire.ChallengeRequest, None ->
              Ok(launch.ChallengeRequest(key))
            launch_wire.PlaceToken(nonce, budget), Some(token) ->
              Ok(launch.PlaceToken(original, nonce, budget, token))
            launch_wire.Query, None -> Ok(launch.Query(key))
            launch_wire.Cancel, None -> Ok(launch.Cancel(original))
            launch_wire.Acknowledge(digest), None ->
              Ok(launch.Acknowledge(key, digest))
            launch_wire.RefuseBeforeNative, None ->
              Ok(launch.RefuseBeforeNative(
                original,
                "owner clearance refused before native dispatch",
              ))
            _, _ -> Error(Nil)
          }
          case operation {
            Error(Nil) -> actor.stop()
            Ok(operation) -> {
              launch.send_operation(
                whole,
                launch.Caller(
                  wire.Owner,
                  row.binding.owner,
                  row.binding.executor,
                  row.binding.generation,
                  launch.scope(whole),
                ),
                operation,
                state.launch_reply,
              )
              actor.continue(Credit(..state, pending: LaunchAsk(key, reply)))
            }
          }
        }
      }
    }
    Some(row), NoAsk, CommandRequest(envelope, reply) -> {
      let routed = case
        command.service_role(command.service(wire.command_ref(envelope)))
      {
        command.CompileService ->
          case row.compile {
            None -> Error(Nil)
            Some(whole) -> {
              compile.send_command_exchange(whole, envelope, state.native_reply)
              Ok(Nil)
            }
          }
        command.LaunchService ->
          case row.launch {
            None -> Error(Nil)
            Some(whole) -> {
              launch.send_command_exchange(whole, envelope, state.native_reply)
              Ok(Nil)
            }
          }
      }
      case routed {
        Error(Nil) -> {
          process.send(reply, Error(Nil))
          available(state)
        }
        Ok(Nil) ->
          actor.continue(
            Credit(
              ..state,
              pending: CommandAsk(wire.command_ref(envelope), reply),
            ),
          )
      }
    }
    _, _, _ -> actor.stop()
  }
}

fn native_replied(
  state: Credit,
  answer: Result(wire.Body, service.Error),
) -> actor.Next(Credit, CreditMessage) {
  case state.registration, state.pending, answer {
    Some(row), NativeHello(envelope, reply), Ok(wire.Hello) -> {
      service.send_exchange(row.native, envelope, state.native_reply)
      actor.continue(Credit(..state, pending: NativeAsk(reply)))
    }
    Some(row), NativeAsk(reply), answer -> {
      let response =
        wire.encode(protocol.envelope(
          row.binding,
          wire.Executor,
          native_answer(answer),
        ))
        |> result.replace_error(Nil)
      process.send(reply, response)
      case answer {
        Error(service.Uncertain) -> actor.stop()
        Ok(_) | Error(_) -> available(Credit(..state, pending: NoAsk))
      }
    }
    Some(row), CommandAsk(ref, reply), answer -> {
      let response = {
        use envelope <- result.try(
          wire.command_envelope(
            ref,
            protocol.envelope(row.binding, wire.Executor, native_answer(answer)),
          )
          |> result.replace_error(Nil),
        )
        wire.encode_command(envelope) |> result.replace_error(Nil)
      }
      process.send(reply, response)
      case answer {
        Error(service.Uncertain) -> actor.stop()
        Ok(_) | Error(_) -> available(Credit(..state, pending: NoAsk))
      }
    }
    _, _, _ -> actor.stop()
  }
}

fn compile_replied(
  state: Credit,
  answer: Result(compile.Reply, compile.Error),
) -> actor.Next(Credit, CreditMessage) {
  case state.pending {
    CompileAsk(key, reply) -> {
      let encoded =
        compile_wire.encode_reply(key, answer)
        |> result.replace_error(Nil)
        |> result.try(encode_segments)
      process.send(reply, encoded)
      case answer {
        Error(compile.Uncertain)
        | Error(compile.Custody(resources.Uncertain)) -> actor.stop()
        Ok(_) | Error(_) -> available(Credit(..state, pending: NoAsk))
      }
    }
    NoAsk
    | LaunchAsk(_, _)
    | CommandAsk(_, _)
    | NativeHello(_, _)
    | NativeAsk(_)
    | WorkspaceAsk(_) -> actor.stop()
  }
}

fn launch_replied(
  state: Credit,
  answer: Result(launch.Reply, launch.Error),
) -> actor.Next(Credit, CreditMessage) {
  case state.pending {
    LaunchAsk(key, reply) -> {
      let encoded =
        launch_wire.encode_reply(key, answer)
        |> result.replace_error(Nil)
        |> result.try(encode_segments)
      process.send(reply, encoded)
      case answer {
        Error(launch.Uncertain) | Error(launch.Custody(resources.Uncertain)) ->
          actor.stop()
        Ok(_) | Error(_) -> available(Credit(..state, pending: NoAsk))
      }
    }
    NoAsk
    | CompileAsk(_, _)
    | CommandAsk(_, _)
    | NativeHello(_, _)
    | NativeAsk(_)
    | WorkspaceAsk(_) -> actor.stop()
  }
}

fn workspace_replied(
  state: Credit,
  answer: Result(journal.Status, workspace.Error),
) -> actor.Next(Credit, CreditMessage) {
  case state.pending {
    WorkspaceAsk(reply) -> {
      process.send(
        reply,
        result.map(answer, protocol.status) |> result.replace_error(Nil),
      )
      case answer {
        Error(workspace.Uncertain)
        | Error(workspace.Custody(journal.Uncertain)) -> actor.stop()
        Ok(_) | Error(_) -> available(Credit(..state, pending: NoAsk))
      }
    }
    NoAsk
    | LaunchAsk(_, _)
    | CompileAsk(_, _)
    | CommandAsk(_, _)
    | NativeHello(_, _)
    | NativeAsk(_) -> actor.stop()
  }
}

fn network_finished(state: Credit) -> actor.Next(Credit, CreditMessage) {
  case state.network {
    None -> actor.stop()
    Some(reports) -> {
      let selector = process.deselect(state.selector, reports)
      let state = Credit(..state, network: None, selector: selector)

      // Only currently delivered, exact-run handoffs may enter service custody.
      // AllDelivered proves producer retirement, not cross-sender message arrival.
      case process.receive(state.requests, 0) {
        Ok(#(correlation, request)) ->
          case state.correlation == Some(correlation) {
            True -> admit(state, request)
            False -> available(state)
          }
        Error(_) -> available(state)
      }
      |> actor.with_selector(selector)
    }
  }
}

fn available(state: Credit) -> actor.Next(Credit, CreditMessage) {
  case state.network, state.pending {
    None, NoAsk -> {
      list.each(state.monitors, process.demonitor_process)
      let selector =
        list.fold(
          state.monitors,
          state.selector,
          process.deselect_specific_monitor,
        )
      case state.registration, state.correlation {
        Some(row), Some(correlation) ->
          process.send(
            state.parent,
            Released(state.subject, Assignment(row, correlation)),
          )
        _, _ -> Nil
      }
      actor.continue(
        Credit(
          ..state,
          registration: None,
          monitors: [],
          selector: selector,
          correlation: None,
        ),
      )
      |> actor.with_selector(selector)
    }
    _, _ -> actor.continue(state)
  }
}

fn serve(
  row: Registration,
  route: protocol.Route,
  reservation: Reservation,
  requests: process.Subject(#(reference.Reference, Request)),
) -> Result(Nil, Nil) {
  let incoming = process.new_subject()
  use _ <- result.try(sent(
    reservation.reply,
    Granted(reservation.correlation, incoming),
  ))
  case route {
    protocol.LaunchBind -> serve_bind(row, reservation, incoming, requests)
    protocol.Native(_)
    | protocol.NativeCommand(_)
    | protocol.Workspace(_)
    | protocol.Compile(_)
    | protocol.Launch(_) -> {
      use bytes <- result.try(receive_input(route, reservation, incoming))
      let reply = process.new_subject()
      use request <- result.try(decode_request(row, route, bytes, reply))
      process.send(requests, #(reservation.correlation, request))
      use bytes <- result.try(process.receive_forever(reply))
      return_output(route, reservation, incoming, bytes)
    }
  }
}

// The exact acceptance stays in this transport task until its single ACK.
fn serve_bind(
  row: Registration,
  reservation: Reservation,
  incoming: process.Subject(Frame),
  requests: process.Subject(#(reference.Reference, Request)),
) -> Result(Nil, Nil) {
  use offered <- result.try(case process.receive_forever(incoming) {
    BindInput(ref, bytes, door) if ref == reservation.correlation ->
      launch_beam.offer_from_wire(row.owner, bytes, door)
      |> result.replace_error(Nil)
    BindInput(_, _, _)
    | Input(_, _, _)
    | ReplyConsumed(_, _)
    | StatusConsumed(_) -> Error(Nil)
  })
  let reply = process.new_subject()
  process.send(requests, #(reservation.correlation, BindRequest(offered, reply)))
  use accepted <- result.try(process.receive_forever(reply))
  let #(bytes, door) = launch_beam.acceptance_fields(accepted)
  use _ <- result.try(sent(
    reservation.reply,
    BindReturned(reservation.correlation, bytes, door),
  ))
  consumed(incoming, reservation.correlation, 0)
}

fn decode_request(
  row: Registration,
  route: protocol.Route,
  bytes: BitArray,
  reply: process.Subject(Result(BitArray, Nil)),
) -> Result(Request, Nil) {
  let binding = row.binding
  case route {
    protocol.LaunchBind -> Error(Nil)
    protocol.Native(lane) -> {
      use envelope <- result.try(protocol.native(binding, wire.Owner, bytes))
      use actual <- result.try(protocol.lane(envelope.body))
      use <- bool.guard(actual != lane, Error(Nil))
      Ok(NativeRequest(envelope, reply))
    }
    protocol.NativeCommand(lane) -> {
      use envelope <- result.try(
        wire.decode_command(
          bytes,
          wire.Owner,
          binding.owner,
          binding.executor,
          binding.scope,
        )
        |> result.replace_error(Nil),
      )
      use exact <- result.try(
        wire.encode_command(envelope) |> result.replace_error(Nil),
      )
      let native = wire.native_envelope(envelope)
      use actual <- result.try(protocol.lane(native.body))
      use <- bool.guard(
        actual != lane
          || native.generation != binding.generation
          || exact != bytes,
        Error(Nil),
      )
      Ok(CommandRequest(envelope, reply))
    }
    protocol.Compile(operation) ->
      case row.compile {
        None -> Error(Nil)
        Some(whole) -> {
          use original <- result.try(
            compile_wire.decode_input(compile.enrolled(whole), bytes)
            |> result.replace_error(Nil),
          )
          Ok(CompileRequest(operation, original, reply))
        }
      }
    protocol.Launch(operation) ->
      case row.launch {
        None -> Error(Nil)
        Some(whole) -> {
          use #(original, token) <- result.try(case operation {
            launch_wire.PlaceToken(_, _) ->
              launch_wire.decode_placement(launch.enrolled(whole), bytes)
              |> result.map(fn(pair) { #(pair.0, Some(pair.1)) })
              |> result.replace_error(Nil)
            launch_wire.ChallengeRequest
            | launch_wire.Query
            | launch_wire.Cancel
            | launch_wire.Acknowledge(_)
            | launch_wire.RefuseBeforeNative ->
              launch_wire.decode_input(launch.enrolled(whole), bytes)
              |> result.map(fn(original) { #(original, None) })
              |> result.replace_error(Nil)
          })
          Ok(LaunchRequest(operation, original, token, reply))
        }
      }
    protocol.Workspace(operation) -> {
      use _ <- result.try(checked_invocation(binding, bytes))
      Ok(WorkspaceRequest(operation, bytes, reply))
    }
  }
}

fn checked_invocation(
  binding: protocol.Binding,
  bytes: BitArray,
) -> Result(tw.Invocation, Nil) {
  use invocation <- result.try(
    codec.decode_invocation(bytes) |> result.replace_error(Nil),
  )
  use expected <- result.try(semantic_scope(binding.scope))
  use <- bool.guard(
    tw.invocation_identity(invocation).0 != expected,
    Error(Nil),
  )
  Ok(invocation)
}

fn receive_input(
  route: protocol.Route,
  reservation: Reservation,
  incoming: process.Subject(Frame),
) -> Result(BitArray, Nil) {
  use header <- result.try(input_frame(incoming, reservation.correlation, 0))
  use receiver <- result.try(protocol.receiver(
    route,
    transfer.Invocation,
    header,
  ))
  use _ <- result.try(sent(
    reservation.reply,
    Consumed(reservation.correlation, 0),
  ))
  receive_chunks(receiver, reservation, incoming, 1)
}

fn input_frame(
  incoming: process.Subject(Frame),
  correlation: reference.Reference,
  ordinal: Int,
) -> Result(BitArray, Nil) {
  case process.receive_forever(incoming) {
    Input(ref, index, bytes) if ref == correlation && index == ordinal ->
      Ok(bytes)
    Input(_, _, _)
    | ReplyConsumed(_, _)
    | StatusConsumed(_)
    | BindInput(_, _, _) -> Error(Nil)
  }
}

fn receive_chunks(
  receiver: transfer.Receiver,
  reservation: Reservation,
  incoming: process.Subject(Frame),
  ordinal: Int,
) -> Result(BitArray, Nil) {
  use bytes <- result.try(input_frame(
    incoming,
    reservation.correlation,
    ordinal,
  ))
  use accepted <- result.try(
    transfer.accept(receiver, bytes) |> result.replace_error(Nil),
  )
  use _ <- result.try(sent(
    reservation.reply,
    Consumed(reservation.correlation, ordinal),
  ))
  case accepted {
    transfer.Complete(bytes) -> Ok(bytes)
    transfer.Receiving(receiver) ->
      receive_chunks(receiver, reservation, incoming, ordinal + 1)
  }
}

fn return_output(
  route: protocol.Route,
  reservation: Reservation,
  incoming: process.Subject(Frame),
  bytes: BitArray,
) -> Result(Nil, Nil) {
  case route, bytes {
    protocol.LaunchBind, _ -> Error(Nil)
    protocol.Workspace(_), <<1, 2, completion:bytes>> -> {
      use _ <- result.try(workspace_status(reservation, incoming, <<1, 2>>))
      return_content(route, reservation, incoming, completion)
    }
    protocol.Workspace(_), _ -> {
      use _ <- result.try(protocol.decode_status(bytes))
      workspace_status(reservation, incoming, bytes)
    }
    protocol.Native(_), _
    | protocol.NativeCommand(_), _
    | protocol.Compile(_), _
    | protocol.Launch(_), _
    -> return_content(route, reservation, incoming, bytes)
  }
}

// Metadata carries no completion content and consumes its own single ACK.
fn workspace_status(
  reservation: Reservation,
  incoming: process.Subject(Frame),
  bytes: BitArray,
) -> Result(Nil, Nil) {
  use <- bool.guard(bit_array.byte_size(bytes) > 34, Error(Nil))
  use _ <- result.try(sent(
    reservation.reply,
    WorkspaceStatus(reservation.correlation, bytes),
  ))
  case process.receive_forever(incoming) {
    StatusConsumed(ref) if ref == reservation.correlation -> Ok(Nil)
    Input(_, _, _)
    | ReplyConsumed(_, _)
    | StatusConsumed(_)
    | BindInput(_, _, _) -> Error(Nil)
  }
}

fn return_content(
  route: protocol.Route,
  reservation: Reservation,
  incoming: process.Subject(Frame),
  bytes: BitArray,
) -> Result(Nil, Nil) {
  use #(header, sender) <- result.try(
    transfer.begin_send(transfer.Completion, bytes) |> result.replace_error(Nil),
  )
  use _ <- result.try(protocol.receiver(route, transfer.Completion, header))
  use _ <- result.try(sent(
    reservation.reply,
    Returned(reservation.correlation, 0, header),
  ))
  use _ <- result.try(consumed(incoming, reservation.correlation, 0))
  output_chunks(sender, reservation, incoming, 1)
}

fn consumed(
  incoming: process.Subject(Frame),
  correlation: reference.Reference,
  ordinal: Int,
) -> Result(Nil, Nil) {
  case process.receive_forever(incoming) {
    ReplyConsumed(ref, index) if ref == correlation && index == ordinal ->
      Ok(Nil)
    Input(_, _, _)
    | ReplyConsumed(_, _)
    | StatusConsumed(_)
    | BindInput(_, _, _) -> Error(Nil)
  }
}

fn output_chunks(
  sender: transfer.Sender,
  reservation: Reservation,
  incoming: process.Subject(Frame),
  ordinal: Int,
) -> Result(Nil, Nil) {
  case transfer.next(sender) {
    None -> Ok(Nil)
    Some(#(frame, sender)) -> {
      use _ <- result.try(sent(
        reservation.reply,
        Returned(reservation.correlation, ordinal, frame),
      ))
      use _ <- result.try(consumed(incoming, reservation.correlation, ordinal))
      output_chunks(sender, reservation, incoming, ordinal + 1)
    }
  }
}

fn owner_exchange(
  config: Config,
  binding: protocol.Binding,
  route: protocol.Route,
  bytes: BitArray,
) -> Result(BitArray, Nil) {
  use _ <- result.try(
    distribution.connect(config.peer, config.within_ms)
    |> result.replace_error(Nil),
  )
  use endpoint <- result.try(
    distribution.endpoint(config.peer, config.within_ms)
    |> result.replace_error(Nil),
  )
  use header <- result.try(protocol.header(binding, route))
  let reply = process.new_subject()
  let correlation = reference.new()
  use _ <- result.try(sent(
    rendezvous(endpoint),
    Reservation(header, correlation, process.self(), reply),
  ))
  case process.receive_forever(reply) {
    Granted(ref, incoming) if ref == correlation -> {
      use <- bool.guard(
        case process.subject_owner(incoming) {
          Ok(pid) -> !distribution.owns(config.peer, pid)
          Error(Nil) -> True
        },
        Error(Nil),
      )
      use _ <- result.try(send_input(bytes, correlation, incoming, reply))
      receive_status_or_output(route, correlation, incoming, reply)
    }
    Granted(_, _)
    | Consumed(_, _)
    | Returned(_, _, _)
    | WorkspaceStatus(_, _)
    | BindReturned(_, _, _) -> Error(Nil)
  }
}

fn owner_bind(
  config: Config,
  binding: protocol.Binding,
  offered: launch_beam.Offer,
) -> Result(launch_beam.Acceptance, Nil) {
  use _ <- result.try(
    distribution.connect(config.peer, config.within_ms)
    |> result.replace_error(Nil),
  )
  use endpoint <- result.try(
    distribution.endpoint(config.peer, config.within_ms)
    |> result.replace_error(Nil),
  )
  use header <- result.try(protocol.header(binding, protocol.LaunchBind))
  let reply = process.new_subject()
  let correlation = reference.new()
  use _ <- result.try(sent(
    rendezvous(endpoint),
    Reservation(header, correlation, process.self(), reply),
  ))
  case process.receive_forever(reply) {
    Granted(ref, incoming) if ref == correlation -> {
      use <- bool.guard(
        case process.subject_owner(incoming) {
          Ok(pid) -> !distribution.owns(config.peer, pid)
          Error(Nil) -> True
        },
        Error(Nil),
      )
      let #(bytes, door) = launch_beam.offer_fields(offered)
      use _ <- result.try(sent(incoming, BindInput(correlation, bytes, door)))
      receive_acceptance(config.peer, bytes, correlation, incoming, reply)
    }
    Granted(_, _)
    | Consumed(_, _)
    | Returned(_, _, _)
    | WorkspaceStatus(_, _)
    | BindReturned(_, _, _) -> Error(Nil)
  }
}

fn receive_acceptance(
  peer: distribution.Peer,
  original_binding: BitArray,
  correlation: reference.Reference,
  incoming: process.Subject(Frame),
  reply: process.Subject(Reply),
) -> Result(launch_beam.Acceptance, Nil) {
  case process.receive_forever(reply) {
    BindReturned(ref, bytes, door) if ref == correlation -> {
      use <- bool.guard(bytes != original_binding, Error(Nil))
      use accepted <- result.try(
        launch_beam.acceptance_from_wire(peer, bytes, door)
        |> result.replace_error(Nil),
      )
      use _ <- result.try(sent(incoming, ReplyConsumed(correlation, 0)))
      Ok(accepted)
    }
    Granted(_, _)
    | Consumed(_, _)
    | Returned(_, _, _)
    | WorkspaceStatus(_, _)
    | BindReturned(_, _, _) -> Error(Nil)
  }
}

fn send_input(
  bytes: BitArray,
  correlation: reference.Reference,
  incoming: process.Subject(Frame),
  reply: process.Subject(Reply),
) -> Result(Nil, Nil) {
  use #(header, sender) <- result.try(
    transfer.begin_send(transfer.Invocation, bytes) |> result.replace_error(Nil),
  )
  use _ <- result.try(sent(incoming, Input(correlation, 0, header)))
  use _ <- result.try(input_consumed(reply, correlation, 0))
  input_chunks(sender, correlation, incoming, reply, 1)
}

fn input_consumed(
  reply: process.Subject(Reply),
  correlation: reference.Reference,
  ordinal: Int,
) -> Result(Nil, Nil) {
  case process.receive_forever(reply) {
    Consumed(ref, index) if ref == correlation && index == ordinal -> Ok(Nil)
    Granted(_, _)
    | Consumed(_, _)
    | Returned(_, _, _)
    | WorkspaceStatus(_, _)
    | BindReturned(_, _, _) -> Error(Nil)
  }
}

fn input_chunks(
  sender: transfer.Sender,
  correlation: reference.Reference,
  incoming: process.Subject(Frame),
  reply: process.Subject(Reply),
  ordinal: Int,
) -> Result(Nil, Nil) {
  case transfer.next(sender) {
    None -> Ok(Nil)
    Some(#(frame, sender)) -> {
      use _ <- result.try(sent(incoming, Input(correlation, ordinal, frame)))
      use _ <- result.try(input_consumed(reply, correlation, ordinal))
      input_chunks(sender, correlation, incoming, reply, ordinal + 1)
    }
  }
}

// A maximal canonical workspace completion keeps the full existing byte ceiling.
fn receive_status_or_output(
  route: protocol.Route,
  correlation: reference.Reference,
  incoming: process.Subject(Frame),
  reply: process.Subject(Reply),
) -> Result(BitArray, Nil) {
  case route {
    protocol.Workspace(_) ->
      case process.receive_forever(reply) {
        WorkspaceStatus(ref, bytes) if ref == correlation -> {
          use <- bool.guard(bit_array.byte_size(bytes) > 34, Error(Nil))
          use _ <- result.try(protocol.decode_status(bytes))
          use _ <- result.try(sent(incoming, StatusConsumed(correlation)))
          case bytes {
            <<1, 2>> -> {
              use completion <- result.try(receive_output(
                route,
                correlation,
                incoming,
                reply,
              ))
              Ok(<<1, 2, completion:bits>>)
            }
            _ -> Ok(bytes)
          }
        }
        Granted(_, _)
        | Consumed(_, _)
        | Returned(_, _, _)
        | WorkspaceStatus(_, _)
        | BindReturned(_, _, _) -> Error(Nil)
      }
    protocol.Native(_)
    | protocol.NativeCommand(_)
    | protocol.Compile(_)
    | protocol.Launch(_) -> receive_output(route, correlation, incoming, reply)
    protocol.LaunchBind -> Error(Nil)
  }
}

fn receive_output(
  route: protocol.Route,
  correlation: reference.Reference,
  incoming: process.Subject(Frame),
  reply: process.Subject(Reply),
) -> Result(BitArray, Nil) {
  case process.receive_forever(reply) {
    Returned(ref, 0, header) if ref == correlation -> {
      use receiver <- result.try(protocol.receiver(
        route,
        transfer.Completion,
        header,
      ))
      use _ <- result.try(sent(incoming, ReplyConsumed(correlation, 0)))
      returned_chunks(receiver, correlation, incoming, reply, 1)
    }
    Granted(_, _)
    | Consumed(_, _)
    | Returned(_, _, _)
    | WorkspaceStatus(_, _)
    | BindReturned(_, _, _) -> Error(Nil)
  }
}

fn returned_chunks(
  receiver: transfer.Receiver,
  correlation: reference.Reference,
  incoming: process.Subject(Frame),
  reply: process.Subject(Reply),
  ordinal: Int,
) -> Result(BitArray, Nil) {
  case process.receive_forever(reply) {
    Returned(ref, index, frame) if ref == correlation && index == ordinal -> {
      use accepted <- result.try(
        transfer.accept(receiver, frame) |> result.replace_error(Nil),
      )
      use _ <- result.try(sent(incoming, ReplyConsumed(correlation, ordinal)))
      case accepted {
        transfer.Complete(bytes) -> Ok(bytes)
        transfer.Receiving(receiver) ->
          returned_chunks(receiver, correlation, incoming, reply, ordinal + 1)
      }
    }
    Granted(_, _)
    | Consumed(_, _)
    | Returned(_, _, _)
    | WorkspaceStatus(_, _)
    | BindReturned(_, _, _) -> Error(Nil)
  }
}

fn sent(subject: process.Subject(a), message: a) -> Result(Nil, Nil) {
  case distribution.send(subject, message) {
    distribution.Sent -> Ok(Nil)
    distribution.WouldBlock
    | distribution.Disconnected
    | distribution.InvalidSubject -> Error(Nil)
  }
}

fn bounded(within_ms: Int, work: fn() -> Result(a, Nil)) -> Result(a, Error) {
  case
    weft.new_prepared([weft.managed(fn(_) { work() })])
    |> weft.deadline(within_ms)
    |> weft.start
  {
    [weft.Completed(_, value)] -> Ok(value)
    [weft.Failed(_, _)] -> Error(Uncertain)
    _ -> Error(Uncertain)
  }
}

// The container preserves both canonical segments and bounds them before slicing.
fn encode_segments(
  segments: #(BitArray, Option(BitArray)),
) -> Result(BitArray, Nil) {
  let #(metadata, content) = segments
  use <- bool.guard(
    bit_array.byte_size(metadata) < 1 || bit_array.byte_size(metadata) > 262_144,
    Error(Nil),
  )
  case content {
    None -> Ok(<<1, bit_array.byte_size(metadata):32, metadata:bits, 0>>)
    Some(bytes) -> {
      use <- bool.guard(
        bit_array.byte_size(bytes) < 1 || bit_array.byte_size(bytes) > 262_144,
        Error(Nil),
      )
      Ok(<<1, bit_array.byte_size(metadata):32, metadata:bits, 1, bytes:bits>>)
    }
  }
}

fn decode_segments(
  bytes: BitArray,
) -> Result(#(BitArray, Option(BitArray)), Nil) {
  use size <- result.try(case bytes {
    <<1, size:32, _:bytes>> if size > 0 && size <= 262_144 -> Ok(size)
    _ -> Error(Nil)
  })
  case bytes {
    <<1, _:32, metadata:bytes-size(size), 0>> -> Ok(#(metadata, None))
    <<1, _:32, metadata:bytes-size(size), 1, content:bytes>> -> {
      use <- bool.guard(
        bit_array.byte_size(content) < 1
          || bit_array.byte_size(content) > 262_144,
        Error(Nil),
      )
      Ok(#(metadata, Some(content)))
    }
    _ -> Error(Nil)
  }
}

// Preserve the existing definite native refusal codes across the new transport.
fn native_answer(answer: Result(wire.Body, service.Error)) -> wire.Body {
  case answer {
    Ok(body) -> body
    Error(service.Invalid) -> wire.Rejected(1)
    Error(service.Capacity) -> wire.Rejected(2)
    Error(service.Expired) -> wire.Rejected(3)
    Error(service.Uncertain) -> wire.Rejected(4)
  }
}

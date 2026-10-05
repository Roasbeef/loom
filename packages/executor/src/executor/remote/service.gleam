//// Executor-side execution admission, never owner approval or a budget ledger.
////
//// Configuration binds exactly one peer label, executor label, Scope, generation,
//// journal and scoped broker/executor. The command-preparation adapter's verify
//// callback checks exact materialized paths/env/policy against administrative
//// registration; argv/cwd never choose a workspace. Every Submit verifies scope,
//// step, full digest and registration before reserving exact request/authorization
//// payloads, committing admission, then committing launch intent. Only that live
//// decision may start native work. Existing payloads on restart are reconciled,
//// never launched. A failure after any possible durable submission is uncertain.
////
//// Challenge W=1000 ms, margin=100 ms, at most 32 unused nonces. Nonce binds peer,
//// generation, complete Native/Command route, scope/key/digest and issue time.
//// B=R-W-margin is positive and at least 1000 ms. First admission freezes receive+B; queue/preparation
//// consume it. The exact cleared helper wall_s must conservatively fit remaining
//// whole seconds, or launch is refused. No policy rewriting occurs after digest.
//// Session authority is explicit, with nonzero original resource/output ceilings.
//// Restart never interprets an old monotonic origin as renewed authorization.
////
//// Output retains exact encoded chunks through bounded journal asks, before
//// Query advertises them. A failed/overquota stream cancels locally and records a
//// terminal protocol failure. Log truncation remains a native result flag; root
//// must configure protocol streams to fail on any truncated bytes (#703).
//// Stdin is ordered/idempotent, 8 KiB/item, 128 items/1 MiB lifetime, checked
//// before forwarding to helper's 16 MiB FIFO. No pending unbounded stdin queue.
//// Receipts name exact terminal payload digest and follow owner durable commit.
//// Exit alone stays NativeUnconfirmed; close permanently fences the epoch and
//// only a witnessed scoped pool drain confirms native retirement.
////
//// The command door retains either the original Claim with its original Compile
//// elapsed deadline or historical Input data. Native authorization clamps to that
//// deadline before Authority is retained, so a later owner Unix-clock rollback
//// cannot enlarge it. Association and helper startup consume the same cap.
//// Full wrapper/context and concrete endpoint equality precede native writes.
//// After Request, Authority and Admit, the separate resource actor commits live
//// association before any AuthorizeLaunch. Cancellation which wins that writer
//// transaction prevents a permit; cancellation afterward may race OS startup.
//// Command controls and duplicate Submit readback require the exact retained
//// ref/key/digest. Recovery never recreates a Claim, ticket or native launch.
////
//// ## Flow
////
//// `exchange` -> `handle` -> `handle_exchange` -> `apply_envelope` -> `submit` -> `first_submit`
//// -> `launch`; `query` reads retained custody without launching.
////
//// `live_command_context` checks Claim identity; `command_context` reads history.
//// `send_command_exchange` enters `handle_command_exchange`, then the same engine.
//// `command_body` fences historical work and `command_association` checks controls.
//// `associate_command` orders its permit; `ticket_route` binds both nonce lanes.
//// `validate_command` checks the complete local endpoint and original identity.
//// `command_deadline` clamps live command authority to original elapsed custody.
//// `handle_open_exchange` applies ordinary work only after `validate_envelope`.
//// `close_scope` retains one original native disposition even on durable failure;
//// repeated close only retries the exact original durable confirmations.
////
//// 1. `exchange` admits one bounded service ask outside the network writer.
//// 2. `validate_envelope` fences peer, role, scope and generation before mutation.
//// 3. `submit` compares exact materialization and returns original evidence.
//// 4. `first_submit` persists request, authority and admission before intent.
//// 5. `launch` consumes only a live committed authorization into native custody.
//// 6. `publish_output` and `publish_terminal` ask the separate durable sink.
//// 7. `close_scope` confirms retirement only from scoped witnessed native drain.

import broker/dispatch
import broker/exec
import broker/executor as local
import broker/internal/call
import broker/policy
import core/command
import core/ids
import core/msgpack as mp
import core/workspace
import executor/remote/admission
import executor/remote/identity
import executor/remote/journal
import executor/remote/native
import executor/remote/payload
import executor/remote/resource_journal
import executor/remote/wire
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp_actor
import gleam/otp/supervision
import gleam/result
import weft/actor

/// Trusted administrative assembly; remote requests cannot replace these facts.
pub type Config {
  /// Verify must reject unmapped resources and policies exceeding registration.
  Config(
    /// The provisioned owner label bound to the pinned peer certificate.
    owner: String,
    /// The provisioned executor label from the administrative scope.
    executor: String,
    /// The exact session/workspace binding and original authority epochs.
    scope: identity.Scope,
    /// The current monotone transport generation, separate from request identity.
    generation: Int,
    /// The already opened durable admission and exact payload custodian.
    journal: journal.Journal,
    /// The scoped native service whose witnessed pool drain proves retirement.
    native: local.Executor,
    /// Administrative validation of exact scope, registration and policy ceilings.
    verify: fn(identity.RequestKey, wire.Prepared) -> Result(Nil, Nil),
    /// The injected local monotonic elapsed clock, shared with native watchdog.
    now: fn() -> Int,
  )
}

/// A bounded actor owning serialized admission and live request controls.
pub opaque type Service {
  /// The listener owns each asynchronous ask until its actual reply or death.
  Service(config: Config, subject: process.Subject(Message), pid: process.Pid)
}

/// Fixed errors leave possibly committed original evidence retained.
pub type Error {
  /// Authentication/schema/generation or clearance binding failed before mutation.
  Invalid

  /// Lifetime evidence/challenge/output capacity is exhausted.
  Capacity

  /// Finite authorization expired, was reused or cannot fit native seconds.
  Expired

  /// A durable transaction/reply failed; recover the original key.
  Uncertain
}

/// Exact local command custody, with historical data separated from live permission.
/// Construction pins the complete original Input and the concrete native endpoint.
/// A recovered row never reconstructs its original preparation Claim.
@internal
pub opaque type CommandContext {
  /// Only checked local constructors retain this association.
  CommandContext(
    /// Separate resource actor whose writer transaction fences cancellation.
    resources: resource_journal.Journal,
    /// Original bounded key/body; no decoded source tree is retained here.
    original: resource_journal.Input,
    /// Complete service and closed Compile command identity.
    ref: command.CommandRef,
    /// Historical readback cannot become first-Submit permission.
    permission: CommandPermission,
  )
}

type CommandPermission {
  /// Retained data grants observation only, never a challenge or Submit.
  Historical

  /// Original live preparation custody is consumed through resource association.
  Live(
    /// Original preparation custody; historical data cannot recreate it.
    claim: resource_journal.Claim,
    /// Original executor-local Compile deadline in Config.now's monotonic era.
    compile_deadline_ms: Int,
  )
}

// Routing stays local and closed; the ticket retains identity without the Claim.
type Route {
  /// Ordinary native service behavior retains its original admission semantics.
  Native

  /// Full original command identity accompanies every admission and control.
  Command(context: CommandContext)
}

type TicketRoute {
  /// A native ticket cannot authorize a command Submit.
  NativeTicket

  /// Command nonce reuse compares the complete original reference.
  CommandTicket(ref: command.CommandRef)
}

type Ticket {
  Ticket(
    /// Complete closed route, without retaining source input or a Claim.
    route: TicketRoute,
    key: identity.RequestKey,
    digest: identity.Digest,
    generation: Int,
    issued: Int,
    nonce: BitArray,
  )
}

// An ambiguous local control reply is retained as a permanent input fence.
// Replaying that ordinal never forwards bytes again or asserts delivery.
type InputDelivery {
  Delivered(bytes: BitArray, eof: dispatch.Eof)
  DeliveryUncertain(bytes: BitArray, eof: dispatch.Eof)
}

type Row {
  Row(
    digest: identity.Digest,
    deadline: Int,
    native: native.Running,
    stdin: List(InputDelivery),
    stdin_bytes: Int,
  )
}

type AdmissionGate {
  Accepting
  Quiesced
}

// One live service owns one native-close attempt. Durable retries cannot
// reconstruct its proof from actor death or invoke the stopped native actor.
type NativeClose {
  /// No native close has been attempted by this original service.
  NativeOpen

  /// The original native close returned its actual retirement proof.
  NativeRetired

  /// A failed or lost native close remains uncertain for this service lifetime.
  NativeUncertain
}

type State {
  State(
    config: Config,
    generation: Int,
    tickets: List(Ticket),
    rows: Dict(identity.RequestKey, Row),
    covered: Dict(identity.RequestKey, identity.Digest),
    subject: process.Subject(Message),
    sequence: Int,
    gate: AdmissionGate,
    native_close: NativeClose,
  )
}

type Message {
  Quiesce(reply: process.Subject(Nil))
  Shutdown(reply: process.Subject(Result(Nil, Error)))
  ControlDone(key: identity.RequestKey, digest: identity.Digest)
  Exchange(
    envelope: wire.Envelope,
    reply: process.Subject(Result(wire.Body, Error)),
  )
  CommandExchange(
    context: CommandContext,
    envelope: wire.CommandEnvelope,
    reply: process.Subject(Result(wire.Body, Error)),
  )
}

type Sink {
  Sink(subject: process.Subject(SinkMessage))
}

type SinkState {
  SinkState(
    journal: journal.Journal,
    key: identity.RequestKey,
    digest: identity.Digest,
    ordinal: Int,
    bytes: Int,
    terminal: Option(BitArray),
    stream: wire.StreamPolicy,
  )
}

type SinkMessage {
  Chunk(chunk: dispatch.Chunk, reply: process.Subject(Result(Nil, Nil)))
  End(terminal: dispatch.Terminal, reply: process.Subject(Nil))
}

/// Starts admission over an already opened durable journal and scoped native pool.
/// This performs no launch or TLS operation and does not create an owner Broker.
///
/// ## Examples
///
/// ```gleam
/// service.start(config)
/// ```
pub fn start(config: Config) -> Result(Service, Error) {
  use Nil <- result.try(validate(config))
  builder(config)
  |> actor.unlinked
  |> actor.start
  |> result.map(fn(started) { Service(config, started.data, started.pid) })
  |> result.map_error(fn(_) { Uncertain })
}

/// Validates fixed identity before a host creates listening resources.
///
/// ## Examples
///
/// ```gleam
/// // service.validate(config) == Ok(Nil)
/// ```
pub fn validate(config: Config) -> Result(Nil, Error) {
  use _ <- result.try(
    identity.executor_id(config.owner) |> result.map_error(fn(_) { Invalid }),
  )
  case
    identity.scope_fields(config.scope).2 == config.executor
    && config.generation > 0
    && config.generation <= 2_147_483_647
    && journal.scope(config.journal) == config.scope
  {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

/// Describes linked admission custody without automatic same-scope resurrection.
/// The caller owns the returned PID and must explicitly shut down the service.
/// Parent exit stops this actor; native retirement remains a separate witness.
///
/// ## Examples
///
/// ```gleam
/// // service.supervised(config).start() -> Ok(started)
/// ```
pub fn supervised(config: Config) -> supervision.ChildSpecification(Service) {
  supervision.worker(fn() {
    use Nil <- result.try(
      validate(config)
      |> result.replace_error(otp_actor.InitFailed(
        "invalid remote service binding",
      )),
    )
    builder(config)
    |> actor.start
    |> result.map(fn(started) {
      otp_actor.Started(started.pid, Service(config, started.data, started.pid))
    })
  })
  |> supervision.restart(supervision.Temporary)
}

/// Returns the actor owned by the trusted local lifetime assembly.
///
/// ## Examples
///
/// ```gleam
/// // process.monitor(service.pid(remote))
/// ```
pub fn pid(service: Service) -> process.Pid {
  service.pid
}

/// Serializes denial of new challenges and submissions before host drain.
/// Queries, receipts and cancellation retain their existing custody meaning.
///
/// ## Examples
///
/// ```gleam
/// // service.quiesce(remote) == Ok(Nil)
/// ```
pub fn quiesce(service: Service) -> Result(Nil, Error) {
  call.try_call(service.subject, waiting: 2000, sending: Quiesce)
  |> result.replace(Nil)
  |> result.replace_error(Uncertain)
}

/// Closes the durable epoch and drains native custody before actor termination.
/// Failure leaves a quiesced actor and its original evidence retained. A dead
/// actor returns uncertainty; process death never establishes native retirement.
///
/// ## Examples
///
/// ```gleam
/// // service.shutdown(remote) == Ok(Nil), after witnessed scoped drain.
/// ```
pub fn shutdown(service: Service) -> Result(Nil, Error) {
  call.try_call(service.subject, waiting: 30_000, sending: Shutdown)
  |> result.unwrap(Error(Uncertain))
}

fn builder(
  config: Config,
) -> actor.Builder(State, Message, process.Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    Ok(
      actor.initialised(State(
        config,
        config.generation,
        [],
        dict.new(),
        dict.new(),
        subject,
        0,
        Accepting,
        NativeOpen,
      ))
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle)
  |> actor.trapping_exits(True)
}

/// Executes one already decoded authenticated envelope via bounded admission ask.
/// A timeout is uncertainty, because the request may already have committed.
///
/// ## Examples
///
/// ```gleam
/// service.exchange(service, envelope)
/// ```
pub fn exchange(
  service: Service,
  envelope: wire.Envelope,
) -> Result(wire.Body, Error) {
  let reply = process.new_subject()
  process.send(service.subject, Exchange(envelope, reply))
  process.receive(reply, 30_000) |> result.unwrap(Error(Uncertain))
}

/// Transfers one concrete exchange to service custody without a caller timeout.
/// The finite listener credit owns reply until consumption or service death.
/// No network worker is allowed to use this door without that custody.
///
/// ## Examples
///
/// `send_exchange(service, envelope, reply)` sends exactly one typed ask.
@internal
pub fn send_exchange(
  service: Service,
  envelope: wire.Envelope,
  reply: process.Subject(Result(wire.Body, Error)),
) -> Nil {
  process.send(service.subject, Exchange(envelope, reply))
}

/// Retains first-Submit custody from the original live preparation Claim.
/// Full original identity and concrete native endpoint are checked before any ask.
/// The physical service still owns source admission and at-most-once Claim use.
/// It copies the deadline captured by original live admission in Config.now's era;
/// neither the Claim, service input nor incoming remaining budget can derive it.
/// Zero is reserved for session authority and refuses. Negative monotonic-era
/// deadlines are valid; authorization and launch compare their elapsed remaining.
///
/// ## Examples
///
/// ```gleam
/// service.live_command_context(remote, claim, ref, original_compile_deadline_ms)
/// // -> Ok(context).
/// ```
@internal
pub fn live_command_context(
  service: Service,
  claim: resource_journal.Claim,
  ref: command.CommandRef,
  compile_deadline_ms: Int,
) -> Result(CommandContext, Error) {
  use Nil <- result.try(case compile_deadline_ms {
    0 -> Error(Invalid)
    _ -> Ok(Nil)
  })
  let original = resource_journal.original(claim)
  let resources = resource_journal.claim_journal(claim)
  use Nil <- result.try(validate_command(
    service.config,
    resources,
    original,
    ref,
  ))
  Ok(CommandContext(resources, original, ref, Live(claim, compile_deadline_ms)))
}

/// Reads exact bounded original data without reconstructing preparation custody.
/// Historical contexts can control an exact retained native association only.
/// They cannot create a challenge or submit, even when a native key is unseen.
/// Missing or conflicting original identity is a definite refusal; journal or
/// reply uncertainty remains uncertain and grants no new command authority.
///
/// ## Examples
///
/// ```gleam
/// service.command_context(remote, resources, ref) // -> Ok(history).
/// ```
@internal
pub fn command_context(
  service: Service,
  resources: resource_journal.Journal,
  ref: command.CommandRef,
) -> Result(CommandContext, Error) {
  use original <- result.try(
    resource_journal.retained_input(resources, command.service(ref))
    |> result.map_error(fn(error) {
      case error {
        resource_journal.Missing | resource_journal.Conflict -> Invalid
        resource_journal.InvalidLimits
        | resource_journal.InvalidPath
        | resource_journal.AlreadyExists
        | resource_journal.BindingMismatch
        | resource_journal.InvalidInput
        | resource_journal.Capacity
        | resource_journal.Corrupt
        | resource_journal.Uncertain
        | resource_journal.Sealed
        | resource_journal.Closed
        | resource_journal.UnsupportedRole
        | resource_journal.StartFailed -> Uncertain
      }
    }),
  )
  use Nil <- result.try(validate_command(
    service.config,
    resources,
    original,
    ref,
  ))
  Ok(CommandContext(resources, original, ref, Historical))
}

fn validate_command(
  config: Config,
  resources: resource_journal.Journal,
  original: resource_journal.Input,
  ref: command.CommandRef,
) -> Result(Nil, Error) {
  let #(session, name, executor, session_epoch, workspace_epoch) =
    identity.scope_fields(config.scope)
  use scope <- result.try(
    workspace.scope_from_fields(
      session,
      name,
      executor,
      session_epoch,
      workspace_epoch,
    )
    |> result.replace_error(Invalid),
  )
  case
    original.key == command.service(ref)
    && command.command_ref(original.key, command.CompileCommand) == Ok(ref)
    && command.coordinates(original.key).0 == scope
    && resource_journal.native_endpoint(resources) == config.journal
  {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

/// Transfers one typed command ask to the same serialized native admission engine.
/// The enclosing listener owns reply custody until actual consumption or death.
/// Native bodies are returned; transport later wraps the original complete ref.
///
/// ## Examples
///
/// ```gleam
/// service.send_command_exchange(remote, context, envelope, reply) // -> Nil.
/// ```
@internal
pub fn send_command_exchange(
  service: Service,
  context: CommandContext,
  envelope: wire.CommandEnvelope,
  reply: process.Subject(Result(wire.Body, Error)),
) -> Nil {
  process.send(service.subject, CommandExchange(context, envelope, reply))
}

/// Waits boundedly for one component command exchange without renewing authority.
/// Timeout does not withdraw the queued ask or prove absence of a committed effect.
///
/// ## Examples
///
/// ```gleam
/// service.exchange_command(remote, context, envelope) // -> Ok(native_body).
/// ```
@internal
pub fn exchange_command(
  service: Service,
  context: CommandContext,
  envelope: wire.CommandEnvelope,
) -> Result(wire.Body, Error) {
  let reply = process.new_subject()
  send_command_exchange(service, context, envelope, reply)
  process.receive(reply, 30_000) |> result.unwrap(Error(Uncertain))
}

/// Exposes only the immutable configured identity for transport validation.
///
/// ## Examples
///
/// ```gleam
/// service.configuration(service)
/// ```
pub fn configuration(service: Service) -> Config {
  service.config
}

/// Conservatively authorizes finite duration using only elapsed-clock remaining.
/// Offsets between hosts never enter this arithmetic.
///
/// ## Examples
///
/// ```gleam
/// service.attempt_budget(5000) // -> Ok(3900).
/// ```
pub fn attempt_budget(remaining_ms: Int) -> Result(Int, Error) {
  let budget = remaining_ms - 1000 - 100
  case budget >= 1000 && budget <= 86_400_000 {
    True -> Ok(budget)
    False -> Error(Expired)
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Quiesce(reply) -> {
      process.send(reply, Nil)
      actor.continue(State(..state, gate: Quiesced, tickets: []))
    }
    Shutdown(reply) -> {
      let #(next, outcome) = close_scope(state)
      case outcome {
        Ok(_) -> {
          process.send(reply, Ok(Nil))
          actor.stop()
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(next)
        }
      }
    }
    ControlDone(key, digest) -> {
      let rows = case dict.get(state.rows, key) {
        Ok(row) if row.digest == digest -> dict.delete(state.rows, key)
        _ -> state.rows
      }
      actor.continue(State(..state, rows:))
    }
    Exchange(envelope, reply) -> handle_exchange(state, Native, envelope, reply)
    CommandExchange(context, envelope, reply) ->
      handle_command_exchange(state, context, envelope, reply)
  }
}

fn handle_command_exchange(
  state: State,
  context: CommandContext,
  envelope: wire.CommandEnvelope,
  reply: process.Subject(Result(wire.Body, Error)),
) -> actor.Next(State, Message) {
  // An opaque context from another service cannot write into this native journal.
  let checked = {
    use Nil <- result.try(validate_command(
      state.config,
      context.resources,
      context.original,
      context.ref,
    ))
    case wire.command_ref(envelope) == context.ref {
      True -> Ok(Nil)
      False -> Error(Invalid)
    }
  }
  case checked {
    Ok(Nil) ->
      handle_exchange(
        state,
        Command(context),
        wire.native_envelope(envelope),
        reply,
      )
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
  }
}

fn handle_exchange(
  state: State,
  route: Route,
  envelope: wire.Envelope,
  reply: process.Subject(Result(wire.Body, Error)),
) -> actor.Next(State, Message) {
  // Closure returns retained state even on failure. Ordinary exchanges keep
  // their existing all-or-error mutation contract and validation ordering.
  case validate_envelope(state, route, envelope), envelope.body {
    Ok(Nil), wire.CloseScope if envelope.generation == state.generation -> {
      let #(next, outcome) = close_scope(state)
      process.send(reply, outcome)
      actor.continue(next)
    }
    Error(error), _ -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
    Ok(Nil), _ -> handle_open_exchange(state, route, envelope, reply)
  }
}

fn handle_open_exchange(
  state: State,
  route: Route,
  envelope: wire.Envelope,
  reply: process.Subject(Result(wire.Body, Error)),
) -> actor.Next(State, Message) {
  case apply_envelope(state, route, envelope) {
    Ok(#(next, body)) -> {
      process.send(reply, Ok(body))
      actor.continue(next)
    }
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
  }
}

fn validate_envelope(
  state: State,
  route: Route,
  envelope: wire.Envelope,
) -> Result(Nil, Error) {
  let config = state.config
  use Nil <- result.try(
    case
      envelope.role == wire.Owner
      && envelope.owner == config.owner
      && envelope.executor == config.executor
      && envelope.scope == config.scope
      && envelope.generation >= state.generation
      && envelope.generation <= 2_147_483_647
    {
      True -> Ok(Nil)
      False -> Error(Invalid)
    },
  )
  command_body(route, envelope.body)
}

fn apply_envelope(
  state: State,
  route: Route,
  envelope: wire.Envelope,
) -> Result(#(State, wire.Body), Error) {
  let config = state.config
  case envelope.body {
    wire.ChallengeRequest(_, _)
      | wire.Submit(_, _, _, _, _)
      if state.gate == Quiesced
    -> Error(Invalid)
    wire.Hello ->
      Ok(#(
        State(
          ..state,
          generation: envelope.generation,
          tickets: case envelope.generation == state.generation {
            True -> state.tickets
            False -> []
          },
        ),
        wire.Hello,
      ))
    _ if envelope.generation != state.generation -> Error(Invalid)
    wire.ChallengeRequest(key, digest) -> challenge(state, route, key, digest)
    wire.Submit(key, digest, prepared, nonce, budget) ->
      submit(state, route, key, digest, prepared, nonce, budget)
    wire.Query(key, digest, cursor) -> {
      use body <- result.try(query(state, key, digest, cursor))
      Ok(#(state, body))
    }
    wire.Cancel(key, digest) -> cancel_key(state, key, digest)
    wire.Stdin(key, digest, ordinal, bytes, eof) ->
      feed(state, key, digest, ordinal, bytes, eof)
    wire.DurableReceipt(key, digest, terminal) -> {
      use _ <- result.try(
        journal.apply(
          config.journal,
          key,
          digest,
          admission.ConfirmOwnerReceipt(terminal),
        )
        |> durable,
      )
      use body <- result.try(query(state, key, digest, 64))
      Ok(#(state, body))
    }
    wire.CloseScope -> Error(Invalid)
    _ -> Error(Invalid)
  }
}

fn command_body(route: Route, body: wire.Body) -> Result(Nil, Error) {
  case route, body {
    Native, _ -> Ok(Nil)

    // Historical identity is useful for recovery but cannot produce fresh authority.
    Command(context), wire.ChallengeRequest(_, _)
    | Command(context), wire.Submit(_, _, _, _, _)
    -> {
      use Nil <- result.try(case context.permission {
        Live(_, _) -> Ok(Nil)
        Historical -> Error(Uncertain)
      })
      case body {
        wire.Submit(_, _, prepared, _, _) if prepared.lifetime == wire.Session ->
          Error(Invalid)
        _ -> Ok(Nil)
      }
    }
    Command(_), wire.Query(key, digest, _)
    | Command(_), wire.Cancel(key, digest)
    | Command(_), wire.Stdin(key, digest, _, _, _)
    | Command(_), wire.DurableReceipt(key, digest, _)
    -> command_association(route, key, digest)
    Command(_), _ -> Error(Invalid)
  }
}

fn command_association(
  route: Route,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(Nil, Error) {
  case route {
    Native -> Ok(Nil)
    Command(context) -> {
      use retained <- result.try(
        resource_journal.inspect_native(context.resources, context.original)
        |> result.replace_error(Uncertain),
      )
      case retained {
        resource_journal.Unassociated -> Error(Uncertain)
        resource_journal.Associated(ref, saved_key, saved_digest, _) ->
          case
            ref == context.ref && saved_key == key && saved_digest == digest
          {
            True -> Ok(Nil)
            False -> Error(Invalid)
          }
      }
    }
  }
}

fn live_row(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(Row, Error) {
  use row <- result.try(
    dict.get(state.rows, key) |> result.map_error(fn(_) { Uncertain }),
  )
  case row.digest == digest {
    True -> Ok(row)
    False -> Error(Invalid)
  }
}

fn challenge(
  state: State,
  route: Route,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(#(State, wire.Body), Error) {
  use Nil <- result.try(case identity.key_scope(key) == state.config.scope {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  let now = state.config.now()
  let tickets =
    list.filter(state.tickets, fn(ticket) { now - ticket.issued < 1000 })
  use Nil <- result.try(case list.drop(tickets, 31) == [] {
    True -> Ok(Nil)
    False -> Error(Capacity)
  })
  let nonce = crypto.strong_random_bytes(32)
  let ticket =
    Ticket(ticket_route(route), key, digest, state.generation, now, nonce)
  Ok(#(
    State(..state, tickets: [ticket, ..tickets]),
    wire.Challenge(key, digest, nonce, 1000),
  ))
}

fn submit(
  state: State,
  route: Route,
  key: identity.RequestKey,
  digest: identity.Digest,
  prepared: wire.Prepared,
  nonce: BitArray,
  budget: Int,
) -> Result(#(State, wire.Body), Error) {
  use Nil <- result.try(verify(state.config, key, digest, prepared))
  use previous <- result.try(
    journal.payloads(state.config.journal, key, digest) |> durable,
  )
  case previous {
    [] ->
      case journal.inspect(state.config.journal, key, digest) {
        Error(journal.Rejected(admission.UnknownRequest)) ->
          first_submit(state, route, key, digest, prepared, nonce, budget)
        Ok(_) -> {
          use Nil <- result.try(command_association(route, key, digest))
          use body <- result.try(query(state, key, digest, 0))
          Ok(#(state, body))
        }
        Error(_) -> Error(Uncertain)
      }
    _ -> {
      use Nil <- result.try(command_association(route, key, digest))
      existing_submission(state, key, digest, previous)
    }
  }
}

fn existing_submission(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  previous: List(payload.Item),
) -> Result(#(State, wire.Body), Error) {
  case
    list.any(previous, fn(item) {
      case item {
        payload.Cancellation(_) -> True
        _ -> False
      }
    })
  {
    True -> {
      use body <- result.try(query(state, key, digest, 0))
      Ok(#(state, body))
    }
    False -> {
      // A stored payload marks prior possible admission. Restart and lost-ack
      // reconciliation never recreates launch permission or a new deadline.
      use item <- result.try(
        list.find(previous, fn(item) {
          case item {
            payload.Request(_) -> True
            _ -> False
          }
        })
        |> result.map_error(fn(_) { Uncertain }),
      )
      use bytes <- result.try(case item {
        payload.Request(bytes) -> Ok(bytes)
        _ -> Error(Uncertain)
      })
      use original <- result.try(
        wire.decode_prepared(bytes) |> result.map_error(fn(_) { Uncertain }),
      )
      use original_digest <- result.try(
        wire.prepared_digest(original) |> result.map_error(fn(_) { Uncertain }),
      )
      use Nil <- result.try(case original_digest == digest {
        True -> Ok(Nil)
        False -> Error(Invalid)
      })
      use body <- result.try(query(state, key, digest, 0))
      Ok(#(state, body))
    }
  }
}

fn verify(
  config: Config,
  key: identity.RequestKey,
  digest: identity.Digest,
  prepared: wire.Prepared,
) -> Result(Nil, Error) {
  use computed <- result.try(
    wire.prepared_digest(prepared) |> result.map_error(fn(_) { Invalid }),
  )
  use Nil <- result.try(
    case identity.key_scope(key) == config.scope && computed == digest {
      True -> Ok(Nil)
      False -> Error(Invalid)
    },
  )
  use Nil <- result.try(
    config.verify(key, prepared) |> result.map_error(fn(_) { Invalid }),
  )
  case prepared.request.policy {
    None -> Error(Invalid)
    Some(policy) -> {
      use Nil <- result.try(
        policy.validate(policy) |> result.map_error(fn(_) { Invalid }),
      )
      let limits = policy.limits
      case
        limits.output_bytes > 0
        && limits.output_bytes <= 262_144
        && limits.cpu_s > 0
        && limits.mem_bytes > 0
        && limits.pids > 0
        && limits.fsize_bytes > 0
      {
        True -> Ok(Nil)
        False -> Error(Invalid)
      }
    }
  }
}

fn first_submit(
  state: State,
  route: Route,
  key: identity.RequestKey,
  digest: identity.Digest,
  prepared: wire.Prepared,
  nonce: BitArray,
  budget: Int,
) -> Result(#(State, wire.Body), Error) {
  use Nil <- result.try(case dict.size(state.rows) < 32 {
    True -> Ok(Nil)
    False -> Error(Capacity)
  })
  use deadline <- result.try(authorize(
    state,
    route,
    key,
    digest,
    prepared.lifetime,
    nonce,
    budget,
  ))
  use bytes <- result.try(
    wire.encode_prepared(prepared) |> result.map_error(fn(_) { Invalid }),
  )
  use authority <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(state.generation),
        mp.IntValue(deadline),
        mp.IntValue(budget),
      ]),
    )
    |> result.map_error(fn(_) { Invalid }),
  )
  use Nil <- result.try(
    journal.put_payload(
      state.config.journal,
      key,
      digest,
      payload.Request(bytes),
    )
    |> durable,
  )
  use Nil <- result.try(
    journal.put_payload(
      state.config.journal,
      key,
      digest,
      payload.Authority(authority),
    )
    |> durable,
  )
  use _ <- result.try(
    journal.admit(state.config.journal, key, digest) |> durable,
  )
  let tickets = list.filter(state.tickets, fn(ticket) { ticket.nonce != nonce })
  let next = State(..state, tickets:, sequence: state.sequence + 1)

  // Actual native admission precedes the separate resource COMMIT. A lost permit
  // reply leaves retained admission, never launch intent or replay eligibility.
  use Nil <- result.try(associate_command(route, key, digest))
  case launch(next, key, digest, prepared, deadline) {
    Ok(answer) -> Ok(answer)
    Error(Expired) | Error(Invalid) -> refuse_admitted(next, key, digest)
    Error(error) -> Error(error)
  }
}

fn associate_command(
  route: Route,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(Nil, Error) {
  case route {
    Native -> Ok(Nil)
    Command(context) -> {
      use claim <- result.try(case context.permission {
        Live(claim, _) -> Ok(claim)
        Historical -> Error(Uncertain)
      })
      use permit <- result.try(
        resource_journal.associate_live_native(claim, context.ref, key, digest)
        |> result.replace_error(Uncertain),
      )
      case
        resource_journal.native_launch_binding(permit)
        == #(context.resources, context.ref, key, digest)
      {
        True -> Ok(Nil)
        False -> Error(Invalid)
      }
    }
  }
}

fn ticket_route(route: Route) -> TicketRoute {
  case route {
    Native -> NativeTicket
    Command(context) -> CommandTicket(context.ref)
  }
}

fn authorize(
  state: State,
  route: Route,
  key: identity.RequestKey,
  digest: identity.Digest,
  lifetime: wire.Lifetime,
  nonce: BitArray,
  budget: Int,
) -> Result(Int, Error) {
  let binding = ticket_route(route)
  case lifetime {
    wire.Session -> {
      case budget == 0 && nonce == <<0:size(256)>> {
        True -> Ok(0)
        False -> Error(Invalid)
      }
    }
    wire.Finite(ceiling) -> {
      use ticket <- result.try(
        list.find(state.tickets, fn(ticket) {
          ticket.route == binding
          && ticket.key == key
          && ticket.digest == digest
          && ticket.generation == state.generation
          && ticket.nonce == nonce
        })
        |> result.map_error(fn(_) { Expired }),
      )
      let now = state.config.now()
      case
        now >= ticket.issued
        && now - ticket.issued < 1000
        && budget >= 1000
        && budget < ceiling
        && now + budget != 0
      {
        True -> {
          // Native duration alone can reflect a later owner wall-clock rollback.
          // Only live command admission carries the original elapsed Compile cap.
          command_deadline(route, now + budget, now)
        }
        False -> Error(Expired)
      }
    }
  }
}

fn command_deadline(
  route: Route,
  native_deadline_ms: Int,
  now_ms: Int,
) -> Result(Int, Error) {
  case route {
    Native -> Ok(native_deadline_ms)
    Command(context) -> {
      use cap <- result.try(case context.permission {
        Live(_, cap) -> Ok(cap)
        Historical -> Error(Uncertain)
      })
      let deadline = int.min(native_deadline_ms, cap)
      case deadline > now_ms {
        True -> Ok(deadline)
        False -> Error(Expired)
      }
    }
  }
}

fn launch(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  prepared: wire.Prepared,
  deadline: Int,
) -> Result(#(State, wire.Body), Error) {
  let config = state.config
  use Nil <- result.try(verify(config, key, digest, prepared))
  let remaining = deadline - config.now()
  use Nil <- result.try(case prepared.request.policy, prepared.lifetime {
    Some(policy), wire.Finite(_) ->
      case
        policy.limits.wall_s > 0
        && remaining >= 1000
        && policy.limits.wall_s * 1000 <= remaining
      {
        True -> Ok(Nil)
        False -> Error(Expired)
      }
    Some(policy), wire.Session ->
      case policy.limits.wall_s == 0 {
        True -> Ok(Nil)
        False -> Error(Invalid)
      }
    None, _ -> Error(Invalid)
  })
  use decision <- result.try(
    journal.apply(config.journal, key, digest, admission.AuthorizeLaunch)
    |> durable,
  )
  case decision.effect {
    admission.NoLaunch -> {
      use body <- result.try(query(state, key, digest, 0))
      Ok(#(state, body))
    }
    admission.Launch(_) -> {
      let #(operation, _) = identity.key_fields(key)
      use operation <- result.try(
        ids.parse_op_id(operation) |> result.map_error(fn(_) { Invalid }),
      )
      let service_subject = state.subject
      let journal = config.journal
      let stream = prepared.stream
      use running <- result.try(
        native.start(
          native.Config(
            config.native,
            operation,
            prepared,
            state.sequence,
            deadline,
            config.now,
            fn() {
              use sink <- result.map(
                output_sink(journal, key, digest, stream)
                |> result.replace_error(Nil),
              )
              native.Publisher(
                fn(chunk) { publish_output(sink, chunk) },
                fn(terminal) { publish_terminal(sink, terminal) },
              )
            },
            fn() { process.send(service_subject, ControlDone(key, digest)) },
          ),
        )
        |> result.map_error(fn(_) { Uncertain }),
      )
      let row = Row(digest, deadline, running, [], 0)
      Ok(#(
        State(
          ..state,
          rows: dict.insert(state.rows, key, row),
          covered: dict.insert(state.covered, key, digest),
        ),
        wire.Evidence(key, digest, 2, deadline),
      ))
    }
  }
}

fn query(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  cursor: Int,
) -> Result(wire.Body, Error) {
  use evidence <- result.try(
    journal.inspect(state.config.journal, key, digest) |> durable,
  )
  use items <- result.try(
    journal.payloads(state.config.journal, key, digest) |> durable,
  )
  case
    list.find(items, fn(item) {
      case item {
        payload.Output(ordinal, _) -> ordinal == cursor
        _ -> False
      }
    })
  {
    Ok(payload.Output(ordinal, bytes)) ->
      Ok(wire.Output(key, digest, ordinal, bytes))
    _ -> query_terminal(state, key, digest, evidence, items)
  }
}

fn query_terminal(
  _state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  evidence: admission.Evidence,
  items: List(payload.Item),
) -> Result(wire.Body, Error) {
  case
    list.find(items, fn(item) {
      case item {
        payload.Terminal(_) -> True
        _ -> False
      }
    })
  {
    Ok(payload.Terminal(bytes)) -> {
      // Payload commit can precede reducer terminal commit. Never advertise a
      // half-committed terminal as receipt-ready evidence.
      case admission.phase(evidence) {
        admission.Terminal(_, _, _)
        | admission.Refused(_, _)
        | admission.Retired(_)
        | admission.RetiredRefusal(_) -> Ok(wire.Terminal(key, digest, bytes))
        _ ->
          Ok(wire.Evidence(
            key,
            digest,
            phase_code(admission.phase(evidence)),
            frozen_deadline(items),
          ))
      }
    }
    _ ->
      Ok(wire.Evidence(
        key,
        digest,
        phase_code(admission.phase(evidence)),
        frozen_deadline(items),
      ))
  }
}

fn frozen_deadline(items: List(payload.Item)) -> Int {
  let found =
    list.find(items, fn(item) {
      case item {
        payload.Authority(_) -> True
        _ -> False
      }
    })
  case found {
    Ok(payload.Authority(bytes)) ->
      case wire.decode_value(bytes) {
        Ok(mp.ArrayValue([mp.IntValue(_), mp.IntValue(deadline), mp.IntValue(_)])) ->
          deadline
        _ -> 0
      }
    _ -> 0
  }
}

fn feed(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  ordinal: Int,
  bytes: BitArray,
  eof: dispatch.Eof,
) -> Result(#(State, wire.Body), Error) {
  use row <- result.try(live_row(state, key, digest))
  case list.first(list.drop(row.stdin, ordinal)) {
    Ok(Delivered(previous, previous_eof))
      if previous == bytes && previous_eof == eof
    -> Ok(#(state, wire.Evidence(key, digest, 2, row.deadline)))
    Ok(DeliveryUncertain(previous, previous_eof))
      if previous == bytes && previous_eof == eof
    -> Error(Uncertain)
    Ok(_) -> Error(Invalid)
    Error(_) -> {
      use Nil <- result.try(
        case
          ordinal >= 0
          && ordinal < 128
          && bit_array.byte_size(bytes) <= 8192
          && row.stdin_bytes + bit_array.byte_size(bytes) <= 1_048_576
        {
          True -> Ok(Nil)
          False -> Error(Capacity)
        },
      )

      use Nil <- result.try(
        case
          ordinal == list.length(row.stdin)
          && !list.any(row.stdin, fn(item) {
            case item {
              Delivered(_, eof) | DeliveryUncertain(_, eof) ->
                eof == dispatch.EndOfInput
            }
          })
        {
          True -> Ok(Nil)
          False -> Error(Invalid)
        },
      )

      // A local ask timeout can follow actual forwarding. Retain the ordinal
      // and its exact bytes even then; a retry must remain uncertain, not write
      // them twice. Rejected(4) returns the updated fence without a delivery ACK.
      let #(delivery, response) = case native.stdin(row.native, bytes, eof) {
        Ok(Nil) -> #(
          Delivered(bytes, eof),
          wire.Evidence(key, digest, 2, row.deadline),
        )
        Error(Nil) -> #(DeliveryUncertain(bytes, eof), wire.Rejected(4))
      }
      let row =
        Row(
          ..row,
          stdin: list.append(row.stdin, [delivery]),
          stdin_bytes: row.stdin_bytes + bit_array.byte_size(bytes),
        )
      Ok(#(State(..state, rows: dict.insert(state.rows, key, row)), response))
    }
  }
}

fn close_scope(state: State) -> #(State, Result(wire.Body, Error)) {
  // Quiescence and the original native disposition survive every outward error.
  // Covered identities cannot grow after this point; retries only confirm them.
  let state = State(..state, gate: Quiesced, tickets: [])
  let fenced = journal.close_epoch(state.config.journal)
  let disposition = case state.native_close {
    NativeOpen ->
      case local.close(state.config.native, draining: 2000, helpers: 5000) {
        Ok(Nil) -> NativeRetired
        Error(_) -> NativeUncertain
      }
    NativeRetired | NativeUncertain -> state.native_close
  }
  let state = State(..state, native_close: disposition)

  // Native success alone never advertises complete scope retirement. The exact
  // original journal and covered-key confirmations must also succeed.
  let outcome = {
    use Nil <- result.try(fenced |> durable)
    use Nil <- result.try(case disposition {
      NativeRetired -> Ok(Nil)
      NativeOpen | NativeUncertain -> Error(Uncertain)
    })
    use Nil <- result.try(
      list.try_each(dict.to_list(state.covered), fn(pair) {
        let #(key, digest) = pair
        journal.apply(
          state.config.journal,
          key,
          digest,
          admission.ConfirmRetirement,
        )
        |> durable
        |> result.replace(Nil)
      }),
    )
    Ok(wire.ScopeRetirement)
  }
  #(state, outcome)
}

fn phase_code(phase: admission.Phase) -> Int {
  case phase {
    admission.Admitted -> 1
    admission.LaunchIntent(_) -> 2
    admission.Refused(_, _) -> 3
    admission.Terminal(_, _, _) -> 4
    admission.Retired(_) -> 5
    admission.RetiredRefusal(_) -> 6
  }
}

fn durable(value: Result(a, journal.Error)) -> Result(a, Error) {
  result.map_error(value, fn(error) {
    case error {
      journal.Rejected(admission.Saturated) -> Capacity
      journal.Rejected(_) -> Invalid
      _ -> Uncertain
    }
  })
}

fn output_sink(
  journal: journal.Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
  stream: wire.StreamPolicy,
) -> Result(Sink, Error) {
  actor.new(SinkState(journal, key, digest, 0, 0, None, stream))
  |> actor.on_message(handle_sink)
  |> actor.trapping_exits(True)
  |> actor.start
  |> result.map(fn(started) { Sink(started.data) })
  |> result.map_error(fn(_) { Uncertain })
}

fn publish_output(sink: Sink, chunk: dispatch.Chunk) -> Result(Nil, Nil) {
  let reply = process.new_subject()
  process.send(sink.subject, Chunk(chunk, reply))
  process.receive(reply, 30_000) |> result.unwrap(Error(Nil))
}

fn publish_terminal(sink: Sink, terminal: dispatch.Terminal) -> Nil {
  let reply = process.new_subject()
  process.send(sink.subject, End(terminal, reply))
  let _ = process.receive(reply, 30_000)
  Nil
}

fn handle_sink(
  state: SinkState,
  message: SinkMessage,
) -> actor.Next(SinkState, SinkMessage) {
  case message {
    Chunk(chunk, reply) -> {
      let outcome = retain_chunks(state, chunk, chunk.data)
      process.send(
        reply,
        result.replace(outcome, Nil) |> result.map_error(fn(_) { Nil }),
      )
      case outcome {
        Ok(next) -> actor.continue(next)
        Error(_) -> {
          let terminal =
            dispatch.Failed(exec.ProtocolViolation(
              "remote output quota or custody failure",
            ))
          let next = retain_terminal(state, terminal) |> result.unwrap(state)
          actor.continue(next)
        }
      }
    }
    End(terminal, reply) -> {
      // The relay serializes this after its final output. Persistence failure
      // leaves durable uncertainty, not a reason to retain an idle actor.
      let _ = retain_terminal(state, terminal)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn retain_chunk(
  state: SinkState,
  chunk: dispatch.Chunk,
) -> Result(SinkState, Error) {
  use Nil <- result.try(case state.terminal {
    None -> Ok(Nil)
    Some(_) -> Error(Invalid)
  })
  use Nil <- result.try(
    case state.stream == wire.ProtocolStream && chunk.truncated {
      True -> Error(Capacity)
      False -> Ok(Nil)
    },
  )
  use bytes <- result.try(
    native.encode_output(chunk) |> result.map_error(fn(_) { Capacity }),
  )
  use Nil <- result.try(
    case
      state.ordinal < 64
      && state.bytes + bit_array.byte_size(bytes) <= 1_048_576
    {
      True -> Ok(Nil)
      False -> Error(Capacity)
    },
  )
  use Nil <- result.try(
    journal.put_payload(
      state.journal,
      state.key,
      state.digest,
      payload.Output(state.ordinal, bytes),
    )
    |> durable,
  )
  Ok(
    SinkState(
      ..state,
      ordinal: state.ordinal + 1,
      bytes: state.bytes + bit_array.byte_size(bytes),
    ),
  )
}

fn retain_terminal(
  state: SinkState,
  terminal: dispatch.Terminal,
) -> Result(SinkState, Error) {
  case state.terminal {
    Some(_) -> Ok(state)
    None -> {
      use bytes <- result.try(
        native.encode_terminal(terminal)
        |> result.map_error(fn(_) { Uncertain }),
      )
      use digest <- result.try(
        wire.digest(bytes) |> result.map_error(fn(_) { Uncertain }),
      )
      use Nil <- result.try(
        journal.put_payload(
          state.journal,
          state.key,
          state.digest,
          payload.Terminal(bytes),
        )
        |> durable,
      )
      use _ <- result.try(
        journal.apply(
          state.journal,
          state.key,
          state.digest,
          admission.ObserveTerminal(digest),
        )
        |> durable,
      )
      Ok(SinkState(..state, terminal: Some(bytes)))
    }
  }
}

fn retain_chunks(
  state: SinkState,
  chunk: dispatch.Chunk,
  remaining: BitArray,
) -> Result(SinkState, Error) {
  case remaining {
    <<first:bytes-size(8192), rest:bits>> if rest != <<>> -> {
      let total = chunk.total_bytes - bit_array.byte_size(rest)
      use next <- result.try(retain_chunk(
        state,
        dispatch.Chunk(
          ..chunk,
          data: first,
          total_bytes: total,
          truncated: False,
        ),
      ))
      retain_chunks(next, chunk, rest)
    }
    _ -> retain_chunk(state, dispatch.Chunk(..chunk, data: remaining))
  }
}

fn refuse_admitted(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(#(State, wire.Body), Error) {
  // Admission exists but no LaunchIntent was committed. Exact refusal bytes
  // establish absence of native custody, while durable owner receipt is owed.
  use bytes <- result.try(
    native.encode_terminal(
      dispatch.Failed(exec.ProtocolViolation(
        "remote authorization expired before native launch",
      )),
    )
    |> result.map_error(fn(_) { Uncertain }),
  )
  use result_digest <- result.try(
    wire.digest(bytes) |> result.map_error(fn(_) { Uncertain }),
  )
  use Nil <- result.try(
    journal.put_payload(
      state.config.journal,
      key,
      digest,
      payload.Terminal(bytes),
    )
    |> durable,
  )
  use _ <- result.try(
    journal.apply(
      state.config.journal,
      key,
      digest,
      admission.RefuseBeforeLaunch(result_digest),
    )
    |> durable,
  )
  Ok(#(state, wire.Terminal(key, digest, bytes)))
}

fn cancel_key(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(#(State, wire.Body), Error) {
  // A live control is already bound to this exact key and digest. Cancel it
  // before asking durability, so a poisoned journal cannot keep native work live.
  case live_row(state, key, digest) {
    Ok(row) -> native.cancel(row.native)
    Error(_) -> Nil
  }

  // The immutable cancellation reservation is the recovery fence even if the
  // process dies between payload, Admit and Refuse commits. Submit treats any
  // prior payload or bare admission as non-fresh and never authorizes launch.
  use bytes <- result.try(
    native.encode_terminal(
      dispatch.Failed(exec.ProtocolViolation(
        "remote request cancelled before native launch",
      )),
    )
    |> result.map_error(fn(_) { Uncertain }),
  )
  use Nil <- result.try(
    journal.put_payload(
      state.config.journal,
      key,
      digest,
      payload.Cancellation(bytes),
    )
    |> durable,
  )
  use decision <- result.try(
    journal.admit(state.config.journal, key, digest) |> durable,
  )
  case admission.phase(decision.evidence) {
    admission.Admitted -> {
      use result_digest <- result.try(
        wire.digest(bytes) |> result.map_error(fn(_) { Uncertain }),
      )
      use Nil <- result.try(
        journal.put_payload(
          state.config.journal,
          key,
          digest,
          payload.Terminal(bytes),
        )
        |> durable,
      )
      use _ <- result.try(
        journal.apply(
          state.config.journal,
          key,
          digest,
          admission.RefuseBeforeLaunch(result_digest),
        )
        |> durable,
      )
      Ok(#(state, wire.Terminal(key, digest, bytes)))
    }
    _ -> {
      use body <- result.try(query(state, key, digest, 64))
      Ok(#(state, body))
    }
  }
}

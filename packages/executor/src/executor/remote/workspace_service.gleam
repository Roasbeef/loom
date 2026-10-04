//// Semantic filesystem effects belong to a scoped service, never a connection.
////
//// Configuration binds an opaque local host to the journal's exact authority
//// scope. Submit validates canonical content before mailbox admission, reserves
//// durable input/result capacity, then takes the first committed execution claim.
//// Only that claim starts a concrete workspace_local.run in a bounded weft run.
//// Duplicate or recovered Started evidence never starts work again.
////
//// The task encodes and commits the exact completion before reporting. Its
//// death, deadline, failed encoding or lost persistence reply leaves Unknown;
//// none proves that a filesystem mutation did not happen. Submit returns initial
//// evidence immediately. Connections may later query the original bytes; they
//// neither own tasks nor keep a completion waiter inside this actor.
////
//// Each active run contributes one outcome and one final drain report through
//// weft's actor subscription adapter. The final report releases its live slot.
//// Durable UUID fences remain in the journal. Ingress aggregate byte/mailbox
//// admission is the enclosing authenticated host's responsibility.
////
//// Close seals durable authority before cancelling and joining these runs. A
//// lost seal reply means uncertain closure, with the journal retained. Joining
//// synchronous workers proves neither filesystem rollback nor native retirement;
//// the enclosing host owns native pool drain and journal release. Temporary
//// supervision never resurrects execution authority automatically. Best-effort
//// shutdown can seal/cancel, but an untrappable kill cannot run a shutdown hook.
////
//// ## Flow
////
//// `configure` checks assembly; `start` and `supervised` enter `builder`.
//// `submit`, `query` and `acknowledge` use `validate` before `exchange`.
//// `handle` dispatches `submit_initial`, which uses `first_claim` and `launch`.
//// `perform` runs the concrete host and persists completion. `reported` removes
//// subscriptions after weft's final report. `begin_close` seals before cancel;
//// `continue_or_close` replies only after all active runs have joined.

import broker/internal/call
import core/ids
import core/workspace as cw
import executor/remote/workspace_journal as journal
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/otp/actor as otp_actor
import gleam/otp/supervision
import gleam/result
import tools/workspace
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft
import weft/actor

/// Checked immutable assembly; peers cannot choose host, scope or task ceilings.
pub opaque type Config {
  /// The constructor is private so an inconsistent binding cannot reach start.
  Config(
    /// Concrete administratively bound executor-local workspace host.
    host: local.Host,
    /// Durable custodian with exactly the host's registration and epochs.
    journal: journal.Journal,
    /// One to four live runs; lifetime identity quotas belong to the journal.
    max_active: Int,
    /// Positive whole-run deadline, initially at most thirty seconds.
    task_ms: Int,
  )
}

/// An opaque service endpoint, independent from a transient caller connection.
pub opaque type Service {
  /// Only the private typed messages can cross this endpoint.
  Service(
    /// Immutable registration used to reject input before the mailbox.
    scope: cw.Scope,
    /// Private actor endpoint; callers cannot cast arbitrary filesystem commands.
    subject: process.Subject(Message),
    /// Lifecycle identity for host supervision, never proof of native retirement.
    pid: process.Pid,
  )
}

/// Fixed service errors; none turns already claimed work into a safe refusal.
pub type Error {
  /// Host/journal scope or supported task ceilings differ before service start.
  InvalidConfiguration

  /// Canonical invocation or acknowledgement digest validation failed.
  InvalidInput

  /// Invocation scope differs before journal access or filesystem effects.
  ScopeMismatch

  /// No active slot is available; admission/claim was not attempted.
  Capacity

  /// Durable custody returned this disposition without granting work.
  Custody(
    /// The original bounded journal error, including permanent Sealed authority.
    error: journal.Error,
  )

  /// This actor has begun close and accepts reconciliation only.
  Closing

  /// A reply, seal commit or task join was lost; retain original journal evidence.
  Uncertain
}

type TaskError {
  EncodingFailed
  PersistenceFailed
}

type Active {
  Active(
    cancel: weft.Cancel,
    reports: process.Subject(weft.Pulled(Nil, TaskError)),
  )
}

type Gate {
  Serving
  Joining(
    reply: process.Subject(Result(Nil, Error)),
    sealed: Result(Nil, Error),
  )
}

type State {
  State(
    config: Config,
    active: Dict(ids.EntryId, Active),
    selector: process.Selector(Message),
    gate: Gate,
  )
}

type Validated {
  Validated(bytes: BitArray, id: ids.EntryId)
}

type Message {
  Submit(Validated, process.Subject(Result(journal.Status, Error)))
  Query(Validated, process.Subject(Result(journal.Status, Error)))
  Acknowledge(
    Validated,
    BitArray,
    process.Subject(Result(journal.Status, Error)),
  )
  Report(ids.EntryId, weft.Pulled(Nil, TaskError))
  Close(process.Subject(Result(Nil, Error)))
}

/// The authenticated listener's closed operation door contains no effect callback.
@internal
pub type Operation {
  /// Takes the original invocation's first durable claim at most once.
  SubmitOperation

  /// Reads existing evidence without execution authority.
  QueryOperation

  /// Reconciles the digest after the owner retained the exact result.
  AcknowledgeOperation(digest: BitArray)
}

/// Checks exact host/journal scope and the initial finite concurrency/deadline caps.
/// This reads immutable accessors only and performs no filesystem operation.
///
/// ## Examples
///
/// `configure(host, journal, 4, 30_000)` binds at most four finite managed runs.
pub fn configure(
  host: local.Host,
  journal: journal.Journal,
  max_active: Int,
  task_ms: Int,
) -> Result(Config, Error) {
  case
    local.scope(host) == journal.scope(journal)
    && max_active >= 1
    && max_active <= 4
    && task_ms >= 1
    && task_ms <= 30_000
  {
    True -> Ok(Config(host, journal, max_active, task_ms))
    False -> Error(InvalidConfiguration)
  }
}

/// Starts an independently owned service over checked administrative assembly.
/// The enclosing host owes explicit close; caller loss cannot cancel its tasks.
///
/// ## Examples
///
/// `start(config)` starts no work until Submit obtains a first journal claim.
pub fn start(config: Config) -> Result(Service, Error) {
  builder(config)
  |> actor.unlinked
  |> actor.start
  |> result.map(fn(started) {
    Service(journal.scope(config.journal), started.data, started.pid)
  })
  |> result.replace_error(Uncertain)
}

/// Builds a linked Temporary child; recovery never automatically replays effects.
/// The host owns close before joining this child and draining its native assembly.
///
/// ## Examples
///
/// `supervised(config).start()` returns the same opaque endpoint as `start`.
pub fn supervised(config: Config) -> supervision.ChildSpecification(Service) {
  supervision.worker(fn() {
    builder(config)
    |> actor.start
    |> result.map(fn(started) {
      otp_actor.Started(
        started.pid,
        Service(journal.scope(config.journal), started.data, started.pid),
      )
    })
  })
  |> supervision.restart(supervision.Temporary)
}

/// Reads the immutable checked authority scope for authenticated transport assembly.
///
/// ## Examples
///
/// `scope(service)` must equal the endpoint's registered workspace scope.
pub fn scope(service: Service) -> cw.Scope {
  service.scope
}

/// Exposes the actor identity solely for enclosing lifetime ownership.
/// Death alone grants neither execution permission nor native retirement proof.
///
/// ## Examples
///
/// `pid(service)` is the Temporary child's lifecycle identity.
pub fn pid(service: Service) -> process.Pid {
  service.pid
}

/// Submits complete canonical bytes and returns initial durable evidence.
/// An initial Unknown means the first claim committed, not that effects finished.
/// Exact duplicates reconcile without another run, even when live capacity is full.
///
/// ## Examples
///
/// `submit(service, bytes)` usually returns Ok(journal.Unknown) after first claim.
pub fn submit(
  service: Service,
  bytes: BitArray,
) -> Result(journal.Status, Error) {
  use input <- result.try(validate(service.scope, bytes))
  exchange(service, Submit(input, _))
}

/// Reads exact committed journal status; this service contains no polling loop.
/// The caller may use weft.poll under its own finite connection/exchange budget.
///
/// ## Examples
///
/// `query(service, original_bytes)` replays Finished's exact retained bytes.
pub fn query(
  service: Service,
  bytes: BitArray,
) -> Result(journal.Status, Error) {
  use input <- result.try(validate(service.scope, bytes))
  exchange(service, Query(input, _))
}

/// Reconciles owner receipt even after durable sealing while the actor is live.
/// The owner MUST persist exact completion bytes before acknowledging their digest.
///
/// ## Examples
///
/// `acknowledge(service, bytes, journal.digest(completion))` retains the UUID fence.
pub fn acknowledge(
  service: Service,
  bytes: BitArray,
  digest: BitArray,
) -> Result(journal.Status, Error) {
  use Nil <- result.try(case bit_array.bit_size(digest) == 256 {
    True -> Ok(Nil)
    False -> Error(InvalidInput)
  })
  use input <- result.try(validate(service.scope, bytes))
  exchange(service, Acknowledge(input, digest, _))
}

/// Sends one validated ask whose reply remains with the stable ingress credit.
/// Validation refusal also replies, so every accepted door owes one final answer.
/// This door has no 35-second caller timeout and never withdraws queued custody.
///
/// ## Examples
///
/// `send_operation(service, QueryOperation, bytes, reply)` asks once.
@internal
pub fn send_operation(
  service: Service,
  operation: Operation,
  bytes: BitArray,
  reply: process.Subject(Result(journal.Status, Error)),
) -> Nil {
  let request = {
    use input <- result.try(validate(service.scope, bytes))
    case operation {
      SubmitOperation -> Ok(Submit(input, reply))
      QueryOperation -> Ok(Query(input, reply))
      AcknowledgeOperation(digest) ->
        case bit_array.bit_size(digest) == 256 {
          True -> Ok(Acknowledge(input, digest, reply))
          False -> Error(InvalidInput)
        }
    }
  }
  case request {
    Ok(message) -> process.send(service.subject, message)
    Error(error) -> process.send(reply, Error(error))
  }
}

/// Seals authority, cancels active runs, and awaits their final weft reports.
/// It retains the journal on every path; successful join asserts no rollback or
/// native retirement. A lost seal commit reply returns uncertain closure.
///
/// ## Examples
///
/// `close(service)` fences new claims before cancelling in-flight filesystem work.
pub fn close(service: Service) -> Result(Nil, Error) {
  exchange(service, Close)
}

fn builder(config: Config) {
  actor.new_with_initialiser(1000, fn(subject) {
    Ok(
      actor.initialised(State(
        config,
        dict.new(),
        process.new_selector() |> process.select(subject),
        Serving,
      ))
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle)
  |> actor.trapping_exits(True)
  |> actor.on_shutdown(shutdown)
}

fn validate(scope: cw.Scope, bytes: BitArray) -> Result(Validated, Error) {
  use invocation <- result.try(
    codec.decode_invocation(bytes) |> result.replace_error(InvalidInput),
  )
  let #(actual, _, _, _, id) = workspace.invocation_identity(invocation)
  case actual == scope {
    True -> Ok(Validated(bytes, id))
    False -> Error(ScopeMismatch)
  }
}

fn exchange(
  service: Service,
  make: fn(process.Subject(Result(a, Error))) -> Message,
) -> Result(a, Error) {
  call.try_call(service.subject, waiting: 35_000, sending: make)
  |> result.unwrap(Error(Uncertain))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Submit(input, reply) -> {
      let #(next, outcome) = submit_initial(state, input)
      process.send(reply, outcome)
      actor.continue(next) |> actor.with_selector(next.selector)
    }
    Query(input, reply) -> {
      process.send(
        reply,
        journal.inspect(state.config.journal, input.bytes)
          |> result.map_error(Custody),
      )
      actor.continue(state)
    }
    Acknowledge(input, digest, reply) -> {
      process.send(
        reply,
        journal.acknowledge(state.config.journal, input.bytes, digest)
          |> result.map_error(Custody),
      )
      actor.continue(state)
    }
    Report(id, report) -> reported(state, id, report)
    Close(reply) -> begin_close(state, reply)
  }
}

fn submit_initial(state: State, input: Validated) {
  // Existing Started/Finished evidence needs no live slot, even during close.
  // Accepted is the sole retained state from which a first claim is possible.
  case journal.inspect(state.config.journal, input.bytes) {
    Ok(journal.Accepted) | Error(journal.Missing) -> first_claim(state, input)
    Ok(status) -> #(state, Ok(status))
    Error(error) -> #(state, Error(Custody(error)))
  }
}

fn first_claim(state: State, input: Validated) {
  let permission = case state.gate {
    Joining(_, _) -> Error(Closing)
    Serving ->
      case dict.size(state.active) < state.config.max_active {
        True -> Ok(Nil)
        False -> Error(Capacity)
      }
  }
  let admitted = {
    use Nil <- result.try(permission)
    use _ <- result.try(
      journal.admit(state.config.journal, input.bytes)
      |> result.map_error(Custody),
    )
    journal.claim(state.config.journal, input.bytes)
    |> result.map_error(Custody)
  }

  // The claim commit precedes the worker's existence. A failure starting the run
  // cannot put Accepted back or assert that the filesystem operation was refused.
  case admitted {
    Ok(journal.Claimed(claim)) -> #(
      launch(state, input.id, claim),
      Ok(journal.Unknown),
    )
    Ok(journal.Existing(status)) -> #(state, Ok(status))
    Error(error) -> #(state, Error(error))
  }
}

fn launch(state: State, id: ids.EntryId, claim: journal.Claim) -> State {
  let reports = process.new_subject()
  let cancel = weft.cancel_signal()
  let host = state.config.host
  let _relay =
    weft.new_prepared([weft.managed(fn(_ledger) { perform(host, claim) })])
    |> weft.deadline(state.config.task_ms)
    |> weft.cancel_grace(1000)
    |> weft.cancel_with(cancel)
    |> weft.cancel_when_exits(process.self())
    |> weft.start_relayed(to: reports)
  State(
    ..state,
    active: dict.insert(state.active, id, Active(cancel, reports)),
    selector: process.select_map(state.selector, reports, Report(id, _)),
  )
}

fn perform(host: local.Host, claim: journal.Claim) -> Result(Nil, TaskError) {
  let invocation = journal.invocation(claim)
  let completion = local.run(host, invocation)
  use bytes <- result.try(
    codec.encode_completion(workspace.request(invocation), completion)
    |> result.replace_error(EncodingFailed),
  )

  // Exact completion is durable before even the advisory run outcome exists.
  journal.finish(claim, bytes)
  |> result.replace(Nil)
  |> result.replace_error(PersistenceFailed)
}

fn reported(
  state: State,
  id: ids.EntryId,
  report: weft.Pulled(Nil, TaskError),
) {
  case report {
    weft.PulledOutcome(_) | weft.NotYet -> actor.continue(state)
    weft.AllDelivered | weft.RunLost(_) -> {
      let next = case dict.get(state.active, id) {
        Error(Nil) -> state
        Ok(active) ->
          State(
            ..state,
            active: dict.delete(state.active, id),
            selector: process.deselect(state.selector, active.reports),
          )
      }
      let next = case report, next.gate {
        weft.RunLost(_), Joining(reply, _) ->
          State(..next, gate: Joining(reply, Error(Uncertain)))
        _, _ -> next
      }
      continue_or_close(next)
    }
  }
}

fn begin_close(state: State, reply: process.Subject(Result(Nil, Error))) {
  case state.gate {
    Joining(_, _) -> {
      process.send(reply, Error(Closing))
      actor.continue(state)
    }
    Serving -> {
      let sealed =
        journal.seal(state.config.journal)
        |> result.replace(Nil)
        |> result.replace_error(Uncertain)

      // Cancellation follows the seal attempt even if COMMIT's reply was lost.
      // Neither cancellation nor a dead worker changes original Started evidence.
      cancel_active(state.active)
      continue_or_close(State(..state, gate: Joining(reply, sealed)))
    }
  }
}

fn continue_or_close(state: State) {
  case state.gate, dict.size(state.active) {
    Joining(reply, outcome), 0 -> {
      process.send(reply, outcome)
      actor.stop()
    }
    Serving, _ | Joining(_, _), _ ->
      actor.continue(state) |> actor.with_selector(state.selector)
  }
}

fn cancel_active(active: Dict(ids.EntryId, Active)) -> Nil {
  dict.values(active) |> list.each(fn(active) { weft.cancel(active.cancel) })
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  case state.gate {
    Serving -> {
      let _ = journal.seal(state.config.journal)
      cancel_active(state.active)
    }
    Joining(_, _) -> cancel_active(state.active)
  }
}

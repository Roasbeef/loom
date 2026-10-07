//// Whole Compile keeps its original preparation continuation outside ingress.
////
//// The actor retains complete input before a managed admission ask. Only atomic
//// first admission returns a Claim; the actor stores that Claim before allowing
//// its worker to create the exact UUID allocation. Historical rows never restart
//// preparation. Claim and native permits are copyable local values, so trusted
//// assembly owes one original continuation rather than a recoverable bearer ID.
////
//// One monotonic cap starts when an original challenge is consumed. Preparation,
//// Ready persistence, native admission and completion observation spend that cap.
//// The native engine receives the unchanged cap and the listener's original final
//// reply endpoint. A forwarding task's drain cannot settle that native ask.
////
//// Cancellation first fences full original input, then follows its actual native
//// association, and finally cancels the managed continuation. Unknown asks and
//// lost drain proofs permanently fence admission. Closing joins local tasks but
//// proves neither resource cleanup nor native retirement. Hard kill cannot run a
//// fence hook; recovery reads history and never reconstructs a Claim.
//// Legacy construction keeps weft's linked ownership: an abnormal relay loss terminates
//// this temporary endpoint rather than leaving an admitting actor without proof.
//// Original construction retains the scope link and installs its own monitor,
//// retains custody before the typed work permit, and joins outcomes,
//// AllDelivered and original Normal independently. Preparation owners retain
//// artifacts until actual native safety and physical/SQL release are witnessed.
////
//// ## Flow
////
//// `configure` checks pinned assembly; `start` and `supervised` use `builder`.
//// `send_operation` enters `handle` and `handle_message`; `operation_key` selects the complete key; `submit` consumes a ticket before `launch`.
//// `perform` re-vets and admits; `begin_preparation` stores the original Claim.
//// `prepare` creates the allocation; `observe` finalizes once after real terminal.
//// `launch_control` bounds metadata asks before phase changes; `control` fences before native cancel.
//// `control_definite` classifies both the result transition and final metadata drain.
//// `route` forwards live claims directly and historical contexts through control.
//// `cancel_entry` follows a fence; `shutdown` attempts sealing on normal exit.
//// `reported` keeps uncertainty fenced; `begin_close` starts one seal/fence barrier.
//// `start_original` and `builder_observed` select original custody.
//// `launch_original` and `start_control_original` retain direct typed aggregates.
//// `offer_active_permit` and `offer_control_permit` retain worker-owned subjects.
//// `grant_runs`, `grant_begin` and `grant_begin_actual` release installed custody.
//// `linked_exit`, `pull_original_runs`, `active_down` and `control_down` keep independent proofs.
//// `original_active_report` and `original_control_report` retain delivery facts.
//// `finish_active_original`, `finish_control_original` and `joined_account` discharge them.
//// `begin_original_close`, `finish_original_close` and `expire_original_close` share a deadline.
//// `begin_release_preparations` and `continue_original_release` retain physical owners.
//// `close_digest`, `original_down` and `preparation_error` preserve exact summaries.

import broker/enrollment
import broker/internal/call
import codemode/compile
import codemode/service_input as input
import core/command
import core/generation
import core/json
import core/msgpack as mp
import core/workspace
import executor/remote/compile_completion as completion
import executor/remote/compile_observation as observation
import executor/remote/compile_preparation as preparation
import executor/remote/identity
import executor/remote/resource_journal as journal
import executor/remote/service as native
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
import gleam/string
import simplifile
import weft
import weft/actor
import weft/poll

/// Trusted exact endpoints and source contract, with explicit finite concurrency.
pub opaque type Config {
  /// Private checked constructor; administrative callers use configure.
  Config(
    /// Original durable resource endpoint; no equivalent replacement is accepted.
    resources: journal.Journal,
    /// The one existing native admission engine.
    native: native.Service,
    /// Trusted effective policy and exact generated catalogue, checked on Submit.
    contract: input.CompilationContract,
    /// Physical and independent metadata task bounds, each in one through four.
    max_active: Int,
    /// Complete enrolled administrative scope.
    scope: workspace.Scope,
  )
}

/// Temporary actor endpoint; its death cannot renew original effect permission.
pub opaque type Service {
  /// Private endpoint constructor retains the exact actor identity.
  Service(
    /// Checked scope for transport registration.
    scope: workspace.Scope,
    /// Exact native endpoint for listener assembly equality, without an ask.
    native: native.Service,
    /// Original checked resource enrollment for canonical listener decoding.
    enrolled: enrollment.SessionEnrollment,
    /// Original live resource writer identity, without its authority.
    resource_owner: process.Pid,
    /// Private closed message door.
    subject: process.Subject(Message),
    /// Lifecycle endpoint, separate from native retirement.
    pid: process.Pid,
  )
}

/// Original quiescence and complete actual finite aggregate account.
@internal
pub opaque type CompileCloseProof {
  /// Produced only after original continuation quiescence.
  CompileCloseProof(
    /// Exact original private Compile door.
    subject: process.Subject(Message),
    /// Original permanent Compile actor.
    pid: process.Pid,
    /// Retained original native Service identity.
    native_pid: process.Pid,
    /// Retained original durable resource actor.
    resource_pid: process.Pid,
    /// Complete immutable administrative scope.
    scope: workspace.Scope,
    /// Original close cap shared with preparation release.
    deadline: Int,
    /// Canonical account of actual discharged finite aggregates.
    digest: generation.Digest,
  )
}

/// Actual original preparation release inventory, after native-safe cleanup.
@internal
pub opaque type CompileResourcesProof {
  /// Original native-safe physical/SQL release account.
  CompileResourcesProof(
    /// Retained original quiescence and shared deadline.
    closed: CompileCloseProof,
    /// Sorted original cleanup accounts and final managed release account.
    digest: generation.Digest,
  )
}

/// Authenticated caller facts, independently compared against trusted assembly.
@internal
pub type Caller {
  /// Caller facts are data from an authenticated enclosing listener.
  Caller(
    /// Only the authenticated Owner role can enter this local door.
    role: wire.Role,
    /// Exact administratively pinned owner label.
    owner: String,
    /// Exact registered executor label.
    executor: String,
    /// Current transport generation, independent of execution identity.
    generation: Int,
    /// Complete session/workspace authority scope and epochs.
    scope: workspace.Scope,
  )
}

/// Whole-service operations contain data only, never effect callbacks.
@internal
pub type Operation {
  /// Issues a short single-use ticket for one complete Compile key.
  ChallengeRequest(
    /// Complete key, including the original input and enrollment digests.
    key: command.ServiceKey,
  )

  /// Offers exact canonical input and the original remaining attempt budget.
  Submit(
    /// Exact bounded canonical input; full identity is retained before admission.
    original: journal.Input,
    /// Original single-use 32-byte ticket.
    nonce: BitArray,
    /// Positive remaining whole-service duration, never a Unix deadline.
    budget_ms: Int,
  )

  /// Reads historical preparation and committed outer result only.
  Query(
    /// Complete original key selects checked retained input.
    key: command.ServiceKey,
  )

  /// Fences complete original input before following native association.
  Cancel(
    /// Full immutable input can fence even before a Claim reply exists.
    original: journal.Input,
  )

  /// Records the owner's separate durable receipt of exact outer completion.
  Acknowledge(
    /// Complete original key; physical/native coordinates cannot substitute it.
    key: command.ServiceKey,
    /// SHA-256 of the exact retained outer completion bytes.
    digest: identity.Digest,
  )
}

/// Replies describe durable history, never current allocation liveness.
@internal
pub type Reply {
  /// Nonce is bound to the exact key and expires on the executor's clock.
  Challenge(
    /// Original complete key named by this ticket.
    key: command.ServiceKey,
    /// Single-use entropy from the executor.
    nonce: BitArray,
    /// Fixed conservative executor-local window of 1000 milliseconds.
    window_ms: Int,
  )

  /// Independent preparation and outer-completion dispositions.
  Observed(
    /// Historical allocation evidence, without a resource lease.
    preparation: journal.Status,
    /// Committed outer result and independent owner receipt, if present.
    completion: journal.CompileStatus,
  )

  /// Committed input/scope fence, without cleanup or native retirement proof.
  Cancelled(
    /// Actual committed fence, not a cancellation or cleanup inference.
    fence: journal.PreparationFence,
  )
}

/// Closed refusal and uncertainty; none fabricates safe nonexecution.
pub type Error {
  /// Endpoint, enrollment or finite capacity differs before start.
  InvalidConfiguration

  /// Caller, key, canonical body or trusted source contract differs.
  Invalid

  /// No bounded task or challenge slot was admitted.
  Capacity

  /// Original nonce or whole-service cap is spent.
  Expired

  /// Fresh admission is permanently fenced or close is in progress.
  Closing

  /// A queued ask or drain proof was lost; original custody remains unresolved.
  Uncertain

  /// Exact bounded durable refusal.
  Custody(
    /// Original bounded durable diagnostic.
    error: journal.Error,
  )

  /// Concrete pre-native preparation error.
  Preparation(
    /// Concrete known error before Ready and native association.
    error: compile.CompileError,
  )
}

type Ticket {
  Ticket(key: command.ServiceKey, nonce: BitArray, issued: Int)
}

type Phase {
  Admitting
  Preparing(claim: journal.Claim)
  Observing(claim: journal.Claim)
  Stopping(claim: Option(journal.Claim))
  Stopped(claim: Option(journal.Claim))
}

type Drain {
  Awaiting
  Delivered
  Lost
}

type Active {
  Active(
    original: journal.Input,
    deadline: Int,
    phase: Phase,
    cancel: weft.Cancel,
    reports: process.Subject(weft.Pulled(Reply, Error)),
    reply: Option(process.Subject(Result(Reply, Error))),
    result: Option(Result(Reply, Error)),
    drain: Drain,
    original_run: Option(ActiveRun),
  )
}

type Control {
  Read(key: command.ServiceKey, digest: Option(identity.Digest))
  Fence(original: journal.Input)
  Route(
    envelope: wire.CommandEnvelope,
    reply: process.Subject(Result(wire.Body, native.Error)),
  )
  Barrier(originals: List(journal.Input))
  ReleasePreparations(
    proof: native.ScopeCloseProof,
    owners: List(preparation.Owner),
    deadline: Int,
  )
}

type ControlAnswer {
  Answer(value: Reply)
  Forwarded
  BarrierDone
  ResourcesReleased(digests: List(generation.Digest))
}

type ControlReply {
  Whole(reply: process.Subject(Result(Reply, Error)))
  Native(reply: process.Subject(Result(wire.Body, native.Error)))
  NoReply
}

type Metadata {
  Metadata(
    task: Control,
    reply: ControlReply,
    cancel: weft.Cancel,
    reports: process.Subject(weft.Pulled(ControlAnswer, Error)),
    result: Option(Result(ControlAnswer, Error)),
    drain: Drain,
    original_run: Option(ControlRun),
  )
}

type Gate {
  Serving
  Fenced
  Joining(
    reply: process.Subject(Result(Nil, Error)),
    barrier: Option(Result(Nil, Error)),
  )
}

type StartDecision {
  BeginPreparation
  BeginOwnedPreparation(owner: preparation.Owner)
  DoNotBegin
}

type Custody {
  LegacyCustody
  OriginalCustody
}

type OriginalDown {
  AwaitingDown
  NormalDown
  LostDown
}

type WorkPermit {
  AwaitingPermit
  OfferedPermit(process.Subject(Nil))
  GrantedPermit
}

type ActiveRun {
  ActiveRun(
    detached: weft.Detached(Reply, Error),
    watch: process.Monitor,
    down: OriginalDown,
    delivery: Drain,
    permit: WorkPermit,
  )
}

type ControlRun {
  ControlRun(
    deadline: Int,
    detached: weft.Detached(ControlAnswer, Error),
    watch: process.Monitor,
    down: OriginalDown,
    delivery: Drain,
    permit: WorkPermit,
  )
}

type OriginalClose {
  NotClosing
  JoiningOriginal(
    deadline: Int,
    reply: process.Subject(Result(CompileCloseProof, Error)),
  )
  AwaitingOriginalResources(proof: CompileCloseProof)
  ReleasingOriginal(
    proof: CompileCloseProof,
    reply: process.Subject(Result(CompileResourcesProof, Error)),
    result: Option(Result(List(generation.Digest), Error)),
  )
  LostOriginal
}

type State {
  State(
    config: Config,
    subject: process.Subject(Message),
    tickets: List(Ticket),
    active: Dict(command.ServiceKey, Active),
    metadata: Dict(Int, Metadata),
    serial: Int,
    selector: process.Selector(Message),
    gate: Gate,
    custody: Custody,
    preparations: Dict(command.ServiceKey, preparation.Owner),
    pending_begin: Option(
      #(command.ServiceKey, journal.Claim, process.Subject(StartDecision)),
    ),
    original_close: OriginalClose,
    account: BitArray,
    probe: Option(preparation.Probe),
    parent: process.Pid,
  )
}

type Message {
  Operation(
    caller: Caller,
    operation: Operation,
    reply: process.Subject(Result(Reply, Error)),
  )
  Begin(
    key: command.ServiceKey,
    claim: journal.Claim,
    reply: process.Subject(StartDecision),
  )
  Ready(key: command.ServiceKey)
  Report(key: command.ServiceKey, report: weft.Pulled(Reply, Error))
  ControlReport(id: Int, report: weft.Pulled(ControlAnswer, Error))
  Command(
    envelope: wire.CommandEnvelope,
    reply: process.Subject(Result(wire.Body, native.Error)),
  )
  LinkedExit(process.ExitMessage)
  ResourceDown
  NativeDown
  Close(reply: process.Subject(Result(Nil, Error)))
  CloseOriginal(reply: process.Subject(Result(CompileCloseProof, Error)))
  ClosePreparations(
    proof: native.ScopeCloseProof,
    reply: process.Subject(Result(CompileResourcesProof, Error)),
  )
  GrantRuns
  ActivePermit(command.ServiceKey, process.Subject(Nil))
  ControlPermit(Int, process.Subject(Nil))
  ReleaseBegin(
    command.ServiceKey,
    journal.Claim,
    process.Subject(StartDecision),
    process.Subject(Nil),
  )
  GrantBegin
  PullOriginalRuns
  ActiveDown(key: command.ServiceKey, down: process.Down)
  ControlDown(id: Int, down: process.Down)
}

/// Checks exact endpoints and administrative scope without reading peer input.
/// Source and opaque contract enrollment are revalidated on Submit before effects.
///
/// ## Examples
///
/// ```gleam
/// compile_service.configure(resources, native, contract, 2)
/// // -> Ok(config) for the exact enrolled assembly.
/// ```
pub fn configure(
  resources: journal.Journal,
  native: native.Service,
  contract: input.CompilationContract,
  max_active: Int,
) -> Result(Config, Error) {
  let config = native.configuration(native)
  let scope = enrollment.native_facts(journal.enrolled(resources)).scope
  let #(session, name, executor, session_epoch, workspace_epoch) =
    identity.scope_fields(config.scope)
  use actual <- result.try(
    workspace.scope_from_fields(
      session,
      name,
      executor,
      session_epoch,
      workspace_epoch,
    )
    |> result.replace_error(InvalidConfiguration),
  )
  case
    actual == scope
    && journal.native_endpoint(resources) == config.journal
    && max_active >= 1
    && max_active <= 4
  {
    True -> Ok(Config(resources, native, contract, max_active, scope))
    False -> Error(InvalidConfiguration)
  }
}

/// Starts a stable temporary service; no physical work starts during initialization.
///
/// ## Examples
///
/// ```gleam
/// compile_service.start(config) // -> Ok(service).
/// ```
pub fn start(config: Config) -> Result(Service, Error) {
  builder(config)
  |> actor.unlinked
  |> actor.start
  |> result.map(fn(started) {
    Service(
      config.scope,
      config.native,
      journal.enrolled(config.resources),
      journal.pid(config.resources),
      started.data,
      started.pid,
    )
  })
  |> result.replace_error(Uncertain)
}

/// Starts the permanent original-custody service under its actual host parent.
/// No preparation or SQL work runs in this initializer.
///
/// ## Examples
///
/// `start_original(config)` retains original preparation owners until full close.
@internal
pub fn start_original(config: Config) -> Result(Service, Error) {
  start_original_observed(config, None)
}

/// Retains the same original service with fixed internal test observations.
///
/// ## Examples
///
/// `start_original_observed(config, None)` is production original construction.
@internal
pub fn start_original_observed(
  config: Config,
  probe: Option(preparation.Probe),
) -> Result(Service, Error) {
  builder_observed(config, OriginalCustody, probe)
  |> actor.trapping_exits(True)
  |> actor.periodic(every: 25, sending: PullOriginalRuns)
  |> actor.start
  |> result.map(fn(started) {
    Service(
      config.scope,
      config.native,
      journal.enrolled(config.resources),
      journal.pid(config.resources),
      started.data,
      started.pid,
    )
  })
  |> result.replace_error(Uncertain)
}

/// Creates a temporary child; supervision never reissues original Claims.
///
/// ## Examples
///
/// ```gleam
/// compile_service.supervised(config) // -> a Temporary child specification.
/// ```
pub fn supervised(config: Config) -> supervision.ChildSpecification(Service) {
  supervision.worker(fn() {
    builder(config)
    |> actor.start
    |> result.map(fn(started) {
      otp_actor.Started(
        started.pid,
        Service(
          config.scope,
          config.native,
          journal.enrolled(config.resources),
          journal.pid(config.resources),
          started.data,
          started.pid,
        ),
      )
    })
  })
  |> supervision.restart(supervision.Temporary)
}

/// Reads the exact checked registration scope, without asking a journal.
///
/// ## Examples
///
/// ```gleam
/// compile_service.scope(service) // -> the enrolled scope.
/// ```
pub fn scope(service: Service) -> workspace.Scope {
  service.scope
}

/// Reads the exact pinned native endpoint for enclosing listener assembly.
/// Equal administrative scopes do not permit substituting another endpoint.
///
/// ## Examples
///
/// ```gleam
/// compile_service.native_service(service) == native // -> exact endpoint equality.
/// ```
@internal
pub fn native_service(service: Service) -> native.Service {
  service.native
}

/// Reads original checked enrollment for canonical listener input and Ready codecs.
/// The listener does not accept a separately supplied enrollment snapshot.
///
/// ## Examples
///
/// ```gleam
/// compile_service.enrolled(service) // -> the original resource enrollment.
/// ```
@internal
pub fn enrolled(service: Service) -> enrollment.SessionEnrollment {
  service.enrolled
}

/// Projects the original resource writer identity without exposing its authority.
///
/// ## Examples
///
/// ```gleam
/// compile_service.resource_owner(service) // -> original_writer_pid.
/// ```
pub fn resource_owner(service: Service) -> process.Pid {
  service.resource_owner
}

/// Exposes only actor lifetime; endpoint death proves no resource cleanup.
///
/// ## Examples
///
/// ```gleam
/// process.monitor(compile_service.pid(service)) // -> an endpoint monitor.
/// ```
pub fn pid(service: Service) -> process.Pid {
  service.pid
}

/// Transfers one authenticated local operation with its original final reply door.
/// The enclosing listener still owns aggregate byte/mailbox admission.
///
/// ## Examples
///
/// ```gleam
/// compile_service.send_operation(service, caller, compile_service.Query(key), reply)
/// // -> Nil; a later reply describes committed history.
/// ```
@internal
pub fn send_operation(
  service: Service,
  caller: Caller,
  operation: Operation,
  reply: process.Subject(Result(Reply, Error)),
) -> Nil {
  process.send(service.subject, Operation(caller, operation, reply))
}

/// Forwards complete command asks through the same native admission engine.
/// The original listener reply subject is retained; forwarding is no acknowledgement.
///
/// ## Examples
///
/// ```gleam
/// compile_service.send_command_exchange(service, envelope, reply) // -> Nil.
/// ```
@internal
pub fn send_command_exchange(
  service: Service,
  envelope: wire.CommandEnvelope,
  reply: process.Subject(Result(wire.Body, native.Error)),
) -> Nil {
  process.send(service.subject, Command(envelope, reply))
}

/// Seals/fences original custody and joins this actor's managed continuations.
/// It never releases journals, cleans resources or asserts native retirement.
///
/// ## Examples
///
/// ```gleam
/// compile_service.close(service) // -> Ok(Nil) only after local drain evidence.
/// ```
pub fn close(service: Service) -> Result(Nil, Error) {
  call.try_call(service.subject, waiting: 35_000, sending: Close)
  |> result.unwrap(Error(Uncertain))
}

/// Quiesces original continuations while retaining actual preparation owners.
///
/// ## Examples
///
/// `close_original(service)` leaves original resource/native doors available.
@internal
pub fn close_original(service: Service) -> Result(CompileCloseProof, Error) {
  call.try_call(service.subject, waiting: 35_000, sending: CloseOriginal)
  |> result.unwrap(Error(Uncertain))
}

/// Completes native-safe original preparation release under the retained deadline.
///
/// ## Examples
///
/// `close_preparations(service, proof)` never reconstructs ownership from SQL.
@internal
pub fn close_preparations(
  service: Service,
  proof: native.ScopeCloseProof,
) -> Result(CompileResourcesProof, Error) {
  call.try_call(service.subject, waiting: 35_000, sending: ClosePreparations(
    proof,
    _,
  ))
  |> result.unwrap(Error(Uncertain))
}

/// Checks the exact original service after a retained close result.
///
/// ## Examples
///
/// `validate_close_original(original, proof)` refuses replacement actors.
@internal
pub fn validate_close_original(
  service: Service,
  proof: CompileCloseProof,
) -> Result(generation.Digest, Error) {
  case
    service.subject == proof.subject
    && service.pid == proof.pid
    && native.pid(service.native) == proof.native_pid
    && service.resource_owner == proof.resource_pid
    && service.scope == proof.scope
  {
    True -> Ok(proof.digest)
    False -> Error(Invalid)
  }
}

/// Checks the original resource proof without reopening stopped actors.
///
/// ## Examples
///
/// `validate_preparations(original, proof)` observes no new authority.
@internal
pub fn validate_preparations(
  service: Service,
  proof: CompileResourcesProof,
) -> Result(generation.Digest, Error) {
  use _ <- result.try(validate_close_original(service, proof.closed))
  Ok(proof.digest)
}

fn builder(
  config: Config,
) -> actor.Builder(State, Message, process.Subject(Message)) {
  builder_observed(config, LegacyCustody, None)
}

fn builder_observed(
  config: Config,
  custody: Custody,
  probe: Option(preparation.Probe),
) -> actor.Builder(State, Message, process.Subject(Message)) {
  let parent = process.self()
  actor.new_with_initialiser(1000, fn(subject) {
    let resource_monitor = process.monitor(journal.pid(config.resources))
    let native_monitor = process.monitor(native.pid(config.native))
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_specific_monitor(resource_monitor, fn(_) {
        ResourceDown
      })
      |> process.select_specific_monitor(native_monitor, fn(_) { NativeDown })
    let selector = case custody {
      LegacyCustody -> selector
      OriginalCustody -> process.select_trapped_exits(selector, LinkedExit)
    }
    Ok(
      actor.initialised(State(
        config,
        subject,
        [],
        dict.new(),
        dict.new(),
        0,
        selector,
        Serving,
        custody,
        dict.new(),
        None,
        NotClosing,
        <<>>,
        probe,
        parent,
      ))
      |> actor.selecting(selector)
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle)
  |> actor.on_shutdown(shutdown)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    LinkedExit(exit) -> linked_exit(state, exit)
    _ -> handle_message(state, message)
  }
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  let next = case message {
    Operation(caller, requested, reply) ->
      operation(state, caller, requested, reply)
    Begin(key, claim, reply) -> begin_preparation(state, key, claim, reply)
    Ready(key) -> ready(state, key)
    Report(key, report) -> reported(state, key, report)
    ControlReport(id, report) -> control_reported(state, id, report)
    Command(envelope, reply) -> route(state, envelope, reply)
    LinkedExit(_) -> state
    ResourceDown | NativeDown -> fence_service(state)
    Close(reply) ->
      case state.custody {
        LegacyCustody -> begin_close(state, reply)
        OriginalCustody -> {
          process.send(reply, Error(Closing))
          state
        }
      }
    CloseOriginal(reply) -> begin_original_close(state, reply)
    ClosePreparations(proof, reply) ->
      begin_release_preparations(state, proof, reply)
    GrantRuns -> grant_runs(state)
    ActivePermit(key, permit) -> offer_active_permit(state, key, permit)
    ControlPermit(id, permit) -> offer_control_permit(state, id, permit)
    GrantBegin -> grant_begin(state)
    ReleaseBegin(key, claim, reply, permit) ->
      grant_begin_actual(
        State(..state, selector: process.deselect(state.selector, permit)),
        key,
        claim,
        reply,
      )
    PullOriginalRuns -> pull_original_runs(state)
    ActiveDown(key, down) -> active_down(state, key, down)
    ControlDown(id, down) -> control_down(state, id, down)
  }
  let continuing = continue_or_close(next)
  case message {
    Operation(..)
    | ActivePermit(..)
    | ControlPermit(..)
    | Command(..)
    | Begin(..)
    | Report(..)
    | ControlReport(..)
    | ActiveDown(..)
    | ControlDown(..)
    | CloseOriginal(..)
    | ClosePreparations(..)
    | Close(..)
    | ResourceDown
    | NativeDown
    | PullOriginalRuns ->
      continuing
      |> actor.then_handle(GrantRuns)
      |> actor.then_handle(GrantBegin)
    GrantRuns | GrantBegin | ReleaseBegin(..) | LinkedExit(_) | Ready(_) ->
      continuing
  }
}

fn operation(
  state: State,
  caller: Caller,
  requested: Operation,
  reply: process.Subject(Result(Reply, Error)),
) -> State {
  let key = operation_key(requested)
  case validate_caller(state.config, caller, key) {
    Error(error) -> {
      process.send(reply, Error(error))
      state
    }
    Ok(Nil) -> dispatch(state, requested, reply)
  }
}

fn operation_key(operation: Operation) -> command.ServiceKey {
  case operation {
    ChallengeRequest(key) | Query(key) | Acknowledge(key, _) -> key
    Submit(original, _, _) | Cancel(original) -> original.key
  }
}

fn validate_caller(
  config: Config,
  caller: Caller,
  key: command.ServiceKey,
) -> Result(Nil, Error) {
  let native = native.configuration(config.native)
  case
    caller.role == wire.Owner
    && caller.owner == native.owner
    && caller.executor == native.executor
    && caller.generation == native.generation
    && caller.scope == config.scope
    && command.coordinates(key).0 == config.scope
    && command.service_role(key) == command.CompileService
  {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

fn dispatch(
  state: State,
  requested: Operation,
  reply: process.Subject(Result(Reply, Error)),
) -> State {
  case requested {
    ChallengeRequest(key) -> challenge(state, key, reply)
    Submit(original, nonce, budget) ->
      submit(state, original, nonce, budget, reply)
    Query(key) -> launch_control(state, Read(key, None), Whole(reply))
    Acknowledge(key, digest) ->
      launch_control(state, Read(key, Some(digest)), Whole(reply))
    Cancel(original) -> {
      case validate_input(state.config, original) {
        Error(error) -> {
          process.send(reply, Error(error))
          state
        }
        Ok(_) -> launch_control(state, Fence(original), Whole(reply))
      }
    }
  }
}

fn challenge(
  state: State,
  key: command.ServiceKey,
  reply: process.Subject(Result(Reply, Error)),
) -> State {
  let now = native.configuration(state.config.native).now()
  let tickets =
    list.filter(state.tickets, fn(ticket) {
      now >= ticket.issued && now - ticket.issued < 1000
    })
  case state.gate, list.is_empty(list.drop(tickets, 31)) {
    Serving, True -> {
      let nonce = crypto.strong_random_bytes(32)
      process.send(reply, Ok(Challenge(key, nonce, 1000)))
      State(..state, tickets: [Ticket(key, nonce, now), ..tickets])
    }
    Serving, False -> {
      process.send(reply, Error(Capacity))
      State(..state, tickets:)
    }
    Fenced, _ | Joining(_, _), _ -> {
      process.send(reply, Error(Closing))
      State(..state, tickets:)
    }
  }
}

fn submit(
  state: State,
  original: journal.Input,
  nonce: BitArray,
  budget: Int,
  reply: process.Subject(Result(Reply, Error)),
) -> State {
  case dict.get(state.active, original.key) {
    Ok(active) -> {
      case active.original == original {
        True -> launch_control(state, Read(original.key, None), Whole(reply))
        False -> {
          process.send(reply, Error(Invalid))
          state
        }
      }
    }
    Error(Nil) -> submit_fresh(state, original, nonce, budget, reply)
  }
}

fn submit_fresh(
  state: State,
  original: journal.Input,
  nonce: BitArray,
  budget: Int,
  reply: process.Subject(Result(Reply, Error)),
) -> State {
  let now = native.configuration(state.config.native).now()
  let ticket =
    list.find(state.tickets, fn(ticket) {
      ticket.key == original.key && ticket.nonce == nonce
    })
  let permitted = {
    use Nil <- result.try(admission_capacity(state))
    use ticket <- result.try(ticket |> result.replace_error(Expired))
    use Nil <- result.try(
      case
        bit_array.byte_size(nonce) == 32
        && budget > 0
        && budget <= 86_400_000
        && now >= ticket.issued
        && now - ticket.issued < 1000
      {
        True -> Ok(Nil)
        False -> Error(Expired)
      },
    )
    validate_input(state.config, original)
  }
  case permitted {
    Error(error) -> {
      process.send(reply, Error(error))
      state
    }
    Ok(_) -> {
      // Consumption precedes admission dispatch. The original cap is retained
      // even when a downstream commit reply or Claim handoff is lost.
      let state =
        State(
          ..state,
          tickets: list.filter(state.tickets, fn(ticket) {
            ticket.nonce != nonce
          }),
        )
      launch(state, original, now + budget, reply)
    }
  }
}

fn admission_capacity(state: State) -> Result(Nil, Error) {
  case state.gate, dict.size(state.active) < state.config.max_active {
    Serving, True -> Ok(Nil)
    Serving, False -> Error(Capacity)
    Fenced, _ | Joining(_, _), _ -> Error(Closing)
  }
}

fn validate_input(
  config: Config,
  original: journal.Input,
) -> Result(input.CompileInput, Error) {
  use decoded <- result.try(
    input.decode_compile(original.body) |> result.replace_error(Invalid),
  )
  use Nil <- result.try(
    enrollment.matches(
      journal.enrolled(config.resources),
      input.compile_facts(decoded).enrolled,
    )
    |> result.replace_error(Invalid),
  )
  use _ <- result.try(
    input.compile_envelope(original.key, decoded)
    |> result.replace_error(Invalid),
  )
  case
    string.lowercase(bit_array.base16_encode(journal.digest(original.body)))
    == command.digests(original.key).0
  {
    True -> Ok(decoded)
    False -> Error(Invalid)
  }
}

fn launch(
  state: State,
  original: journal.Input,
  deadline: Int,
  reply: process.Subject(Result(Reply, Error)),
) -> State {
  case state.custody {
    LegacyCustody -> launch_legacy(state, original, deadline, reply)
    OriginalCustody -> launch_original(state, original, deadline, reply)
  }
}

fn launch_legacy(
  state: State,
  original: journal.Input,
  deadline: Int,
  reply: process.Subject(Result(Reply, Error)),
) -> State {
  let reports = process.new_subject()
  let cancel = weft.cancel_signal()
  let config = state.config
  let subject = state.subject
  let now = native.configuration(config.native).now
  let _ =
    weft.new_prepared([
      weft.managed(fn(_ledger) { perform(config, subject, original, deadline) }),
    ])
    |> weft.deadline(deadline - now())
    |> weft.cancel_grace(1000)
    |> weft.cancel_with(cancel)
    |> weft.cancel_when_exits(process.self())
    |> weft.start_relayed(to: reports)
  let active =
    Active(
      original,
      deadline,
      Admitting,
      cancel,
      reports,
      Some(reply),
      None,
      Awaiting,
      None,
    )
  State(
    ..state,
    active: dict.insert(state.active, original.key, active),
    selector: process.select_map(state.selector, reports, Report(
      original.key,
      _,
    )),
  )
}

fn begin_preparation(
  state: State,
  key: command.ServiceKey,
  claim: journal.Claim,
  reply: process.Subject(StartDecision),
) -> State {
  case dict.get(state.active, key) {
    Error(Nil) -> {
      process.send(reply, DoNotBegin)
      state
    }
    Ok(active) -> accept_begin(state, active, key, claim, reply)
  }
}

fn accept_begin(
  state: State,
  active: Active,
  key: command.ServiceKey,
  claim: journal.Claim,
  reply: process.Subject(StartDecision),
) -> State {
  let now = native.configuration(state.config.native).now()
  let exact = active.original == journal.original(claim)
  case state.gate, active.phase {
    Serving, Admitting if exact && active.deadline > now -> {
      // Claim retention precedes the response authorizing physical preparation.
      // Copying this local value never creates a second original continuation.
      let active = Active(..active, phase: Preparing(claim), reply: None)
      send_whole(
        active_reply(state, key),
        Ok(Observed(journal.Unknown(None), journal.CompilePending)),
      )
      case state.custody {
        LegacyCustody -> {
          process.send(reply, BeginPreparation)
          State(..state, active: dict.insert(state.active, key, active))
        }
        OriginalCustody -> {
          case
            preparation.park_observed(
              state.config.resources,
              state.config.native,
              active.original,
              state.probe,
            )
          {
            Ok(owner) ->
              State(
                ..state,
                active: dict.insert(state.active, key, active),
                preparations: dict.insert(state.preparations, key, owner),
                pending_begin: Some(#(key, claim, reply)),
              )
            Error(_) -> {
              process.send(reply, DoNotBegin)
              fence_service(state)
            }
          }
        }
      }
    }
    Serving, Preparing(_)
    | Serving, Observing(_)
    | Serving, Stopping(_)
    | Serving, Stopped(_)
    | Serving, Admitting
    | Fenced, _
    | Joining(_, _), _
    -> {
      process.send(reply, DoNotBegin)
      state
    }
  }
}

fn active_reply(
  state: State,
  key: command.ServiceKey,
) -> Option(process.Subject(Result(Reply, Error))) {
  dict.get(state.active, key)
  |> result.map(fn(active) { active.reply })
  |> result.unwrap(None)
}

fn ready(state: State, key: command.ServiceKey) -> State {
  case dict.get(state.active, key) {
    Ok(Active(phase: Preparing(claim), ..) as active) ->
      State(
        ..state,
        active: dict.insert(
          state.active,
          key,
          Active(..active, phase: Observing(claim)),
        ),
      )
    Ok(_) | Error(Nil) -> state
  }
}

fn perform(
  config: Config,
  subject: process.Subject(Message),
  original: journal.Input,
  deadline: Int,
) -> Result(Reply, Error) {
  use decoded <- result.try(validate_input(config, original))
  use admitted <- result.try(
    admit_attempt(config, original.key, decoded)
    |> result.replace_error(Invalid),
  )
  use Nil <- result.try(remaining(config, deadline))
  use first <- result.try(
    journal.admit_preparation(config.resources, original)
    |> result.map_error(Custody),
  )
  case first {
    journal.Retained(status) -> {
      use completion <- result.try(
        journal.inspect_compile(config.resources, original)
        |> result.map_error(Custody),
      )
      Ok(Observed(status, completion))
    }
    journal.FreshClaim(claim) -> {
      use owner <- result.try(handoff(
        config,
        subject,
        original.key,
        claim,
        deadline,
      ))
      let prepared = case owner {
        None -> prepare(config, admitted, claim, deadline)
        Some(owner) ->
          preparation.prepare(owner, admitted, claim, deadline)
          |> result.map_error(preparation_error)
      }
      case prepared {
        Ok(Nil) -> {
          process.send(subject, Ready(original.key))
          observe(config, original, deadline)
        }
        Error(Preparation(error)) -> before(config, claim, error)
        Error(error) -> Error(error)
      }
    }
  }
}

fn handoff(
  config: Config,
  subject: process.Subject(Message),
  key: command.ServiceKey,
  claim: journal.Claim,
  deadline: Int,
) -> Result(Option(preparation.Owner), Error) {
  use Nil <- result.try(remaining(config, deadline))
  let wait = deadline - native.configuration(config.native).now()
  case call.try_call(subject, waiting: wait, sending: Begin(key, claim, _)) {
    Ok(BeginPreparation) -> remaining(config, deadline) |> result.replace(None)
    Ok(BeginOwnedPreparation(owner)) ->
      remaining(config, deadline) |> result.replace(Some(owner))
    Ok(DoNotBegin) -> Error(Closing)
    Error(_) -> Error(Uncertain)
  }
}

fn prepare(
  config: Config,
  admitted: input.AdmittedCompile,
  claim: journal.Claim,
  deadline: Int,
) -> Result(Nil, Error) {
  let #(key, _, _) = input.admitted_compile(admitted)
  let enrolled = journal.enrolled(config.resources)
  use root <- result.try(
    enrollment.compile_path(enrolled, key) |> result.replace_error(Invalid),
  )
  use Nil <- result.try(remaining(config, deadline))

  // Exclusive mkdir refuses a preexisting allocation. No cleanup or alternative
  // suffix can erase lifetime identity or make a failed preparation retry safe.
  use Nil <- result.try(
    simplifile.create_directory(root)
    |> result.replace_error(
      Preparation(compile.WorkspaceSetupFailed(
        "allocation already exists or cannot be created",
      )),
    ),
  )
  use Nil <- result.try(remaining(config, deadline))
  use ready <- result.try(
    preparation.write_layout(
      config.resources,
      config.native,
      admitted,
      root,
      deadline,
    )
    |> result.map_error(preparation_error),
  )
  preparation.publish_ready(config.native, claim, ready, deadline)
  |> result.map_error(preparation_error)
}

fn before(
  config: Config,
  claim: journal.Claim,
  error: compile.CompileError,
) -> Result(Reply, Error) {
  let original = journal.original(claim)
  use value <- result.try(
    completion.failed_before_native(
      journal.enrolled(config.resources),
      original.key,
      observation.bounded_error(error),
    )
    |> result.replace_error(Invalid),
  )
  use retained <- result.try(
    journal.fail_preparation(claim, value) |> result.map_error(Custody),
  )
  Ok(Observed(
    journal.Unknown(None),
    journal.CompileRetained(retained, journal.ReceiptPending),
  ))
}

fn observe(
  config: Config,
  original: journal.Input,
  deadline: Int,
) -> Result(Reply, Error) {
  use Nil <- result.try(remaining(config, deadline))
  let now = native.configuration(config.native).now
  let observed =
    poll.until_on(
      poll.Clock(now, process.sleep),
      deadline - now(),
      poll.Fixed(25),
      fn() {
        case observation.observe(config.resources, original) {
          Ok(Some(value)) -> poll.Done(value)
          Ok(None) -> poll.Retry
          Error(_) -> poll.Fail(Uncertain)
        }
      },
    )
  use value <- result.try(case observed {
    poll.Answered(value) -> Ok(value)
    poll.Failed(error) -> Error(error)
    poll.Expired -> Error(Expired)
  })
  use Nil <- result.try(remaining(config, deadline))
  use completion <- result.try(
    observation.finalize(value) |> result.replace_error(Uncertain),
  )
  use Nil <- result.try(remaining(config, deadline))
  use retained <- result.try(
    journal.commit_compile(config.resources, original, completion)
    |> result.map_error(Custody),
  )
  use status <- result.try(
    journal.inspect(config.resources, original) |> result.map_error(Custody),
  )
  Ok(Observed(status, journal.CompileRetained(retained, journal.ReceiptPending)))
}

fn remaining(config: Config, deadline: Int) -> Result(Nil, Error) {
  case native.configuration(config.native).now() < deadline {
    True -> Ok(Nil)
    False -> Error(Expired)
  }
}

fn route(
  state: State,
  envelope: wire.CommandEnvelope,
  reply: process.Subject(Result(wire.Body, native.Error)),
) -> State {
  let ref = wire.command_ref(envelope)
  case dict.get(state.active, command.service(ref)) {
    Ok(active) -> route_active(state, active, ref, envelope, reply)
    Error(Nil) -> launch_control(state, Route(envelope, reply), Native(reply))
  }
}

fn route_active(
  state: State,
  active: Active,
  ref: command.CommandRef,
  envelope: wire.CommandEnvelope,
  reply: process.Subject(Result(wire.Body, native.Error)),
) -> State {
  case phase_claim(active.phase), state.gate {
    Some(claim), Serving -> {
      case
        native.live_command_context(
          state.config.native,
          claim,
          ref,
          active.deadline,
        )
      {
        Ok(context) -> {
          native.send_command_exchange(
            state.config.native,
            context,
            envelope,
            reply,
          )
          state
        }
        Error(error) -> {
          process.send(reply, Error(error))
          state
        }
      }
    }
    None, _ | Some(_), Fenced | Some(_), Joining(_, _) ->
      launch_control(state, Route(envelope, reply), Native(reply))
  }
}

fn phase_claim(phase: Phase) -> Option(journal.Claim) {
  case phase {
    Preparing(claim) | Observing(claim) -> Some(claim)
    Admitting | Stopping(_) | Stopped(_) -> None
  }
}

fn launch_control(state: State, task: Control, reply: ControlReply) -> State {
  case dict.size(state.metadata) < state.config.max_active {
    False -> {
      send_control(reply, Error(Capacity))
      state
    }
    True -> {
      // Metadata admission and the local stop transition share this actor turn.
      // A capacity refusal must leave the original Claim and phase unchanged.
      let state = case task {
        Fence(original) -> stop_entry(state, original.key)
        Read(_, _) | Route(_, _) | Barrier(_) | ReleasePreparations(..) -> state
      }
      start_control(state, task, reply)
    }
  }
}

fn start_control(state: State, task: Control, reply: ControlReply) -> State {
  case state.custody {
    LegacyCustody -> start_control_legacy(state, task, reply)
    OriginalCustody -> start_control_original(state, task, reply)
  }
}

fn start_control_legacy(
  state: State,
  task: Control,
  reply: ControlReply,
) -> State {
  let reports = process.new_subject()
  let cancel = weft.cancel_signal()
  let config = state.config
  let id = state.serial
  let _ =
    weft.new_prepared([weft.managed(fn(_ledger) { control(config, task) })])
    |> weft.deadline(30_000)
    |> weft.cancel_grace(1000)
    |> weft.cancel_with(cancel)
    |> weft.cancel_when_exits(process.self())
    |> weft.start_relayed(to: reports)
  let metadata = Metadata(task, reply, cancel, reports, None, Awaiting, None)
  State(
    ..state,
    serial: id + 1,
    metadata: dict.insert(state.metadata, id, metadata),
    selector: process.select_map(state.selector, reports, ControlReport(id, _)),
  )
}

fn control(config: Config, task: Control) -> Result(ControlAnswer, Error) {
  case task {
    Read(key, digest) -> {
      use original <- result.try(
        journal.retained_input(config.resources, key)
        |> result.map_error(Custody),
      )
      use prepared <- result.try(
        journal.inspect(config.resources, original) |> result.map_error(Custody),
      )
      let completed = case digest {
        None -> journal.inspect_compile(config.resources, original)
        Some(digest) ->
          journal.acknowledge_compile(config.resources, original, digest)
      }
      use completed <- result.try(completed |> result.map_error(Custody))
      Ok(Answer(Observed(prepared, completed)))
    }
    Fence(original) -> {
      use fenced <- result.try(fence_original(config, original))
      Ok(Answer(Cancelled(fenced)))
    }
    Route(envelope, reply) -> {
      // Historical lookup stays inside a managed bounded metadata task. Passing
      // the original final reply endpoint does not discharge listener custody.
      // An exact identity refusal is definite; only its joined metadata task
      // releases the slot. Journal or reply uncertainty still fences admission.
      use context <- result.try(
        native.command_context(
          config.native,
          config.resources,
          wire.command_ref(envelope),
        )
        |> result.map_error(fn(error) {
          case error {
            native.Invalid -> Invalid
            native.Capacity | native.Expired | native.Uncertain -> Uncertain
          }
        }),
      )
      native.send_command_exchange(config.native, context, envelope, reply)
      Ok(Forwarded)
    }
    ReleasePreparations(proof, owners, deadline) -> {
      use digests <- result.try(
        list.try_map(owners, fn(owner) {
          use released <- result.try(
            preparation.release(owner, proof, deadline)
            |> result.map_error(preparation_error),
          )
          preparation.validate_release(owner, released)
          |> result.map_error(preparation_error)
        }),
      )
      Ok(ResourcesReleased(digests))
    }
    Barrier(originals) -> {
      use _ <- result.try(
        journal.seal(config.resources) |> result.map_error(Custody),
      )
      use _ <- result.try(
        list.try_map(originals, fn(original) {
          fence_original(config, original)
        }),
      )
      Ok(BarrierDone)
    }
  }
}

fn fence_original(
  config: Config,
  original: journal.Input,
) -> Result(journal.PreparationFence, Error) {
  use fenced <- result.try(
    journal.fence_preparation(config.resources, original)
    |> result.map_error(Custody),
  )
  let associated = journal.inspect_native(config.resources, original)
  use Nil <- result.try(follow_native(config, associated))
  Ok(fenced)
}

fn follow_native(
  config: Config,
  associated: Result(journal.NativeStatus, journal.Error),
) -> Result(Nil, Error) {
  case associated {
    Ok(journal.Unassociated) | Error(journal.Missing) -> Ok(Nil)
    Error(error) -> Error(Custody(error))
    Ok(journal.Associated(ref, key, digest, _)) -> {
      use context <- result.try(
        native.command_context(config.native, config.resources, ref)
        |> result.replace_error(Uncertain),
      )
      let configured = native.configuration(config.native)
      let envelope =
        wire.Envelope(
          wire.Owner,
          configured.owner,
          configured.executor,
          configured.generation,
          configured.scope,
          wire.Cancel(key, digest),
        )
      use envelope <- result.try(
        wire.command_envelope(ref, envelope) |> result.replace_error(Uncertain),
      )
      native.exchange_command(config.native, context, envelope)
      |> result.replace(Nil)
      |> result.replace_error(Uncertain)
    }
  }
}

fn stop_entry(state: State, key: command.ServiceKey) -> State {
  case dict.get(state.active, key) {
    Error(Nil) -> state
    Ok(active) ->
      State(
        ..state,
        active: dict.insert(
          state.active,
          key,
          Active(..active, phase: Stopping(phase_claim(active.phase))),
        ),
      )
  }
}

fn fenced_entry(state: State, key: command.ServiceKey) -> State {
  case dict.get(state.active, key) {
    Error(Nil) -> state
    Ok(active) -> {
      let active = Active(..active, phase: Stopped(phase_claim(active.phase)))
      case active.result, active.drain {
        Some(Error(Closing)), Delivered ->
          State(..state, active: dict.delete(state.active, key))
        _, _ -> State(..state, active: dict.insert(state.active, key, active))
      }
    }
  }
}

fn fence_service(state: State) -> State {
  case state.gate {
    Serving -> {
      let next = State(..state, gate: Fenced, tickets: [])
      let next =
        dict.keys(next.active)
        |> list.fold(next, fn(next, key) { stop_entry(next, key) })
      let originals =
        dict.values(next.active) |> list.map(fn(active) { active.original })

      // Endpoint/ask loss closes the same durable authority as orderly closure.
      // This exclusive barrier remains available even when metadata slots are held.
      start_control(next, Barrier(originals), NoReply)
    }
    Fenced | Joining(_, _) -> state
  }
}

fn reported(
  state: State,
  key: command.ServiceKey,
  report: weft.Pulled(Reply, Error),
) -> State {
  case dict.get(state.active, key) {
    Error(Nil) -> state
    Ok(active) ->
      case active.original_run {
        None -> record_report(state, key, active, report)
        Some(_) -> original_active_report(state, key, active, report)
      }
  }
}

fn record_report(
  state: State,
  key: command.ServiceKey,
  active: Active,
  report: weft.Pulled(Reply, Error),
) -> State {
  case report {
    weft.NotYet -> state
    weft.PulledOutcome(outcome) -> {
      let result = whole_outcome(outcome)
      send_whole(active.reply, result)
      let active = Active(..active, reply: None, result: Some(result))
      let next = State(..state, active: dict.insert(state.active, key, active))
      case result {
        Ok(_) -> next
        Error(Closing) | Error(Invalid) -> next
        Error(_) ->
          launch_control(fence_service(next), Fence(active.original), NoReply)
      }
    }
    weft.AllDelivered -> finish_active(state, key, active)
    weft.RunLost(_) -> {
      send_whole(active.reply, Error(Uncertain))
      let active = Active(..active, reply: None, drain: Lost)
      let next =
        State(
          ..state,
          active: dict.insert(state.active, key, active),
          selector: process.deselect(state.selector, active.reports),
        )
      launch_control(fence_service(next), Fence(active.original), NoReply)
    }
  }
}

fn whole_outcome(outcome: weft.Outcome(Reply, Error)) -> Result(Reply, Error) {
  case outcome {
    weft.Completed(_, value) -> Ok(value)
    weft.Failed(_, error) -> Error(error)
    weft.Abandoned(_) | weft.NeverStarted(_) -> Error(Closing)
    weft.Crashed(_, _)
    | weft.DrainProofLost(_, _)
    | weft.CancellationUnconfirmed(_) -> Error(Uncertain)
  }
}

fn finish_active(
  state: State,
  key: command.ServiceKey,
  active: Active,
) -> State {
  weft.cancel(active.cancel)
  let next =
    State(..state, selector: process.deselect(state.selector, active.reports))
  case active.result, active.phase {
    Some(Ok(_)), _
    | Some(Error(Invalid)), _
    | Some(Error(Closing)), Stopped(_)
    -> State(..next, active: dict.delete(state.active, key))
    Some(Error(Closing)), Stopping(_) ->
      State(
        ..next,
        active: dict.insert(
          state.active,
          key,
          Active(..active, drain: Delivered),
        ),
      )
    None, _ | Some(Error(_)), _ ->
      fence_service(
        State(
          ..next,
          active: dict.insert(
            state.active,
            key,
            Active(..active, drain: Delivered),
          ),
        ),
      )
  }
}

fn control_reported(
  state: State,
  id: Int,
  report: weft.Pulled(ControlAnswer, Error),
) -> State {
  case dict.get(state.metadata, id) {
    Error(Nil) -> state
    Ok(metadata) ->
      case metadata.original_run {
        None -> record_control(state, id, metadata, report)
        Some(_) -> original_control_report(state, id, metadata, report)
      }
  }
}

fn record_control(
  state: State,
  id: Int,
  metadata: Metadata,
  report: weft.Pulled(ControlAnswer, Error),
) -> State {
  case report {
    weft.NotYet -> state
    weft.PulledOutcome(outcome) -> {
      let result = control_outcome(outcome)
      send_control(metadata.reply, result)
      let next =
        State(
          ..state,
          metadata: dict.insert(
            state.metadata,
            id,
            Metadata(..metadata, reply: NoReply, result: Some(result)),
          ),
        )
      control_result(next, metadata.task, result)
    }
    weft.AllDelivered -> {
      weft.cancel(metadata.cancel)
      let next =
        State(
          ..state,
          selector: process.deselect(state.selector, metadata.reports),
        )

      // A definite refusal and successful answer discharge the same drained
      // metadata custody. Uncertainty or a missing outcome retains the slot.
      let definite = case metadata.result {
        Some(result) -> control_definite(metadata.task, result)
        None -> False
      }
      case definite {
        True -> State(..next, metadata: dict.delete(state.metadata, id))
        False ->
          fence_service(
            State(
              ..next,
              metadata: dict.insert(
                state.metadata,
                id,
                Metadata(..metadata, drain: Delivered),
              ),
            ),
          )
      }
    }
    weft.RunLost(_) -> {
      send_control(metadata.reply, Error(Uncertain))
      let next =
        State(
          ..state,
          metadata: dict.insert(
            state.metadata,
            id,
            Metadata(..metadata, reply: NoReply, drain: Lost),
          ),
          selector: process.deselect(state.selector, metadata.reports),
        )
      control_result(fence_service(next), metadata.task, Error(Uncertain))
    }
  }
}

fn control_outcome(
  outcome: weft.Outcome(ControlAnswer, Error),
) -> Result(ControlAnswer, Error) {
  case outcome {
    weft.Completed(_, value) -> Ok(value)
    weft.Failed(_, error) -> Error(error)
    weft.Crashed(_, _)
    | weft.Abandoned(_)
    | weft.NeverStarted(_)
    | weft.DrainProofLost(_, _)
    | weft.CancellationUnconfirmed(_) -> Error(Uncertain)
  }
}

fn control_result(
  state: State,
  task: Control,
  result: Result(ControlAnswer, Error),
) -> State {
  case task, result {
    Fence(original), _ -> {
      // Cancellation follows the fence attempt, including ambiguous replies.
      // A lost ask still fences admission and cannot restore the original slot.
      let next = case result {
        Ok(_) -> fenced_entry(state, original.key)
        Error(_) -> fence_service(state)
      }
      cancel_entry(next, original.key)
      next
    }
    Barrier(_), outcome -> {
      let state = case outcome {
        Ok(_) -> dict.keys(state.active) |> list.fold(state, fenced_entry)
        Error(_) -> state
      }
      cancel_all(state)
      case state.gate {
        Joining(reply, _) ->
          State(
            ..state,
            gate: Joining(reply, Some(outcome |> result.replace(Nil))),
          )
        Serving | Fenced -> fence_service(state)
      }
    }
    ReleasePreparations(..), outcome -> {
      case state.original_close {
        ReleasingOriginal(proof, reply, _) -> {
          let result = case outcome {
            Ok(ResourcesReleased(digests)) -> Ok(digests)
            Ok(_) -> Error(Uncertain)
            Error(error) -> Error(error)
          }
          State(
            ..state,
            original_close: ReleasingOriginal(proof, reply, Some(result)),
          )
        }
        _ -> state
      }
    }
    Read(_, _), outcome | Route(_, _), outcome ->
      case control_definite(task, outcome) {
        True -> state
        False -> fence_service(state)
      }
  }
}

// Only historical absence or identity refusal proves a definite metadata error.
// Fence and close errors may conceal a commit and retain unresolved custody.

fn control_definite(
  task: Control,
  outcome: Result(ControlAnswer, Error),
) -> Bool {
  case task, outcome {
    _, Ok(_) -> True
    Read(_, _), Error(Custody(journal.Missing))
    | Read(_, _), Error(Custody(journal.Conflict))
    | Route(_, _), Error(Invalid)
    -> True
    _, Error(_) -> False
  }
}

fn send_whole(
  reply: Option(process.Subject(Result(Reply, Error))),
  value: Result(Reply, Error),
) -> Nil {
  case reply {
    Some(reply) -> process.send(reply, value)
    None -> Nil
  }
}

fn send_control(
  reply: ControlReply,
  value: Result(ControlAnswer, Error),
) -> Nil {
  case reply, value {
    Whole(reply), Ok(Answer(value)) -> process.send(reply, Ok(value))
    Whole(reply), Error(error) -> process.send(reply, Error(error))
    Whole(reply), Ok(Forwarded)
    | Whole(reply), Ok(BarrierDone)
    | Whole(reply), Ok(ResourcesReleased(_))
    -> process.send(reply, Error(Uncertain))
    Native(reply), Error(Capacity) ->
      process.send(reply, Error(native.Capacity))
    Native(reply), Error(Invalid) -> process.send(reply, Error(native.Invalid))
    Native(reply), Error(_) -> process.send(reply, Error(native.Uncertain))
    Native(_), Ok(_) | NoReply, _ -> Nil
  }
}

fn begin_close(
  state: State,
  reply: process.Subject(Result(Nil, Error)),
) -> State {
  case state.gate {
    Joining(_, _) -> {
      process.send(reply, Error(Closing))
      state
    }
    Serving | Fenced -> {
      let state = State(..state, gate: Joining(reply, None), tickets: [])
      let originals =
        dict.values(state.active) |> list.map(fn(active) { active.original })

      // The exclusive close barrier is independent of occupied metadata slots.
      // Its seal precedes fences and managed cancellation; journals stay retained.
      let barrier =
        list.find(dict.values(state.metadata), fn(metadata) {
          case metadata.task {
            Barrier(_) -> True
            Read(_, _) | Fence(_) | Route(_, _) | ReleasePreparations(..) ->
              False
          }
        })
      case barrier {
        Error(Nil) -> start_control(state, Barrier(originals), NoReply)
        Ok(metadata) ->
          case metadata.result, metadata.drain {
            Some(outcome), _ ->
              State(
                ..state,
                gate: Joining(reply, Some(outcome |> result.replace(Nil))),
              )
            None, Lost ->
              State(..state, gate: Joining(reply, Some(Error(Uncertain))))
            None, Awaiting | None, Delivered -> state
          }
      }
    }
  }
}

fn continue_or_close(state: State) -> actor.Next(State, Message) {
  let drained =
    list.all(dict.values(state.active), fn(active) { active.drain != Awaiting })
    && list.all(dict.values(state.metadata), fn(metadata) {
      metadata.drain != Awaiting
    })
  case state.gate, drained {
    Joining(reply, Some(outcome)), True -> {
      let lost = dict.size(state.active) > 0 || dict.size(state.metadata) > 0
      case state.custody {
        LegacyCustody -> {
          process.send(reply, case lost {
            True -> Error(Uncertain)
            False -> outcome
          })
          actor.stop()
        }
        OriginalCustody ->
          finish_original_close(state, case lost {
            True -> Error(Uncertain)
            False -> outcome
          })
      }
    }
    Serving, _ | Fenced, _ | Joining(_, _), _ ->
      continue_original_release(state)
  }
}

fn cancel_entry(state: State, key: command.ServiceKey) -> Nil {
  case dict.get(state.active, key) {
    Ok(active) -> weft.cancel(active.cancel)
    Error(Nil) -> Nil
  }
}

fn cancel_all(state: State) -> Nil {
  dict.values(state.active)
  |> list.each(fn(active) { weft.cancel(active.cancel) })
  dict.values(state.metadata)
  |> list.each(fn(metadata) { weft.cancel(metadata.cancel) })
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  // A trapping normal shutdown can attempt a seal, but an untrappable kill
  // cannot promise any durable write. Temporary supervision never restarts work.
  let _ = journal.seal(state.config.resources)
  cancel_all(state)
}

// The executor reads its own committed predecessor evidence before preparation.
// An owner assertion cannot replace the retained terminal or its native facts.
fn admit_attempt(
  config: Config,
  key: command.ServiceKey,
  decoded: input.CompileInput,
) -> Result(input.AdmittedCompile, input.InputError) {
  case command.compile_predecessor(key) {
    None -> input.admit_compile(key, config.contract, decoded)
    Some(previous) -> {
      use original <- result.try(
        journal.retained_input(config.resources, previous)
        |> result.replace_error(input.AssociationMismatch),
      )
      use original_input <- result.try(input.decode_compile(original.body))
      use retained <- result.try(
        journal.inspect_compile(config.resources, original)
        |> result.replace_error(input.AssociationMismatch),
      )
      use completed <- result.try(case retained {
        journal.CompileRetained(value, _) ->
          Ok(journal.retained_compile_value(value))
        journal.CompilePending -> Error(input.AssociationMismatch)
      })
      use failure <- result.try(case completion.compiled(completed).result {
        Error(error) -> Ok(error)
        Ok(_) -> Error(input.AssociationMismatch)
      })
      input.admit_rewrite(
        key,
        config.contract,
        decoded,
        previous,
        original_input,
        failure,
      )
    }
  }
}

// Preserve weft's original caller link while making finite scope failures
// observable. Actual parent/other-link loss still shuts this permanent actor.
fn linked_exit(
  state: State,
  exit: process.ExitMessage,
) -> actor.Next(State, Message) {
  let original_scope =
    list.any(dict.values(state.active), fn(active) {
      case active.original_run {
        Some(run) -> weft.scope_pid(run.detached) == exit.pid
        None -> False
      }
    })
    || list.any(dict.values(state.metadata), fn(metadata) {
      case metadata.original_run {
        Some(run) -> weft.scope_pid(run.detached) == exit.pid
        None -> False
      }
    })
  case exit.pid == state.parent, original_scope, exit.reason {
    True, _, process.Normal -> actor.stop()
    True, _, reason -> actor.stop_abnormal(string.inspect(reason))
    False, True, process.Normal ->
      actor.continue(state) |> actor.with_selector(state.selector)
    False, True, process.Killed | False, True, process.Abnormal(_) ->
      actor.continue(fence_service(state))
      |> actor.with_selector(state.selector)
    False, False, process.Normal ->
      actor.continue(state) |> actor.with_selector(state.selector)
    False, False, reason -> actor.stop_abnormal(string.inspect(reason))
  }
}

// Original runs are held by this actor, so their outbox never belongs to a relay.
// Work remains parked until the acquired run/monitor state has been installed.
fn launch_original(
  state: State,
  original: journal.Input,
  deadline: Int,
  reply: process.Subject(Result(Reply, Error)),
) -> State {
  let config = state.config
  let subject = state.subject
  let cancel = weft.cancel_signal()
  let wait = deadline - native.configuration(config.native).now()
  let parent = process.self()

  // The task creates its own receiving door; early offers queue until custody exists.
  let detached =
    weft.new_prepared([
      weft.managed(fn(_ledger) {
        let permit = process.new_subject()
        process.send(subject, ActivePermit(original.key, permit))
        use Nil <- result.try(
          process.receive(permit, wait) |> result.replace_error(Closing),
        )
        perform(config, subject, original, deadline)
      }),
    ])
    |> weft.deadline(wait)
    |> weft.cancel_grace(1000)
    |> weft.cancel_with(cancel)
    |> weft.cancel_when_exits(parent)
    |> weft.start_detached

  // The original scope monitor precedes installed state and the worker offer.
  // Retaining its link preserves weft's caller-death Gone/drain transition.
  let watch = process.monitor(weft.scope_pid(detached))
  let run = ActiveRun(detached, watch, AwaitingDown, Awaiting, AwaitingPermit)
  let active =
    Active(
      original,
      deadline,
      Admitting,
      cancel,
      process.new_subject(),
      Some(reply),
      None,
      Awaiting,
      Some(run),
    )
  State(
    ..state,
    active: dict.insert(state.active, original.key, active),
    selector: process.select_specific_monitor(state.selector, watch, ActiveDown(
      original.key,
      _,
    )),
  )
}

fn start_control_original(
  state: State,
  task: Control,
  reply: ControlReply,
) -> State {
  let config = state.config
  let cancel = weft.cancel_signal()
  let parent = process.self()
  let subject = state.subject
  let id = state.serial
  let started = native.configuration(config.native).now()
  let wait = case task {
    ReleasePreparations(_, _, deadline) -> int.min(30_000, deadline - started)
    _ -> 30_000
  }

  // Metadata retains its own concrete result type and unchanged original allowance.
  let detached =
    weft.new_prepared([
      weft.managed(fn(_ledger) {
        let permit = process.new_subject()
        process.send(subject, ControlPermit(id, permit))
        use Nil <- result.try(
          process.receive(permit, wait) |> result.replace_error(Uncertain),
        )
        control(config, task)
      }),
    ])
    |> weft.deadline(wait)
    |> weft.cancel_grace(1000)
    |> weft.cancel_with(cancel)
    |> weft.cancel_when_exits(parent)
    |> weft.start_detached

  // The original scope monitor precedes installed state and the worker offer.
  // Retaining its link preserves weft's caller-death Gone/drain transition.
  let watch = process.monitor(weft.scope_pid(detached))
  let run =
    ControlRun(
      started + wait,
      detached,
      watch,
      AwaitingDown,
      Awaiting,
      AwaitingPermit,
    )
  let metadata =
    Metadata(
      task,
      reply,
      cancel,
      process.new_subject(),
      None,
      Awaiting,
      Some(run),
    )
  State(
    ..state,
    serial: state.serial + 1,
    metadata: dict.insert(state.metadata, state.serial, metadata),
    selector: process.select_specific_monitor(
      state.selector,
      watch,
      ControlDown(state.serial, _),
    ),
  )
}

// Worker-owned subjects are offered only to the exact already-installed entry.
// Custody or deadline loss cancels the parked worker without granting effects.
fn offer_active_permit(
  state: State,
  key: command.ServiceKey,
  permit: process.Subject(Nil),
) -> State {
  case dict.get(state.active, key) {
    Ok(Active(original_run: Some(run), ..) as active)
      if run.permit == AwaitingPermit
    -> {
      case
        state.gate,
        active.deadline > native.configuration(state.config.native).now()
      {
        Serving, True ->
          State(
            ..state,
            active: dict.insert(
              state.active,
              key,
              Active(
                ..active,
                original_run: Some(
                  ActiveRun(..run, permit: OfferedPermit(permit)),
                ),
              ),
            ),
          )
        _, _ -> {
          weft.cancel(active.cancel)
          state
        }
      }
    }
    _ -> state
  }
}

fn offer_control_permit(
  state: State,
  id: Int,
  permit: process.Subject(Nil),
) -> State {
  case dict.get(state.metadata, id) {
    Ok(Metadata(original_run: Some(run), ..) as metadata)
      if run.permit == AwaitingPermit
    -> {
      case run.deadline > native.configuration(state.config.native).now() {
        True ->
          State(
            ..state,
            metadata: dict.insert(
              state.metadata,
              id,
              Metadata(
                ..metadata,
                original_run: Some(
                  ControlRun(..run, permit: OfferedPermit(permit)),
                ),
              ),
            ),
          )
        False -> {
          weft.cancel(metadata.cancel)
          state
        }
      }
    }
    _ -> state
  }
}

fn grant_runs(state: State) -> State {
  let active =
    dict.map_values(state.active, fn(_, active) {
      case active.original_run {
        Some(ActiveRun(permit: OfferedPermit(permit), ..) as run) -> {
          case preparation.observes(state.probe, preparation.RunPermit) {
            True ->
              preparation.notify(
                state.probe,
                preparation.BeforeRunPermit(
                  preparation.ActiveRun,
                  weft.scope_pid(run.detached),
                  permit,
                ),
              )
            False -> process.send(permit, Nil)
          }
          Active(
            ..active,
            original_run: Some(ActiveRun(..run, permit: GrantedPermit)),
          )
        }
        _ -> active
      }
    })
  let metadata =
    dict.map_values(state.metadata, fn(_, metadata) {
      case metadata.original_run {
        Some(ControlRun(permit: OfferedPermit(permit), ..) as run) -> {
          case preparation.observes(state.probe, preparation.RunPermit) {
            True ->
              preparation.notify(
                state.probe,
                preparation.BeforeRunPermit(
                  preparation.ControlRun,
                  weft.scope_pid(run.detached),
                  permit,
                ),
              )
            False -> process.send(permit, Nil)
          }
          Metadata(
            ..metadata,
            original_run: Some(ControlRun(..run, permit: GrantedPermit)),
          )
        }
        _ -> metadata
      }
    })
  State(..state, active:, metadata:)
}

// The Begin response follows installed permanent ownership and the original
// Claim. A held test permit rechecks admission when finally received.
fn grant_begin(state: State) -> State {
  case state.pending_begin {
    None -> state
    Some(#(key, claim, reply)) -> {
      let state = State(..state, pending_begin: None)
      case
        preparation.observes(state.probe, preparation.BeginPermit),
        dict.get(state.preparations, key)
      {
        True, Ok(owner) -> {
          let permit = process.new_subject()
          preparation.notify(
            state.probe,
            preparation.BeforeBeginPermit(preparation.pid(owner), permit),
          )
          State(
            ..state,
            selector: process.select_map(state.selector, permit, fn(_) {
              ReleaseBegin(key, claim, reply, permit)
            }),
          )
        }
        _, _ -> grant_begin_actual(state, key, claim, reply)
      }
    }
  }
}

fn grant_begin_actual(
  state: State,
  key: command.ServiceKey,
  claim: journal.Claim,
  reply: process.Subject(StartDecision),
) -> State {
  let granted = {
    use active <- result.try(dict.get(state.active, key))
    use owner <- result.try(dict.get(state.preparations, key))
    case state.gate, active.phase {
      Serving, Preparing(saved) ->
        case
          journal.original(saved) == journal.original(claim)
          && active.deadline > native.configuration(state.config.native).now()
        {
          True -> Ok(owner)
          False -> Error(Nil)
        }
      _, _ -> Error(Nil)
    }
  }
  process.send(reply, case granted {
    Ok(owner) -> BeginOwnedPreparation(owner)
    Error(Nil) -> DoNotBegin
  })
  state
}

fn pull_original_runs(state: State) -> State {
  let state =
    list.fold(dict.keys(state.active), state, fn(state, key) {
      case dict.get(state.active, key) {
        Ok(Active(original_run: Some(run), ..)) if run.delivery == Awaiting ->
          reported(state, key, weft.pull(run.detached, within: 0))
        _ -> state
      }
    })
  let state =
    list.fold(dict.keys(state.metadata), state, fn(state, id) {
      case dict.get(state.metadata, id) {
        Ok(Metadata(original_run: Some(run), ..)) if run.delivery == Awaiting ->
          control_reported(state, id, weft.pull(run.detached, within: 0))
        _ -> state
      }
    })
  expire_original_close(state)
}

fn original_active_report(
  state: State,
  key: command.ServiceKey,
  active: Active,
  report: weft.Pulled(Reply, Error),
) -> State {
  case active.original_run {
    None -> state
    Some(run) -> {
      case report {
        weft.PulledOutcome(_) -> {
          let state = record_report(state, key, active, report)
          finish_active_original(state, key)
        }
        weft.AllDelivered -> {
          let active =
            Active(
              ..active,
              original_run: Some(ActiveRun(..run, delivery: Delivered)),
            )
          finish_active_original(
            State(..state, active: dict.insert(state.active, key, active)),
            key,
          )
        }
        weft.RunLost(_) ->
          record_report(
            state,
            key,
            Active(
              ..active,
              original_run: Some(ActiveRun(..run, delivery: Lost)),
            ),
            report,
          )
        weft.NotYet -> state
      }
    }
  }
}

fn active_down(
  state: State,
  key: command.ServiceKey,
  down: process.Down,
) -> State {
  case dict.get(state.active, key) {
    Ok(Active(original_run: Some(run), ..) as active) -> {
      let proof = original_down(down)
      let active =
        Active(..active, original_run: Some(ActiveRun(..run, down: proof)))
      let state = State(..state, active: dict.insert(state.active, key, active))
      case proof {
        NormalDown -> finish_active_original(state, key)
        AwaitingDown | LostDown ->
          record_report(state, key, active, weft.RunLost(process.Killed))
      }
    }
    _ -> state
  }
}

fn finish_active_original(state: State, key: command.ServiceKey) -> State {
  case dict.get(state.active, key) {
    Ok(Active(result: Some(_), original_run: Some(run), ..) as active)
      if run.delivery == Delivered && run.down == NormalDown
    -> {
      process.demonitor_process(run.watch)
      let state =
        joined_account(
          state,
          weft.scope_pid(run.detached),
          json.to_string(command.encode_service(key)),
        )
      let state =
        State(
          ..state,
          selector: process.deselect_specific_monitor(state.selector, run.watch),
        )
      finish_active(state, key, active)
    }
    _ -> state
  }
}

fn original_control_report(
  state: State,
  id: Int,
  metadata: Metadata,
  report: weft.Pulled(ControlAnswer, Error),
) -> State {
  case metadata.original_run {
    None -> state
    Some(run) ->
      case report {
        weft.PulledOutcome(_) -> {
          let state = record_control(state, id, metadata, report)
          finish_control_original(state, id)
        }
        weft.AllDelivered -> {
          let metadata =
            Metadata(
              ..metadata,
              original_run: Some(ControlRun(..run, delivery: Delivered)),
            )
          finish_control_original(
            State(..state, metadata: dict.insert(state.metadata, id, metadata)),
            id,
          )
        }
        weft.RunLost(_) ->
          record_control(
            state,
            id,
            Metadata(
              ..metadata,
              original_run: Some(ControlRun(..run, delivery: Lost)),
            ),
            report,
          )
        weft.NotYet -> state
      }
  }
}

fn control_down(state: State, id: Int, down: process.Down) -> State {
  case dict.get(state.metadata, id) {
    Ok(Metadata(original_run: Some(run), ..) as metadata) -> {
      let proof = original_down(down)
      let metadata =
        Metadata(..metadata, original_run: Some(ControlRun(..run, down: proof)))
      let state =
        State(..state, metadata: dict.insert(state.metadata, id, metadata))
      case proof {
        NormalDown -> finish_control_original(state, id)
        AwaitingDown | LostDown ->
          record_control(state, id, metadata, weft.RunLost(process.Killed))
      }
    }
    _ -> state
  }
}

fn finish_control_original(state: State, id: Int) -> State {
  case dict.get(state.metadata, id) {
    Ok(Metadata(result: Some(_), original_run: Some(run), ..) as metadata)
      if run.delivery == Delivered && run.down == NormalDown
    -> {
      process.demonitor_process(run.watch)
      let state =
        joined_account(
          state,
          weft.scope_pid(run.detached),
          "metadata/" <> int.to_string(id),
        )
      let state =
        State(
          ..state,
          selector: process.deselect_specific_monitor(state.selector, run.watch),
        )
      record_control(state, id, metadata, weft.AllDelivered)
    }
    _ -> state
  }
}

fn original_down(down: process.Down) -> OriginalDown {
  case down {
    process.ProcessDown(reason: process.Normal, ..) -> NormalDown
    process.ProcessDown(..) | process.PortDown(..) -> LostDown
  }
}

fn joined_account(state: State, pid: process.Pid, label: String) -> State {
  case
    mp.encode(
      mp.ArrayValue([
        mp.StringValue("loom.compile.original-run/1"),
        mp.BinaryValue(state.account),
        mp.StringValue(string.inspect(pid)),
        mp.StringValue(label),
        mp.StringValue("outcome-delivered-original-normal"),
      ]),
    )
  {
    Ok(bytes) -> State(..state, account: crypto.hash(crypto.Sha256, bytes))
    Error(_) -> State(..fence_service(state), original_close: LostOriginal)
  }
}

fn preparation_error(error: preparation.Error) -> Error {
  case error {
    preparation.Invalid -> Invalid
    preparation.Expired -> Expired
    preparation.Uncertain -> Uncertain
    preparation.Preparation(error) -> Preparation(error)
    preparation.Custody(error) -> Custody(error)
  }
}

fn begin_original_close(
  state: State,
  reply: process.Subject(Result(CompileCloseProof, Error)),
) -> State {
  case state.custody, state.original_close {
    OriginalCustody, NotClosing -> {
      let deadline = native.configuration(state.config.native).now() + 35_000
      begin_close(
        State(..state, original_close: JoiningOriginal(deadline, reply)),
        process.new_subject(),
      )
    }
    _, _ -> {
      process.send(reply, Error(Closing))
      state
    }
  }
}

fn finish_original_close(
  state: State,
  outcome: Result(Nil, Error),
) -> actor.Next(State, Message) {
  case state.original_close {
    JoiningOriginal(deadline, reply) -> {
      let proof = {
        use Nil <- result.try(outcome)
        use digest <- result.try(
          close_digest(state, "loom.compile.original-close/1", []),
        )
        Ok(CompileCloseProof(
          state.subject,
          process.self(),
          native.pid(state.config.native),
          journal.pid(state.config.resources),
          state.config.scope,
          deadline,
          digest,
        ))
      }
      process.send(reply, proof)
      let closed = case proof {
        Ok(proof) -> AwaitingOriginalResources(proof)
        Error(_) -> LostOriginal
      }
      actor.continue(State(..state, gate: Fenced, original_close: closed))
      |> actor.with_selector(state.selector)
    }
    _ -> actor.continue(state) |> actor.with_selector(state.selector)
  }
}

fn begin_release_preparations(
  state: State,
  proof: native.ScopeCloseProof,
  reply: process.Subject(Result(CompileResourcesProof, Error)),
) -> State {
  case state.original_close {
    AwaitingOriginalResources(closed) -> {
      let allowed = {
        use _ <- result.try(
          native.validate_scope_close(state.config.native, proof)
          |> result.replace_error(Invalid),
        )
        case native.configuration(state.config.native).now() < closed.deadline {
          True -> Ok(Nil)
          False -> Error(Expired)
        }
      }
      case allowed {
        Ok(Nil) ->
          start_control(
            State(
              ..state,
              original_close: ReleasingOriginal(closed, reply, None),
            ),
            ReleasePreparations(
              proof,
              dict.values(state.preparations),
              closed.deadline,
            ),
            NoReply,
          )
        Error(error) -> {
          process.send(reply, Error(error))
          state
        }
      }
    }
    _ -> {
      process.send(reply, Error(Closing))
      state
    }
  }
}

fn continue_original_release(state: State) -> actor.Next(State, Message) {
  let size = dict.size(state.metadata)
  case state.original_close {
    ReleasingOriginal(closed, reply, Some(result)) if size == 0 -> {
      let resources = {
        use digests <- result.try(result)
        use digest <- result.try(close_digest(
          state,
          "loom.compile.original-resources/1",
          digests,
        ))
        Ok(CompileResourcesProof(closed, digest))
      }
      process.send(reply, resources)
      case resources {
        Ok(_) -> actor.stop()
        Error(_) ->
          actor.continue(State(..state, original_close: LostOriginal))
          |> actor.with_selector(state.selector)
      }
    }
    _ -> actor.continue(state) |> actor.with_selector(state.selector)
  }
}

fn close_digest(
  state: State,
  domain: String,
  digests: List(generation.Digest),
) -> Result(generation.Digest, Error) {
  let config = native.configuration(state.config.native)
  let #(session, workspace, executor, session_epoch, workspace_epoch) =
    identity.scope_fields(config.scope)
  let values =
    list.map(digests, fn(digest) {
      bit_array.base16_encode(generation.digest_bytes(digest))
    })
    |> list.sort(string.compare)
    |> list.map(mp.StringValue)
  use bytes <- result.try(
    mp.encode(
      mp.ArrayValue([
        mp.StringValue(domain),
        mp.StringValue(session),
        mp.StringValue(workspace),
        mp.StringValue(executor),
        mp.IntValue(session_epoch),
        mp.IntValue(workspace_epoch),
        mp.IntValue(config.generation),
        mp.StringValue(string.inspect(process.self())),
        mp.StringValue(string.inspect(native.pid(state.config.native))),
        mp.StringValue(string.inspect(journal.pid(state.config.resources))),
        mp.BinaryValue(state.account),
        mp.ArrayValue(values),
      ]),
    )
    |> result.replace_error(Uncertain),
  )
  crypto.hash(crypto.Sha256, bytes)
  |> generation.digest
  |> result.replace_error(Uncertain)
}

fn expire_original_close(state: State) -> State {
  let now = native.configuration(state.config.native).now()
  case state.original_close {
    JoiningOriginal(deadline, reply) if now >= deadline -> {
      process.send(reply, Error(Uncertain))
      cancel_all(state)
      State(..state, gate: Fenced, original_close: LostOriginal)
    }
    ReleasingOriginal(closed, reply, _) if now >= closed.deadline -> {
      process.send(reply, Error(Uncertain))
      cancel_all(state)
      State(..state, gate: Fenced, original_close: LostOriginal)
    }
    _ -> state
  }
}

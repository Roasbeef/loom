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
//// Exit alone stays NativeUnconfirmed. Launch retirement requires its exact
//// original helper witness and durable confirmation; scoped close additionally
//// fences the epoch and confirms the original pool drain.
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
//// `finish_confirmation` promotes only a fully drained original confirmation.
////
//// Registered ServerLease rows reuse this original actor and native journal.
//// `install_lsp_pending` atomically wins original first-placement custody;
//// `submit_lsp_pending` validates exact owner-cleared bytes before Request and
//// retains checked coverage before its first possibly committed write. One real
//// consumed sink precedes `begin_lsp` and actual AuthorizeLaunch. Managed native,
//// input and output tasks retain their original lifetime and actual drain proof.
//// `accept_lsp_started` calls `release_joined_lsp_output` after installing the
//// original handle; consumption and AllDelivered may already hold that ordinal.
//// `close_lsp_row` fences physical control before SQL, and `lsp_retired` retains
//// the independent original pool witness. Semantic and endpoint joins still own
//// lease retirement; no ServerProtocol row supplies finite reusable authority.
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
//// 7. `persist_retirements` commits exact Launch proof; `close_scope` drains scope.

import broker/dispatch
import broker/exec
import broker/executor as local
import broker/framing
import broker/internal/call
import broker/policy
import core/clock
import core/command
import core/ids
import core/lsp_command as lsp_id
import core/msgpack as mp
import core/workspace
import executor/remote/admission
import executor/remote/identity
import executor/remote/internal/lsp_native_plan as lsp_plan
import executor/remote/internal/lsp_output_join as output_join
import executor/remote/journal
import executor/remote/journal_codec
import executor/remote/lsp_journal as lsp_store
import executor/remote/lsp_wire
import executor/remote/native
import executor/remote/payload
import executor/remote/resource_journal
import executor/remote/wire
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor as otp_actor
import gleam/otp/supervision
import gleam/result
import lsp/internal/consumed_channel as consumed
import lsp/transport
import weft
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
    control_lost: Option(fn() -> Nil),
    associated: Option(fn() -> Nil),
    retired: Option(fn() -> Nil),
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
    retirement: ExecutionRetirement,
    control: ControlCustody,
    monitor: Option(process.Monitor),
    control_lost: Option(fn() -> Nil),
    confirmation: Confirmation,
  )
}

// These facts belong to the original native row, independently of its
// killable adapter. Positive proof survives only the fixed persistence window.
type ExecutionRetirement {
  ReuseNative
  AwaitingNative(retired: Option(fn() -> Nil))
  PositiveNative(retired: Option(fn() -> Nil))
  ConfirmedNative
  UncertainNative
}

// At most one bounded confirmation task belongs to each original native Row.
type ConfirmationAttempt {
  FirstConfirmation
  FinalConfirmation
}

type Confirmation {
  ConfirmationReady(attempt: ConfirmationAttempt)
  Confirming(
    reports: process.Subject(weft.Pulled(Nil, journal.Error)),
    cancel: weft.Cancel,
    outcome: Option(Result(Nil, journal.Error)),
    attempt: ConfirmationAttempt,
    relay: process.Pid,
  )
  ConfirmationSpent
  ConfirmationLost
}

type ControlCustody {
  RunningControl
  FinishedControl
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
    lsp_rows: Dict(String, LspRow),
  )
}

/// Original live startup context; retained rows cannot reconstruct this door.
@internal
pub opaque type PendingServerLease {
  /// Only the original Service creates this one-shot installation door.
  PendingServerLease(
    /// Original immutable Service subject, never a registry lookup.
    subject: process.Subject(Message),
    /// Exact lease address already checked by the original DAL.
    address: String,
    /// Original local installation identity, never recreated by readback.
    nonce: reference.Reference,
  )
}

/// Exact original local attachment, incapable of choosing a replacement row.
@internal
pub opaque type LspProtocolAttachment {
  /// The checked original row owns every callback and cleanup observation.
  LspProtocolAttachment(
    /// Original immutable Service subject, never a registry lookup.
    subject: process.Subject(Message),
    /// Exact lease address already checked by the original DAL.
    address: String,
    /// Original local installation identity, never recreated by readback.
    nonce: reference.Reference,
  )
}

/// Independent original cleanup observations; none grants lease retirement.
@internal
pub type LspCleanup {
  LspCleanup(
    /// Whether original input has been fenced.
    input: LspInputGate,
    /// Original managed continuations' actual drain disposition.
    drain: LspDrain,
    /// Exact bounded terminal/protocol witness, independent of native proof.
    terminal: Option(BitArray),
    /// Exact original native retirement callback, independent of terminal.
    native: LspRetirement,
  )
}

/// Original attachment input disposition.
@internal
pub type LspInputGate {
  /// Original admission and actual input credit remain live.
  LspOpen

  /// Closure is absorbing, even if a late original ACK arrives.
  LspClosed
}

/// Original managed drain observation.
@internal
pub type LspDrain {
  /// At least one original managed continuation has not delivered its drain.
  LspPendingDrain

  /// Every original continuation delivered actual AllDelivered.
  LspDrained

  /// Missing original managed proof cannot be renewed by a replacement task.
  LspUnknownDrain
}

/// Exact original helper retirement observation.
@internal
pub type LspRetirement {
  /// The exact original pool observer has not supplied its verdict.
  LspAwaitingNative

  /// Native exit, ForgetRetired and original normal DOWN supplied exact proof.
  LspPositiveNative

  /// Original proof failed or was lost; terminal and drain cannot replace it.
  LspUnknownNative
}

type LspPermission {
  LspPending
  LspConsumed
}

type LspBegin {
  LspNotBegun
  LspBegun
}

type LspNative {
  LspNative(
    key: identity.RequestKey,
    digest: identity.Digest,
    prepared: wire.Prepared,
    command: lsp_store.CommandReadback,
    claim: lsp_store.ServerLeaseClaim,
    sequence: Int,
    incarnation: Int,
  )
}

type LspTask {
  LspTask(
    reports: process.Subject(weft.Pulled(Nil, Nil)),
    cancel: weft.Cancel,
    outcome: Option(Result(Nil, Nil)),
    drain: LspDrain,
  )
}

type LspInput {
  LspInput(
    bytes: BitArray,
    ordinal: Int,
    ready: Option(process.Subject(Result(local.ProtocolExecution, Nil))),
    ack: Option(process.Subject(Result(Nil, Nil))),
    accepted: Option(Result(Nil, Nil)),
    reply: process.Subject(Result(Nil, Nil)),
    task: LspTask,
  )
}

type LspOutput {
  LspOutput(credit: output_join.Join, task: LspTask)
}

type LspRow {
  LspRow(
    store: lsp_store.Store,
    binding: lsp_store.Binding,
    lease: lsp_id.LspServiceKey,
    startup: lsp_store.LeaseStartupClaim,
    plan: lsp_plan.CheckedServerPlan,
    era: lsp_id.ClockEra,
    deadline: Int,
    nonce: reference.Reference,
    owner: process.Pid,
    monitor: process.Monitor,
    permission: LspPermission,
    begun: LspBegin,
    gate: LspInputGate,
    native: Option(LspNative),
    execution: Option(local.ProtocolExecution),
    sink: Option(consumed.Sink),
    events: process.Subject(exec.ProtocolEvent),
    start: Option(LspTask),
    input: Option(LspInput),
    output: Option(LspOutput),
    frames: Int,
    bytes: Int,
    last_input: Option(#(Int, BitArray)),
    output_ordinal: Int,
    terminal: Option(BitArray),
    retirement: LspRetirement,
    drain: LspDrain,
  )
}

type Message {
  InstallPendingLsp(
    lsp_store.Store,
    lsp_store.LeaseStartupClaim,
    lsp_plan.CheckedServerPlan,
    lsp_id.ClockEra,
    process.Pid,
    process.Subject(Result(PendingServerLease, Error)),
  )
  SubmitPendingLsp(
    PendingServerLease,
    identity.RequestKey,
    wire.Prepared,
    process.Subject(Result(LspProtocolAttachment, Error)),
  )
  InstallLspSink(
    LspProtocolAttachment,
    consumed.Sink,
    process.Subject(Result(Nil, Error)),
  )
  BeginLsp(String, reference.Reference)
  CloseLsp(String, reference.Reference)
  InspectLsp(LspProtocolAttachment, process.Subject(Result(LspCleanup, Error)))
  LspStarted(
    String,
    reference.Reference,
    Result(local.ProtocolExecution, local.ProtocolStartFailure),
  )
  LspEvent(String, exec.ProtocolEvent)
  LspReport(String, LspTaskKind, weft.Pulled(Nil, Nil))
  LspFeed(
    String,
    reference.Reference,
    BitArray,
    process.Subject(Result(Nil, Nil)),
  )
  LspInputReady(
    String,
    Int,
    process.Subject(Result(local.ProtocolExecution, Nil)),
    process.Subject(Result(Nil, Nil)),
  )
  LspRetired(
    String,
    reference.Reference,
    dispatch.ExecutionId,
    Result(Nil, exec.RetirementFailure),
  )
  Quiesce(reply: process.Subject(Nil))
  Shutdown(reply: process.Subject(Result(Nil, Error)))
  AdapterDown(process.Down)
  ControlDone(key: identity.RequestKey, digest: identity.Digest)
  OriginalNativeRetired(
    key: identity.RequestKey,
    digest: identity.Digest,
    result: Result(Nil, exec.RetirementFailure),
  )
  PersistRetirements
  ConfirmationReport(
    key: identity.RequestKey,
    digest: identity.Digest,
    report: weft.Pulled(Nil, journal.Error),
  )
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

type LspTaskKind {
  LspStartTask
  LspInputTask
  LspOutputTask
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
        dict.new(),
      ))
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(AdapterDown),
      )
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle)
  |> actor.trapping_exits(True)
  |> actor.periodic(every: 25, sending: PersistRetirements)
  |> actor.on_shutdown(stop_confirmations)
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
  Ok(CommandContext(
    resources,
    original,
    ref,
    Live(claim, compile_deadline_ms),
    None,
    None,
    None,
  ))
}

/// Binds the original Launch owner to durable exact-helper retirement.
/// Only a validated LaunchService/SatelliteCommand can register this callback;
/// its send-only notification does not grant native execution authority.
///
/// ## Examples
///
/// `live_launch_command_context(service, claim, ref, deadline, lost, associated, retired)` preserves the original door.
@internal
pub fn live_launch_command_context(
  service: Service,
  claim: resource_journal.Claim,
  ref: command.CommandRef,
  deadline_ms: Int,
  control_lost: fn() -> Nil,
  associated: fn() -> Nil,
  retired: fn() -> Nil,
) -> Result(CommandContext, Error) {
  use context <- result.try(live_command_context(
    service,
    claim,
    ref,
    deadline_ms,
  ))
  case command.service_role(context.original.key) {
    command.LaunchService ->
      Ok(
        CommandContext(
          ..context,
          control_lost: Some(control_lost),
          associated: Some(associated),
          retired: Some(retired),
        ),
      )
    command.CompileService -> Error(Invalid)
  }
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
  Ok(CommandContext(resources, original, ref, Historical, None, None, None))
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
  let physical_role = case command.service_role(original.key) {
    command.CompileService -> command.CompileCommand
    command.LaunchService -> command.SatelliteCommand
  }
  case
    original.key == command.service(ref)
    && command.command_ref(original.key, physical_role) == Ok(ref)
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

/// Installs original first-reservation custody in this one native service owner.
/// The trusted assembly supplies the era paired with Config.now. History and a
/// copied token cannot install another row or replace a lost original reply.
///
/// ## Examples
/// `install_pending_lsp(service, store, fresh_claim, checked_plan, original_era)`.
@internal
pub fn install_pending_lsp(
  service: Service,
  store: lsp_store.Store,
  claim: lsp_store.LeaseStartupClaim,
  plan: lsp_plan.CheckedServerPlan,
  era: lsp_id.ClockEra,
) -> Result(PendingServerLease, Error) {
  let reply = process.new_subject()
  process.send(
    service.subject,
    InstallPendingLsp(store, claim, plan, era, process.self(), reply),
  )
  process.receive(reply, 30_000) |> result.unwrap(Error(Uncertain))
}

/// Consumes original pending installation before attempting native admission.
/// This local door accepts only the exact original owner-cleared materialization;
/// the owner Broker route is supplied by later full-host assembly.
///
/// ## Examples
/// A lost reply cannot submit the original pending context again.
@internal
pub fn submit_pending_lsp(
  pending: PendingServerLease,
  key: identity.RequestKey,
  prepared: wire.Prepared,
) -> Result(LspProtocolAttachment, Error) {
  let reply = process.new_subject()
  process.send(pending.subject, SubmitPendingLsp(pending, key, prepared, reply))
  process.receive(reply, 30_000) |> result.unwrap(Error(Uncertain))
}

/// Installs one real consumed sink before beginning the original native command.
/// Writer admission and native output consumption stay separate local credits.
///
/// ## Examples
/// Starting a second client from a copied attachment cannot replace its sink.
@internal
pub fn lsp_transport(attachment: LspProtocolAttachment) -> transport.Transport {
  let subject = attachment.subject
  let address = attachment.address
  let nonce = attachment.nonce
  transport.ConsumedChannelTransport(fn(sink) {
    let reply = process.new_subject()
    process.send(
      subject,
      InstallLspSink(
        LspProtocolAttachment(subject, address, nonce),
        sink,
        reply,
      ),
    )
    use Nil <- result.try(
      process.receive(reply, 1000)
      |> result.unwrap(Error(Uncertain))
      |> result.replace_error("original LSP attachment refused"),
    )
    process.send(subject, BeginLsp(address, nonce))
    Ok(
      consumed.Session(
        fn(bytes) {
          let reply = process.new_subject()
          process.send(subject, LspFeed(address, nonce, bytes, reply))
          process.receive(reply, 30_000) |> result.unwrap(Error(Nil))
        },
        fn() { process.send(subject, CloseLsp(address, nonce)) },
      ),
    )
  })
}

/// Fences original input and requests cancellation without waiting for output.
///
/// ## Examples
/// A blocked output consumer cannot prevent original cancellation.
@internal
pub fn close_lsp(attachment: LspProtocolAttachment) -> Nil {
  process.send(
    attachment.subject,
    CloseLsp(attachment.address, attachment.nonce),
  )
}

/// Reads distinct original cleanup observations without granting slot release.
///
/// ## Examples
/// Terminal bytes and native proof remain separately observable after closure.
@internal
pub fn inspect_lsp_cleanup(
  attachment: LspProtocolAttachment,
) -> Result(LspCleanup, Error) {
  let reply = process.new_subject()
  process.send(attachment.subject, InspectLsp(attachment, reply))
  process.receive(reply, 1000) |> result.unwrap(Error(Uncertain))
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
    InstallPendingLsp(store, claim, plan, era, owner, reply) -> {
      let #(state, result) =
        install_lsp_pending(state, store, claim, plan, era, owner)
      process.send(reply, result)
      continue_retirements(state)
    }
    SubmitPendingLsp(pending, key, prepared, reply) -> {
      let #(state, result) = submit_lsp_pending(state, pending, key, prepared)
      process.send(reply, result)
      continue_retirements(state)
    }
    InstallLspSink(attachment, sink, reply) -> {
      let #(state, answer) = install_lsp_sink(state, attachment, sink)
      process.send(reply, answer)
      continue_retirements(state)
    }
    BeginLsp(address, nonce) ->
      continue_retirements(begin_lsp(state, address, nonce))
    CloseLsp(address, nonce) ->
      continue_retirements(close_lsp_row(state, address, nonce))
    InspectLsp(attachment, reply) -> {
      process.send(reply, inspect_lsp(state, attachment))
      actor.continue(state)
    }
    LspStarted(address, nonce, answer) ->
      continue_retirements(lsp_started(state, address, nonce, answer))
    LspEvent(address, event) ->
      continue_retirements(lsp_event(state, address, event))
    LspReport(address, kind, report) ->
      continue_retirements(lsp_report(state, address, kind, report))
    LspFeed(address, nonce, bytes, reply) ->
      continue_retirements(lsp_feed(state, address, nonce, bytes, reply))
    LspInputReady(address, ordinal, ready, ack) ->
      continue_retirements(lsp_input_ready(state, address, ordinal, ready, ack))
    LspRetired(address, nonce, execution, answer) ->
      continue_retirements(lsp_retired(state, address, nonce, execution, answer))
    Quiesce(reply) -> {
      let state = fence_all_lsp(State(..state, gate: Quiesced, tickets: []))
      process.send(reply, Nil)
      continue_retirements(state)
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
    AdapterDown(down) -> {
      let rows =
        list.fold(dict.to_list(state.rows), state.rows, fn(rows, pair) {
          let #(key, row) = pair
          case row.monitor == Some(down.monitor) {
            True -> {
              option.map(row.control_lost, fn(notify) { notify() })
              finish_control(rows, key, row)
            }
            False -> rows
          }
        })
      let state = State(..state, rows:)
      let state =
        list.fold(dict.to_list(state.lsp_rows), state, fn(state, pair) {
          case pair.1.monitor == down.monitor {
            True -> close_lsp_row(state, pair.0, pair.1.nonce)
            False -> state
          }
        })
      continue_retirements(state)
    }
    ControlDone(key, digest) -> {
      let rows = case dict.get(state.rows, key) {
        Ok(row) if row.digest == digest -> finish_control(state.rows, key, row)
        _ -> state.rows
      }
      continue_retirements(State(..state, rows:))
    }
    OriginalNativeRetired(key, digest, outcome) -> {
      let rows = case dict.get(state.rows, key) {
        Ok(Row(retirement: AwaitingNative(retired), ..) as row)
          if row.digest == digest
        -> {
          let retirement = case outcome {
            Ok(Nil) -> PositiveNative(retired)
            Error(_) -> UncertainNative
          }
          dict.insert(state.rows, key, Row(..row, retirement:))
        }
        _ -> state.rows
      }
      continue_retirements(State(..state, rows:))
    }
    PersistRetirements -> continue_retirements(state)
    ConfirmationReport(key, digest, report) ->
      continue_retirements(confirmation_report(state, key, digest, report))
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
  case launch(next, key, digest, prepared, deadline, route) {
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
        True -> {
          option.map(context.associated, fn(notify) { notify() })
          Ok(Nil)
        }
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
  route: Route,
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
      let native_config =
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
        )
      use running <- result.try(
        case route {
          Native -> native.start(native_config)
          Command(context) ->
            case command.service_role(context.original.key) {
              command.CompileService -> native.start(native_config)
              command.LaunchService ->
                native.start_launch(native_config, fn(outcome) {
                  process.send(
                    service_subject,
                    OriginalNativeRetired(key, digest, outcome),
                  )
                })
            }
        }
        |> result.map_error(fn(_) { Uncertain }),
      )
      let retirement = case route {
        Native -> ReuseNative
        Command(context) ->
          case command.service_role(context.original.key) {
            command.CompileService -> ReuseNative
            command.LaunchService -> AwaitingNative(context.retired)
          }
      }
      let monitor = case retirement {
        ReuseNative -> None
        AwaitingNative(_) -> Some(process.monitor(native.pid(running)))
        PositiveNative(_) | ConfirmedNative | UncertainNative -> None
      }
      let control_lost = case route {
        Native -> None
        Command(context) -> context.control_lost
      }
      let row =
        Row(
          digest,
          deadline,
          running,
          [],
          0,
          retirement,
          RunningControl,
          monitor,
          control_lost,
          ConfirmationReady(FirstConfirmation),
        )

      // This actor cannot consume callback messages before returning this Row.
      // Launch startup is parked, so a lost startup ACK cannot dispatch first.
      case retirement {
        AwaitingNative(_) -> native.begin_launch(running)
        ReuseNative | PositiveNative(_) | ConfirmedNative | UncertainNative ->
          Nil
      }
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

// Only the original pool callback creates PositiveNative. A journal failure
// retains that exact proof and callback, while retries consume observation grace.
// Actual control termination releases admission only after durable retirement.
// A killed adapter cannot send ControlDone, so the original row owns its monitor.
fn finish_control(
  rows: dict.Dict(identity.RequestKey, Row),
  key: identity.RequestKey,
  row: Row,
) -> dict.Dict(identity.RequestKey, Row) {
  option.map(row.monitor, process.demonitor_process)
  case row.retirement {
    ReuseNative | ConfirmedNative -> dict.delete(rows, key)
    AwaitingNative(_) | PositiveNative(_) | UncertainNative ->
      dict.insert(
        rows,
        key,
        Row(..row, control: FinishedControl, monitor: None),
      )
  }
}

fn persist_retirements(state: State) -> State {
  let now = state.config.now()
  list.fold(dict.to_list(state.rows), state, fn(state, pair) {
    let #(key, row) = pair
    case row.retirement, row.confirmation {
      PositiveNative(_), ConfirmationReady(attempt)
        if now < row.deadline + 6000
      -> {
        let reports = process.new_subject()
        let cancel = weft.cancel_signal()
        let book = state.config.journal
        let digest = row.digest
        let relay =
          weft.new_prepared([
            weft.managed(fn(_ledger) {
              journal.apply(book, key, digest, admission.ConfirmRetirement)
              |> result.replace(Nil)
            }),
          ])
          |> weft.deadline(row.deadline + 6000 - now)
          |> weft.cancel_grace(1000)
          |> weft.cancel_with(cancel)
          |> weft.cancel_when_exits(process.self())
          |> weft.start_relayed(to: reports)
        let row =
          Row(
            ..row,
            confirmation: Confirming(reports, cancel, None, attempt, relay),
          )
        State(..state, rows: dict.insert(state.rows, key, row))
      }
      _, _ -> state
    }
  })
}

// Reports retain the exact original proof through an uncertain acknowledgement.
// Only actual AllDelivered permits another ask, under the same fixed deadline.
fn confirmation_report(
  state: State,
  key: identity.RequestKey,
  digest: identity.Digest,
  report: weft.Pulled(Nil, journal.Error),
) -> State {
  case dict.get(state.rows, key) {
    Ok(
      Row(
        confirmation: Confirming(reports, cancel, outcome, attempt, relay),
        ..,
      ) as row,
    )
      if row.digest == digest
    -> {
      case report {
        weft.NotYet -> state
        weft.PulledOutcome(result) -> {
          let outcome = case result {
            weft.Completed(_, Nil) -> Ok(Nil)
            weft.Failed(_, error) -> Error(error)
            _ -> Error(journal.Uncertain)
          }
          let row =
            Row(
              ..row,
              confirmation: Confirming(
                reports,
                cancel,
                Some(outcome),
                attempt,
                relay,
              ),
            )
          State(..state, rows: dict.insert(state.rows, key, row))
        }
        weft.AllDelivered -> {
          weft.cancel(cancel)
          finish_confirmation(state, key, row, outcome, attempt)
        }
        weft.RunLost(_) -> {
          weft.cancel(cancel)
          State(
            ..state,
            rows: dict.insert(
              state.rows,
              key,
              Row(..row, confirmation: ConfirmationLost),
            ),
          )
        }
      }
    }
    _ -> state
  }
}

// Actual relay drain is the only entry to promotion or another bounded ask.
fn finish_confirmation(
  state: State,
  key: identity.RequestKey,
  row: Row,
  outcome: Option(Result(Nil, journal.Error)),
  attempt: ConfirmationAttempt,
) -> State {
  let now = state.config.now()
  case outcome, row.retirement {
    Some(Ok(Nil)), PositiveNative(retired) if now < row.deadline + 6000 -> {
      option.map(retired, fn(notify) { notify() })
      let rows = case row.control {
        FinishedControl -> dict.delete(state.rows, key)
        RunningControl ->
          dict.insert(
            state.rows,
            key,
            Row(
              ..row,
              retirement: ConfirmedNative,
              confirmation: ConfirmationSpent,
            ),
          )
      }
      State(..state, rows:)
    }
    _, _ -> {
      let confirmation = case attempt {
        FirstConfirmation -> ConfirmationReady(FinalConfirmation)
        FinalConfirmation -> ConfirmationSpent
      }
      State(
        ..state,
        rows: dict.insert(state.rows, key, Row(..row, confirmation:)),
      )
    }
  }
}

fn continue_retirements(state: State) -> actor.Next(State, Message) {
  let state = persist_retirements(state)
  let selector =
    list.fold(
      dict.to_list(state.rows),
      process.new_selector()
        |> process.select(state.subject)
        |> process.select_monitors(AdapterDown),
      fn(selector, pair) {
        let #(key, row) = pair
        case row.confirmation {
          Confirming(reports, _, _, _, _) ->
            process.select_map(selector, reports, ConfirmationReport(
              key,
              row.digest,
              _,
            ))
          ConfirmationReady(_) | ConfirmationSpent | ConfirmationLost ->
            selector
        }
      },
    )
  let selector =
    list.fold(dict.to_list(state.lsp_rows), selector, fn(selector, pair) {
      let #(address, row) = pair
      let selector =
        process.select_map(selector, row.events, LspEvent(address, _))
      let tasks = [
        #(LspStartTask, row.start),
        #(LspInputTask, option.map(row.input, fn(input) { input.task })),
        #(LspOutputTask, option.map(row.output, fn(output) { output.task })),
      ]
      list.fold(tasks, selector, fn(selector, pair) {
        case pair.1 {
          Some(task) ->
            process.select_map(selector, task.reports, LspReport(
              address,
              pair.0,
              _,
            ))
          None -> selector
        }
      })
    })
  actor.continue(state) |> actor.with_selector(selector)
}

fn stop_confirmations(state: State, _reason: process.ExitReason) -> Nil {
  dict.values(state.lsp_rows) |> list.each(cancel_lsp_controls)
  dict.values(state.rows)
  |> list.each(fn(row) {
    case row.confirmation {
      Confirming(_, cancel, _, _, _) -> weft.cancel(cancel)
      ConfirmationReady(_) | ConfirmationSpent | ConfirmationLost -> Nil
    }
  })
}

fn close_scope(state: State) -> #(State, Result(wire.Body, Error)) {
  // Quiescence and the original native disposition survive every outward error.
  // Covered identities cannot grow after this point; retries only confirm them.
  let state = fence_all_lsp(State(..state, gate: Quiesced, tickets: []))

  // A confirmation result is not its relay drain. Scope closure cannot issue
  // another journal write while an original continuation still owns that writer.
  case
    list.any(dict.values(state.rows), fn(row) {
      case row.confirmation {
        Confirming(..) | ConfirmationLost -> True
        ConfirmationReady(_) | ConfirmationSpent -> False
      }
    })
    || list.any(dict.values(state.lsp_rows), fn(row) { row.drain != LspDrained })
  {
    True -> #(state, Error(Uncertain))
    False -> close_drained_scope(state)
  }
}

fn close_drained_scope(state: State) -> #(State, Result(wire.Body, Error)) {
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

  // Scoped confirmation supplies only the inherited scope proof. Original pool
  // callbacks queued during close still enter the sole per-Launch managed path;
  // this synchronous scope lane cannot bypass its deadline or report drain.

  // Native success alone never advertises complete scope retirement. The exact
  // original journal and covered-key confirmations must also succeed.
  let outcome = {
    // Scope retirement cannot substitute for a launched LSP's exact observer.
    // Its queued callback must enter the actor before a later close can succeed.
    use <- bool.guard(
      list.any(dict.values(state.lsp_rows), fn(row) {
        row.begun == LspBegun && row.retirement != LspPositiveNative
      }),
      Error(Uncertain),
    )
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
  // The original adapter owns this sink. Its death must release the executor
  // writer's settlement ask, rather than wait thirty seconds on a dead subject.
  let _ =
    call.try_call(sink.subject, waiting: 30_000, sending: End(terminal, _))
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

// The incoming fresh lease is already charged in the durable slot inventory.
// This one Service reserves its prospective native row before any checkout.
fn install_lsp_pending(
  state: State,
  store: lsp_store.Store,
  claim: lsp_store.LeaseStartupClaim,
  plan: lsp_plan.CheckedServerPlan,
  era: lsp_id.ClockEra,
  owner: process.Pid,
) -> #(State, Result(PendingServerLease, Error)) {
  let state = prune_retired_lsp_rows(state)
  let #(binding, lease, deadline, original_era) =
    lsp_store.lease_startup_fields(claim)
  let address = lsp_id.lease_address(lease)
  let checked = {
    use expected_binding <- result.try(
      lsp_plan.binding(plan, state.config.generation)
      |> result.replace_error(Invalid),
    )
    use Nil <- result.try(
      bool.guard(
        !{
          state.gate == Accepting
          && binding == expected_binding
          && original_era == era
          && lsp_plan.fields(plan).0 == state.config.scope
          && !dict.has_key(state.lsp_rows, address)
        },
        Error(Invalid),
        fn() { Ok(Nil) },
      ),
    )
    use Nil <- result.try(
      lsp_store.verify_lease_startup(store, binding, claim, era)
      |> result.replace_error(Invalid),
    )
    use Nil <- result.try(
      lsp_plan.lease_matches(plan, lease) |> result.replace_error(Invalid),
    )
    use snapshot <- result.try(
      local.snapshot(state.config.native, waiting: 1000)
      |> result.replace_error(Uncertain),
    )
    use custody <- result.try(snapshot.pool |> result.replace_error(Uncertain))
    use count <- result.try(
      lsp_store.unretired_lease_count(store, binding)
      |> result.replace_error(Uncertain),
    )
    use Nil <- result.try(
      case
        count <= custody.census.size - 3
        && dict.size(state.lsp_rows) < custody.census.size - 3
      {
        True -> Ok(Nil)
        False -> Error(Capacity)
      },
    )
    use ref <- result.try(
      lsp_id.lsp_startup_command(lease, lsp_id.ServerLease)
      |> result.replace_error(Invalid),
    )
    use command <- result.try(
      lsp_store.reserve_command(store, ref, lsp_wire.Diagnostics(None), None)
      |> result.replace_error(Uncertain),
    )
    use offer <- result.try(
      lsp_plan.offer(plan) |> result.replace_error(Invalid),
    )
    use placement <- result.try(
      lsp_store.retain_startup_offer(claim, command, offer, fn(actual, bytes) {
        case actual == ref && bytes == offer {
          True -> Ok(Nil)
          False -> Error(lsp_store.Conflict)
        }
      })
      |> result.replace_error(Uncertain),
    )
    use Nil <- result.try(case placement {
      lsp_store.FreshPlacement(_) -> Ok(Nil)
      lsp_store.RetainedPlacement(_) -> Error(Uncertain)
    })
    Ok(Nil)
  }
  case checked {
    Error(error) -> #(state, Error(error))
    Ok(Nil) -> {
      let nonce = reference.new()
      let row =
        LspRow(
          store,
          binding,
          lease,
          claim,
          plan,
          era,
          deadline,
          nonce,
          owner,
          process.monitor(owner),
          LspPending,
          LspNotBegun,
          LspOpen,
          None,
          None,
          None,
          process.new_subject(),
          None,
          None,
          None,
          0,
          0,
          None,
          1,
          None,
          LspAwaitingNative,
          LspPendingDrain,
        )
      #(
        State(..state, lsp_rows: dict.insert(state.lsp_rows, address, row)),
        Ok(PendingServerLease(state.subject, address, nonce)),
      )
    }
  }
}

fn prune_retired_lsp_rows(state: State) -> State {
  let rows =
    list.fold(dict.to_list(state.lsp_rows), state.lsp_rows, fn(rows, pair) {
      let #(address, row) = pair
      case row.gate, row.retirement, row.drain {
        LspClosed, LspPositiveNative, LspDrained -> {
          case
            lsp_store.inspect_lease(row.store, row.binding, row.lease)
            |> result.map(lsp_store.lease_disposition)
          {
            Ok(lsp_store.Retired) -> {
              process.demonitor_process(row.monitor)
              dict.delete(rows, address)
            }
            _ -> rows
          }
        }
        _, _, _ -> rows
      }
    })
  State(..state, lsp_rows: rows)
}

// Consuming local installation precedes Request, so lost admission replies cannot
// use a copied context to install another native attachment.
fn submit_lsp_pending(
  state: State,
  pending: PendingServerLease,
  key: identity.RequestKey,
  prepared: wire.Prepared,
) -> #(State, Result(LspProtocolAttachment, Error)) {
  let found = {
    use Nil <- result.try(
      bool.guard(!{ pending.subject == state.subject }, Error(Invalid), fn() {
        Ok(Nil)
      }),
    )
    use row <- result.try(
      dict.get(state.lsp_rows, pending.address) |> result.replace_error(Invalid),
    )
    use Nil <- result.try(
      bool.guard(
        !{
          row.nonce == pending.nonce
          && row.permission == LspPending
          && row.gate == LspOpen
          && state.gate == Accepting
        },
        Error(Invalid),
        fn() { Ok(Nil) },
      ),
    )
    Ok(row)
  }
  case found {
    Error(error) -> #(state, Error(error))
    Ok(row) -> {
      let row = LspRow(..row, permission: LspConsumed)
      let state =
        State(
          ..state,
          lsp_rows: dict.insert(state.lsp_rows, pending.address, row),
          sequence: state.sequence + 1,
        )
      case validate_lsp_native(state, row, key, prepared) {
        Error(error) -> #(
          close_lsp_row(state, pending.address, row.nonce),
          Error(error),
        )
        Ok(#(digest, bytes, authority)) -> {
          // Request may commit even when its reply is lost. Exact checked coverage
          // therefore begins before that first write and remains on every failure.
          let state =
            State(..state, covered: dict.insert(state.covered, key, digest))
          record_lsp_native(state, row, key, prepared, digest, bytes, authority)
          |> finish_lsp_admission(state, pending.address, row)
        }
      }
    }
  }
}

fn finish_lsp_admission(
  answer: Result(LspNative, Error),
  state: State,
  address: String,
  row: LspRow,
) -> #(State, Result(LspProtocolAttachment, Error)) {
  case answer {
    Error(error) -> #(close_lsp_row(state, address, row.nonce), Error(error))
    Ok(native) -> {
      let row = LspRow(..row, native: Some(native))
      let state =
        State(..state, lsp_rows: dict.insert(state.lsp_rows, address, row))
      #(state, Ok(LspProtocolAttachment(state.subject, address, row.nonce)))
    }
  }
}

// Opaque lease construction already checked the header. Comparing these original
// coordinates prevents another request in the same scope from consuming its plan.
fn lsp_key_matches(
  lease: lsp_id.LspServiceKey,
  key: identity.RequestKey,
) -> Bool {
  let #(operation, request) = identity.key_fields(key)
  case lsp_id.lease_value(lease) {
    mp.ArrayValue([
      _,
      _,
      _,
      _,
      mp.StringValue(op),
      _,
      mp.StringValue(id),
      _,
      _,
      _,
      _,
      _,
    ]) -> operation == op && request == id
    _ -> False
  }
}

fn validate_lsp_native(
  state: State,
  row: LspRow,
  key: identity.RequestKey,
  prepared: wire.Prepared,
) -> Result(#(identity.Digest, BitArray, BitArray), Error) {
  use Nil <- result.try(
    lsp_store.verify_lease_startup(row.store, row.binding, row.startup, row.era)
    |> result.replace_error(Invalid),
  )
  use Nil <- result.try(
    lsp_plan.verify(row.plan, key, prepared) |> result.replace_error(Invalid),
  )
  use Nil <- result.try(
    state.config.verify(key, prepared) |> result.replace_error(Invalid),
  )
  use Nil <- result.try(
    bool.guard(
      !{
        identity.key_scope(key) == state.config.scope
        && lsp_key_matches(row.lease, key)
        && state.config.now() < row.deadline
      },
      Error(Invalid),
      fn() { Ok(Nil) },
    ),
  )
  use digest <- result.try(
    wire.prepared_digest(prepared) |> result.replace_error(Invalid),
  )
  use bytes <- result.try(
    wire.encode_prepared(prepared) |> result.replace_error(Invalid),
  )
  use original <- result.try(
    journal.payloads(state.config.journal, key, digest) |> durable,
  )
  use Nil <- result.try(
    bool.guard(!{ original == [] }, Error(Invalid), fn() { Ok(Nil) }),
  )
  use authority <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(state.generation),
        mp.IntValue(row.deadline),
        mp.IntValue(43_200_000),
      ]),
    )
    |> result.replace_error(Invalid),
  )
  Ok(#(digest, bytes, authority))
}

fn record_lsp_native(
  state: State,
  row: LspRow,
  key: identity.RequestKey,
  prepared: wire.Prepared,
  digest: identity.Digest,
  bytes: BitArray,
  authority: BitArray,
) -> Result(LspNative, Error) {
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

  // The actual native incarnation and sequence precede AuthorizeLaunch, and the
  // association verifier reads the original native admission and exact payloads.
  use snapshot <- result.try(
    local.snapshot(state.config.native, waiting: 1000)
    |> result.replace_error(Uncertain),
  )
  let #(operation, request) = identity.key_fields(key)
  use native_identity <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(1),
        mp.BinaryValue(journal_codec.binding(identity.key_scope(key))),
        mp.StringValue(operation),
        mp.StringValue(request),
        mp.BinaryValue(identity.digest_bytes(digest)),
        mp.IntValue(snapshot.incarnation),
        mp.IntValue(state.sequence),
      ]),
    )
    |> result.replace_error(Invalid),
  )
  use ref <- result.try(
    lsp_id.lsp_startup_command(row.lease, lsp_id.ServerLease)
    |> result.replace_error(Invalid),
  )
  use command <- result.try(
    lsp_store.inspect_command(
      row.store,
      row.binding,
      ref,
      lsp_wire.Diagnostics(None),
      None,
    )
    |> result.replace_error(Uncertain),
  )
  let book = state.config.journal
  use command <- result.try(
    lsp_store.associate(
      row.store,
      command,
      native_identity,
      bytes,
      fn(history, actual_identity, actual_prepared) {
        use Nil <- result.try(
          case
            lsp_store.command_evidence(history).0 == ref
            && actual_identity == native_identity
            && actual_prepared == bytes
          {
            True -> Ok(Nil)
            False -> Error(lsp_store.Conflict)
          },
        )
        use evidence <- result.try(
          journal.inspect(book, key, digest)
          |> result.replace_error(lsp_store.Uncertain),
        )
        use items <- result.try(
          journal.payloads(book, key, digest)
          |> result.replace_error(lsp_store.Uncertain),
        )
        case
          admission.phase(evidence) == admission.Admitted
          && list.contains(items, payload.Request(bytes))
          && list.contains(items, payload.Authority(authority))
        {
          True -> Ok(Nil)
          False -> Error(lsp_store.Conflict)
        }
      },
    )
    |> result.replace_error(Uncertain),
  )
  use claim <- result.try(
    case lsp_store.start_command(row.store, command, None) {
      Ok(lsp_store.FreshServer(claim)) -> Ok(claim)
      Ok(lsp_store.FreshCommand(_)) | Ok(lsp_store.RetainedCommand(_)) ->
        Error(Uncertain)
      Error(_) -> Error(Uncertain)
    },
  )
  Ok(LspNative(
    key,
    digest,
    prepared,
    command,
    claim,
    state.sequence,
    snapshot.incarnation,
  ))
}

fn install_lsp_sink(
  state: State,
  attachment: LspProtocolAttachment,
  sink: consumed.Sink,
) -> #(State, Result(Nil, Error)) {
  case dict.get(state.lsp_rows, attachment.address) {
    Ok(LspRow(sink: None, native: Some(_), gate: LspOpen, ..) as row)
      if attachment.subject == state.subject && row.nonce == attachment.nonce
    -> {
      #(
        State(
          ..state,
          lsp_rows: dict.insert(
            state.lsp_rows,
            attachment.address,
            LspRow(..row, sink: Some(sink)),
          ),
        ),
        Ok(Nil),
      )
    }
    _ -> #(state, Error(Invalid))
  }
}

fn begin_lsp(
  state: State,
  address: String,
  nonce: reference.Reference,
) -> State {
  case dict.get(state.lsp_rows, address) {
    Ok(
      LspRow(
        native: Some(native),
        sink: Some(_),
        begun: LspNotBegun,
        gate: LspOpen,
        ..,
      ) as row,
    )
      if row.nonce == nonce
    -> {
      let row = LspRow(..row, begun: LspBegun)
      let state =
        State(..state, lsp_rows: dict.insert(state.lsp_rows, address, row))
      case authorize_lsp(state, row, native, address) {
        Ok(task) ->
          State(
            ..state,
            lsp_rows: dict.insert(
              state.lsp_rows,
              address,
              LspRow(..row, start: Some(task)),
            ),
          )
        Error(_) -> close_lsp_row(state, address, nonce)
      }
    }
    _ -> state
  }
}

fn authorize_lsp(
  state: State,
  row: LspRow,
  native: LspNative,
  address: String,
) -> Result(LspTask, Error) {
  use Nil <- result.try(
    lsp_store.verify_server_claim(row.store, row.binding, native.claim, row.era)
    |> result.replace_error(Invalid),
  )
  use Nil <- result.try(
    lsp_plan.verify(row.plan, native.key, native.prepared)
    |> result.replace_error(Invalid),
  )
  use Nil <- result.try(
    state.config.verify(native.key, native.prepared)
    |> result.replace_error(Invalid),
  )
  let remaining = row.deadline - state.config.now()
  use Nil <- result.try(
    bool.guard(
      !{ remaining > 0 && state.gate == Accepting },
      Error(Invalid),
      fn() { Ok(Nil) },
    ),
  )
  let self = state.subject
  let nonce = row.nonce
  use dispatcher <- result.try(
    local.dispatcher_protocol_retiring_with_native_deadline(
      state.config.native,
      fn(execution, answer) {
        process.send(self, LspRetired(address, nonce, execution, answer))
      },
    )
    |> result.replace_error(Invalid),
  )
  use decision <- result.try(
    journal.apply(
      state.config.journal,
      native.key,
      native.digest,
      admission.AuthorizeLaunch,
    )
    |> durable,
  )
  use Nil <- result.try(case decision.effect {
    admission.Launch(_) -> Ok(Nil)
    admission.NoLaunch -> Error(Uncertain)
  })

  // Only committed first authorization enters the original lifetime custodian.
  let reports = process.new_subject()
  let cancel = weft.cancel_signal()
  let events = row.events
  let deadline = row.deadline
  let now = state.config.now
  let sequence = native.sequence
  let request = native.prepared.request

  // This managed child remains the exact native caller for the whole attachment.
  // Its death reaches the original borrow even when the start reply is lost.
  let _ =
    weft.new_prepared([
      weft.managed(fn(_) {
        let lifetime = process.new_subject()
        let answer =
          local.start_protocol(
            dispatcher,
            local.ProtocolDispatch(
              sequence,
              request,
              clock.from_function(now),
              deadline,
              events,
              process.self(),
            ),
          )
        process.send(self, LspStarted(address, nonce, answer))
        process.receive_forever(lifetime)
        Ok(Nil)
      }),
    ])
    |> weft.deadline(remaining)
    |> weft.cancel_grace(1000)
    |> weft.cancel_with(cancel)
    |> weft.cancel_when_exits(process.self())
    |> weft.start_relayed(to: reports)
  Ok(LspTask(reports, cancel, None, LspPendingDrain))
}

fn lsp_started(
  state: State,
  address: String,
  nonce: reference.Reference,
  answer: Result(local.ProtocolExecution, local.ProtocolStartFailure),
) -> State {
  case dict.get(state.lsp_rows, address) {
    Ok(row) if row.nonce == nonce -> {
      case answer {
        Ok(execution) -> accept_lsp_started(state, address, row, execution)
        Error(local.ProtocolStartUnknown(execution, _) as failure) ->
          finish_lsp_start_failure(
            State(
              ..state,
              lsp_rows: dict.insert(
                state.lsp_rows,
                address,
                LspRow(..row, execution: Some(execution)),
              ),
            ),
            address,
            LspRow(..row, execution: Some(execution)),
            failure,
          )
        Error(failure) -> finish_lsp_start_failure(state, address, row, failure)
      }
    }
    _ -> {
      case answer {
        Ok(execution) | Error(local.ProtocolStartUnknown(execution, _)) -> {
          local.cancel_protocol(execution)
          local.release_protocol_execution(execution)
        }
        Error(local.ProtocolNotStarted(_))
        | Error(local.ProtocolStartReplyLost) -> Nil
      }
      state
    }
  }
}

// One exact body and credit wait are retained before forwarding. The worker
// waits under the original deadline until native startup and the actual ACK.
fn accept_lsp_started(
  state: State,
  address: String,
  row: LspRow,
  execution: local.ProtocolExecution,
) -> State {
  let row = LspRow(..row, execution: Some(execution))
  let state =
    State(..state, lsp_rows: dict.insert(state.lsp_rows, address, row))
  case row.gate, row.native {
    LspClosed, _ -> {
      local.cancel_protocol(execution)
      local.release_protocol_execution(execution)
      state
    }
    LspOpen, Some(native) -> {
      case lsp_store.serving(native.claim) {
        Ok(_) -> {
          option.map(row.input, fn(input) {
            option.map(input.ready, fn(ready) {
              process.send(ready, Ok(execution))
            })
          })
          release_joined_lsp_output(state, address)
        }
        Error(_) -> close_lsp_row(state, address, row.nonce)
      }
    }
    LspOpen, None -> close_lsp_row(state, address, row.nonce)
  }
}

fn lsp_feed(
  state: State,
  address: String,
  nonce: reference.Reference,
  bytes: BitArray,
  reply: process.Subject(Result(Nil, Nil)),
) -> State {
  let size = bit_array.byte_size(bytes)
  case dict.get(state.lsp_rows, address) {
    Ok(LspRow(gate: LspOpen, input: None, sink: Some(_), ..) as row)
      if row.nonce == nonce
      && size > 0
      && size <= 8192
      && row.frames < 8191
      && row.bytes + size <= 67_108_864
    -> {
      let reports = process.new_subject()
      let cancel = weft.cancel_signal()
      let self = state.subject
      let ordinal = row.frames + 1
      let _ =
        weft.new_prepared([
          weft.managed(fn(_) {
            let ready = process.new_subject()
            let ack = process.new_subject()
            process.send(self, LspInputReady(address, ordinal, ready, ack))
            use execution <- result.try(process.receive_forever(ready))
            use Nil <- result.try(
              local.protocol_input(
                execution,
                ordinal,
                ordinal,
                bytes,
                framing.InputContinues,
                waiting: 1000,
              )
              |> result.replace_error(Nil),
            )
            process.receive_forever(ack)
          }),
        ])
        |> weft.deadline(30_000)
        |> weft.cancel_grace(1000)
        |> weft.cancel_with(cancel)
        |> weft.cancel_when_exits(process.self())
        |> weft.start_relayed(to: reports)
      let input =
        LspInput(
          bytes,
          ordinal,
          None,
          None,
          None,
          reply,
          LspTask(reports, cancel, None, LspPendingDrain),
        )
      State(
        ..state,
        lsp_rows: dict.insert(
          state.lsp_rows,
          address,
          LspRow(
            ..row,
            input: Some(input),
            frames: row.frames + 1,
            bytes: row.bytes + bit_array.byte_size(bytes),
          ),
        ),
      )
    }
    Ok(row) -> {
      process.send(reply, Error(Nil))
      close_lsp_row(state, address, row.nonce)
    }
    Error(_) -> {
      process.send(reply, Error(Nil))
      state
    }
  }
}

fn lsp_input_ready(
  state: State,
  address: String,
  ordinal: Int,
  ready: process.Subject(Result(local.ProtocolExecution, Nil)),
  ack: process.Subject(Result(Nil, Nil)),
) -> State {
  case dict.get(state.lsp_rows, address) {
    Ok(LspRow(input: Some(input), gate: LspOpen, ..) as row)
      if input.ordinal == ordinal && input.ready == None
    -> {
      option.map(row.execution, fn(execution) {
        process.send(ready, Ok(execution))
      })
      option.map(input.accepted, fn(answer) { process.send(ack, answer) })
      let input = LspInput(..input, ready: Some(ready), ack: Some(ack))
      State(
        ..state,
        lsp_rows: dict.insert(
          state.lsp_rows,
          address,
          LspRow(..row, input: Some(input)),
        ),
      )
    }
    _ -> {
      process.send(ready, Error(Nil))
      process.send(ack, Error(Nil))
      state
    }
  }
}

fn lsp_event(
  state: State,
  address: String,
  event: exec.ProtocolEvent,
) -> State {
  case dict.get(state.lsp_rows, address) {
    Error(_) -> state
    Ok(row) -> lsp_row_event(state, address, row, event)
  }
}

fn lsp_row_event(
  state: State,
  address: String,
  row: LspRow,
  event: exec.ProtocolEvent,
) -> State {
  case event {
    exec.ProtocolInputAccepted(ordinal, frame) ->
      lsp_input_ack(state, address, row, ordinal, frame, Ok(Nil))
    exec.ProtocolInputRefused(ordinal, frame, _) ->
      lsp_input_ack(state, address, row, ordinal, frame, Error(Nil))
    exec.ProtocolOutput(ordinal, stream, data, _, disposition) ->
      offer_lsp_output(state, address, row, ordinal, stream, data, disposition)
    exec.ProtocolTerminal(answer, disposition) -> {
      let terminal = case answer {
        Ok(value) -> dispatch.Completed(value)
        Error(error) -> dispatch.Failed(error)
      }
      finish_lsp_terminal(state, address, row, terminal, disposition)
    }
    exec.ProtocolReusable ->
      finish_lsp_terminal(
        state,
        address,
        row,
        dispatch.Failed(exec.ProtocolViolation(
          "server lease received reusable witness",
        )),
        framing.ProtocolFailed,
      )
    exec.ProtocolFailure(error) ->
      finish_lsp_terminal(
        state,
        address,
        row,
        dispatch.Failed(error),
        framing.ProtocolFailed,
      )
  }
}

fn lsp_input_ack(
  state: State,
  address: String,
  row: LspRow,
  ordinal: Int,
  frame: Int,
  answer: Result(Nil, Nil),
) -> State {
  case row.input {
    Some(input)
      if input.ordinal == ordinal
      && frame == ordinal
      && input.accepted == None
      && row.gate == LspOpen
    -> {
      option.map(input.ack, fn(ack) { process.send(ack, answer) })
      let input = LspInput(..input, accepted: Some(answer))
      let state =
        State(
          ..state,
          lsp_rows: dict.insert(
            state.lsp_rows,
            address,
            LspRow(..row, input: Some(input)),
          ),
        )
      case answer {
        Ok(Nil) -> state
        Error(Nil) -> close_lsp_row(state, address, row.nonce)
      }
    }
    _ -> close_lsp_row(state, address, row.nonce)
  }
}

fn offer_lsp_output(
  state: State,
  address: String,
  row: LspRow,
  ordinal: Int,
  stream: framing.OutputStream,
  data: BitArray,
  disposition: framing.OutputDisposition,
) -> State {
  let size = bit_array.byte_size(data)
  case row.gate, row.output, row.sink {
    LspOpen, None, Some(sink)
      if ordinal == row.output_ordinal && size <= 32_768
    -> {
      let reports = process.new_subject()
      let cancel = weft.cancel_signal()
      let stream = case stream {
        framing.Stdout -> consumed.Stdout
        framing.Stderr -> consumed.Stderr
      }
      let integrity = case disposition {
        framing.OutputComplete -> consumed.Intact
        framing.OutputTruncated -> consumed.Truncated
      }
      let _ =
        weft.new_prepared([
          weft.managed(fn(_) {
            consumed.publish(sink, stream, data, integrity)
            |> result.replace_error(Nil)
          }),
        ])
        |> weft.deadline(30_000)
        |> weft.cancel_grace(1000)
        |> weft.cancel_with(cancel)
        |> weft.cancel_when_exits(process.self())
        |> weft.start_relayed(to: reports)
      let output =
        LspOutput(
          output_join.new(ordinal),
          LspTask(reports, cancel, None, LspPendingDrain),
        )
      State(
        ..state,
        lsp_rows: dict.insert(
          state.lsp_rows,
          address,
          LspRow(..row, output: Some(output)),
        ),
      )
    }
    _, _, _ -> close_lsp_row(state, address, row.nonce)
  }
}

// The original native events subject supplied this terminal. The DAL verifier
// then checks the exact immutable association and bytes against native custody.
fn finish_lsp_terminal(
  state: State,
  address: String,
  row: LspRow,
  terminal: dispatch.Terminal,
  disposition: framing.ProtocolDisposition,
) -> State {
  let disposition = case row.gate {
    LspClosed -> framing.ProtocolFailed
    LspOpen -> disposition
  }
  let encoded = lsp_plan.encode_terminal(terminal, disposition)
  retain_lsp_witness(state, address, row, encoded)
}

fn finish_lsp_start_failure(
  state: State,
  address: String,
  row: LspRow,
  failure: local.ProtocolStartFailure,
) -> State {
  retain_lsp_witness(
    state,
    address,
    row,
    lsp_plan.encode_start_failure(failure),
  )
}

// Only the original native events or original start continuation enter this door.
// Its closed bytes record failure without granting native retirement or slot reuse.
fn retain_lsp_witness(
  state: State,
  address: String,
  row: LspRow,
  encoded: Result(BitArray, wire.Error),
) -> State {
  let retained = lsp_witness_bytes(state, row, encoded)
  let row = case retained {
    Ok(bytes) -> LspRow(..row, terminal: Some(bytes))
    Error(_) -> row
  }
  option.map(row.sink, fn(sink) {
    consumed.closed(sink, "original native LSP protocol settled")
  })
  close_lsp_row(
    State(..state, lsp_rows: dict.insert(state.lsp_rows, address, row)),
    address,
    row.nonce,
  )
}

fn lsp_witness_bytes(
  state: State,
  row: LspRow,
  encoded: Result(BitArray, wire.Error),
) -> Result(BitArray, Error) {
  use native <- result.try(row.native |> option.to_result(Uncertain))
  use bytes <- result.try(encoded |> result.replace_error(Uncertain))
  use digest <- result.try(
    wire.digest(bytes) |> result.replace_error(Uncertain),
  )
  use Nil <- result.try(
    journal.put_payload(
      state.config.journal,
      native.key,
      native.digest,
      payload.Terminal(bytes),
    )
    |> durable,
  )
  use _ <- result.try(
    journal.apply(
      state.config.journal,
      native.key,
      native.digest,
      admission.ObserveTerminal(digest),
    )
    |> durable,
  )
  let book = state.config.journal
  use _ <- result.try(
    lsp_store.retain_terminal(
      row.store,
      native.command,
      bytes,
      <<>>,
      fn(history, exact, projection) {
        use Nil <- result.try(
          case
            lsp_store.command_evidence(history).0
            == lsp_store.command_evidence(native.command).0
            && exact == bytes
            && projection == <<>>
          {
            True -> Ok(Nil)
            False -> Error(lsp_store.Conflict)
          },
        )
        use items <- result.try(
          journal.payloads(book, native.key, native.digest)
          |> result.replace_error(lsp_store.Uncertain),
        )
        case list.contains(items, payload.Terminal(bytes)) {
          True -> Ok(Nil)
          False -> Error(lsp_store.Conflict)
        }
      },
    )
    |> result.replace_error(Uncertain),
  )
  Ok(bytes)
}

fn close_lsp_row(
  state: State,
  address: String,
  nonce: reference.Reference,
) -> State {
  case dict.get(state.lsp_rows, address) {
    Ok(LspRow(gate: LspOpen, ..) as row) if row.nonce == nonce -> {
      cancel_lsp_controls(row)

      // Physical cancellation precedes durable asks, so a failed SQL reply cannot
      // keep the original native borrow useful or reopen this local input door.
      let _ = {
        use lease <- result.try(lsp_store.inspect_lease(
          row.store,
          row.binding,
          row.lease,
        ))
        lsp_store.close_lease(row.store, lease)
      }
      option.map(row.native, fn(native) {
        let _ = lsp_store.fence_command(row.store, native.command)
        Nil
      })
      let row = LspRow(..row, gate: LspClosed)

      // A local consumer's closure cannot advertise a successful native prefix.
      // The closed failure tag is independent of terminal and retirement events.
      let row = case row.begun, row.terminal {
        LspBegun, None -> {
          case lsp_witness_bytes(state, row, lsp_plan.encode_local_closure()) {
            Ok(bytes) -> LspRow(..row, terminal: Some(bytes))
            Error(_) -> row
          }
        }
        _, _ -> row
      }
      let row = case row.output {
        Some(output) if output.task.drain == LspDrained -> finish_lsp_output(row)
        _ -> row
      }
      let row = lsp_drain(row)
      State(..state, lsp_rows: dict.insert(state.lsp_rows, address, row))
    }
    _ -> state
  }
}

fn cancel_lsp_controls(row: LspRow) -> Nil {
  option.map(row.execution, fn(execution) {
    local.cancel_protocol(execution)
    local.release_protocol_execution(execution)
  })
  option.map(row.start, fn(task) { weft.cancel(task.cancel) })
  option.map(row.input, fn(input) { weft.cancel(input.task.cancel) })
  option.map(row.output, fn(output) { weft.cancel(output.task.cancel) })
  option.map(row.sink, fn(sink) {
    consumed.closed(sink, "original LSP input fenced")
  })
  Nil
}

fn fence_all_lsp(state: State) -> State {
  // All originals receive physical cancellation before any durable fence ask.
  dict.values(state.lsp_rows) |> list.each(cancel_lsp_controls)
  list.fold(dict.to_list(state.lsp_rows), state, fn(state, pair) {
    close_lsp_row(state, pair.0, pair.1.nonce)
  })
}

fn inspect_lsp(
  state: State,
  attachment: LspProtocolAttachment,
) -> Result(LspCleanup, Error) {
  use row <- result.try(
    dict.get(state.lsp_rows, attachment.address)
    |> result.replace_error(Invalid),
  )
  use Nil <- result.try(
    bool.guard(
      !{ attachment.subject == state.subject && attachment.nonce == row.nonce },
      Error(Invalid),
      fn() { Ok(Nil) },
    ),
  )
  Ok(LspCleanup(row.gate, row.drain, row.terminal, row.retirement))
}

fn lsp_retired(
  state: State,
  address: String,
  nonce: reference.Reference,
  execution: dispatch.ExecutionId,
  answer: Result(Nil, exec.RetirementFailure),
) -> State {
  let sequence = dispatch.seq(execution)
  let incarnation = dispatch.incarnation(execution)
  case dict.get(state.lsp_rows, address) {
    Ok(LspRow(native: Some(native), retirement: LspAwaitingNative, ..) as row)
      if row.nonce == nonce
      && native.sequence == sequence
      && native.incarnation == incarnation
    -> {
      let retirement = case answer {
        Ok(Nil) -> LspPositiveNative
        Error(_) -> LspUnknownNative
      }
      case retirement {
        LspPositiveNative -> {
          let _ =
            journal.apply(
              state.config.journal,
              native.key,
              native.digest,
              admission.ConfirmRetirement,
            )
          Nil
        }
        LspAwaitingNative | LspUnknownNative -> Nil
      }
      State(
        ..state,
        lsp_rows: dict.insert(
          state.lsp_rows,
          address,
          LspRow(..row, retirement:),
        ),
      )
    }
    _ -> state
  }
}

fn lsp_report(
  state: State,
  address: String,
  kind: LspTaskKind,
  report: weft.Pulled(Nil, Nil),
) -> State {
  case dict.get(state.lsp_rows, address) {
    Error(_) -> state
    Ok(row) -> {
      let row = lsp_task_report(row, kind, report)
      let state =
        State(..state, lsp_rows: dict.insert(state.lsp_rows, address, row))
      case report {
        weft.PulledOutcome(outcome) -> {
          case lsp_task_result(outcome) {
            Ok(Nil) -> state
            Error(Nil) -> close_lsp_row(state, address, row.nonce)
          }
        }
        weft.RunLost(_) -> close_lsp_row(state, address, row.nonce)
        weft.AllDelivered | weft.NotYet -> state
      }
    }
  }
}

fn lsp_task_report(
  row: LspRow,
  kind: LspTaskKind,
  report: weft.Pulled(Nil, Nil),
) -> LspRow {
  case kind, report {
    LspStartTask, weft.PulledOutcome(outcome) ->
      LspRow(
        ..row,
        start: option.map(row.start, fn(task) {
          LspTask(..task, outcome: Some(lsp_task_result(outcome)))
        }),
      )
    LspInputTask, weft.PulledOutcome(outcome) ->
      LspRow(
        ..row,
        input: option.map(row.input, fn(input) {
          LspInput(
            ..input,
            task: LspTask(..input.task, outcome: Some(lsp_task_result(outcome))),
          )
        }),
      )
    LspOutputTask, weft.PulledOutcome(outcome) ->
      LspRow(
        ..row,
        output: option.map(row.output, fn(output) {
          LspOutput(
            ..output,
            task: LspTask(
              ..output.task,
              outcome: Some(lsp_task_result(outcome)),
            ),
          )
        }),
      )
    LspStartTask, weft.AllDelivered -> {
      option.map(row.start, fn(task) { weft.cancel(task.cancel) })
      lsp_drain(LspRow(..row, start: None))
    }
    LspInputTask, weft.AllDelivered -> {
      option.map(row.input, fn(input) { weft.cancel(input.task.cancel) })
      finish_lsp_input(row)
    }
    LspOutputTask, weft.AllDelivered -> {
      // AllDelivered releases the externally owned signal even when the exact
      // consumed ordinal must remain held until its original execution arrives.
      option.map(row.output, fn(output) { weft.cancel(output.task.cancel) })
      let row =
        LspRow(
          ..row,
          output: option.map(row.output, fn(output) {
            LspOutput(..output, task: LspTask(..output.task, drain: LspDrained))
          }),
        )
      finish_lsp_output(row)
    }
    _, weft.RunLost(_) -> LspRow(..row, drain: LspUnknownDrain)
    _, weft.NotYet -> row
  }
}

fn finish_lsp_input(row: LspRow) -> LspRow {
  case row.input {
    Some(input) -> {
      let answer = case row.gate, input.accepted, input.task.outcome {
        LspOpen, Some(Ok(Nil)), Some(Ok(Nil)) -> Ok(Nil)
        _, _, _ -> Error(Nil)
      }
      process.send(input.reply, answer)
      let last = case answer {
        Ok(Nil) ->
          Some(#(input.ordinal, crypto.hash(crypto.Sha256, input.bytes)))
        Error(Nil) -> row.last_input
      }
      lsp_drain(LspRow(..row, input: None, last_input: last))
    }
    None -> row
  }
}

fn finish_lsp_output(row: LspRow) -> LspRow {
  case row.output {
    Some(output) -> {
      let #(credit, action) = case row.gate, output.task.outcome {
        LspOpen, Some(Ok(Nil)) -> {
          let #(credit, action) = case row.execution {
            Some(execution) -> output_join.original(output.credit, execution)
            None -> #(output.credit, output_join.Hold)
          }
          case action {
            output_join.Release(..) -> #(credit, action)
            output_join.Hold | output_join.Dropped ->
              output_join.consumed(credit)
          }
        }
        _, _ -> output_join.drop(output.credit)
      }
      case action {
        output_join.Release(execution, ordinal) -> {
          local.protocol_output_consumed(execution, ordinal)
          lsp_drain(
            LspRow(..row, output: None, output_ordinal: row.output_ordinal + 1),
          )
        }
        output_join.Dropped -> lsp_drain(LspRow(..row, output: None))
        output_join.Hold ->
          LspRow(..row, output: Some(LspOutput(..output, credit: credit)))
      }
    }
    None -> lsp_drain(row)
  }
}

fn release_joined_lsp_output(state: State, address: String) -> State {
  case dict.get(state.lsp_rows, address) {
    Ok(LspRow(output: Some(output), ..) as row)
      if output.task.drain == LspDrained
    ->
      State(
        ..state,
        lsp_rows: dict.insert(state.lsp_rows, address, finish_lsp_output(row)),
      )
    _ -> state
  }
}

fn lsp_drain(row: LspRow) -> LspRow {
  case row.drain, row.gate, row.start, row.input, row.output {
    LspUnknownDrain, _, _, _, _ -> row
    _, LspClosed, None, None, None -> LspRow(..row, drain: LspDrained)
    _, _, _, _, _ -> row
  }
}

fn lsp_task_result(outcome: weft.Outcome(Nil, Nil)) -> Result(Nil, Nil) {
  case outcome {
    weft.Completed(_, Nil) -> Ok(Nil)
    weft.Failed(_, Nil)
    | weft.Crashed(..)
    | weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) -> Error(Nil)
  }
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

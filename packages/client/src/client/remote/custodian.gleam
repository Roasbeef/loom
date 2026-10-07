//// One supervised actor owns one session's remote tool journal.
////
//// `execute` asks for an atomic fresh reservation and a bounded final ticket.
//// Only a fresh reservation starts a weft-owned worker. Caller death loses
//// its ticket, never the worker or committed report. `reported` consumes task
//// reports, commits exact final bytes and only then answers the ticket.
//// Exact commit and complete live delivery discharge a durable run marker.
//// A restarted owner with any unreleased run remains recovery-only.
////
//// Requests are typed and byte bounded; task admission is bounded by four
//// active runs. These properties do not bound an OTP mailbox: root must bind
//// the handle to its bounded ingress/effect pool. No unbounded cast writer,
//// observer list, arbitrary SQL closure or process ledger is exposed here.
////
//// ## Flow
////
//// `execute_with_profile` → `begin` → `reported` retains exact final tool outcomes.
//// `retain_report` commits a complete report before its final reference.
//// `read_report_chunk` reads immutable bounded owner-local slices.
//// `fatal_fence` → `unresolved` permanently fences this incarnation's discharge.
//// `answer_once` preserves the first disposition; `fence_admission` blocks reuse.
//// `reserve_service_child` → `admit_offer` → `reserve_command_child` commits
//// service/offer/complete native custody through the same serialized `handle`.
//// `service_child`, `offer`, `command_offer_for_origin` and `command_child`
//// recover original evidence;
//// `cancel_service` fences those links in one transaction. `collect` defers
//// physical-service payload deletion until independent recovery transfer exists.
//// `with_registered` validates closed placement before `boot_generation` commits
//// the pin and full association on this actor's original connection.
//// `registered_readback` separates original readiness from `HistoryOnly`;
//// `reserve_tool`, `reserve_workspace`, `reserve_service`, `reserve_offer` and
//// `reserve_command` use its private connection-bound live generation.
//// `retain_intent` and `admit_system_child` preserve durable system ordinals.
//// `lookup_workspace_administration_intent` reads historical metadata through
//// the captured actor association without retaining or allocating a source.
//// `reconciliation_intent` prevents fresh allocation by a fenced original owner.
//// `receipt_readback` verifies exact original receipt and generation before ACK.
//// `allocate_system` stores the actual opaque pending value under a fresh Ref.
//// `consume_system_reservation` closes it before exact cleared-envelope checks;
//// `handle_system_reservation` shares this actor's existing bounded selector.
//// `resolve_semantic_parent` → `reserve_workspace_command` retains the original
//// semantic parent beside each fixed native phase; `semantic_evidence` is history.

import broker/dispatch
import broker/enrollment
import broker/internal/call
import broker/policy
import client/remote/native_envelope
import client/remote/outcome
import codemode/service_input
import core/command
import core/generation
import core/ids
import core/msgpack
import core/remote_tool
import core/report_value
import core/workspace
import executor/remote/compile_completion
import executor/remote/compile_wire
import executor/remote/identity
import executor/remote/registration
import executor/remote/wire
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/erlang/reference
import gleam/list
import gleam/option
import gleam/otp/supervision
import gleam/result
import gleam/string
import runtime/effects
import simplifile
import storage/owner_custody as custody
import storage/storage
import weft
import weft/actor
import weft/registry

/// Immutable dependencies and bounded worker policy.
pub opaque type Config {
  Config(
    /// Separate owner journal pathname.
    path: String,
    /// Durable session identity bound in SQLite metadata.
    session: ids.SessionId,
    /// Persistent row and byte quotas.
    limits: custody.Limits,
    /// Maximum independently owned active tool bodies.
    active: Int,
    /// Hard lifetime of one live owner task, in milliseconds.
    task_ms: Int,
    /// Trusted host SHA-256 seam, absent for ordinary-only custody.
    sha256: option.Option(fn(BitArray) -> BitArray),
    /// Closed placement contains metadata only, never a live connection token.
    placement: Placement,
    /// Remote runner receives its pinned custodian and original runtime identity.
    runner: fn(Handle, remote_tool.ToolKey, effects.ToolRun) ->
      effects.ToolOutcome,
  )
}

/// External handles resolve the supervised registry; runner handles pin one owner.
/// Only admission supplies the private pinned destination before spawning work.
pub opaque type Handle {
  Handle(
    address: registry.Address(Message),
    destination: Destination,
    /// Registered boot retains this original companion path before opening a writer.
    path: String,
    /// An address cannot be rebound to a different registered generation.
    placement: Placement,
    task_ms: Int,
    /// Pre-send quota bound, rechecked against the actor store configuration.
    limits: custody.Limits,
  )
}

// External history follows the registry; an admitted runner retains one incarnation.
type Destination {
  Reclaimable
  Pinned(
    process.Subject(Message),
    process.Subject(dispatch.SystemReservationMessage),
  )
}

/// Original ready custody, with no claim about executor activation acknowledgement.
/// Only the live original actor can construct this pinned assembly projection.
pub opaque type RegisteredOwner {
  RegisteredOwner(
    /// Original incarnation-pinned custodian, never the reclaimable address.
    owner: Handle,
    /// Actual committed and verified enrollment metadata.
    pin: custody.EnrollmentPin,
    /// Exact immutable association retained by the same connection.
    association: generation.GenerationAssociation,
  )
}

/// Ready custody and historical metadata cannot become the same authority.
pub type RegisteredBoot {
  /// Pin and association have committed; executor Activate is still a caller step.
  ReadyForActivation(owner: RegisteredOwner)

  /// Reopen grants only original history, never a replacement owner-use bundle.
  HistoryOnly(
    /// Exact original verified pin.
    pin: custody.EnrollmentPin,
    /// Complete original generation association.
    association: generation.GenerationAssociation,
  )
}

/// A fresh local permission is distinct from durable allocation history.
pub type SystemReservationAllocation {
  /// The only original live allocation may enter Broker clearance.
  SystemPermission(ref: dispatch.SystemReservationRef)

  /// Historical allocation grants no clearance or native send.
  SystemObservation(
    /// Complete original once-allocated system origin.
    origin: remote_tool.ChildOrigin,
    /// Original immutable work UUID.
    request_id: ids.EntryId,
    /// Closed historical state, never a replacement pending permission.
    stage: custody.SystemChildStage,
  )
}

type PendingAuthority {
  LivePending(custody.PendingSystemChild)
  SpentPending
}

type OriginalSystemPending {
  OriginalSystemPending(
    intent: custody.IntentReadback,
    declaration: dispatch.SystemCommandDeclaration,
    caller: process.Pid,
    association: generation.GenerationAssociation,
    origin: remote_tool.ChildOrigin,
    request_id: ids.EntryId,
    permission: PendingAuthority,
  )
}

type ExistingCompanion {
  NewCompanion
  ExistingCompanion
}

type Placement {
  OrdinaryPlacement
  RegisteredPlacement(
    pin: custody.EnrollmentPin,
    association: generation.GenerationAssociation,
    first_generation: Int,
  )
}

type GenerationCustody {
  OrdinaryCustody
  OriginalGeneration(custody.LiveGeneration)
  HistoricalGeneration(generation.GenerationAssociation)
}

/// Closed actor vocabulary; no caller can submit a query closure.
pub opaque type Message {
  /// The one auxiliary typed subject joins this existing actor selector.
  SystemReservation(dispatch.SystemReservationMessage)

  /// Original declaration and caller accompany the original retained intent.
  AllocateSystem(
    custody.IntentReadback,
    dispatch.SystemCommandDeclaration,
    process.Pid,
    process.Subject(Result(SystemReservationAllocation, custody.Error)),
  )

  /// Cancellation of an intent whose allocation reply was lost uses original data only.
  CancelSystemIntent(
    custody.IntentReadback,
    process.Subject(Result(Nil, custody.Error)),
  )

  /// Reads an exact admitted semantic parent under the original live association.
  ReadSemanticEvidence(
    remote_tool.ChildOrigin,
    process.Subject(
      Result(
        #(ids.EntryId, BitArray, BitArray, generation.GenerationAssociation),
        custody.Error,
      ),
    ),
  )

  ResolveSemanticParent(
    ids.EntryId,
    BitArray,
    process.Subject(Result(custody.SemanticParent, custody.Error)),
  )

  /// Commits full native bytes with a same-transaction original semantic check.
  ReserveWorkspaceCommand(
    custody.SemanticParent,
    remote_tool.ChildOrigin,
    ids.EntryId,
    BitArray,
    process.Subject(Result(#(ids.EntryId, BitArray), custody.Error)),
  )

  /// Readiness retains only this actor's actual original connection disposition.
  ReadRegistered(process.Subject(Result(RegisteredBoot, custody.Error)))

  /// Exact ToolKey history cannot select the current generation.
  ReadToolGeneration(
    remote_tool.ToolKey,
    process.Subject(Result(generation.GenerationAssociation, custody.Error)),
  )

  /// Complete native/workspace origin resolves its independently retained link.
  ReadChildGeneration(
    remote_tool.ChildOrigin,
    process.Subject(Result(generation.GenerationAssociation, custody.Error)),
  )

  /// Complete service identity is validated before projecting its original link.
  ReadServiceGeneration(
    command.ServiceKey,
    process.Subject(Result(generation.GenerationAssociation, custody.Error)),
  )

  /// Receipt and original generation are read by the same serialized writer.
  ReadReceiptGeneration(
    remote_tool.ChildOrigin,
    ids.EntryId,
    process.Subject(
      Result(#(BitArray, generation.GenerationAssociation), custody.Error),
    ),
  )

  /// Fixed trusted work intent retains its original UUID and eventual child slot.
  RetainSystemIntent(
    String,
    custody.SystemService,
    ids.OpId,
    String,
    ids.EntryId,
    BitArray,
    process.Subject(Result(custody.IntentReadback, custody.Error)),
  )

  /// The actor fixes service and association; lookup reconstructs no live token.
  LookupWorkspaceAdministrationIntent(
    String,
    process.Subject(Result(custody.IntentReadback, custody.Error)),
  )

  /// Only the existing pure closed-family encoder enters atomic system allocation.
  AdmitSystemChild(
    custody.IntentReadback,
    fn(remote_tool.ChildOrigin, ids.EntryId) ->
      Result(custody.SystemReservationPayload, custody.Error),
    process.Subject(Result(custody.SystemReservationReadback, custody.Error)),
  )

  Execute(
    remote_tool.ToolKey,
    custody.FinalProfile,
    BitArray,
    BitArray,
    effects.ToolRun,
    process.Subject(Result(effects.ToolOutcome, custody.Error)),
    process.Subject(Result(Nil, custody.Error)),
  )
  Lookup(
    remote_tool.ToolKey,
    BitArray,
    BitArray,
    process.Subject(Result(custody.Evidence, custody.Error)),
  )
  ReserveChild(
    remote_tool.ChildOrigin,
    ids.EntryId,
    BitArray,
    process.Subject(Result(#(ids.EntryId, BitArray), custody.Error)),
  )

  /// A configured, byte-bounded semantic invocation reservation.
  ReserveWorkspace(
    remote_tool.ChildOrigin,
    ids.EntryId,
    custody.WorkspaceRequest,
    process.Subject(Result(Nil, custody.Error)),
  )

  /// A configured, byte-bounded semantic completion custody transfer.
  ReceiveWorkspace(
    remote_tool.ChildOrigin,
    ids.EntryId,
    custody.WorkspaceCompletion,
    BitArray,
    process.Subject(Result(Nil, custody.Error)),
  )

  /// Exact outer service reservation; no transport or preparation is performed.
  ReserveService(
    custody.ServiceRequest,
    option.Option(service_input.CompilationContract),
    process.Subject(Result(Nil, custody.Error)),
  )

  /// Readback of the original physical service and its independent completion.
  ReadService(
    command.ServiceKey,
    process.Subject(
      Result(
        #(custody.ServiceRequest, option.Option(custody.Payload)),
        custody.Error,
      ),
    ),
  )

  /// Exact immutable command offer admission after original service comparison.
  AdmitOffer(
    custody.ServiceRequest,
    custody.CommandOfferPayload,
    process.Subject(Result(custody.Admission, custody.Error)),
  )

  /// Header-first readback of a retained command offer.
  ReadOffer(
    command.CommandRef,
    process.Subject(Result(custody.CommandOfferPayload, custody.Error)),
  )

  /// Indexed historical offer data, including exact cancelled evidence.
  ReadOfferForOrigin(
    remote_tool.ChildOrigin,
    process.Subject(Result(custody.CommandOfferPayload, custody.Error)),
  )

  /// Complete native content reserved only by the post-clearance caller.
  ReserveCommand(
    custody.CommandOfferPayload,
    ids.EntryId,
    custody.Payload,
    process.Subject(Result(#(ids.EntryId, custody.Payload), custody.Error)),
  )

  /// Readback preserves original native UUID/content and optional receipt.
  ReadCommand(
    command.CommandRef,
    process.Subject(
      Result(
        #(ids.EntryId, custody.Payload, option.Option(custody.Payload)),
        custody.Error,
      ),
    ),
  )

  /// One atomic fence across service, offers and allocated native commands.
  CancelService(command.ServiceKey, process.Subject(Result(Nil, custody.Error)))

  ReadChild(
    remote_tool.ChildOrigin,
    process.Subject(
      Result(#(ids.EntryId, BitArray, option.Option(BitArray)), custody.Error),
    ),
  )
  ReceiveChild(
    remote_tool.ChildOrigin,
    ids.EntryId,
    BitArray,
    process.Subject(Result(Nil, custody.Error)),
  )
  CancelChild(
    remote_tool.ChildOrigin,
    process.Subject(Result(Nil, custody.Error)),
  )
  Collect(
    remote_tool.ToolKey,
    storage.Storage(Nil),
    process.Subject(Result(Nil, custody.Error)),
  )

  /// Only an original pinned live run can commit a bounded complete report.
  RetainReport(
    remote_tool.ToolKey,
    report_value.CompleteReport,
    process.Subject(Result(report_value.ReportRef, custody.Error)),
  )

  /// Authenticated owner assembly supplies the session-bound report reference.
  ReadReportChunk(
    report_value.ReportRef,
    Int,
    process.Subject(Result(custody.ReportChunk, custody.Error)),
  )

  FenceRun(remote_tool.ToolKey, process.Subject(Result(Nil, custody.Error)))
  Reported(String, weft.Pulled(effects.ToolOutcome, Nil))
  Stop(process.Subject(Result(Nil, custody.Error)))
}

type Held {
  Held(
    key: remote_tool.ToolKey,
    original: effects.ToolRun,
    profile: custody.FinalProfile,
    reports: process.Subject(weft.Pulled(effects.ToolOutcome, Nil)),
    cancel: weft.Cancel,
    disposition: Disposition,
    reply: process.Subject(Result(effects.ToolOutcome, custody.Error)),
  )
}

type Disposition {
  AwaitingReport
  FinalCommitted(custody.Payload)
  Unresolved
}

type AdmissionState {
  Admitting
  RecoveryOnly
}

type State {
  State(
    config: Config,
    store: custody.Store,
    generation: GenerationCustody,
    live: Dict(String, Held),
    admission: AdmissionState,
    owner: Handle,
    self: process.Subject(Message),
    system_subject: process.Subject(dispatch.SystemReservationMessage),
    live_system: Dict(reference.Reference, OriginalSystemPending),
  )
}

/// Checks active capacity and a finite owner task lifetime.
///
/// ## Examples
///
/// ```gleam
/// // custodian.config(path, session, limits, 4, 60_000, remote_runner)
/// ```
pub fn config(
  path: String,
  session: ids.SessionId,
  limits: custody.Limits,
  active: Int,
  task_ms: Int,
  runner: fn(Handle, remote_tool.ToolKey, effects.ToolRun) ->
    effects.ToolOutcome,
) -> Result(Config, custody.Error) {
  case active > 0 && active <= 4 && task_ms > 0 && task_ms <= 86_400_000 {
    True ->
      Ok(Config(
        path:,
        session:,
        limits:,
        active:,
        task_ms:,
        sha256: option.None,
        placement: OrdinaryPlacement,
        runner:,
      ))
    False -> Error(custody.Invalid("invalid owner task capacity or lifetime"))
  }
}

/// Allocates an address outside every transport connection.
///
/// ## Examples
///
/// ```gleam
/// // let owner = custodian.new(names, config)
/// ```
pub fn new(names: registry.Registry, config: Config) -> Handle {
  Handle(
    registry.new_address(names),
    Reclaimable,
    config.path,
    config.placement,
    config.task_ms,
    config.limits,
  )
}

/// Configures report hashing through the existing trusted host SHA-256 function.
/// This constructor creates no storage-to-host dependency or hashing package.
///
/// ## Examples
///
/// `config_with_reports(path, session, limits, active, ms, runner, bootstrap.sha256)` supports explicit report profiles.
pub fn config_with_reports(
  path: String,
  session: ids.SessionId,
  limits: custody.Limits,
  active: Int,
  task_ms: Int,
  runner: fn(Handle, remote_tool.ToolKey, effects.ToolRun) ->
    effects.ToolOutcome,
  sha256: fn(BitArray) -> BitArray,
) -> Result(Config, custody.Error) {
  config(path, session, limits, active, task_ms, runner)
  |> result.map(fn(config) { Config(..config, sha256: option.Some(sha256)) })
}

/// Checks registered metadata without opening storage or granting live admission.
/// The trusted caller has already compared Describe with its immutable boot table.
/// This boundary independently checks full enrollment, registration and association.
///
/// ## Examples
///
/// `with_registered(config, pin, association, 1)` still starts no owner or executor.
pub fn with_registered(
  config: Config,
  pin: custody.EnrollmentPin,
  association: generation.GenerationAssociation,
  configured_first: Int,
) -> Result(Config, custody.Error) {
  let placement = RegisteredPlacement(pin, association, configured_first)
  use Nil <- result.try(validate_registered(config, placement))
  Ok(Config(..config, placement: placement))
}

/// Reads actual readiness after pin and association COMMIT/readback.
/// ReadyForActivation does not attest that the executor has activated this bundle.
///
/// ## Examples
///
/// Reopening the same generation returns `HistoryOnly`, never another live token.
pub fn registered(owner: Handle) -> Result(RegisteredBoot, custody.Error) {
  ask(owner, ReadRegistered)
}

/// Projects the original pinned owner and exact committed immutable metadata.
/// HistoryOnly has no value accepted by this function.
///
/// ## Examples
///
/// `registered_fields(ready)` supplies the original owner to registered dispatch.
pub fn registered_fields(
  ready: RegisteredOwner,
) -> #(Handle, custody.EnrollmentPin, generation.GenerationAssociation) {
  #(ready.owner, ready.pin, ready.association)
}

/// Resolves complete ToolKey history through its original generation association.
///
/// ## Examples
///
/// `tool_generation(owner, key)` never infers generation from the active owner.
pub fn tool_generation(
  owner: Handle,
  key: remote_tool.ToolKey,
) -> Result(generation.GenerationAssociation, custody.Error) {
  ask(owner, fn(reply) { ReadToolGeneration(key, reply) })
}

/// Resolves complete child provenance, including tool-free system origins.
///
/// ## Examples
///
/// `child_generation(owner, origin)` refuses an absent original link.
pub fn child_generation(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
) -> Result(generation.GenerationAssociation, custody.Error) {
  ask(owner, fn(reply) { ReadChildGeneration(origin, reply) })
}

/// Validates complete retained service identity before reading its generation.
///
/// ## Examples
///
/// `service_generation(owner, key)` preserves Original versus rewritten Compile.
pub fn service_generation(
  owner: Handle,
  key: command.ServiceKey,
) -> Result(generation.GenerationAssociation, custody.Error) {
  ask(owner, fn(reply) { ReadServiceGeneration(key, reply) })
}

/// Reads the exact committed child receipt and its independent generation link.
/// The caller compares full family result bytes before constructing network ACK.
///
/// ## Examples
///
/// `receipt_generation(owner, origin, id)` refuses a changed original UUID.
pub fn receipt_generation(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  request_id: ids.EntryId,
) -> Result(#(BitArray, generation.GenerationAssociation), custody.Error) {
  ask(owner, fn(reply) { ReadReceiptGeneration(origin, request_id, reply) })
}

/// Retains one trusted durable work address before any system child allocation.
/// History-only owners can inspect an exact intent but cannot insert a new one.
///
/// ## Examples
///
/// `retain_system_intent(owner, address, service, op, step, id, bytes)` mints no UUID.
pub fn retain_system_intent(
  owner: Handle,
  work_address: String,
  service: custody.SystemService,
  operation: ids.OpId,
  step: String,
  request_id: ids.EntryId,
  bytes: BitArray,
) -> Result(custody.IntentReadback, custody.Error) {
  use Nil <- result.try(input_bound(bytes, 131_072))
  ask(owner, fn(reply) {
    RetainSystemIntent(
      work_address,
      service,
      operation,
      step,
      request_id,
      bytes,
      reply,
    )
  })
}

/// Looks up one WorkspaceAdministration intent owned by this captured actor.
/// Original and historical registered actors expose their exact evidence; an
/// ordinary actor refuses. The returned value cannot allocate an unadmitted child.
///
/// ## Examples
///
/// `lookup_workspace_administration_intent(owner, address)` allocates no UUID.
@internal
pub fn lookup_workspace_administration_intent(
  owner: Handle,
  work_address: String,
) -> Result(custody.IntentReadback, custody.Error) {
  ask(owner, fn(reply) {
    LookupWorkspaceAdministrationIntent(work_address, reply)
  })
}

/// Allocates original system custody while pinning its actual event-subject owner.
/// Reclaimable handles cannot mint a local permission for a replacement actor.
///
/// ## Examples
///
/// `allocate_system_reservation(owner, intent, declaration, events)` may return history.
pub fn allocate_system_reservation(
  owner: Handle,
  intent: custody.IntentReadback,
  declaration: dispatch.SystemCommandDeclaration,
  events: process.Subject(event),
) -> Result(SystemReservationAllocation, custody.Error) {
  use Nil <- result.try(case owner.destination {
    Pinned(_, _) -> Ok(Nil)
    Reclaimable -> Error(custody.Frozen)
  })
  use caller <- result.try(
    process.subject_owner(events) |> result.replace_error(custody.Conflict),
  )
  use Nil <- result.try(exact(fn() { caller == process.self() }))
  use Nil <- result.try(declaration_bound(declaration))
  ask(owner, fn(reply) { AllocateSystem(intent, declaration, caller, reply) })
}

/// Checks that a local ref targets this exact original typed subject.
/// Equality of the owner PID alone would confuse subjects owned by one actor.
///
/// ## Examples
///
/// `system_ref_matches(owner, ref)` never resolves a reclaimable address.
pub fn system_ref_matches(
  owner: Handle,
  ref: dispatch.SystemReservationRef,
) -> Result(Nil, custody.Error) {
  let #(subject, _, origin, _) = dispatch.system_reservation_fields(ref)
  use Nil <- result.try(case owner.destination {
    Pinned(_, expected) -> exact(fn() { expected == subject })
    Reclaimable -> Error(custody.Frozen)
  })
  case remote_tool.child_fields(origin) {
    remote_tool.SystemFields(_, _, _) -> Ok(Nil)
    remote_tool.ToolFields(_, _) | remote_tool.WorkspaceCommandFields(_, _) ->
      Error(custody.Conflict)
  }
}

/// Cancels original retained work when allocation never returned a live ref.
///
/// ## Examples
///
/// `cancel_system_intent(owner, intent)` permanently allocates an unallocated ordinal.
pub fn cancel_system_intent(
  owner: Handle,
  intent: custody.IntentReadback,
) -> Result(Nil, custody.Error) {
  ask(owner, fn(reply) { CancelSystemIntent(intent, reply) })
}

/// Resolves original semantic custody from its exact UUID and full input bytes.
///
/// ## Examples
///
/// `resolve_semantic_parent(owner, uuid, input)` refuses cancelled parents.
pub fn resolve_semantic_parent(
  owner: Handle,
  request_id: ids.EntryId,
  bytes: BitArray,
) -> Result(custody.SemanticParent, custody.Error) {
  use Nil <- result.try(input_bound(bytes, 33_554_432))
  ask(owner, fn(reply) { ResolveSemanticParent(request_id, bytes, reply) })
}

/// Reserves a workspace-native envelope after exact retained-parent comparison.
/// Only the original actual Fresh insertion can return a sendable result.
///
/// ## Examples
///
/// `reserve_workspace_command(owner, parent, origin, uuid, bytes)` refuses replay.
pub fn reserve_workspace_command(
  owner: Handle,
  parent: custody.SemanticParent,
  origin: remote_tool.ChildOrigin,
  request_id: ids.EntryId,
  bytes: BitArray,
) -> Result(#(ids.EntryId, BitArray), custody.Error) {
  use Nil <- result.try(input_bound(bytes, 131_072))
  ask(owner, fn(reply) {
    ReserveWorkspaceCommand(parent, origin, request_id, bytes, reply)
  })
}

fn original_live(
  state: State,
) -> Result(custody.LiveGeneration, custody.Error) {
  case state.generation, state.admission {
    OriginalGeneration(live), Admitting -> Ok(live)
    _, _ -> Error(custody.Frozen)
  }
}

fn declaration_bound(
  declaration: dispatch.SystemCommandDeclaration,
) -> Result(Nil, custody.Error) {
  use _ <- result.try(
    workspace.step(declaration.step) |> result.replace_error(custody.Conflict),
  )
  use Nil <- result.try(
    exact(fn() {
      declaration.deadline_ms > 0
      && string.byte_size(declaration.owner) > 0
      && string.byte_size(declaration.owner) <= 128
      && declaration.argv != []
      && list.length(declaration.argv) <= 256
      && list.length(declaration.env) <= 256
      && string.byte_size(declaration.cwd) <= 8192
    }),
  )
  let size =
    list.fold(
      declaration.argv,
      string.byte_size(declaration.cwd)
        + string.byte_size(declaration.owner)
        + string.byte_size(declaration.step),
      fn(size, value) { size + string.byte_size(value) },
    )
  let size =
    list.fold(declaration.env, size, fn(size, pair) {
      size + string.byte_size(pair.0) + string.byte_size(pair.1)
    })
  exact(fn() { size <= 8192 })
}

fn allocate_system(
  state: State,
  intent: custody.IntentReadback,
  declaration: dispatch.SystemCommandDeclaration,
  caller: process.Pid,
) -> #(State, Result(SystemReservationAllocation, custody.Error)) {
  let allocated = {
    use _ <- result.try(original_live(state))
    use Nil <- result.try(declaration_bound(declaration))
    use associated <- result.try(current_association(state))
    let fields = custody.system_intent_fields(intent)
    use Nil <- result.try(
      exact(fn() {
        fields.0 == associated
        && fields.3 == declaration.operation
        && fields.4 == declaration.step
      }),
    )
    custody.allocate_native_system(state.store, intent)
  }
  case allocated {
    Error(error) -> #(state, Error(error))
    Ok(custody.RetainedPending(origin, request_id, stage)) -> #(
      state,
      Ok(SystemObservation(origin, request_id, stage)),
    )
    Ok(custody.FreshPending(pending)) -> {
      let #(origin, request_id, associated) =
        custody.pending_system_fields(pending)
      let reference = reference.new()
      let original =
        OriginalSystemPending(
          intent,
          declaration,
          caller,
          associated,
          origin,
          request_id,
          LivePending(pending),
        )
      let ref =
        dispatch.system_reservation_ref(
          state.system_subject,
          reference,
          origin,
          request_id,
        )
      #(
        State(
          ..state,
          live_system: dict.insert(state.live_system, reference, original),
        ),
        Ok(SystemPermission(ref)),
      )
    }
  }
}

fn handle_system_reservation(
  state: State,
  message: dispatch.SystemReservationMessage,
) -> actor.Next(State, Message) {
  case message {
    dispatch.ReserveSystem(ref, cleared, bytes, reply) -> {
      let #(state, outcome) =
        consume_system_reservation(state, ref, cleared, bytes)
      process.send(reply, outcome |> result.replace_error(Nil))
      resume(state)
    }
    dispatch.CancelSystem(ref, reply) -> {
      let #(subject, reference, origin, request_id) =
        dispatch.system_reservation_fields(ref)
      let original = {
        use Nil <- result.try(exact(fn() { subject == state.system_subject }))
        use original <- result.try(
          dict.get(state.live_system, reference)
          |> result.replace_error(custody.Missing),
        )
        use Nil <- result.try(
          exact(fn() {
            original.origin == origin && original.request_id == request_id
          }),
        )
        Ok(original)
      }
      case original {
        Error(_) -> {
          process.send(reply, Error(Nil))
          resume(state)
        }
        Ok(original) -> {
          let state =
            State(
              ..state,
              live_system: dict.insert(
                state.live_system,
                reference,
                OriginalSystemPending(..original, permission: SpentPending),
              ),
            )
          process.send(
            reply,
            custody.cancel_native_system(state.store, original.intent)
              |> result.replace_error(Nil),
          )
          resume(state)
        }
      }
    }
  }
}

fn consume_system_reservation(
  state: State,
  ref: dispatch.SystemReservationRef,
  cleared: dispatch.ClearedSystemCommand,
  bytes: BitArray,
) -> #(State, Result(#(ids.EntryId, BitArray), custody.Error)) {
  let #(subject, reference, origin, request_id) =
    dispatch.system_reservation_fields(ref)
  let found = {
    use Nil <- result.try(exact(fn() { subject == state.system_subject }))
    dict.get(state.live_system, reference)
    |> result.replace_error(custody.Missing)
  }
  case found {
    Error(error) -> #(state, Error(error))
    Ok(original) -> {
      // Consumption precedes validation and persistence, and survives every Result arm.
      let consumed =
        State(
          ..state,
          live_system: dict.insert(
            state.live_system,
            reference,
            OriginalSystemPending(..original, permission: SpentPending),
          ),
        )
      let admitted = {
        use _ <- result.try(original_live(consumed))
        use pending <- result.try(case original.permission {
          LivePending(pending) -> Ok(pending)
          SpentPending -> Error(custody.Frozen)
        })
        use Nil <- result.try(
          exact(fn() {
            original.origin == origin && original.request_id == request_id
          }),
        )
        use associated <- result.try(current_association(consumed))
        use Nil <- result.try(
          exact(fn() { associated == original.association }),
        )
        use Nil <- result.try(check_system_envelope(
          consumed,
          original,
          cleared,
          bytes,
        ))
        use payload <- result.try(custody.payload(consumed.config.limits, bytes))
        use stored <- result.try(custody.admit_pending_system(
          consumed.store,
          pending,
          payload,
        ))
        use Nil <- result.try(
          exact(fn() {
            stored.admission == custody.Fresh
            && stored.origin == origin
            && stored.request_id == request_id
          }),
        )
        use actual <- result.try(custody.child(consumed.store, origin))
        use Nil <- result.try(
          exact(fn() {
            actual.0 == request_id && custody.bytes(actual.1) == bytes
          }),
        )
        Ok(#(request_id, bytes))
      }
      #(consumed, admitted)
    }
  }
}

fn check_system_envelope(
  state: State,
  original: OriginalSystemPending,
  cleared: dispatch.ClearedSystemCommand,
  bytes: BitArray,
) -> Result(Nil, custody.Error) {
  use Nil <- result.try(input_bound(bytes, 131_072))
  let declared = original.declaration
  use Nil <- result.try(
    exact(fn() {
      cleared.operation == declared.operation
      && cleared.step == declared.step
      && cleared.deadline_ms == declared.deadline_ms
      && cleared.caller == option.Some(original.caller)
      && cleared.request.argv == declared.argv
      && cleared.request.env == declared.env
      && cleared.request.cwd == declared.cwd
    }),
  )
  let #(scope, _, _) =
    generation.key_fields(generation.association_key(original.association))
  use scope <- result.try(executor_scope(scope))
  use decoded <- result.try(
    native_envelope.decode_cleared(declared.owner, scope, bytes)
    |> result.replace_error(custody.Conflict),
  )
  use Nil <- result.try(
    exact(fn() {
      decoded.0 == cleared.operation
      && decoded.1.step == cleared.step
      && decoded.1.request == cleared.request
      && decoded.2 == cleared.deadline_ms
    }),
  )
  use enrolled <- result.try(case state.config.placement {
    RegisteredPlacement(pin, _, _) ->
      enrollment.decode(custody.enrollment_fields(pin).4)
      |> result.replace_error(custody.Conflict)
    OrdinaryPlacement -> Error(custody.Frozen)
  })
  let registration = enrollment.digests(enrolled).0
  let native = enrollment.native_facts(enrolled)
  use actual_policy <- result.try(option.to_result(
    cleared.request.policy,
    custody.Conflict,
  ))
  let #(composed, narrowings) =
    policy.compose(native.ceiling, actual_policy, [])
  use Nil <- result.try(case decoded.1.lifetime {
    wire.Finite(ms)
      if ms > 0
      && actual_policy.limits.wall_s > 0
      && actual_policy.limits.wall_s * 1000 <= ms
    -> Ok(Nil)
    wire.Finite(_) | wire.Session -> Error(custody.Conflict)
  })
  exact(fn() {
    string.lowercase(
      bit_array.base16_encode(identity.digest_bytes(decoded.1.registration)),
    )
    == registration
    && cleared.request.demand == native.demand
    && composed == actual_policy
    && narrowings == []
    && decoded.1.stream == wire.Logs
  })
}

/// Allocates through the existing serialized child/link/counter transaction.
/// The trusted encoder constructs closed native/workspace payloads and performs no I/O.
/// History retries return Retained; an unallocated historical intent is Frozen.
///
/// ## Examples
///
/// `admit_system_child(owner, retained, build)` never resets the lifetime counter.
pub fn admit_system_child(
  owner: Handle,
  intent: custody.IntentReadback,
  build: fn(remote_tool.ChildOrigin, ids.EntryId) ->
    Result(custody.SystemReservationPayload, custody.Error),
) -> Result(custody.SystemReservationReadback, custody.Error) {
  ask(owner, fn(reply) { AdmitSystemChild(intent, build, reply) })
}

/// Starts the actor; production embeds supervised instead.
///
/// ## Examples
///
/// ```gleam
/// // custodian.start(owner, config)
/// ```
pub fn start(
  owner: Handle,
  config: Config,
) -> actor.StartResult(process.Subject(Message)) {
  builder(owner, config) |> actor.start
}

/// Embeds journal custody under the session's existing supervisor.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(supervisor, custodian.supervised(owner, config))
/// ```
pub fn supervised(
  owner: Handle,
  config: Config,
) -> supervision.ChildSpecification(process.Subject(Message)) {
  builder(owner, config) |> actor.supervised
}

fn builder(owner: Handle, config: Config) {
  actor.new_with_initialiser(5000, fn(subject) {
    let original_path = case owner.placement {
      OrdinaryPlacement -> True
      RegisteredPlacement(_, _, _) -> owner.path == config.path
    }
    use Nil <- result.try(
      case owner.placement == config.placement && original_path {
        True -> Ok(Nil)
        False -> Error("owner placement or companion path changed before boot")
      },
    )
    use existed <- result.try(
      simplifile.exists(config.path, False)
      |> result.replace_error("owner custody placement unavailable"),
    )
    use store <- result.try(
      case config.sha256 {
        option.None -> custody.open(config.path, config.session, config.limits)
        option.Some(sha256) ->
          custody.open_with_reports(
            config.path,
            config.session,
            config.limits,
            sha256,
          )
      }
      |> result.replace_error("owner custody open failed"),
    )
    use generation <- result.try(
      boot_generation(config, store, case existed {
        True -> ExistingCompanion
        False -> NewCompanion
      })
      |> result.map_error(fn(_) {
        let _closed = custody.close(store)
        "registered owner pin or generation boot failed"
      }),
    )
    use Nil <- result.try(
      custody.validate_finals(store, fn(key, profile, reference, payload) {
        case profile {
          custody.OrdinaryFinal -> Ok(Nil)
          custody.CodeModeReportV1 -> {
            use final <- result.try(
              effects.decode_tool_outcome(custody.bytes(payload)),
            )
            use terminal <- result.try(
              custody.report_outcome(store, key)
              |> result.replace_error("report terminal lookup failed"),
            )
            use Nil <- result.try(outcome.validate_final(
              profile,
              reference,
              terminal,
              final,
            ))
            use request <- result.try(
              custody.original_request(store, key)
              |> result.replace_error("original request lookup failed"),
            )
            outcome.validate_original_request(request, final)
          }
        }
      })
      |> result.map_error(fn(_) {
        let _closed = custody.close(store)
        "owner final-report association failed"
      }),
    )
    use outstanding <- result.try(
      custody.unreleased(store)
      |> result.map_error(fn(_) {
        let _closed = custody.close(store)
        "owner custody discharge probe failed"
      }),
    )
    let admission = case outstanding, generation {
      custody.Released, OrdinaryCustody
      | custody.Released, OriginalGeneration(_)
      -> Admitting
      custody.Unreleased, _ | _, HistoricalGeneration(_) -> RecoveryOnly
    }
    let system_subject = process.new_subject()
    let pinned = Handle(..owner, destination: Pinned(subject, system_subject))
    Ok(
      actor.initialised(State(
        config:,
        store:,
        generation:,
        live: dict.new(),
        live_system: dict.new(),
        system_subject:,
        admission:,
        owner: pinned,
        self: subject,
      ))
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_map(system_subject, SystemReservation),
      )
      |> actor.returning(subject),
    )
  })
  |> actor.addressed(owner.address)
  |> actor.on_message(handle)
  |> actor.trapping_exits(True)
  |> actor.on_shutdown(fn(state, _reason) {
    list.each(dict.values(state.live), fn(held) { weft.cancel(held.cancel) })
    let _closed = custody.close(state.store)
    Nil
  })
}

/// Starts only a fresh admitted task, then awaits a bounded final ticket.
/// A timeout is uncertainty; the supervised owner retains committed evidence.
///
/// ## Examples
///
/// ```gleam
/// // custodian.execute(owner, key, arguments, request, original_run)
/// ```
pub fn execute(
  owner: Handle,
  key: remote_tool.ToolKey,
  arguments: BitArray,
  request: BitArray,
  original: effects.ToolRun,
) -> Result(effects.ToolOutcome, custody.Error) {
  execute_with_profile(
    owner,
    key,
    arguments,
    request,
    original,
    custody.OrdinaryFinal,
  )
}

/// Starts only a Fresh original run under its trusted immutable final profile.
///
/// ## Examples
///
/// `execute_with_profile(owner, key, args, request, original, custody.CodeModeReportV1)` never derives profile from the call name.
pub fn execute_with_profile(
  owner: Handle,
  key: remote_tool.ToolKey,
  arguments: BitArray,
  request: BitArray,
  original: effects.ToolRun,
  profile: custody.FinalProfile,
) -> Result(effects.ToolOutcome, custody.Error) {
  use Nil <- result.try(input_bound(arguments, 262_144))
  use Nil <- result.try(input_bound(request, 262_144))
  let ticket = process.new_subject()
  use Nil <- result.try(
    ask(owner, fn(reply) {
      Execute(key, profile, arguments, request, original, ticket, reply)
    }),
  )
  process.receive(ticket, owner.task_ms + 1000)
  |> result.unwrap(Error(custody.Unavailable("owner final ticket timed out")))
}

/// Checks exact immutable request bytes before exposing final or child evidence.
/// Missing evidence never grants fresh execution permission.
///
/// ## Examples
///
/// ```gleam
/// // custodian.lookup(owner, key, arguments, request)
/// ```
pub fn lookup(
  owner: Handle,
  key: remote_tool.ToolKey,
  arguments: BitArray,
  request: BitArray,
) -> Result(custody.Evidence, custody.Error) {
  use Nil <- result.try(input_bound(arguments, 262_144))
  use Nil <- result.try(input_bound(request, 262_144))
  ask(owner, fn(reply) { Lookup(key, arguments, request, reply) })
}

/// Reserves once or returns the original UUID and exact request on retry.
/// Root mints proposed_id outside connections; retained origins ignore a new
/// candidate only after exact parent identity and request equality checks.
///
/// ## Examples
///
/// ```gleam
/// // custodian.reserve_child(owner, original_origin, proposed_id, request)
/// ```
pub fn reserve_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  proposed_id: ids.EntryId,
  request: BitArray,
) -> Result(#(ids.EntryId, BitArray), custody.Error) {
  use Nil <- result.try(input_bound(request, 131_072))
  ask(owner, fn(reply) { ReserveChild(origin, proposed_id, request, reply) })
}

/// Reserves exact workspace invocation bytes with their original UUID.
/// Both semantic and configured byte limits are checked before mailbox send.
/// A concurrent candidate with another UUID conflicts, rather than executing.
///
/// ## Examples
///
/// `reserve_workspace_child(owner, origin, id, bytes)` commits before send.
pub fn reserve_workspace_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
  request: BitArray,
) -> Result(Nil, custody.Error) {
  use request <- result.try(custody.workspace_request(owner.limits, request))
  ask(owner, fn(reply) { ReserveWorkspace(origin, id, request, reply) })
}

/// Commits exact workspace completion bytes before returning durable custody.
/// The configured byte quota is checked before bytes enter the owner mailbox.
///
/// ## Examples
///
/// `receive_workspace_child(owner, origin, id, bytes)` permits an exact duplicate.
pub fn receive_workspace_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
  receipt: BitArray,
) -> Result(Nil, custody.Error) {
  let bytes = receipt
  use receipt <- result.try(custody.workspace_completion(owner.limits, bytes))
  ask(owner, fn(reply) { ReceiveWorkspace(origin, id, receipt, bytes, reply) })
}

/// Commits complete original Compile/Launch input before preparation or send.
/// Bound checks precede the mailbox; the original service UUID is never minted here.
///
/// ## Examples
///
/// `reserve_service_child(owner, key, input)` returns only after the commit.
pub fn reserve_service_child(
  owner: Handle,
  key: command.ServiceKey,
  input: BitArray,
) -> Result(custody.ServiceRequest, custody.Error) {
  use request <- result.try(custody.service_request(owner.limits, key, input))
  use Nil <- result.try(
    ask(owner, fn(reply) { ReserveService(request, option.None, reply) }),
  )
  Ok(request)
}

/// Reserves Compile only after checking immutable predecessor evidence locally.
/// The contract is fixed administrative assembly, never decoded peer authority.
///
/// ## Examples
///
/// `reserve_compile_child(owner, key, bytes, contract)` checks rewrite lineage
/// in the original owner actor before any new durable child admission.
pub fn reserve_compile_child(
  owner: Handle,
  key: command.ServiceKey,
  input: BitArray,
  contract: service_input.CompilationContract,
) -> Result(custody.ServiceRequest, custody.Error) {
  use request <- result.try(custody.service_request(owner.limits, key, input))
  use Nil <- result.try(
    ask(owner, fn(reply) {
      ReserveService(request, option.Some(contract), reply)
    }),
  )
  Ok(request)
}

/// Retrieves the exact original service and independent completion custody.
///
/// ## Examples
///
/// `service_child(owner, key)` never grants a second service execution.
pub fn service_child(
  owner: Handle,
  key: command.ServiceKey,
) -> Result(
  #(custody.ServiceRequest, option.Option(custody.Payload)),
  custody.Error,
) {
  ask(owner, fn(reply) { ReadService(key, reply) })
}

/// Commits an exact immutable offer after the original service input comparison.
/// A capacity refusal leaves the executor responsible for retaining its offer.
///
/// ## Examples
///
/// `admit_offer(owner, original, offer)` returns Retained for an exact duplicate.
pub fn admit_offer(
  owner: Handle,
  original: custody.ServiceRequest,
  offer: custody.CommandOfferPayload,
) -> Result(custody.Admission, custody.Error) {
  use _ <- result.try(custody.workspace_request(
    owner.limits,
    custody.service_content(original),
  ))
  let #(ref, digest) = custody.offer_identity(offer)
  use offer <- result.try(custody.command_offer_payload(
    owner.limits,
    ref,
    digest,
    custody.offer_content(offer),
  ))
  ask(owner, fn(reply) { AdmitOffer(original, offer, reply) })
}

/// Retrieves the original retained offer without allocating native identity.
///
/// ## Examples
///
/// `offer(owner, ref)` refuses changed identity and cancelled authority.
pub fn offer(
  owner: Handle,
  ref: command.CommandRef,
) -> Result(custody.CommandOfferPayload, custody.Error) {
  ask(owner, fn(reply) { ReadOffer(ref, reply) })
}

/// Reads a complete historical offer through its original native origin.
/// The existing five-second custodian ask grants no live clearance or reservation.
/// Exact cancellation history remains available; frozen evidence refuses.
///
/// ## Examples
///
/// `command_offer_for_origin(owner, command.native_origin(ref))` reads retained
/// identity and bytes after cancellation without allocating a native UUID.
pub fn command_offer_for_origin(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
) -> Result(custody.CommandOfferPayload, custody.Error) {
  ask(owner, fn(reply) { ReadOfferForOrigin(origin, reply) })
}

/// Reserves COMPLETE post-clearance native content under the original offer.
/// Exact duplicates return the original UUID, even with another candidate.
///
/// ## Examples
///
/// `reserve_command_child(owner, offer, id, prepared)` commits before native send.
pub fn reserve_command_child(
  owner: Handle,
  offer: custody.CommandOfferPayload,
  candidate: ids.EntryId,
  prepared: BitArray,
) -> Result(#(ids.EntryId, custody.Payload), custody.Error) {
  let #(ref, digest) = custody.offer_identity(offer)
  use offer <- result.try(custody.command_offer_payload(
    owner.limits,
    ref,
    digest,
    custody.offer_content(offer),
  ))
  use request <- result.try(custody.payload(owner.limits, prepared))
  ask(owner, fn(reply) { ReserveCommand(offer, candidate, request, reply) })
}

/// Retrieves original complete native evidence for reconciliation after loss.
///
/// ## Examples
///
/// `command_child(owner, ref)` never re-clears uncertain native execution.
pub fn command_child(
  owner: Handle,
  ref: command.CommandRef,
) -> Result(
  #(ids.EntryId, custody.Payload, option.Option(custody.Payload)),
  custody.Error,
) {
  ask(owner, fn(reply) { ReadCommand(ref, reply) })
}

/// Atomically fences outer service, immutable offers and allocated native rows.
/// Persistence failure requires the caller's existing fatal assembly fence.
///
/// ## Examples
///
/// `cancel_service(owner, key)` preserves the original native bytes for late receipt.
pub fn cancel_service(
  owner: Handle,
  key: command.ServiceKey,
) -> Result(Nil, custody.Error) {
  ask(owner, fn(reply) { CancelService(key, reply) })
}

/// Retrieves stable UUID, outgoing bytes and optional exact child receipt.
///
/// ## Examples
///
/// ```gleam
/// // custodian.child(owner, original_origin)
/// ```
pub fn child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
) -> Result(#(ids.EntryId, BitArray, option.Option(BitArray)), custody.Error) {
  ask(owner, fn(reply) { ReadChild(origin, reply) })
}

/// Commits exact child result bytes before the dispatcher advertises receipt.
///
/// ## Examples
///
/// ```gleam
/// // custodian.receive_child(owner, origin, id, receipt)
/// ```
pub fn receive_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
  receipt: BitArray,
) -> Result(Nil, custody.Error) {
  use Nil <- result.try(input_bound(receipt, 2_097_152))
  ask(owner, fn(reply) { ReceiveChild(origin, id, receipt, reply) })
}

/// Encodes bounded ordered output and terminal bytes without text conversion.
/// Each encoded remote output is retained byte for byte with its boundary.
///
/// ## Examples
///
/// ```gleam
/// // custodian.receipt(outputs, terminal)
/// ```
pub fn receipt(
  outputs: List(BitArray),
  terminal: BitArray,
) -> Result(BitArray, custody.Error) {
  use Nil <- result.try(input_bound(terminal, 32_768))
  let within =
    list.fold(outputs, #(0, 0), fn(acc, bytes) {
      #(acc.0 + 1, acc.1 + bit_array.byte_size(bytes))
    })
  use Nil <- result.try(case within.0 <= 64 && within.1 <= 1_048_576 {
    True -> Ok(Nil)
    False -> Error(custody.Capacity)
  })
  use _ <- result.try(
    list.try_map(outputs, fn(bytes) { input_bound(bytes, 16_384) }),
  )
  msgpack.encode(
    msgpack.ArrayValue([
      msgpack.ArrayValue(list.map(outputs, msgpack.BinaryValue)),
      msgpack.BinaryValue(terminal),
    ]),
  )
  |> result.replace_error(custody.Invalid("invalid exact child receipt"))
}

/// Durably fences the same original origin, including before UUID reservation.
/// A refusal must stop managed dispatch; it is not an acknowledged cancel.
///
/// ## Examples
///
/// ```gleam
/// // custodian.cancel_child(owner, original_origin)
/// ```
pub fn cancel_child(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
) -> Result(Nil, custody.Error) {
  ask(owner, fn(reply) { CancelChild(origin, reply) })
}

/// Reads actual reserved session storage and collects only an exact handoff.
/// ToolFailed records stay retained because their synthetic message is not exact.
///
/// ## Examples
///
/// ```gleam
/// // custodian.collect(owner, key, actual_session_storage)
/// ```
pub fn collect(
  owner: Handle,
  key: remote_tool.ToolKey,
  source: storage.Storage(a),
) -> Result(Nil, custody.Error) {
  let erased =
    storage.Storage(
      handle: Nil,
      commit: fn(_, tx) { storage.commit(source, tx) },
      get_entries: fn(_, ids) { storage.get_entries(source, ids) },
      get_register: fn(_, ns, key) { storage.get_register(source, ns, key) },
      list_registers: fn(_, ns, prefix) {
        storage.list_registers(source, ns, prefix)
      },
      scan_branch: fn(_, query) { storage.scan_branch(source, query) },
      scan_entries: fn(_, query) { storage.scan_entries(source, query) },
      scan_entry_heads: fn(_, query) { storage.scan_entry_heads(source, query) },
      scan_usage: fn(_, query) { storage.scan_usage(source, query) },
      stats: fn(_) { storage.stats(source) },
      close: fn(_) { storage.close(source) },
    )
  ask(owner, fn(reply) { Collect(key, erased, reply) })
}

/// Stops journal ownership after requesting cancellation of active weft runs.
/// This is not a native retirement witness and grants no collection authority.
///
/// ## Examples
///
/// ```gleam
/// // custodian.stop(owner)
/// ```
pub fn stop(owner: Handle) -> Result(Nil, custody.Error) {
  ask(owner, Stop)
}

/// Permanently fences the current run after an unresolved consumer failure.
/// A later ordinary outcome can be retained but cannot discharge this incarnation.
///
/// ## Examples
///
/// `fatal_fence(owner, key)` must use the pinned handle supplied to the runner.
pub fn fatal_fence(
  owner: Handle,
  key: remote_tool.ToolKey,
) -> Result(Nil, custody.Error) {
  ask(owner, fn(reply) { FenceRun(key, reply) })
}

/// Commits a checked report through the original live pinned custodian.
/// Any error or lost reply fences the original run before returning uncertainty.
///
/// ## Examples
///
/// `retain_report(pinned_owner, original_key, report)` precedes bounded final rendering.
pub fn retain_report(
  owner: Handle,
  key: remote_tool.ToolKey,
  report: report_value.CompleteReport,
) -> Result(report_value.ReportRef, custody.Error) {
  case owner.destination {
    Reclaimable -> Error(custody.Conflict)
    Pinned(_, _) -> {
      let retained = ask(owner, fn(reply) { RetainReport(key, report, reply) })
      case retained {
        Ok(reference) -> Ok(reference)
        Error(error) -> {
          let _fenced = fatal_fence(owner, key)
          Error(error)
        }
      }
    }
  }
}

/// Reads one aligned bounded chunk through this session's existing owner door.
/// The caller's authenticated assembly, rather than the URI, grants access.
///
/// ## Examples
///
/// `read_report_chunk(owner, reference, 0)` never contacts an executor filesystem.
pub fn read_report_chunk(
  owner: Handle,
  reference: report_value.ReportRef,
  offset: Int,
) -> Result(custody.ReportChunk, custody.Error) {
  ask(owner, fn(reply) { ReadReportChunk(reference, offset, reply) })
}

fn ask(
  owner: Handle,
  message: fn(process.Subject(Result(a, custody.Error))) -> Message,
) -> Result(a, custody.Error) {
  use subject <- result.try(
    case owner.destination {
      Reclaimable -> registry.lookup(owner.address)
      Pinned(subject, _) -> Ok(subject)
    }
    |> result.replace_error(custody.Unavailable(
      "owner not supervised or unavailable",
    )),
  )
  call.try_call(subject, waiting: 5000, sending: message)
  |> result.unwrap(Error(custody.Unavailable("owner ask failed")))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    SystemReservation(message) -> handle_system_reservation(state, message)
    AllocateSystem(intent, declaration, caller, reply) -> {
      let #(state, outcome) =
        allocate_system(state, intent, declaration, caller)
      process.send(reply, outcome)
      resume(state)
    }
    CancelSystemIntent(intent, reply) -> {
      process.send(reply, custody.cancel_native_system(state.store, intent))
      resume(state)
    }
    ReadSemanticEvidence(origin, reply) -> {
      process.send(reply, custody.semantic_evidence(state.store, origin))
      resume(state)
    }
    ResolveSemanticParent(id, bytes, reply) -> {
      let outcome = {
        use live <- result.try(original_live(state))
        custody.semantic_parent(state.store, live, id, bytes)
      }
      process.send(reply, outcome)
      resume(state)
    }
    ReserveWorkspaceCommand(parent, origin, id, bytes, reply) -> {
      let outcome = {
        use _ <- result.try(original_live(state))
        use request <- result.try(custody.payload(state.config.limits, bytes))
        use admitted <- result.try(custody.admit_workspace_command(
          state.store,
          parent,
          origin,
          id,
          request,
        ))
        use Nil <- result.try(case admitted {
          custody.Fresh -> Ok(Nil)
          custody.Retained -> Error(custody.Frozen)
        })
        use readback <- result.try(custody.child(state.store, origin))
        use Nil <- result.try(
          exact(fn() { readback.0 == id && custody.bytes(readback.1) == bytes }),
        )
        Ok(#(id, bytes))
      }
      process.send(reply, outcome)
      resume(state)
    }
    ReadRegistered(reply) -> {
      process.send(reply, registered_readback(state))
      resume(state)
    }
    ReadToolGeneration(key, reply) -> {
      process.send(reply, custody.tool_generation(state.store, key))
      resume(state)
    }
    ReadChildGeneration(origin, reply) -> {
      process.send(reply, custody.child_generation(state.store, origin))
      resume(state)
    }
    ReadServiceGeneration(key, reply) -> {
      let readback = {
        use _ <- result.try(custody.service_child(state.store, key))
        custody.child_generation(state.store, command.service_origin(key))
      }
      process.send(reply, readback)
      resume(state)
    }
    ReadReceiptGeneration(origin, id, reply) -> {
      process.send(reply, receipt_readback(state, origin, id))
      resume(state)
    }
    RetainSystemIntent(address, service, op, step, id, bytes, reply) -> {
      process.send(
        reply,
        retain_intent(state, address, service, op, step, id, bytes),
      )
      resume(state)
    }
    LookupWorkspaceAdministrationIntent(address, reply) -> {
      let readback = {
        use association <- result.try(current_association(state))
        custody.lookup_system_intent(
          state.store,
          association,
          address,
          custody.WorkspaceAdministration,
        )
      }
      process.send(reply, readback)
      resume(state)
    }
    AdmitSystemChild(intent, build, reply) -> {
      let admitted = {
        use associated <- result.try(current_association(state))
        use Nil <- result.try(
          exact(fn() { associated == custody.system_intent_fields(intent).0 }),
        )
        use intent <- result.try(reconciliation_intent(state, intent))
        custody.admit_system_child(state.store, intent, build)
      }
      process.send(reply, admitted)
      resume(state)
    }
    Execute(key, profile, args, request, original, ticket, reply) ->
      begin(state, key, profile, args, request, original, ticket, reply)
    Lookup(key, args, request, reply) -> {
      let outcome = {
        use args <- result.try(custody.payload(state.config.limits, args))
        use request <- result.try(custody.payload(state.config.limits, request))
        use Nil <- result.try(custody.validate_request(
          state.store,
          key,
          args,
          request,
        ))
        custody.lookup(state.store, key)
      }
      process.send(reply, outcome)
      resume(state)
    }
    ReserveChild(origin, candidate, request, reply) -> {
      process.send(reply, reserve(state, origin, candidate, request))
      resume(state)
    }
    ReserveWorkspace(origin, id, request, reply) -> {
      process.send(reply, reserve_workspace(state, origin, id, request))
      resume(state)
    }
    ReceiveWorkspace(origin, id, receipt, bytes, reply) -> {
      let committed = {
        use Nil <- result.try(custody.receive_workspace_child(
          state.store,
          origin,
          id,
          receipt,
        ))
        verify_receipt_readback(state, origin, id, bytes)
      }
      process.send(reply, committed)
      resume(state)
    }
    ReserveService(request, contract, reply) -> {
      let checked = {
        use Nil <- result.try(check_compile_reservation(
          state.store,
          request,
          contract,
        ))
        reserve_service(state, request)
      }
      process.send(reply, checked)
      resume(state)
    }
    ReadService(key, reply) -> {
      process.send(reply, custody.service_child(state.store, key))
      resume(state)
    }
    AdmitOffer(original, offer, reply) -> {
      process.send(reply, reserve_offer(state, original, offer))
      resume(state)
    }
    ReadOffer(ref, reply) -> {
      process.send(reply, custody.offer(state.store, ref))
      resume(state)
    }
    ReadOfferForOrigin(origin, reply) -> {
      process.send(reply, custody.command_offer_for_origin(state.store, origin))
      resume(state)
    }
    ReserveCommand(offer, candidate, request, reply) -> {
      process.send(reply, reserve_command(state, offer, candidate, request))
      resume(state)
    }
    ReadCommand(ref, reply) -> {
      process.send(reply, custody.command_child(state.store, ref))
      resume(state)
    }
    CancelService(key, reply) -> {
      process.send(reply, custody.cancel_service(state.store, key))
      resume(state)
    }
    ReadChild(origin, reply) -> {
      process.send(
        reply,
        custody.child(state.store, origin)
          |> result.map(fn(row) {
            #(row.0, custody.bytes(row.1), option.map(row.2, custody.bytes))
          }),
      )
      resume(state)
    }
    ReceiveChild(origin, id, bytes, reply) -> {
      let outcome = {
        use payload <- result.try(custody.payload(state.config.limits, bytes))
        use Nil <- result.try(custody.receive_child(
          state.store,
          origin,
          id,
          payload,
        ))
        verify_receipt_readback(state, origin, id, bytes)
      }
      process.send(reply, outcome)
      resume(state)
    }
    CancelChild(origin, reply) -> {
      process.send(reply, custody.cancel_child(state.store, origin))
      resume(state)
    }
    Collect(key, source, reply) -> {
      let outcome = {
        use proof <- result.try(custody.verify_commit(
          state.store,
          key,
          source,
          outcome.validate_commit,
        ))
        custody.collect(state.store, proof)
      }
      process.send(reply, outcome)
      resume(state)
    }
    RetainReport(key, report, reply) -> {
      let address = remote_tool.address(key)
      case dict.get(state.live, address) {
        Ok(held)
          if held.key == key && held.profile == custody.CodeModeReportV1
        -> {
          let result = custody.retain_report(state.store, key, report)
          let next = case result {
            Ok(_) -> state
            Error(_) ->
              unresolved(
                state,
                address,
                held,
                "complete report retention failed",
              )
          }
          process.send(reply, result)
          resume(next)
        }
        Ok(_) | Error(_) -> {
          process.send(reply, Error(custody.Conflict))
          resume(state)
        }
      }
    }
    ReadReportChunk(reference, offset, reply) -> {
      process.send(
        reply,
        custody.read_report_chunk(state.store, reference, offset),
      )
      resume(state)
    }
    FenceRun(key, reply) -> {
      let address = remote_tool.address(key)
      let state = case dict.get(state.live, address) {
        Ok(held) -> {
          process.send(reply, Ok(Nil))
          unresolved(state, address, held, "owner consumer fatal fence")
        }
        Error(Nil) -> {
          process.send(reply, Error(custody.Missing))
          State(
            ..state,
            admission: RecoveryOnly,
            live_system: dict.map_values(state.live_system, fn(_, original) {
              OriginalSystemPending(..original, permission: SpentPending)
            }),
          )
        }
      }
      resume(state)
    }
    Reported(address, report) -> resume(reported(state, address, report))
    Stop(reply) -> {
      process.send(reply, Ok(Nil))
      actor.stop()
    }
  }
}

fn begin(
  state: State,
  key: remote_tool.ToolKey,
  profile: custody.FinalProfile,
  args: BitArray,
  request: BitArray,
  original: effects.ToolRun,
  ticket: process.Subject(Result(effects.ToolOutcome, custody.Error)),
  reply: process.Subject(Result(Nil, custody.Error)),
) -> actor.Next(State, Message) {
  let admitted = {
    use Nil <- result.try(
      outcome.validate_admission(profile, original)
      |> result.map_error(custody.Invalid),
    )
    use Nil <- result.try(case profile {
      custody.OrdinaryFinal -> Ok(Nil)
      custody.CodeModeReportV1 ->
        outcome.validate_request_identity(
          request,
          original.call.id,
          original.call.name,
        )
        |> result.map_error(custody.Invalid)
    })
    use args <- result.try(custody.payload(state.config.limits, args))
    use request <- result.try(custody.payload(state.config.limits, request))
    use Nil <- result.try(
      case
        state.admission == Admitting
        && dict.size(state.live) < state.config.active
      {
        True -> Ok(Nil)
        False -> Error(custody.Capacity)
      },
    )
    reserve_tool(state, key, args, request, profile)
  }
  case admitted {
    Ok(custody.Fresh) -> {
      let runner = state.config.runner
      let pinned = state.owner
      let owner_pid = process.self()
      let reports = process.new_subject()
      let cancel = weft.cancel_signal()
      let _relay =
        weft.new_prepared([
          weft.managed(fn(_ledger) { Ok(runner(pinned, key, original)) }),
        ])
        |> weft.cancel_when_exits(owner_pid)
        |> weft.cancel_with(cancel)
        |> weft.deadline(state.config.task_ms)
        |> weft.start_relayed(to: reports)
      process.send(reply, Ok(Nil))
      resume(
        State(
          ..state,
          live: dict.insert(
            state.live,
            remote_tool.address(key),
            Held(
              key,
              original,
              profile,
              reports,
              cancel,
              AwaitingReport,
              ticket,
            ),
          ),
        ),
      )
    }
    Ok(custody.Retained) -> {
      process.send(
        reply,
        Error(custody.Invalid("retained admission cannot rerun tool body")),
      )
      resume(state)
    }
    Error(error) -> {
      process.send(reply, Error(error))
      resume(state)
    }
  }
}

fn reserve(
  state: State,
  origin: remote_tool.ChildOrigin,
  candidate: ids.EntryId,
  request: BitArray,
) -> Result(#(ids.EntryId, BitArray), custody.Error) {
  use payload <- result.try(custody.payload(state.config.limits, request))
  use original_id <- result.try(case custody.child(state.store, origin) {
    Ok(#(id, _, _)) -> Ok(id)
    Error(custody.Missing) -> Ok(candidate)
    Error(error) -> Error(error)
  })
  use Nil <- result.try(case state.generation, state.admission {
    OrdinaryCustody, _ ->
      custody.admit_child(state.store, origin, original_id, payload)
    OriginalGeneration(live), Admitting ->
      custody.admit_registered_child(
        state.store,
        live,
        origin,
        original_id,
        payload,
      )
      |> result.replace(Nil)
    HistoricalGeneration(_), _ | OriginalGeneration(_), RecoveryOnly ->
      Error(custody.Frozen)
  })
  use stored <- result.try(custody.child(state.store, origin))
  Ok(#(stored.0, custody.bytes(stored.1)))
}

// The selector retains the report subject until weft confirms all delivery.
// Dropping it at the first result would lose the drain notification and make
// finished task slots appear available before their owner scope has retired.
fn resume(state: State) -> actor.Next(State, Message) {
  let selector =
    list.fold(
      dict.to_list(state.live),
      process.new_selector()
        |> process.select(state.self)
        |> process.select_map(state.system_subject, SystemReservation),
      fn(selector, row) {
        let #(address, held) = row
        process.select_map(selector, held.reports, fn(report) {
          Reported(address, report)
        })
      },
    )
  actor.continue(state) |> actor.with_selector(selector)
}

fn reported(
  state: State,
  address: String,
  report: weft.Pulled(effects.ToolOutcome, Nil),
) -> State {
  case dict.get(state.live, address) {
    Error(Nil) -> state
    Ok(held) -> report_held(state, address, held, report)
  }
}

fn report_held(
  state: State,
  address: String,
  held: Held,
  report: weft.Pulled(effects.ToolOutcome, Nil),
) -> State {
  case report {
    weft.PulledOutcome(weft.Completed(_, value)) -> {
      let committed = {
        use Nil <- result.try(
          outcome.validate_outcome(held.original, value)
          |> result.map_error(custody.Invalid),
        )
        use reference <- result.try(custody.report_reference(
          state.store,
          held.key,
        ))
        use terminal <- result.try(custody.report_outcome(state.store, held.key))
        use Nil <- result.try(
          outcome.validate_final(held.profile, reference, terminal, value)
          |> result.map_error(custody.Invalid),
        )
        use bytes <- result.try(
          effects.encode_tool_outcome(value)
          |> result.map_error(custody.Invalid),
        )
        use payload <- result.try(custody.final_payload(
          state.config.limits,
          held.profile,
          bytes,
        ))
        use Nil <- result.try(custody.finish_with_reference(
          state.store,
          held.key,
          payload,
          reference,
        ))
        Ok(#(value, payload))
      }
      case committed {
        Ok(#(value, payload)) -> {
          // A generic diagnostic says nothing about whether code ran. The report
          // profile keeps that durable diagnostic without granting live discharge.
          case held.profile, value {
            custody.CodeModeReportV1, effects.ToolFailed(_) ->
              unresolved(
                state,
                address,
                held,
                "complete report absent; generic diagnostic retains uncertainty",
              )
            custody.OrdinaryFinal, _
            | custody.CodeModeReportV1, effects.ToolCompleted(..)
            ->
              answer_once(
                state,
                address,
                held,
                Ok(value),
                FinalCommitted(payload),
              )
          }
        }
        Error(error) ->
          answer_once(state, address, held, Error(error), Unresolved)
          |> fence_admission
      }
    }
    weft.PulledOutcome(weft.Failed(..))
    | weft.PulledOutcome(weft.Crashed(..))
    | weft.PulledOutcome(weft.Abandoned(..))
    | weft.PulledOutcome(weft.NeverStarted(..))
    | weft.PulledOutcome(weft.DrainProofLost(..))
    | weft.PulledOutcome(weft.CancellationUnconfirmed(..)) ->
      unresolved(
        state,
        address,
        held,
        "owner worker lost; exact final report unknown",
      )

    // Only this live run's complete delivery can release exact committed bytes.
    // Failure leaves the durable marker and the in-memory slot occupied.
    weft.AllDelivered -> {
      case held.disposition {
        FinalCommitted(payload) -> {
          case custody.discharge(state.store, held.key, payload) {
            Ok(Nil) -> State(..state, live: dict.delete(state.live, address))
            Error(_) ->
              unresolved(state, address, held, "owner discharge commit failed")
          }
        }
        AwaitingReport | Unresolved ->
          unresolved(
            state,
            address,
            held,
            "owner completed without releasable report",
          )
      }
    }
    weft.RunLost(_) ->
      unresolved(
        state,
        address,
        held,
        "owner run lost; exact final report unknown",
      )
    weft.NotYet -> state
  }
}

fn answer_once(
  state: State,
  address: String,
  held: Held,
  result: Result(effects.ToolOutcome, custody.Error),
  disposition: Disposition,
) -> State {
  case held.disposition {
    FinalCommitted(_) | Unresolved -> state
    AwaitingReport -> {
      process.send(held.reply, result)
      State(
        ..state,
        live: dict.insert(state.live, address, Held(..held, disposition:)),
      )
    }
  }
}

// The owner holds this sticky fence because a dead worker cannot fence itself.
fn unresolved(
  state: State,
  address: String,
  held: Held,
  reason: String,
) -> State {
  let state =
    answer_once(
      state,
      address,
      held,
      Error(custody.Unavailable(reason)),
      Unresolved,
    )
  State(
    ..state,
    admission: RecoveryOnly,
    live: dict.insert(
      state.live,
      address,
      Held(..held, disposition: Unresolved),
    ),
  )
}

fn fence_admission(state: State) -> State {
  State(..state, admission: RecoveryOnly)
}

fn input_bound(bytes: BitArray, maximum: Int) -> Result(Nil, custody.Error) {
  case
    bit_array.bit_size(bytes) % 8 == 0 && bit_array.byte_size(bytes) <= maximum
  {
    True -> Ok(Nil)
    False -> Error(custody.Capacity)
  }
}

// Immutable retained rows make validation stable until the following admission.
// Neither transport input nor a caller's diagnostic can supply the predecessor.
fn check_compile_reservation(
  store: custody.Store,
  request: custody.ServiceRequest,
  contract: option.Option(service_input.CompilationContract),
) -> Result(Nil, custody.Error) {
  let key = custody.service_identity(request)
  case command.compile_predecessor(key), contract {
    option.None, _ -> Ok(Nil)
    option.Some(_), option.None ->
      Error(custody.Invalid("rewrite requires checked Compile reservation"))
    option.Some(previous), option.Some(contract) -> {
      let enrolled = service_input.contract_enrolled(contract)
      use next <- result.try(
        compile_wire.decode_input(enrolled, custody.service_content(request))
        |> result.replace_error(custody.Conflict),
      )
      use retained <- result.try(custody.service_child(store, previous))
      use original <- result.try(
        compile_wire.decode_input(enrolled, custody.service_content(retained.0))
        |> result.replace_error(custody.Conflict),
      )
      use bytes <- result.try(option.to_result(retained.1, custody.Conflict))
      use completed <- result.try(
        compile_completion.decode(enrolled, previous, custody.bytes(bytes))
        |> result.replace_error(custody.Conflict),
      )
      use failed <- result.try(
        case compile_completion.compiled(completed).result {
          Error(error) -> Ok(error)
          Ok(_) -> Error(custody.Conflict)
        },
      )
      use next_input <- result.try(
        service_input.decode_compile(next.body)
        |> result.replace_error(custody.Conflict),
      )
      use original_input <- result.try(
        service_input.decode_compile(original.body)
        |> result.replace_error(custody.Conflict),
      )
      service_input.admit_rewrite(
        key,
        contract,
        next_input,
        previous,
        original_input,
        failed,
      )
      |> result.replace(Nil)
      |> result.replace_error(custody.Conflict)
    }
  }
}

// Registered metadata is validated without owner-side physical filesystem access.
fn validate_registered(
  config: Config,
  placement: Placement,
) -> Result(Nil, custody.Error) {
  use #(pin, associated, first) <- result.try(case placement {
    OrdinaryPlacement -> Error(custody.Invalid("registered placement required"))
    RegisteredPlacement(pin, associated, first) -> Ok(#(pin, associated, first))
  })
  use sha256 <- result.try(option.to_result(
    config.sha256,
    custody.Invalid("registered custody requires SHA-256"),
  ))
  let #(session, binding, descriptor, digest, bytes) =
    custody.enrollment_fields(pin)
  let #(scope, key_digest, _) =
    generation.key_fields(generation.association_key(associated))
  use Nil <- result.try(
    exact(fn() {
      session == config.session
      && workspace.scope(session, binding) == scope
      && descriptor == key_digest
      && digest == generation.association_fields(associated).1
      && sha256(bytes) == generation.digest_bytes(digest)
      && first > 0
      && first <= generation.max_generation
    }),
  )

  // The embedded native facts must describe this exact immutable association.
  use enrolled <- result.try(
    enrollment.decode(bytes) |> result.replace_error(custody.Conflict),
  )
  let native = enrollment.native_facts(enrolled)
  use Nil <- result.try(exact(fn() { native.scope == scope }))
  use native_scope <- result.try(executor_scope(native.scope))
  use registered <- result.try(
    registration.new(
      native_scope,
      native.working_roots,
      native.ceiling,
      native.demand,
      Ok,
    )
    |> result.replace_error(custody.Conflict),
  )

  // Recomputing native registration prevents a canonical but substituted digest.
  let actual =
    identity.digest_bytes(registration.digest(registered))
    |> bit_array.base16_encode
    |> string.lowercase
  exact(fn() { actual == enrollment.digests(enrolled).0 })
}

fn executor_scope(
  scope: workspace.Scope,
) -> Result(identity.Scope, custody.Error) {
  let #(session, binding) = workspace.scope_fields(scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, name) = workspace.selector_fields(selector)
  use executor <- result.try(
    identity.executor_id(executor) |> result.replace_error(custody.Conflict),
  )
  use name <- result.try(
    identity.workspace_id(name) |> result.replace_error(custody.Conflict),
  )
  use workspace_epoch <- result.try(
    identity.epoch(workspace_epoch) |> result.replace_error(custody.Conflict),
  )
  use session_epoch <- result.try(
    identity.epoch(session_epoch) |> result.replace_error(custody.Conflict),
  )
  Ok(identity.scope(session, name, executor, session_epoch, workspace_epoch))
}

fn boot_generation(
  config: Config,
  store: custody.Store,
  existed: ExistingCompanion,
) -> Result(GenerationCustody, custody.Error) {
  case config.placement {
    OrdinaryPlacement ->
      case custody.read_enrollment(store) {
        Error(custody.Missing) -> Ok(OrdinaryCustody)
        Ok(_) -> Error(custody.Frozen)
        Error(error) -> Error(error)
      }
    RegisteredPlacement(pin, associated, first) -> {
      use Nil <- result.try(validate_registered(config, config.placement))

      // Existing missing metadata is never repaired by adopting today's enrollment.
      use Nil <- result.try(case existed {
        ExistingCompanion ->
          custody.read_enrollment(store) |> result.map(fn(_) { Nil })
        NewCompanion -> Ok(Nil)
      })
      use readback <- result.try(custody.pin_enrollment(store, pin))
      use Nil <- result.try(exact(fn() { custody.pin_value(readback) == pin }))
      use admitted <- result.try(custody.retain_generation(
        store,
        associated,
        first,
      ))
      case admitted {
        custody.FreshGeneration(live) -> Ok(OriginalGeneration(live))
        custody.RetainedGeneration(original) ->
          Ok(HistoricalGeneration(original))
      }
    }
  }
}

fn current_association(
  state: State,
) -> Result(generation.GenerationAssociation, custody.Error) {
  case state.generation {
    OrdinaryCustody -> Error(custody.Invalid("registered owner required"))
    OriginalGeneration(live) -> Ok(custody.live_association(live))
    HistoricalGeneration(associated) -> Ok(associated)
  }
}

fn registered_readback(state: State) -> Result(RegisteredBoot, custody.Error) {
  use associated <- result.try(current_association(state))
  use pin <- result.try(custody.read_enrollment(state.store))
  use Nil <- result.try(case state.config.placement {
    RegisteredPlacement(original, _, _) -> exact(fn() { pin == original })
    OrdinaryPlacement -> Error(custody.Frozen)
  })
  use Nil <- result.try(validate_registered(
    state.config,
    RegisteredPlacement(pin, associated, case state.config.placement {
      RegisteredPlacement(_, _, first) -> first
      OrdinaryPlacement -> 0
    }),
  ))
  use readback <- result.try(custody.read_generation(
    state.store,
    generation.association_key(associated),
  ))
  use Nil <- result.try(exact(fn() { readback == associated }))
  case state.generation, state.admission {
    OriginalGeneration(_), Admitting ->
      Ok(ReadyForActivation(RegisteredOwner(state.owner, pin, associated)))
    HistoricalGeneration(_), _ -> Ok(HistoryOnly(pin, associated))
    OriginalGeneration(_), RecoveryOnly | OrdinaryCustody, _ ->
      Error(custody.Frozen)
  }
}

fn reserve_tool(
  state: State,
  key: remote_tool.ToolKey,
  args: custody.Payload,
  request: custody.Payload,
  profile: custody.FinalProfile,
) -> Result(custody.Admission, custody.Error) {
  case state.generation, state.admission {
    OrdinaryCustody, _ ->
      custody.admit_fresh_with_profile(state.store, key, args, request, profile)
    OriginalGeneration(live), Admitting ->
      custody.admit_registered_fresh_with_profile(
        state.store,
        live,
        key,
        args,
        request,
        profile,
      )
    HistoricalGeneration(_), _ | OriginalGeneration(_), RecoveryOnly ->
      Error(custody.Frozen)
  }
}

fn reserve_workspace(
  state: State,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
  request: custody.WorkspaceRequest,
) -> Result(Nil, custody.Error) {
  case state.generation, state.admission {
    OrdinaryCustody, _ ->
      custody.admit_workspace_child(state.store, origin, id, request)
    OriginalGeneration(live), Admitting ->
      custody.admit_registered_workspace_child(
        state.store,
        live,
        origin,
        id,
        request,
      )
      |> result.replace(Nil)
    HistoricalGeneration(_), _ | OriginalGeneration(_), RecoveryOnly ->
      Error(custody.Frozen)
  }
}

fn reserve_service(
  state: State,
  request: custody.ServiceRequest,
) -> Result(Nil, custody.Error) {
  case state.generation, state.admission {
    OrdinaryCustody, _ -> custody.admit_service_child(state.store, request)
    OriginalGeneration(live), Admitting ->
      custody.admit_registered_service_child(state.store, live, request)
      |> result.replace(Nil)
    HistoricalGeneration(_), _ | OriginalGeneration(_), RecoveryOnly ->
      Error(custody.Frozen)
  }
}

fn reserve_offer(
  state: State,
  original: custody.ServiceRequest,
  offer: custody.CommandOfferPayload,
) -> Result(custody.Admission, custody.Error) {
  case state.generation, state.admission {
    OrdinaryCustody, _ -> custody.admit_offer(state.store, original, offer)
    OriginalGeneration(live), Admitting ->
      custody.admit_registered_offer(state.store, live, original, offer)
    HistoricalGeneration(_), _ | OriginalGeneration(_), RecoveryOnly ->
      Error(custody.Frozen)
  }
}

fn reserve_command(
  state: State,
  offer: custody.CommandOfferPayload,
  candidate: ids.EntryId,
  request: custody.Payload,
) -> Result(#(ids.EntryId, custody.Payload), custody.Error) {
  case state.generation, state.admission {
    OrdinaryCustody, _ ->
      custody.admit_command_child(state.store, offer, candidate, request)
    OriginalGeneration(live), Admitting -> {
      use admitted <- result.try(custody.admit_registered_command_child(
        state.store,
        live,
        offer,
        candidate,
        request,
      ))
      Ok(#(admitted.1, admitted.2))
    }
    HistoricalGeneration(_), _ | OriginalGeneration(_), RecoveryOnly ->
      Error(custody.Frozen)
  }
}

fn receipt_readback(
  state: State,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
) -> Result(#(BitArray, generation.GenerationAssociation), custody.Error) {
  use stored <- result.try(custody.child(state.store, origin))
  use Nil <- result.try(exact(fn() { stored.0 == id }))
  use receipt <- result.try(option.to_result(stored.2, custody.Missing))
  use associated <- result.try(custody.child_generation(state.store, origin))
  Ok(#(custody.bytes(receipt), associated))
}

fn verify_receipt_readback(
  state: State,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
  bytes: BitArray,
) -> Result(Nil, custody.Error) {
  case state.generation {
    OrdinaryCustody -> Ok(Nil)
    OriginalGeneration(_) | HistoricalGeneration(_) -> {
      use readback <- result.try(receipt_readback(state, origin, id))
      exact(fn() { readback.0 == bytes })
    }
  }
}

fn retain_intent(
  state: State,
  address: String,
  service: custody.SystemService,
  op: ids.OpId,
  step: String,
  id: ids.EntryId,
  bytes: BitArray,
) -> Result(custody.IntentReadback, custody.Error) {
  use intent <- result.try(case state.generation, state.admission {
    OrdinaryCustody, _ ->
      Error(custody.Invalid("registered system intent required"))
    OriginalGeneration(live), Admitting ->
      custody.system_intent(live, address, service, op, step, id, bytes)
    OriginalGeneration(live), RecoveryOnly ->
      custody.historical_system_intent(
        custody.live_association(live),
        address,
        service,
        op,
        step,
        id,
        bytes,
      )
    HistoricalGeneration(associated), _ ->
      custody.historical_system_intent(
        associated,
        address,
        service,
        op,
        step,
        id,
        bytes,
      )
  })
  case state.generation, state.admission {
    OriginalGeneration(_), Admitting ->
      custody.retain_system_intent(state.store, intent)
    HistoricalGeneration(_), _ | OriginalGeneration(_), RecoveryOnly ->
      custody.read_system_intent(state.store, intent)
    OrdinaryCustody, _ -> Error(custody.Frozen)
  }
}

// Historical reconciliation reconstructs a read-only intent on this connection.
// A previously retained opaque live intent cannot allocate after the owner fences.
fn reconciliation_intent(
  state: State,
  retained: custody.IntentReadback,
) -> Result(custody.IntentReadback, custody.Error) {
  case state.generation, state.admission {
    OriginalGeneration(_), Admitting -> Ok(retained)
    OriginalGeneration(_), RecoveryOnly | HistoricalGeneration(_), _ -> {
      let #(associated, address, service, op, step, id, bytes) =
        custody.system_intent_fields(retained)
      use original <- result.try(custody.historical_system_intent(
        associated,
        address,
        service,
        op,
        step,
        id,
        bytes,
      ))
      custody.read_system_intent(state.store, original)
    }
    OrdinaryCustody, _ -> Error(custody.Frozen)
  }
}

fn exact(agrees: fn() -> Bool) -> Result(Nil, custody.Error) {
  case agrees() {
    True -> Ok(Nil)
    False -> Error(custody.Conflict)
  }
}

/// Reads the original semantic envelope and digest after cancellation as evidence.
///
/// ## Examples
///
/// `semantic_evidence(owner, origin)` cannot create new reserve permission.
pub fn semantic_evidence(
  owner: Handle,
  origin: remote_tool.ChildOrigin,
) -> Result(
  #(ids.EntryId, BitArray, BitArray, generation.GenerationAssociation),
  custody.Error,
) {
  ask(owner, fn(reply) { ReadSemanticEvidence(origin, reply) })
}

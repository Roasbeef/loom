//// Daemon admission over durable metadata and independently owned instances.
////
//// Listing and status inspect the catalogue without assembling a session. An
//// explicit open reserves one bounded slot, installs the original custody
//// monitor, and only then releases its parked builder. Heavy assembly and
//// cleanup run outside this actor. Concurrent opens for one identity return
//// the same operation; stopping never frees its slot before confirmed drain.
////
//// This actor is the custody registry and must not be restarted empty beside
//// its surviving cleanup scopes. A transitive outer owner may trust this actor's
//// normal exit because every orderly exit waits for all reservations to drain.
//// An untrappable registry death loses that aggregate proof: its child scopes
//// self-cancel, but the daemon must retain its lock and remain recovery-blocked.
//// Connection handlers own no instance lifetime and may be replaced independently
//// of this registry.
////
//// Calls report `Unavailable` when the registry dies or fails to answer within
//// five seconds. That deadline bounds the caller, not a queued admission or
//// cleanup: a retry must inspect the same session identity before assuming that
//// an earlier request did no work.
////
//// Creation is serialized with metadata reads here. The registry recovers an
//// existing request key before minting identity, path, or creation time. Only
//// an explicit create request can initialize a reserved row; ordinary open
//// refuses it. Assembly persists the reserved canonical identity before runtime
//// startup, then the registry confirms successful initialization in the catalogue.

import broker/internal/call
import client/daemon/domain as domain_service
import client/distill
import client/distillpass
import client/internal/instance_host as host
import client/internal/instance_owner as custody
import core/ids
import filepath
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import storage/access
import storage/catalogue
import storage/domain
import weft/state_machine as sm

/// Live lifecycle state, separate from persisted file initialization.
pub type Status {
  /// No runtime or cleanup reservation is owned by this registry.
  Saved

  /// One builder owns this opening operation.
  Opening(operation: String)

  /// The original builder remains resident with this incarnation.
  Resident(incarnation: String)

  /// Cleanup is pending and replacement remains forbidden.
  Stopping(operation: String)

  /// Cleanup lost proof or failed; the slot stays reserved.
  RecoveryBlocked(reason: String)
}

/// An admission refusal does not start a builder or mutate a conversation.
pub type Error {
  /// Metadata access or decoding failed.
  Catalogue(error: catalogue.Error)

  /// The file's creation reservation has not been reconciled yet.
  NotInitialized

  /// Every runtime slot is reserved, including stopping and blocked slots.
  Capacity

  /// This session is stopping or blocked, or the daemon is shutting down.
  Unavailable

  /// The operation no longer names the retained incarnation of this session.
  StaleOperation

  /// Parked process preparation failed before session work began.
  Preparation(reason: String)
}

/// Metadata plus the registry's current lifecycle observation.
pub type View {
  View(
    /// Durable registration; its state does not claim runtime liveness.
    registration: catalogue.Registration,
    /// The live reservation state at this read.
    status: Status,
  )
}

/// Owner-authorized creation metadata, with host-validated workspace/configuration.
pub type Creation {
  Creation(
    /// Stable across retries, including retries after daemon restart.
    request_key: String,
    /// Canonical workspace selected by the owner, never a collaborator's path.
    workspace: String,
    /// Display label, not a database filename.
    name: String,
    /// Validated configuration reference with no credential values.
    configuration: String,
  )
}

/// Whether the daemon may admit a new runtime reservation.
pub type Admission {
  /// Normal operation, subject to the capacity limit.
  Accepting

  /// Shutdown has begun; existing reservations still own cleanup.
  Draining
}

/// A bounded census of live reservations, with no session metadata.
pub type Summary {
  Summary(
    /// Admission state, independent of the number of available slots.
    admission: Admission,
    /// Maximum number of simultaneous runtime reservations.
    capacity: Int,
    /// All reservations, including uncertain cleanup.
    occupied: Int,
    /// Builders which have not published a usable instance.
    opening: Int,
    /// Usable resident instances.
    resident: Int,
    /// Reservations awaiting cleanup proof.
    stopping: Int,
    /// Reservations retaining failed or lost cleanup proof.
    blocked: Int,
    /// Maximum retained domain reservations, equal to session capacity.
    domain_capacity: Int,
    /// All retained domains, including cleanup and dependent retirement.
    domain_occupied: Int,
    /// Domains retaining a reported failure or lost cleanup proof.
    domain_blocked: Int,
  )
}

/// The assembly capabilities supplied by daemon wiring.
pub type Assembly(instance) {
  Assembly(
    /// Opens one domain under retained custody, outside the registry.
    domain_build: fn(
      domain.Domain,
      fn() -> Result(List(distill.Source), String),
      custody.Owner,
    ) -> Result(domain_service.Services, String),
    /// Acquires and publishes resources before their effects begin.
    build: fn(
      catalogue.Registration,
      domain.Domain,
      domain_service.Services,
      custody.Owner,
    ) -> Result(instance, String),
    /// Root deaths which make the instance unusable.
    fatal: fn(instance) -> List(#(String, Pid)),
  )
}

/// A registry handle. Only the daemon holds the assembly configuration.
pub opaque type Manager(instance) {
  Manager(commands: Subject(Message(instance)), pid: Pid)
}

type Phase {
  Ready
  ShuttingDown
}

/// What a reserved session slot has done so far with its builder.
///
/// The variants record what has already happened rather than what was
/// intended, which is why `retired` may release a reservation from any of them
/// without consulting this type.
type Occupancy(instance) {
  /// The builder is parked because its domain has not published services yet.
  /// `host.begin` has not been sent, so no assembly work has started.
  WaitingForDomain

  /// `host.begin` has been sent and the builder owns assembly. No instance
  /// exists yet, so nothing may resolve this session.
  Building

  /// Assembly published an instance and the catalogue confirmed the
  /// registration. This is the only phase `resolve` answers from.
  Running(instance)

  /// Cancellation has been issued and ordered cleanup is running. The
  /// reservation is still held: only the original witness's normal exit
  /// releases it.
  Closing

  /// Cleanup reported a failure, so its holder stays alive and no normal exit
  /// can ever arrive. The reservation is permanent until an operator acts.
  Blocked(String)
}

/// One session's reservation: its builder, its identity, and the channels the
/// registry watches that builder through.
type Slot(instance) {
  Slot(
    /// The domain whose shared services this session was admitted against.
    domain_id: String,
    /// The parked builder and its cancellation capability.
    host: host.Host,
    /// This incarnation's identity; a stale operation never addresses it.
    operation: String,
    /// What the builder has done so far.
    phase: Occupancy(instance),
    /// The original custody monitor. Its normal exit is the drain proof.
    watch: Monitor,
    /// The published instance, or the reason assembly refused.
    results: Subject(Result(instance, String)),
    /// An assembly fault. Cleanup has started; a separate channel reports it.
    faults: Subject(String),
    /// A cleanup failure, after which no normal exit can follow.
    failures: Subject(custody.Failure),
  )
}

/// Why a domain's maintenance cadence was fenced, and therefore whether the
/// fence may be lifted again.
///
/// The two are not interchangeable, and the difference is the whole of what
/// makes revival safe: a fence taken while admission is open is a pause, while
/// one taken on the way out is a step of retirement that has already been
/// decided.
type Quiescence {
  /// The domain lost its last dependent session while the daemon was still
  /// accepting. Its services stay alive throughout, so a new session in the
  /// same workspace may take them back.
  Idle

  /// The fence belongs to retirement — daemon shutdown, or a domain whose
  /// cancellation the registry has already chosen. Those services must never
  /// be handed back, because the cancellation that follows is not withdrawable.
  Retiring
}

/// What a retained domain slot has done so far with its shared services.
///
/// The legal transitions are:
///
/// - `DomainPreparing` to `DomainRunning` on a published build, or to
///   `DomainWaitingFailure` on a refusal.
/// - `DomainRunning` to `DomainQuiescing(Idle, _)` when the last dependent
///   session retires while admission is open, and to
///   `DomainQuiescing(Retiring, _)` while the daemon is draining.
/// - `DomainQuiescing(Idle, services)` back to `DomainRunning(services)` when
///   a new session in the same domain is admitted. This is the machine's only
///   backwards edge, and `Retiring` is what withholds it once cancellation has
///   been decided.
/// - `DomainQuiescing(_, _)` to `DomainClosing` when the fenced maintenance
///   pass settles and the host is cancelled.
/// - `DomainClosing` to `DomainDrained` on the witness's normal exit.
/// - `DomainWaitingFailure` to `DomainBlocked` once cancellation has been
///   issued; neither is ever admitted against again.
///
/// Revival hands back the *same* services and un-fences the cadence with them
/// (`domain_service.resume`), so a reopened workspace goes on running
/// scheduled maintenance. Handing the services back without that would leave
/// the maintenance worker in `Quiescing`, where it ignores every hint and
/// schedules nothing, and a workspace closed and reopened once — the ordinary
/// path — would distil nothing more until the domain retired and was rebuilt.
/// The coalesced pass the fence admitted still runs to completion, and the
/// account it produces reaches a slot that is no longer quiescing and is
/// ignored there.
///
/// A cadence that refuses to resume fails the domain rather than reviving it:
/// the worker that owns this domain's maintenance is not answering, which is
/// the same fact a refused quiesce carries, and admitting against it would
/// hand a session services whose custody is already in doubt.
type DomainPhase {
  DomainPreparing
  DomainRunning(domain_service.Services)
  DomainQuiescing(Quiescence, domain_service.Services)
  DomainClosing
  DomainDrained
  DomainWaitingFailure(String)
  DomainBlocked(String)
}

/// One domain's reservation: its builder, its identity, the channels the
/// registry watches it through, and how many sessions still need it.
type DomainSlot {
  DomainSlot(
    /// The parked domain builder and its cancellation capability.
    host: host.Host,
    /// This domain incarnation's identity.
    operation: String,
    /// What the domain builder has done so far.
    phase: DomainPhase,
    /// The original custody monitor. Its normal exit is the drain proof.
    watch: Monitor,
    /// The published services, or the reason the builder refused.
    results: Subject(Result(domain_service.Services, String)),
    /// A build fault, reported before its cleanup runs.
    faults: Subject(String),
    /// A cleanup failure, after which no normal exit can follow.
    failures: Subject(custody.Failure),
    /// Where a requested maintenance quiesce reports its settled pass.
    settled: Subject(distillpass.Pass),
    /// How many session slots name this domain. Maintained where a slot is
    /// inserted and where one is deleted, because re-deriving it folds every
    /// slot for every domain on every lifecycle message.
    dependents: Int,
  )
}

type Message(instance) {
  DomainSourceIds(String, String, Subject(Result(List(String), String)))
  DomainSourcePaths(List(String), Subject(Result(List(distill.Source), String)))
  FrameAuthority(
    String,
    String,
    String,
    access.Digest,
    Subject(Result(#(access.Principal, access.Authority), FrameRefusal)),
  )
  DomainServices(
    String,
    String,
    Subject(Result(domain_service.Services, String)),
  )
  DomainOpened(String, String, Result(domain_service.Services, String))
  DomainFailed(String, String, String)
  DomainRetired(String, String, process.ExitReason)
  DomainSettled(String, String, distillpass.Pass)
  Administer(
    access.Digest,
    String,
    Administration,
    Subject(Result(access.Principal, AdminError)),
  )
  Census(Subject(Summary))

  /// Answers the subject a session's domain currently settles on. Fixtures
  /// only; see `settle_subject`.
  SettleSubject(String, Subject(Result(Subject(distillpass.Pass), Error)))
  AuthorizedPage(
    access.Digest,
    String,
    Subject(Result(#(Int, List(View)), Error)),
  )
  Authenticate(access.Digest, Subject(Result(access.Principal, Error)))
  SessionAuthority(
    access.Digest,
    String,
    Subject(Result(#(access.Principal, access.Authority), Error)),
  )
  Create(
    Creation,
    String,
    ids.Generator,
    domain.Scope,
    String,
    Subject(Result(View, Error)),
  )
  DomainForSession(String, Subject(Result(domain.Domain, Error)))
  Isolate(
    access.Digest,
    String,
    String,
    String,
    Subject(Result(domain.Domain, AdminError)),
  )
  WorkspaceDefault(String, Subject(Result(View, Error)))
  SetDefault(String, String, Subject(Result(View, Error)))
  Open(String, Subject(Result(Status, Error)))
  StopSession(String, Subject(Result(Status, Error)))
  StopIncarnation(String, String, Subject(Result(Status, Error)))
  Get(String, Subject(Result(View, Error)))
  Page(String, Subject(Result(#(Int, List(View)), Error)))
  Resolve(String, Subject(Result(instance, Error)))
  ResolveIncarnation(String, String, Subject(Result(instance, Error)))
  Operation(String, String, Subject(Result(View, Error)))
  Shutdown
  Opened(String, String, Result(instance, String))
  Faulted(String, String)
  Failed(String, String, String)
  Retired(String, String, process.ExitReason)
  LinkedExit(Pid)
}

/// Why one already-attached socket's frame is no longer authorized.
///
/// The transport re-asks this question when it admits a command and again
/// when it delivers the reply, so the answer distinguishes the three ways an
/// attachment goes stale from the registry simply not answering. A caller
/// that cannot tell those apart reports a revocation as an outage.
@internal
pub type FrameRefusal {
  /// The attachment names a previous daemon lifetime.
  StaleEpoch

  /// The session's retained incarnation is no longer the admitted one.
  StaleIncarnation

  /// The credential is revoked, or no longer a member of this session.
  Unauthorized

  /// The registry died or did not answer inside the caller's deadline.
  RegistryUnavailable
}

/// One owner-only mutation; bearer values never enter the registry.
@internal
pub type Administration {
  /// Creates a permanently reserved member ID and its first session grant.
  Invite(
    id: String,
    name: String,
    digest: access.Digest,
    session_id: String,
    role: access.Role,
  )

  /// Changes one existing member's session grant.
  SetRole(id: String, session_id: String, role: access.Role)

  /// Removes one session grant without revoking unrelated memberships.
  RevokeMembership(id: String, session_id: String)

  /// Revokes every active member credential and inserts one replacement.
  RotateMember(id: String, digest: access.Digest)

  /// Revokes all member credentials while retaining the recovery identity.
  RevokeMember(id: String)
}

/// An administration refusal contains no credential material.
@internal
pub type AdminError {
  /// Sharing a private aggregate requires explicit stopped isolation first.
  IsolationRequired

  /// The supplied credential is absent, revoked, or not the owner.
  AdminForbidden

  /// The caller addressed a previous daemon incarnation.
  AdminStaleEpoch

  /// The registry is unavailable or draining.
  AdminUnavailable

  /// The atomic durable mutation was refused.
  AdminMetadata(error: catalogue.Error)
}

/// Reauthenticates owner and epoch in the same dispatch as the mutation.
///
/// A timeout is an unknown outcome, not permission to retry an invitation.
/// The caller must retain its chosen member ID and recover by explicit rotation.
///
/// ## Examples
///
/// ```gleam
/// // manager.administer(registry, owner_digest, epoch, RotateMember(id, digest))
/// ```
@internal
pub fn administer(
  manager: Manager(instance),
  caller: access.Digest,
  epoch: String,
  action: Administration,
) -> Result(access.Principal, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: Administer(
    caller,
    epoch,
    action,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

type Book(instance) {
  Book(
    catalogue: catalogue.Catalogue,
    assembly: Assembly(instance),
    limit: Int,
    epoch: String,
    next: Int,
    slots: Dict(String, Slot(instance)),
    domains: Dict(String, DomainSlot),
    commands: Subject(Message(instance)),
    parent: Pid,
  )
}

/// Starts an empty live registry over existing catalogue metadata.
///
/// The caller holds the daemon lifetime lock. Opening this registry never
/// reopens a saved session. Its supervisor must retain cleanup authority if
/// this process dies; starting a replacement immediately is not supported.
///
/// ## Examples
///
/// ```gleam
/// // manager.start(catalogue, assembly, epoch: daemon_epoch, limit: 8)
/// ```
@internal
pub fn start(
  catalogue: catalogue.Catalogue,
  assembly: Assembly(instance),
  epoch epoch: String,
  limit limit: Int,
) -> Result(Manager(instance), String) {
  case limit > 0 && epoch != "" {
    False -> Error("daemon admission requires a positive limit and epoch")
    True -> {
      let parent = process.self()
      sm.new_with_initialiser(1000, fn(commands) {
        let book =
          Book(
            catalogue:,
            assembly:,
            limit:,
            epoch:,
            next: 0,
            slots: dict.new(),
            domains: dict.new(),
            commands:,
            parent:,
          )
        sm.initialised(Ready, book)
        |> sm.selecting(selector(book))
        |> sm.returning(commands)
        |> Ok
      })
      |> sm.trapping_exits(True)
      |> sm.on_event(handle)
      |> sm.start
      |> result.map(fn(started) { Manager(started.data, started.pid) })
      |> result.map_error(string.inspect)
    }
  }
}

/// Returns the registry PID for the daemon supervisor's lifetime monitor.
///
/// ## Examples
///
/// ```gleam
/// let watch = process.monitor(manager.pid(registry))
/// ```
@internal
pub fn pid(manager: Manager(instance)) -> Pid {
  manager.pid
}

/// Resolves a credential on the same serialized connection as catalogue access.
///
/// This is an internal capability for the authenticated listener. It does not
/// grant lifecycle authority by itself; control requests still check principal
/// kind, and session requests use `session_authority` at admission.
///
/// ## Examples
///
/// ```gleam
/// // manager.authenticate(registry, credential_digest)
/// ```
@internal
pub fn authenticate(
  manager: Manager(instance),
  digest: access.Digest,
) -> Result(access.Principal, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Authenticate(
    digest,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Rechecks credential and session membership together without opening a runtime.
///
/// The gateway calls this at command admission, not just at initial attachment.
/// A cached principal cannot continue issuing commands after credential
/// revocation. No listener or gateway accesses the catalogue connection itself.
///
/// ## Examples
///
/// ```gleam
/// // manager.session_authority(registry, credential_digest, session_id)
/// ```
@internal
pub fn session_authority(
  manager: Manager(instance),
  digest: access.Digest,
  id: String,
) -> Result(#(access.Principal, access.Authority), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: SessionAuthority(
    digest,
    id,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Answers daemon lifetime, session incarnation and session authority in one
/// registry turn.
///
/// This is the per-frame authorization question. The session transport asks it
/// when a command is admitted and again when its reply is delivered, so the
/// cost is paid twice per command on the session's own serialization point.
/// Asking readiness, residency and membership separately put three
/// cross-process round trips behind each of those checks; this is one, and it
/// is still a live read rather than a cache, so a credential revoked between a
/// command's admission and its delivery still closes the attachment.
///
/// ## Examples
///
/// ```gleam
/// // manager.frame_authority(registry, epoch:, id:, incarnation:, digest:)
/// ```
@internal
pub fn frame_authority(
  manager: Manager(instance),
  epoch epoch: String,
  id id: String,
  incarnation incarnation: String,
  digest digest: access.Digest,
) -> Result(#(access.Principal, access.Authority), FrameRefusal) {
  call.try_call(manager.commands, waiting: 5000, sending: FrameAuthority(
    epoch,
    id,
    incarnation,
    digest,
    _,
  ))
  |> result.unwrap(Error(RegistryUnavailable))
}

/// Requests an explicit lazy open, or returns the already accepted operation.
///
/// ## Examples
///
/// ```gleam
/// // manager.open(registry, session_id)
/// ```
@internal
pub fn open(manager: Manager(instance), id: String) -> Result(Status, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Open(id, _))
  |> result.unwrap(Error(Unavailable))
}

/// Reserves and explicitly initializes a session, reusing its creation key.
///
/// The daemon supplies its private sessions directory and an entropy-seeded
/// generator. Neither identity nor file path is minted on a retry. Assembly
/// must persist this exact identity before starting recovery; only a successful
/// assembly lets the registry confirm the reservation as saved. A timeout leaves
/// the request's durable reservation intact and does not authorize a new key.
///
/// ## Examples
///
/// ```gleam
/// // manager.create(registry, request, directory: sessions_dir, generator: ids)
/// ```
@internal
pub fn create(
  manager: Manager(instance),
  request: Creation,
  directory directory: String,
  generator generator: ids.Generator,
) -> Result(View, Error) {
  create_scoped(
    manager,
    request,
    directory:,
    generator:,
    scope: domain.WorkspacePrivate,
    configuration: "",
  )
}

/// Creates with explicit domain policy and captured owner configuration metadata.
///
/// Existing workspace domain records retain their configuration and imported
/// paths. No session open can redefine them by racing to become resident first.
///
/// ## Examples
///
/// ```gleam
/// // manager.create_scoped(registry, request, directory: sessions, generator: ids, scope: domain.SessionOnly, configuration: "")
/// ```
@internal
pub fn create_scoped(
  manager: Manager(instance),
  request: Creation,
  directory directory: String,
  generator generator: ids.Generator,
  scope scope: domain.Scope,
  configuration configuration: String,
) -> Result(View, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Create(
    request,
    directory,
    generator,
    scope,
    configuration,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Reads domain metadata without admitting a runtime or opening derived stores.
///
/// ## Examples
///
/// ```gleam
/// // manager.session_domain(registry, session_id)
/// ```
@internal
pub fn session_domain(
  manager: Manager(instance),
  id: String,
) -> Result(domain.Domain, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: DomainForSession(
    id,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Applies an owner-acknowledged prospective isolation after all custody retires.
///
/// The server must decode explicit share-existing-transcript acknowledgement
/// before calling this capability. This operation does not sanitize old entries.
///
/// ## Examples
///
/// ```gleam
/// // manager.isolate(registry, owner_digest, epoch, session_id, state_root)
/// ```
@internal
pub fn isolate(
  manager: Manager(instance),
  caller: access.Digest,
  epoch: String,
  id: String,
  state_root: String,
) -> Result(domain.Domain, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: Isolate(
    caller,
    epoch,
    id,
    state_root,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Reads a workspace default without opening it, including after restart.
///
/// ## Examples
///
/// ```gleam
/// // manager.workspace_default(registry, workspace)
/// ```
@internal
pub fn workspace_default(
  manager: Manager(instance),
  workspace: String,
) -> Result(View, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: WorkspaceDefault(
    workspace,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Changes only the durable default; selecting it does not execute the session.
///
/// ## Examples
///
/// ```gleam
/// // manager.set_default(registry, workspace, session_id)
/// ```
@internal
pub fn set_default(
  manager: Manager(instance),
  workspace: String,
  id: String,
) -> Result(View, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: SetDefault(
    workspace,
    id,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Begins stop without waiting for external drain in the registry handler.
///
/// ## Examples
///
/// ```gleam
/// // manager.stop_session(registry, session_id)
/// ```
@internal
pub fn stop_session(
  manager: Manager(instance),
  id: String,
) -> Result(Status, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: StopSession(id, _))
  |> result.unwrap(Error(Unavailable))
}

/// Stops only the original incarnation, with comparison and cancellation in
/// one registry dispatch. The reply admits cleanup; it never waits for the
/// requesting gateway to retire itself.
///
/// ## Examples
///
/// ```gleam
/// // manager.stop_if_incarnation(registry, session_id, incarnation)
/// ```
@internal
pub fn stop_if_incarnation(
  manager: Manager(instance),
  id: String,
  incarnation: String,
) -> Result(Status, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: StopIncarnation(
    id,
    incarnation,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Reads one registration and live status without waking a saved runtime.
///
/// ## Examples
///
/// ```gleam
/// // manager.get(registry, session_id)
/// ```
@internal
pub fn get(manager: Manager(instance), id: String) -> Result(View, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Get(id, _))
  |> result.unwrap(Error(Unavailable))
}

/// Returns a bounded metadata page with current lifecycle observations.
///
/// The revision covers durable metadata, not ephemeral runtime transitions.
///
/// ## Examples
///
/// ```gleam
/// // manager.page(registry, after: "")
/// ```
@internal
pub fn page(
  manager: Manager(instance),
  after after: String,
) -> Result(#(Int, List(View)), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Page(after, _))
  |> result.unwrap(Error(Unavailable))
}

/// Lists the current credential's visible registrations without opening them.
///
/// Membership is applied before the SQL page limit. A continuation therefore
/// names only a returned registration, never an unrelated hidden session.
/// Revocation is checked again on every call, including continuation pages.
///
/// ## Examples
///
/// ```gleam
/// // manager.authorized_page(registry, digest, after: "")
/// ```
@internal
pub fn authorized_page(
  manager: Manager(instance),
  digest: access.Digest,
  after after: String,
) -> Result(#(Int, List(View)), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: AuthorizedPage(
    digest,
    after,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Counts live reservations without scanning the durable catalogue.
///
/// ## Examples
///
/// ```gleam
/// // manager.summary(registry)
/// ```
@internal
pub fn summary(manager: Manager(instance)) -> Result(Summary, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Census)
  |> result.replace_error(Unavailable)
}

/// Reports the subject on which a resident session's domain will settle.
///
/// This exists for one registry fixture: a revival replaces the slot's
/// settle subject so that an account of the fence it withdrew cannot be
/// taken for the next fence's settle, and the only way a test can deliver
/// such an account is to hold the earlier subject. Nothing in production
/// reads a settle subject back out; the registry issues it with each fence.
///
/// ## Examples
///
/// ```gleam
/// // manager.settle_subject(registry, session_id)
/// ```
@internal
pub fn settle_subject(
  manager: Manager(instance),
  id: String,
) -> Result(Subject(distillpass.Pass), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: SettleSubject(id, _))
  |> result.replace_error(Unavailable)
  |> result.flatten
}

/// Resolves only a resident instance; lookup never implicitly opens one.
///
/// ## Examples
///
/// ```gleam
/// // manager.resolve(registry, session_id)
/// ```
@internal
pub fn resolve(
  manager: Manager(instance),
  id: String,
) -> Result(instance, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Resolve(id, _))
  |> result.unwrap(Error(Unavailable))
}

/// Resolves a resident incarnation without attaching to its replacement.
///
/// ## Examples
///
/// ```gleam
/// // manager.resolve_incarnation(registry, session_id, incarnation)
/// ```
@internal
pub fn resolve_incarnation(
  manager: Manager(instance),
  id: String,
  incarnation: String,
) -> Result(instance, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: ResolveIncarnation(
    id,
    incarnation,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Reads an operation only while its original reservation remains retained.
///
/// A blocked reservation still has an operation identity. Once custody drains,
/// the registry forgets the operation instead of accumulating terminal history.
///
/// ## Examples
///
/// ```gleam
/// // manager.operation(registry, session_id, operation_id)
/// ```
@internal
pub fn operation(
  manager: Manager(instance),
  id: String,
  operation: String,
) -> Result(View, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Operation(
    id,
    operation,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Fences admission and asks every instance to close, retaining blocked slots.
///
/// ## Examples
///
/// ```gleam
/// manager.shutdown(registry)
/// ```
@internal
pub fn shutdown(manager: Manager(instance)) -> Nil {
  process.send(manager.commands, Shutdown)
}

fn handle(
  phase: Phase,
  book: Book(instance),
  message: Message(instance),
) -> sm.Step(Phase, Book(instance), Message(instance), sm.Postponable) {
  case message {
    DomainSourceIds(id, after, reply) -> {
      process.send(
        reply,
        domain.sources(book.catalogue, id, after:)
          |> result.map_error(string.inspect),
      )
      sm.keep(book)
    }
    DomainSourcePaths(identities, reply) -> {
      process.send(reply, source_paths(book.catalogue, identities))
      sm.keep(book)
    }
    FrameAuthority(epoch, id, incarnation, digest, reply) -> {
      process.send(
        reply,
        frame_authorized(book, epoch, id, incarnation, digest),
      )
      sm.keep(book)
    }
    DomainServices(id, operation, reply) -> {
      let services = case dict.get(book.domains, id) {
        Ok(DomainSlot(operation: current, phase: DomainRunning(services), ..))
          if current == operation
        -> Ok(services)
        Ok(_) | Error(Nil) -> Error("domain admission is no longer resident")
      }
      process.send(reply, services)
      sm.keep(book)
    }
    DomainOpened(id, operation, outcome) ->
      step(phase, domain_opened(book, id, operation, outcome))
    DomainFailed(id, operation, reason) ->
      step(phase, domain_failed(book, id, operation, reason))
    DomainRetired(id, operation, reason) ->
      step(phase, domain_retired(book, id, operation, reason))
    DomainSettled(id, operation, _account) ->
      step(phase, domain_settled(book, id, operation))
    DomainForSession(id, reply) -> {
      process.send(
        reply,
        domain.for_session(book.catalogue, id) |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    Isolate(caller, epoch, id, state_root, reply) -> {
      process.send(
        reply,
        isolate_now(phase, book, caller, epoch, id, state_root),
      )
      sm.keep(book)
    }
    Administer(digest, epoch, action, reply) -> {
      process.send(reply, administer_now(phase, book, digest, epoch, action))
      sm.keep(book)
    }
    Census(reply) -> {
      process.send(reply, census(phase, book))
      sm.keep(book)
    }
    SettleSubject(id, reply) -> {
      let answer = {
        use slot <- result.try(
          dict.get(book.slots, id) |> result.replace_error(Unavailable),
        )
        use domain <- result.try(
          dict.get(book.domains, slot.domain_id)
          |> result.replace_error(Unavailable),
        )
        Ok(domain.settled)
      }
      process.send(reply, answer)
      sm.keep(book)
    }
    AuthorizedPage(digest, after, reply) -> {
      let outcome = {
        use principal <- result.try(access.authenticate(book.catalogue, digest))
        case principal.kind {
          access.OwnerPrincipal -> catalogue.page(book.catalogue, after:)
          access.MemberPrincipal ->
            catalogue.member_page(book.catalogue, principal.id, after:)
        }
      }
      process.send(reply, viewed_page(book, outcome))
      sm.keep(book)
    }
    Authenticate(digest, reply) -> {
      process.send(
        reply,
        access.authenticate(book.catalogue, digest)
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    SessionAuthority(digest, id, reply) -> {
      let outcome = {
        use principal <- result.try(access.authenticate(book.catalogue, digest))
        use authority <- result.try(access.authorization(
          book.catalogue,
          principal.id,
          id,
        ))
        Ok(#(principal, authority))
      }
      process.send(reply, result.map_error(outcome, Catalogue))
      sm.keep(book)
    }
    Create(request, directory, generator, scope, configuration, reply) -> {
      let #(book, outcome) =
        create_session(
          phase,
          book,
          request,
          directory,
          generator,
          scope,
          configuration,
        )
      process.send(reply, outcome)
      step(phase, book)
    }
    WorkspaceDefault(workspace, reply) -> {
      process.send(
        reply,
        catalogue.workspace_default(book.catalogue, workspace)
          |> result.map_error(Catalogue)
          |> result.map(fn(record) { View(record, status(book, record.id)) }),
      )
      sm.keep(book)
    }
    SetDefault(workspace, id, reply) -> {
      let outcome = case phase {
        ShuttingDown -> Error(Unavailable)
        Ready ->
          catalogue.set_workspace_default(book.catalogue, workspace, id)
          |> result.map_error(Catalogue)
          |> result.map(fn(record) { View(record, status(book, record.id)) })
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    Get(id, reply) -> {
      let view =
        catalogue.get(book.catalogue, id)
        |> result.map_error(Catalogue)
        |> result.map(fn(record) { View(record, status(book, id)) })
      process.send(reply, view)
      sm.keep(book)
    }
    Page(after, reply) -> {
      let page =
        catalogue.page(book.catalogue, after:)
        |> viewed_page(book, _)
      process.send(reply, page)
      sm.keep(book)
    }
    Resolve(id, reply) -> {
      let instance = case dict.get(book.slots, id) {
        Ok(Slot(phase: Running(instance), ..)) -> Ok(instance)
        Ok(Slot(..)) | Error(Nil) -> Error(Unavailable)
      }
      process.send(reply, instance)
      sm.keep(book)
    }
    ResolveIncarnation(id, incarnation, reply) -> {
      let instance = case dict.get(book.slots, id) {
        Ok(Slot(phase: Running(instance), operation:, ..))
          if operation == incarnation
        -> Ok(instance)
        Ok(Slot(..)) | Error(Nil) -> Error(StaleOperation)
      }
      process.send(reply, instance)
      sm.keep(book)
    }
    Operation(id, operation, reply) -> {
      // Compare and observe in one registry turn, including blocked custody.
      let view = case dict.get(book.slots, id) {
        Ok(Slot(operation: current, ..)) if current == operation ->
          catalogue.get(book.catalogue, id)
          |> result.map_error(Catalogue)
          |> result.map(fn(record) { View(record, status(book, id)) })
        Ok(Slot(..)) | Error(Nil) -> Error(StaleOperation)
      }
      process.send(reply, view)
      sm.keep(book)
    }
    Open(id, reply) -> {
      let #(book, outcome) = admit(phase, book, id)
      process.send(reply, outcome)
      step(phase, book)
    }
    StopSession(id, reply) -> {
      let book = stop_slot(book, id)
      process.send(
        reply,
        catalogue.get(book.catalogue, id)
          |> result.map_error(Catalogue)
          |> result.replace(status(book, id)),
      )
      step(phase, book)
    }
    StopIncarnation(id, incarnation, reply) -> {
      case dict.get(book.slots, id) {
        Ok(slot) if slot.operation == incarnation -> {
          let book = stop_slot(book, id)
          process.send(reply, Ok(status(book, id)))
          step(phase, book)
        }
        Ok(_) | Error(Nil) -> {
          process.send(reply, Error(StaleOperation))
          sm.keep(book)
        }
      }
    }
    Opened(id, operation, outcome) ->
      step(phase, opened(book, id, operation, outcome))
    Faulted(id, operation) -> step(phase, faulted(book, id, operation))
    Failed(id, operation, reason) ->
      step(phase, failed(book, id, operation, reason))
    Retired(id, operation, reason) ->
      step(phase, retired(book, id, operation, reason))
    Shutdown -> {
      let closing = list.fold(dict.keys(book.slots), book, stop_slot)
      step(ShuttingDown, closing)
    }
    LinkedExit(pid) ->
      case pid == book.parent {
        // The starter's death requests shutdown, not a clean exit. This actor
        // is a transitive witness, so its normal exit must still mean every
        // original custody monitor has proved its instance fully retired.
        True -> {
          let closing = list.fold(dict.keys(book.slots), book, stop_slot)
          step(ShuttingDown, closing)
        }
        False -> sm.keep(book)
      }
  }
}

fn administer_now(phase, book: Book(instance), digest, epoch, action) {
  use Nil <- result.try(authorize_admin(phase, book, digest, epoch))
  administer_member(book.catalogue, action)
}

fn authorize_admin(phase, book: Book(instance), digest, epoch) {
  use Nil <- result.try(case phase {
    Ready -> Ok(Nil)
    ShuttingDown -> Error(AdminUnavailable)
  })
  use principal <- result.try(
    access.authenticate(book.catalogue, digest)
    |> result.replace_error(AdminForbidden),
  )
  use Nil <- result.try(case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error(AdminForbidden)
  })
  case epoch == book.epoch {
    True -> Ok(Nil)
    False -> Error(AdminStaleEpoch)
  }
}

fn administer_member(store, action) {
  case action {
    Invite(id, name, digest, session_id, role) -> {
      use Nil <- result.try(require_shared(store, session_id))
      access.invite_member(store, id, name, digest, session_id, role)
      |> result.map_error(AdminMetadata)
    }
    RotateMember(id, digest) ->
      access.rotate_member(store, id, digest) |> result.map_error(AdminMetadata)
    RevokeMember(id) ->
      access.revoke_member(store, id) |> result.map_error(AdminMetadata)
    SetRole(id, session_id, role) -> {
      use Nil <- result.try(require_shared(store, session_id))
      use member <- result.try(
        admin_member(store, id) |> result.map_error(AdminMetadata),
      )
      use Nil <- result.try(
        access.grant(store, id, session_id, role)
        |> result.map_error(AdminMetadata),
      )
      Ok(member)
    }
    RevokeMembership(id, session_id) -> {
      use member <- result.try(
        admin_member(store, id) |> result.map_error(AdminMetadata),
      )
      use Nil <- result.try(
        access.revoke_membership(store, id, session_id)
        |> result.map_error(AdminMetadata),
      )
      Ok(member)
    }
  }
}

fn require_shared(store, session_id) {
  use selected <- result.try(
    domain.for_session(store, session_id) |> result.map_error(AdminMetadata),
  )
  case selected.scope {
    domain.WorkspacePrivate -> Error(IsolationRequired)
    domain.SessionOnly -> Ok(Nil)
  }
}

fn isolate_now(phase, book: Book(instance), caller, epoch, id, state_root) {
  use Nil <- result.try(authorize_admin(phase, book, caller, epoch))
  use Nil <- result.try(case dict.has_key(book.slots, id) {
    True -> Error(AdminUnavailable)
    False -> Ok(Nil)
  })
  use record <- result.try(
    catalogue.get(book.catalogue, id) |> result.map_error(AdminMetadata),
  )
  use existing <- result.try(
    domain.for_session(book.catalogue, id) |> result.map_error(AdminMetadata),
  )
  let fresh =
    domain_record(
      record,
      domain.SessionOnly,
      existing.configuration,
      state_root,
    )
  domain.isolate(book.catalogue, id, fresh) |> result.map_error(AdminMetadata)
}

fn admin_member(store, id) {
  use principal <- result.try(access.get(store, id))
  case principal.kind {
    access.MemberPrincipal -> Ok(principal)
    access.OwnerPrincipal -> Error(catalogue.Conflict)
  }
}

fn viewed_page(
  book: Book(instance),
  page: Result(catalogue.Page, catalogue.Error),
) {
  page
  |> result.map_error(Catalogue)
  |> result.map(fn(page) {
    #(
      page.revision,
      list.map(page.records, fn(record) {
        View(record, status(book, record.id))
      }),
    )
  })
}

// The census walks only the capacity-bounded live slots, never all saved files.
// Closing and blocked slots count as occupied until their original witness exits.
fn census(phase: Phase, book: Book(instance)) -> Summary {
  let admission = case phase {
    Ready -> Accepting
    ShuttingDown -> Draining
  }
  let empty =
    Summary(
      admission:,
      capacity: book.limit,
      occupied: dict.size(book.slots),
      opening: 0,
      resident: 0,
      stopping: 0,
      blocked: 0,
      domain_capacity: book.limit,
      domain_occupied: dict.size(book.domains),
      domain_blocked: dict.fold(book.domains, 0, fn(count, _, slot) {
        case slot.phase {
          DomainWaitingFailure(_) | DomainBlocked(_) -> count + 1
          DomainPreparing
          | DomainRunning(_)
          | DomainQuiescing(_, _)
          | DomainClosing
          | DomainDrained -> count
        }
      }),
    )
  list.fold(dict.values(book.slots), empty, fn(counts, slot) {
    case slot.phase {
      WaitingForDomain | Building ->
        Summary(..counts, opening: counts.opening + 1)
      Running(_) -> Summary(..counts, resident: counts.resident + 1)
      Closing -> Summary(..counts, stopping: counts.stopping + 1)
      Blocked(_) -> Summary(..counts, blocked: counts.blocked + 1)
    }
  })
}

fn create_session(
  phase: Phase,
  book: Book(instance),
  request: Creation,
  directory: String,
  generator: ids.Generator,
  scope: domain.Scope,
  configuration: String,
) -> #(Book(instance), Result(View, Error)) {
  case phase {
    ShuttingDown -> #(book, Error(Unavailable))
    Ready -> {
      case
        reserve_creation(
          book.catalogue,
          request,
          directory,
          generator,
          scope,
          configuration,
        )
      {
        Error(error) -> #(book, Error(Catalogue(error)))
        Ok(record) -> {
          let #(book, outcome) = case
            dict.has_key(book.slots, record.id),
            dict.size(book.slots) >= book.limit
          {
            True, _ -> admit(phase, book, record.id)
            False, True -> #(book, Error(Capacity))
            False, False -> prepare_slot(book, record)
          }
          #(book, result.map(outcome, fn(status) { View(record, status) }))
        }
      }
    }
  }
}

// Only a missing key permits allocation. Corrupt or unavailable metadata must
// not produce a second file under a new identity, even if the caller retries.
fn reserve_creation(
  store: catalogue.Catalogue,
  request: Creation,
  directory: String,
  generator: ids.Generator,
  scope: domain.Scope,
  configuration: String,
) -> Result(catalogue.Registration, catalogue.Error) {
  case catalogue.by_request_key(store, request.request_key) {
    Ok(record) ->
      case
        record.workspace == request.workspace
        && record.name == request.name
        && record.configuration == request.configuration
      {
        True -> {
          use selected <- result.try(domain.for_session(store, record.id))
          case selected.scope == scope {
            True -> Ok(record)
            False -> Error(catalogue.Conflict)
          }
        }
        False -> Error(catalogue.Conflict)
      }
    Error(catalogue.Missing) -> {
      let #(id, _) = ids.mint_session(generator)
      let text = ids.session_id_to_string(id)
      let record =
        catalogue.Registration(
          id: text,
          path: filepath.join(directory, text <> ".db"),
          workspace: request.workspace,
          name: request.name,
          configuration: request.configuration,
          created_at: ids.session_id_timestamp_ms(id),
          request_key: request.request_key,
          state: catalogue.Reserved,
        )
      use selected <- result.try(select_creation_domain(
        store,
        record,
        scope,
        configuration,
        filepath.directory_name(directory),
      ))
      domain.reserve_session(store, record, selected)
    }
    Error(error) -> Error(error)
  }
}

fn select_creation_domain(
  store,
  record: catalogue.Registration,
  scope,
  configuration,
  state_root,
) {
  let configuration = case record.configuration {
    "" -> configuration
    explicit -> explicit
  }
  case domain.get(store, domain.key(scope, record.workspace, record.id)) {
    Ok(existing) -> Ok(existing)
    Error(catalogue.Missing) ->
      Ok(domain_record(record, scope, configuration, state_root))
    Error(error) -> Error(error)
  }
}

fn domain_record(
  record: catalogue.Registration,
  scope,
  configuration,
  state_root,
) {
  let directory = case scope {
    domain.WorkspacePrivate -> {
      let hash =
        record.workspace
        |> bit_array.from_string
        |> bootstrap.sha256
        |> bit_array.base16_encode
        |> string.lowercase
      state_root <> "/workspaces/" <> hash
    }
    domain.SessionOnly -> state_root <> "/domains/sessions/" <> record.id
  }
  domain.Domain(
    domain.key(scope, record.workspace, record.id),
    scope,
    record.workspace,
    configuration,
    directory <> "/loom-memory.db",
    directory <> "/loom-search.db",
  )
}

fn admit(
  phase: Phase,
  book: Book(instance),
  id: String,
) -> #(Book(instance), Result(Status, Error)) {
  case phase, dict.get(book.slots, id) {
    ShuttingDown, _ -> #(book, Error(Unavailable))
    Ready, Ok(Slot(phase: WaitingForDomain, operation:, ..))
    | Ready, Ok(Slot(phase: Building, operation:, ..))
    -> #(book, Ok(Opening(operation)))
    Ready, Ok(Slot(phase: Running(_), operation:, ..)) -> #(
      book,
      Ok(Resident(operation)),
    )
    Ready, Ok(Slot(phase: Closing, ..))
    | Ready, Ok(Slot(phase: Blocked(_), ..))
    -> #(book, Error(Unavailable))
    Ready, Error(Nil) -> new_slot(book, id)
  }
}

fn new_slot(
  book: Book(instance),
  id: String,
) -> #(Book(instance), Result(Status, Error)) {
  case dict.size(book.slots) >= book.limit {
    True -> #(book, Error(Capacity))
    False ->
      case catalogue.get(book.catalogue, id) {
        Error(error) -> #(book, Error(Catalogue(error)))
        Ok(catalogue.Registration(state: catalogue.Reserved, ..)) -> #(
          book,
          Error(NotInitialized),
        )
        Ok(record) -> prepare_slot(book, record)
      }
  }
}

fn prepare_slot(
  book: Book(instance),
  record: catalogue.Registration,
) -> #(Book(instance), Result(Status, Error)) {
  case domain.for_session(book.catalogue, record.id) {
    Error(error) -> #(book, Error(Catalogue(error)))
    Ok(selected) -> {
      let #(book, admitted) = ensure_domain(book, selected)
      case admitted {
        Error(error) -> #(book, Error(error))
        Ok(operation) -> prepare_domain_slot(book, record, selected, operation)
      }
    }
  }
}

// Capturing immutable metadata before preparation keeps catalogue access inside
// the registry and prevents the builder from choosing paths after admission.
fn prepare_domain_slot(
  book: Book(instance),
  record: catalogue.Registration,
  selected: domain.Domain,
  domain_operation: String,
) -> #(Book(instance), Result(Status, Error)) {
  let results = process.new_subject()
  let faults = process.new_subject()
  let failures = process.new_subject()
  let operation = book.epoch <> ":" <> int.to_string(book.next)
  case
    host.prepare(
      build: fn(owner) {
        use services <- result.try(
          call.try_call(book.commands, waiting: 5000, sending: DomainServices(
            selected.id,
            domain_operation,
            _,
          ))
          |> result.unwrap(Error("domain registry is unavailable")),
        )
        book.assembly.build(record, selected, services, owner)
      },
      fatal: book.assembly.fatal,
      results:,
      faults:,
      failures:,
    )
  {
    Error(reason) -> #(book, Error(Preparation(reason)))
    Ok(host) -> {
      let watch = process.monitor(host.owner(host))
      let slot =
        Slot(
          domain_id: selected.id,
          host:,
          operation:,
          phase: WaitingForDomain,
          watch:,
          results:,
          faults:,
          failures:,
        )
      let book =
        Book(
          ..book,
          next: book.next + 1,
          slots: dict.insert(book.slots, record.id, slot),
          domains: depend(book.domains, selected.id, 1),
        )

      // The reservation and original monitor exist before recovery can run.
      #(activate_domain_slots(book, selected.id), Ok(Opening(operation)))
    }
  }
}

// Admission against a retained domain. A domain fenced while it had no
// dependent session is revived here rather than refused: its services never
// stopped, and refusing would make every open in the workspace fail for the
// length of a maintenance pass, which by default is ten minutes. A fence taken
// on the way to retirement is not revivable, because the cancellation that
// follows it has already been decided.
fn ensure_domain(book: Book(instance), selected: domain.Domain) {
  case dict.get(book.domains, selected.id) {
    Ok(DomainSlot(phase: DomainPreparing, operation:, ..))
    | Ok(DomainSlot(phase: DomainRunning(_), operation:, ..)) -> #(
      book,
      Ok(operation),
    )
    Ok(
      DomainSlot(phase: DomainQuiescing(Idle, services), operation:, ..) as slot,
    ) ->
      case domain_service.resume(services) {
        // The withdrawn fence's account, if it is ever sent, must not be
        // taken for a later fence's settle. The worker sends a reply from its
        // own turn, so one decided before this revival can still reach this
        // registry after a second quiesce has been issued. A fresh subject
        // per fence makes that account unselectable: the selector is rebuilt
        // from the book every step, and only the current subject is in it.
        Ok(Nil) -> #(
          Book(
            ..book,
            domains: dict.insert(
              book.domains,
              selected.id,
              DomainSlot(
                ..slot,
                phase: DomainRunning(services),
                settled: process.new_subject(),
              ),
            ),
          ),
          Ok(operation),
        )

        // The maintenance worker did not take the resume, which says its
        // custody is already lost. That is what a refused quiesce says too,
        // and it is answered the same way: the domain fails, every session
        // naming it is stopped, and this admission is refused rather than
        // joining a domain nobody owns.
        Error(reason) -> #(
          domain_failed(book, selected.id, operation, reason),
          Error(Unavailable),
        )
      }

    // The settled pass this domain is still waiting on is answered on the
    // slot's own `settled` subject, and `domain_settled` ignores an account
    // whose phase is no longer quiescing, so a revived domain needs no guard
    // against the reply it has already asked for.
    Ok(DomainSlot(phase: DomainQuiescing(Retiring, _), ..))
    | Ok(DomainSlot(phase: DomainClosing, ..))
    | Ok(DomainSlot(phase: DomainDrained, ..))
    | Ok(DomainSlot(phase: DomainWaitingFailure(_), ..))
    | Ok(DomainSlot(phase: DomainBlocked(_), ..)) -> #(book, Error(Unavailable))
    Error(Nil) -> prepare_shared_domain(book, selected)
  }
}

// The dependent count is the answer to "may this domain be fenced", and it is
// maintained at the two places a session slot enters or leaves the book rather
// than folded out of the slots on every message.
fn depend(domains: Dict(String, DomainSlot), id: String, by: Int) {
  case dict.get(domains, id) {
    Ok(slot) ->
      dict.insert(
        domains,
        id,
        DomainSlot(..slot, dependents: slot.dependents + by),
      )
    Error(Nil) -> domains
  }
}

fn prepare_shared_domain(book: Book(instance), selected: domain.Domain) {
  case dict.size(book.domains) >= book.limit {
    True -> #(book, Error(Capacity))
    False -> {
      let results = process.new_subject()
      let faults = process.new_subject()
      let failures = process.new_subject()
      let operation = book.epoch <> ":domain:" <> int.to_string(book.next)

      // Enumeration runs on whichever process resolves sources — the domain
      // builder, and later each maintenance pass — never in the registry's own
      // handler. The registry answers one bounded page per turn, so a domain
      // near the source cap costs a few short turns instead of one turn that
      // parks every queued authorization behind five hundred catalogue reads.
      let commands = book.commands
      let sources = fn() { collect_sources(commands, selected.id, "", [], 0) }
      case
        host.prepare(
          build: fn(owner) {
            book.assembly.domain_build(selected, sources, owner)
          },
          fatal: domain_service.children,
          results:,
          faults:,
          failures:,
        )
      {
        Error(reason) -> #(book, Error(Preparation(reason)))
        Ok(host) -> {
          let slot =
            DomainSlot(
              host,
              operation,
              DomainPreparing,
              process.monitor(host.owner(host)),
              results,
              faults,
              failures,
              process.new_subject(),
              0,
            )
          let book =
            Book(
              ..book,
              next: book.next + 1,
              domains: dict.insert(book.domains, selected.id, slot),
            )
          host.begin(host)
          #(book, Ok(operation))
        }
      }
    }
  }
}

// Waiting sessions already own parked hosts and consume ordinary capacity. No
// extra waiter process or unbounded continuation book is required.
fn activate_domain_slots(book: Book(instance), id: String) {
  case dict.get(book.domains, id) {
    Ok(DomainSlot(phase: DomainRunning(_), ..)) -> {
      let slots =
        dict.map_values(book.slots, fn(_, slot) {
          case slot.domain_id == id, slot.phase {
            True, WaitingForDomain -> {
              host.begin(slot.host)
              Slot(..slot, phase: Building)
            }
            _, _ -> slot
          }
        })
      Book(..book, slots:)
    }
    Ok(_) | Error(Nil) -> book
  }
}

fn domain_opened(book: Book(instance), id, operation, outcome) {
  case dict.get(book.domains, id) {
    Ok(slot) if slot.operation == operation ->
      case slot.phase, outcome {
        DomainPreparing, Ok(services) ->
          activate_domain_slots(
            Book(
              ..book,
              domains: dict.insert(
                book.domains,
                id,
                DomainSlot(..slot, phase: DomainRunning(services)),
              ),
            ),
            id,
          )
        DomainPreparing, Error(reason) ->
          domain_failed(book, id, operation, reason)
        _, _ -> book
      }
    Ok(_) | Error(Nil) -> book
  }
}

fn domain_failed(book: Book(instance), id, operation, reason) {
  case dict.get(book.domains, id) {
    Ok(DomainSlot(phase: DomainDrained, ..)) -> book
    Ok(DomainSlot(phase: DomainBlocked(_), ..)) -> book
    Ok(DomainSlot(phase: DomainWaitingFailure(_), ..)) -> book
    Ok(slot) if slot.operation == operation -> {
      let book =
        Book(
          ..book,
          domains: dict.insert(
            book.domains,
            id,
            DomainSlot(..slot, phase: DomainWaitingFailure(reason)),
          ),
        )
      dict.fold(book.slots, book, fn(book, session_id, session) {
        case session.domain_id == id {
          True -> stop_slot(book, session_id)
          False -> book
        }
      })
    }
    Ok(_) | Error(Nil) -> book
  }
}

fn domain_retired(book: Book(instance), id, operation, reason) {
  case dict.get(book.domains, id) {
    Ok(slot) if slot.operation == operation ->
      case reason {
        process.Normal -> {
          process.demonitor_process(slot.watch)
          let book =
            Book(
              ..book,
              domains: dict.insert(
                book.domains,
                id,
                DomainSlot(..slot, phase: DomainDrained),
              ),
            )
          dict.fold(book.slots, book, fn(book, session_id, session) {
            case session.domain_id == id {
              True -> stop_slot(book, session_id)
              False -> book
            }
          })
        }
        reason -> domain_failed(book, id, operation, string.inspect(reason))
      }
    Ok(_) | Error(Nil) -> book
  }
}

fn clean_session_retired(book: Book(instance), id, session_id) {
  case dict.get(book.domains, id), catalogue.get(book.catalogue, session_id) {
    Ok(DomainSlot(phase: DomainRunning(services), operation:, ..)),
      Ok(catalogue.Registration(state: catalogue.Saved, ..))
    ->
      case domain_service.notify_closed(services) {
        Ok(Nil) -> book
        Error(reason) -> domain_failed(book, id, operation, reason)
      }
    _, _ -> book
  }
}

// The admission phase decides whether a fence may later be lifted, so it is
// passed in rather than re-derived where the fence is taken: a domain quiesced
// while the daemon is draining must never be handed back to a new session.
fn close_unused_domains(phase: Phase, book: Book(instance)) {
  let quiescence = case phase {
    Ready -> Idle
    ShuttingDown -> Retiring
  }
  dict.fold(book.domains, book, fn(book, id, slot) {
    case slot.dependents > 0 {
      True -> book
      False -> close_unused_domain(book, id, slot, quiescence)
    }
  })
}

fn close_unused_domain(
  book: Book(instance),
  id,
  slot: DomainSlot,
  quiescence: Quiescence,
) {
  case slot.phase {
    DomainRunning(services) ->
      case domain_service.quiesce(services, slot.settled) {
        Ok(Nil) ->
          Book(
            ..book,
            domains: dict.insert(
              book.domains,
              id,
              DomainSlot(..slot, phase: DomainQuiescing(quiescence, services)),
            ),
          )
        Error(reason) -> domain_failed(book, id, slot.operation, reason)
      }
    DomainPreparing -> {
      host.cancel(slot.host)
      Book(
        ..book,
        domains: dict.insert(
          book.domains,
          id,
          DomainSlot(..slot, phase: DomainClosing),
        ),
      )
    }
    DomainDrained -> Book(..book, domains: dict.delete(book.domains, id))
    DomainWaitingFailure(reason) -> {
      host.cancel(slot.host)
      Book(
        ..book,
        domains: dict.insert(
          book.domains,
          id,
          DomainSlot(..slot, phase: DomainBlocked(reason)),
        ),
      )
    }
    DomainQuiescing(_, _) | DomainClosing | DomainBlocked(_) -> book
  }
}

fn domain_settled(book: Book(instance), id, operation) {
  case dict.get(book.domains, id) {
    Ok(DomainSlot(phase: DomainQuiescing(_, _), ..) as slot)
      if slot.operation == operation
    -> {
      host.cancel(slot.host)
      Book(
        ..book,
        domains: dict.insert(
          book.domains,
          id,
          DomainSlot(..slot, phase: DomainClosing),
        ),
      )
    }
    Ok(_) | Error(Nil) -> book
  }
}

// `storage/domain.sources` answers at most this many identities per call, and
// the registry resolves at most that many registrations in one turn. Both
// halves of a page therefore cost one bounded handler turn each.
const source_page = 100

// The bounded total a domain may contribute to recall. An oversized domain is
// refused rather than silently truncated to an authorized-looking prefix.
const source_limit = 512

// The page walk runs on the caller's process, one registry call per half-page,
// so the cap is enforced here rather than inside a handler turn. SQL filters
// Saved state before pagination; this only bounds how much of it is admitted.
fn collect_sources(
  commands: Subject(Message(instance)),
  id: String,
  after: String,
  accumulated: List(distill.Source),
  count: Int,
) -> Result(List(distill.Source), String) {
  use identities <- result.try(
    call.try_call(commands, waiting: 5000, sending: DomainSourceIds(
      id,
      after,
      _,
    ))
    |> result.unwrap(Error("domain source registry is unavailable")),
  )
  let total = count + list.length(identities)
  use <- bool.guard(
    when: total > source_limit,
    return: Error("domain exceeds the bounded source limit"),
  )
  use sources <- result.try(
    call.try_call(commands, waiting: 5000, sending: DomainSourcePaths(
      identities,
      _,
    ))
    |> result.unwrap(Error("domain source registry is unavailable")),
  )

  // A short page is the last one, and so is a page the walk cannot advance
  // past: both end the enumeration rather than asking the same page again.
  let accumulated = list.append(accumulated, sources)
  case list.drop(identities, source_page - 1) == [], list.last(identities) {
    True, _ | _, Error(Nil) -> Ok(accumulated)
    False, Ok(last) -> collect_sources(commands, id, last, accumulated, total)
  }
}

// A caller may only hand back a page this registry itself produced, and the
// guard states that rather than trusting it: an oversized list would put the
// unbounded catalogue walk back inside the handler this split exists to keep
// short.
fn source_paths(
  store: catalogue.Catalogue,
  identities: List(String),
) -> Result(List(distill.Source), String) {
  use <- bool.guard(
    when: list.drop(identities, source_page) != [],
    return: Error("domain source page exceeds the bounded read limit"),
  )
  list.try_map(identities, fn(id) {
    use record <- result.try(
      catalogue.get(store, id) |> result.map_error(string.inspect),
    )
    use session <- result.try(
      ids.parse_session_id(id)
      |> result.replace_error("invalid domain source identity"),
    )
    Ok(distill.Source(session, record.path))
  })
}

// The three checks are ordered widest fence inwards. A caller addressing a
// previous daemon has nothing here to resolve, and an attachment whose
// incarnation is gone must not have its credential read at all: the answer is
// already no, and reading it would make a stale socket a way to probe
// membership.
fn frame_authorized(
  book: Book(instance),
  epoch: String,
  id: String,
  incarnation: String,
  digest: access.Digest,
) -> Result(#(access.Principal, access.Authority), FrameRefusal) {
  use Nil <- result.try(case epoch == book.epoch {
    True -> Ok(Nil)
    False -> Error(StaleEpoch)
  })
  use Nil <- result.try(case dict.get(book.slots, id) {
    Ok(Slot(phase: Running(_), operation:, ..)) if operation == incarnation ->
      Ok(Nil)
    Ok(Slot(..)) | Error(Nil) -> Error(StaleIncarnation)
  })
  {
    use principal <- result.try(access.authenticate(book.catalogue, digest))
    use authority <- result.try(access.authorization(
      book.catalogue,
      principal.id,
      id,
    ))
    Ok(#(principal, authority))
  }
  |> result.replace_error(Unauthorized)
}

fn stop_slot(book: Book(instance), id: String) -> Book(instance) {
  case dict.get(book.slots, id) {
    Error(Nil) | Ok(Slot(phase: Blocked(_), ..)) -> book
    Ok(slot) -> {
      host.cancel(slot.host)
      Book(
        ..book,
        slots: dict.insert(book.slots, id, Slot(..slot, phase: Closing)),
      )
    }
  }
}

fn opened(
  book: Book(instance),
  id: String,
  operation: String,
  outcome: Result(instance, String),
) -> Book(instance) {
  case dict.get(book.slots, id) {
    Ok(slot) if slot.operation == operation ->
      case slot.phase, outcome {
        Building, Ok(instance) ->
          case catalogue.confirm(book.catalogue, id) {
            Error(error) -> failed(book, id, operation, string.inspect(error))
            Ok(_record) ->
              Book(
                ..book,
                slots: dict.insert(
                  book.slots,
                  id,
                  Slot(..slot, phase: Running(instance)),
                ),
              )
          }
        Building, Error(_reason) -> stop_slot(book, id)
        WaitingForDomain, _ | Closing, _ | Blocked(_), _ | Running(_), _ -> book
      }
    Ok(_) | Error(Nil) -> book
  }
}

// An assembly fault means Weft's ordered cleanup has already started, so the
// slot is closing rather than blocked: its witness will exit normally and
// `retired` will release the reservation. Answering `Blocked` here would tell
// an operator the daemon can never be replaced, and would make `stop_slot` a
// no-op on a slot that is merely mid-fault when shutdown arrives. The reason
// is deliberately not retained: `Closing` is a claim about ordering, and the
// reservation it holds is released by drain rather than by diagnosis.
fn faulted(
  book: Book(instance),
  id: String,
  operation: String,
) -> Book(instance) {
  case dict.get(book.slots, id) {
    Ok(slot) if slot.operation == operation -> stop_slot(book, id)
    Ok(_) | Error(Nil) -> book
  }
}

// A cleanup failure is the other half: its holder stays alive by design, so no
// normal exit can ever arrive and the reservation is genuinely unrecoverable.
fn failed(
  book: Book(instance),
  id: String,
  operation: String,
  reason: String,
) -> Book(instance) {
  case dict.get(book.slots, id) {
    Ok(slot) if slot.operation == operation -> {
      host.cancel(slot.host)
      Book(
        ..book,
        slots: dict.insert(book.slots, id, Slot(..slot, phase: Blocked(reason))),
      )
    }
    Ok(_) | Error(Nil) -> book
  }
}

// A `Normal` witness exit is the only proof that releases a reservation, and
// it is deliberately checked without consulting `slot.phase`. A slot may be
// building, closing, or mid-fault when its custody drains, and in every one of
// those cases the drain is complete and the slot must go; making the release
// conditional on the phase would strand a reservation whose resources are
// already gone. Every other exit reason is lost proof and blocks instead.
fn retired(
  book: Book(instance),
  id: String,
  operation: String,
  reason: process.ExitReason,
) -> Book(instance) {
  case dict.get(book.slots, id) {
    Ok(slot) if slot.operation == operation ->
      case reason {
        process.Normal -> {
          process.demonitor_process(slot.watch)
          let book =
            Book(
              ..book,
              slots: dict.delete(book.slots, id),
              domains: depend(book.domains, slot.domain_id, -1),
            )
          clean_session_retired(book, slot.domain_id, id)
        }
        _ -> failed(book, id, operation, string.inspect(reason))
      }
    Ok(_) | Error(Nil) -> book
  }
}

fn status(book: Book(instance), id: String) -> Status {
  case dict.get(book.slots, id) {
    Error(Nil) -> Saved
    Ok(Slot(phase: WaitingForDomain, operation:, ..))
    | Ok(Slot(phase: Building, operation:, ..)) -> Opening(operation)
    Ok(Slot(phase: Running(_), operation:, ..)) -> Resident(operation)
    Ok(Slot(phase: Closing, operation:, ..)) -> Stopping(operation)
    Ok(Slot(phase: Blocked(reason), ..)) -> RecoveryBlocked(reason)
  }
}

fn step(
  phase: Phase,
  book: Book(instance),
) -> sm.Step(Phase, Book(instance), Message(instance), sm.Postponable) {
  let book = close_unused_domains(phase, book)
  case phase, dict.size(book.slots), dict.size(book.domains) {
    ShuttingDown, 0, 0 -> sm.stop()
    _, _, _ -> sm.transition(phase, book) |> sm.with_selector(selector(book))
  }
}

// Rebuild the selector from the bounded live slots. Completed incarnations do
// not leave monitor handlers or reply subjects accumulating across reopen cycles.
fn selector(book: Book(instance)) -> process.Selector(Message(instance)) {
  let base =
    process.new_selector()
    |> process.select(book.commands)
    |> process.select_trapped_exits(fn(exit) { LinkedExit(exit.pid) })
  let base =
    dict.fold(book.domains, base, fn(selector, id, slot) {
      selector
      |> process.select_map(slot.results, fn(outcome) {
        DomainOpened(id, slot.operation, outcome)
      })
      |> process.select_map(slot.faults, fn(reason) {
        DomainFailed(id, slot.operation, reason)
      })
      |> process.select_map(slot.failures, fn(failure) {
        DomainFailed(id, slot.operation, string.inspect(failure))
      })
      |> process.select_map(slot.settled, fn(account) {
        DomainSettled(id, slot.operation, account)
      })
      |> process.select_specific_monitor(slot.watch, fn(down) {
        DomainRetired(id, slot.operation, down.reason)
      })
    })
  dict.fold(book.slots, base, fn(selector, id, slot) {
    selector
    |> process.select_map(slot.results, fn(outcome) {
      Opened(id, slot.operation, outcome)
    })
    |> process.select_map(slot.faults, fn(_reason) {
      Faulted(id, slot.operation)
    })
    |> process.select_map(slot.failures, fn(failure) {
      Failed(id, slot.operation, string.inspect(failure))
    })
    |> process.select_specific_monitor(slot.watch, fn(down) {
      Retired(id, slot.operation, down.reason)
    })
  })
}

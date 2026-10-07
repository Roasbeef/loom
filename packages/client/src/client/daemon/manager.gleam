//// Daemon admission over durable metadata and independently owned instances.
////
//// Listing and status inspect the catalogue without assembling a session. An
//// explicit open reserves one bounded slot, installs the original custody
//// monitor, and only then releases its parked builder. Heavy assembly and
//// cleanup run outside this actor. Concurrent opens for one identity return
//// the same operation; stopping never frees its slot before confirmed drain.
//// A fresh session may reserve a parked host while its domain is closing. The
//// original domain witness must exit normally before replacement can begin;
//// the accepted session operation remains observable throughout that wait.
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
////
//// ## Flow
////
//// `start` → `handle` → `admit` → `prepare_slot` → `opened` → `retired`
////
//// 1. `start` builds the empty `Book` and runs the registry as a weft state
////    machine whose `Phase` is `Ready` until `Shutdown` or the starter's death.
//// 2. `handle` receives one `Message` and returns the next book through
////    `step`; every public function sends one of them and awaits the reply.
//// 3. `admit` answers an open from the existing slot, or `new_slot` reserves
////    one against the limit and `prepare_slot` selects its domain.
//// 4. `ensure_domain` finds or builds the shared domain services, and
////    `prepare_domain_slot` parks the session builder as `WaitingForDomain`.
//// 5. `domain_opened` publishes the services, and `activate_domain_slots`
////    releases each parked builder with `host.begin`.
//// 6. `opened` records the built instance as `Running` once the catalogue
////    confirms it; `failed` and `faulted` route a refusal into cleanup.
//// 7. `stop_slot` orders cleanup, and `retired` frees the slot only on the
////    witness's normal exit, after which `close_unused_domains` may retire
////    the domain itself.
//// 8. `step` rebuilds the `selector` and stops once `ShuttingDown` has no slots
////    or domains left.

import broker/internal/call
import broker/internal/ffi_crypto
import client/daemon/domain as domain_service
import client/distill
import client/distillpass
import client/internal/instance_host as host
import client/internal/instance_owner as custody
import core/glance
import core/ids
import filepath
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import storage/access
import storage/catalogue
import storage/domain
import telemetry/owner
import weft/state_machine as sm

/// Live lifecycle state, joined with the durable initialization the registry
/// would refuse an open against.
pub type Status {
  /// A creation reserved this identity and never reconciled it, so no
  /// database stands behind it and only a create retry can complete it.
  Reserved

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

  /// An archived registration requires explicit restoration before admission.
  SessionArchived

  /// Every runtime slot is reserved, including stopping and blocked slots.
  Capacity

  /// This session is stopping or blocked, or the daemon is shutting down.
  Unavailable

  /// The operation no longer names the retained incarnation of this session.
  StaleOperation

  /// This exact operation's builder returned an error. Distinct from
  /// `StaleOperation`, which claims the request was overtaken. The reason is
  /// one line of at most 2048 UTF-8 bytes, available only through authorized
  /// reads of this exact operation.
  StartFailed(reason: String)

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
    /// The model profile the session is created under, or `None` for the
    /// configuration's default roles. It is retained with the registration and
    /// resolved again by every open (protocol-change/076).
    profile: Option(String),
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
      Manager(instance),
    ) -> Result(instance, String),
    /// Root deaths which make the instance unusable.
    fatal: fn(instance) -> List(#(String, Pid)),
    /// Hands one resident instance back whatever it still holds, at the
    /// moment it is reachable and its peers are still live.
    ///
    /// This is the graceful-drain hook. A daemon shutdown has to return the
    /// hub's held prompts to their submitters *before* the session sockets
    /// those returns travel over are killed, and the instance is opaque to
    /// the root that orders that teardown. So the assembly — which already
    /// knows how to build an instance — also knows how to drain one, and the
    /// registry calls it on every resident slot while the peers are alive.
    /// It is `Nil`-returning and must be safe to run on an already-drained
    /// instance, because a session may be drained once by the root and once
    /// by its own close.
    ///
    /// The second argument is the caller's remaining budget in
    /// milliseconds. The registry spends one shared deadline across every
    /// resident instance rather than handing each its own, because the
    /// caller is a bounded shutdown: N instances at a per-instance budget
    /// would make the worst case N times that budget, and the root that
    /// ordered the drain would have killed the sockets before the last
    /// instance finished. An implementation returns when its own work is
    /// done or the budget is spent, whichever comes first.
    drain: fn(instance, Int) -> Nil,
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
    /// Immutable paths and scope used when a drained domain is replaced.
    selected: domain.Domain,
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
  /// A session's first accepted prompt, to be reduced to its subtitle. There
  /// is no reply: the sender is a hub that must not wait on the registry.
  SeedSubtitle(String, String)

  /// A folder a session was just created in, to be remembered. There is no
  /// reply: the creation has already succeeded and a failed write only means
  /// the folder is not offered again.
  RememberFolder(String)

  /// The remembered folders, newest first.
  RecentFolders(Subject(Result(List(catalogue.Recent), Error)))

  /// Forget the remembered folder with this identity.
  ForgetFolder(Int, Subject(Result(Nil, Error)))
  Rename(
    access.Digest,
    String,
    String,
    String,
    Subject(Result(View, AdminError)),
  )
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

  /// Binds a credential digest to a claim at a wall-clock instant; the only
  /// writer of the credential table besides `Administer`.
  Claim(
    access.ClaimDigest,
    access.Digest,
    Option(String),
    Int,
    Subject(Result(access.Claimed, ClaimError)),
  )

  /// The browser claim: `Claim` for a `Browser` digest, with the instant the
  /// login it binds ends.
  ClaimLogin(
    access.ClaimDigest,
    access.Digest,
    Option(String),
    Int,
    Int,
    Subject(Result(access.Claimed, ClaimError)),
  )

  /// The `/v2/claim` upgrade's filter: the claim exists and is not void.
  ClaimKnown(access.ClaimDigest, Subject(Result(Nil, Error)))

  /// Writes a browser login's row: the principal, the digest of the token's
  /// identifier, when it began, when it ends and the login it came from. It is
  /// the daemon's own act at an exchange, so it carries no credential.
  IssueLogin(
    String,
    access.Digest,
    Int,
    Int,
    Option(String),
    Subject(Result(Nil, Error)),
  )

  /// A login's resume: the row is active, is a login, and names this
  /// principal. Records the resume at most once an hour.
  ResumeLogin(
    access.Digest,
    String,
    Int,
    Subject(Result(access.Principal, Error)),
  )

  /// Revokes every active login, which a start that drew a new root key does.
  RevokeAllLogins(Subject(Result(Int, Error)))

  /// A principal's sign-in listing, read as the caller or, for the owner, as
  /// another principal.
  Signins(
    access.Digest,
    Option(String),
    String,
    Int,
    Subject(Result(#(String, access.SigninPage), AdminError)),
  )

  /// One sign-in revoked, as its principal or as the owner.
  RevokeLogin(
    access.Digest,
    String,
    Option(String),
    String,
    Subject(Result(#(String, access.Digest), AdminError)),
  )

  /// Every sign-in of one principal revoked, as that principal or the owner.
  RevokeLogins(
    access.Digest,
    String,
    Option(String),
    Subject(Result(#(String, Int), AdminError)),
  )

  /// One principal's display name changed, as that principal or the owner
  /// (protocol-change/065, PR 10). The name is the unjudged text the caller
  /// typed; the catalogue trims and checks it in the transaction that writes.
  RenamePrincipal(
    access.Digest,
    String,
    Option(String),
    String,
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
  AuthorizedRoles(
    access.Digest,
    Subject(Result(List(#(String, access.Role)), Error)),
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
  SetVisibility(
    access.Digest,
    String,
    String,
    catalogue.Visibility,
    Subject(Result(View, AdminError)),
  )
  ArchivedPage(
    access.Digest,
    String,
    Subject(Result(#(Int, List(View)), AdminError)),
  )
  PrincipalPage(
    access.Digest,
    String,
    Int,
    Subject(Result(access.ListingPage, AdminError)),
  )
  MembershipPage(
    access.Digest,
    String,
    String,
    Subject(Result(access.MembershipPage, AdminError)),
  )
  SessionMemberPage(
    access.Digest,
    String,
    String,
    Subject(Result(Members, AdminError)),
  )
  Delete(
    access.Digest,
    String,
    String,
    String,
    Subject(Result(catalogue.Registration, AdminError)),
  )
  WorkspaceDefault(String, Subject(Result(View, Error)))
  SetDefault(String, String, Subject(Result(View, Error)))
  Open(String, Subject(Result(Status, Error)))
  StopSession(String, Subject(Result(Status, Error)))
  StopIncarnation(String, String, Subject(Result(Status, Error)))
  Get(String, Subject(Result(View, Error)))
  Unshared(Subject(List(String)))
  Page(String, Subject(Result(#(Int, List(View)), Error)))
  Resolve(String, Subject(Result(instance, Error)))
  ResolveIncarnation(String, String, Subject(Result(instance, Error)))
  Operation(String, String, Subject(Result(View, Error)))
  Shutdown

  /// Snapshots resident drain capabilities without invoking user callbacks.
  /// Delivery revalidates authority through this actor, so it must keep serving.
  DrainHeld(Subject(List(fn(Int) -> Nil)))
  Opened(String, String, Result(instance, String))
  Faulted(String, String)
  Failed(String, String, String)
  Retired(String, String, process.ExitReason)
  LinkedExit(Pid)
}

/// The registry's whole state besides its phase: the catalogue it reads, the
/// slots and domains it reserves, and the credential table. `handle` threads
/// one `Book` through every message and `step` returns the next.
type Book(instance) {
  Book(
    catalogue: catalogue.Catalogue,
    assembly: Assembly(instance),
    limit: Int,
    epoch: String,
    next: Int,
    slots: Dict(String, Slot(instance)),
    // The operation of the most recent build that returned an error, per
    // session. A failed build's slot is deleted as soon as its cleanup drains,
    // which is usually before the requesting terminal's first poll, so without
    // this the poll finds no slot and is answered `StaleOperation` — telling
    // an operator their request was overtaken when in truth it failed. One
    // entry per session, capped at `limit`, cleared when that session opens
    // again; see `remember_failure`.
    failed_operations: Dict(String, #(String, String)),
    domains: Dict(String, DomainSlot),
    commands: Subject(Message(instance)),
    parent: Pid,
    authority: Dict(
      #(access.Digest, String),
      #(access.Principal, access.Authority),
    ),
  )
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

/// One owner-only mutation; bearer and claim values never enter the
/// registry, only their digests.
@internal
pub type Administration {
  /// Creates a permanently reserved member ID, its enrollment (an open claim
  /// or the invitee's own credential digest), and its first session grant.
  Invite(
    id: String,
    name: String,
    enrollment: access.Enrollment,
    session_id: String,
    role: access.Role,
  )

  /// Changes one existing member's session grant.
  SetRole(id: String, session_id: String, role: access.Role)

  /// Removes one session grant without revoking unrelated memberships.
  RevokeMembership(id: String, session_id: String)

  /// Voids the open claim, revokes every active member credential, and
  /// inserts one replacement enrollment.
  RotateMember(id: String, enrollment: access.Enrollment)

  /// Revokes all member credentials and voids the open claim while retaining
  /// the recovery identity.
  RevokeMember(id: String)
}

/// Why a claim bound nothing. Neither variant carries a digest.
@internal
pub type ClaimError {
  /// The catalogue refused the claim, with the reason the claim socket
  /// reports.
  ClaimRefused(refusal: access.ClaimRefusal)

  /// The registry is draining, died, or did not answer in time. The claim may
  /// or may not have bound; presenting the same claim and digest again
  /// answers which.
  ClaimUnavailable
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

  /// A live reservation still owns this session, so its files are still in
  /// use. Deletion is refused rather than stopping the session on the
  /// caller's behalf: the caller stops it and observes the drain first.
  AdminBusy

  /// The registration names a database outside the daemon's own sessions
  /// directory, so the unlink is refused before any file is touched. Only a
  /// hand-edited or migrated row can reach this, and the alternative is a
  /// recursive removal of whatever directory that row happens to name.
  AdminForeignPath

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

/// Redeems a claim for the presented credential digest in one serialized
/// dispatch, like every administration mutation.
///
/// `name` is the invitee's chosen display name, or `None` to keep the
/// inviter's; it is applied in the transaction that binds the credential, and
/// a refused name (`InvalidClaimName`) binds nothing.
///
/// `now_ms` is the wall-clock instant the expiry is judged against and the
/// one recorded as the claim instant. A timeout is an unknown outcome; the
/// claim socket reports it as `unavailable`, and a rerun with the same claim
/// and digest either completes or refuses.
///
/// ## Examples
///
/// ```gleam
/// // manager.claim(registry, claim, credential, None, now_ms: bootstrap.system_time_ms())
/// ```
@internal
pub fn claim(
  manager: Manager(instance),
  claim: access.ClaimDigest,
  credential: access.Digest,
  name: Option(String),
  now_ms now_ms: Int,
) -> Result(access.Claimed, ClaimError) {
  call.try_call(manager.commands, waiting: 5000, sending: Claim(
    claim,
    credential,
    name,
    now_ms,
    _,
  ))
  |> result.unwrap(Error(ClaimUnavailable))
}

/// Redeems a claim for a browser login (protocol-change/065, PR 9): `claim` with
/// a `Browser` digest, which the catalogue writes as a login row ending at
/// `expires_at_ms`, so the sign-in lists with its expiry as every other does.
/// The name, the clock and the unknown outcome are `claim`'s.
///
/// ## Examples
///
/// ```gleam
/// // manager.claim_login(registry, claim, login, None, now_ms:, expires_at_ms:)
/// ```
@internal
pub fn claim_login(
  manager: Manager(instance),
  claim: access.ClaimDigest,
  credential: access.Digest,
  name: Option(String),
  now_ms now_ms: Int,
  expires_at_ms expires_at_ms: Int,
) -> Result(access.Claimed, ClaimError) {
  call.try_call(manager.commands, waiting: 5000, sending: ClaimLogin(
    claim,
    credential,
    name,
    now_ms,
    expires_at_ms,
    _,
  ))
  |> result.unwrap(Error(ClaimUnavailable))
}

/// Answers whether a claim exists and is not void, for the `/v2/claim`
/// upgrade. The command, not this check, decides expiry and binding.
///
/// ## Examples
///
/// ```gleam
/// // manager.claim_known(registry, claim)
/// ```
@internal
pub fn claim_known(
  manager: Manager(instance),
  claim: access.ClaimDigest,
) -> Result(Nil, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: ClaimKnown(claim, _))
  |> result.unwrap(Error(Unavailable))
}

/// Records a browser login's row in one serialized dispatch: `principal_id`,
/// the `Browser` digest of the token's identifier, the instants it began and
/// ends (Unix milliseconds) and, for a device link's login, the fingerprint of
/// the login it came from. The daemon calls it at the exchange that sets the
/// login; the caller has already decided the principal may hold one.
///
/// ## Examples
///
/// ```gleam
/// // manager.issue_login(registry, "alice", digest, now, now + thirty_days, None)
/// ```
@internal
pub fn issue_login(
  manager: Manager(instance),
  principal_id: String,
  digest: access.Digest,
  issued_at_ms: Int,
  expires_at_ms: Int,
  issued_by: Option(String),
) -> Result(Nil, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: IssueLogin(
    principal_id,
    digest,
    issued_at_ms,
    expires_at_ms,
    issued_by,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Resumes a login: the row for `digest` must be an active login of
/// `principal_id`, and then the principal is answered and the row's last
/// resume is recorded when it is older than an hour. Any other row, a revoked
/// one or an unknown one is `Catalogue(Missing)`.
///
/// ## Examples
///
/// ```gleam
/// // manager.resume_login(registry, digest, "alice", now_ms)
/// ```
@internal
pub fn resume_login(
  manager: Manager(instance),
  digest: access.Digest,
  principal_id: String,
  now_ms: Int,
) -> Result(access.Principal, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: ResumeLogin(
    digest,
    principal_id,
    now_ms,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Revokes every active browser login of every principal, answering how many.
/// A daemon start that drew a new root key calls it, because no token the old
/// key signed can verify again and the listings would otherwise show them live.
///
/// ## Examples
///
/// ```gleam
/// // manager.revoke_all_logins(registry)
/// ```
@internal
pub fn revoke_all_logins(manager: Manager(instance)) -> Result(Int, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: RevokeAllLogins)
  |> result.unwrap(Error(Unavailable))
}

/// Lists sign-ins, the browser logins of a principal: the caller's own when
/// `target` is `None`, and any principal's when the caller is the owner. A
/// member naming another principal is `AdminForbidden`. The caller is
/// reauthenticated in the registry's own dispatch, as every administration is,
/// so a credential revoked a moment ago reads nothing. `now_ms` is the instant
/// a login's expiry is judged against. The answer names the principal whose
/// sign-ins these are.
///
/// ## Examples
///
/// ```gleam
/// // manager.signins(registry, caller, None, after: "", now_ms: now)
/// ```
@internal
pub fn signins(
  manager: Manager(instance),
  caller: access.Digest,
  target: Option(String),
  after after: String,
  now_ms now_ms: Int,
) -> Result(#(String, access.SigninPage), AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: Signins(
    caller,
    target,
    after,
    now_ms,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Revokes one sign-in, named by its fingerprint: the caller's own when
/// `target` is `None`, and any principal's when the caller is the owner. The
/// caller and the epoch are checked in the same dispatch as the write, and the
/// frame memo is dropped before the reply, so every page the login minted ends
/// at its next frame. The answer is the principal and the login's digest, which
/// the caller logs the fingerprint of.
///
/// ## Examples
///
/// ```gleam
/// // manager.revoke_login(registry, caller, epoch, None, "9c1e0f2ab3d4e5f6")
/// ```
@internal
pub fn revoke_login(
  manager: Manager(instance),
  caller: access.Digest,
  epoch: String,
  target: Option(String),
  fingerprint: String,
) -> Result(#(String, access.Digest), AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: RevokeLogin(
    caller,
    epoch,
    target,
    fingerprint,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Revokes every sign-in of one principal ("sign out everywhere"), under the
/// same rules as `revoke_login`, and answers the principal and how many were
/// active.
///
/// ## Examples
///
/// ```gleam
/// // manager.revoke_logins(registry, caller, epoch, None)
/// ```
@internal
pub fn revoke_logins(
  manager: Manager(instance),
  caller: access.Digest,
  epoch: String,
  target: Option(String),
) -> Result(#(String, Int), AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: RevokeLogins(
    caller,
    epoch,
    target,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Changes one principal's display name: the caller's own when `target` is
/// `None` or names the caller, and any principal's when the caller is the
/// owner (protocol-change/065, PR 10). A member naming another principal is
/// `AdminForbidden`. The caller and the epoch are checked in the same dispatch
/// as the write, the name is judged by the rule a claim's chosen name is
/// (`storage/access.rename`), and the authority memo is dropped before the
/// reply so no later frame reads the old name. A refused name is
/// `AdminMetadata(catalogue.Invalid(_))` and writes nothing. The answer is the
/// principal as renamed. An origin already admitted keeps the name it was
/// admitted under (`core/message`), since the name is read again only when a
/// page or a session is admitted.
///
/// ## Examples
///
/// ```gleam
/// // manager.rename_principal(registry, caller, epoch, None, "Alex")
/// ```
@internal
pub fn rename_principal(
  manager: Manager(instance),
  caller: access.Digest,
  epoch: String,
  target: Option(String),
  name: String,
) -> Result(access.Principal, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: RenamePrincipal(
    caller,
    epoch,
    target,
    name,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Renames metadata after reauthenticating owner and epoch in one dispatch.
///
/// This does not acquire a conversation or alter a resident runtime. The
/// catalogue retains the original creation name for request-key equality.
///
/// ## Examples
///
/// ```gleam
/// // manager.rename(registry, owner_digest, epoch, id, "review auth")
/// ```
@internal
pub fn rename(
  manager: Manager(instance),
  caller: access.Digest,
  epoch: String,
  id: String,
  name: String,
) -> Result(View, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: Rename(
    caller,
    epoch,
    id,
    name,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Seeds a session's subtitle from its first accepted prompt, without waiting.
///
/// The session's own hub calls this once (`gateway.with_first_prompt`), so it
/// carries no credential: no wire message reaches it, and the identity is the
/// one the hub was built for. The write runs in the registry's turn, which
/// serializes it with every other catalogue change, and the catalogue keeps the
/// first subtitle it is given (`catalogue.seed_subtitle`). A failed write leaves
/// the session without a subtitle, which every page already draws as the
/// creation age, so the failure is not reported to the hub.
///
/// ## Examples
///
/// ```gleam
/// // manager.seed_subtitle(registry, session_id, "Fix the flaky retry test")
/// ```
@internal
pub fn seed_subtitle(
  manager: Manager(instance),
  id: String,
  prompt: String,
) -> Nil {
  process.send(manager.commands, SeedSubtitle(id, prompt))
}

/// Remembers a folder a session was just created in, without waiting
/// (protocol-change/074).
///
/// The control command's creation calls this once a session exists, so a folder
/// is remembered whichever surface created in it: the terminal, a control
/// client or a page. It carries no credential, since it is made by the daemon's
/// own code after the creation was authorized, and the write runs in the
/// registry's turn with every other catalogue change. A failed write leaves the
/// folder out of the recent list and nothing else, so it is not reported.
///
/// ## Examples
///
/// ```gleam
/// // manager.remember_folder(registry, "/Users/o/code/app")
/// ```
@internal
pub fn remember_folder(manager: Manager(instance), workspace: String) -> Nil {
  process.send(manager.commands, RememberFolder(workspace))
}

/// Reads the remembered folders, newest first, each with the identity the
/// catalogue gave it.
///
/// This is not an authorization: the caller has already decided that the
/// asking principal is the owner (`ui_socket.recent_for`), since the list is
/// the owner's alone and belongs to no session.
///
/// ## Examples
///
/// ```gleam
/// // manager.recent_folders(registry)
/// ```
@internal
pub fn recent_folders(
  manager: Manager(instance),
) -> Result(List(catalogue.Recent), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: RecentFolders)
  |> result.unwrap(Error(Unavailable))
}

/// Forgets the remembered folder with this identity, as `recent_folders`
/// numbered it. An identity that is gone is not an error.
///
/// ## Examples
///
/// ```gleam
/// // manager.forget_folder(registry, 4)
/// ```
@internal
pub fn forget_folder(
  manager: Manager(instance),
  id: Int,
) -> Result(Nil, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: ForgetFolder(id, _))
  |> result.unwrap(Error(Unavailable))
}

/// Archives or restores a stopped session under owner and epoch authority.
///
/// The slot check and catalogue transaction share one actor turn, so no open
/// can acquire custody between deciding the session is stopped and hiding it.
///
/// ## Examples
///
/// ```gleam
/// // manager.set_visibility(registry, owner, epoch, id, catalogue.Archived)
/// ```
@internal
pub fn set_visibility(
  manager: Manager(instance),
  caller: access.Digest,
  epoch: String,
  id: String,
  visibility: catalogue.Visibility,
) -> Result(View, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: SetVisibility(
    caller,
    epoch,
    id,
    visibility,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Lists only the owner's archived metadata without opening a session.
///
/// ## Examples
///
/// ```gleam
/// // manager.archived_page(registry, owner, after: "")
/// ```
@internal
pub fn archived_page(
  manager: Manager(instance),
  caller: access.Digest,
  after after: String,
) -> Result(#(Int, List(View)), AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: ArchivedPage(
    caller,
    after,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Lists principals with the credential state of each, owner-only.
///
/// The caller is reauthenticated in the registry's own dispatch, as every
/// administration is, so a credential revoked a moment ago reads nothing.
/// `now_ms` is the wall-clock instant an open claim's remaining lifetime is
/// measured from. The page carries fingerprints and lifetimes, never a claim
/// or a bearer.
///
/// ## Examples
///
/// ```gleam
/// // manager.principal_page(registry, owner, after: "", now_ms: now)
/// ```
@internal
pub fn principal_page(
  manager: Manager(instance),
  caller: access.Digest,
  after after: String,
  now_ms now_ms: Int,
) -> Result(access.ListingPage, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: PrincipalPage(
    caller,
    after,
    now_ms,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Lists one principal's session memberships, owner-only.
///
/// ## Examples
///
/// ```gleam
/// // manager.membership_page(registry, owner, "alice", after: "")
/// ```
@internal
pub fn membership_page(
  manager: Manager(instance),
  caller: access.Digest,
  principal_id: String,
  after after: String,
) -> Result(access.MembershipPage, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: MembershipPage(
    caller,
    principal_id,
    after,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// One session's members and the scope it was created with, as
/// `session_member_page` answers them.
///
/// The scope is what the catalogue's domain record holds for the session, and
/// it decides whether the session may be shared at all (`require_shared`), so
/// the owner's page can tell a private session from one an invitation may name
/// before the owner presses anything (protocol-change/065, the addendum on
/// `scope`).
pub type Members {
  Members(
    /// `SessionOnly` for a session that may be shared, `WorkspacePrivate` for
    /// one that shares its notes and history with its workspace.
    scope: domain.Scope,
    /// One page of the session's members in principal order.
    page: access.SessionMemberPage,
  )
}

/// Lists one session's members and its scope, owner-only
/// (protocol-change/065, `sessions.members`).
///
/// The caller is reauthenticated in the registry's own dispatch, as every
/// administration is. An unknown session is `AdminMetadata(Missing)`.
///
/// ## Examples
///
/// ```gleam
/// // manager.session_member_page(registry, owner, session_id, after: "")
/// ```
@internal
pub fn session_member_page(
  manager: Manager(instance),
  caller: access.Digest,
  session_id: String,
  after after: String,
) -> Result(Members, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: SessionMemberPage(
    caller,
    session_id,
    after,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
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
            failed_operations: dict.new(),
            domains: dict.new(),
            commands:,
            parent:,
            authority: dict.new(),
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

/// Removes a stopped session's registration and unlinks its database family.
///
/// Owner and epoch are rechecked in the same dispatch as the mutation, as
/// they are for every other administration. A session the registry still
/// holds a slot for is refused with `AdminBusy`: the reservation means a
/// writer may still hold the file, and the caller stops the session and
/// observes the drain before asking again. Because the durable row goes
/// first, a crash after the transaction leaves files nothing refers to
/// rather than a registration whose database is gone.
///
/// The caller supplies the daemon's own sessions directory, and a row whose
/// path lies outside it is refused with `AdminForeignPath` before the row is
/// removed. Every path the daemon mints is already under that directory, so
/// the check only rejects a row that was hand-edited or migrated in.
///
/// ## Examples
///
/// ```gleam
/// // manager.delete_session(registry, owner_digest, epoch, session_id, sessions)
/// ```
@internal
pub fn delete_session(
  manager: Manager(instance),
  caller: access.Digest,
  epoch: String,
  id: String,
  sessions: String,
) -> Result(catalogue.Registration, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: Delete(
    caller,
    epoch,
    id,
    sessions,
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

/// Lists the active sessions that have no member and no observer, in
/// session-ID order, whether or not they are resident: the sessions only the
/// daemon's owner can read (protocol-change/077).
///
/// A closed session is listed so that a model's roster can say it exists and
/// is not running. Listing it grants nothing, because a message is delivered
/// only into a resident session and nothing here opens one. A session that has
/// any membership row, of either role, is left out, so a session another
/// person can read is never linked to the owner's others by default. A session
/// whose membership the catalogue cannot read is left out as well, and so is
/// every session when the registry does not answer in five seconds, which
/// refuses the default rather than widening it. The walk stops at
/// `unshared_limit` sessions.
///
/// ## Examples
///
/// ```gleam
/// // manager.unshared_sessions(registry)
/// ```
@internal
pub fn unshared_sessions(manager: Manager(instance)) -> List(String) {
  call.try_call(manager.commands, waiting: 5000, sending: Unshared)
  |> result.unwrap([])
}

/// The most sessions `unshared_sessions` considers.
pub const unshared_limit = 256

// The registry's own turn of `unshared_sessions`. It reads one catalogue page
// at a time and one membership page per session, so its cost is bounded by
// `unshared_limit`.
fn unshared(book: Book(instance)) -> List(String) {
  unshared_from(book, "", [], 0)
  |> list.sort(string.compare)
}

fn unshared_from(
  book: Book(instance),
  after: String,
  found: List(String),
  seen: Int,
) -> List(String) {
  case seen >= unshared_limit, catalogue.page(book.catalogue, after:) {
    True, _ | False, Error(_) -> found
    False, Ok(page) ->
      case list.last(page.records) {
        Error(Nil) -> found
        Ok(last) -> {
          let held =
            list.filter(page.records, fn(record) {
              record.state == catalogue.Saved
              && case
                access.session_members_page(book.catalogue, record.id, "")
              {
                Ok(members) -> members.entries == []
                Error(_) -> False
              }
            })
          unshared_from(
            book,
            last.id,
            list.append(list.map(held, fn(record) { record.id }), found),
            seen + list.length(page.records),
          )
        }
      }
  }
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

/// Lists the role the credential's principal holds in each session of its
/// first page of memberships, as `authorized_page` lists the sessions.
///
/// The credential is authenticated again on this call. The owner holds no
/// membership rows, so its answer is empty: the owner owns every session and a
/// role would say nothing. A member's answer is its memberships in session-ID
/// order, at most `access.listing_limit`, the same bound and order as the
/// first page `authorized_page` reads, so a row of that page has its role here.
///
/// ## Examples
///
/// ```gleam
/// // manager.authorized_roles(registry, digest)
/// ```
@internal
pub fn authorized_roles(
  manager: Manager(instance),
  digest: access.Digest,
) -> Result(List(#(String, access.Role)), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: AuthorizedRoles(
    digest,
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
/// such an account is to hold the earlier subject. The holder of a settle
/// subject can forge a settle, so this is a capability handed out on purpose
/// to fixtures alone: it is internal, has no wire route, and nothing in
/// production reads a settle subject back out. The registry issues each
/// subject with its fence.
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

/// Reads a retained operation or the exact bounded opening failure.
///
/// A recorded failure takes precedence over a closing reservation's status.
/// Custody still fences replacement; the next admission clears the failure
/// memo. Successful operations are forgotten when their custody drains.
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

/// Runs resident drain capabilities in the caller, within one shared budget.
///
/// The daemon root invokes this from its bounded Weft task. The registry only
/// snapshots capabilities: a gateway's authenticated delivery calls back into
/// the registry and would deadlock if this actor invoked the drain itself.
/// An unavailable registry or an expired budget cannot confirm delivery.
///
/// ## Examples
///
/// ```gleam
/// // manager.drain_held(registry)
/// ```
@internal
pub fn drain_held(manager: Manager(instance)) -> Nil {
  let deadline = bootstrap.monotonic_time_ms() + drain_budget_ms
  let drains =
    call.try_call(
      manager.commands,
      waiting: drain_budget_ms,
      sending: DrainHeld,
    )
    |> result.unwrap([])
  list.each(drains, fn(drain) {
    drain(int.max(deadline - bootstrap.monotonic_time_ms(), 0))
  })
}

// Every resident session spends the remainder of this same window. The root
// also bounds the task so a misbehaving callback cannot block daemon control.
const drain_budget_ms = 5000

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
      let #(book, answer) =
        frame_authorized(book, epoch, id, incarnation, digest)
      process.send(reply, answer)
      sm.keep(book)
    }
    DomainServices(id, operation, reply) -> {
      let services = services_for_builder(book, id, operation)
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
    SeedSubtitle(id, prompt) -> {
      let _written = catalogue.seed_subtitle(book.catalogue, id, prompt)
      sm.keep(book)
    }
    RememberFolder(workspace) -> {
      let _written = catalogue.remember_folder(book.catalogue, workspace)
      sm.keep(book)
    }
    RecentFolders(reply) -> {
      process.send(
        reply,
        catalogue.recent_folders(book.catalogue)
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    ForgetFolder(id, reply) -> {
      process.send(
        reply,
        catalogue.forget_folder(book.catalogue, id)
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    Rename(caller, epoch, id, name, reply) -> {
      let outcome = {
        use Nil <- result.try(authorize_admin(phase, book, caller, epoch))
        use record <- result.map(
          catalogue.rename(book.catalogue, id, name)
          |> result.map_error(AdminMetadata),
        )
        View(record, status(book, record))
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    Isolate(caller, epoch, id, state_root, reply) -> {
      process.send(
        reply,
        isolate_now(phase, book, caller, epoch, id, state_root),
      )
      sm.keep(book)
    }
    SetVisibility(caller, epoch, id, visibility, reply) -> {
      let outcome = {
        use Nil <- result.try(authorize_admin(phase, book, caller, epoch))
        use Nil <- result.try(case dict.has_key(book.slots, id) {
          True -> Error(AdminBusy)
          False -> Ok(Nil)
        })
        use record <- result.map(
          catalogue.set_visibility(book.catalogue, id, visibility)
          |> result.map_error(AdminMetadata),
        )
        View(record, status(book, record))
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    ArchivedPage(caller, after, reply) -> {
      let outcome = {
        use principal <- result.try(
          principal_of(book, caller)
          |> result.replace_error(AdminForbidden),
        )
        use Nil <- result.try(case principal.kind {
          access.OwnerPrincipal -> Ok(Nil)
          access.MemberPrincipal -> Error(AdminForbidden)
        })
        use page <- result.map(
          catalogue.archived_page(book.catalogue, after:)
          |> result.map_error(AdminMetadata),
        )
        #(
          page.revision,
          list.map(page.records, fn(record) {
            View(record, status(book, record))
          }),
        )
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    PrincipalPage(caller, after, now_ms, reply) -> {
      let outcome = {
        use Nil <- result.try(authenticated_owner(book, caller))
        access.principals_page(book.catalogue, after, now_ms)
        |> result.map_error(AdminMetadata)
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    MembershipPage(caller, id, after, reply) -> {
      let outcome = {
        use Nil <- result.try(authenticated_owner(book, caller))
        access.memberships_page(book.catalogue, id, after)
        |> result.map_error(AdminMetadata)
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    SessionMemberPage(caller, id, after, reply) -> {
      let outcome = {
        use Nil <- result.try(authenticated_owner(book, caller))

        // The members are read first, so a malformed cursor or an unknown
        // session is refused as it always was, and the scope is read only for a
        // session that exists.
        use page <- result.try(
          access.session_members_page(book.catalogue, id, after)
          |> result.map_error(AdminMetadata),
        )
        use selected <- result.map(
          domain.for_session(book.catalogue, id)
          |> result.map_error(AdminMetadata),
        )
        Members(selected.scope, page)
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    Delete(caller, epoch, id, sessions, reply) -> {
      process.send(reply, delete_now(phase, book, caller, epoch, id, sessions))
      sm.keep(book)
    }

    // Administration is the only writer of the credential, principal and
    // membership tables, so it is also the only thing that can make a
    // remembered frame authority wrong. The memo is dropped whatever the
    // outcome and before the reply leaves: a refused mutation is cheap to
    // forget, and a caller must never be told a change landed while a frame
    // check can still answer from state that predates it.
    Administer(digest, epoch, action, reply) -> {
      let outcome = administer_now(phase, book, digest, epoch, action)
      let book = Book(..book, authority: dict.new())
      process.send(reply, outcome)
      sm.keep(book)
    }

    // A claim only inserts a credential nobody has presented yet, which no
    // remembered answer can depend on. The memo is dropped anyway, so the
    // rule stays "every writer of the access tables drops it" rather than an
    // argument about which writes are harmless.
    Claim(claim, credential, name, now_ms, reply) -> {
      let outcome = case phase {
        Ready ->
          access.claim(
            book.catalogue,
            claim,
            credential,
            name,
            now_ms,
            same_digest,
          )
          |> result.map_error(ClaimRefused)
        ShuttingDown -> Error(ClaimUnavailable)
      }
      let book = Book(..book, authority: dict.new())
      process.send(reply, outcome)
      sm.keep(book)
    }

    // The browser claim binds a login in place of a bearer, and records when
    // it ends, in the same transaction (protocol-change/065, PR 9). It drops
    // the memo for the reason `Claim` does.
    ClaimLogin(claim, credential, name, now_ms, expires_at_ms, reply) -> {
      let outcome = case phase {
        Ready ->
          access.claim_login(
            book.catalogue,
            claim,
            credential,
            name,
            now_ms,
            expires_at_ms,
            same_digest,
          )
          |> result.map_error(ClaimRefused)
        ShuttingDown -> Error(ClaimUnavailable)
      }
      let book = Book(..book, authority: dict.new())
      process.send(reply, outcome)
      sm.keep(book)
    }
    ClaimKnown(claim, reply) -> {
      process.send(
        reply,
        access.claim_known(book.catalogue, claim) |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }

    // The login messages. A revocation drops the frame memo whatever the
    // outcome and before the reply leaves, as `Administer` does, so a revoked
    // login's pages are refused at their next frame and never answered from a
    // memo that predates the revocation. Issuing a login adds a row and changes
    // no existing credential's answer, so it leaves the memo alone.
    IssueLogin(principal_id, digest, issued_at_ms, expires_at_ms, from, reply) -> {
      let outcome =
        access.issue_login(
          book.catalogue,
          principal_id,
          digest,
          issued_at_ms,
          expires_at_ms,
          from,
        )
        |> result.map_error(Catalogue)
      process.send(reply, outcome)
      sm.keep(book)
    }
    ResumeLogin(digest, principal_id, now_ms, reply) -> {
      let outcome = {
        use principal <- result.try(
          principal_of(book, digest) |> result.map_error(Catalogue),
        )
        use Nil <- result.try(case principal.id == principal_id {
          True -> Ok(Nil)
          False -> Error(Catalogue(catalogue.Missing))
        })
        use _stamp <- result.map(
          access.resumed(book.catalogue, digest, now_ms)
          |> result.map_error(Catalogue),
        )
        principal
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    RevokeAllLogins(reply) -> {
      let outcome =
        access.revoke_all_logins(book.catalogue) |> result.map_error(Catalogue)
      let book = Book(..book, authority: dict.new())
      process.send(reply, outcome)
      sm.keep(book)
    }
    Signins(caller, target, after, now_ms, reply) -> {
      let outcome = {
        use principal_id <- result.try(acting_on(book, caller, target))
        access.signins_page(book.catalogue, principal_id, after, now_ms)
        |> result.map(fn(page) { #(principal_id, page) })
        |> result.map_error(AdminMetadata)
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    RevokeLogin(caller, epoch, target, fingerprint, reply) -> {
      let outcome = {
        use Nil <- result.try(current_epoch(phase, book, epoch))
        use principal_id <- result.try(acting_on(book, caller, target))
        access.revoke_login(book.catalogue, principal_id, fingerprint)
        |> result.map(fn(digest) { #(principal_id, digest) })
        |> result.map_error(AdminMetadata)
      }
      let book = Book(..book, authority: dict.new())
      process.send(reply, outcome)
      sm.keep(book)
    }
    RevokeLogins(caller, epoch, target, reply) -> {
      let outcome = {
        use Nil <- result.try(current_epoch(phase, book, epoch))
        use principal_id <- result.try(acting_on(book, caller, target))
        access.revoke_logins(book.catalogue, principal_id)
        |> result.map(fn(count) { #(principal_id, count) })
        |> result.map_error(AdminMetadata)
      }
      let book = Book(..book, authority: dict.new())
      process.send(reply, outcome)
      sm.keep(book)
    }
    RenamePrincipal(caller, epoch, target, name, reply) -> {
      let outcome = {
        use Nil <- result.try(current_epoch(phase, book, epoch))
        use principal_id <- result.try(acting_on(book, caller, target))
        access.rename(book.catalogue, principal_id, name)
        |> result.map_error(AdminMetadata)
      }
      let book = Book(..book, authority: dict.new())
      process.send(reply, outcome)
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
        use principal <- result.try(principal_of(book, digest))
        case principal.kind {
          access.OwnerPrincipal -> catalogue.page(book.catalogue, after:)
          access.MemberPrincipal ->
            catalogue.member_page(book.catalogue, principal.id, after:)
        }
      }
      process.send(reply, viewed_page(book, outcome))
      sm.keep(book)
    }
    AuthorizedRoles(digest, reply) -> {
      let outcome = {
        use principal <- result.try(principal_of(book, digest))
        case principal.kind {
          access.OwnerPrincipal -> Ok([])
          access.MemberPrincipal ->
            access.memberships_page(book.catalogue, principal.id, "")
            |> result.map(fn(page) {
              list.map(page.entries, fn(entry) {
                #(entry.session_id, entry.role)
              })
            })
        }
      }
      process.send(reply, result.map_error(outcome, Catalogue))
      sm.keep(book)
    }
    Authenticate(digest, reply) -> {
      process.send(
        reply,
        principal_of(book, digest)
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    SessionAuthority(digest, id, reply) -> {
      let outcome = {
        use principal <- result.try(principal_of(book, digest))
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
          |> result.map(fn(record) { View(record, status(book, record)) }),
      )
      sm.keep(book)
    }
    SetDefault(workspace, id, reply) -> {
      let outcome = case phase {
        ShuttingDown -> Error(Unavailable)
        Ready ->
          catalogue.set_workspace_default(book.catalogue, workspace, id)
          |> result.map_error(Catalogue)
          |> result.map(fn(record) { View(record, status(book, record)) })
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    Get(id, reply) -> {
      let view =
        catalogue.get(book.catalogue, id)
        |> result.map_error(Catalogue)
        |> result.map(fn(record) { View(record, status(book, record)) })
      process.send(reply, view)
      sm.keep(book)
    }
    Unshared(reply) -> {
      process.send(reply, unshared(book))
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
      // A recorded opening failure is already final even while its custody
      // is closing. The operator must see that reason on the first poll;
      // retirement still owns the separate capacity and replacement fences.
      let view = case dict.get(book.failed_operations, id) {
        Ok(#(failed, reason)) if failed == operation ->
          Error(StartFailed(reason))
        Ok(_) | Error(Nil) ->
          case dict.get(book.slots, id) {
            Ok(Slot(operation: current, ..)) if current == operation ->
              catalogue.get(book.catalogue, id)
              |> result.map_error(Catalogue)
              |> result.map(fn(record) { View(record, status(book, record)) })
            Ok(Slot(..)) | Error(Nil) -> Error(StaleOperation)
          }
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
          |> result.map(status(book, _)),
      )
      step(phase, book)
    }
    StopIncarnation(id, incarnation, reply) -> {
      case dict.get(book.slots, id) {
        Ok(slot) if slot.operation == incarnation -> {
          let book = stop_slot(book, id)

          // A stopped incarnation was resident, so its record was reconciled
          // long ago; the read is still what says which durable state it
          // settles into rather than assuming the reconciled one.
          process.send(
            reply,
            catalogue.get(book.catalogue, id)
              |> result.map_error(Catalogue)
              |> result.map(status(book, _)),
          )
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

    // Callbacks leave the actor with their original instance. A later slot
    // replacement must never redirect a drain to a different incarnation.
    DrainHeld(reply) -> {
      let drain = book.assembly.drain
      let drains =
        dict.values(book.slots)
        |> list.filter_map(fn(slot) {
          case slot.phase {
            Running(instance) -> Ok(fn(within) { drain(instance, within) })
            WaitingForDomain | Building | Closing | Blocked(_) -> Error(Nil)
          }
        })
      process.send(reply, drains)
      step(phase, book)
    }
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

// The owner check every read-only owner command shares: the credential must
// still authenticate, and as the owner. Reads carry no epoch, since they
// change nothing a previous daemon lifetime could have meant differently.
// Every digest this actor authenticates is looked up as the kind it was made
// as (protocol-change/065). A wire path makes its digest with
// `access.credential_digest`, which is a `Bearer`, so a string a connection
// presents can never reach a login's row; a page minted from a browser login
// carries the `Browser` digest the daemon made from the login's identifier.
// Authentication is in this one function, so no message below can skip it.
fn principal_of(book: Book(instance), digest: access.Digest) {
  access.authenticate(book.catalogue, digest)
}

fn authenticated_owner(book: Book(instance), digest) {
  use principal <- result.try(
    principal_of(book, digest)
    |> result.replace_error(AdminForbidden),
  )
  case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error(AdminForbidden)
  }
}

// Whose sign-ins a caller may read or revoke, or whose name it may change: its
// own, or any principal's when the caller is the owner. The caller is authenticated first, as the kind its
// digest was made as, so a revoked login reads and revokes nothing.
fn acting_on(
  book: Book(instance),
  caller: access.Digest,
  target: Option(String),
) -> Result(String, AdminError) {
  use principal <- result.try(
    principal_of(book, caller) |> result.replace_error(AdminForbidden),
  )
  case target {
    option.None -> Ok(principal.id)
    option.Some(id) if id == principal.id -> Ok(id)
    option.Some(id) ->
      case principal.kind {
        access.OwnerPrincipal -> Ok(id)
        access.MemberPrincipal -> Error(AdminForbidden)
      }
  }
}

// A write is refused while the daemon is stopping and when it names another
// daemon lifetime, as every administration is.
fn current_epoch(
  phase,
  book: Book(instance),
  epoch,
) -> Result(Nil, AdminError) {
  use Nil <- result.try(case phase {
    Ready -> Ok(Nil)
    ShuttingDown -> Error(AdminUnavailable)
  })
  case epoch == book.epoch {
    True -> Ok(Nil)
    False -> Error(AdminStaleEpoch)
  }
}

fn authorize_admin(phase, book: Book(instance), digest, epoch) {
  use Nil <- result.try(case phase {
    Ready -> Ok(Nil)
    ShuttingDown -> Error(AdminUnavailable)
  })
  use principal <- result.try(
    principal_of(book, digest)
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
    Invite(id, name, enrollment, session_id, role) -> {
      use Nil <- result.try(require_shared(store, session_id))
      access.invite_member(store, id, name, enrollment, session_id, role)
      |> result.map_error(AdminMetadata)
    }
    RotateMember(id, enrollment) ->
      access.rotate_member(store, id, enrollment)
      |> result.map_error(AdminMetadata)
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

// Two digests are 64-character base16 SHA-256 values, the same length
// whatever they digest, so a constant-time comparison of their bytes reveals
// nothing about either through the time a refusal takes.
fn same_digest(stored: String, presented: String) -> Bool {
  ffi_crypto.constant_time_equal(
    bit_array.from_string(stored),
    bit_array.from_string(presented),
  )
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

// Deletion runs entirely inside this actor turn, which is what makes the
// busy check meaningful: no open can take a slot between the check and the
// removal, and once the row is gone `admit` can no longer find the session
// to open it. The unlink follows the commit for the same reason isolation
// writes metadata first — a half-applied delete must leave files without a
// registration, never a registration without files.
fn delete_now(phase, book: Book(instance), caller, epoch, id, sessions) {
  use Nil <- result.try(authorize_admin(phase, book, caller, epoch))
  use Nil <- result.try(case dict.has_key(book.slots, id) {
    True -> Error(AdminBusy)
    False -> Ok(Nil)
  })

  // Containment is decided against the row still in the catalogue, before
  // the transaction removes it. A row naming a path outside the sessions
  // directory keeps both its registration and its files: refusing early is
  // what stops the scratch-directory removal below from being pointed at an
  // arbitrary tree by a row nobody minted here.
  use existing <- result.try(
    catalogue.get(book.catalogue, id) |> result.map_error(AdminMetadata),
  )
  use Nil <- result.try(
    case string.starts_with(existing.path, sessions <> "/") {
      True -> Ok(Nil)
      False -> Error(AdminForeignPath)
    },
  )
  use record <- result.try(
    catalogue.delete(book.catalogue, id) |> result.map_error(AdminMetadata),
  )
  unlink_conversation(record.path)
  Ok(record)
}

// Removes the conversation database and the sidecars SQLite keeps beside it.
// A missing sidecar is the ordinary case rather than a fault: a cleanly
// closed database has no WAL or journal, and only a crashed writer leaves
// the scratch directory. Nothing here can be retried usefully, so a refusal
// from the filesystem is not reported: the registration is already gone and
// the daemon must not resurrect it.
fn unlink_conversation(path: String) -> Nil {
  // Each of these is a single file, so the non-recursive removal is the one
  // that matches: a `delete` here would descend into anything that turned
  // out to be a directory instead.
  list.each(
    [path <> "-wal", path <> "-shm", path <> "-journal", path],
    fn(target) {
      let _removed = simplifile.delete_file(target)
      Nil
    },
  )

  // The scratch sidecar is a directory when SQLite left one behind, which is
  // the single place recursion is wanted. `delete_now` has already confirmed
  // the whole family sits under the daemon's sessions directory.
  let _scratch = simplifile.delete(path <> ".tmp")
  Nil
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
      list.map(page.records, fn(record) { View(record, status(book, record)) }),
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

          // Admission compares immutable creation metadata, but the response
          // displays the current name even when this was an old key's retry.
          let viewed = {
            use status <- result.try(outcome)
            use displayed <- result.map(
              catalogue.get(book.catalogue, record.id)
              |> result.map_error(Catalogue),
            )
            View(displayed, status)
          }
          #(book, viewed)
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
        && record.profile == request.profile
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
          profile: request.profile,
          subtitle: option.None,
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
  let selected = {
    use visibility <- result.try(
      catalogue.visibility(book.catalogue, record.id)
      |> result.map_error(Catalogue),
    )
    use Nil <- result.try(case visibility {
      catalogue.Active -> Ok(Nil)
      catalogue.Archived -> Error(SessionArchived)
    })
    domain.for_session(book.catalogue, record.id) |> result.map_error(Catalogue)
  }
  case selected {
    Error(error) -> #(book, Error(error))
    Ok(selected) -> {
      let #(book, admitted) = ensure_domain(book, selected)
      case admitted {
        Error(error) -> #(book, Error(error))
        Ok(_operation) -> prepare_domain_slot(book, record, selected)
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
) -> #(Book(instance), Result(Status, Error)) {
  let results = process.new_subject()
  let faults = process.new_subject()
  let failures = process.new_subject()
  let operation = book.epoch <> ":" <> int.to_string(book.next)

  // The persistent host retains its builder after assembly. Project these
  // inputs before closing over them so it cannot retain the registry's other
  // resident instances through the full book.
  let commands = book.commands
  let build = book.assembly.build
  let directory = Manager(commands, process.self())

  case
    host.prepare(
      build: fn(owner) {
        use services <- result.try(
          call.try_call(commands, waiting: 5000, sending: DomainServices(
            record.id,
            operation,
            _,
          ))
          |> result.unwrap(Error("domain registry is unavailable")),
        )
        build(record, selected, services, owner, directory)
      },
      fatal: book.assembly.fatal,
      results:,
      faults:,
      failures:,
      label: fn() { owner.label([#("session", record.id)], owner.SessionHost) },
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
          // A fresh attempt supersedes whatever the last one failed at, and
          // dropping the memo here is what keeps the map to one entry per
          // session however many times an operator retries.
          failed_operations: dict.delete(book.failed_operations, record.id),
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
// follows it has already been decided. Once cancellation has begun, an open
// instead reserves a parked session for replacement after normal retirement.
fn ensure_domain(book: Book(instance), selected: domain.Domain) {
  case dict.get(book.domains, selected.id) {
    Ok(DomainSlot(phase: DomainPreparing, operation:, ..))
    | Ok(DomainSlot(phase: DomainRunning(_), operation:, ..))
    | Ok(DomainSlot(phase: DomainClosing, operation:, ..)) -> #(
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

      // Domain hosts also keep their builder after publication. Retain the
      // callback alone, not the registry and its resident instances.
      let domain_build = book.assembly.domain_build

      case
        host.prepare(
          build: fn(owner) { domain_build(selected, sources, owner) },
          fatal: domain_service.children,
          results:,
          faults:,
          failures:,
          label: fn() { owner.label([], owner.DomainHost) },
        )
      {
        Error(reason) -> #(book, Error(Preparation(reason)))
        Ok(host) -> {
          let slot =
            DomainSlot(
              selected,
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

// A parked builder belongs to a session operation, not to the domain that
// happened to be retiring when it was admitted. Only the registry can release
// that builder, and it does so after the replacement services are published.
// Checking the session operation prevents an old builder from borrowing the
// services selected for a later open of the same durable identity.
fn services_for_builder(book: Book(instance), id: String, operation: String) {
  use slot <- result.try(
    dict.get(book.slots, id)
    |> result.map_error(fn(_) { "session admission is no longer retained" }),
  )
  case slot.phase, slot.operation == operation {
    Building, True -> {
      use domain <- result.try(
        dict.get(book.domains, slot.domain_id)
        |> result.map_error(fn(_) { "domain admission is no longer retained" }),
      )
      case domain.phase {
        DomainRunning(services) -> Ok(services)
        DomainPreparing
        | DomainQuiescing(_, _)
        | DomainClosing
        | DomainDrained
        | DomainWaitingFailure(_)
        | DomainBlocked(_) -> Error("domain admission is no longer resident")
      }
    }
    _, _ -> Error("session admission is no longer building")
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
          True ->
            remember_failure(
              stop_slot(book, session_id),
              session_id,
              session.operation,
              reason,
            )
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
        process.Normal if slot.phase == DomainClosing -> {
          process.demonitor_process(slot.watch)
          replace_drained_domain(book, id, slot)
        }
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

// Normal retirement is the only event that may transfer a domain reservation
// to a fresh builder. Waiting sessions already consume ordinary capacity and
// own parked hosts; they have never borrowed the retiring services. Cancelled
// waiters may still be draining, so only a live waiter justifies replacement.
fn replace_drained_domain(book: Book(instance), id: String, slot: DomainSlot) {
  let waiting =
    list.any(dict.values(book.slots), fn(session) {
      session.domain_id == id && session.phase == WaitingForDomain
    })
  case waiting {
    False ->
      Book(
        ..book,
        domains: dict.insert(
          book.domains,
          id,
          DomainSlot(..slot, phase: DomainDrained),
        ),
      )
    True -> {
      let vacant = Book(..book, domains: dict.delete(book.domains, id))
      let #(replacement, answer) = prepare_shared_domain(vacant, slot.selected)
      case answer {
        Ok(_) ->
          Book(
            ..replacement,
            domains: depend(replacement.domains, id, slot.dependents),
          )

        // Failed preparation retains the original reservation and cancels all
        // parked sessions through the same path as a domain build failure.
        Error(reason) ->
          domain_failed(book, id, slot.operation, string.inspect(reason))
      }
    }
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
) -> #(
  Book(instance),
  Result(#(access.Principal, access.Authority), FrameRefusal),
) {
  let answer = {
    use Nil <- result.try(case epoch == book.epoch {
      True -> Ok(Nil)
      False -> Error(StaleEpoch)
    })
    use Nil <- result.try(case dict.get(book.slots, id) {
      Ok(Slot(phase: Running(_), operation:, ..)) if operation == incarnation ->
        Ok(Nil)
      Ok(Slot(..)) | Error(Nil) -> Error(StaleIncarnation)
    })
    Ok(Nil)
  }

  // The two fences above are answered from this actor's own state, so they run
  // on every call. Only the third question reaches the catalogue, and only it
  // is worth remembering.
  case answer {
    Error(refusal) -> #(book, Error(refusal))
    Ok(Nil) -> resolved_authority(book, id, digest)
  }
}

// The credential resolution behind a frame check, answered from `book.authority`
// when it has been answered before.
//
// This is memoisation rather than a cache, and two fences hold it to that. The
// first is the single writer: the tables it reads — `access_credential`,
// `access_principal`, `access_membership`, and the session registration row —
// are written in exactly three places, `administer_member`, `access.claim` and
// `access.rename`, reached only by the `Administer`, `Claim` and
// `RenamePrincipal` messages this same actor serialises, and every one of those
// arms drops the whole memo before it replies. A claim
// only inserts a credential that has never authenticated, so it could not
// change a remembered answer anyway; it drops the memo so the fence stays one
// rule rather than two. Startup's `access.bootstrap_owner` runs in the root
// before the registry exists. The second is the slot lifetime: `frame_authority`
// resolves nothing without a `Running` slot for the session, and `forget_authority`
// drops an entry when that slot goes, so no remembered answer outlives the
// incarnation that could read it. A remembered answer therefore cannot differ
// from the live read it replaces, and a revoked credential still closes its
// attachment on the very next frame. A change that relaxes either fence — a
// second writer of those tables, or a memo that survives its slot — has to
// restore the property some other way.
//
// The slot fence is also why a session deletion has nothing of its own to clear
// here: a session with no slot has no entries left, whatever its memberships did
// while it was resident.
//
// What this removes is real work rather than a round trip. `access.authenticate`
// and `access.authorization` together issue about ten SQLite statements, each
// freshly prepared, and the per-frame check runs once per pushed provider delta
// per attached terminal on top of twice per command. Measured against the
// shipped live-delivery fixture that was the daemon's entire steady-state
// profile: the fourteen most-called functions in the process were all
// `esqlite3` statement preparation and `storage/access` string validation.
//
// A refusal is not remembered. It is the path that closes the attachment, so
// there is no second frame to pay for it, and remembering it would keep a
// principal out between a grant and the next administration.
fn resolved_authority(
  book: Book(instance),
  id: String,
  digest: access.Digest,
) -> #(
  Book(instance),
  Result(#(access.Principal, access.Authority), FrameRefusal),
) {
  let key = #(digest, id)
  case dict.get(book.authority, key) {
    Ok(remembered) -> #(book, Ok(remembered))
    Error(Nil) ->
      case resolve_authority(book, id, digest) {
        Error(refusal) -> #(book, Error(refusal))
        Ok(answer) -> #(
          Book(..book, authority: dict.insert(book.authority, key, answer)),
          Ok(answer),
        )
      }
  }
}

fn resolve_authority(
  book: Book(instance),
  id: String,
  digest: access.Digest,
) -> Result(#(access.Principal, access.Authority), FrameRefusal) {
  {
    use principal <- result.try(principal_of(book, digest))
    use authority <- result.try(access.authorization(
      book.catalogue,
      principal.id,
      id,
    ))
    Ok(#(principal, authority))
  }
  |> result.replace_error(Unauthorized)
}

// Removing a slot takes the memo entries keyed on its session with it. Nothing
// reads such an entry while the session is gone, but the key is credential and
// session alone, so a reopened session would answer from a memo written under
// the previous incarnation, which may predate an administration made in
// between. Dropping the keys here also bounds the memo by the sessions the
// daemon currently holds rather than by every session it has ever held.
fn forget_authority(book: Book(instance), id: String) -> Book(instance) {
  Book(
    ..book,
    authority: dict.filter(book.authority, fn(key, _) { key.1 != id }),
  )
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

        // Cleanup is ordered by the same `stop_slot` a deliberate stop uses,
        // but a build that returned an error is not a stop: the memo is what
        // keeps that distinction observable after the slot is gone. The
        // bounded reason survives retirement for the authenticated operator
        // polling this exact operation. It grants no replacement authority.
        Building, Error(reason) ->
          remember_failure(stop_slot(book, id), id, operation, reason)
        WaitingForDomain, _ | Closing, _ | Blocked(_), _ | Running(_), _ -> book
      }
    Ok(_) | Error(Nil) -> book
  }
}

// Records that this operation's builder failed, so a later read of that exact
// operation is answered `StartFailed` rather than `StaleOperation`.
//
// The memo is capped at the same limit that bounds live slots, and a session
// holds at most one entry, so a daemon that fails opens all night cannot grow
// this map past the size the operator already provisioned. At the cap the
// newest failure loses its diagnosis rather than the map losing its bound: an
// operator with `limit` undiagnosed failures already has a bigger problem than
// the wording of the next refusal.
fn remember_failure(
  book: Book(instance),
  id: String,
  operation: String,
  reason: String,
) -> Book(instance) {
  case
    dict.has_key(book.failed_operations, id)
    || dict.size(book.failed_operations) < book.limit
  {
    True ->
      Book(
        ..book,
        failed_operations: dict.insert(book.failed_operations, id, #(
          operation,
          glance.clip(reason, 2048),
        )),
      )
    False -> book
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
            |> forget_authority(id)
          clean_session_retired(book, slot.domain_id, id)
        }
        _ -> failed(book, id, operation, string.inspect(reason))
      }
    Ok(_) | Error(Nil) -> book
  }
}

// A slot is the live half of the answer and the registration is the durable
// half; only the pair says whether an open can succeed. Reading liveness alone
// reported a record that is still `Reserved` as `Saved`, because a reservation
// owns no slot either — so an incomplete creation rendered in the selector as
// an ordinary saved session and every selection of it was refused with
// `NotInitialized`. Where there is no slot, the durable state is the answer.
fn status(book: Book(instance), record: catalogue.Registration) -> Status {
  case dict.get(book.slots, record.id) {
    Error(Nil) ->
      case record.state {
        catalogue.Reserved -> Reserved
        catalogue.Saved -> Saved
      }

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

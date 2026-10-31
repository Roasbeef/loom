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
//// 9. `delete_registration` writes the releases a deleted parent owes
////    (`owe_releases`, from the holders `holders_of` read in the caller's
////    process) before it removes the registration, and
////    `remote_releases` and `settle_remote_release` are how the release
////    drainer reads and settles them.
//// 10. `delegate_now` admits the delegate session of a spawner's pair and refuses
////    one that is not open. `claim_now` is the Agency's claim of one spawn against
////    the spawner's rolling day, and `add_spend` is how a child's tokens reach
////    the same table. `release_now` begins a release by marking the row
////    and stopping the slot, `finish_drained_release` deletes the session when
////    the slot drains, and `sweep_now` deletes what a failed deletion left, what
////    `due_for_deletion` finds due, and `close_idle` closes the resident
////    sessions that have been idle past the spawner's idle window.
//// 11. Deleting a delegate session cascades (protocol-change/084, phase 4):
////    `delete_delegate`, which both the drained release and the sweep use,
////    reads the closed file's stubs with `descendant_holders` and writes their
////    release rows with `owe_releases` before the registration goes.
//// 12. A top-level session another orchestrator's page asked for
////    (protocol-change/094) is reserved by `relay_now`, which is one catalogue
////    transaction: the request's existing row, or the two caps counted and the
////    registration, its mapping and the row written together. It reserves and
////    nothing more; the session's store is made afterwards by `create`, which
////    finds the reservation by its request key. `relayed_page_now` lists a
////    spawner's sessions with their live status, and `archive_relayed_now`
////    archives one that holds no slot.

import broker/internal/call
import broker/internal/ffi_crypto
import client/daemon/domain as domain_service
import client/internal/ffi_os
import client/internal/instance_host as host
import client/internal/instance_owner as custody
import client/internal/shared_history
import client/remote_child
import client/remote_release
import client/spawners
import core/clock
import core/glance
import core/ids
import filepath
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import host/bootstrap
import session_view/text_hygiene
import simplifile
import storage/access
import storage/catalogue
import storage/domain
import telemetry/owner
import weft
import weft/state_machine as sm

/// Live lifecycle state, joined with the durable initialization the registry
/// would refuse an open against.
pub type Status {
  /// A creation reserved this identity and never reconciled it, so no
  /// database stands behind it and only a create retry can complete it.
  Reserved

  /// A creation reserved this identity, its start failed, and the catalogue
  /// kept why (protocol-change/093). It is a `Reserved` in every other respect:
  /// no database is promised, only a create retry under the original request
  /// key can complete it, and the owner may delete it. The reason is one
  /// cleaned line of at most `catalogue.start_failure_limit` bytes and `at` is
  /// when the start failed, in Unix milliseconds.
  FailedStart(reason: String, at: Int)

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

  /// This catalogue is handing the session to the orchestrator `to` under the
  /// move `op`, so nothing here may open it until the move finishes or aborts
  /// (protocol-change/078, phase 5).
  SessionMoving(op: String, to: String)

  /// This catalogue handed the session to the orchestrator `to`. Its row is a
  /// tombstone that only records who owns the session now, and no open,
  /// restore or delete runs here.
  SessionMoved(to: String)

  /// The session's deletion has begun through the session directory
  /// (protocol-change/083): its deletion mark is written, and nothing opens it
  /// while the mark stands.
  SessionDeleting
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
    /// When `executor` is set it is instead the name of a workspace registered
    /// on that executor, which is kept exactly as given.
    workspace: String,
    /// Display label, not a database filename.
    name: String,
    /// Validated configuration reference with no credential values.
    configuration: String,
    /// The model profile the session is created under, or `None` for the
    /// configuration's default roles. It is retained with the registration and
    /// resolved again by every open (protocol-change/076).
    profile: Option(String),
    /// The `[models.<key>]` entry the session's `main` role is pinned to, or
    /// `None` for the chain the profile or configuration gives. It is retained
    /// with the registration and resolved again by every open
    /// (protocol-change/080).
    model: Option(String),
    /// The executor the workspace is registered on, or the empty string for a
    /// workspace on this host (protocol-change/078).
    executor: String,
    /// The `[pools.<name>]` whose executors may hold the workspace, or the
    /// empty string. A creation names an executor or a pool and never both:
    /// the pool picks the executor when the session first opens.
    pool: String,
  )
}

/// The registry's part of serving a subagent for a parent on another
/// orchestrator (protocol-change/084): find or create the delegate session of
/// one (spawner, parent session) pair, and admit it.
pub type DelegateRequest {
  DelegateRequest(
    /// The `[spawners.<name>]` key of the spawning orchestrator.
    spawner: String,
    /// The spawning orchestrator's identity for the parent session.
    parent_session: String,
    /// The creation a first spawn makes. Its `request_key` is derived from the
    /// pair by the caller, so a creation retried after a crash finds the
    /// registration it reserved and does not make a second one.
    creation: Creation,
    /// The directory new conversation files are placed in.
    directory: String,
    /// The generator that mints the session's identity.
    generator: ids.Generator,
    /// The daemon-wide domain configuration a new session's mapping carries.
    configuration: String,
    /// The most delegate sessions the spawner may hold.
    limit: Int,
    /// The current time, which becomes the pair's last contact.
    now_ms: Int,
  )
}

/// The delegate session of a pair and its current admission or custody state.
pub type Delegated {
  Delegated(
    /// This daemon's identity for the session.
    session_id: String,
    /// `Resident` is serving and `Opening` is building. A retained slot reports
    /// `Stopping` while original custody drains or `RecoveryBlocked` when its
    /// cleanup proof was lost, so callers can distinguish retry from refusal.
    status: Status,
  )
}

/// Why a delegate session could not be found or made.
pub type DelegateError {
  /// The pair has no session and the spawner already holds as many as it may.
  DelegateAtLimit(
    /// How many the spawner holds.
    held: Int,
  )

  /// The spawner's rolling day has reached one of its caps, and no session was
  /// made or admitted.
  DelegateDayCap(
    /// Which cap.
    cap: DayCap,
    /// Its value.
    limit: Int,
  )

  /// The pair's session was released: its spawner reported that the parent
  /// session was deleted, so the session accepts no more children and is being
  /// deleted.
  DelegateReleased

  /// The registry refused or failed.
  DelegateFailed(
    /// The registry's error.
    error: Error,
  )
}

/// The registry's part of a top-level session another orchestrator's page asks
/// for (protocol-change/094): the request, the registration it would make, and
/// the caps it is judged by.
pub type RelayRequest {
  RelayRequest(
    /// The `[spawners.<name>]` key of the orchestrator that asked.
    spawner: String,
    /// The UUIDv7 it minted for the submit.
    request_id: String,
    /// The creation the request would make. Its `request_key` is
    /// `catalogue.relayed_key(spawner, request_id)`, so the create that opens
    /// the session afterwards finds this reservation.
    creation: Creation,
    /// The directory new conversation files are placed in.
    directory: String,
    /// The generator that mints the session's identity.
    generator: ids.Generator,
    /// The daemon-wide domain configuration a new session's mapping carries.
    configuration: String,
    /// The two caps and the clock.
    limits: catalogue.RelayedLimits,
  )
}

/// A relayed session after the registry reserved it, or found it reserved.
pub type Relaying {
  Relaying(
    /// This daemon's identity for the session.
    session_id: String,
    /// The registration's state. `Reserved` means the store has not been made
    /// and the caller finishes the session by creating it.
    state: catalogue.State,
  )
}

/// Why a relayed session could not be reserved.
pub type RelayError {
  /// A cap of the spawner's table was reached, and nothing was written.
  RelayCapped(
    /// Which cap.
    cap: catalogue.RelayedCap,
    /// Its value.
    limit: Int,
  )

  /// The registry refused or failed.
  RelayFailed(
    /// The registry's error.
    error: Error,
  )

  /// The request id was already used by another spawner.
  RelayForeign
}

/// One relayed session of a spawner's listing, with its live status.
pub type RelayedView {
  RelayedView(
    /// The row and the placement and archive state the listing reads.
    listing: catalogue.RelayedListing,
    /// The registration and its status now.
    view: View,
  )
}

/// Why a relayed session could not be archived.
pub type RelayedArchiveError {
  /// The session is not relayed for that spawner.
  ArchiveNotRelayed

  /// The session still holds a slot. The caller stops it and asks again once
  /// it has drained.
  ArchiveBusy

  /// The registry refused or failed.
  ArchiveFailed(
    /// The registry's error.
    error: Error,
  )
}

/// The two caps a spawner's rolling day can reach.
pub type DayCap {
  /// The tokens its children used, against `token_budget_per_day`.
  DayTokens

  /// The spawns admitted, against `max_per_day`.
  DaySpawns
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
      fn() -> Result(List(shared_history.Source), String),
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

/// What a retained domain slot has done so far with its shared services.
///
/// The legal transitions are:
///
/// - `DomainPreparing` to `DomainRunning` on a published build, or to
///   `DomainWaitingFailure` on a refusal.
/// - `DomainRunning` to `DomainClosing` when the last dependent session
///   retires, or the daemon is draining, and the host is cancelled.
/// - `DomainClosing` to `DomainDrained` on the witness's normal exit.
/// - `DomainWaitingFailure` to `DomainBlocked` once cancellation has been
///   issued; neither is ever admitted against again.
///
/// A session opened while its domain is `DomainClosing` is parked until the
/// domain drains and is then admitted against a replacement, so a closing
/// domain is never handed back.
type DomainPhase {
  DomainPreparing
  DomainRunning(domain_service.Services)
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

  /// Records the executor a pooled session's first attach chose, once.
  SeedExecutor(String, String)

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

  /// Replace the model profile a registration names, for the session's own
  /// hub (protocol-change/082).
  SetProfile(String, Option(String), Subject(Result(Nil, Error)))

  /// One fresh page carries membership-validated paths in the same turn.
  DomainSources(
    String,
    String,
    Subject(Result(List(shared_history.Source), String)),
  )
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
  DelegateSession(DelegateRequest, Subject(Result(Delegated, DelegateError)))

  /// Reserves a top-level session for another orchestrator's page, in one
  /// catalogue transaction (protocol-change/094).
  RelayReserve(RelayRequest, Subject(Result(Relaying, RelayError)))

  /// The relayed row of a session, without waking it.
  RelayedOfSession(String, Subject(Result(Option(catalogue.Relayed), Error)))

  /// One page of a spawner's relayed sessions: the spawner, the identity the
  /// page follows and the most rows.
  RelayedSessions(
    String,
    String,
    Int,
    Subject(Result(List(RelayedView), Error)),
  )

  /// Archives a relayed session of a spawner that holds no slot.
  ArchiveRelayed(String, String, Subject(Result(View, RelayedArchiveError)))

  /// Claims one spawn against a spawner's rolling day: the spawner, its two
  /// caps, the time and the reply.
  ClaimSpawn(
    String,
    Option(Int),
    Option(Int),
    Int,
    Subject(Result(Nil, DelegateError)),
  )

  /// Adds tokens a spawner's child used to the spawner's current spend bucket.
  SpendTokens(String, Int, Int, Subject(Result(Nil, Error)))

  /// The delegate record of a session, read without waking it.
  DelegateOf(String, Subject(Result(Option(catalogue.Delegate), Error)))

  /// Installs the bell a deletion rings after it writes the releases it owes.
  SetReleaseBell(fn() -> Nil)

  /// Every release a deleted parent session still owes an orchestrator.
  RemoteReleases(Subject(Result(List(catalogue.RemoteRelease), Error)))

  /// Deletes one release row, once the orchestrator has answered.
  SettleRemoteRelease(catalogue.RemoteRelease, Subject(Result(Nil, Error)))

  /// The delegate record of a (spawner, parent session) pair, read without
  /// creating or waking anything.
  DelegatePair(
    String,
    String,
    Subject(Result(Option(catalogue.Delegate), Error)),
  )

  /// Releases the delegate session of a pair: marks it releasing, stops its
  /// slot, and deletes it once the slot has drained. The strings are the
  /// spawner, the parent session and the sessions directory.
  ReleaseDelegate(String, String, String, Subject(Result(Nil, Error)))

  /// Deletes the delegate sessions that are due and answers how many went, with
  /// the resident ones that look idle. The function judges a spawner, the
  /// integer is the time, and the string the sessions directory.
  SweepDelegates(
    fn(String) -> spawners.Standing,
    Int,
    String,
    Subject(Result(Due(instance), Error)),
  )

  /// Closes the listed sessions that are still open, still resident, and whose
  /// last contact is still the one listed. Answers how many it closed.
  CloseIdle(List(#(String, Int)), Subject(Int))
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
    List(String),
    Subject(Result(catalogue.Registration, AdminError)),
  )

  /// Who serves a session, read without waking it.
  Custody(String, Subject(Result(catalogue.Custody, Error)))

  /// Whether the owner archived a session, read without waking it. A session
  /// this catalogue does not hold is `Catalogue(Missing)`.
  Visibility(String, Subject(Result(catalogue.Visibility, Error)))

  /// Who serves each of a page of sessions, read in one registry turn, for a
  /// listing that marks the sessions that are moving or have moved.
  Custodies(
    List(String),
    Subject(Result(List(#(String, catalogue.Custody)), Error)),
  )

  /// The owner's request to hand a session to the orchestrator named, under the
  /// operation identity the caller minted: the caller, the epoch, the session,
  /// the destination and the identity.
  BeginMove(
    access.Digest,
    String,
    String,
    String,
    String,
    Subject(Result(catalogue.Custody, AdminError)),
  )

  /// The mover's compare-and-set that ends a move, for the session and the
  /// operation: `Moving -> Moved`.
  FinishMove(String, String, Subject(Result(catalogue.Custody, Error)))

  /// The mover's compare-and-set that abandons a move before anything reached
  /// the receiver: `Moving -> Resident`.
  AbortMove(String, String, Subject(Result(catalogue.Custody, Error)))

  /// The importer's request to take in a session another orchestrator handed
  /// over.
  ImportSession(Import, Subject(Result(catalogue.Custody, AdminError)))

  /// The moves still in `Moving`, for a restart to resume.
  MovingSessions(Subject(Result(List(catalogue.Pending), Error)))

  /// Reserves a creation's registration without opening it, so a directory
  /// member can record the owner before the session can be served
  /// (protocol-change/083).
  Reserve(
    Creation,
    String,
    ids.Generator,
    domain.Scope,
    String,
    Subject(Result(catalogue.Registration, Error)),
  )

  /// The owner's request to begin deleting a session through the directory:
  /// the caller, the epoch and the session. The mark is written in this turn.
  BeginDelete(
    access.Digest,
    String,
    String,
    Subject(Result(catalogue.Registration, AdminError)),
  )

  /// Removes a deletion mark the directory refused.
  Unmark(String, Subject(Result(Nil, Error)))

  /// Finishes a marked deletion once the record is gone: the session and the
  /// sessions directory.
  FinishDelete(
    String,
    String,
    List(String),
    Subject(Result(catalogue.Registration, AdminError)),
  )

  /// The sessions marked for deletion, for a pass that finishes them.
  DeletingSessions(Subject(Result(List(String), Error)))

  /// Every remote registration, active or archived, with its custody row, for
  /// seeding the directory store from this catalogue (protocol-change/083).
  RemoteRegistrations(
    Subject(Result(List(#(catalogue.Registration, catalogue.Custody)), Error)),
  )

  /// The identities of every confirmed local session, active or archived, for
  /// writing their owner records as lookup hints (protocol-change/083).
  LocalSessions(Subject(Result(List(String), Error)))

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
    // The delegate sessions whose release has stopped their slot, keyed by
    // session and holding the sessions directory the deletion is checked
    // against. The slot's drain is what deletes the session (`retired`), and a
    // restart forgets the map, which the retention sweep covers: it deletes
    // every delegate session that is not open and has no slot.
    releasing: Dict(String, String),
    // Rung after a deletion writes the releases it owes, so the daemon's release
    // drainer, which sleeps when nothing is owed, wakes for them. A registry
    // that has no drainer rings nothing.
    release_bell: fn() -> Nil,
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

  /// The session is being handed to the orchestrator `to` under the move `op`,
  /// so it may not be archived, restored or deleted until the move ends.
  AdminMoving(op: String, to: String)

  /// The session was handed to the orchestrator `to`, which owns it now.
  AdminMoved(to: String)

  /// The session cannot be moved, with the reason in words. A local session has
  /// no executor whose scope could follow it, a reserved one has no file and an
  /// archived one must be restored first.
  AdminNotMovable(reason: String)

  /// A file the operation had to place could not be, with the reason.
  AdminFailed(reason: String)
}

/// A session handed over by another orchestrator, in the form the registry
/// applies it: the registration and domain mapping the importer built from the
/// move's manifest, the move's identity, and where the verified copy waits
/// (protocol-change/078, phase 5).
@internal
pub type Import {
  Import(
    /// The registration to create, with its path under this daemon's sessions
    /// directory. A session returning to this catalogue keeps the one it has.
    registration: catalogue.Registration,
    /// The session-only domain mapping to bind with a new registration.
    mapping: domain.Domain,
    /// The move's identity.
    op: String,
    /// The `[orchestrators.<name>]` the session came from.
    from: String,
    /// Where the verified copy waits. It is moved to the registration's path in
    /// the same registry turn that records the import, and it is already
    /// there, with nothing waiting, when a repeat of the same import arrives.
    received: String,
    /// The first-prompt subtitle the source showed, kept so a listing reads the
    /// same on this side.
    subtitle: Option(String),
  )
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
/// catalogue retains the original creation name for request-key equality. A
/// session that is moving or has moved is refused as `AdminMoving` or
/// `AdminMoved`, as archiving and deleting it are, because the move row is the
/// only record of who owns it.
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

/// Replaces the model profile a session's registration names, or clears it with
/// `None` (protocol-change/082).
///
/// The session's own hub calls this when its owner switches profile, so like
/// `seed_subtitle` it carries no credential: no wire message reaches it, the
/// identity is the one the hub was built for, and the hub has already judged
/// who may ask. The registry does not check that the configuration defines the
/// name, which the hub's loader did a moment earlier; the catalogue judges only
/// its grammar. The write runs in the registry's turn, and the profile is read
/// by the next open, so a resident session is not changed by it.
///
/// ## Examples
///
/// ```gleam
/// // manager.set_profile(registry, session_id, Some("codex"))
/// ```
@internal
pub fn set_profile(
  manager: Manager(instance),
  id: String,
  profile: Option(String),
) -> Result(Nil, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: SetProfile(
    id,
    profile,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
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

/// Records which executor a pooled session's first attach chose, without
/// waiting.
///
/// The session's own assembly calls this once, after the first attach that
/// succeeded, and the write runs in the registry's turn, which serializes it
/// with every other catalogue change. The catalogue keeps the first executor it
/// is given and ignores a session that named its executor or no pool
/// (`catalogue.seed_executor`). The session's own store already names the
/// executor, and that record decides every later open, so a failed write leaves
/// a listing without the executor and changes nothing else; it is not reported.
///
/// ## Examples
///
/// ```gleam
/// // manager.seed_executor(registry, session_id, "build-box")
/// ```
@internal
pub fn seed_executor(
  manager: Manager(instance),
  id: String,
  executor: String,
) -> Nil {
  process.send(manager.commands, SeedExecutor(id, executor))
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
  // start distinguishes the limit > 0 && epoch != "" outcomes before continuing the transition.
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
            releasing: dict.new(),
            release_bell: fn() { Nil },
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

/// Finds the delegate session of a (spawner, parent session) pair and admits it,
/// or creates it on the pair's first message.
///
/// A pair with a session answers it, moves its last contact to `now_ms` and
/// opens it if it is not resident, which is how a restart or a close of the
/// session needs no step of its own. A pair with none is created through the
/// same path as any session, with the `SessionOnly` memory domain, unless the
/// spawner already holds `limit` sessions, which answers `DelegateAtLimit`. The
/// lookup, the count, the creation and the record run in one turn of the
/// registry, so two first spawns cannot both pass the cap.
///
/// ## Examples
///
/// ```gleam
/// // manager.delegate_session(registry, request) == Ok(manager.Delegated(session_id:, status:))
/// ```
@internal
pub fn delegate_session(
  manager: Manager(instance),
  request: DelegateRequest,
) -> Result(Delegated, DelegateError) {
  call.try_call(manager.commands, waiting: 5000, sending: DelegateSession(
    request,
    _,
  ))
  |> result.replace_error(DelegateFailed(Unavailable))
  |> result.flatten
}

/// Reserves a top-level session for another orchestrator's page, or finds the
/// one its request already reserved (protocol-change/094).
///
/// The lookup of the request id, the count of the spawner's two caps, the
/// registration with its domain mapping, and the row naming it run in one
/// immediate catalogue transaction in one turn of the registry, so two creates
/// cannot both pass a cap and a crash leaves all three writes or none. This
/// reserves and does not make the session's store: the caller then creates the
/// session under the same request key (`create`), which is the path that turns
/// any reservation into a session, and a request that is resent after a crash
/// between the two finds its reservation here and finishes it there.
///
/// ## Examples
///
/// ```gleam
/// // manager.reserve_relayed(registry, request) == Ok(manager.Relaying(session_id:, state: catalogue.Reserved))
/// ```
@internal
pub fn reserve_relayed(
  manager: Manager(instance),
  request: RelayRequest,
) -> Result(Relaying, RelayError) {
  call.try_call(manager.commands, waiting: 5000, sending: RelayReserve(
    request,
    _,
  ))
  |> result.replace_error(RelayFailed(Unavailable))
  |> result.flatten
}

/// Reads the relayed row of a session, or `None` for a session no orchestrator's
/// page asked for, without waking anything.
///
/// ## Examples
///
/// ```gleam
/// // manager.relayed_of(registry, session_id) == Ok(option.None)
/// ```
@internal
pub fn relayed_of(
  manager: Manager(instance),
  id: String,
) -> Result(Option(catalogue.Relayed), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: RelayedOfSession(
    id,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// One page of a spawner's relayed sessions, newest first, each with its
/// registration and live status. The read opens no conversation file.
///
/// ## Examples
///
/// ```gleam
/// // manager.relayed_sessions(registry, "laptop", after: "", limit: 64) == Ok([])
/// ```
@internal
pub fn relayed_sessions(
  manager: Manager(instance),
  spawner: String,
  after after: String,
  limit limit: Int,
) -> Result(List(RelayedView), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: RelayedSessions(
    spawner,
    after,
    limit,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Archives a relayed session of the spawner, which must hold no slot
/// (protocol-change/094). The slot check, the relayed check and the catalogue
/// transaction share one registry turn, so no open can take the session between
/// deciding it is stopped and hiding it. Archiving an archived session is not an
/// error. There is no delete here: deleting is the owner's, on this daemon's own
/// page.
///
/// ## Examples
///
/// ```gleam
/// // manager.archive_relayed(registry, "laptop", session_id)
/// ```
@internal
pub fn archive_relayed(
  manager: Manager(instance),
  spawner: String,
  id: String,
) -> Result(View, RelayedArchiveError) {
  call.try_call(manager.commands, waiting: 5000, sending: ArchiveRelayed(
    spawner,
    id,
    _,
  ))
  |> result.replace_error(ArchiveFailed(Unavailable))
  |> result.flatten
}

/// Claims one spawn against a spawner's rolling day (protocol-change/084, phase
/// 2): refuses with `DelegateDayCap` when the day's tokens have reached
/// `token_budget` or its spawns have reached `max_per_day`, and otherwise counts
/// the spawn, in one registry turn that touches only the catalogue.
///
/// The Agency's holder calls this for a child it is about to create, after it has
/// found the call site new, so a resent spawn is never claimed. `within_ms` bounds
/// the wait; an unanswered claim is `DelegateFailed(Unavailable)`, which the
/// caller must not read as a cap.
///
/// ## Examples
///
/// ```gleam
/// // manager.claim_spawn(registry, "laptop", Some(1_000_000), Some(20), now_ms: 1_000, within_ms: 5_000)
/// // == Ok(Nil)
/// ```
@internal
pub fn claim_spawn(
  manager: Manager(instance),
  spawner: String,
  token_budget: Option(Int),
  max_per_day: Option(Int),
  now_ms now_ms: Int,
  within_ms within_ms: Int,
) -> Result(Nil, DelegateError) {
  call.try_call(manager.commands, waiting: within_ms, sending: ClaimSpawn(
    spawner,
    token_budget,
    max_per_day,
    now_ms,
    _,
  ))
  |> result.replace_error(DelegateFailed(Unavailable))
  |> result.flatten
}

/// Adds the tokens a spawner's child used to the spawner's spend for the hour
/// `now_ms` falls in (protocol-change/084, phase 2). The usage hook of a
/// delegate session calls it from a process of its own, never from the strand's
/// driver, so the wait on the registry stalls only that process.
///
/// ## Examples
///
/// ```gleam
/// // manager.add_spend(registry, "laptop", now_ms: 1_000, tokens: 512) == Ok(Nil)
/// ```
@internal
pub fn add_spend(
  manager: Manager(instance),
  spawner: String,
  now_ms now_ms: Int,
  tokens tokens: Int,
) -> Result(Nil, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: SpendTokens(
    spawner,
    now_ms,
    tokens,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Reads the delegate record of a session without waking it: `Some` for the
/// session of a (spawner, parent session) pair, `None` for an ordinary session.
///
/// A session's builder asks this to learn whether it is a delegate session,
/// which decides whether its Agency reaps overdue children on a timer. The
/// registry writes the record in the turn that creates the session, before
/// it answers anything else, so a builder that asks sees it.
///
/// ## Examples
///
/// ```gleam
/// // manager.delegate_of(registry, session_id) == Ok(option.None)
/// ```
@internal
pub fn delegate_of(
  manager: Manager(instance),
  id: String,
) -> Result(Option(catalogue.Delegate), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: DelegateOf(id, _))
  |> result.unwrap(Error(Unavailable))
}

/// Installs the bell a deletion rings after it writes the releases it owes
/// (protocol-change/084, phase 2). The daemon's release drainer sleeps when
/// nothing is owed, and the bell is what wakes it for a row written later. The
/// registry starts with a bell that rings nothing.
///
/// ## Examples
///
/// ```gleam
/// // manager.on_releases_owed(registry, fn() { peer_outbox_drain.poke(name) })
/// ```
@internal
pub fn on_releases_owed(manager: Manager(instance), bell: fn() -> Nil) -> Nil {
  process.send(manager.commands, SetReleaseBell(bell))
}

/// Every release a deleted parent session still owes an orchestrator
/// (protocol-change/084, phase 2). The daemon's release drainer reads it once per
/// pass; the rows are written by the deletion itself (`delete_session`).
///
/// ## Examples
///
/// ```gleam
/// // manager.remote_releases(registry) == Ok([])
/// ```
@internal
pub fn remote_releases(
  manager: Manager(instance),
) -> Result(List(catalogue.RemoteRelease), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: RemoteReleases)
  |> result.unwrap(Error(Unavailable))
}

/// Deletes a release row once the orchestrator has answered it. A row that is
/// already gone is not an error.
///
/// ## Examples
///
/// ```gleam
/// // manager.settle_remote_release(registry, release) == Ok(Nil)
/// ```
@internal
pub fn settle_remote_release(
  manager: Manager(instance),
  release: catalogue.RemoteRelease,
) -> Result(Nil, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: SettleRemoteRelease(
    release,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Reads the delegate record of a (spawner, parent session) pair without
/// creating, opening or touching anything: `None` when the pair has no session.
///
/// A release asks this first, because a release for a pair that was never seen
/// must not make a session only to delete it (`delegate_session` does).
///
/// ## Examples
///
/// ```gleam
/// // manager.delegate_pair(registry, "laptop", parent) == Ok(option.None)
/// ```
@internal
pub fn delegate_pair(
  manager: Manager(instance),
  spawner: String,
  parent_session: String,
) -> Result(Option(catalogue.Delegate), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: DelegatePair(
    spawner,
    parent_session,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Releases the delegate session of a pair, because its spawner reported the
/// parent session deleted (protocol-change/084, phase 2).
///
/// The row moves to releasing, so no spawn is admitted for the pair from then
/// on (`delegate_session` answers `DelegateReleased`), and the session's slot,
/// if it has one, is stopped. The session and its row are deleted when the slot
/// has drained, or at once when it has none. Deleting the session deletes
/// everything stored under it. A pair with no row is `Ok` and nothing happens,
/// and a repeat tries the deletion again if the first failed.
///
/// ## Examples
///
/// ```gleam
/// // manager.release_delegate(registry, "laptop", parent, sessions) == Ok(Nil)
/// ```
@internal
pub fn release_delegate(
  manager: Manager(instance),
  spawner: String,
  parent_session: String,
  sessions: String,
) -> Result(Nil, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: ReleaseDelegate(
    spawner,
    parent_session,
    sessions,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// What the retention sweep asks about delegate sessions (protocol-change/084).
pub type Sweep(instance) {
  Sweep(
    /// What a session's spawner allows, or that its table was removed.
    standing: fn(String) -> spawners.Standing,
    /// Whether any child of a resident session still has a run. It is asked
    /// outside the registry's turn, so it may be slow and may call anything.
    activity: fn(instance) -> Activity,
  )
}

/// What a resident delegate session is doing, as the sweep needs to know it.
pub type Activity {
  /// A child has a run, or the question could not be answered.
  Busy

  /// No child has a run.
  Quiet
}

/// What one sweep did.
pub type Swept {
  Swept(
    /// The delegate sessions deleted.
    deleted: Int,
    /// The resident delegate sessions closed and kept.
    closed: Int,
  )
}

/// What the registry's turn of a sweep found: the sessions it deleted, and the
/// resident ones that may be closed once somebody has asked them whether a child
/// is running.
pub type Due(instance) {
  Due(
    /// The delegate sessions deleted.
    deleted: Int,
    /// The resident open sessions whose spawner is removed or silent past its
    /// idle window.
    candidates: List(Candidate(instance)),
  )
}

/// A resident, open delegate session whose spawner is removed or silent past
/// its idle window, as the registry saw it.
pub type Candidate(instance) {
  Candidate(
    /// The session's identity.
    session_id: String,
    /// The spawner's last contact as the registry read it, which `CloseIdle`
    /// compares against.
    last_contact_ms: Int,
    /// The running instance, for the question about its children.
    instance: instance,
  )
}

/// Deletes the delegate sessions that are due and closes the resident ones that
/// are idle, and answers how many of each (protocol-change/084, the retention
/// sweep).
///
/// A session with no slot is deleted when its spawner's table was removed,
/// when its release has begun, or when its spawner has sent nothing for longer
/// than the spawner's retention. A session the registry holds a slot for is
/// never deleted, since something is using it. Such a session is closed when it
/// is open, has no child with a run, and its spawner has been silent for the
/// spawner's `idle_close_s`, or at once when the spawner was removed. Closing
/// uses the ordinary stop and deletes nothing, so the next spawn or join
/// reopens the session. A session whose deletion fails is kept for the next
/// sweep, and the others are still swept.
///
/// This runs in the caller's process in three steps: `SweepDelegates` in the
/// registry's turn, the question about children outside it, and `CloseIdle` in
/// the registry's turn again. Asking a session about its children can be slow
/// and can fail, so it must not hold the registry. What makes the close sound
/// is the comparison in the last step. A `Spawn` or `Join` claims its pair in a
/// registry turn, which moves the row's `last_contact_ms`, before it reaches
/// the session's Agency. A claim that comes between the first step's read and
/// the last step's close therefore changes the value `CloseIdle` compares, and
/// the session is kept. A claim before the read leaves the session too recent
/// to be a candidate.
///
/// ## Examples
///
/// ```gleam
/// // manager.sweep_delegates(registry, sweep, now_ms, sessions) == Ok(manager.Swept(deleted: 1, closed: 0))
/// ```
@internal
pub fn sweep_delegates(
  manager: Manager(instance),
  sweep: Sweep(instance),
  now_ms: Int,
  sessions: String,
) -> Result(Swept, Error) {
  use Due(deleted:, candidates:) <- result.try(
    call.try_call(manager.commands, waiting: 5000, sending: SweepDelegates(
      sweep.standing,
      now_ms,
      sessions,
      _,
    ))
    |> result.unwrap(Error(Unavailable)),
  )
  let quiet =
    candidates
    |> list.filter(fn(candidate) { sweep.activity(candidate.instance) == Quiet })
    |> list.map(fn(candidate) {
      #(candidate.session_id, candidate.last_contact_ms)
    })

  // sweep_delegates distinguishes the the selected value outcomes before continuing the transition.
  use closed <- result.map(case quiet {
    [] -> Ok(0)
    [_, ..] ->
      call.try_call(manager.commands, waiting: 5000, sending: CloseIdle(
        quiet,
        _,
      ))
      |> result.replace_error(Unavailable)
  })

  Swept(deleted:, closed:)
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
  let holders = holders_of(manager, id)
  call.try_call(manager.commands, waiting: 5000, sending: Delete(
    caller,
    epoch,
    id,
    sessions,
    holders,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Reserves a creation's registration without opening it
/// (protocol-change/083). A repeat under the same request key returns the
/// stored registration, as `create` does.
///
/// ## Examples
///
/// ```gleam
/// // manager.reserve(registry, creation, directory:, generator:, scope:, configuration:)
/// ```
@internal
pub fn reserve(
  manager: Manager(instance),
  request: Creation,
  directory directory: String,
  generator generator: ids.Generator,
  scope scope: domain.Scope,
  configuration configuration: String,
) -> Result(catalogue.Registration, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Reserve(
    request,
    directory,
    generator,
    scope,
    configuration,
    _,
  ))
  |> result.unwrap(Error(Unavailable))
}

/// Begins a delete through the directory: checks the owner, the epoch and that
/// no slot is open, and writes the session's deletion mark in the same turn.
///
/// ## Examples
///
/// ```gleam
/// // manager.begin_delete(registry, owner, epoch, session_id)
/// ```
@internal
pub fn begin_delete(
  manager: Manager(instance),
  caller: access.Digest,
  epoch: String,
  id: String,
) -> Result(catalogue.Registration, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: BeginDelete(
    caller,
    epoch,
    id,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Removes a deletion mark after the directory refused the delete.
///
/// ## Examples
///
/// ```gleam
/// // manager.unmark_deleting(registry, session_id)
/// ```
@internal
pub fn unmark_deleting(
  manager: Manager(instance),
  id: String,
) -> Result(Nil, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Unmark(id, _))
  |> result.unwrap(Error(Unavailable))
}

/// Finishes a marked deletion once the directory record is gone.
///
/// ## Examples
///
/// ```gleam
/// // manager.finish_delete(registry, session_id, sessions_directory)
/// ```
@internal
pub fn finish_delete(
  manager: Manager(instance),
  id: String,
  sessions: String,
) -> Result(catalogue.Registration, AdminError) {
  let holders = holders_of(manager, id)
  call.try_call(manager.commands, waiting: 5000, sending: FinishDelete(
    id,
    sessions,
    holders,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Every remote registration, active or archived, with its custody row.
///
/// ## Examples
///
/// ```gleam
/// // manager.remote_registrations(registry)
/// ```
@internal
pub fn remote_registrations(
  manager: Manager(instance),
) -> Result(List(#(catalogue.Registration, catalogue.Custody)), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: RemoteRegistrations)
  |> result.unwrap(Error(Unavailable))
}

/// The identities of every confirmed local session, active or archived: one
/// with no executor and no pool, whose checkout is a directory on this machine.
/// An actively assembling local creation returns `Unavailable`: a coverage
/// caller must retry after confirmation rather than treat an incomplete census
/// as the completion of its creation request.
///
/// ## Examples
///
/// ```gleam
/// // manager.local_sessions(registry) == Ok([session_id])
/// ```
@internal
pub fn local_sessions(
  manager: Manager(instance),
) -> Result(List(String), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: LocalSessions)
  |> result.unwrap(Error(Unavailable))
}

/// The sessions marked for deletion, in identity order.
///
/// ## Examples
///
/// ```gleam
/// // manager.deleting_sessions(registry) == Ok([])
/// ```
@internal
pub fn deleting_sessions(
  manager: Manager(instance),
) -> Result(List(String), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: DeletingSessions)
  |> result.unwrap(Error(Unavailable))
}

/// Reads who serves a session without opening its conversation: this
/// catalogue (`Resident`), another orchestrator it was handed to (`Moved`), or
/// a move in either direction that has not finished.
///
/// ## Examples
///
/// ```gleam
/// // manager.custody(registry, session_id) == Ok(catalogue.Resident)
/// ```
@internal
pub fn custody(
  manager: Manager(instance),
  id: String,
) -> Result(catalogue.Custody, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Custody(id, _))
  |> result.unwrap(Error(Unavailable))
}

/// Reads whether a session is archived without opening it. A session this
/// catalogue does not hold is `Error(Catalogue(Missing))`, so one read tells
/// absent from held.
///
/// ## Examples
///
/// ```gleam
/// // manager.visibility(registry, session_id) == Ok(catalogue.Active)
/// ```
@internal
pub fn visibility(
  manager: Manager(instance),
  id: String,
) -> Result(catalogue.Visibility, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Visibility(id, _))
  |> result.unwrap(Error(Unavailable))
}

/// Reads who serves each of the sessions named, in one registry turn, so a
/// listing of a page marks the moving and moved sessions with one call and not
/// one for each row.
///
/// The answer pairs each identity with its custody, in the order asked, from one
/// read of the move table (`catalogue.custodies`). An identity with no move row
/// is `Resident`, which includes one the catalogue does not hold: the identities
/// of a listing come from the catalogue's own page, so none is checked again. A
/// stored move row that does not decode also reads as `Resident` here. A listing
/// is a display, and a row that shows less than it could is the safe way to be
/// wrong, since `open`, `restore` and `delete` read the row again and refuse on
/// their own.
///
/// ## Examples
///
/// ```gleam
/// // manager.custodies(registry, [session_id])
/// //   == Ok([#(session_id, catalogue.Resident)])
/// ```
@internal
pub fn custodies(
  manager: Manager(instance),
  ids: List(String),
) -> Result(List(#(String, catalogue.Custody)), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: Custodies(ids, _))
  |> result.unwrap(Error(Unavailable))
}

/// Begins handing a session to the orchestrator `to` under the move `op`, as
/// the owner, in one registry turn: the intent is committed and the session's
/// slot is stopped together, so no runtime can open the store after the intent
/// is durable.
///
/// A repeat toward the same orchestrator answers the stored `Moving`, with the
/// operation identity that is stored and not the one offered. A session that is
/// moving toward another orchestrator is a conflict, one that has moved is
/// `AdminMoved`, and a session that cannot be moved at all is
/// `AdminNotMovable` with the reason.
///
/// ## Examples
///
/// ```gleam
/// // manager.begin_move(registry, owner, epoch, id, to: "laptop", op: "0192f3c1")
/// ```
@internal
pub fn begin_move(
  manager: Manager(instance),
  caller: access.Digest,
  epoch: String,
  id: String,
  to to: String,
  op op: String,
) -> Result(catalogue.Custody, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: BeginMove(
    caller,
    epoch,
    id,
    to,
    op,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// Ends a move on the side that gave the session up, once the receiver
/// activated it: `Moving -> Moved`. A repeat answers the stored `Moved`.
///
/// ## Examples
///
/// ```gleam
/// // manager.finish_move(registry, id, op: "0192f3c1")
/// ```
@internal
pub fn finish_move(
  manager: Manager(instance),
  id: String,
  op op: String,
) -> Result(catalogue.Custody, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: FinishMove(id, op, _))
  |> result.unwrap(Error(Unavailable))
}

/// Abandons a move before anything reached the receiver: `Moving -> Resident`.
///
/// ## Examples
///
/// ```gleam
/// // manager.abort_move(registry, id, op: "0192f3c1")
/// ```
@internal
pub fn abort_move(
  manager: Manager(instance),
  id: String,
  op op: String,
) -> Result(catalogue.Custody, Error) {
  call.try_call(manager.commands, waiting: 5000, sending: AbortMove(id, op, _))
  |> result.unwrap(Error(Unavailable))
}

/// Takes in a session another orchestrator handed over, in one registry turn:
/// the registration, mapping and `Imported` custody are written together and
/// the verified copy is moved to the registration's path. A repeat of the same
/// import answers the stored custody and finishes a placement that a crash
/// interrupted.
///
/// ## Examples
///
/// ```gleam
/// // manager.import_session(registry, manager.Import(registration:, mapping:, op:, from:, received:, subtitle:))
/// ```
@internal
pub fn import_session(
  manager: Manager(instance),
  incoming: Import,
) -> Result(catalogue.Custody, AdminError) {
  call.try_call(manager.commands, waiting: 5000, sending: ImportSession(
    incoming,
    _,
  ))
  |> result.unwrap(Error(AdminUnavailable))
}

/// The moves still in `Moving`, in session order, for a restart to resume.
///
/// ## Examples
///
/// ```gleam
/// // manager.moving_sessions(registry)
/// ```
@internal
pub fn moving_sessions(
  manager: Manager(instance),
) -> Result(List(catalogue.Pending), Error) {
  call.try_call(manager.commands, waiting: 5000, sending: MovingSessions)
  |> result.unwrap(Error(Unavailable))
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
/// refuses the default rather than widening it. The answer holds at most
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

// The registry's own turn of `unshared_sessions`. One query names every
// session that has a member, and the catalogue is read a page at a time and
// filtered against that set, so the cost is one scan and the pages. The bound
// is applied to the sorted answer, so no more than `unshared_limit` sessions
// are ever returned.
/// Produces the session view with shared-session state removed.
fn unshared(book: Book(instance)) -> List(String) {
  // unshared distinguishes the access.membered_sessions(book.catalogue) outcomes before continuing the transition.
  case access.membered_sessions(book.catalogue) {
    Error(_) -> []
    Ok(membered) -> {
      let excluded = set.from_list(membered)
      unshared_from(book, "", excluded, [])
      |> list.sort(string.compare)
      |> list.take(unshared_limit)
    }
  }
}

// The catalogue's pages are in session-ID order and each is bounded, so the
// walk ends at the last page or once it has found more than the limit.
/// Projects a shared session into the local, nonshared representation.
fn unshared_from(
  book: Book(instance),
  after: String,
  excluded: set.Set(String),
  found: List(String),
) -> List(String) {
  case
    list.length(found) >= unshared_limit,
    catalogue.page(book.catalogue, after:)
  {
    True, _ | False, Error(_) -> found
    False, Ok(page) ->
      case list.last(page.records) {
        Error(Nil) -> found
        Ok(last) -> {
          let held =
            list.filter(page.records, fn(record) {
              record.state == catalogue.Saved
              && !set.contains(excluded, record.id)
            })
          unshared_from(
            book,
            last.id,
            excluded,
            list.append(list.map(held, fn(record) { record.id }), found),
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

/// Applies one daemon-manager message, preserving transition ordering while producing effects.
fn handle(
  phase: Phase,
  book: Book(instance),
  message: Message(instance),
) -> sm.Step(Phase, Book(instance), Message(instance), sm.Postponable) {
  case message {
    DomainSources(id, after, reply) -> {
      process.send(reply, source_paths(book.catalogue, id, after))
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
    SeedExecutor(id, executor) -> {
      let _written = catalogue.seed_executor(book.catalogue, id, executor)
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
        use Nil <- result.try(refuse_moved(book, id))
        use record <- result.map(
          catalogue.rename(book.catalogue, id, name)
          |> result.map_error(AdminMetadata),
        )
        View(record, status(book, record))
      }
      process.send(reply, outcome)
      sm.keep(book)
    }
    SetProfile(id, profile, reply) -> {
      process.send(
        reply,
        catalogue.set_profile(book.catalogue, id, profile)
          |> result.replace(Nil)
          |> result.map_error(Catalogue),
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
    SetVisibility(caller, epoch, id, visibility, reply) -> {
      let outcome = {
        use Nil <- result.try(authorize_admin(phase, book, caller, epoch))

        // handle distinguishes the the selected value outcomes before continuing the transition.
        use Nil <- result.try(case dict.has_key(book.slots, id) {
          True -> Error(AdminBusy)
          False -> Ok(Nil)
        })

        use Nil <- result.try(refuse_moved(book, id))
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

        // handle distinguishes the the selected value outcomes before continuing the transition.
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
    Delete(caller, epoch, id, sessions, holders, reply) -> {
      process.send(
        reply,
        delete_now(phase, book, caller, epoch, id, sessions, holders),
      )
      sm.keep(book)
    }
    Custody(id, reply) -> {
      process.send(
        reply,
        catalogue.custody(book.catalogue, id) |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    Visibility(id, reply) -> {
      process.send(
        reply,
        catalogue.visibility(book.catalogue, id) |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    Custodies(ids, reply) -> {
      // One statement reads every move row, and each asked identity is paired
      // with its row or with `Resident`, in the order asked.
      let read =
        catalogue.custodies(book.catalogue)
        |> result.map(fn(rows) {
          let moves = dict.from_list(rows)
          list.map(ids, fn(id) {
            #(id, result.unwrap(dict.get(moves, id), catalogue.Resident))
          })
        })
        |> result.map_error(Catalogue)
      process.send(reply, read)
      sm.keep(book)
    }
    BeginMove(caller, epoch, id, to, op, reply) -> {
      let #(book, outcome) =
        begin_move_now(phase, book, caller, epoch, id, to, op)
      process.send(reply, outcome)
      step(phase, book)
    }
    FinishMove(id, op, reply) -> {
      process.send(
        reply,
        catalogue.finish_move(book.catalogue, id, op:)
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    AbortMove(id, op, reply) -> {
      process.send(
        reply,
        catalogue.abort_move(book.catalogue, id, op:)
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    ImportSession(incoming, reply) -> {
      process.send(reply, import_now(phase, book, incoming))
      sm.keep(book)
    }
    MovingSessions(reply) -> {
      process.send(
        reply,
        catalogue.moving(book.catalogue) |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    Reserve(request, directory, generator, scope, configuration, reply) -> {
      // handle distinguishes the the selected value outcomes before continuing the transition.
      let outcome = case phase {
        ShuttingDown -> Error(Unavailable)
        Ready ->
          reserve_creation(
            book.catalogue,
            request,
            directory,
            generator,
            scope,
            configuration,
          )
          |> result.map_error(Catalogue)
      }

      process.send(reply, outcome)
      sm.keep(book)
    }
    BeginDelete(caller, epoch, id, reply) -> {
      process.send(reply, begin_delete_now(phase, book, caller, epoch, id))
      sm.keep(book)
    }
    Unmark(id, reply) -> {
      process.send(
        reply,
        catalogue.unmark_deleting(book.catalogue, id)
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    FinishDelete(id, sessions, holders, reply) -> {
      process.send(reply, finish_delete_now(phase, book, id, sessions, holders))
      sm.keep(book)
    }
    RemoteRegistrations(reply) -> {
      process.send(reply, remote_registrations_in(book.catalogue))
      sm.keep(book)
    }
    LocalSessions(reply) -> {
      process.send(reply, local_sessions_in(book))
      sm.keep(book)
    }
    DeletingSessions(reply) -> {
      process.send(
        reply,
        catalogue.deleting(book.catalogue) |> result.map_error(Catalogue),
      )
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
      // handle distinguishes the the selected value outcomes before continuing the transition.
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
      // handle distinguishes the the selected value outcomes before continuing the transition.
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

        // handle distinguishes the the selected value outcomes before continuing the transition.
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
    AuthorizedPage(digest, after, reply) -> {
      let outcome = {
        use principal <- result.try(principal_of(book, digest))

        // handle distinguishes the principal.kind outcomes before continuing the transition.
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

        // handle distinguishes the principal.kind outcomes before continuing the transition.
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
    DelegateSession(request, reply) -> {
      let #(book, outcome) = delegate_now(phase, book, request)
      process.send(reply, outcome)
      step(phase, book)
    }
    RelayReserve(request, reply) -> {
      process.send(reply, relay_now(phase, book, request))
      sm.keep(book)
    }
    RelayedOfSession(id, reply) -> {
      process.send(
        reply,
        catalogue.relayed_of(book.catalogue, id) |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    RelayedSessions(spawner, after, limit, reply) -> {
      process.send(reply, relayed_page_now(book, spawner, after, limit))
      sm.keep(book)
    }
    ArchiveRelayed(spawner, id, reply) -> {
      process.send(reply, archive_relayed_now(phase, book, spawner, id))
      sm.keep(book)
    }
    ClaimSpawn(spawner, token_budget, max_per_day, now_ms, reply) -> {
      process.send(
        reply,
        claim_now(book, spawner, token_budget, max_per_day, now_ms),
      )
      sm.keep(book)
    }
    SpendTokens(spawner, now_ms, tokens, reply) -> {
      process.send(
        reply,
        catalogue.add_spawner_spend(
          book.catalogue,
          spawner,
          now_ms:,
          tokens:,
          spawns: 0,
        )
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    DelegateOf(id, reply) -> {
      process.send(
        reply,
        catalogue.delegate_of(book.catalogue, id)
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    SetReleaseBell(bell) -> sm.keep(Book(..book, release_bell: bell))
    RemoteReleases(reply) -> {
      process.send(
        reply,
        catalogue.remote_releases(book.catalogue) |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    SettleRemoteRelease(release, reply) -> {
      process.send(
        reply,
        catalogue.settle_remote_release(
          book.catalogue,
          release.parent_session,
          release.orchestrator,
        )
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    DelegatePair(spawner, parent_session, reply) -> {
      process.send(
        reply,
        catalogue.delegate_for(book.catalogue, spawner, parent_session)
          |> result.map_error(Catalogue),
      )
      sm.keep(book)
    }
    ReleaseDelegate(spawner, parent_session, sessions, reply) -> {
      let #(book, outcome) =
        release_now(book, spawner, parent_session, sessions)
      process.send(reply, outcome)
      step(phase, book)
    }
    SweepDelegates(standing, now_ms, sessions, reply) -> {
      process.send(reply, sweep_now(book, standing, now_ms, sessions))
      sm.keep(book)
    }
    CloseIdle(seen, reply) -> {
      let #(book, closed) = close_idle(book, seen)
      process.send(reply, closed)
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
      // handle distinguishes the the selected value outcomes before continuing the transition.
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
      // handle distinguishes the the selected value outcomes before continuing the transition.
      let instance = case dict.get(book.slots, id) {
        Ok(Slot(phase: Running(instance), ..)) -> Ok(instance)
        Ok(Slot(..)) | Error(Nil) -> Error(Unavailable)
      }

      process.send(reply, instance)
      sm.keep(book)
    }
    ResolveIncarnation(id, incarnation, reply) -> {
      // handle distinguishes the the selected value outcomes before continuing the transition.
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
      // handle distinguishes the dict.get(book.slots, id) outcomes before continuing the transition.
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

/// Resolves an authenticated owner identity from the request context.
fn authenticated_owner(book: Book(instance), digest) {
  use principal <- result.try(
    principal_of(book, digest)
    |> result.replace_error(AdminForbidden),
  )

  // authenticated_owner distinguishes the principal.kind outcomes before continuing the transition.
  case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error(AdminForbidden)
  }
}

// Whose sign-ins a caller may read or revoke, or whose name it may change: its
// own, or any principal's when the caller is the owner. The caller is authenticated first, as the kind its
// digest was made as, so a revoked login reads and revokes nothing.
/// Determines which principal the operation is authorized to act for.
fn acting_on(
  book: Book(instance),
  caller: access.Digest,
  target: Option(String),
) -> Result(String, AdminError) {
  use principal <- result.try(
    principal_of(book, caller) |> result.replace_error(AdminForbidden),
  )

  // acting_on distinguishes the target outcomes before continuing the transition.
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
/// Reads the current membership epoch used to fence stale authority.
fn current_epoch(
  phase,
  book: Book(instance),
  epoch,
) -> Result(Nil, AdminError) {
  // current_epoch distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case phase {
    Ready -> Ok(Nil)
    ShuttingDown -> Error(AdminUnavailable)
  })

  // current_epoch distinguishes the epoch == book.epoch outcomes before continuing the transition.
  case epoch == book.epoch {
    True -> Ok(Nil)
    False -> Error(AdminStaleEpoch)
  }
}

/// Checks whether the caller may administer the requested member.
fn authorize_admin(phase, book: Book(instance), digest, epoch) {
  // authorize_admin distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case phase {
    Ready -> Ok(Nil)
    ShuttingDown -> Error(AdminUnavailable)
  })

  use principal <- result.try(
    principal_of(book, digest)
    |> result.replace_error(AdminForbidden),
  )

  // authorize_admin distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error(AdminForbidden)
  })

  // authorize_admin distinguishes the epoch == book.epoch outcomes before continuing the transition.
  case epoch == book.epoch {
    True -> Ok(Nil)
    False -> Error(AdminStaleEpoch)
  }
}

/// Applies an authorized member-administration request and returns its transition result.
fn administer_member(store, action) {
  // administer_member distinguishes the action outcomes before continuing the transition.
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

/// Requires a shared session before applying shared-session operations.
fn require_shared(store, session_id) {
  use selected <- result.try(
    domain.for_session(store, session_id) |> result.map_error(AdminMetadata),
  )

  // require_shared distinguishes the selected.scope outcomes before continuing the transition.
  case selected.scope {
    domain.WorkspacePrivate -> Error(IsolationRequired)
    domain.SessionOnly -> Ok(Nil)
  }
}

/// Performs the immediate shared-to-isolated session transition.
fn isolate_now(phase, book: Book(instance), caller, epoch, id, state_root) {
  use Nil <- result.try(authorize_admin(phase, book, caller, epoch))

  // isolate_now distinguishes the the selected value outcomes before continuing the transition.
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

// A session that is moving or has moved is not this catalogue's to archive,
// restore or delete: the move row is the only record of who owns it. Both
// answers name the other side, so the caller can say where the session went.
/// Returns the refusal used when a session has already moved.
fn refuse_moved(book: Book(instance), id: String) -> Result(Nil, AdminError) {
  case catalogue.custody(book.catalogue, id) {
    Ok(catalogue.Moving(op:, to:)) -> Error(AdminMoving(op:, to:))
    Ok(catalogue.Moved(to:, ..)) -> Error(AdminMoved(to:))
    Ok(catalogue.Resident) | Ok(catalogue.Imported(..)) -> Ok(Nil)
    Error(error) -> Error(AdminMetadata(error))
  }
}

// The write-ahead step of a move: the intent and the stop share this turn, so
// nothing can open the store between deciding to hand the session over and
// recording that the decision was made. The intent is committed before the slot
// is cancelled, which leaves a crash between the two with a `Moving` row and a
// slot that does not exist after restart, the state the mover resumes from.
/// Starts the move after validating that the session can leave its current owner.
fn begin_move_now(
  phase: Phase,
  book: Book(instance),
  caller: access.Digest,
  epoch: String,
  id: String,
  to: String,
  op: String,
) -> #(Book(instance), Result(catalogue.Custody, AdminError)) {
  let decided = {
    use Nil <- result.try(authorize_admin(phase, book, caller, epoch))
    use record <- result.try(
      catalogue.get(book.catalogue, id) |> result.map_error(AdminMetadata),
    )
    use Nil <- result.try(movable(book, record))
    use custody <- result.try(
      catalogue.custody(book.catalogue, id) |> result.map_error(AdminMetadata),
    )

    // begin_move_now distinguishes the custody outcomes before continuing the transition.
    case custody {
      catalogue.Moved(to: owner, ..) -> Error(AdminMoved(to: owner))
      catalogue.Moving(to: heading, ..) if heading == to -> Ok(custody)
      catalogue.Moving(..) -> Error(AdminMetadata(catalogue.Conflict))
      catalogue.Resident | catalogue.Imported(..) ->
        catalogue.begin_move(book.catalogue, id, op:, to:)
        |> result.map_error(AdminMetadata)
    }
  }

  // begin_move_now distinguishes the decided outcomes before continuing the transition.
  case decided {
    Ok(custody) -> #(stop_slot(book, id), Ok(custody))
    Error(error) -> #(book, Error(error))
  }
}

// Whether a registration can be handed over: a session on an executor, whose
// scope the receiver can reopen, that has a file and is not archived. A local
// session's checkout is a directory on this machine, which does not travel.
/// Checks the session state and ownership conditions required for a move.
fn movable(
  book: Book(instance),
  record: catalogue.Registration,
) -> Result(Nil, AdminError) {
  use visibility <- result.try(
    catalogue.visibility(book.catalogue, record.id)
    |> result.map_error(AdminMetadata),
  )

  // A delegate session serves the orchestrator whose subagents it holds and
  // answers to it by name, so handing it to a third orchestrator would strand
  // them (protocol-change/084). The marker is the catalogue's own row.
  use marker <- result.try(
    catalogue.delegate_of(book.catalogue, record.id)
    |> result.map_error(AdminMetadata),
  )

  // movable distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case marker {
    Some(_) ->
      Error(AdminNotMovable(
        "a delegate session serves its spawner's subagents and does not move",
      ))
    None -> Ok(Nil)
  })

  // movable distinguishes the record.state, visibility, record.executor outcomes before continuing the transition.
  case record.state, visibility, record.executor {
    catalogue.Reserved, _, _ ->
      Error(AdminNotMovable("the session has not finished being created"))
    _, catalogue.Archived, _ ->
      Error(AdminNotMovable("the session is archived; restore it first"))
    _, _, "" ->
      Error(AdminNotMovable(
        "only a session on an executor can move; this one has no executor yet",
      ))
    catalogue.Saved, catalogue.Active, _ -> Ok(Nil)
  }
}

// Applies a session another orchestrator handed over. The registration, the
// mapping and the import row commit together, then the verified copy is moved
// into place, all in this turn, so no open sees the row without the file. A
// crash between the commit and the rename leaves the copy where it was, and the
// same import arriving again finishes the rename.
/// Imports a moved session and reconciles its committed state with the local manager.
fn import_now(
  phase: Phase,
  book: Book(instance),
  incoming: Import,
) -> Result(catalogue.Custody, AdminError) {
  // import_now distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case phase {
    Ready -> Ok(Nil)
    ShuttingDown -> Error(AdminUnavailable)
  })

  let id = incoming.registration.id

  // Whether this import already committed is read before anything else, since
  // the answer to a repeat is the same row. A repeat must not put a copy over a
  // file that is in place: whatever waits is a late duplicate, and the session
  // may have run on the placed file since.
  //
  // The read must not fail silently into "not a repeat". A session the catalogue
  // has no row for is the ordinary first arrival, but any other failure leaves
  // the question open, and treating it as a first import would answer a repeat
  // with a refusal when a slot is open, or put a late duplicate over the placed
  // file when none is. It is reported as `AdminFailed`, and not as a metadata
  // error, because the importer turns an invalid-metadata error into a refusal
  // and a refusal is final for the source; a failure is a stall, and the source
  // asks again. No test injects the failure: every write to the move table goes
  // through validation, so the rows the public API can produce always decode,
  // and a closed database crashes the registry in the driver instead of
  // returning an error. The rule is held by the shape of the case, which has no
  // arm that maps an unreadable row to `False`.
  use repeat <- result.try(case catalogue.custody(book.catalogue, id) {
    Ok(held) ->
      Ok(held == catalogue.Imported(op: incoming.op, from: incoming.from))
    Error(catalogue.Missing) -> Ok(False)
    Error(other) ->
      Error(AdminFailed(
        "the session's move record could not be read: " <> string.inspect(other),
      ))
  })

  // An open slot refuses a first import, which would replace the file under a
  // running session. It cannot refuse a repeat. Once the commit exists the
  // sender must be told yes however often it asks, because it treats a refusal
  // as final and takes the session back, and the owner may well have opened the
  // session here after the first reply was lost. A repeat touches no file that

  // is in place, so a running session is safe from it.
  use Nil <- result.try(case repeat, dict.has_key(book.slots, id) {
    False, True -> Error(AdminBusy)
    True, _ | False, False -> Ok(Nil)
  })

  use custody <- result.try(
    domain.import_session(
      book.catalogue,
      incoming.registration,
      incoming.mapping,
      op: incoming.op,
      from: incoming.from,
    )
    |> result.map_error(AdminMetadata),
  )

  // import_now distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case repeat {
    True -> finish_placement(incoming)
    False -> place_received(incoming)
  })

  // import_now distinguishes the incoming.subtitle outcomes before continuing the transition.
  case incoming.subtitle {
    option.Some(text) -> {
      let _seeded = catalogue.seed_subtitle(book.catalogue, id, text)
      Nil
    }
    option.None -> Nil
  }

  Ok(custody)
}

// Completes the placement a repeated import may have left unfinished. A file
// already at the session's path was placed by the import that committed, so a
// copy still waiting is a late duplicate and is removed; with no file there, the
// commit was not followed by its rename, and the waiting copy is placed now.
/// Completes placement after the destination has accepted the session.
fn finish_placement(incoming: Import) -> Result(Nil, AdminError) {
  // finish_placement distinguishes the simplifile.is_file(incoming.registration.path) outcomes before continuing the transition.
  case simplifile.is_file(incoming.registration.path) {
    Ok(True) -> {
      let _removed = simplifile.delete_file(incoming.received)
      Ok(Nil)
    }
    Ok(False) | Error(_) -> place_received(incoming)
  }
}

// Moves the verified copy to the session's path. A copy that is no longer
// waiting is the repeat of an import that already placed it, which is fine only
// if the session's file is there.
/// Places an incoming session only after its transfer state is accepted.
fn place_received(incoming: Import) -> Result(Nil, AdminError) {
  let path = incoming.registration.path

  // place_received distinguishes the simplifile.is_file(incoming.received) outcomes before continuing the transition.
  case simplifile.is_file(incoming.received) {
    Ok(True) ->
      case simplifile.create_directory_all(filepath.directory_name(path)) {
        Ok(Nil) ->
          simplifile.rename(at: incoming.received, to: path)
          |> result.map_error(fn(error) {
            AdminFailed(
              "the session file could not be put in place: "
              <> simplifile.describe_error(error),
            )
          })
        Error(error) ->
          Error(AdminFailed(
            "the sessions directory is unusable: "
            <> simplifile.describe_error(error),
          ))
      }
    Ok(False) | Error(_) ->
      case simplifile.is_file(path) {
        Ok(True) -> Ok(Nil)
        Ok(False) | Error(_) ->
          Error(AdminFailed("the received session file is gone"))
      }
  }
}

// Deletion runs entirely inside this actor turn, which is what makes the
// busy check meaningful: no open can take a slot between the check and the
// removal, and once the row is gone `admit` can no longer find the session
// to open it. The unlink follows the commit for the same reason isolation
// writes metadata first — a half-applied delete must leave files without a
// registration, never a registration without files.
// The first half of a delete through the directory (protocol-change/083). The
// mark is written in the same turn that finds no slot open, and admission reads
// it in the turn that reserves one, so nothing can open the session between
// this turn and the record's deletion. The mark comes before the record is
// touched because it stops this daemon serving the session.
/// Begins deletion after checking the session registration and current state.
fn begin_delete_now(
  phase,
  book: Book(instance),
  caller,
  epoch,
  id,
) -> Result(catalogue.Registration, AdminError) {
  use Nil <- result.try(authorize_admin(phase, book, caller, epoch))

  // begin_delete_now distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case dict.has_key(book.slots, id) {
    True -> Error(AdminBusy)
    False -> Ok(Nil)
  })

  use Nil <- result.try(refuse_moved(book, id))
  use record <- result.try(
    catalogue.get(book.catalogue, id) |> result.map_error(AdminMetadata),
  )
  use Nil <- result.try(
    catalogue.mark_deleting(book.catalogue, id)
    |> result.map_error(AdminMetadata),
  )
  Ok(record)
}

// Every registration placed on an executor or a pool, in both visibilities,
// paired with its custody row. Local sessions have no directory record.
/// Collects remote registrations represented by the supplied session state.
fn remote_registrations_in(
  store: catalogue.Catalogue,
) -> Result(List(#(catalogue.Registration, catalogue.Custody)), Error) {
  use active <- result.try(all_pages(store, catalogue.page, "", []))
  use archived <- result.try(all_pages(store, catalogue.archived_page, "", []))
  list.append(active, archived)
  |> list.filter(fn(record) { record.executor != "" || record.pool != "" })
  |> list.try_map(fn(record) {
    catalogue.custody(store, record.id)
    |> result.map(fn(custody) { #(record, custody) })
  })
  |> result.map_error(Catalogue)
}

// A reserved registration has no session yet to find. While its builder still
// owns an admission, omitting it would let the directory cover request finish
// before confirmation, with no later request to publish the new local hint.
/// Collects local sessions represented by the supplied session state.
fn local_sessions_in(book: Book(instance)) -> Result(List(String), Error) {
  use active <- result.try(all_pages(book.catalogue, catalogue.page, "", []))
  use archived <- result.try(
    all_pages(book.catalogue, catalogue.archived_page, "", []),
  )
  let local =
    list.append(active, archived)
    |> list.filter(fn(record) { record.executor == "" && record.pool == "" })
  let slots = book.slots
  let assembling =
    list.any(local, fn(record) {
      record.state == catalogue.Reserved
      && case dict.get(slots, record.id) {
        Ok(Slot(phase: WaitingForDomain, ..)) | Ok(Slot(phase: Building, ..)) ->
          True
        Ok(Slot(phase: Closing, ..))
        | Ok(Slot(phase: Blocked(_), ..))
        | Ok(Slot(phase: Running(_), ..))
        | Error(Nil) -> False
      }
    })

  // Failed and inactive reservations have no pending confirmation, so they do
  // not prevent confirmed sessions from receiving their lookup hints.
  case assembling {
    True -> Error(Unavailable)
    False ->
      local
      |> list.filter(fn(record) { record.state != catalogue.Reserved })
      |> list.map(fn(record) { record.id })
      |> Ok
  }
}

/// Reads all bounded pages needed to complete the session listing.
fn all_pages(
  store: catalogue.Catalogue,
  page: fn(catalogue.Catalogue, String) ->
    Result(catalogue.Page, catalogue.Error),
  after: String,
  seen: List(catalogue.Registration),
) -> Result(List(catalogue.Registration), Error) {
  // all_pages distinguishes the page(store, after) outcomes before continuing the transition.
  case page(store, after) {
    Error(error) -> Error(Catalogue(error))
    Ok(catalogue.Page(records: [], ..)) -> Ok(list.reverse(seen))
    Ok(catalogue.Page(records:, ..)) -> {
      let last = list.fold(records, after, fn(_, record) { record.id })
      all_pages(store, page, last, list.append(list.reverse(records), seen))
    }
  }
}

// The second half: the record is gone, so the registration, its mark and its
// file go. It needs the mark, which is the owner's authorized intent recorded
// by the first half, so a restart can finish it without a caller.
/// Finishes deletion after dependent session state has been retired.
fn finish_delete_now(
  phase,
  book: Book(instance),
  id,
  sessions,
  holders,
) -> Result(catalogue.Registration, AdminError) {
  // finish_delete_now distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case phase {
    Ready -> Ok(Nil)
    ShuttingDown -> Error(AdminUnavailable)
  })

  use marked <- result.try(
    catalogue.deletion(book.catalogue, id) |> result.map_error(AdminMetadata),
  )

  // finish_delete_now distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case marked {
    catalogue.Deleting -> Ok(Nil)
    catalogue.NotDeleting ->
      Error(AdminFailed("the session is not marked for deletion"))
  })

  // finish_delete_now distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case dict.has_key(book.slots, id) {
    True -> Error(AdminBusy)
    False -> Ok(Nil)
  })

  delete_registration(book, id, sessions, holders)
}

/// Deletes the registration through the manager-owned deletion transition.
fn delete_now(
  phase,
  book: Book(instance),
  caller,
  epoch,
  id,
  sessions,
  holders,
) {
  use Nil <- result.try(authorize_admin(phase, book, caller, epoch))

  // delete_now distinguishes the the selected value outcomes before continuing the transition.
  use Nil <- result.try(case dict.has_key(book.slots, id) {
    True -> Error(AdminBusy)
    False -> Ok(Nil)
  })

  use Nil <- result.try(refuse_moved(book, id))
  delete_registration(book, id, sessions, holders)
}

// An owner's deletion of a session: the releases it owes come first, and the
// registration second. The order is what makes a crash between them safe (see
// `client/remote_release`). The rows are written here, in the registry's turn
// and before the registration leaves.
//
// The orchestrators that hold a child arrive in the message. The stubs that name
// them are in the session's own file, which `holders_of` reads in the caller's
// process before it sends: opening a store runs its migrations and links its
// actor to the process that opens it, and neither belongs in the registry's
// turn. That leaves one window, between the read and the turn, in which the
// session could be reopened, start a child and close again. The deletion would
// then miss that child's orchestrator, and the child would run to its deadline
// as it did before releases existed. Nothing is built for it: the deletion
// needs the session closed, and the caller has just seen it so.
//
// A file that cannot be read owes nothing: a session whose file is unreadable
// could not have been waited on. A catalogue that cannot take the rows refuses
// the deletion, since the same catalogue would be taking the deletion next.
/// Removes the registration record after its lifecycle permits deletion.
fn delete_registration(
  book: Book(instance),
  id: String,
  sessions: String,
  holders: List(String),
) -> Result(catalogue.Registration, AdminError) {
  use Nil <- result.try(owe_releases(book, id, holders))
  remove_registration(book, id, sessions)
}

/// Finds outstanding release obligations retained for active holders.
fn owe_releases(
  book: Book(instance),
  id: String,
  holders: List(String),
) -> Result(Nil, AdminError) {
  // owe_releases distinguishes the holders outcomes before continuing the transition.
  case holders {
    [] -> Ok(Nil)
    [_, ..] -> {
      use Nil <- result.map(
        catalogue.write_remote_releases(
          book.catalogue,
          id,
          holders,
          now_ms: ffi_os.system_time_ms(),
        )
        |> result.map_error(AdminMetadata),
      )
      book.release_bell()
    }
  }
}

// The orchestrators that may hold a child of a session about to be deleted,
// read from its closed file in the caller's process. A session the registry
// cannot name, or a file that cannot be read, owes nothing.
/// Selects holders that own the requested session resource.
fn holders_of(manager: Manager(instance), id: String) -> List(String) {
  case get(manager, id) {
    Error(_) -> []
    Ok(View(registration:, ..)) ->
      case
        remote_release.stubs_at(
          registration.path,
          "delete-read:" <> id,
          clock.from_function(ffi_os.system_time_ms),
        )
      {
        Ok(kept) -> remote_child.holders(kept)
        Error(_) -> []
      }
  }
}

// The first turn of the retention sweep, which reads the rows once and acts on
// the ones with no slot. A row with no slot can be deleted and a row with one
// can only be closed, so the held rows that look idle are handed back as
// candidates with the contact time this turn read, and the second turn
// (`close_idle`) closes the ones that are still as they were.
//
// The decoder keeps retention at or above the longest deadline, so a session
// past it holds no child that could still be running. Closing has no such
// bound, so the caller asks each candidate whether a child still has a run. A
// deletion that fails leaves its session for the next sweep, since nothing can
// usefully retry it here.
/// Coordinates sweep now with the daemon manager’s session state and effects.
fn sweep_now(
  book: Book(instance),
  standing: fn(String) -> spawners.Standing,
  now_ms: Int,
  sessions: String,
) -> Result(Due(instance), Error) {
  use rows <- result.map(
    catalogue.delegates(book.catalogue) |> result.map_error(Catalogue),
  )
  let #(held, free) =
    list.partition(rows, fn(row) { dict.has_key(book.slots, row.session_id) })
  let deleted =
    free
    |> list.filter(fn(row) { due_for_deletion(standing, row, now_ms) })
    |> list.count(fn(row) {
      result.is_ok(delete_delegate(book, row.session_id, sessions))
    })
  let candidates =
    list.filter_map(held, fn(row) {
      case silent_past_idle(standing, row, now_ms), running_slot(book, row) {
        True, Ok(instance) ->
          Ok(Candidate(
            session_id: row.session_id,
            last_contact_ms: row.last_contact_ms,
            instance:,
          ))
        _, _ -> Error(Nil)
      }
    })
  Due(deleted:, candidates:)
}

// The second turn of the retention sweep. A session is stopped only if it is
// still open, still resident and running, and its spawner's last contact is the
// one the first turn saw. The stop is the ordinary one, and the row stays. A
// session that failed any of the three is skipped, and the next sweep judges it
// again.
/// Coordinates close idle with the daemon manager’s session state and effects.
fn close_idle(
  book: Book(instance),
  seen: List(#(String, Int)),
) -> #(Book(instance), Int) {
  list.fold(seen, #(book, 0), fn(so_far, one) {
    let #(book, closed) = so_far
    let #(session_id, contact) = one

    // close_idle distinguishes the catalogue.delegate_of(book.catalogue, session_id) outcomes before continuing the transition.
    case catalogue.delegate_of(book.catalogue, session_id) {
      Ok(Some(row)) ->
        case row.last_contact_ms == contact, running_slot(book, row) {
          True, Ok(_instance) -> #(stop_slot(book, session_id), closed + 1)
          _, _ -> #(book, closed)
        }
      Ok(None) | Error(_) -> #(book, closed)
    }
  })
}

// The instance of the running slot that holds the row's session, if the row is
// open and a slot is running. A session that is still opening or already
// closing is left to finish.
/// Coordinates running slot with the daemon manager’s session state and effects.
fn running_slot(
  book: Book(instance),
  row: catalogue.Delegate,
) -> Result(instance, Nil) {
  case row.state, dict.get(book.slots, row.session_id) {
    catalogue.Open, Ok(Slot(phase: Running(instance), ..)) -> Ok(instance)
    _, _ -> Error(Nil)
  }
}

// Whether a session with no slot is deleted: its spawner was removed, its
// release has begun, or its spawner has been silent past the retention.
/// Coordinates due for deletion with the daemon manager’s session state and effects.
fn due_for_deletion(
  standing: fn(String) -> spawners.Standing,
  row: catalogue.Delegate,
  now_ms: Int,
) -> Bool {
  case standing(row.spawner) {
    spawners.Removed -> True
    spawners.Configured(retain_ms:, ..) ->
      release_begun(row) || now_ms - row.last_contact_ms > retain_ms
  }
}

// Whether the spawner is gone or has been silent for its `idle_close_s`.
/// Coordinates silent past idle with the daemon manager’s session state and effects.
fn silent_past_idle(
  standing: fn(String) -> spawners.Standing,
  row: catalogue.Delegate,
  now_ms: Int,
) -> Bool {
  case standing(row.spawner) {
    spawners.Removed -> True
    spawners.Configured(idle_close_ms:, ..) ->
      now_ms - row.last_contact_ms > idle_close_ms
  }
}

// A session whose spawner reported the parent deleted is deleted whatever its
// age, once nothing holds its slot: the retention only bounds a spawner that
// went quiet, and this one said what it meant.
fn release_begun(row: catalogue.Delegate) -> Bool {
  case row.state {
    catalogue.Open -> False
    catalogue.Releasing | catalogue.Released -> True
  }
}

// The release of one pair, in the registry's own turn so that no spawn is
// admitted between marking the session and stopping its slot. A pair with no
// row has nothing to release, and nothing is created for it. The state moves
// forward only, so a repeat leaves it where it is and tries the deletion again,
// which is how a deletion that failed is healed.
/// Coordinates release now with the daemon manager’s session state and effects.
fn release_now(
  book: Book(instance),
  spawner: String,
  parent_session: String,
  sessions: String,
) -> #(Book(instance), Result(Nil, Error)) {
  // release_now distinguishes the catalogue.delegate_for(book.catalogue, spawner, parent_session) outcomes before continuing the transition.
  case catalogue.delegate_for(book.catalogue, spawner, parent_session) {
    Error(error) -> #(book, Error(Catalogue(error)))
    Ok(None) -> #(book, Ok(Nil))
    Ok(Some(found)) -> {
      // release_now distinguishes the the selected value outcomes before continuing the transition.
      let marked = case found.state {
        catalogue.Open ->
          catalogue.set_delegate_state(
            book.catalogue,
            found.session_id,
            catalogue.Releasing,
          )
        catalogue.Releasing | catalogue.Released -> Ok(Nil)
      }

      // release_now distinguishes the marked outcomes before continuing the transition.
      case marked {
        Error(error) -> #(book, Error(Catalogue(error)))
        Ok(Nil) ->
          case dict.has_key(book.slots, found.session_id) {
            // Something holds the slot: stop it, and let the drain delete the
            // session.
            True -> #(
              Book(
                ..stop_slot(book, found.session_id),
                releasing: dict.insert(
                  book.releasing,
                  found.session_id,
                  sessions,
                ),
              ),
              Ok(Nil),
            )
            False -> #(book, finish_release(book, found.session_id, sessions))
          }
      }
    }
  }
}

// The last step of a release, once no slot holds the session: the row says the
// slot has drained, and then the session and its row go together. A deletion
// that fails leaves the row released, and the next release or sweep tries again.
/// Coordinates finish release while keeping the session lifecycle transition explicit.
fn finish_release(
  book: Book(instance),
  session_id: String,
  sessions: String,
) -> Result(Nil, Error) {
  use Nil <- result.try(
    catalogue.set_delegate_state(book.catalogue, session_id, catalogue.Released)
    |> result.map_error(Catalogue),
  )
  delete_delegate(book, session_id, sessions)
  |> result.replace(Nil)
  |> result.map_error(fn(_) { Unavailable })
}

// The deletion of a delegate session that no slot holds, and the releases it
// owes in turn (protocol-change/084, phase 4). A child of the session may have
// started children of its own on another orchestrator, and the session's stubs
// are the only record of them. So this turn reads the stubs from the closed
// file and writes one release row for each orchestrator they name before it
// removes the registration, as a parent session's deletion does.
//
// The rows are written here and not when the release begins. Until the slot
// has drained, the session's drainer and a spawn still being asked keep
// resending the `Spawn` of a stub that is `Requested`, and one that reached the
// other orchestrator after its `Release` would make a child there whose parent
// is gone. Once the slot has drained nothing of the session runs to send it.
/// Coordinates delete delegate while keeping the session lifecycle transition explicit.
fn delete_delegate(
  book: Book(instance),
  session_id: String,
  sessions: String,
) -> Result(catalogue.Registration, AdminError) {
  use existing <- result.try(
    catalogue.get(book.catalogue, session_id) |> result.map_error(AdminMetadata),
  )
  use Nil <- result.try(owe_releases(
    book,
    session_id,
    descendant_holders(existing.path, session_id),
  ))
  remove_registration(book, session_id, sessions)
}

// How long the registry's turn may spend reading a closed delegate session's
// stubs, in milliseconds. The read lists one prefix and closes.
const descendant_read_ms = 5000

// The orchestrators a closed delegate session's stubs name. The file is read in
// a task with a deadline, so a store that faults or hangs costs the turn the
// bound and no more, and the store's actor is linked to the task and not to the
// registry. A file that cannot be read owes nothing, as for a deletion: the
// children below it run to their deadlines.
/// Coordinates descendant holders with the daemon manager’s session state and effects.
fn descendant_holders(path: String, session_id: String) -> List(String) {
  let read =
    [
      fn() {
        remote_release.stubs_at(
          path,
          "release-read:" <> session_id,
          clock.from_function(ffi_os.system_time_ms),
        )
      },
    ]
    |> weft.new
    |> weft.deadline(descendant_read_ms)
    |> weft.start

  // descendant_holders distinguishes the read outcomes before continuing the transition.
  case read {
    [weft.Completed(value: kept, ..)] -> remote_child.holders(kept)
    _ -> []
  }
}

/// Coordinates remove registration with the daemon manager’s session state and effects.
fn remove_registration(
  book: Book(instance),
  id: String,
  sessions: String,
) -> Result(catalogue.Registration, AdminError) {
  // Containment is decided against the row still in the catalogue, before
  // the transaction removes it. A row naming a path outside the sessions
  // directory keeps both its registration and its files: refusing early is
  // what stops the scratch-directory removal below from being pointed at an
  // arbitrary tree by a row nobody minted here.
  use existing <- result.try(
    catalogue.get(book.catalogue, id) |> result.map_error(AdminMetadata),
  )

  // This guard prevents deletion when a registration points outside the session root.
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
/// Coordinates unlink conversation with the daemon manager’s session state and effects.
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

/// Coordinates admin member with the daemon manager’s session state and effects.
fn admin_member(store, id) {
  use principal <- result.try(access.get(store, id))

  // admin_member distinguishes the principal.kind outcomes before continuing the transition.
  case principal.kind {
    access.MemberPrincipal -> Ok(principal)
    access.OwnerPrincipal -> Error(catalogue.Conflict)
  }
}

/// Coordinates viewed page with the daemon manager’s session state and effects.
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
/// Coordinates census with the daemon manager’s session state and effects.
fn census(phase: Phase, book: Book(instance)) -> Summary {
  // census distinguishes the the selected value outcomes before continuing the transition.
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
          DomainPreparing | DomainRunning(_) | DomainClosing | DomainDrained ->
            count
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

/// Coordinates create session with the daemon manager’s session state and effects.
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
      // create_session distinguishes the the selected value outcomes before continuing the transition.
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
          // create_session distinguishes the the selected value outcomes before continuing the transition.
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

// A relayed session reserved, in one turn. A request id that already has a row
// is answered from the row, and needs no new identity. A new one is minted the
// way any creation is, and the catalogue judges the two caps and writes the
// registration, its mapping and the row in one transaction. The registry's turn
// is what orders the creates of one daemon, and the transaction is what holds
// between connections.
/// Coordinates relay now with the daemon manager’s session state and effects.
fn relay_now(
  phase: Phase,
  book: Book(instance),
  request: RelayRequest,
) -> Result(Relaying, RelayError) {
  // relay_now distinguishes the phase outcomes before continuing the transition.
  case phase {
    ShuttingDown -> Error(RelayFailed(Unavailable))
    Ready -> {
      let failed = fn(error) {
        case error {
          catalogue.Conflict -> RelayForeign
          other -> RelayFailed(Catalogue(other))
        }
      }

      // This read spares a resend a new identity and is an optimisation. The
      // check that decides is the one inside the reserving transaction.
      use found <- result.try(
        catalogue.relayed_for(
          book.catalogue,
          request.spawner,
          request.request_id,
        )
        |> result.map_error(failed),
      )

      // relay_now distinguishes the found outcomes before continuing the transition.
      case found {
        Some(row) -> relaying(book, row.session_id)
        None -> {
          let record =
            new_registration(
              request.creation,
              request.directory,
              request.generator,
            )
          use selected <- result.try(
            select_creation_domain(
              book.catalogue,
              record,
              domain.SessionOnly,
              request.configuration,
              filepath.directory_name(request.directory),
            )
            |> result.map_error(failed),
          )
          use claim <- result.try(
            domain.reserve_relayed(
              book.catalogue,
              request.spawner,
              request.request_id,
              request.limits,
              record,
              selected,
            )
            |> result.map_error(failed),
          )

          // relay_now distinguishes the claim outcomes before continuing the transition.
          case claim {
            catalogue.RelayedCapped(cap:, limit:) ->
              Error(RelayCapped(cap:, limit:))
            catalogue.RelayedFound(record: row) ->
              relaying(book, row.session_id)
            catalogue.RelayedMade(registration:, ..) ->
              Ok(Relaying(
                session_id: registration.id,
                state: registration.state,
              ))
          }
        }
      }
    }
  }
}

// What a reserved session's registration says now.
/// Coordinates relaying with the daemon manager’s session state and effects.
fn relaying(
  book: Book(instance),
  session_id: String,
) -> Result(Relaying, RelayError) {
  catalogue.get(book.catalogue, session_id)
  |> result.map(fn(record) { Relaying(session_id:, state: record.state) })
  |> result.map_error(fn(error) { RelayFailed(Catalogue(error)) })
}

// One page of a spawner's relayed sessions with the status each holds now. A
// row whose registration cannot be read fails the page, because a page that
// silently dropped it would let the spawner think the session was gone.
/// Coordinates relayed page now with the daemon manager’s session state and effects.
fn relayed_page_now(
  book: Book(instance),
  spawner: String,
  after: String,
  limit: Int,
) -> Result(List(RelayedView), Error) {
  use listings <- result.try(
    catalogue.relayed_page(book.catalogue, spawner, after:, limit:)
    |> result.map_error(Catalogue),
  )
  list.try_map(listings, fn(listing) {
    use record <- result.map(
      catalogue.get(book.catalogue, listing.record.session_id)
      |> result.map_error(Catalogue),
    )
    RelayedView(listing:, view: View(record, status(book, record)))
  })
}

// Archives a relayed session of the spawner that holds no slot. The relayed row
// is read in this turn, so a session another spawner started, or none, is
// refused as not relayed whatever its state.
/// Coordinates archive relayed now with the daemon manager’s session state and effects.
fn archive_relayed_now(
  phase: Phase,
  book: Book(instance),
  spawner: String,
  id: String,
) -> Result(View, RelayedArchiveError) {
  // archive_relayed_now distinguishes the phase outcomes before continuing the transition.
  case phase {
    ShuttingDown -> Error(ArchiveFailed(Unavailable))
    Ready -> {
      use found <- result.try(
        catalogue.relayed_of(book.catalogue, id)
        |> result.map_error(fn(error) { ArchiveFailed(Catalogue(error)) }),
      )

      // archive_relayed_now distinguishes the the selected value outcomes before continuing the transition.
      use Nil <- result.try(case found {
        Some(row) if row.spawner == spawner -> Ok(Nil)
        Some(_) | None -> Error(ArchiveNotRelayed)
      })

      // archive_relayed_now distinguishes the the selected value outcomes before continuing the transition.
      use Nil <- result.try(case dict.has_key(book.slots, id) {
        True -> Error(ArchiveBusy)
        False -> Ok(Nil)
      })

      // archive_relayed_now distinguishes the the selected value outcomes before continuing the transition.
      use Nil <- result.try(case catalogue.custody(book.catalogue, id) {
        Ok(catalogue.Moving(op:, to:)) ->
          Error(ArchiveFailed(SessionMoving(op:, to:)))
        Ok(catalogue.Moved(to:, ..)) -> Error(ArchiveFailed(SessionMoved(to:)))
        Ok(catalogue.Resident) | Ok(catalogue.Imported(..)) -> Ok(Nil)
        Error(error) -> Error(ArchiveFailed(Catalogue(error)))
      })

      use record <- result.map(
        catalogue.set_visibility(book.catalogue, id, catalogue.Archived)
        |> result.map_error(fn(error) { ArchiveFailed(Catalogue(error)) }),
      )
      View(record, status(book, record))
    }
  }
}

// The pair's session, admitted. An existing record is answered whatever the
// count is, since the cap bounds how many sessions a spawner opens and not how
// often it returns to one. A pair with none is created and recorded in this
// turn. A creation that crashes between the registration and the record is
// retried under the same request key, which finds the registration again, so
// the record is the only thing the retry has left to write.
/// Coordinates delegate now with the daemon manager’s session state and effects.
fn delegate_now(
  phase: Phase,
  book: Book(instance),
  request: DelegateRequest,
) -> #(Book(instance), Result(Delegated, DelegateError)) {
  case phase {
    ShuttingDown -> #(book, Error(DelegateFailed(Unavailable)))
    Ready ->
      case
        catalogue.delegate_for(
          book.catalogue,
          request.spawner,
          request.parent_session,
        )
      {
        Error(error) -> #(book, Error(DelegateFailed(Catalogue(error))))
        Ok(Some(found)) ->
          case found.state {
            catalogue.Open ->
              returning_delegate(phase, book, request, found.session_id)
            catalogue.Releasing | catalogue.Released -> #(
              book,
              Error(DelegateReleased),
            )
          }
        Ok(None) -> first_delegate(phase, book, request)
      }
  }
}

// A spawn claimed against the spawner's rolling day, in one turn: the last 24
// buckets are read, the caps judged, and the spawn counted. The read is one
// bounded catalogue query on the connection this actor already owns, and the
// turn touches nothing else, so it opens no store and calls no session. Counting
// in the turn is what makes two spawns see each other, because the registry
// handles one message at a time.
/// Coordinates claim now with the daemon manager’s session state and effects.
fn claim_now(
  book: Book(instance),
  spawner: String,
  token_budget: Option(Int),
  max_per_day: Option(Int),
  now_ms: Int,
) -> Result(Nil, DelegateError) {
  use spent <- result.try(
    catalogue.spawner_spend(book.catalogue, spawner, now_ms:)
    |> result.map_error(fn(error) { DelegateFailed(Catalogue(error)) }),
  )

  // claim_now distinguishes the at_cap(spent.tokens, token_budget), at_cap(spent.spawns, max_per_day) outcomes before continuing the transition.
  case at_cap(spent.tokens, token_budget), at_cap(spent.spawns, max_per_day) {
    Some(limit), _ -> Error(DelegateDayCap(cap: DayTokens, limit:))
    None, Some(limit) -> Error(DelegateDayCap(cap: DaySpawns, limit:))
    None, None ->
      catalogue.add_spawner_spend(
        book.catalogue,
        spawner,
        now_ms:,
        tokens: 0,
        spawns: 1,
      )
      |> result.map_error(fn(error) { DelegateFailed(Catalogue(error)) })
  }
}

// The cap's value when `used` has reached it, and nothing when it has not or
// when there is no cap.
/// Coordinates at cap with the daemon manager’s session state and effects.
fn at_cap(used: Int, cap: Option(Int)) -> Option(Int) {
  option.then(cap, fn(limit) {
    case used >= limit {
      True -> Some(limit)
      False -> None
    }
  })
}

// A pair that has a session: the contact time moves, and the session is
// admitted if it is not resident.
/// Coordinates returning delegate with the daemon manager’s session state and effects.
fn returning_delegate(
  phase: Phase,
  book: Book(instance),
  request: DelegateRequest,
  session_id: String,
) -> #(Book(instance), Result(Delegated, DelegateError)) {
  // returning_delegate distinguishes the claim_delegate(book, request, session_id) outcomes before continuing the transition.
  case claim_delegate(book, request, session_id) {
    Error(error) -> #(book, Error(error))
    Ok(Nil) -> {
      // A retained slot carries a more precise answer than admission's
      // Unavailable: Closing may retire, while Blocked has lost that proof.
      // The delegate resolver needs that distinction to decide whether its

      // sender should retry. Neither descriptor grants a replacement slot.
      let #(book, admitted) = case dict.get(book.slots, session_id) {
        Ok(Slot(phase: Closing, operation:, ..)) -> #(
          book,
          Ok(Stopping(operation)),
        )
        Ok(Slot(phase: Blocked(reason), ..)) -> #(
          book,
          Ok(RecoveryBlocked(reason)),
        )
        Ok(_) | Error(Nil) -> admit(phase, book, session_id)
      }

      #(book, delegated(session_id, admitted))
    }
  }
}

// A pair that has none. The room is checked before anything is created, so a
// spawner past its cap leaves no registration behind, and the record is written
// after, once the registration exists for its foreign key.
/// Coordinates first delegate with the daemon manager’s session state and effects.
fn first_delegate(
  phase: Phase,
  book: Book(instance),
  request: DelegateRequest,
) -> #(Book(instance), Result(Delegated, DelegateError)) {
  // first_delegate distinguishes the delegate_room(book, request) outcomes before continuing the transition.
  case delegate_room(book, request) {
    Error(error) -> #(book, Error(error))
    Ok(Nil) -> {
      let #(book, created) =
        create_session(
          phase,
          book,
          request.creation,
          request.directory,
          request.generator,
          domain.SessionOnly,
          request.configuration,
        )

      // first_delegate distinguishes the created outcomes before continuing the transition.
      case created {
        Error(error) -> #(book, Error(DelegateFailed(error)))
        Ok(View(registration:, status:)) ->
          case claim_delegate(book, request, registration.id) {
            Error(error) -> #(book, Error(error))
            Ok(Nil) -> #(
              book,
              Ok(Delegated(session_id: registration.id, status:)),
            )
          }
      }
    }
  }
}

/// Coordinates delegate room with the daemon manager’s session state and effects.
fn delegate_room(
  book: Book(instance),
  request: DelegateRequest,
) -> Result(Nil, DelegateError) {
  use held <- result.try(
    catalogue.delegates_held(book.catalogue, request.spawner)
    |> result.map_error(fn(error) { DelegateFailed(Catalogue(error)) }),
  )

  // delegate_room distinguishes the held >= request.limit outcomes before continuing the transition.
  case held >= request.limit {
    True -> Error(DelegateAtLimit(held:))
    False -> Ok(Nil)
  }
}

// The catalogue's record of the pair, written or touched. Its own count check
// is the second line behind `delegate_room`, in one transaction with the insert.
/// Coordinates claim delegate with the daemon manager’s session state and effects.
fn claim_delegate(
  book: Book(instance),
  request: DelegateRequest,
  session_id: String,
) -> Result(Nil, DelegateError) {
  use claim <- result.try(
    catalogue.claim_delegate(
      book.catalogue,
      request.spawner,
      request.parent_session,
      session_id,
      limit: request.limit,
      now_ms: request.now_ms,
    )
    |> result.map_error(fn(error) { DelegateFailed(Catalogue(error)) }),
  )

  // claim_delegate distinguishes the claim outcomes before continuing the transition.
  case claim {
    catalogue.Claimed(_) -> Ok(Nil)
    catalogue.AtLimit(held:) -> Error(DelegateAtLimit(held:))
  }
}

/// Coordinates delegated with the daemon manager’s session state and effects.
fn delegated(
  session_id: String,
  admitted: Result(Status, Error),
) -> Result(Delegated, DelegateError) {
  case admitted {
    Ok(status) -> Ok(Delegated(session_id:, status:))
    Error(error) -> Error(DelegateFailed(error))
  }
}

// The registration a creation would make: a fresh identity, the path its file
// would have, and the creation's metadata, in the `Reserved` state.
/// Coordinates new registration with the daemon manager’s session state and effects.
fn new_registration(
  request: Creation,
  directory: String,
  generator: ids.Generator,
) -> catalogue.Registration {
  let #(id, _) = ids.mint_session(generator)
  let text = ids.session_id_to_string(id)
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
    model: request.model,
    executor: request.executor,
    pool: request.pool,
    subtitle: option.None,
  )
}

// Only a missing key permits allocation. Corrupt or unavailable metadata must
// not produce a second file under a new identity, even if the caller retries.
/// Coordinates reserve creation with the daemon manager’s session state and effects.
fn reserve_creation(
  store: catalogue.Catalogue,
  request: Creation,
  directory: String,
  generator: ids.Generator,
  scope: domain.Scope,
  configuration: String,
) -> Result(catalogue.Registration, catalogue.Error) {
  // reserve_creation distinguishes the catalogue.by_request_key(store, request.request_key) outcomes before continuing the transition.
  case catalogue.by_request_key(store, request.request_key) {
    Ok(record) ->
      case
        record.workspace == request.workspace
        && record.name == request.name
        && record.configuration == request.configuration
        && record.profile == request.profile
        && record.model == request.model
        && record.pool == request.pool
        && named_same_executor(record, request)
      {
        True -> {
          use selected <- result.try(domain.for_session(store, record.id))

          // reserve_creation distinguishes the selected.scope == scope outcomes before continuing the transition.
          case selected.scope == scope {
            True -> Ok(record)
            False -> Error(catalogue.Conflict)
          }
        }
        False -> Error(catalogue.Conflict)
      }
    Error(catalogue.Missing) -> {
      let record = new_registration(request, directory, generator)
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

// Whether a stored registration names the executor the request does. A request
// in a pool names none, and the stored one holds whichever executor the pool's
// first attach chose, so for a pooled request the executor is not part of what
// a retry has to repeat.
fn named_same_executor(
  record: catalogue.Registration,
  request: Creation,
) -> Bool {
  request.pool != "" || record.executor == request.executor
}

/// Coordinates select creation domain with the daemon manager’s session state and effects.
fn select_creation_domain(
  store,
  record: catalogue.Registration,
  scope,
  configuration,
  state_root,
) {
  // select_creation_domain distinguishes the the selected value outcomes before continuing the transition.
  let configuration = case record.configuration {
    "" -> configuration
    explicit -> explicit
  }

  // select_creation_domain distinguishes the domain.get(store, domain.key(scope, record.workspace, record.id)) outcomes before continuing the transition.
  case domain.get(store, domain.key(scope, record.workspace, record.id)) {
    Ok(existing) -> Ok(existing)
    Error(catalogue.Missing) ->
      Ok(domain_record(record, scope, configuration, state_root))
    Error(error) -> Error(error)
  }
}

/// The session-only domain a session on an executor is given: its own memory
/// and index files below `state_root`, beside no other session's. A session that
/// another orchestrator handed over gets the same mapping a session created here
/// does, so the registry never has to ask which of the two it is looking at.
///
/// ## Examples
///
/// ```gleam
/// // manager.session_only_domain(registration, "", "/state")
/// ```
@internal
pub fn session_only_domain(
  record: catalogue.Registration,
  configuration: String,
  state_root: String,
) -> domain.Domain {
  domain_record(record, domain.SessionOnly, configuration, state_root)
}

/// Coordinates domain record with the daemon manager’s session state and effects.
fn domain_record(
  record: catalogue.Registration,
  scope,
  configuration,
  state_root,
) {
  // domain_record distinguishes the the selected value outcomes before continuing the transition.
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

/// Coordinates admit with the daemon manager’s session state and effects.
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

/// Coordinates new slot with the daemon manager’s session state and effects.
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

/// Coordinates prepare slot with the daemon manager’s session state and effects.
fn prepare_slot(
  book: Book(instance),
  record: catalogue.Registration,
) -> #(Book(instance), Result(Status, Error)) {
  let selected = {
    use visibility <- result.try(
      catalogue.visibility(book.catalogue, record.id)
      |> result.map_error(Catalogue),
    )

    // prepare_slot distinguishes the the selected value outcomes before continuing the transition.
    use Nil <- result.try(case visibility {
      catalogue.Active -> Ok(Nil)
      catalogue.Archived -> Error(SessionArchived)
    })

    // A session that is being handed to another orchestrator, or was, is not
    // this catalogue's to run. The row is read here, in the turn that reserves
    // the slot, so a move that began a turn earlier is always seen.
    use custody <- result.try(
      catalogue.custody(book.catalogue, record.id)
      |> result.map_error(Catalogue),
    )

    // prepare_slot distinguishes the the selected value outcomes before continuing the transition.
    use Nil <- result.try(case custody {
      catalogue.Moving(op:, to:) -> Error(SessionMoving(op:, to:))
      catalogue.Moved(to:, ..) -> Error(SessionMoved(to:))
      catalogue.Resident | catalogue.Imported(..) -> Ok(Nil)
    })

    // A session whose deletion through the directory has begun is not served,
    // read in this turn for the same reason as the custody row above.
    use marked <- result.try(
      catalogue.deletion(book.catalogue, record.id)
      |> result.map_error(Catalogue),
    )

    // prepare_slot distinguishes the the selected value outcomes before continuing the transition.
    use Nil <- result.try(case marked {
      catalogue.Deleting -> Error(SessionDeleting)
      catalogue.NotDeleting -> Ok(Nil)
    })

    domain.for_session(book.catalogue, record.id) |> result.map_error(Catalogue)
  }

  // prepare_slot distinguishes the selected outcomes before continuing the transition.
  case selected {
    Error(error) -> #(book, Error(error))
    Ok(selected) -> {
      let #(book, admitted) = ensure_domain(book, selected)

      // prepare_slot distinguishes the admitted outcomes before continuing the transition.
      case admitted {
        Error(error) -> #(book, Error(error))
        Ok(_operation) -> prepare_domain_slot(book, record, selected)
      }
    }
  }
}

// A fresh attempt supersedes whatever the last one failed at, durably as well
// as in the memo, so a reservation being retried is listed as starting again
// and not as a failure that no longer describes it.
//
// It runs only once the attempt has a host. Every earlier refusal (a blocked or
// drained domain, a failed preparation) creates no slot, so nothing would ever
// record a new failure, and clearing first would lose the reason of the last
// real one. A clear that fails leaves a stale reason that the next failure
// replaces or the file's confirmation clears, so it does not refuse the open.
fn clear_kept_failure(store: catalogue.Catalogue, id: String) -> Nil {
  case catalogue.clear_start_failure(store, id) {
    Ok(Nil) | Error(_) -> Nil
  }
}

// Capturing immutable metadata before preparation keeps catalogue access inside
// the registry and prevents the builder from choosing paths after admission.
/// Coordinates prepare domain slot with the daemon manager’s session state and effects.
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

  // prepare_domain_slot distinguishes the the selected value outcomes before continuing the transition.
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
      clear_kept_failure(book.catalogue, record.id)
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

// Admission against a retained domain. A domain that is preparing or running
// is joined. One that is closing is joined too, as a parked session that waits
// for the domain's normal exit and is then admitted against a replacement; the
// cancellation already ordered is not withdrawable, so its services are never
// handed to a new session. One that drained, failed or is blocked refuses.
/// Coordinates ensure domain with the daemon manager’s session state and effects.
fn ensure_domain(book: Book(instance), selected: domain.Domain) {
  case dict.get(book.domains, selected.id) {
    Ok(DomainSlot(phase: DomainPreparing, operation:, ..))
    | Ok(DomainSlot(phase: DomainRunning(_), operation:, ..))
    | Ok(DomainSlot(phase: DomainClosing, operation:, ..)) -> #(
      book,
      Ok(operation),
    )
    Ok(DomainSlot(phase: DomainDrained, ..))
    | Ok(DomainSlot(phase: DomainWaitingFailure(_), ..))
    | Ok(DomainSlot(phase: DomainBlocked(_), ..)) -> #(book, Error(Unavailable))
    Error(Nil) -> prepare_shared_domain(book, selected)
  }
}

// The dependent count is the answer to "may this domain be fenced", and it is
// maintained at the two places a session slot enters or leaves the book rather
// than folded out of the slots on every message.
/// Coordinates depend with the daemon manager’s session state and effects.
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

/// Coordinates prepare shared domain with the daemon manager’s session state and effects.
fn prepare_shared_domain(book: Book(instance), selected: domain.Domain) {
  // prepare_shared_domain distinguishes the dict.size(book.domains) >= book.limit outcomes before continuing the transition.
  case dict.size(book.domains) >= book.limit {
    True -> #(book, Error(Capacity))
    False -> {
      let results = process.new_subject()
      let faults = process.new_subject()
      let failures = process.new_subject()
      let operation = book.epoch <> ":domain:" <> int.to_string(book.next)

      // Enumeration runs on whichever process resolves sources, the domain
      // builder and later each index refresh, never in the registry's own
      // handler. The registry answers one bounded page per turn, so a domain
      // near the source cap costs a few short turns instead of one turn that
      // parks every queued authorization behind five hundred catalogue reads.
      let commands = book.commands
      let domain_id = selected.id
      let sources = fn() { collect_sources(commands, domain_id, "", [], 0) }

      // Domain hosts also keep their builder after publication. Retain the
      // callback alone, not the registry and its resident instances.
      let domain_build = book.assembly.domain_build

      // prepare_shared_domain distinguishes the the selected value outcomes before continuing the transition.
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
/// Coordinates services for builder with the daemon manager’s session state and effects.
fn services_for_builder(book: Book(instance), id: String, operation: String) {
  use slot <- result.try(
    dict.get(book.slots, id)
    |> result.map_error(fn(_) { "session admission is no longer retained" }),
  )

  // services_for_builder distinguishes the slot.phase, slot.operation == operation outcomes before continuing the transition.
  case slot.phase, slot.operation == operation {
    Building, True -> {
      use domain <- result.try(
        dict.get(book.domains, slot.domain_id)
        |> result.map_error(fn(_) { "domain admission is no longer retained" }),
      )

      // services_for_builder distinguishes the domain.phase outcomes before continuing the transition.
      case domain.phase {
        DomainRunning(services) -> Ok(services)
        DomainPreparing
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
/// Coordinates activate domain slots with the daemon manager’s session state and effects.
fn activate_domain_slots(book: Book(instance), id: String) {
  // activate_domain_slots distinguishes the dict.get(book.domains, id) outcomes before continuing the transition.
  case dict.get(book.domains, id) {
    Ok(DomainSlot(phase: DomainRunning(_), ..)) -> {
      let slots =
        dict.map_values(book.slots, fn(_, slot) {
          // activate_domain_slots distinguishes the slot.domain_id == id, slot.phase outcomes before continuing the transition.
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

/// Coordinates domain opened with the daemon manager’s session state and effects.
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

/// Coordinates domain failed with the daemon manager’s session state and effects.
fn domain_failed(book: Book(instance), id, operation, reason) {
  // domain_failed distinguishes the dict.get(book.domains, id) outcomes before continuing the transition.
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

/// Coordinates domain retired with the daemon manager’s session state and effects.
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
/// Coordinates replace drained domain with the daemon manager’s session state and effects.
fn replace_drained_domain(book: Book(instance), id: String, slot: DomainSlot) {
  let waiting =
    list.any(dict.values(book.slots), fn(session) {
      session.domain_id == id && session.phase == WaitingForDomain
    })

  // replace_drained_domain distinguishes the waiting outcomes before continuing the transition.
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

      // replace_drained_domain distinguishes the answer outcomes before continuing the transition.
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

// A slot that drained because its session was released is the moment the
// session can be deleted. A failure leaves the row released for the sweep.
/// Coordinates finish drained release while keeping the session lifecycle transition explicit.
fn finish_drained_release(book: Book(instance), id: String) -> Book(instance) {
  // finish_drained_release distinguishes the dict.get(book.releasing, id) outcomes before continuing the transition.
  case dict.get(book.releasing, id) {
    Error(Nil) -> book
    Ok(sessions) -> {
      let _deleted = finish_release(book, id, sessions)
      Book(..book, releasing: dict.delete(book.releasing, id))
    }
  }
}

// A domain no session depends on is cancelled at once. Whether the daemon is
// still accepting makes no difference: the cancellation is not withdrawable,
// so a session that opens afterwards waits for the drain and is admitted
// against a replacement.
/// Coordinates close unused domains with the daemon manager’s session state and effects.
fn close_unused_domains(book: Book(instance)) {
  dict.fold(book.domains, book, fn(book, id, slot) {
    case slot.dependents > 0 {
      True -> book
      False -> close_unused_domain(book, id, slot)
    }
  })
}

/// Coordinates close unused domain with the daemon manager’s session state and effects.
fn close_unused_domain(book: Book(instance), id, slot: DomainSlot) {
  // close_unused_domain distinguishes the slot.phase outcomes before continuing the transition.
  case slot.phase {
    DomainRunning(_) | DomainPreparing -> {
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
    DomainClosing | DomainBlocked(_) -> book
  }
}

// `storage/domain.source_records` answers at most this many rows per call, and
// the registry validates at most that many joined registrations in one turn.
const source_page = 100

// The bounded total of conversation sessions a domain may contribute to
// recall: 511, leaving one slot in `shared_history`'s 512-source ceiling for
// the domain's `loom-memory.db` store (`serve.with_memory_source`). An
// oversized domain is refused rather than silently truncated.
const source_limit = 511

/// Walks bounded source pages in the caller while the registry stays responsive.
fn collect_sources(
  commands: Subject(Message(instance)),
  id: String,
  after: String,
  accumulated: List(shared_history.Source),
  count: Int,
) -> Result(List(shared_history.Source), String) {
  use sources <- result.try(
    call.try_call(commands, waiting: 5000, sending: DomainSources(id, after, _))
    |> result.unwrap(Error("domain source registry is unavailable")),
  )
  let total = count + list.length(sources)
  use <- bool.guard(
    when: total > source_limit,
    return: Error("domain exceeds the bounded source limit"),
  )

  // The identity and its path came from the same fresh catalogue read. A
  // full page advances by its last identity; a short page finishes the walk.
  let accumulated = list.append(accumulated, sources)

  // A short or empty page finishes; a full page continues after its last ID.
  case list.drop(sources, source_page - 1), list.last(sources) {
    [], _ | _, Error(Nil) -> Ok(accumulated)
    [_, ..], Ok(last) ->
      collect_sources(
        commands,
        id,
        ids.session_id_to_string(last.session),
        accumulated,
        total,
      )
  }
}

/// Projects one validated source page before the catalogue owner's turn ends.
fn source_paths(
  store: catalogue.Catalogue,
  id: String,
  after: String,
) -> Result(List(shared_history.Source), String) {
  use records <- result.try(
    domain.source_records(store, id, after:) |> result.map_error(string.inspect),
  )
  list.try_map(records, fn(record) {
    use session <- result.map(
      ids.parse_session_id(record.id)
      |> result.replace_error("invalid domain source identity"),
    )
    shared_history.Source(session, record.path)
  })
}

// The three checks are ordered widest fence inwards. A caller addressing a
// previous daemon has nothing here to resolve, and an attachment whose
// incarnation is gone must not have its credential read at all: the answer is
// already no, and reading it would make a stale socket a way to probe
// membership.
/// Coordinates frame authorized with the daemon manager’s session state and effects.
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
    // frame_authorized distinguishes the the selected value outcomes before continuing the transition.
    use Nil <- result.try(case epoch == book.epoch {
      True -> Ok(Nil)
      False -> Error(StaleEpoch)
    })

    // frame_authorized distinguishes the the selected value outcomes before continuing the transition.
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
/// Coordinates resolved authority with the daemon manager’s session state and effects.
fn resolved_authority(
  book: Book(instance),
  id: String,
  digest: access.Digest,
) -> #(
  Book(instance),
  Result(#(access.Principal, access.Authority), FrameRefusal),
) {
  let key = #(digest, id)

  // resolved_authority distinguishes the dict.get(book.authority, key) outcomes before continuing the transition.
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

/// Coordinates resolve authority with the daemon manager’s session state and effects.
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

/// Coordinates stop slot with the daemon manager’s session state and effects.
fn stop_slot(book: Book(instance), id: String) -> Book(instance) {
  // stop_slot distinguishes the dict.get(book.slots, id) outcomes before continuing the transition.
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

/// Coordinates opened with the daemon manager’s session state and effects.
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
/// Coordinates remember failure with the daemon manager’s session state and effects.
fn remember_failure(
  book: Book(instance),
  id: String,
  operation: String,
  reason: String,
) -> Book(instance) {
  keep_start_failure(book.catalogue, id, reason)

  // remember_failure distinguishes the the selected value outcomes before continuing the transition.
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

// Files the failure against the reservation, so it outlives this process
// (protocol-change/093). The in-memory memo above answers the operator who is
// polling this exact operation, and this row answers everyone after a restart.
//
// The text is cleaned here because the catalogue owns rows and not display
// text: terminal sequences and invisible codepoints are replaced first, then
// the line is collapsed and cut to the stored bound. Cleaning first matters
// because replacing a tab or a control can lengthen the text.
//
// A session that is already `Saved` has no creation to describe and the
// catalogue refuses it, and a write that fails loses only the diagnosis. Both
// leave the reservation as it was, so neither is worth failing the cleanup
// that called this.
/// Coordinates keep start failure with the daemon manager’s session state and effects.
fn keep_start_failure(
  store: catalogue.Catalogue,
  id: String,
  reason: String,
) -> Nil {
  // keep_start_failure distinguishes the the selected value outcomes before continuing the transition.
  let line = case
    reason
    |> text_hygiene.single_line
    |> glance.clip(catalogue.start_failure_limit)
  {
    "" -> "the start failed without saying why"
    cleaned -> cleaned
  }

  // keep_start_failure distinguishes the the selected value outcomes before continuing the transition.
  case
    catalogue.record_start_failure(store, id, line, at: ffi_os.system_time_ms())
  {
    Ok(Nil) | Error(_) -> Nil
  }
}

// An assembly fault means Weft's ordered cleanup has already started, so the
// slot is closing rather than blocked: its witness will exit normally and
// `retired` will release the reservation. Answering `Blocked` here would tell
// an operator the daemon can never be replaced, and would make `stop_slot` a
// no-op on a slot that is merely mid-fault when shutdown arrives. The reason
// is deliberately not retained: `Closing` is a claim about ordering, and the
// reservation it holds is released by drain rather than by diagnosis.
/// Coordinates faulted with the daemon manager’s session state and effects.
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
/// Coordinates failed with the daemon manager’s session state and effects.
fn failed(
  book: Book(instance),
  id: String,
  operation: String,
  reason: String,
) -> Book(instance) {
  // failed distinguishes the dict.get(book.slots, id) outcomes before continuing the transition.
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
/// Coordinates retired with the daemon manager’s session state and effects.
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
          finish_drained_release(book, id)
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
/// Coordinates status with the daemon manager’s session state and effects.
fn status(book: Book(instance), record: catalogue.Registration) -> Status {
  case dict.get(book.slots, record.id) {
    Error(Nil) ->
      case record.state {
        catalogue.Reserved -> reserved_status(book, record)
        catalogue.Saved -> Saved
      }

    Ok(Slot(phase: WaitingForDomain, operation:, ..))
    | Ok(Slot(phase: Building, operation:, ..)) -> Opening(operation)
    Ok(Slot(phase: Running(_), operation:, ..)) -> Resident(operation)
    Ok(Slot(phase: Closing, operation:, ..)) -> Stopping(operation)
    Ok(Slot(phase: Blocked(reason), ..)) -> RecoveryBlocked(reason)
  }
}

// A reservation with no slot is a failed start when the catalogue kept a
// reason for it and an ordinary reservation otherwise. A read that fails shows
// the plain reservation: the reason is a display aid layered over the
// registration, and `Reserved` is already the conservative answer.
/// Coordinates reserved status with the daemon manager’s session state and effects.
fn reserved_status(
  book: Book(instance),
  record: catalogue.Registration,
) -> Status {
  case catalogue.start_failure(book.catalogue, record.id) {
    Ok(Some(catalogue.StartFailure(reason:, at:))) -> FailedStart(reason:, at:)
    Ok(None) | Error(_) -> Reserved
  }
}

/// Coordinates step with the daemon manager’s session state and effects.
fn step(
  phase: Phase,
  book: Book(instance),
) -> sm.Step(Phase, Book(instance), Message(instance), sm.Postponable) {
  let book = close_unused_domains(book)

  // step distinguishes the phase, dict.size(book.slots), dict.size(book.domains) outcomes before continuing the transition.
  case phase, dict.size(book.slots), dict.size(book.domains) {
    ShuttingDown, 0, 0 -> sm.stop()
    _, _, _ -> sm.transition(phase, book) |> sm.with_selector(selector(book))
  }
}

// Rebuild the selector from the bounded live slots. Completed incarnations do
// not leave monitor handlers or reply subjects accumulating across reopen cycles.
/// Coordinates selector with the daemon manager’s session state and effects.
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

//// Executor LSP custody precedes effects and preserves original uncertainty.
////
//// One private weft actor owns the connection, including poison and close.
//// Concurrent callers and independent opens serialize under BEGIN IMMEDIATE.
//// First capture retains its original nonce, clock era and E0. Only the first
//// timed transition COMMIT issues a finite claim; recovery fences unfinished
//// originals regardless of whether a host repeats the clock era or tick.
////
//// Permanent assembly uses `park_fresh` under its own linked parent, retains
//// the resource-free original ACK, then calls `initialise_fresh`. Acquired owns
//// the actual connection before shared setup runs in the next actor turn.
//// A queued parent exit does not preempt that already admitted bounded turn.
//// Temporary `recover_owned` self-adopts before ACK or SQL and has no Clock,
//// incarnation, Store projector or admission door. History preserves original
//// era, nonce, E0 and deadlines while sharing the existing canonical reducers.
//// Owned release requires explicit close ACK and the same original normal DOWN;
//// the managed caller separately joins its Outcome, AllDelivered and scope DOWN.
////
//// Lease, finite and command rows share a permanent reservation ledger. Exact
//// receipt does not free capacity or a lease slot. Only original physical
//// retirement verification followed by exact Retired COMMIT clears that slot.
//// Verification callbacks run in trusted local assembly outside the SQL turn;
//// the transaction compares the original readback again. Digests identify
//// evidence and never prove that native resources or managed children joined.
////
//// DELETE rollback journaling, 4096-byte pages, a 131072-page ceiling and
//// MEMORY temporary storage are checked before each transaction. The built-in
//// sqlight SQLite VFS is required; this API accepts no extension, VFS, ATTACH,
//// VACUUM or externally retained reader transaction. Logical quota is neither
//// VM RSS nor physical file size. Every reservation remains permanently charged,
//// even after exact receipt; this milestone has no payload reclamation. Complete
//// finite capacity therefore permits fewer than sixty maximum-size originals
//// under the byte ceiling, before other lease or command reservations.
//// A rollback record adds eight bytes per page;
//// sector-aligned transaction headers add linked-engine/VFS overhead separately.
////
//// ## Flow
////
//// `fresh` and `recover` enter `open`. `reserve_lease`, `capture_finite` and
//// `reserve_command` charge `insert` before effects. `accept_finite` commits the
//// original timing once; `start_command` commits its sole claim. `retain_offer`,
//// `associate`, `retain_terminal` and `retain_reusable` preserve exact history.
//// `finish` and `acknowledge` retain canonical result and exact receipt.
//// `close_lease`, `retire_lease`, `fence_command` and `seal` retain fences and original joins.
//// `lease_disposition`, `finite_disposition`, `command_disposition`,
//// `command_evidence` and `result_receipt` project checked history.
//// `inspect_lease`, `inspect_finite`, `inspect_command` and `inventory` enter
//// guarded `lookup` and `read_row`; `validate_row` checks complete canonical parent equality.
//// `exchange`, `handle`, `transact` and `complete` own actor replies and COMMIT.
//// `fresh_input`, `park_fresh`, `initialise_fresh` and `live_store` retain one
//// original live endpoint. `recovery_input` and `recover_owned` install a closed
//// historical door. `inspect_lease_owned`, `inspect_finite_owned`,
//// `inspect_command_owned` and `acknowledge_exact_owned` share `read_lease`,
//// `read_finite`, `read_command` and `write_exact_receipt`. `acquire_input`,
//// `handle_setup` and `setup` install Acquired before SQL. `handle_release`,
//// `release_subject`, `close_connection` and `shutdown` retain exact close proof.
//// `clear_probe` spends a synthetic refusal while retaining its original observer.

import core/bounded_msgpack
import core/generation as g
import core/ids
import core/lsp_command as id
import core/msgpack as mp
import core/workspace
import executor/lsp_custody_schema
import executor/remote/lsp_wire as wire
import executor/sql
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import parrot/dev
import simplifile
import sqlight
import weft
import weft/actor

/// Maximum permanent identities across all three families.
pub const max_rows = 4096

/// Maximum permanent logical reservations across all three families.
pub const max_bytes = 268_435_456

/// Full finite body capacity, including observation's separate enclosing shell.
pub const result_capacity = 4_464_896

/// Full retained Search projection capacity, independent of raw collector bytes.
pub const search_capacity = 1_644_800

/// Immutable configured ceilings, reduced from the approved maxima.
pub opaque type Limits {
  Limits(rows: Int, bytes: Int)
}

/// Full exact generation association; historical lookup never chooses latest.
pub opaque type Binding {
  Binding(key: g.GenerationKey, enrollment: g.Digest)
}

/// Trusted original service clock, installed once and never supplied by a peer.
pub type Clock {
  Clock(
    /// Host/VM clock incarnation identity.
    era: id.ClockEra,
    /// Original local monotonic milliseconds; negative values are valid.
    now: fn() -> Int,
    /// Original cryptographic nonce source, called only for first capture.
    nonce: fn() -> BitArray,
  )
}

/// Original serialized connection endpoint; no replacement lookup exists.
pub opaque type Store {
  /// Construction is restricted to checked original custody at this boundary.
  Store(
    /// The exact original private connection owner, with no replacement lookup.
    subject: process.Subject(Message),
    /// The original complete generation and enrollment association.
    binding: Binding,
    /// The already retained original DAL-use UUID.
    incarnation: ids.EntryId,
  )
}

/// Immutable originals selected by permanent full-host assembly, before SQL.
@internal
pub opaque type FreshInput {
  FreshInput(
    /// Original absolute selected database path.
    path: String,
    /// Complete generation and enrollment association.
    binding: Binding,
    /// Original semantic contract commitment.
    contract: g.Digest,
    /// Original DAL-use incarnation, never reconstructed from history.
    incarnation: ids.EntryId,
    /// Immutable reduced permanent ceilings.
    limits: Limits,
    /// Actual original trusted clock construction.
    clock: Clock,
    /// Exact enrolled profile order and roots.
    profiles: id.EnrolledProfiles,
  )
}

/// Resource-free acknowledged writer directly linked to its permanent parent.
@internal
pub opaque type ParkedFresh {
  ParkedFresh(
    /// Original private endpoint retained before initialization.
    subject: process.Subject(Message),
    /// Original acknowledged writer PID.
    pid: process.Pid,
  )
}

/// Original live endpoint returned once, after original setup COMMIT.
@internal
pub opaque type LiveStore {
  LiveStore(
    /// Same original Store used by existing admission and claim checks.
    store: Store,
  )
}

/// Historical selection contains no live clock or incarnation authority.
@internal
pub opaque type RecoveryInput {
  RecoveryInput(
    /// Original absolute selected database path.
    path: String,
    /// Complete historical generation and enrollment association.
    binding: Binding,
    /// Original semantic contract commitment.
    contract: g.Digest,
    /// Immutable reduced permanent ceilings.
    limits: Limits,
    /// Exact enrolled profile order and roots.
    profiles: id.EnrolledProfiles,
  )
}

/// Adopted original history writer exposes only checked query and exact receipt.
@internal
pub opaque type OwnedRecovery {
  OwnedRecovery(
    /// Original private closed history message door.
    subject: process.Subject(Message),
    /// Original acknowledged adopted writer PID.
    pid: process.Pid,
    /// Retained input binding, never selected anew by a history query.
    binding: Binding,
  )
}

/// Closed finite observations for deterministic original custody controls.
@internal
pub type Checkpoint {

  /// No resource exists and the original ledger has not adopted this writer.
  BeforeAdopt

  /// Original ownership is installed before the resource-free startup ACK.
  BeforeAck

  /// Actual connection is retained in Acquired before shared SQL setup.
  AfterAcquire

  /// Original setup COMMIT succeeded before the readiness reply.
  AfterCommitBeforeReady

  /// Original connection is retained before an explicit close attempt.
  BeforeCloseAck

  /// Successful explicit close ACK precedes original normal DOWN.
  AfterCloseAckBeforeExit
}

/// A checkpoint changes observation only, except its labelled synthetic refusal.
@internal
pub type Permit {

  /// Continue the original bounded operation and reply.
  Proceed

  /// Retain the actual result but deliberately lose its reply.
  SuppressReply

  /// Refuse one explicit close without claiming an actual SQLite close fault.
  RefuseClose
}

/// A closed probe never receives a connection or replacement owner.
@internal
pub type Probe {

  /// Production construction has no checkpoint or callback.
  Unobserved

  /// One selected finite ordering point reports the actual original.
  Observed(
    /// Selected closed ordering point.
    selected: Checkpoint,
    /// Exact original observations and successful or failed actual close.
    observations: process.Subject(OwnershipEvent),
  )
}

/// Exact writer identity and close evidence used only by custody controls.
@internal
pub type OwnershipEvent {

  /// One gate retains the same original writer and its one permit subject.
  CheckpointReached(
    /// Closed selected ordering point.
    stage: Checkpoint,
    /// Actual original writer PID.
    owner: process.Pid,
    /// One finite gate, never SQL or claim authority.
    permit: process.Subject(Permit),
  )

  /// The original writer attempted actual SQL close, including shutdown cleanup.
  ConnectionClosed(
    /// Actual original writer PID.
    owner: process.Pid,
    /// Actual sqlight close outcome, never synthetic RefuseClose.
    outcome: Result(Nil, Error),
  )
}

/// Closed slot phases; Uncertain retains every original cleanup obligation.
pub type LeasePhase {

  /// The exact original occupies its slot before offer or native work.
  Reserved

  /// The immutable server offer is retained without owner clearance.
  Offered

  /// The owner-returned exact native association is retained.
  OwnerAssociated

  /// One original server startup claim committed before its effect.
  Starting

  /// The original claim installed the actual live service.
  Serving

  /// Admission is fenced while original physical cleanup proceeds.
  Closing

  /// Verified original retirement committed and released this slot pointer.
  Retired

  /// Original startup or cleanup custody remains unavailable and charged.
  UncertainLease
}

/// Finite historical phases carry no execution permission.
pub type FinitePhase {

  /// The original nonce, era and E0 are retained without a claim.
  Captured

  /// Original timed admission is retained without renewed authority.
  Accepted

  /// The sole original finite claim may have crossed an effect boundary.
  Started

  /// The original unspent capture was cancelled before any claim.
  Cancelled

  /// The complete immutable canonical result committed.
  Finished

  /// The exact owner result receipt committed without reclaiming capacity.
  Acknowledged

  /// The original finite continuation is fenced and remains charged.
  Unknown
}

/// Command terminal and reusable completion are independent.
pub type CommandPhase {

  /// Full eventual command evidence capacity is retained before offer.
  CommandReserved

  /// The original complete offer is retained for owner clearance.
  CommandOffered

  /// The exact checked original native association is retained.
  CommandAssociated

  /// One original command dispatch claim committed.
  CommandStarted

  /// Terminal is retained but helper reuse remains unproved.
  Finishing

  /// Historical finite command completion conveys no retirement authority.
  CommandFinished

  /// Terminal and matching consumed reusable witness both committed.
  Reusable

  /// Unresolved original command custody is absorbing and charged.
  UnknownCommand
}

/// Complete checked lease history, with separate native and cleanup evidence.
pub opaque type LeaseReadback {
  LeaseReadback(row: sql.LspRead, key: id.LspServiceKey, phase: LeasePhase)
}

/// Original first-reservation custody, unavailable from a historical readback.
pub opaque type LeaseStartupClaim {
  /// Construction follows only the first original reservation COMMIT/readback.
  LeaseStartupClaim(
    /// Original DAL subject and connection incarnation, compared internally.
    store: Store,
    /// Exact immutable original lease bytes and deadline.
    original: LeaseReadback,
    /// Trusted original clock construction, separate from decoded era text.
    era: id.ClockEra,
  )
}

/// Only the first successful reservation transaction grants startup custody.
pub type LeaseReservation {

  /// The original reservation COMMIT and exact readback issued this token.
  FreshLease(claim: LeaseStartupClaim)

  /// Retry and recovery history can never reconstruct startup custody.
  RetainedLease(history: LeaseReadback)
}

/// First original placement differs from retained immutable placement history.
@internal
pub type StartupPlacement {

  /// Only the first original offer CAS committed this checked readback.
  FreshPlacement(history: CommandReadback)

  /// Matching history cannot install another live pending service context.
  RetainedPlacement(history: CommandReadback)
}

/// Checked finite history retains its original capture even after recovery.
pub opaque type FiniteReadback {
  /// Construction is restricted to checked original custody at this boundary.
  FiniteReadback(
    /// Complete bounded canonical SQL readback, including immutable evidence.
    row: sql.LspRead,
    /// Original capture coordinates and complete parent-control reference.
    capture: id.FiniteCapture,
    /// The exact original canonical semantic request.
    request: wire.Request,
    /// The closed checked historical disposition, conveying no fresh authority.
    phase: FinitePhase,
  )
}

/// Exact command history references only its real lease or finite parent.
pub opaque type CommandReadback {
  CommandReadback(row: sql.LspRead, ref: id.LspCommandRef, phase: CommandPhase)
}

/// One original post-COMMIT finite claim; its control never renews.
pub opaque type FiniteClaim {
  /// Construction is restricted to checked original custody at this boundary.
  FiniteClaim(
    /// The actual issuing connection owner, unavailable after closure.
    store: Store,
    /// The exact original committed row retained by this continuation.
    original: FiniteReadback,
    /// The original capture and immutable timed proposal.
    invocation: id.LspInvocation,
    /// The original era, E0, remaining allowance, deadline and timing digest.
    control: id.AdmittedFiniteControl,
  )
}

/// First command dispatch claim, permanently unavailable through history.
pub opaque type CommandClaim {
  CommandClaim(store: Store, original: CommandReadback)
}

/// Server startup authority has a closed distinct constructor.
pub opaque type ServerLeaseClaim {
  ServerLeaseClaim(claim: CommandClaim, lease: LeaseReadback)
}

/// First finite acceptance grants one original claim or returns only history.
pub type FiniteAdmission {

  /// Only the successful original timed transaction issued this claim.
  FreshFinite(claim: FiniteClaim)

  /// Exact history grants no second finite claim.
  RetainedFinite(history: FiniteReadback)
}

/// First command dispatch discriminates session lease from finite work.
pub type CommandAdmission {

  /// Only this original first dispatch transition issued a finite claim.
  FreshCommand(claim: CommandClaim)

  /// Only the exact original session lease issued server startup authority.
  FreshServer(claim: ServerLeaseClaim)

  /// Duplicate dispatch or recovery grants history only.
  RetainedCommand(history: CommandReadback)
}

/// Exact result reference includes generation and permanent invocation address.
pub opaque type ResultReceipt {
  ResultReceipt(binding: Binding, address: String, digest: g.Digest)
}

/// Checked retirement record is history, separate from physical evidence.
pub opaque type RetirementReceipt {
  /// Construction is restricted to checked original custody at this boundary.
  RetirementReceipt(
    /// The original complete generation and enrollment association.
    binding: Binding,
    /// Complete original generation or lease identity, never latest routing.
    key: id.LspServiceKey,
    /// The exact original admitted native identity bytes.
    native_identity: BitArray,
    /// The exact immutable canonical original native Prepared bytes.
    native_prepared: BitArray,
    /// Canonical cleanup evidence admitted by the trusted original verifier.
    evidence: BitArray,
    /// SHA-256 of the exact retained canonical result or evidence bytes.
    digest: g.Digest,
  )
}

/// Fixed errors retain no untrusted SQL or body contents.
pub type Error {

  /// A trusted input fails its fixed canonical identity or size contract.
  Invalid

  /// Fresh creation would replace existing permanent history.
  AlreadyExists

  /// The exact original permanent row does not exist.
  Missing

  /// Immutable original bytes, generation, parent or evidence differ.
  Conflict

  /// Full eventual reservation exceeds a configured hard ceiling.
  Capacity

  /// Original admission or cleanup custody forbids fresh authority.
  Fenced

  /// Stored scalar, canonical body or phase pairing is inconsistent.
  Corrupt

  /// The linked engine or selected physical store profile is unsupported.
  UnsupportedProfile

  /// SQL, COMMIT or reply failure may conceal a durable transition.
  Uncertain
}

type Context {
  Context(
    connection: sqlight.Connection,
    authority: Authority,
    scope: workspace.Scope,
    contract: g.Digest,
    limits: Limits,
    profiles: id.EnrolledProfiles,
  )
}

type Authority {
  OriginalLive(Store, Clock)
  HistoryOnly
}

type Disposition {
  Legacy
  ParentOwned
  HistoryOwned
}

type Input {
  LiveInput(FreshInput, Store)
  HistoricalInput(RecoveryInput)
}

type State {
  Waiting(Input, Disposition, Probe)
  Acquired(Context, Mode, Disposition, Probe)
  Open(Context, Disposition, Probe)
  FailedClose(Context, Disposition, Probe)
  Released(Disposition, Probe)
}

type Mode {
  Create
  Recover
}

type Reply {
  LeaseReply(LeaseReadback)
  LeaseReservationReply(LeaseReservation)
  FiniteReply(FiniteReadback)
  CommandReply(CommandReadback)
  AdmissionReply(FiniteAdmission)
  StartReply(CommandAdmission)
  ReceiptReply(ResultReceipt)
  RetirementReply(RetirementReceipt)
  CountReply(Int)
  PlacementReply(StartupPlacement)
  ReadyReply(Store)
  NilReply
}

type Message {
  Initialise(process.Subject(Result(Reply, Error)))
  Setup(process.Subject(Result(Reply, Error)))
  InspectLease(id.LspServiceKey, Binding, process.Subject(Result(Reply, Error)))
  InspectFinite(
    id.FiniteCapture,
    wire.Request,
    Binding,
    process.Subject(Result(Reply, Error)),
  )
  InspectCommand(
    id.LspCommandRef,
    wire.Request,
    Option(id.SelectedProject),
    Binding,
    process.Subject(Result(Reply, Error)),
  )
  AcknowledgeExact(
    id.FiniteCapture,
    wire.Request,
    g.Digest,
    Binding,
    process.Subject(Result(Reply, Error)),
  )
  CloseAck(Probe, Permit, process.Subject(Result(Reply, Error)))
  Work(
    fn(Context) -> Result(Reply, Error),
    process.Subject(Result(Reply, Error)),
  )
  Release(process.Subject(Result(Reply, Error)))
  Stop
}

/// Selects lower existing custody ceilings without widening production bounds.
///
/// ## Examples
/// `limits(4096, 268_435_456)` is the maximum profile.
pub fn limits(rows: Int, bytes: Int) -> Result(Limits, Error) {
  case rows > 0 && rows <= max_rows && bytes > 0 && bytes <= max_bytes {
    True -> Ok(Limits(rows, bytes))
    False -> Error(Invalid)
  }
}

/// Pins exact original generation and enrollment without granting authority.
///
/// ## Examples
/// Historical callers retain the old binding rather than selecting latest.
pub fn binding(key: g.GenerationKey, enrollment: g.Digest) -> Binding {
  Binding(key, enrollment)
}

/// Retains immutable live inputs without filesystem access or SQL acquisition.
///
/// ## Examples
/// Permanent assembly passes its checked original plan and trusted clock once.
@internal
pub fn fresh_input(
  path: String,
  binding: Binding,
  contract: g.Digest,
  incarnation: ids.EntryId,
  limits: Limits,
  clock: Clock,
  profiles: id.EnrolledProfiles,
) -> Result(FreshInput, Error) {
  use Nil <- result.try(valid_path(path))
  Ok(FreshInput(path, binding, contract, incarnation, limits, clock, profiles))
}

/// Starts a resource-free linked writer under its actual permanent parent.
///
/// ## Examples
/// Retain this original ACK and PID before requesting initialization.
@internal
pub fn park_fresh(input: FreshInput) -> Result(ParkedFresh, Error) {
  park_fresh_observed(input, Unobserved)
}

/// Adds one closed finite checkpoint to the same production live construction.
///
/// ## Examples
/// An AfterAcquire control retains the actual connection before shared setup.
@internal
pub fn park_fresh_observed(
  input: FreshInput,
  probe: Probe,
) -> Result(ParkedFresh, Error) {
  use started <- result.try(
    actor.new_with_initialiser(1000, fn(subject) {
      use _ <- result.try(
        checkpoint(probe, BeforeAck)
        |> result.replace_error("Original LSP parent unavailable before ACK"),
      )
      let store = Store(subject, input.binding, input.incarnation)
      Ok(
        actor.initialised(Waiting(LiveInput(input, store), ParentOwned, probe))
        |> actor.returning(subject),
      )
    })
    |> actor.trapping_exits(True)
    |> actor.on_message(handle)
    |> actor.on_shutdown(shutdown)
    |> actor.start
    |> result.replace_error(Uncertain),
  )
  Ok(ParkedFresh(started.data, started.pid))
}

/// Projects only the acknowledged original writer for its parent's monitor.
///
/// ## Examples
/// Monitoring this PID never resolves a replacement process.
@internal
pub fn fresh_owner(original: ParkedFresh) -> process.Pid {
  original.pid
}

/// Initializes this already retained original once; retries grant no readiness.
///
/// ## Examples
/// A lost post-COMMIT result retains the same writer and cleanup obligation.
@internal
pub fn initialise_fresh(original: ParkedFresh) -> Result(LiveStore, Error) {
  use reply <- result.try(exchange_subject(original.subject, Initialise))
  case reply {
    ReadyReply(store) -> Ok(LiveStore(store))
    LeaseReply(_)
    | LeaseReservationReply(_)
    | FiniteReply(_)
    | CommandReply(_)
    | AdmissionReply(_)
    | StartReply(_)
    | ReceiptReply(_)
    | RetirementReply(_)
    | CountReply(_)
    | PlacementReply(_)
    | NilReply -> Error(Corrupt)
  }
}

/// Projects the exact original live endpoint for existing LSP admission.
///
/// ## Examples
/// reserve_lease_live retains this Store in its sole first-reservation claim.
@internal
pub fn live_store(ready: LiveStore) -> Store {
  ready.store
}

/// Requires original successful close ACK followed by the same normal DOWN.
///
/// ## Examples
/// This also releases a retained parked writer whose readiness reply was lost.
@internal
pub fn release_fresh(original: ParkedFresh) -> Result(Nil, Error) {
  release_subject(original.subject, original.pid)
}

/// Selects exact history without creating a live clock or Store.
///
/// ## Examples
/// Recovery retains the historical binding supplied by admitted plan assembly.
@internal
pub fn recovery_input(
  path: String,
  binding: Binding,
  contract: g.Digest,
  limits: Limits,
  profiles: id.EnrolledProfiles,
) -> Result(RecoveryInput, Error) {
  use Nil <- result.try(valid_path(path))
  Ok(RecoveryInput(path, binding, contract, limits, profiles))
}

/// Self-adopts into the original finite managed ledger before ACK or SQL.
///
/// ## Examples
/// This exposes only retained evidence and exact receipt operations.
@internal
pub fn recover_owned(
  input: RecoveryInput,
  ledger: weft.Ledger,
) -> Result(OwnedRecovery, Error) {
  recover_owned_observed(input, ledger, Unobserved)
}

/// Adds one closed finite checkpoint to actual original managed construction.
///
/// ## Examples
/// BeforeAdopt permits testing worker loss before any file acquisition.
@internal
pub fn recover_owned_observed(
  input: RecoveryInput,
  ledger: weft.Ledger,
  probe: Probe,
) -> Result(OwnedRecovery, Error) {
  use started <- result.try(
    actor.new_with_initialiser(1000, fn(subject) {
      use _ <- result.try(
        checkpoint(probe, BeforeAdopt)
        |> result.replace_error("LSP history checkpoint expired"),
      )
      let cancel = fn() {
        process.send(subject, Release(process.new_subject()))
      }
      use Nil <- result.try(
        case weft.adopt(ledger, owner: process.self(), cancel:) {
          weft.Refused -> Error("Original LSP history adoption refused")
          weft.Adopted -> Ok(Nil)
        },
      )
      use _ <- result.try(
        checkpoint(probe, BeforeAck)
        |> result.replace_error("Original LSP history unavailable before ACK"),
      )
      Ok(
        actor.initialised(Waiting(HistoricalInput(input), HistoryOwned, probe))
        |> actor.returning(subject),
      )
    })
    |> actor.trapping_exits(True)
    |> actor.on_message(handle)
    |> actor.on_shutdown(shutdown)
    |> actor.unlinked
    |> actor.start
    |> result.replace_error(Uncertain),
  )
  let original = OwnedRecovery(started.data, started.pid, input.binding)
  case exchange_subject(original.subject, Initialise) |> result.try(as_nil) {
    Ok(Nil) -> Ok(original)
    Error(error) -> {
      process.send(original.subject, Release(process.new_subject()))
      Error(error)
    }
  }
}

/// Reads an exact original lease using the immutable history input binding.
///
/// ## Examples
/// Matching retained evidence grants no startup or retirement authority.
@internal
pub fn inspect_lease_owned(
  original: OwnedRecovery,
  key: id.LspServiceKey,
) -> Result(LeaseReadback, Error) {
  exchange_subject(original.subject, InspectLease(key, original.binding, _))
  |> result.try(as_lease)
}

/// Reads the full original capture and request without renewing its anchor.
///
/// ## Examples
/// The historical era, nonce, E0 and deadline remain byte-exact.
@internal
pub fn inspect_finite_owned(
  original: OwnedRecovery,
  capture: id.FiniteCapture,
  request: wire.Request,
) -> Result(FiniteReadback, Error) {
  exchange_subject(original.subject, InspectFinite(
    capture,
    request,
    original.binding,
    _,
  ))
  |> result.try(as_finite)
}

/// Checks the complete original parent, request and enrolled command profile.
///
/// ## Examples
/// A changed request or full parent cannot substitute for the retained command.
@internal
pub fn inspect_command_owned(
  original: OwnedRecovery,
  ref: id.LspCommandRef,
  request: wire.Request,
  selected: Option(id.SelectedProject),
) -> Result(CommandReadback, Error) {
  exchange_subject(original.subject, InspectCommand(
    ref,
    request,
    selected,
    original.binding,
    _,
  ))
  |> result.try(as_command)
}

/// Commits only an exact result receipt through the existing checked reducer.
///
/// ## Examples
/// Receipt commits retain permanent charges and never release a lease slot.
@internal
pub fn acknowledge_exact_owned(
  original: OwnedRecovery,
  capture: id.FiniteCapture,
  request: wire.Request,
  digest: g.Digest,
) -> Result(Nil, Error) {
  exchange_subject(original.subject, AcknowledgeExact(
    capture,
    request,
    digest,
    original.binding,
    _,
  ))
  |> result.try(as_nil)
}

/// Joins this exact adopted writer after its successful explicit close reply.
///
/// ## Examples
/// The managed caller must separately join its original Outcome and scope drain.
@internal
pub fn release_owned(original: OwnedRecovery) -> Result(Nil, Error) {
  release_subject(original.subject, original.pid)
}

/// Creates a fresh scoped LSP store without replacing existing history.
///
/// ## Examples
/// `fresh(path, binding, contract, incarnation, limits, clock, profiles)` refuses reuse.
pub fn fresh(
  path: String,
  binding: Binding,
  contract: g.Digest,
  incarnation: ids.EntryId,
  limits: Limits,
  clock: Clock,
  profiles: id.EnrolledProfiles,
) -> Result(Store, Error) {
  open(path, binding, contract, incarnation, limits, clock, profiles, Create)
}

/// Opens exact history and fences all unavailable unfinished originals.
///
/// ## Examples
/// Repeating era and tick cannot regenerate a historical claim or anchor.
pub fn recover(
  path: String,
  binding: Binding,
  contract: g.Digest,
  incarnation: ids.EntryId,
  limits: Limits,
  clock: Clock,
  profiles: id.EnrolledProfiles,
) -> Result(Store, Error) {
  open(path, binding, contract, incarnation, limits, clock, profiles, Recover)
}

/// Constructs the exact enrolled server/root and original incarnation input.
/// The incarnation is the lease's already retained original request UUID.
///
/// ## Examples
/// A replacement retains a new UUID and consumes another permanent identity.
pub fn lease_input(
  configured_name: String,
  canonical_root: String,
  incarnation: ids.EntryId,
) -> Result(BitArray, Error) {
  use Nil <- result.try(check(
    configured_name != ""
      && string.byte_size(configured_name) <= 128
      && !string.contains(configured_name, "\u{0000}")
      && canonical_path(canonical_root),
    Invalid,
  ))
  mp.encode(
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue(configured_name),
      mp.StringValue(canonical_root),
      mp.StringValue(ids.entry_id_to_string(incarnation)),
    ]),
  )
  |> invalid
}

/// Retains a session lease and current slot before any startup effect.
/// Trusted assembly provides canonical configured label/root input and slot.
///
/// ## Examples
/// An unretired slot refuses another incarnation even after terminal or receipt.
pub fn reserve_lease(
  store: Store,
  key: id.LspServiceKey,
  input: BitArray,
  configured_name: String,
  canonical_root: String,
) -> Result(LeaseReadback, Error) {
  use reservation <- result.try(reserve_lease_live(
    store,
    key,
    input,
    configured_name,
    canonical_root,
  ))
  case reservation {
    FreshLease(claim) -> Ok(claim.original)
    RetainedLease(history) -> Ok(history)
  }
}

/// Reserves once and returns live startup custody only after its first COMMIT.
/// Existing rows return history, including when their era and ticks repeat.
///
/// ## Examples
/// `reserve_lease_live(store, key, input, name, root)` cannot renew an original.
@internal
pub fn reserve_lease_live(
  store: Store,
  key: id.LspServiceKey,
  input: BitArray,
  configured_name: String,
  canonical_root: String,
) -> Result(LeaseReservation, Error) {
  use bytes <- result.try(wire.encode_lease(key) |> invalid)
  use value <- result.try(mp.decode(bytes) |> invalid)
  use Nil <- result.try(validate_identity(store.binding, value, input, None))
  use Nil <- result.try(check(
    configured_name != ""
      && string.byte_size(configured_name) <= 128
      && canonical_path(canonical_root),
    Invalid,
  ))

  // Generation is excluded from the slot: both authority epochs still participate.
  let slot = slot_scope(store.binding.key, configured_name, canonical_root)
  use reply <- result.try(
    exchange(store, fn(context) {
      use #(_, clock) <- result.try(live_authority(context))
      case lookup(context, id.lease_address(key)) {
        Ok(row) -> {
          use Nil <- result.try(exact(row, store.binding, bytes, input))
          use Nil <- result.try(check(row.slot == slot, Conflict))
          use history <- result.try(lease_history(row))
          Ok(LeaseReservationReply(RetainedLease(history)))
        }
        Error(Missing) -> {
          use Nil <- result.try(admission_open(context))
          use slots <- result.try(query(context, sql.lsp_slots()))
          use Nil <- result.try(check(
            !list.any(slots, fn(old) { old.slot == slot }),
            Fenced,
          ))
          let tick = clock.now()
          let deadline = tick + 43_200_000
          use Nil <- result.try(check(
            signed_tick(tick) && signed_tick(deadline) && deadline != 0,
            Invalid,
          ))
          let charge = charge(bytes, input, slot, 0)
          use Nil <- result.try(insert(
            context,
            id.lease_address(key),
            0,
            charge,
          ))
          use generation <- result.try(
            g.encode_key(store.binding.key) |> invalid,
          )
          use Nil <- result.try(statement(
            context,
            sql.lsp_insert_lease(
              id.lease_address(key),
              slot,
              deadline,
              id.era_string(clock.era),
              bytes,
              input,
              generation,
              g.digest_bytes(store.binding.enrollment),
              charge,
              0,
            ),
          ))
          use Nil <- result.try(statement(
            context,
            sql.lsp_insert_slot(slot, id.lease_address(key)),
          ))
          use row <- result.try(lookup(context, id.lease_address(key)))
          use history <- result.try(lease_history(row))
          Ok(
            LeaseReservationReply(
              FreshLease(LeaseStartupClaim(store, history, clock.era)),
            ),
          )
        }
        Error(error) -> Error(error)
      }
    }),
  )
  case reply {
    LeaseReservationReply(reservation) -> Ok(reservation)
    _ -> Error(Corrupt)
  }
}

/// Projects immutable original startup facts without exporting the Store door.
///
/// ## Examples
/// This token's deadline and era survive exact retries unchanged.
@internal
pub fn lease_startup_fields(
  claim: LeaseStartupClaim,
) -> #(Binding, id.LspServiceKey, Int, id.ClockEra) {
  // The ClockEra was admitted at construction; retaining the original typed
  // clock avoids a decoder or a peer string becoming clock provenance.
  #(
    claim.store.binding,
    claim.original.key,
    claim.original.row.deadline_tick,
    claim.era,
  )
}

/// Rechecks original first-reservation custody without returning launch authority.
/// The caller already holds the original Store and trusted native clock era.
///
/// ## Examples
/// A copied token cannot pass verification against another connection owner.
@internal
pub fn verify_lease_startup(
  store: Store,
  binding: Binding,
  claim: LeaseStartupClaim,
  era: id.ClockEra,
) -> Result(Nil, Error) {
  use Nil <- result.try(check(
    store == claim.store && binding == store.binding && era == claim.era,
    Conflict,
  ))
  use reply <- result.try(
    exchange(store, fn(context) {
      use #(_, clock) <- result.try(live_authority(context))
      use Nil <- result.try(admission_open(context))
      use row <- result.try(lookup(context, claim.original.row.address))
      use Nil <- result.try(same_original(row, claim.original.row))
      use Nil <- result.try(exact_binding(row, binding))
      let now = clock.now()
      use Nil <- result.try(check(
        clock.era == era
          && row.clock_era == id.era_string(era)
          && row.deadline_tick == claim.original.row.deadline_tick
          && row.phase >= 0
          && row.phase <= 2
          && signed_tick(now)
          && now < row.deadline_tick,
        Fenced,
      ))
      Ok(NilReply)
    }),
  )
  as_nil(reply)
}

/// Observes the bounded current-slot inventory without granting cleanup rights.
/// A freshly reserved incoming lease is already included in this count.
///
/// ## Examples
/// Uncertain originals continue to occupy their slot until verified retirement.
@internal
pub fn unretired_lease_count(
  store: Store,
  binding: Binding,
) -> Result(Int, Error) {
  use Nil <- result.try(check(binding == store.binding, Conflict))
  use reply <- result.try(
    exchange(store, fn(context) {
      use slots <- result.try(query(context, sql.lsp_slots()))
      Ok(CountReply(list.length(slots)))
    }),
  )
  case reply {
    CountReply(count) -> Ok(count)
    _ -> Error(Corrupt)
  }
}

/// Reads exact complete lease history without constructing startup authority.
///
/// ## Examples
/// `inspect_lease(store, original_binding, key)` never follows a current-slot successor.
pub fn inspect_lease(
  store: Store,
  binding: Binding,
  key: id.LspServiceKey,
) -> Result(LeaseReadback, Error) {
  use _ <- result.try(wire.encode_lease(key) |> invalid)
  use reply <- result.try(
    exchange(store, fn(context) { read_lease(context, binding, key) }),
  )
  as_lease(reply)
}

/// Captures exact request, reference, E0 and one nonce before owner timing.
/// Exact retries preserve the anchor without calling the nonce source again.
///
/// ## Examples
/// Recovery returns the historical anchor but never refreshes its window.
pub fn capture_finite(
  store: Store,
  capture: id.FiniteCapture,
  request: wire.Request,
) -> Result(FiniteReadback, Error) {
  use bytes <- result.try(wire.encode_capture(capture, request) |> invalid)
  use input <- result.try(wire.encode_request(request) |> invalid)
  use value <- result.try(mp.decode(bytes) |> invalid)
  use Nil <- result.try(validate_identity(store.binding, value, input, None))
  use reply <- result.try(
    exchange(store, fn(context) {
      use #(_, clock) <- result.try(live_authority(context))
      case lookup(context, id.capture_address(capture)) {
        Ok(row) -> {
          use Nil <- result.try(exact(row, store.binding, bytes, input))
          finite_reply(row)
        }
        Error(Missing) -> {
          use Nil <- result.try(admission_open(context))
          let tick = clock.now()
          use Nil <- result.try(check(signed_tick(tick), Invalid))
          use nonce <- result.try(g.digest(clock.nonce()) |> invalid)
          use parent <- result.try(
            wire.parent_digest(id.capture_parent(capture)) |> invalid,
          )
          let anchor = id.finite_anchor(clock.era, nonce, parent)
          use anchor <- result.try(wire.encode_anchor(anchor) |> invalid)
          let reservation = charge(bytes, input, "", result_capacity)
          use Nil <- result.try(insert(
            context,
            id.capture_address(capture),
            1,
            reservation,
          ))
          use generation <- result.try(
            g.encode_key(store.binding.key) |> invalid,
          )
          use Nil <- result.try(statement(
            context,
            sql.lsp_insert_finite(
              id.capture_address(capture),
              anchor,
              tick,
              id.era_string(clock.era),
              bytes,
              input,
              generation,
              g.digest_bytes(store.binding.enrollment),
              reservation,
              0,
            ),
          ))
          use row <- result.try(lookup(context, id.capture_address(capture)))
          finite_reply(row)
        }
        Error(error) -> Error(error)
      }
    }),
  )
  as_finite(reply)
}

/// Projects the unchanged historical anchor and original local E0.
///
/// ## Examples
/// A wire reply exports only the anchor; E0 stays executor-local.
pub fn captured_anchor(
  history: FiniteReadback,
) -> Result(#(id.FiniteAnchor, Int), Error) {
  use anchor <- result.try(wire.decode_anchor(history.row.anchor) |> invalid)
  Ok(#(anchor, history.row.anchor_tick))
}

/// Admits timed control once and returns its sole post-COMMIT Started claim.
/// Expiry fences the existing capture without renewing nonce or timing.
///
/// ## Examples
/// Exact duplicate Submit returns RetainedFinite even before its deadline.
pub fn accept_finite(
  store: Store,
  invocation: id.LspInvocation,
  request: wire.Request,
) -> Result(FiniteAdmission, Error) {
  let capture = id.invocation_capture(invocation)
  use bytes <- result.try(wire.encode_capture(capture, request) |> invalid)
  use timed <- result.try(
    wire.encode_invocation(invocation, request) |> invalid,
  )
  use proposal <- result.try(
    wire.encode_timing(id.invocation_proposal(invocation)) |> invalid,
  )
  use digest <- result.try(
    wire.timing_digest(id.invocation_proposal(invocation)) |> invalid,
  )
  use input <- result.try(wire.encode_request(request) |> invalid)
  use reply <- result.try(
    exchange(store, fn(context) {
      use #(_, clock) <- result.try(live_authority(context))
      use row <- result.try(lookup(context, id.capture_address(capture)))
      use Nil <- result.try(exact(row, store.binding, bytes, input))
      case row.timing_proposal {
        <<>> -> {
          use Nil <- result.try(check(row.phase == 0, Fenced))
          use Nil <- result.try(admission_open(context))
          use anchor <- result.try(wire.decode_anchor(row.anchor) |> invalid)
          case
            id.admitted_control(
              anchor,
              id.invocation_proposal(invocation),
              row.anchor_tick,
              clock.now(),
              clock.era,
              digest,
            )
          {
            Error(_) -> {
              use Nil <- result.try(update(
                context,
                sql.LspRead(..row, phase: 8),
                row.phase,
              ))
              use history <- result.try(finite_history(
                sql.LspRead(..row, phase: 8),
              ))
              Ok(AdmissionReply(RetainedFinite(history)))
            }
            Ok(control) -> {
              let #(_, _, remaining, deadline, _) = id.control_fields(control)
              let changed =
                sql.LspRead(
                  ..row,
                  phase: 2,
                  timing_proposal: proposal,
                  timing_digest: g.digest_bytes(digest),
                  remaining_ms: remaining,
                  deadline_tick: deadline,
                )
              use Nil <- result.try(update(context, changed, row.phase))
              use saved <- result.try(lookup(context, row.address))
              use Nil <- result.try(check(saved == changed, Uncertain))
              use history <- result.try(finite_history(saved))
              let _ = timed
              Ok(
                AdmissionReply(
                  FreshFinite(FiniteClaim(store, history, invocation, control)),
                ),
              )
            }
          }
        }
        original -> {
          use Nil <- result.try(check(
            original == proposal && row.timing_digest == g.digest_bytes(digest),
            Conflict,
          ))
          use history <- result.try(finite_history(row))
          Ok(AdmissionReply(RetainedFinite(history)))
        }
      }
    }),
  )
  case reply {
    AdmissionReply(answer) -> Ok(answer)
    _ -> Error(Corrupt)
  }
}

/// Returns the original immutable control for the original physical continuation.
///
/// ## Examples
/// Every Search and finite startup step uses this same deadline.
pub fn finite_control(claim: FiniteClaim) -> id.AdmittedFiniteControl {
  claim.control
}

/// Reads exact request history, including independently checked parent reference.
///
/// ## Examples
/// History has no claim even if the stored phase is Started.
pub fn inspect_finite(
  store: Store,
  binding: Binding,
  capture: id.FiniteCapture,
  request: wire.Request,
) -> Result(FiniteReadback, Error) {
  use _ <- result.try(wire.encode_capture(capture, request) |> invalid)
  use _ <- result.try(wire.encode_request(request) |> invalid)
  use reply <- result.try(
    exchange(store, fn(context) {
      read_finite(context, binding, capture, request)
    }),
  )
  as_finite(reply)
}

/// Reserves a closed exact parent command and all eventual evidence capacity.
/// The checked reference already fixes enrolled ordinal/root; parent readback is
/// compared again under the writer lock, including its exact generation.
///
/// ## Examples
/// Sixteen distinct cold Search rows consume sixteen permanent identities.
pub fn reserve_command(
  store: Store,
  ref: id.LspCommandRef,
  request: wire.Request,
  selected: Option(id.SelectedProject),
) -> Result(CommandReadback, Error) {
  use bytes <- result.try(wire.encode_command(ref) |> invalid)
  use reply <- result.try(
    exchange(store, fn(context) {
      use checked <- result.try(
        wire.decode_command(bytes, request, context.profiles, selected)
        |> invalid,
      )
      use Nil <- result.try(check(checked == ref, Conflict))
      use parent <- result.try(parent_row(context, ref, request))
      use Nil <- result.try(exact_binding(parent, store.binding))
      case lookup(context, id.command_address(ref)) {
        Ok(row) -> {
          use Nil <- result.try(exact(row, store.binding, bytes, parent.input))
          command_reply(context, row, ref)
        }
        Error(Missing) -> {
          use Nil <- result.try(admission_open(context))
          use Nil <- result.try(check(
            parent.phase != 8
              && parent.phase != 3
              && parent.phase != 5
              && parent.phase != 6
              && parent.phase != 7,
            Fenced,
          ))
          let #(kind, role, ordinal, root, parent_bytes, projection) =
            command_coordinates(ref)
          let reservation = charge(bytes, parent.input, root, projection)
          use Nil <- result.try(insert(
            context,
            id.command_address(ref),
            2,
            reservation,
          ))
          use generation <- result.try(
            g.encode_key(store.binding.key) |> invalid,
          )
          use Nil <- result.try(statement(
            context,
            sql.lsp_insert_command(
              id.command_address(ref),
              kind,
              parent.address,
              parent_bytes,
              role,
              ordinal,
              root,
              bytes,
              parent.input,
              generation,
              g.digest_bytes(store.binding.enrollment),
              reservation,
              0,
            ),
          ))
          use saved <- result.try(lookup(context, id.command_address(ref)))
          command_reply(context, saved, ref)
        }
        Error(error) -> Error(error)
      }
    }),
  )
  as_command(reply)
}

/// Inspects the exact immutable command and independently checks its real parent.
///
/// ## Examples
/// A later invocation cannot query an earlier Search association.
pub fn inspect_command(
  store: Store,
  binding: Binding,
  ref: id.LspCommandRef,
  request: wire.Request,
  selected: Option(id.SelectedProject),
) -> Result(CommandReadback, Error) {
  use _ <- result.try(wire.encode_command(ref) |> invalid)
  use reply <- result.try(
    exchange(store, fn(context) {
      read_command(context, binding, ref, request, selected)
    }),
  )
  as_command(reply)
}

/// Retains one canonical offer after original trusted placement verification.
/// The verifier compares enrolled argv/policy/roots and full command identity.
///
/// ## Examples
/// An exact retry inspects history; changed offer bytes conflict permanently.
pub fn retain_offer(
  store: Store,
  history: CommandReadback,
  offer: BitArray,
  verify: fn(id.LspCommandRef, BitArray) -> Result(Nil, Error),
) -> Result(CommandReadback, Error) {
  use placement <- result.try(retain_offer_mode(
    store,
    history,
    offer,
    verify,
    None,
  ))
  case placement {
    FreshPlacement(history) | RetainedPlacement(history) -> Ok(history)
  }
}

/// Consumes first original ServerLease placement under the existing offer CAS.
/// A copied startup token and a lost reply can return only retained placement.
///
/// ## Examples
/// Two services sharing this Store cannot both install original pending custody.
@internal
pub fn retain_startup_offer(
  claim: LeaseStartupClaim,
  history: CommandReadback,
  offer: BitArray,
  verify: fn(id.LspCommandRef, BitArray) -> Result(Nil, Error),
) -> Result(StartupPlacement, Error) {
  retain_offer_mode(claim.store, history, offer, verify, Some(claim))
}

fn retain_offer_mode(
  store: Store,
  history: CommandReadback,
  offer: BitArray,
  verify: fn(id.LspCommandRef, BitArray) -> Result(Nil, Error),
  startup: Option(LeaseStartupClaim),
) -> Result(StartupPlacement, Error) {
  use Nil <- result.try(canonical_record(offer, 131_072))
  use Nil <- result.try(verify(history.ref, offer))
  use reply <- result.try(
    exchange(store, fn(context) {
      use #(_, clock) <- result.try(live_authority(context))
      use row <- result.try(lookup(context, history.row.address))
      use Nil <- result.try(same_original(row, history.row))
      use Nil <- result.try(exact_binding(row, store.binding))
      use Nil <- result.try(case startup {
        None -> Ok(Nil)
        Some(claim) -> {
          use Nil <- result.try(check(
            claim.store == store
              && id.lsp_startup_command(claim.original.key, id.ServerLease)
              == Ok(history.ref),
            Conflict,
          ))
          use parent <- result.try(lookup(context, claim.original.row.address))
          use Nil <- result.try(same_original(parent, claim.original.row))
          check(
            parent.phase >= 0
              && parent.phase <= 2
              && clock.era == claim.era
              && parent.deadline_tick == claim.original.row.deadline_tick
              && clock.now() < parent.deadline_tick,
            Fenced,
          )
        }
      })
      case row.offer {
        <<>> -> {
          use Nil <- result.try(check(row.phase == 0, Fenced))
          use Nil <- result.try(admission_open(context))
          let next = sql.LspRead(..row, phase: 1, offer: offer)
          use Nil <- result.try(update(context, next, row.phase))
          use Nil <- result.try(mirror_server(context, history.ref, next, 1))
          use saved <- result.try(lookup(context, row.address))
          use Nil <- result.try(check(saved == next, Uncertain))
          use history <- result.try(command_history(saved, history.ref))
          Ok(PlacementReply(FreshPlacement(history)))
        }
        original -> {
          use Nil <- result.try(check(original == offer, Conflict))
          use history <- result.try(command_history(row, history.ref))
          Ok(PlacementReply(RetainedPlacement(history)))
        }
      }
    }),
  )
  case reply {
    PlacementReply(placement) -> Ok(placement)
    _ -> Error(Corrupt)
  }
}

/// Retains exact owner clearance after actual native admission verification.
/// The verifier must join retained owner/native records and original endpoint;
/// bytes alone neither authenticate clearance nor grant Submit authority.
///
/// ## Examples
/// Historical association may commit after expiry but never dispatches.
pub fn associate(
  store: Store,
  history: CommandReadback,
  native_identity: BitArray,
  native_prepared: BitArray,
  verify: fn(CommandReadback, BitArray, BitArray) -> Result(Nil, Error),
) -> Result(CommandReadback, Error) {
  use Nil <- result.try(canonical_record(native_identity, 8192))
  use Nil <- result.try(canonical_record(native_prepared, 131_072))
  use Nil <- result.try(verify(history, native_identity, native_prepared))
  command_mutation(store, history, fn(context, row) {
    case row.native_identity {
      <<>> -> {
        use Nil <- result.try(check(row.phase == 1 && row.offer != <<>>, Fenced))
        let next =
          sql.LspRead(
            ..row,
            phase: 2,
            native_identity: native_identity,
            native_prepared: native_prepared,
          )
        use Nil <- result.try(update(context, next, row.phase))
        use Nil <- result.try(mirror_server(context, history.ref, next, 2))
        Ok(next)
      }
      original -> {
        use Nil <- result.try(check(
          original == native_identity && row.native_prepared == native_prepared,
          Conflict,
        ))
        Ok(row)
      }
    }
  })
}

/// Commits sole command startup permission under original live timing custody.
/// Finite Search and finite startup use the original invocation claim. A
/// ServerLease uses only its separately captured original twelve-hour deadline.
///
/// ## Examples
/// Repeated start and recovery return only RetainedCommand history.
pub fn start_command(
  store: Store,
  history: CommandReadback,
  finite: Option(FiniteClaim),
) -> Result(CommandAdmission, Error) {
  use reply <- result.try(
    exchange(store, fn(context) {
      use #(_, clock) <- result.try(live_authority(context))
      use row <- result.try(lookup(context, history.row.address))
      use Nil <- result.try(same_original(row, history.row))
      case row.phase {
        2 -> {
          use Nil <- result.try(admission_open(context))
          let now = clock.now()
          use Nil <- result.try(check(signed_tick(now), Invalid))
          use Nil <- result.try(check_dispatch(
            context,
            history.ref,
            finite,
            now,
          ))
          let changed = sql.LspRead(..row, phase: 3)
          use Nil <- result.try(update(context, changed, 2))
          use Nil <- result.try(mirror_server(context, history.ref, changed, 3))
          use saved <- result.try(lookup(context, row.address))
          use Nil <- result.try(check(saved == changed, Uncertain))
          use command <- result.try(command_history(saved, history.ref))
          let claim = CommandClaim(store, command)
          case is_server(history.ref) {
            True -> {
              use parent <- result.try(lookup(context, row.parent_address))
              use lease <- result.try(lease_history(parent))
              Ok(StartReply(FreshServer(ServerLeaseClaim(claim, lease))))
            }
            False -> Ok(StartReply(FreshCommand(claim)))
          }
        }
        _ -> {
          use saved <- result.try(command_history(row, history.ref))
          Ok(StartReply(RetainedCommand(saved)))
        }
      }
    }),
  )
  case reply {
    StartReply(admitted) -> Ok(admitted)
    _ -> Error(Corrupt)
  }
}

/// Projects the exact ServerLease dispatch association for trusted native joins.
///
/// ## Examples
/// This claim cannot be reconstructed from a terminal or retirement receipt.
pub fn server_claim_fields(
  claim: ServerLeaseClaim,
) -> #(id.LspServiceKey, id.LspCommandRef, BitArray, BitArray, Int, String) {
  #(
    claim.lease.key,
    claim.claim.original.ref,
    claim.claim.original.row.native_identity,
    claim.claim.original.row.native_prepared,
    claim.lease.row.deadline_tick,
    claim.lease.row.clock_era,
  )
}

/// Rechecks exact original server dispatch custody without minting authority.
/// A trusted native clock construction supplies the original era; history or
/// decoded strings cannot substitute for that live construction.
///
/// ## Examples
/// Verification refuses a closed lease even when its claim bytes still match.
@internal
pub fn verify_server_claim(
  store: Store,
  binding: Binding,
  claim: ServerLeaseClaim,
  era: id.ClockEra,
) -> Result(Nil, Error) {
  use Nil <- result.try(check(
    store == claim.claim.store && store.binding == binding,
    Conflict,
  ))
  use reply <- result.try(
    exchange(store, fn(context) {
      use #(_, clock) <- result.try(live_authority(context))
      use Nil <- result.try(admission_open(context))
      use lease <- result.try(lookup(context, claim.lease.row.address))
      use command <- result.try(lookup(
        context,
        claim.claim.original.row.address,
      ))
      use Nil <- result.try(same_original(lease, claim.lease.row))
      use Nil <- result.try(same_original(command, claim.claim.original.row))
      use Nil <- result.try(exact_binding(lease, binding))
      let now = clock.now()

      // Dispatch remains tied to both original rows, including immutable native
      // association and deadline, rather than possession of a matching digest.
      use Nil <- result.try(check(
        command.phase == 3
          && { lease.phase == 3 || lease.phase == 4 }
          && clock.era == era
          && lease.clock_era == id.era_string(era)
          && lease.deadline_tick == claim.lease.row.deadline_tick
          && command.deadline_tick == claim.claim.original.row.deadline_tick
          && command.native_identity == claim.claim.original.row.native_identity
          && command.native_prepared == claim.claim.original.row.native_prepared
          && lease.native_identity == command.native_identity
          && lease.native_prepared == command.native_prepared
          && signed_tick(now)
          && now < lease.deadline_tick,
        Fenced,
      ))
      Ok(NilReply)
    }),
  )
  as_nil(reply)
}

/// Marks Serving only from the original post-COMMIT server claim.
///
/// ## Examples
/// Manager recovery cannot recreate this claim or a live protocol attachment.
pub fn serving(claim: ServerLeaseClaim) -> Result(LeaseReadback, Error) {
  use reply <- result.try(
    exchange(claim.claim.store, fn(context) {
      use row <- result.try(lookup(context, claim.lease.row.address))
      use Nil <- result.try(same_original(row, claim.lease.row))
      use Nil <- result.try(check(
        row.native_identity == claim.claim.original.row.native_identity
          && row.native_prepared == claim.claim.original.row.native_prepared,
        Conflict,
      ))
      case row.phase {
        3 -> {
          let next = sql.LspRead(..row, phase: 4)
          use Nil <- result.try(update(context, next, 3))
          lease_reply(next)
        }
        4 -> lease_reply(row)
        _ -> Error(Fenced)
      }
    }),
  )
  as_lease(reply)
}

/// Fences unresolved command custody without dropping any native evidence.
/// A ServerLease fence also marks its original slot Uncertain in the same writer.
///
/// ## Examples
/// A late reusable witness cannot reopen a fenced original helper borrow.
pub fn fence_command(
  store: Store,
  history: CommandReadback,
) -> Result(CommandReadback, Error) {
  command_mutation(store, history, fn(context, row) {
    case row.phase {
      6 | 7 | 8 -> Ok(row)
      _ -> {
        let next = sql.LspRead(..row, phase: 8)
        use Nil <- result.try(update(context, next, row.phase))
        use Nil <- result.try(mirror_server(context, history.ref, next, 8))
        Ok(next)
      }
    }
  })
}

/// Retains exact terminal and checked bounded projection independently of reuse.
/// The verifier checks actual original native terminal and complete projection;
/// no raw stdout/stderr archive enters this store.
///
/// ## Examples
/// Finishing alone leaves its original helper unavailable for reuse.
pub fn retain_terminal(
  store: Store,
  history: CommandReadback,
  terminal: BitArray,
  projection: BitArray,
  verify: fn(CommandReadback, BitArray, BitArray) -> Result(Nil, Error),
) -> Result(CommandReadback, Error) {
  use Nil <- result.try(canonical_record(terminal, 32_768))
  let capacity = case id.command_parent(history.ref) {
    id.Search(_, _, _) -> search_capacity
    id.Startup(_) -> 131_072
  }
  use Nil <- result.try(check(
    bit_array.byte_size(projection) <= capacity,
    Capacity,
  ))
  use Nil <- result.try(verify(history, terminal, projection))
  command_mutation(store, history, fn(context, row) {
    case row.terminal {
      <<>> -> {
        use Nil <- result.try(check(row.phase == 3 || row.phase == 8, Fenced))
        let phase = case row.phase {
          8 -> 8
          _ -> 4
        }
        let next =
          sql.LspRead(
            ..row,
            phase: phase,
            terminal: terminal,
            projected_result: projection,
          )
        use Nil <- result.try(update(context, next, row.phase))
        use Nil <- result.try(mirror_server(context, history.ref, next, -1))
        Ok(next)
      }
      original -> {
        use Nil <- result.try(check(
          original == terminal && row.projected_result == projection,
          Conflict,
        ))
        Ok(row)
      }
    }
  })
}

/// Retains the consumed original helper reusable witness after exact terminal.
/// ServerLease always refuses; a late witness cannot reopen an uncertain row.
///
/// ## Examples
/// Terminal and owner receipt cannot substitute for ProtocolReusable.
pub fn retain_reusable(
  store: Store,
  history: CommandReadback,
  witness: BitArray,
  verify: fn(CommandReadback, BitArray) -> Result(Nil, Error),
) -> Result(CommandReadback, Error) {
  use Nil <- result.try(check(!is_server(history.ref), Invalid))
  use Nil <- result.try(canonical_record(witness, 8192))
  use Nil <- result.try(verify(history, witness))
  command_mutation(store, history, fn(context, row) {
    case row.reusable_witness {
      <<>> -> {
        use Nil <- result.try(check(
          row.phase == 4 && row.terminal != <<>>,
          Fenced,
        ))
        let next = sql.LspRead(..row, phase: 7, reusable_witness: witness)
        use Nil <- result.try(update(context, next, 4))
        Ok(next)
      }
      original -> {
        use Nil <- result.try(check(original == witness, Conflict))
        Ok(row)
      }
    }
  })
}

/// Retains a complete canonical request-matched result from its original claim.
/// A failed COMMIT issues no result receipt and leaves original work uncertain.
///
/// ## Examples
/// Exact finish retries cannot change result bytes or mint execution authority.
pub fn finish(
  claim: FiniteClaim,
  value: wire.ResultValue,
) -> Result(ResultReceipt, Error) {
  use bytes <- result.try(
    wire.encode_result(claim.original.request, value) |> invalid,
  )
  use reply <- result.try(
    exchange(claim.store, fn(context) {
      use row <- result.try(lookup(context, claim.original.row.address))
      use Nil <- result.try(same_original(row, claim.original.row))
      use Nil <- result.try(check(
        row.timing_proposal == claim.original.row.timing_proposal
          && row.deadline_tick == claim.original.row.deadline_tick,
        Conflict,
      ))
      case row.projected_result {
        <<>> -> {
          use Nil <- result.try(check(row.phase == 2, Fenced))
          let next = sql.LspRead(..row, phase: 6, projected_result: bytes)
          use Nil <- result.try(update(context, next, 2))
          use saved <- result.try(lookup(context, row.address))
          use Nil <- result.try(check(saved == next, Uncertain))
          Ok(
            ReceiptReply(ResultReceipt(
              claim.store.binding,
              row.address,
              hash(bytes),
            )),
          )
        }
        original -> {
          use Nil <- result.try(check(original == bytes, Conflict))
          Ok(
            ReceiptReply(ResultReceipt(
              claim.store.binding,
              row.address,
              hash(bytes),
            )),
          )
        }
      }
    }),
  )
  case reply {
    ReceiptReply(receipt) -> Ok(receipt)
    _ -> Error(Corrupt)
  }
}

/// Reads complete immutable canonical result under its original request.
///
/// ## Examples
/// Acknowledgement preserves history and never creates another result.
pub fn retained_result(
  history: FiniteReadback,
) -> Result(wire.ResultValue, Error) {
  use Nil <- result.try(check(history.row.projected_result != <<>>, Missing))
  wire.decode_result(history.request, history.row.projected_result) |> invalid
}

/// Records exact owner result receipt without reclaiming permanent capacity.
/// The owner must COMMIT/read back both result and companion reference first.
///
/// ## Examples
/// Wrong digest or generation is a permanent conflict, never successful ACK.
pub fn acknowledge(store: Store, receipt: ResultReceipt) -> Result(Nil, Error) {
  use reply <- result.try(
    exchange(store, fn(context) { write_receipt(context, receipt) }),
  )
  as_nil(reply)
}

/// Checks a received exact result digest against original retained request history.
/// The owner COMMIT/readbacks still precede calling this closed ACK operation.
///
/// ## Examples
/// An incorrect result digest cannot acknowledge or release any original row.
pub fn acknowledge_exact(
  store: Store,
  binding: Binding,
  capture: id.FiniteCapture,
  request: wire.Request,
  digest: g.Digest,
) -> Result(Nil, Error) {
  use history <- result.try(inspect_finite(store, binding, capture, request))
  use receipt <- result.try(result_receipt(history))
  use Nil <- result.try(check(receipt.digest == digest, Conflict))
  acknowledge(store, receipt)
}

/// Exposes exact original result-routing fields without effect permission.
///
/// ## Examples
/// Companion custody retains this bounded reference, not a second result body.
pub fn receipt_fields(
  receipt: ResultReceipt,
) -> #(g.GenerationKey, g.Digest, String, g.Digest) {
  #(
    receipt.binding.key,
    receipt.binding.enrollment,
    receipt.address,
    receipt.digest,
  )
}

/// Fences original finite work while preserving all original timing and evidence.
/// Cancellation itself proves neither no effect nor managed-child drain.
///
/// ## Examples
/// Finite cancellation never closes a server shared by other invocations.
pub fn cancel(
  store: Store,
  history: FiniteReadback,
) -> Result(FiniteReadback, Error) {
  use reply <- result.try(
    exchange(store, fn(context) {
      use row <- result.try(lookup(context, history.row.address))
      use Nil <- result.try(same_original(row, history.row))
      case row.phase {
        0 -> {
          let next = sql.LspRead(..row, phase: 3)
          use Nil <- result.try(update(context, next, 0))
          finite_reply(next)
        }
        1 | 2 -> {
          let next = sql.LspRead(..row, phase: 8)
          use Nil <- result.try(update(context, next, row.phase))
          finite_reply(next)
        }
        _ -> finite_reply(row)
      }
    }),
  )
  as_finite(reply)
}

/// Commits Closing before trusted assembly closes transport and original native work.
/// Uncertain remains absorbing and continues to occupy its original slot.
///
/// ## Examples
/// Closing reports no native retirement or endpoint drain by itself.
pub fn close_lease(
  store: Store,
  history: LeaseReadback,
) -> Result(LeaseReadback, Error) {
  use reply <- result.try(
    exchange(store, fn(context) {
      use row <- result.try(lookup(context, history.row.address))
      use Nil <- result.try(same_original(row, history.row))
      case row.phase {
        0 | 1 | 2 | 3 | 4 -> {
          let next = sql.LspRead(..row, phase: 5)
          use Nil <- result.try(update(context, next, row.phase))
          lease_reply(next)
        }
        _ -> lease_reply(row)
      }
    }),
  )
  as_lease(reply)
}

/// Validates exact original native retirement and every independent cleanup join.
/// Evidence is canonical bounded data. Trusted assembly must check original helper
/// exit/ForgetRetired/normal monitor, child/transport/endpoint joins and input fence.
/// It must also prove no native dispatch for an original never-started lease.
///
/// ## Examples
/// Only this verified original transaction releases the current-slot pointer.
pub fn retire_lease(
  store: Store,
  history: LeaseReadback,
  evidence: BitArray,
  verify: fn(LeaseReadback, BitArray) -> Result(Nil, Error),
) -> Result(RetirementReceipt, Error) {
  use Nil <- result.try(canonical_record(evidence, 8192))
  use Nil <- result.try(verify(history, evidence))
  use reply <- result.try(
    exchange(store, fn(context) {
      use row <- result.try(lookup(context, history.row.address))
      use Nil <- result.try(check(row == history.row, Conflict))
      use Nil <- result.try(check(
        row.phase == 5 || row.phase == 8 || row.phase == 6,
        Fenced,
      ))
      case row.retirement {
        <<>> -> {
          let next = sql.LspRead(..row, phase: 6, retirement: evidence)
          use Nil <- result.try(update(context, next, row.phase))
          use removed <- result.try(query(
            context,
            sql.lsp_remove_slot(row.slot, row.address),
          ))
          use Nil <- result.try(check(
            removed == [sql.LspRemoveSlot(row.address)],
            Uncertain,
          ))
          use saved <- result.try(lookup(context, row.address))
          use Nil <- result.try(check(saved == next, Uncertain))
          Ok(
            RetirementReply(RetirementReceipt(
              store.binding,
              history.key,
              row.native_identity,
              row.native_prepared,
              evidence,
              hash(evidence),
            )),
          )
        }
        original -> {
          use Nil <- result.try(check(original == evidence, Conflict))
          Ok(
            RetirementReply(RetirementReceipt(
              store.binding,
              history.key,
              row.native_identity,
              row.native_prepared,
              evidence,
              hash(evidence),
            )),
          )
        }
      }
    }),
  )
  case reply {
    RetirementReply(receipt) -> Ok(receipt)
    _ -> Error(Corrupt)
  }
}

/// Projects committed retirement history without asserting new live custody.
///
/// ## Examples
/// Exact evidence is available for later generation/native cleanup joins.
pub fn retirement_fields(
  receipt: RetirementReceipt,
) -> #(
  g.GenerationKey,
  id.LspServiceKey,
  BitArray,
  BitArray,
  BitArray,
  g.Digest,
) {
  #(
    receipt.binding.key,
    receipt.key,
    receipt.native_identity,
    receipt.native_prepared,
    receipt.evidence,
    receipt.digest,
  )
}

/// Permanently seals fresh capture/reservation/dispatch across independent opens.
///
/// ## Examples
/// Historical result and original cleanup reconciliation remain readable.
pub fn seal(store: Store) -> Result(Nil, Error) {
  use reply <- result.try(
    exchange(store, fn(context) {
      use Nil <- result.try(statement(context, sql.lsp_seal()))
      Ok(NilReply)
    }),
  )
  as_nil(reply)
}

/// Closes and joins this original connection owner; it proves no native retirement.
///
/// ## Examples
/// A closed Store cannot silently reopen or substitute another endpoint.
pub fn release(store: Store) -> Result(Nil, Error) {
  use owner <- result.try(
    process.subject_owner(store.subject) |> result.replace_error(Uncertain),
  )
  let watch = process.monitor(owner)
  let outcome = {
    use reply <- result.try(exchange_message(store, Release))
    use Nil <- result.try(as_nil(reply))
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) {
      case down {
        process.ProcessDown(reason: process.Normal, ..) -> Ok(Nil)
        process.ProcessDown(..) | process.PortDown(..) -> Error(Uncertain)
      }
    })
    |> process.selector_receive(5000)
    |> result.unwrap(Error(Uncertain))
  }
  process.demonitor_process(watch)
  outcome
}

fn open(
  path: String,
  binding: Binding,
  contract: g.Digest,
  incarnation: ids.EntryId,
  limits: Limits,
  clock: Clock,
  profiles: id.EnrolledProfiles,
  mode: Mode,
) -> Result(Store, Error) {
  use Nil <- result.try(valid_path(path))
  use connection <- result.try(acquire(path, mode))
  let placeholder = Store(process.new_subject(), binding, incarnation)
  let context =
    Context(
      connection,
      OriginalLive(placeholder, clock),
      g.key_scope(binding.key),
      contract,
      limits,
      profiles,
    )
  let outcome = setup(context, mode)
  case outcome {
    Ok(Nil) -> {
      case
        actor.new_with_initialiser(5000, fn(subject) {
          actor.initialised(Open(
            Context(
              ..context,
              authority: OriginalLive(
                Store(subject, binding, incarnation),
                clock,
              ),
            ),
            Legacy,
            Unobserved,
          ))
          |> actor.returning(subject)
          |> Ok
        })
        |> actor.on_message(handle)
        |> actor.on_shutdown(shutdown)
        |> actor.start
      {
        Ok(started) -> Ok(Store(started.data, binding, incarnation))
        Error(_) -> {
          let _ = sqlight.close(connection)
          Error(Uncertain)
        }
      }
    }
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      let _ = sqlight.close(connection)
      Error(error)
    }
  }
}

fn valid_path(path: String) -> Result(Nil, Error) {
  check(
    string.starts_with(path, "/")
      && string.byte_size(path) <= 4096
      && !string.contains(path, "\u{0000}"),
    Invalid,
  )
}

fn acquire(path: String, mode: Mode) -> Result(sqlight.Connection, Error) {
  use exists <- result.try(simplifile.exists(path, False) |> invalid)
  use Nil <- result.try(case mode, exists {
    Create, True -> Error(AlreadyExists)
    Recover, False -> Error(Missing)
    _, _ -> Ok(Nil)
  })
  sqlight.open(path) |> sql_error
}

fn setup(context: Context, mode: Mode) -> Result(Nil, Error) {
  use Nil <- result.try(case mode {
    Create ->
      sqlight.exec(
        "PRAGMA page_size=4096; PRAGMA journal_mode=DELETE",
        context.connection,
      )
      |> sql_error
    Recover -> {
      use sizes <- result.try(pragma_int(context.connection, "PRAGMA page_size"))
      use modes <- result.try(pragma_string(
        context.connection,
        "PRAGMA journal_mode",
      ))
      check(sizes == [4096] && modes == ["delete"], UnsupportedProfile)
    }
  })
  use Nil <- result.try(
    sqlight.exec(
      "PRAGMA max_page_count=131072; PRAGMA temp_store=MEMORY; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000",
      context.connection,
    )
    |> sql_error,
  )
  use Nil <- result.try(profile(context.connection))
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", context.connection) |> sql_error,
  )
  let prepared = {
    use Nil <- result.try(case mode {
      Create -> {
        use Nil <- result.try(
          sqlight.exec(lsp_custody_schema.schema, context.connection)
          |> sql_error,
        )
        use scope <- result.try(scope_bytes(context.scope))
        statement(
          context,
          sql.initialize_lsp(
            scope,
            g.digest_bytes(context.contract),
            context.limits.rows,
            context.limits.bytes,
          ),
        )
      }
      Recover -> Ok(Nil)
    })
    use Nil <- result.try(inventory(context))
    use headers <- result.try(query(context, sql.lsp_headers()))
    use Nil <- result.try(
      list.try_each(headers, fn(header) {
        lookup(context, header.address) |> result.replace(Nil)
      }),
    )
    case mode {
      Create -> Ok(Nil)
      Recover -> {
        use Nil <- result.try(statement(context, sql.lsp_recover_lease()))
        use Nil <- result.try(statement(context, sql.lsp_recover_finite()))
        statement(context, sql.lsp_recover_command())
      }
    }
  }
  complete(context, prepared)
}

fn live_authority(context: Context) -> Result(#(Store, Clock), Error) {
  case context.authority {
    OriginalLive(store, clock) -> Ok(#(store, clock))
    HistoryOnly -> Error(Fenced)
  }
}

fn read_lease(
  context: Context,
  binding: Binding,
  key: id.LspServiceKey,
) -> Result(Reply, Error) {
  use bytes <- result.try(wire.encode_lease(key) |> invalid)
  use row <- result.try(lookup(context, id.lease_address(key)))
  use Nil <- result.try(exact_header(row, binding, bytes))
  lease_reply(row)
}

fn read_finite(
  context: Context,
  binding: Binding,
  capture: id.FiniteCapture,
  request: wire.Request,
) -> Result(Reply, Error) {
  use bytes <- result.try(wire.encode_capture(capture, request) |> invalid)
  use input <- result.try(wire.encode_request(request) |> invalid)
  use row <- result.try(lookup(context, id.capture_address(capture)))
  use Nil <- result.try(exact(row, binding, bytes, input))
  finite_reply(row)
}

fn read_command(
  context: Context,
  binding: Binding,
  ref: id.LspCommandRef,
  request: wire.Request,
  selected: Option(id.SelectedProject),
) -> Result(Reply, Error) {
  use bytes <- result.try(wire.encode_command(ref) |> invalid)
  use checked <- result.try(
    wire.decode_command(bytes, request, context.profiles, selected) |> invalid,
  )
  use Nil <- result.try(check(checked == ref, Conflict))
  use row <- result.try(lookup(context, id.command_address(ref)))
  use parent <- result.try(parent_row(context, ref, request))
  use Nil <- result.try(exact(row, binding, bytes, parent.input))
  use Nil <- result.try(exact_binding(parent, binding))
  command_reply(context, row, ref)
}

fn write_receipt(
  context: Context,
  receipt: ResultReceipt,
) -> Result(Reply, Error) {
  use row <- result.try(lookup(context, receipt.address))
  use Nil <- result.try(exact_binding(row, receipt.binding))
  use Nil <- result.try(check(
    row.kind == 1
      && row.projected_result != <<>>
      && hash(row.projected_result) == receipt.digest,
    Conflict,
  ))
  case row.phase {
    6 -> {
      use Nil <- result.try(update(
        context,
        sql.LspRead(..row, phase: 7, receipt: g.digest_bytes(receipt.digest)),
        6,
      ))
      Ok(NilReply)
    }
    7 -> {
      use Nil <- result.try(check(
        row.receipt == g.digest_bytes(receipt.digest),
        Conflict,
      ))
      Ok(NilReply)
    }
    _ -> Error(Fenced)
  }
}

fn write_exact_receipt(
  context: Context,
  binding: Binding,
  capture: id.FiniteCapture,
  request: wire.Request,
  digest: g.Digest,
) -> Result(Reply, Error) {
  use reply <- result.try(read_finite(context, binding, capture, request))
  use history <- result.try(as_finite(reply))
  use receipt <- result.try(result_receipt(history))
  use Nil <- result.try(check(receipt.digest == digest, Conflict))
  write_receipt(context, receipt)
}

fn profile(connection: sqlight.Connection) -> Result(Nil, Error) {
  let decoder = {
    use version <- decode.field(0, decode.string)
    use source <- decode.field(1, decode.string)
    decode.success(#(version, source))
  }
  use linked <- result.try(
    sqlight.query(sql.lsp_linked_sqlite().0, connection, [], decoder)
    |> sql_error,
  )
  use Nil <- result.try(check(
    linked
      == [
      #(
        "3.50.4",
        "2025-07-30 19:33:53 4d8adfb30e03f9cf27f800a2c1ba3c48fb4ca1b08b0f5ed59a4d5ecbf45e20a3",
      ),
    ],
    UnsupportedProfile,
  ))
  use pages <- result.try(pragma_int(connection, "PRAGMA page_size"))
  use ceiling <- result.try(pragma_int(connection, "PRAGMA max_page_count"))
  use mode <- result.try(pragma_string(connection, "PRAGMA journal_mode"))
  use temporary <- result.try(pragma_int(connection, "PRAGMA temp_store"))
  use sync <- result.try(pragma_int(connection, "PRAGMA synchronous"))
  use foreign <- result.try(pragma_int(connection, "PRAGMA foreign_keys"))
  check(
    pages == [4096]
      && ceiling == [131_072]
      && mode == ["delete"]
      && temporary == [2]
      && sync == [2]
      && foreign == [1],
    UnsupportedProfile,
  )
}

fn pragma_int(
  connection: sqlight.Connection,
  statement: String,
) -> Result(List(Int), Error) {
  sqlight.query(
    statement,
    connection,
    [],
    decode.field(0, decode.int, decode.success),
  )
  |> sql_error
}

fn pragma_string(
  connection: sqlight.Connection,
  statement: String,
) -> Result(List(String), Error) {
  sqlight.query(
    statement,
    connection,
    [],
    decode.field(0, decode.string, decode.success),
  )
  |> sql_error
}

fn inventory(context: Context) -> Result(Nil, Error) {
  use metadata <- result.try(query(context, sql.lsp_metadata()))
  use scope <- result.try(scope_bytes(context.scope))
  use Nil <- result.try(case metadata {
    [value] ->
      check(
        value.scope == scope
          && value.contract == g.digest_bytes(context.contract)
          && value.row_limit == context.limits.rows
          && value.byte_limit == context.limits.bytes,
        Corrupt,
      )
    _ -> Error(Corrupt)
  })
  use integrity <- result.try(query(context, sql.lsp_inventory_integrity()))
  use Nil <- result.try(check(
    integrity == [sql.LspInventoryIntegrity(0)],
    Corrupt,
  ))
  use ledger <- result.try(query(context, sql.lsp_ledger()))
  use Nil <- result.try(case ledger {
    [value] -> {
      use invalid_count <- result.try(scalar(value.invalid))
      use bytes <- result.try(scalar(value.bytes))
      check(
        invalid_count == 0
          && value.count <= context.limits.rows
          && bytes <= context.limits.bytes,
        Corrupt,
      )
    }
    _ -> Error(Corrupt)
  })
  use headers <- result.try(query(context, sql.lsp_headers()))
  use Nil <- result.try(case ledger {
    [value] -> check(value.count == list.length(headers), Corrupt)
    _ -> Error(Corrupt)
  })
  use Nil <- result.try(
    list.try_each(headers, fn(header) {
      check(
        header.invalid == 0
          && result.is_ok(gleam_option_int(header.identity_size))
          && result.is_ok(gleam_option_int(header.input_size))
          && result.is_ok(gleam_option_int(header.generation_key_size))
          && header.enrollment_digest_size == Some(32)
          && header.reserved_bytes > 0,
        Corrupt,
      )
    }),
  )
  use slots <- result.try(query(context, sql.lsp_slots()))
  use Nil <- result.try(
    list.try_each(slots, fn(slot) {
      use Nil <- result.try(check(slot.invalid == 0, Corrupt))
      use lease <- result.try(lookup(context, slot.address))
      check(
        lease.kind == 0 && lease.slot == slot.slot && lease.phase != 6,
        Corrupt,
      )
    }),
  )
  list.try_each(headers, fn(header) {
    case header.kind {
      0 -> {
        use lease <- result.try(lookup(context, header.address))
        check(
          list.any(slots, fn(slot) {
            slot.address == header.address && slot.slot == lease.slot
          })
            == { lease.phase != 6 },
          Corrupt,
        )
      }
      1 | 2 -> Ok(Nil)
      _ -> Error(Corrupt)
    }
  })
}

fn admission_open(context: Context) -> Result(Nil, Error) {
  use metadata <- result.try(query(context, sql.lsp_metadata()))
  case metadata {
    [meta] if meta.sealed == 0 -> Ok(Nil)
    _ -> Error(Fenced)
  }
}

fn insert(
  context: Context,
  address: String,
  kind: Int,
  charge: Int,
) -> Result(Nil, Error) {
  use ledger <- result.try(query(context, sql.lsp_ledger()))
  use Nil <- result.try(case ledger {
    [value] -> {
      use bytes <- result.try(scalar(value.bytes))
      check(
        value.count < context.limits.rows
          && bytes + charge <= context.limits.bytes,
        Capacity,
      )
    }
    _ -> Error(Corrupt)
  })
  statement(context, sql.lsp_insert_identity(address, kind, charge))
}

fn charge(
  header: BitArray,
  input: BitArray,
  address_extra: String,
  result: Int,
) -> Int {
  // Conservative address/index duplication, full offer/prepared/terminal, parent,
  // timing, receipt, cleanup and bounded tombstone capacity precede every effect.
  262_144
  + bit_array.byte_size(header)
  * 8
  + bit_array.byte_size(input)
  + string.byte_size(address_extra)
  * 4
  + 131_072
  + 131_072
  + 32_768
  + result
}

fn lookup(context: Context, address: String) -> Result(sql.LspRead, Error) {
  use row <- result.try(read_row(context, address))
  use Nil <- result.try(validate_row(context, row))
  Ok(row)
}

fn read_row(context: Context, address: String) -> Result(sql.LspRead, Error) {
  use headers <- result.try(query(context, sql.lsp_headers()))
  use Nil <- result.try(
    case list.find(headers, fn(header) { header.address == address }) {
      Ok(header) -> check(header.invalid == 0, Corrupt)
      Error(Nil) -> Error(Missing)
    },
  )
  use rows <- result.try(query(context, sql.lsp_read(address)))
  case rows {
    [row] -> Ok(row)
    _ -> Error(Corrupt)
  }
}

fn validate_row(context: Context, row: sql.LspRead) -> Result(Nil, Error) {
  use generation <- result.try(
    g.decode_key(row.generation_key) |> result.replace_error(Corrupt),
  )
  use enrollment <- result.try(
    g.digest(row.enrollment_digest) |> result.replace_error(Corrupt),
  )
  use Nil <- result.try(check(g.key_scope(generation) == context.scope, Corrupt))
  let binding = Binding(generation, enrollment)
  let #(extra, capacity) = case row.kind {
    0 -> #(row.slot, 0)
    1 -> #("", result_capacity)
    2 -> #(row.search_root, case row.parent_kind {
      1 -> search_capacity
      _ -> 131_072
    })
    _ -> #("", 0)
  }
  use Nil <- result.try(check(
    row.reserved_bytes == charge(row.identity, row.input, extra, capacity),
    Corrupt,
  ))
  use Nil <- result.try(check(
    { row.native_identity == <<>> } == { row.native_prepared == <<>> },
    Corrupt,
  ))
  use Nil <- result.try(check(
    row.native_identity == <<>> || row.offer != <<>>,
    Corrupt,
  ))
  use Nil <- result.try(check(
    row.terminal == <<>> || row.native_identity != <<>>,
    Corrupt,
  ))
  use Nil <- result.try(check(
    row.reusable_witness == <<>> || row.terminal != <<>>,
    Corrupt,
  ))
  use Nil <- result.try(
    list.try_each(
      [
        #(row.offer, 131_072),
        #(row.native_identity, 8192),
        #(row.native_prepared, 131_072),
        #(row.terminal, 32_768),
        #(row.reusable_witness, 8192),
        #(row.retirement, 8192),
      ],
      fn(pair) {
        case pair.0 {
          <<>> -> Ok(Nil)
          bytes ->
            canonical_record(bytes, pair.1) |> result.replace_error(Corrupt)
        }
      },
    ),
  )
  case row.kind {
    0 -> {
      use lease <- result.try(
        wire.decode_lease(row.identity) |> result.replace_error(Corrupt),
      )
      use value <- result.try(
        mp.decode(row.identity) |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(
        validate_identity(binding, value, row.input, Some(context.contract))
        |> result.replace_error(Corrupt),
      )
      use lease_input_value <- result.try(
        bounded_msgpack.decode(row.input) |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(case lease_input_value, value {
        mp.ArrayValue([
          mp.IntValue(1),
          mp.StringValue(name),
          mp.StringValue(root),
          mp.StringValue(incarnation),
        ]),
          mp.ArrayValue([_, _, _, _, _, _, mp.StringValue(original_id), ..])
        ->
          check(
            incarnation == original_id
              && name != ""
              && string.byte_size(name) <= 128
              && !string.contains(name, "\u{0000}")
              && canonical_path(root)
              && row.slot == slot_scope(generation, name, root),
            Corrupt,
          )
        _, _ -> Error(Corrupt)
      })
      use Nil <- result.try(check(
        row.address == id.lease_address(lease)
          && row.deadline_tick != 0
          && signed_tick(row.deadline_tick)
          && row.projected_result == <<>>
          && row.receipt == <<>>
          && row.reusable_witness == <<>>,
        Corrupt,
      ))
      use _ <- result.try(
        id.clock_era(row.clock_era) |> result.replace_error(Corrupt),
      )
      use _ <- result.try(lease_history(row))
      use Nil <- result.try(check(
        { row.phase == 6 } == { row.retirement != <<>> },
        Corrupt,
      ))
      case row.phase {
        0 ->
          check(
            row.offer == <<>>
              && row.native_identity == <<>>
              && row.terminal == <<>>,
            Corrupt,
          )
        1 -> check(row.offer != <<>> && row.native_identity == <<>>, Corrupt)
        2 | 3 | 4 ->
          check(row.offer != <<>> && row.native_identity != <<>>, Corrupt)
        5 | 6 | 8 -> Ok(Nil)
        _ -> Error(Corrupt)
      }
    }
    1 -> {
      use request <- result.try(
        wire.decode_request(row.input) |> result.replace_error(Corrupt),
      )
      use capture <- result.try(
        wire.decode_capture(row.identity, request)
        |> result.replace_error(Corrupt),
      )
      use value <- result.try(
        mp.decode(row.identity) |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(
        validate_identity(binding, value, row.input, Some(context.contract))
        |> result.replace_error(Corrupt),
      )
      use anchor <- result.try(
        wire.decode_anchor(row.anchor) |> result.replace_error(Corrupt),
      )
      use parent <- result.try(
        wire.parent_digest(id.capture_parent(capture))
        |> result.replace_error(Corrupt),
      )
      use era <- result.try(
        id.clock_era(row.clock_era) |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(check(
        row.address == id.capture_address(capture)
          && signed_tick(row.anchor_tick)
          && row.offer == <<>>
          && row.native_identity == <<>>
          && row.terminal == <<>>
          && row.reusable_witness == <<>>
          && row.retirement == <<>>,
        Corrupt,
      ))
      use Nil <- result.try(case id.anchor_value(anchor) {
        mp.ArrayValue([mp.IntValue(1), mp.StringValue(a), _, mp.BinaryValue(p)]) ->
          check(a == row.clock_era && p == g.digest_bytes(parent), Corrupt)
        _ -> Error(Corrupt)
      })
      use Nil <- result.try(case row.timing_proposal {
        <<>> ->
          check(
            row.timing_digest == <<>>
              && row.remaining_ms == 0
              && row.deadline_tick == 0
              && { row.phase == 0 || row.phase == 3 || row.phase == 8 },
            Corrupt,
          )
        proposal -> {
          use proposal <- result.try(
            wire.decode_timing(proposal, id.capture_parent(capture))
            |> result.replace_error(Corrupt),
          )
          use digest <- result.try(
            wire.timing_digest(proposal) |> result.replace_error(Corrupt),
          )
          use invocation <- result.try(
            id.lsp_invocation(capture, proposal, parent)
            |> result.replace_error(Corrupt),
          )
          let _ = invocation

          // Historical validation uses the original E0, not a newly sampled clock.
          use control <- result.try(
            id.admitted_control(
              anchor,
              proposal,
              row.anchor_tick,
              row.anchor_tick,
              era,
              digest,
            )
            |> result.replace_error(Corrupt),
          )
          let #(_, _, remaining, deadline, _) = id.control_fields(control)
          check(
            row.timing_digest == g.digest_bytes(digest)
              && row.remaining_ms == remaining
              && row.deadline_tick == deadline
              && row.phase != 0
              && row.phase != 3,
            Corrupt,
          )
        }
      })
      use _ <- result.try(finite_history(row))
      use Nil <- result.try(check(
        { row.phase == 6 || row.phase == 7 } == { row.projected_result != <<>> },
        Corrupt,
      ))
      use Nil <- result.try(check(
        { row.phase == 7 } == { row.receipt != <<>> },
        Corrupt,
      ))
      case row.projected_result {
        <<>> -> Ok(Nil)
        bytes -> {
          use _ <- result.try(
            wire.decode_result(request, bytes) |> result.replace_error(Corrupt),
          )
          check(
            row.receipt == <<>> || row.receipt == g.digest_bytes(hash(bytes)),
            Corrupt,
          )
        }
      }
    }
    2 -> validate_command_row(context, row, binding)
    _ -> Error(Corrupt)
  }
}

fn validate_command_row(
  context: Context,
  row: sql.LspRead,
  binding: Binding,
) -> Result(Nil, Error) {
  use Nil <- result.try(check(
    row.retirement == <<>>
      && row.receipt == <<>>
      && row.anchor == <<>>
      && row.timing_proposal == <<>>,
    Corrupt,
  ))

  // Command ancestry is closed: only a concrete lease or finite row can parent
  // it. Check the kind before validation so corrupt command cycles never recurse.
  use parent <- result.try(read_row(context, row.parent_address))
  use Nil <- result.try(check(parent.kind == 0 || parent.kind == 1, Corrupt))
  use Nil <- result.try(validate_row(context, parent))
  use Nil <- result.try(
    exact_binding(parent, binding) |> result.replace_error(Corrupt),
  )
  use Nil <- result.try(check(
    row.input == parent.input && row.parent == parent.identity,
    Corrupt,
  ))
  use value <- result.try(
    bounded_msgpack.decode(row.identity) |> result.replace_error(Corrupt),
  )
  use Nil <- result.try(case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.ArrayValue([mp.IntValue(0), lease, mp.IntValue(role)]),
    ]) -> {
      use key <- result.try(
        id.decode_lease_value(lease) |> result.replace_error(Corrupt),
      )
      use ref <- result.try(
        id.lsp_startup_command(key, case role {
          0 -> id.Probe
          1 -> id.Prepare
          2 -> id.ServerLease
          _ -> id.Probe
        })
        |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(check(
        role >= 0
          && role <= 2
          && row.parent_kind == 0
          && parent.kind == 0
          && row.startup_role == role
          && row.search_profile_ordinal == -1
          && row.search_root == ""
          && row.address == id.command_address(ref),
        Corrupt,
      ))
      check(role != 2 || row.reusable_witness == <<>>, Corrupt)
    }
    mp.ArrayValue([
      mp.IntValue(1),
      mp.ArrayValue([
        mp.IntValue(1),
        timed,
        mp.IntValue(ordinal),
        mp.StringValue(root),
      ]),
    ]) -> {
      use request <- result.try(
        wire.decode_request(parent.input) |> result.replace_error(Corrupt),
      )
      use input <- result.try(
        wire.semantic_input(request) |> result.replace_error(Corrupt),
      )
      use invocation <- result.try(
        id.decode_invocation_value(timed, input)
        |> result.replace_error(Corrupt),
      )
      use proposal <- result.try(
        wire.encode_timing(id.invocation_proposal(invocation))
        |> result.replace_error(Corrupt),
      )
      use header <- result.try(
        wire.encode_capture(id.invocation_capture(invocation), request)
        |> result.replace_error(Corrupt),
      )
      check(
        row.parent_kind == 1
          && parent.kind == 1
          && ordinal >= 0
          && ordinal < 16
          && row.search_profile_ordinal == ordinal
          && canonical_path(root)
          && row.search_root == root
          && row.startup_role == -1
          && header == parent.identity
          && proposal == parent.timing_proposal,
        Corrupt,
      )
    }
    _ -> Error(Corrupt)
  })
  use _ <- result.try(command_phase(row.phase))
  use Nil <- result.try(check(
    row.phase != 0 || { row.offer == <<>> && row.native_identity == <<>> },
    Corrupt,
  ))
  use Nil <- result.try(check(
    row.phase != 1 || { row.offer != <<>> && row.native_identity == <<>> },
    Corrupt,
  ))
  use Nil <- result.try(check(
    row.phase != 2 && row.phase != 3 || row.native_identity != <<>>,
    Corrupt,
  ))
  use Nil <- result.try(check(
    row.phase != 4 && row.phase != 7 || row.terminal != <<>>,
    Corrupt,
  ))
  check({ row.phase == 7 } == { row.reusable_witness != <<>> }, Corrupt)
}

fn validate_identity(
  binding: Binding,
  value: mp.MsgPackValue,
  input: BitArray,
  contract: Option(g.Digest),
) -> Result(Nil, Error) {
  use Nil <- result.try(check(
    bit_array.byte_size(input) > 0 && bit_array.byte_size(input) <= 131_072,
    Capacity,
  ))
  case value {
    mp.ArrayValue([
      mp.IntValue(1),
      _,
      scope,
      _,
      _,
      _,
      _,
      mp.BinaryValue(input_digest),
      mp.BinaryValue(enrollment),
      mp.BinaryValue(actual_contract),
      _,
      _,
    ]) -> {
      use expected <- result.try(lsp_scope_value(g.key_scope(binding.key)))
      use Nil <- result.try(check(
        scope == expected
          && enrollment == g.digest_bytes(binding.enrollment)
          && input_digest == g.digest_bytes(hash(input)),
        Conflict,
      ))
      case contract {
        None -> Ok(Nil)
        Some(expected) ->
          check(actual_contract == g.digest_bytes(expected), Conflict)
      }
    }
    _ -> Error(Invalid)
  }
}

fn exact(
  row: sql.LspRead,
  binding: Binding,
  header: BitArray,
  input: BitArray,
) -> Result(Nil, Error) {
  use Nil <- result.try(exact_header(row, binding, header))
  check(row.input == input, Conflict)
}

fn exact_header(
  row: sql.LspRead,
  binding: Binding,
  header: BitArray,
) -> Result(Nil, Error) {
  use Nil <- result.try(exact_binding(row, binding))
  check(row.identity == header, Conflict)
}

fn exact_binding(row: sql.LspRead, binding: Binding) -> Result(Nil, Error) {
  use bytes <- result.try(g.encode_key(binding.key) |> invalid)
  check(
    row.generation_key == bytes
      && row.enrollment_digest == g.digest_bytes(binding.enrollment),
    Conflict,
  )
}

fn same_original(row: sql.LspRead, old: sql.LspRead) -> Result(Nil, Error) {
  check(
    row.address == old.address
      && row.kind == old.kind
      && row.identity == old.identity
      && row.input == old.input
      && row.generation_key == old.generation_key
      && row.enrollment_digest == old.enrollment_digest
      && row.slot == old.slot
      && row.parent == old.parent
      && row.parent_address == old.parent_address
      && row.anchor == old.anchor
      && row.anchor_tick == old.anchor_tick
      && row.clock_era == old.clock_era,
    Conflict,
  )
}

fn parent_row(
  context: Context,
  ref: id.LspCommandRef,
  request: wire.Request,
) -> Result(sql.LspRead, Error) {
  case id.command_parent(ref) {
    id.Startup(lease) -> {
      use bytes <- result.try(wire.encode_lease(lease) |> invalid)
      use row <- result.try(lookup(context, id.lease_address(lease)))
      use Nil <- result.try(check(
        row.kind == 0 && row.identity == bytes,
        Conflict,
      ))
      Ok(row)
    }
    id.Search(invocation, _, _) -> {
      let capture = id.invocation_capture(invocation)
      use bytes <- result.try(wire.encode_capture(capture, request) |> invalid)
      use input <- result.try(wire.encode_request(request) |> invalid)
      use proposal <- result.try(
        wire.encode_timing(id.invocation_proposal(invocation)) |> invalid,
      )
      use row <- result.try(lookup(context, id.capture_address(capture)))
      use Nil <- result.try(check(
        row.kind == 1
          && row.identity == bytes
          && row.input == input
          && row.timing_proposal == proposal,
        Conflict,
      ))
      Ok(row)
    }
  }
}

fn command_coordinates(
  ref: id.LspCommandRef,
) -> #(Int, Int, Int, String, BitArray, Int) {
  case id.command_value(ref) {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.ArrayValue([mp.IntValue(0), lease, mp.IntValue(role)]),
    ]) -> #(0, role, -1, "", encode(lease), 131_072)
    mp.ArrayValue([
      mp.IntValue(1),
      mp.ArrayValue([
        mp.IntValue(1),
        _,
        mp.IntValue(ordinal),
        mp.StringValue(root),
      ]),
    ]) -> {
      case id.command_parent(ref) {
        id.Search(invocation, _, _) -> #(
          1,
          -1,
          ordinal,
          root,
          encode(id.capture_value(id.invocation_capture(invocation))),
          search_capacity,
        )
        id.Startup(_) -> #(0, -1, -1, "", <<>>, 0)
      }
    }
    _ -> #(0, -1, -1, "", <<>>, 0)
  }
}

fn is_server(ref: id.LspCommandRef) -> Bool {
  let #(_, role, _, _, _, _) = command_coordinates(ref)
  role == 2
}

fn check_dispatch(
  context: Context,
  ref: id.LspCommandRef,
  finite: Option(FiniteClaim),
  now: Int,
) -> Result(Nil, Error) {
  use #(original_store, clock) <- result.try(live_authority(context))
  case is_server(ref), finite {
    True, _ -> {
      case id.command_parent(ref) {
        id.Startup(key) -> {
          use lease <- result.try(lookup(context, id.lease_address(key)))
          check(
            lease.phase == 2
              && lease.clock_era == id.era_string(clock.era)
              && now < lease.deadline_tick,
            Fenced,
          )
        }
        id.Search(_, _, _) -> Error(Invalid)
      }
    }
    False, Some(claim) -> {
      use Nil <- result.try(check(
        claim.store.subject == original_store.subject,
        Fenced,
      ))
      use parent <- result.try(lookup(context, claim.original.row.address))
      use Nil <- result.try(same_original(parent, claim.original.row))
      let #(era, _, _, deadline, _) = id.control_fields(claim.control)
      use Nil <- result.try(check(
        parent.phase == 2
          && era == clock.era
          && now < deadline
          && parent.deadline_tick == deadline,
        Fenced,
      ))
      case id.command_parent(ref) {
        id.Search(invocation, _, _) ->
          check(invocation == claim.invocation, Conflict)
        id.Startup(key) -> {
          use lease <- result.try(lookup(context, id.lease_address(key)))
          check(lease.phase >= 0 && lease.phase <= 4, Fenced)
        }
      }
    }
    False, None -> Error(Fenced)
  }
}

fn mirror_server(
  context: Context,
  ref: id.LspCommandRef,
  command: sql.LspRead,
  phase: Int,
) -> Result(Nil, Error) {
  case is_server(ref) {
    False -> Ok(Nil)
    True -> {
      use lease <- result.try(lookup(context, command.parent_address))
      use Nil <- result.try(check(lease.phase != 6, Fenced))

      // Closing precedes physical cleanup. Late placement and native admission
      // remain historical evidence without restoring command dispatch authority.
      let next_phase = case lease.phase, phase {
        5, 8 -> 8
        5, _ -> 5
        _, -1 -> lease.phase
        _, _ -> phase
      }
      use Nil <- result.try(check(lease.phase != 8 || next_phase == 8, Fenced))
      let next =
        sql.LspRead(
          ..lease,
          phase: next_phase,
          offer: command.offer,
          native_identity: command.native_identity,
          native_prepared: command.native_prepared,
          terminal: command.terminal,
        )
      update(context, next, lease.phase)
    }
  }
}

fn command_mutation(
  store: Store,
  history: CommandReadback,
  mutate: fn(Context, sql.LspRead) -> Result(sql.LspRead, Error),
) -> Result(CommandReadback, Error) {
  use reply <- result.try(
    exchange(store, fn(context) {
      use row <- result.try(lookup(context, history.row.address))
      use Nil <- result.try(same_original(row, history.row))
      use Nil <- result.try(exact_binding(row, store.binding))
      use changed <- result.try(mutate(context, row))
      use saved <- result.try(lookup(context, row.address))
      use Nil <- result.try(check(saved == changed, Uncertain))
      command_reply(context, saved, history.ref)
    }),
  )
  as_command(reply)
}

fn lease_history(row: sql.LspRead) -> Result(LeaseReadback, Error) {
  use key <- result.try(
    wire.decode_lease(row.identity) |> result.replace_error(Corrupt),
  )
  use phase <- result.try(case row.phase {
    0 -> Ok(Reserved)
    1 -> Ok(Offered)
    2 -> Ok(OwnerAssociated)
    3 -> Ok(Starting)
    4 -> Ok(Serving)
    5 -> Ok(Closing)
    6 -> Ok(Retired)
    8 -> Ok(UncertainLease)
    _ -> Error(Corrupt)
  })
  Ok(LeaseReadback(row, key, phase))
}

fn finite_history(row: sql.LspRead) -> Result(FiniteReadback, Error) {
  use request <- result.try(
    wire.decode_request(row.input) |> result.replace_error(Corrupt),
  )
  use capture <- result.try(
    wire.decode_capture(row.identity, request) |> result.replace_error(Corrupt),
  )
  use phase <- result.try(case row.phase {
    0 -> Ok(Captured)
    1 -> Ok(Accepted)
    2 -> Ok(Started)
    3 -> Ok(Cancelled)
    6 -> Ok(Finished)
    7 -> Ok(Acknowledged)
    8 -> Ok(Unknown)
    _ -> Error(Corrupt)
  })
  Ok(FiniteReadback(row, capture, request, phase))
}

fn command_phase(phase: Int) -> Result(CommandPhase, Error) {
  case phase {
    0 -> Ok(CommandReserved)
    1 -> Ok(CommandOffered)
    2 -> Ok(CommandAssociated)
    3 -> Ok(CommandStarted)
    4 -> Ok(Finishing)
    6 -> Ok(CommandFinished)
    7 -> Ok(Reusable)
    8 -> Ok(UnknownCommand)
    _ -> Error(Corrupt)
  }
}

fn command_history(
  row: sql.LspRead,
  ref: id.LspCommandRef,
) -> Result(CommandReadback, Error) {
  use phase <- result.try(command_phase(row.phase))
  Ok(CommandReadback(row, ref, phase))
}

fn lease_reply(row: sql.LspRead) -> Result(Reply, Error) {
  lease_history(row) |> result.map(LeaseReply)
}

fn finite_reply(row: sql.LspRead) -> Result(Reply, Error) {
  finite_history(row) |> result.map(FiniteReply)
}

fn command_reply(
  _context: Context,
  row: sql.LspRead,
  ref: id.LspCommandRef,
) -> Result(Reply, Error) {
  command_history(row, ref) |> result.map(CommandReply)
}

fn as_lease(reply: Reply) -> Result(LeaseReadback, Error) {
  case reply {
    LeaseReply(value) -> Ok(value)
    _ -> Error(Corrupt)
  }
}

fn as_finite(reply: Reply) -> Result(FiniteReadback, Error) {
  case reply {
    FiniteReply(value) -> Ok(value)
    _ -> Error(Corrupt)
  }
}

fn as_command(reply: Reply) -> Result(CommandReadback, Error) {
  case reply {
    CommandReply(value) -> Ok(value)
    _ -> Error(Corrupt)
  }
}

fn as_nil(reply: Reply) -> Result(Nil, Error) {
  case reply {
    NilReply -> Ok(Nil)
    _ -> Error(Corrupt)
  }
}

fn update(
  context: Context,
  row: sql.LspRead,
  old_phase: Int,
) -> Result(Nil, Error) {
  use phases <- result.try(case row.kind {
    0 ->
      query(
        context,
        sql.lsp_update_lease(
          row.phase,
          row.offer,
          row.native_identity,
          row.native_prepared,
          row.terminal,
          row.reusable_witness,
          row.projected_result,
          row.receipt,
          row.retirement,
          row.address,
          old_phase,
        ),
      )
      |> result.map(list.map(_, fn(value) { value.phase }))
    1 ->
      query(
        context,
        sql.lsp_update_finite(
          row.phase,
          row.offer,
          row.native_identity,
          row.native_prepared,
          row.terminal,
          row.reusable_witness,
          row.projected_result,
          row.receipt,
          row.retirement,
          row.timing_proposal,
          row.timing_digest,
          row.remaining_ms,
          row.deadline_tick,
          row.address,
          old_phase,
        ),
      )
      |> result.map(list.map(_, fn(value) { value.phase }))
    2 ->
      query(
        context,
        sql.lsp_update_command(
          row.phase,
          row.offer,
          row.native_identity,
          row.native_prepared,
          row.terminal,
          row.reusable_witness,
          row.projected_result,
          row.receipt,
          row.retirement,
          row.address,
          old_phase,
        ),
      )
      |> result.map(list.map(_, fn(value) { value.phase }))
    _ -> Error(Corrupt)
  })
  check(phases == [row.phase], Uncertain)
}

fn exchange(
  store: Store,
  work: fn(Context) -> Result(Reply, Error),
) -> Result(Reply, Error) {
  exchange_message(store, fn(reply) { Work(work, reply) })
}

fn exchange_message(
  store: Store,
  make: fn(process.Subject(Result(Reply, Error))) -> Message,
) -> Result(Reply, Error) {
  exchange_subject(store.subject, make)
}

fn release_subject(
  subject: process.Subject(Message),
  owner: process.Pid,
) -> Result(Nil, Error) {
  let watch = process.monitor(owner)
  let outcome = {
    use reply <- result.try(exchange_subject(subject, Release))
    use Nil <- result.try(as_nil(reply))
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) {
      case down {
        process.ProcessDown(reason: process.Normal, ..) -> Ok(Nil)
        process.ProcessDown(..) | process.PortDown(..) -> Error(Uncertain)
      }
    })
    |> process.selector_receive(5000)
    |> result.unwrap(Error(Uncertain))
  }
  process.demonitor_process(watch)
  outcome
}

fn exchange_subject(
  subject: process.Subject(Message),
  make: fn(process.Subject(Result(Reply, Error))) -> Message,
) -> Result(Reply, Error) {
  use owner <- result.try(
    process.subject_owner(subject) |> result.replace_error(Uncertain),
  )
  use Nil <- result.try(check(process.is_alive(owner), Uncertain))
  let reply = process.new_subject()
  let watch = process.monitor(owner)
  process.send(subject, make(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(watch, fn(_) { Error(Uncertain) })
    |> process.selector_receive(30_000)
  process.demonitor_process(watch)
  result.unwrap(answer, Error(Uncertain))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Initialise(reply) -> handle_initialise(state, reply)
    Setup(reply) -> handle_setup(state, reply)
    Work(work, reply) -> handle_work(state, work, reply)
    InspectLease(key, binding, reply) ->
      handle_history(
        state,
        fn(context) { read_lease(context, binding, key) },
        reply,
      )
    InspectFinite(capture, request, binding, reply) ->
      handle_history(
        state,
        fn(context) { read_finite(context, binding, capture, request) },
        reply,
      )
    InspectCommand(ref, request, selected, binding, reply) ->
      handle_history(
        state,
        fn(context) { read_command(context, binding, ref, request, selected) },
        reply,
      )
    AcknowledgeExact(capture, request, digest, binding, reply) ->
      handle_history(
        state,
        fn(context) {
          write_exact_receipt(context, binding, capture, request, digest)
        },
        reply,
      )
    Release(reply) -> handle_release(state, reply)
    CloseAck(probe, permit, reply) -> {
      // The prior turn installed connection-free Released before this ACK.
      reply_permit(permit, reply, Ok(NilReply))
      use _ <- or_stop(checkpoint(probe, AfterCloseAckBeforeExit))
      actor.stop()
    }
    Stop -> handle_stop(state)
  }
}

fn handle_initialise(
  state: State,
  reply: process.Subject(Result(Reply, Error)),
) -> actor.Next(State, Message) {
  case state {
    Waiting(input, disposition, probe) -> {
      case acquire_input(input) {
        Ok(#(context, mode)) ->
          // Shutdown retains the actual connection before any SQL setup turn.
          actor.continue(Acquired(context, mode, disposition, probe))
          |> actor.then_handle(Setup(reply))
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(Released(disposition, probe))
          |> actor.then_handle(Stop)
        }
      }
    }
    Acquired(_, _, _, _)
    | Open(_, _, _)
    | FailedClose(_, _, _)
    | Released(_, _) -> {
      process.send(reply, Error(Uncertain))
      actor.continue(state)
    }
  }
}

fn acquire_input(input: Input) -> Result(#(Context, Mode), Error) {
  case input {
    LiveInput(input, store) -> {
      use connection <- result.try(acquire(input.path, Create))
      Ok(#(
        Context(
          connection,
          OriginalLive(store, input.clock),
          g.key_scope(input.binding.key),
          input.contract,
          input.limits,
          input.profiles,
        ),
        Create,
      ))
    }
    HistoricalInput(input) -> {
      use connection <- result.try(acquire(input.path, Recover))
      Ok(#(
        Context(
          connection,
          HistoryOnly,
          g.key_scope(input.binding.key),
          input.contract,
          input.limits,
          input.profiles,
        ),
        Recover,
      ))
    }
  }
}

fn handle_setup(
  state: State,
  reply: process.Subject(Result(Reply, Error)),
) -> actor.Next(State, Message) {
  case state {
    Acquired(context, mode, disposition, probe) -> {
      use _ <- or_stop(checkpoint(probe, AfterAcquire))
      settle_setup(context, disposition, probe, reply, setup(context, mode))
    }
    Waiting(_, _, _) | Open(_, _, _) | FailedClose(_, _, _) | Released(_, _) -> {
      process.send(reply, Error(Uncertain))
      actor.continue(state)
    }
  }
}

fn settle_setup(
  context: Context,
  disposition: Disposition,
  probe: Probe,
  reply: process.Subject(Result(Reply, Error)),
  outcome: Result(Nil, Error),
) -> actor.Next(State, Message) {
  case outcome {
    Ok(Nil) -> {
      use permit <- or_stop(checkpoint(probe, AfterCommitBeforeReady))
      let ready = case context.authority {
        OriginalLive(store, _) -> ReadyReply(store)
        HistoryOnly -> NilReply
      }
      reply_permit(permit, reply, Ok(ready))
      actor.continue(Open(context, disposition, probe))
    }
    Error(error) -> {
      process.send(reply, Error(error))
      stop_context(context, disposition, probe)
    }
  }
}

fn handle_work(
  state: State,
  work: fn(Context) -> Result(Reply, Error),
  reply: process.Subject(Result(Reply, Error)),
) -> actor.Next(State, Message) {
  case state {
    Open(context, Legacy, probe) | Open(context, ParentOwned, probe) ->
      execute_work(context, state, probe, work, reply)
    Open(_, HistoryOwned, _) -> {
      process.send(reply, Error(Fenced))
      actor.continue(state)
    }
    Waiting(_, _, _)
    | Acquired(_, _, _, _)
    | FailedClose(_, _, _)
    | Released(_, _) -> {
      process.send(reply, Error(Uncertain))
      actor.continue(state)
    }
  }
}

fn handle_history(
  state: State,
  work: fn(Context) -> Result(Reply, Error),
  reply: process.Subject(Result(Reply, Error)),
) -> actor.Next(State, Message) {
  case state {
    Open(context, HistoryOwned, probe) ->
      execute_work(context, state, probe, work, reply)
    Open(_, Legacy, _)
    | Open(_, ParentOwned, _)
    | Waiting(_, _, _)
    | Acquired(_, _, _, _)
    | FailedClose(_, _, _)
    | Released(_, _) -> {
      process.send(reply, Error(Fenced))
      actor.continue(state)
    }
  }
}

fn execute_work(
  context: Context,
  state: State,
  probe: Probe,
  work: fn(Context) -> Result(Reply, Error),
  reply: process.Subject(Result(Reply, Error)),
) -> actor.Next(State, Message) {
  let outcome = transact(context, work)
  process.send(reply, outcome)
  case outcome, state {
    Error(Uncertain), Open(_, disposition, _)
    | Error(Corrupt), Open(_, disposition, _)
    | Error(UnsupportedProfile), Open(_, disposition, _)
    -> stop_context(context, disposition, probe)
    _, _ -> actor.continue(state)
  }
}

fn handle_release(
  state: State,
  reply: process.Subject(Result(Reply, Error)),
) -> actor.Next(State, Message) {
  case state {
    Open(context, Legacy, _) -> {
      process.send(
        reply,
        sqlight.close(context.connection)
          |> sql_error
          |> result.map(fn(_) { NilReply }),
      )
      actor.continue(Released(Legacy, Unobserved)) |> actor.then_handle(Stop)
    }
    Acquired(context, _, disposition, probe)
    | Open(context, disposition, probe)
    | FailedClose(context, disposition, probe) -> {
      use permit <- or_stop(checkpoint(probe, BeforeCloseAck))
      release_context(context, disposition, probe, permit, reply)
    }
    Waiting(_, disposition, probe) ->
      actor.continue(Released(disposition, probe))
      |> actor.then_handle(CloseAck(probe, Proceed, reply))
    Released(_, _) -> {
      process.send(reply, Error(Uncertain))
      actor.continue(state)
    }
  }
}

fn release_context(
  context: Context,
  disposition: Disposition,
  probe: Probe,
  permit: Permit,
  reply: process.Subject(Result(Reply, Error)),
) -> actor.Next(State, Message) {
  let outcome = case permit {
    RefuseClose -> Error(Uncertain)
    Proceed | SuppressReply -> close_connection(context.connection, probe)
  }
  case outcome {
    Ok(Nil) ->
      actor.continue(Released(disposition, probe))
      |> actor.then_handle(CloseAck(probe, permit, reply))
    Error(error) -> {
      process.send(reply, Error(error))

      // A synthetic refusal is one-shot; the same failed original stays owned.
      actor.continue(FailedClose(context, disposition, clear_probe(probe)))
    }
  }
}

fn clear_probe(probe: Probe) -> Probe {
  case probe {
    Unobserved -> Unobserved
    Observed(_, subject) -> Observed(BeforeAdopt, subject)
  }
}

fn stop_context(
  context: Context,
  disposition: Disposition,
  probe: Probe,
) -> actor.Next(State, Message) {
  case disposition {
    Legacy -> {
      let _ = sqlight.close(context.connection)
      actor.continue(Released(Legacy, Unobserved)) |> actor.then_handle(Stop)
    }
    ParentOwned | HistoryOwned -> {
      case close_connection(context.connection, probe) {
        Ok(Nil) ->
          actor.continue(Released(disposition, probe))
          |> actor.then_handle(Stop)
        Error(_) ->
          actor.continue(FailedClose(context, disposition, probe))
          |> actor.then_handle(Stop)
      }
    }
  }
}

fn handle_stop(state: State) -> actor.Next(State, Message) {
  case state {
    Released(_, _) -> actor.stop()
    Waiting(_, _, _)
    | Acquired(_, _, _, _)
    | Open(_, _, _)
    | FailedClose(_, _, _) ->
      actor.stop_abnormal("Original LSP SQL custody incomplete")
  }
}

fn or_stop(
  outcome: Result(a, Error),
  then: fn(a) -> actor.Next(State, Message),
) -> actor.Next(State, Message) {
  case outcome {
    Ok(value) -> then(value)
    Error(_) -> actor.stop_abnormal("Original LSP custody checkpoint expired")
  }
}

fn checkpoint(probe: Probe, stage: Checkpoint) -> Result(Permit, Error) {
  case probe {
    Observed(selected, observations) if selected == stage -> {
      let permit = process.new_subject()
      process.send(
        observations,
        CheckpointReached(stage, process.self(), permit),
      )
      process.new_selector()
      |> process.select_map(permit, Ok)
      |> process.select_trapped_exits(fn(_) { Error(Uncertain) })
      |> process.selector_receive(1000)
      |> result.unwrap(Error(Uncertain))
    }
    Unobserved | Observed(_, _) -> Ok(Proceed)
  }
}

fn reply_permit(permit: Permit, reply: process.Subject(a), value: a) -> Nil {
  case permit {
    Proceed | RefuseClose -> process.send(reply, value)
    SuppressReply -> Nil
  }
}

fn close_connection(
  connection: sqlight.Connection,
  probe: Probe,
) -> Result(Nil, Error) {
  let outcome = sqlight.close(connection) |> sql_error
  case probe {
    Unobserved -> Nil
    Observed(_, subject) ->
      process.send(subject, ConnectionClosed(process.self(), outcome))
  }
  outcome
}

fn transact(
  context: Context,
  work: fn(Context) -> Result(Reply, Error),
) -> Result(Reply, Error) {
  use Nil <- result.try(profile(context.connection))
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", context.connection) |> sql_error,
  )
  let outcome = {
    use Nil <- result.try(inventory(context))
    use value <- result.try(work(context))
    use Nil <- result.try(inventory(context))
    Ok(value)
  }
  complete(context, outcome)
}

fn complete(context: Context, outcome: Result(a, Error)) -> Result(a, Error) {
  case outcome {
    Ok(value) -> {
      use Nil <- result.try(
        sqlight.exec("COMMIT", context.connection) |> sql_error,
      )
      Ok(value)
    }
    Error(error) -> {
      use Nil <- result.try(
        sqlight.exec("ROLLBACK", context.connection) |> sql_error,
      )
      Error(error)
    }
  }
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  case state {
    Waiting(_, _, _) | Released(_, _) -> Nil
    Open(context, Legacy, _) -> {
      let _ = sqlight.close(context.connection)
      Nil
    }
    Acquired(context, _, _, probe)
    | Open(context, _, probe)
    | FailedClose(context, _, probe) -> {
      // No original owned normal exit may hide a failed actual SQL close.
      case close_connection(context.connection, probe) {
        Ok(Nil) -> Nil
        Error(_) -> process.kill(process.self())
      }
    }
  }
}

fn statement(
  context: Context,
  generated: #(String, List(dev.Param)),
) -> Result(Nil, Error) {
  let #(text, parameters) = generated
  query(context, #(text, parameters, decode.success(Nil)))
  |> result.replace(Nil)
}

fn query(
  context: Context,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(List(a), Error) {
  let #(text, parameters, decoder) = generated
  use arguments <- result.try(
    list.try_map(parameters, fn(value) {
      case value {
        dev.ParamInt(value) -> Ok(sqlight.int(value))
        dev.ParamString(value) -> Ok(sqlight.text(value))
        dev.ParamBitArray(value) -> Ok(sqlight.blob(value))
        _ -> Error(Corrupt)
      }
    }),
  )
  sqlight.query(text, context.connection, arguments, decoder) |> sql_error
}

fn lsp_scope_value(scope: workspace.Scope) -> Result(mp.MsgPackValue, Error) {
  let #(session, binding) = workspace.scope_fields(scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, name) = workspace.selector_fields(selector)
  Ok(
    mp.ArrayValue([
      mp.StringValue(ids.session_id_to_string(session)),
      mp.StringValue(executor),
      mp.StringValue(name),
      mp.IntValue(workspace_epoch),
      mp.IntValue(session_epoch),
    ]),
  )
}

fn scope_bytes(scope: workspace.Scope) -> Result(BitArray, Error) {
  use value <- result.try(lsp_scope_value(scope))
  mp.encode(value) |> invalid
}

fn slot_scope(key: g.GenerationKey, name: String, root: String) -> String {
  case lsp_scope_value(g.key_scope(key)) {
    Ok(scope) ->
      bit_array.base16_encode(
        encode(
          mp.ArrayValue([scope, mp.StringValue(name), mp.StringValue(root)]),
        ),
      )
    Error(_) -> ""
  }
}

fn canonical_record(bytes: BitArray, maximum: Int) -> Result(Nil, Error) {
  use Nil <- result.try(check(
    bit_array.byte_size(bytes) > 0 && bit_array.byte_size(bytes) <= maximum,
    Capacity,
  ))
  use value <- result.try(bounded_msgpack.decode(bytes) |> invalid)
  use canonical <- result.try(mp.encode(value) |> invalid)
  check(canonical == bytes, Invalid)
}

fn canonical_path(path: String) -> Bool {
  string.starts_with(path, "/")
  && string.byte_size(path) <= 8192
  && !string.contains(path, "\u{0000}")
  && !string.contains(path, "\\")
  && {
    path == "/"
    || list.all(string.split(string.drop_start(path, 1), "/"), fn(part) {
      part != "" && part != "." && part != ".."
    })
  }
}

fn signed_tick(value: Int) -> Bool {
  value >= -9_223_372_036_854_775_808 && value <= 9_223_372_036_854_775_807
}

fn encode(value: mp.MsgPackValue) -> BitArray {
  mp.encode(value) |> result.lazy_unwrap(fn() { <<>> })
}

fn hash(bytes: BitArray) -> g.Digest {
  case g.digest(crypto.hash(crypto.Sha256, bytes)) {
    Ok(digest) -> digest
    Error(_) -> hash(<<>>)
  }
}

fn check(condition: Bool, error: Error) -> Result(Nil, Error) {
  case condition {
    True -> Ok(Nil)
    False -> Error(error)
  }
}

fn invalid(value: Result(a, e)) -> Result(a, Error) {
  value |> result.replace_error(Invalid)
}

fn sql_error(value: Result(a, sqlight.Error)) -> Result(a, Error) {
  value |> result.replace_error(Uncertain)
}

fn scalar(value: Option(decode.Dynamic)) -> Result(Int, Error) {
  use value <- result.try(case value {
    Some(value) -> Ok(value)
    None -> Error(Corrupt)
  })
  decode.run(value, decode.int) |> result.replace_error(Corrupt)
}

fn gleam_option_int(value: Option(Int)) -> Result(Nil, Error) {
  case value {
    Some(value) if value > 0 -> Ok(Nil)
    _ -> Error(Corrupt)
  }
}

/// Returns the closed retained slot disposition with no startup authority.
///
/// ## Examples
/// Retired alone describes the witnessed historical original.
pub fn lease_disposition(history: LeaseReadback) -> LeasePhase {
  history.phase
}

/// Returns the closed finite historical phase with no renewed control.
///
/// ## Examples
/// Started remains history after the original first-claim reply.
pub fn finite_disposition(history: FiniteReadback) -> FinitePhase {
  history.phase
}

/// Returns command history, separating terminal from reusable completion.
///
/// ## Examples
/// Finishing never means that the original helper can be checked in.
pub fn command_disposition(history: CommandReadback) -> CommandPhase {
  history.phase
}

/// Projects exact immutable command bytes for original native/owner verification.
///
/// ## Examples
/// The actual witness verifier compares this tuple to its original handles.
pub fn command_evidence(
  history: CommandReadback,
) -> #(
  id.LspCommandRef,
  BitArray,
  BitArray,
  BitArray,
  BitArray,
  BitArray,
  BitArray,
) {
  #(
    history.ref,
    history.row.offer,
    history.row.native_identity,
    history.row.native_prepared,
    history.row.terminal,
    history.row.reusable_witness,
    history.row.projected_result,
  )
}

/// Reconstructs only the historical result reference after exact result readback.
///
/// ## Examples
/// Lost receipt replies need this original result, never another invocation.
pub fn result_receipt(history: FiniteReadback) -> Result(ResultReceipt, Error) {
  use _ <- result.try(retained_result(history))
  use key <- result.try(
    g.decode_key(history.row.generation_key) |> result.replace_error(Corrupt),
  )
  use enrollment <- result.try(
    g.digest(history.row.enrollment_digest) |> result.replace_error(Corrupt),
  )
  Ok(ResultReceipt(
    Binding(key, enrollment),
    history.row.address,
    hash(history.row.projected_result),
  ))
}

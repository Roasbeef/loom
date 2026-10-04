//// Durable first preparation claims for exact Compile and Launch inputs.
////
//// The journal reserves permanent identities and full Ready capacity before a
//// service may touch disk. A first Reserved->Preparing commit returns one live
//// Claim. Duplicate and recovered Preparing rows are Unknown, never permission
//// to run again. Gleam values are duplicable: the trusted adapter must perform
//// that returned claim at most once after its own re-vetting/artifact admission.
//// This journal checks canonical syntax and identity, not those authorization
//// facts, successful compilation, live resource custody or native retirement.
////
//// Original logical child addresses match owner custody. They exclude physical
//// step, content and UUID so changed evidence reaches the same conflict fence;
//// full key/header and exact input bytes retain all those immutable facts.
//// Historical Ready bytes remain even after uncertainty or witnessed cleanup.
//// They cannot reconstruct a listener, token or preparation claim on recovery.
////
//// Each private weft actor owns a SQLite connection. BEGIN IMMEDIATE, WAL and
//// FULL synchronization serialize independent opens. Checked scalar inventory
//// bounds precede reading one body; recovery validates bodies one at a time.
//// COMMIT precedes replies. SQL failure poisons this endpoint as uncertain.
//// Logical reservation ceilings do not bound SQLite pages/WAL or resident memory.
//// No timer, row collection, native process owner or effect retry lives here.
//// Format 2 reserves input, Ready, native association and closed completion capacity
//// before preparation. Format 1 cannot be upgraded into permission. Actual native
//// readback precedes the resource writer lock; historical retries need no live
//// native endpoint. Completion, cleanup, native retirement and outer receipt stay
//// distinct. A recovered Reserved row does not establish a fresh original deadline;
//// the physical caller must independently hold live original service authority.
//// Whole-service admission uses admit_preparation: only its own insertion can
//// issue a Claim. fence_preparation can retain a cancelled original before Submit.
//// Both commits precede replies; retained Reserved history never reissues authority.
//// Launch capacity is reserved but its outcome API remains unsupported.
////
//// Historical Input lookup reconstructs data, never the original live Claim.
//// Only that Claim can request fresh native launch eligibility. Its association
//// commit serializes with cancellation on this same resource row: a fence that
//// wins denies eligibility; cancellation after admission follows the exact native
//// tuple and remains in flight. Neither the permit nor this ordering promises
//// cancellation before OS start. Lost replies and historical duplicates grant no
//// new permit; the native reducer still owns its separate at-most-once launch.
////
//// ## Flow
////
//// `fresh` and `recover` enter `start` and `initialise`. `reserve`, `inspect`
//// and `claim_preparation` validate exact input before `exchange`. `commit_ready`
//// verifies its original key/producer before `run`. `handle` commits `transact`
//// before replying. `inventory` bounds headers; `retained` and `checked_row` validate one body.
//// `execute` compares both address and UUID fences, then `transition` applies
//// monotone state changes. `seal` enters `metadata_transaction` under the same
//// writer lock. `decode_header` uses core's full key decoder; `ready_for` checks
//// historical location association. `reservation` keeps lifetime byte accounting.
//// `custody_request` checks historical retries before native readback and releases
//// the writer lock before asking another actor. `custody_transition` retains the
//// immutable native tuple, completion or outer ACK. `checked_custody` recovers
//// checked retention handles; `native_readback` requires actual admission and
//// `option_terminal` projects its bounded terminal slot. `native_template` checks
//// exact hermetic facts without repeating clearance or filesystem canonicalization.
//// `retained_input` enters `input_transaction` for complete-key historical data.
//// `associate_live_native` enters `live_association` through the original Claim;
//// `native_launch_binding` exposes only its committed exact binding.
//// `live_authority` checks the original native actor's canonical finite authority.
//// `native_endpoint` and `claim_journal` expose exact local handles for trusted routing.
//// `admit_preparation` shares `execute` and `insert` under the original writer lock.
//// `fence_preparation` enters `fence_transaction` and `fence_input`; sealed missing
//// inputs return only the durable scope disposition, after checking address conflicts.

import broker/command as offer
import broker/enrollment
import broker/policy
import codemode/service_command
import codemode/service_input as input
import codemode/service_resources as resources
import core/command
import core/ids
import core/json
import core/msgpack as mp
import core/remote_tool
import core/workspace
import executor/remote/admission
import executor/remote/compile_completion as completion
import executor/remote/identity
import executor/remote/journal as native_journal
import executor/remote/journal_codec
import executor/remote/payload
import executor/remote/wire
import executor/resource_schema
import executor/sql
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import parrot/dev
import simplifile
import sqlight
import weft/actor

/// Immutable lifetime ceilings; no transition returns row or byte capacity.
pub opaque type Limits {
  Limits(
    /// Permanent original UUID slots.
    rows: Int,
    /// Logical input/header/address, Ready, native association and completion reservations.
    bytes: Int,
  )
}

/// One connection-owning endpoint pinned to exact trusted enrollment and limits.
pub opaque type Journal {
  Journal(
    /// Private actor subject, never a native resource owner.
    subject: process.Subject(Message),
    /// Original full administrative snapshot.
    enrolled: enrollment.SessionEnrollment,
    /// Exact configured native endpoint; scope equality cannot substitute another actor.
    native: native_journal.Journal,
  )
}

/// Original service key and exact canonical body, revalidated at every entry.
pub type Input {
  Input(
    /// Full original identity, including physical coordinates and provenance.
    key: command.ServiceKey,
    /// Canonical whole Compile or Launch body, without a duplicate header.
    body: BitArray,
  )
}

/// One live post-COMMIT preparation permission, unavailable from historical rows.
pub opaque type Claim {
  Claim(
    /// Original endpoint; a recovered endpoint cannot reuse this value.
    journal: Journal,
    /// Exact immutable original invocation validated before reservation.
    original: Validated,
  )
}

/// Original live association eligibility, never recoverable from historical data.
/// The native adapter must use this value only in its original first-Submit
/// continuation; Gleam values are copyable, and native AuthorizeLaunch separately
/// enforces at-most-once effect permission. No new lifetime or stored token exists.
pub opaque type NativeLaunchPermit {
  NativeLaunchPermit(
    /// Exact original resource actor endpoint, including its enrollment.
    journal: Journal,
    /// Original complete command reference.
    ref: command.CommandRef,
    /// Actual retained native key, including full scope and independent UUID.
    key: identity.RequestKey,
    /// Digest of the exact admitted canonical Prepared.
    digest: identity.Digest,
  )
}

/// Historical dispositions, never claims of current resource custody.
pub type Status {
  /// Exact input and full location-receipt capacity are durably reserved.
  Reserved

  /// Preparation may have occurred; original Ready evidence remains if issued.
  Unknown(ready: Option(resources.Ready))

  /// Canonical location evidence committed, without successful Compile or lease.
  Prepared(ready: resources.Ready)

  /// Trusted resource owner witnessed cleanup; historical location evidence stays.
  Released(ready: Option(resources.Ready))
}

/// Only the first committed Reserved->Preparing transition grants preparation.
pub type Claimed {
  /// Trusted service may perform this original preparation at most once.
  Claimed(claim: Claim)

  /// Retained evidence grants no new preparation permission.
  Existing(status: Status)
}

/// Whole-service first admission distinguishes local issuance from retained data.
/// A lost reply or historical Reserved row cannot reconstruct original authority.
@internal
pub type FirstAdmission {
  /// This transaction inserted the original and committed Preparing before reply.
  FreshClaim(
    /// Original copyable local permission; the trusted adapter owes one use.
    claim: Claim,
  )

  /// Exact retained history, including Reserved, grants no fresh permission.
  Retained(
    /// Historical disposition checked against the complete immutable input.
    status: Status,
  )
}

/// Committed cancellation disposition, separate from resource cleanup or retirement.
@internal
pub type PreparationFence {
  /// The exact row is Unknown or Released, retaining any original Ready evidence.
  InputFenced(
    /// Historical data; an associated native request can still be in flight.
    status: Status,
  )

  /// No row exists, and the committed scope seal already blocks new admission.
  ScopeFenced
}

/// Cleanup is a trusted owner witness, separate from endpoint/native retirement.
pub type Cleanup {
  /// Caller witnessed its own resource owner's cleanup; no inferred timeout.
  ResourceOwnerCleaned
}

/// Durable admission mode, separate from connection endpoint lifetime.
pub type ScopeMode {
  /// New reservations and first preparation claims remain possible.
  Open

  /// Permanent fence against new reservations and first claims across all opens.
  SealedScope
}

/// Fixed diagnostics never echo SQL text, peer source or other large data.
pub type Error {
  /// Lifetime ceilings are outside the supported finite profile.
  InvalidLimits

  /// A database path must be bounded absolute text without NUL.
  InvalidPath

  /// Fresh creation cannot replace any existing database fence.
  AlreadyExists

  /// Existing evidence or recovery path is absent.
  Missing

  /// Canonical input does not bind the exact trusted snapshot.
  BindingMismatch

  /// Body digest, syntax, bounds or Ready identity is invalid.
  InvalidInput

  /// Logical address, UUID, full key or retained evidence differs.
  Conflict

  /// Permanent row or complete Ready reservation capacity is exhausted.
  Capacity

  /// Stored bounded headers or canonical evidence failed validation.
  Corrupt

  /// A failed transaction/reply may conceal a commit; recover original evidence.
  Uncertain

  /// Durable seal prevents a new reservation or first claim.
  Sealed

  /// Endpoint is closed or poisoned.
  Closed

  /// This closed first cut reserves Launch capacity but settles Compile only.
  UnsupportedRole

  /// Connection-owning actor could not start.
  StartFailed
}

/// Immutable native identity and exact Prepared; historical data grants no launch.
pub type NativeStatus {
  /// No actual native association has committed.
  Unassociated

  /// Actual native journal admission was read before this immutable tuple committed.
  Associated(
    /// Original full closed command reference.
    ref: command.CommandRef,
    /// Independent native UUID, operation and full enrolled scope.
    key: identity.RequestKey,
    /// SHA-256 of the unchanged canonical Prepared.
    digest: identity.Digest,
    /// Exact recorded cleared materialization, never a reconstructed policy.
    prepared: wire.Prepared,
  )
}

/// Outer receipt is separate from native receipt, retirement and resource cleanup.
pub type OuterReceipt {
  /// The original owner has not acknowledged these exact completion bytes.
  ReceiptPending

  /// The authenticated owner adapter reported its durable exact-byte receipt.
  ReceiptAcknowledged
}

/// A checked local durable completion handle, recoverable without a live native endpoint.
pub opaque type RetainedCompile {
  RetainedCompile(
    /// The decoded closed result retaining the complete original service identity.
    decoded: completion.CompileCompletion,
    /// Exact canonical retained bytes.
    bytes: BitArray,
    /// SHA-256 naming completion bytes, independent of Prepared and terminal hashes.
    digest: identity.Digest,
  )
}

/// Historical Compile custody, never another preparation or native permission.
pub type CompileStatus {
  /// No exact closed result has committed.
  CompilePending

  /// A local retention handle and its independent outer receipt state.
  CompileRetained(
    /// Exact bytes can be retrieved even after a lost Before-native reply.
    retained: RetainedCompile,
    /// Only authenticated owner acknowledgement advances this field.
    receipt: OuterReceipt,
  )
}

type CustodyCommand {
  ObserveNative(Validated)
  AssociateNative(
    Validated,
    command.CommandRef,
    identity.RequestKey,
    identity.Digest,
  )
  AssociateLiveNative(
    Validated,
    command.CommandRef,
    identity.RequestKey,
    identity.Digest,
  )
  ObserveCompile(Validated)
  SettleCompile(Validated, completion.CompileCompletion, BitArray)
  FailPreparation(Validated, completion.CompileCompletion, BitArray)
  AcknowledgeCompile(Validated, identity.Digest)
}

type CustodyAnswer {
  NativeAnswer(NativeStatus)
  LaunchAnswer(command.CommandRef, identity.RequestKey, identity.Digest)
  CompileAnswer(CompileStatus)
  RetainedAnswer(RetainedCompile)
  NeedReadback
}

type NativeReadback {
  NativeReadback(
    prepared: wire.Prepared,
    bytes: BitArray,
    evidence: admission.Evidence,
    authority: Option(BitArray),
    terminal: Option(BitArray),
  )
}

type CustodyRow {
  CustodyRow(native: NativeStatus, compiled: CompileStatus)
}

type Validated {
  Validated(
    original: Input,
    id: BitArray,
    address: BitArray,
    header: BitArray,
    role: Int,
    digest: BitArray,
    producer: Option(command.ServiceKey),
  )
}

type Mode {
  Fresh
  Recover
}

type MetadataCommand {
  ObserveMode
  SealScope
}

type Inventory {
  Inventory(mode: ScopeMode, rows: List(sql.ResourceHeaders))
}

type Config {
  Config(
    path: String,
    enrolled: enrollment.SessionEnrollment,
    limits: Limits,
    native: native_journal.Journal,
  )
}

type State {
  Waiting(config: Config)
  Ready(config: Config, connection: sqlight.Connection)
}

type Command {
  Reserve(Validated)
  Inspect(Validated)
  TakeClaim(Validated)
  AdmitFirst(Validated)
  CommitReady(Validated, BitArray)
  LoseResources(Validated)
  RetireResources(Validated)
}

type Permission {
  Granted
  Withheld
}

type Answer {
  Answer(status: Status, permission: Permission)
}

type Message {
  Initialise(Mode, process.Subject(Result(Nil, Error)))
  Run(Command, process.Subject(Result(Answer, Error)))
  FencePreparation(Validated, process.Subject(Result(PreparationFence, Error)))
  ReadInput(command.ServiceKey, process.Subject(Result(Input, Error)))
  Metadata(MetadataCommand, process.Subject(Result(ScopeMode, Error)))
  Custody(CustodyCommand, process.Subject(Result(CustodyAnswer, Error)))
  CloseEndpoint(process.Subject(Result(Nil, Error)))
}

/// Validates finite lifetime row/byte ceilings, retained permanently.
///
/// ## Examples
///
/// `limits(4096, 268_435_456)` bounds logical reservations to 256 MiB.
pub fn limits(rows: Int, bytes: Int) -> Result(Limits, Error) {
  case rows > 0 && rows <= 4096 && bytes > 0 && bytes <= 268_435_456 {
    True -> Ok(Limits(rows, bytes))
    False -> Error(InvalidLimits)
  }
}

/// Creates only an unused database path and commits its exact snapshot binding.
///
/// ## Examples
///
/// `fresh(path, enrolled, limits, native)` refuses existing evidence.
pub fn fresh(
  path: String,
  enrolled: enrollment.SessionEnrollment,
  limits: Limits,
  native: native_journal.Journal,
) -> Result(Journal, Error) {
  start(Config(path, enrolled, limits, native), Fresh)
}

/// Recovers checked historical evidence without returning any preparation claim.
///
/// ## Examples
///
/// `recover(path, enrolled, limits, native)` refuses changed snapshot or quotas.
pub fn recover(
  path: String,
  enrolled: enrollment.SessionEnrollment,
  limits: Limits,
  native: native_journal.Journal,
) -> Result(Journal, Error) {
  start(Config(path, enrolled, limits, native), Recover)
}

/// Reserves exact input, identity, full Ready and eventual completion capacity before effects.
///
/// ## Examples
///
/// An exact `reserve(journal, original)` retry returns existing evidence even sealed.
pub fn reserve(journal: Journal, original: Input) -> Result(Status, Error) {
  request(journal, original, Reserve)
}

/// Inspects original evidence without implicit reservation or resource authority.
///
/// ## Examples
///
/// `inspect(journal, original)` returns Missing before reservation.
pub fn inspect(journal: Journal, original: Input) -> Result(Status, Error) {
  request(journal, original, Inspect)
}

/// Returns the exact fixed native endpoint for trusted local admission binding.
/// Comparing scope alone is insufficient: another same-scope journal may contain
/// different actual request history. This accessor performs no ask or admission.
///
/// ## Examples
///
/// ```gleam
/// assert resource_journal.native_endpoint(book) == configured_native
/// ```
@internal
pub fn native_endpoint(book: Journal) -> native_journal.Journal {
  book.native
}

/// Returns the original live Claim endpoint for trusted local route binding.
/// Historical Input, recovery and a same-scope endpoint cannot mint this value.
/// This accessor performs no ask and reconstructs neither Claim nor permit.
///
/// ## Examples
///
/// ```gleam
/// assert resource_journal.claim_journal(claim) == configured_resources
/// ```
@internal
pub fn claim_journal(claim: Claim) -> Journal {
  claim.journal
}

/// Reads original retained input using the complete key, without live authority.
/// The bounded scalar inventory precedes one body read. Exact key, canonical
/// body/digest and enrollment equality remain mandatory after cancellation,
/// sealing or native endpoint death. This API reserves nothing and returns no
/// Claim, renewed deadline, clearance or permission to reconstruct resources.
///
/// ## Examples
///
/// ```gleam
/// resource_journal.retained_input(book, original.key)
/// // -> Ok(original)
/// ```
pub fn retained_input(
  book: Journal,
  key: command.ServiceKey,
) -> Result(Input, Error) {
  let header =
    bit_array.from_string(json.to_string(command.encode_service(key)))
  let address =
    bit_array.from_string(
      remote_tool.child_address(command.service_origin(key)),
    )
  use Nil <- result.try(
    case
      bit_array.byte_size(header) <= 8192
      && bit_array.byte_size(address) <= 8192
    {
      True -> Ok(Nil)
      False -> Error(InvalidInput)
    },
  )
  exchange(book, ReadInput(key, _))
}

/// Commits Preparing before returning the one live preparation claim.
/// The trusted service MUST re-vet Compile or admit retained successful Compile
/// evidence for Launch before calling. Syntax validation here is not that proof.
///
/// ## Examples
///
/// Repeated `claim_preparation(journal, original)` returns Existing(Unknown(None)).
pub fn claim_preparation(
  journal: Journal,
  original: Input,
) -> Result(Claimed, Error) {
  use validated <- result.try(validate(journal.enrolled, original))
  use answer <- result.try(exchange(journal, Run(TakeClaim(validated), _)))
  case answer.permission {
    Granted -> Ok(Claimed(Claim(journal, validated)))
    Withheld -> Ok(Existing(answer.status))
  }
}

/// Atomically inserts and claims only a previously absent original invocation.
/// Trusted assembly must hold the original finite authority and re-vetted input.
/// Existing Reserved rows return data even after reopen; they cannot recreate a
/// live continuation. FreshClaim is issued only after COMMIT, never after a lost
/// or ambiguous reply. The explicit reserve/claim APIs keep their component use.
///
/// ## Examples
///
/// ```gleam
/// resource_journal.admit_preparation(book, original)
/// // -> Ok(resource_journal.FreshClaim(claim)) on this original insertion only.
/// ```
@internal
pub fn admit_preparation(
  book: Journal,
  original: Input,
) -> Result(FirstAdmission, Error) {
  use validated <- result.try(validate(book.enrolled, original))
  use answer <- result.try(exchange(book, Run(AdmitFirst(validated), _)))
  case answer.permission {
    Granted -> Ok(FreshClaim(Claim(book, validated)))
    Withheld -> Ok(Retained(answer.status))
  }
}

/// Commits an original cancellation fence before the caller follows native work.
/// Missing input reserves the same lifetime capacity before becoming Unknown.
/// Full immutable evidence is compared even when sealed. ScopeFenced records
/// only an already committed seal for an absent identity, never a fabricated row.
/// A lost reply remains Uncertain; no successful disposition proves cleanup or
/// absence of an already associated native submission.
///
/// ## Examples
///
/// ```gleam
/// resource_journal.fence_preparation(book, original)
/// // -> Ok(resource_journal.InputFenced(resource_journal.Unknown(None))).
/// ```
@internal
pub fn fence_preparation(
  book: Journal,
  original: Input,
) -> Result(PreparationFence, Error) {
  use validated <- result.try(validate(book.enrolled, original))
  exchange(book, FencePreparation(validated, _))
}

/// Returns the exact original key/body for the trusted physical service.
///
/// ## Examples
///
/// `original(claim).body` never substitutes current enrollment defaults.
pub fn original(claim: Claim) -> Input {
  claim.original.original
}

/// Commits exact Ready bytes under the original key and Launch producer.
/// A late claim cannot commit after explicit uncertainty or resource cleanup.
/// An exact already-Prepared retry retains original bytes without new permission.
///
/// ## Examples
///
/// `commit_ready(claim, ready)` proves location association, never native admission.
pub fn commit_ready(
  claim: Claim,
  ready: resources.Ready,
) -> Result(Status, Error) {
  use bytes <- result.try(
    resources.encode(ready) |> result.replace_error(InvalidInput),
  )
  use _ <- result.try(ready_for(claim.journal.enrolled, claim.original, bytes))
  run(claim.journal, CommitReady(claim.original, bytes))
}

/// Permanently records uncertainty, retaining original Ready bytes when present.
///
/// ## Examples
///
/// `mark_unknown(journal, original)` cannot fabricate a receipt after owner death.
pub fn mark_unknown(
  journal: Journal,
  original: Input,
) -> Result(Status, Error) {
  request(journal, original, LoseResources)
}

/// Records witnessed resource-owner cleanup without discarding replay evidence.
/// This is independent of endpoint release, native retirement or Compile success.
///
/// ## Examples
///
/// `mark_released(journal, original, ResourceOwnerCleaned)` retains original Ready.
pub fn mark_released(
  journal: Journal,
  original: Input,
  _cleanup: Cleanup,
) -> Result(Status, Error) {
  request(journal, original, RetireResources)
}

/// Reads the exact trusted snapshot retained by this endpoint.
///
/// ## Examples
///
/// `enrolled(journal)` is the original snapshot, never a newer advertisement.
pub fn enrolled(journal: Journal) -> enrollment.SessionEnrollment {
  journal.enrolled
}

/// Reads the current committed mode under the same writer lock as claims.
///
/// ## Examples
///
/// `mode(journal)` returns SealedScope after another endpoint seals.
pub fn mode(journal: Journal) -> Result(ScopeMode, Error) {
  exchange(journal, Metadata(ObserveMode, _))
}

/// Permanently fences all new reservations and first claims across independent opens.
///
/// ## Examples
///
/// `seal(journal)` commits before returning; existing evidence remains inspectable.
pub fn seal(journal: Journal) -> Result(ScopeMode, Error) {
  exchange(journal, Metadata(SealScope, _))
}

/// Closes only this SQLite actor endpoint; no resources are retired or cancelled.
///
/// ## Examples
///
/// `release_endpoint(journal)` permits explicit recovery without changing phases.
pub fn release_endpoint(journal: Journal) -> Result(Nil, Error) {
  case exchange(journal, CloseEndpoint) {
    Error(Closed) -> Ok(Nil)
    outcome -> outcome
  }
}

/// Reads historical native association without consulting the native endpoint.
///
/// ## Examples
///
/// `inspect_native(book, original)` returns Unassociated before actual admission.
pub fn inspect_native(
  book: Journal,
  original: Input,
) -> Result(NativeStatus, Error) {
  use original <- result.try(compile_original(book, original))
  use answer <- result.try(exchange(book, Custody(ObserveNative(original), _)))
  case answer {
    NativeAnswer(value) -> Ok(value)
    CompileAnswer(_)
    | RetainedAnswer(_)
    | LaunchAnswer(_, _, _)
    | NeedReadback -> Error(Corrupt)
  }
}

/// Associates only exact actual admitted Prepared read from the pinned journal.
/// A committed exact retry succeeds from history even if the native endpoint died.
///
/// ## Examples
///
/// `associate_native(book, original, ref, key, digest)` never admits or launches.
pub fn associate_native(
  book: Journal,
  original: Input,
  ref: command.CommandRef,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(NativeStatus, Error) {
  use original <- result.try(compile_original(book, original))
  use answer <- result.try(
    exchange(book, Custody(AssociateNative(original, ref, key, digest), _)),
  )
  case answer {
    NativeAnswer(value) -> Ok(value)
    CompileAnswer(_)
    | RetainedAnswer(_)
    | LaunchAnswer(_, _, _)
    | NeedReadback -> Error(Corrupt)
  }
}

/// Commits fresh live association only for the original preparation Claim.
/// Native readback happens outside the resource writer transaction. The final
/// transaction rechecks open scope, Prepared state, exact original input and
/// absence of association before COMMIT. Cancellation before that commit refuses;
/// cancellation afterward follows the retained tuple as in-flight work. An exact
/// duplicate, lost reply or historical association never yields another permit.
///
/// ## Examples
///
/// ```gleam
/// resource_journal.associate_live_native(claim, ref, key, digest)
/// // -> Ok(permit)
/// ```
pub fn associate_live_native(
  claim: Claim,
  ref: command.CommandRef,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(NativeLaunchPermit, Error) {
  let book = claim.journal
  use original <- result.try(compile_original(book, claim.original.original))
  use answer <- result.try(
    exchange(book, Custody(AssociateLiveNative(original, ref, key, digest), _)),
  )
  case answer {
    LaunchAnswer(ref, key, digest) ->
      Ok(NativeLaunchPermit(book, ref, key, digest))
    NativeAnswer(_) | CompileAnswer(_) | RetainedAnswer(_) | NeedReadback ->
      Error(Corrupt)
  }
}

/// Exposes exact committed binding for the native first-Submit continuation.
/// Comparing these values adds no authority to another journal, ref or request.
/// The original Claim endpoint is retained, not a recovered endpoint or bearer ID.
///
/// ## Examples
///
/// ```gleam
/// assert resource_journal.native_launch_binding(permit) == #(book, ref, key, digest)
/// ```
pub fn native_launch_binding(
  permit: NativeLaunchPermit,
) -> #(Journal, command.CommandRef, identity.RequestKey, identity.Digest) {
  #(permit.journal, permit.ref, permit.key, permit.digest)
}

/// Recovers a checked retention handle, including a Before-native lost reply.
///
/// ## Examples
///
/// `inspect_compile(book, original)` never recreates preparation authority.
pub fn inspect_compile(
  book: Journal,
  original: Input,
) -> Result(CompileStatus, Error) {
  use original <- result.try(compile_original(book, original))
  use answer <- result.try(exchange(book, Custody(ObserveCompile(original), _)))
  case answer {
    CompileAnswer(value) -> Ok(value)
    NativeAnswer(_)
    | RetainedAnswer(_)
    | LaunchAnswer(_, _, _)
    | NeedReadback -> Error(Corrupt)
  }
}

/// Commits one exact canonical native-associated result after actual terminal readback.
/// Historical retries compare retained bytes before requiring a live native journal.
///
/// ## Examples
///
/// `commit_compile(book, original, value)` returns local retention after COMMIT.
pub fn commit_compile(
  book: Journal,
  original: Input,
  value: completion.CompileCompletion,
) -> Result(RetainedCompile, Error) {
  use original <- result.try(compile_original(book, original))
  use bytes <- result.try(completion_bytes(book.enrolled, original, value))
  retained_answer(book, SettleCompile(original, value, bytes))
}

/// Settles failure only through the original live Preparing claim before Ready.
/// The atomic Unknown transition fences a later Ready; absence after Ready proves nothing.
///
/// ## Examples
///
/// `fail_preparation(claim, value)` refuses a native-associated or post-Ready value.
pub fn fail_preparation(
  claim: Claim,
  value: completion.CompileCompletion,
) -> Result(RetainedCompile, Error) {
  use original <- result.try(compile_original(
    claim.journal,
    claim.original.original,
  ))
  use bytes <- result.try(completion_bytes(
    claim.journal.enrolled,
    original,
    value,
  ))
  retained_answer(claim.journal, FailPreparation(original, value, bytes))
}

/// Returns exact local durable bytes, never an owner receipt or execution permit.
///
/// ## Examples
///
/// `retained_compile_bytes(retained)` is unchanged across recovery and ACK.
pub fn retained_compile_bytes(retained: RetainedCompile) -> BitArray {
  retained.bytes
}

/// Returns the completion hash, distinct from Prepared and native-terminal hashes.
///
/// ## Examples
///
/// `retained_compile_digest(retained)` names only the exact outer completion.
pub fn retained_compile_digest(retained: RetainedCompile) -> identity.Digest {
  retained.digest
}

/// Returns the decoded closed historical result without artifact issuance authority.
///
/// ## Examples
///
/// `retained_compile_value(retained)` retains the original full Compile identity.
pub fn retained_compile_value(
  retained: RetainedCompile,
) -> completion.CompileCompletion {
  retained.decoded
}

/// Records authenticated original-owner durable acknowledgement of exact result bytes.
/// The adapter must authenticate and commit before calling; this is not native receipt.
///
/// ## Examples
///
/// `acknowledge_compile(book, original, digest)` refuses a different completion hash.
pub fn acknowledge_compile(
  book: Journal,
  original: Input,
  digest: identity.Digest,
) -> Result(CompileStatus, Error) {
  use original <- result.try(compile_original(book, original))
  use answer <- result.try(
    exchange(book, Custody(AcknowledgeCompile(original, digest), _)),
  )
  case answer {
    CompileAnswer(value) -> Ok(value)
    NativeAnswer(_)
    | RetainedAnswer(_)
    | LaunchAnswer(_, _, _)
    | NeedReadback -> Error(Corrupt)
  }
}

fn compile_original(
  book: Journal,
  original: Input,
) -> Result(Validated, Error) {
  use Nil <- result.try(case command.service_role(original.key) {
    command.CompileService -> Ok(Nil)
    command.LaunchService -> Error(UnsupportedRole)
  })
  validate(book.enrolled, original)
}

fn completion_bytes(
  enrolled: enrollment.SessionEnrollment,
  original: Validated,
  value: completion.CompileCompletion,
) -> Result(BitArray, Error) {
  use Nil <- result.try(
    case completion.original(value) == original.original.key {
      True -> Ok(Nil)
      False -> Error(Conflict)
    },
  )
  use bytes <- result.try(
    completion.encode(value) |> result.replace_error(InvalidInput),
  )
  use _ <- result.try(
    completion.decode(enrolled, original.original.key, bytes)
    |> result.replace_error(InvalidInput),
  )
  Ok(bytes)
}

fn retained_answer(
  book: Journal,
  command: CustodyCommand,
) -> Result(RetainedCompile, Error) {
  use answer <- result.try(exchange(book, Custody(command, _)))
  case answer {
    RetainedAnswer(value) -> Ok(value)
    NativeAnswer(_) | CompileAnswer(_) | LaunchAnswer(_, _, _) | NeedReadback ->
      Error(Corrupt)
  }
}

/// Computes SHA-256 over the exact canonical body or receipt bytes.
///
/// ## Examples
///
/// `digest(original.body)` must equal the ServiceKey input digest in lowercase hex.
pub fn digest(bytes: BitArray) -> BitArray {
  crypto.hash(crypto.Sha256, bytes)
}

fn request(
  journal: Journal,
  original: Input,
  command: fn(Validated) -> Command,
) -> Result(Status, Error) {
  use validated <- result.try(validate(journal.enrolled, original))
  run(journal, command(validated))
}

fn validate(
  enrolled: enrollment.SessionEnrollment,
  original: Input,
) -> Result(Validated, Error) {
  use Nil <- result.try(
    case
      bit_array.bit_size(original.body) % 8 == 0
      && bit_array.byte_size(original.body) <= 9_437_184
    {
      True -> Ok(Nil)
      False -> Error(InvalidInput)
    },
  )
  use producer <- result.try(case command.service_role(original.key) {
    command.CompileService -> {
      use decoded <- result.try(
        input.decode_compile(original.body)
        |> result.replace_error(InvalidInput),
      )
      use Nil <- result.try(
        enrollment.matches(enrolled, input.compile_facts(decoded).enrolled)
        |> result.replace_error(BindingMismatch),
      )
      use _ <- result.try(
        input.compile_envelope(original.key, decoded)
        |> result.replace_error(InvalidInput),
      )
      Ok(None)
    }
    command.LaunchService -> {
      use decoded <- result.try(
        input.decode_launch(original.body) |> result.replace_error(InvalidInput),
      )
      let facts = input.launch_facts(decoded)
      use Nil <- result.try(
        enrollment.matches(enrolled, facts.enrolled)
        |> result.replace_error(BindingMismatch),
      )
      use _ <- result.try(
        input.launch_envelope(original.key, decoded)
        |> result.replace_error(InvalidInput),
      )
      Ok(Some(facts.compiled_by))
    }
  })
  use Nil <- result.try(
    case
      string.lowercase(bit_array.base16_encode(digest(original.body)))
      == command.digests(original.key).0
    {
      True -> Ok(Nil)
      False -> Error(InvalidInput)
    },
  )
  let header =
    bit_array.from_string(json.to_string(command.encode_service(original.key)))
  let address =
    bit_array.from_string(
      remote_tool.child_address(command.service_origin(original.key)),
    )
  use Nil <- result.try(
    case
      bit_array.byte_size(header) <= 8192
      && bit_array.byte_size(address) <= 8192
    {
      True -> Ok(Nil)
      False -> Error(InvalidInput)
    },
  )
  let role = case command.service_role(original.key) {
    command.CompileService -> 0
    command.LaunchService -> 1
  }
  Ok(Validated(
    original,
    bit_array.from_string(
      ids.entry_id_to_string(command.request_id(original.key)),
    ),
    address,
    header,
    role,
    digest(original.body),
    producer,
  ))
}

fn ready_for(
  enrolled: enrollment.SessionEnrollment,
  original: Validated,
  bytes: BitArray,
) -> Result(resources.Ready, Error) {
  use ready <- result.try(
    resources.decode(enrolled, bytes) |> result.replace_error(InvalidInput),
  )
  let agrees = case ready, original.producer {
    resources.CompileReady(locations), None ->
      resources.compile_fields(locations).0 == original.original.key
    resources.LaunchReady(locations), Some(producer) ->
      resources.launch_keys(locations) == #(original.original.key, producer)
    _, _ -> False
  }
  case agrees {
    True -> Ok(ready)
    False -> Error(InvalidInput)
  }
}

fn run(journal: Journal, command: Command) -> Result(Status, Error) {
  exchange(journal, Run(command, _)) |> result.map(fn(answer) { answer.status })
}

fn start(config: Config, mode: Mode) -> Result(Journal, Error) {
  use Nil <- result.try(
    case
      string.starts_with(config.path, "/")
      && string.byte_size(config.path) <= 4096
      && !string.contains(config.path, "\u{0}")
    {
      True -> Ok(Nil)
      False -> Error(InvalidPath)
    },
  )
  use scope <- result.try(native_scope(config.enrolled))
  use Nil <- result.try(case native_journal.scope(config.native) == scope {
    True -> Ok(Nil)
    False -> Error(BindingMismatch)
  })
  use started <- result.try(
    actor.new(Waiting(config))
    |> actor.on_message(handle)
    |> actor.on_shutdown(shutdown)
    |> actor.unlinked
    |> actor.start
    |> result.replace_error(StartFailed),
  )
  let journal = Journal(started.data, config.enrolled, config.native)
  case exchange(journal, Initialise(mode, _)) {
    Ok(Nil) -> Ok(journal)
    Error(error) -> {
      // Initialization may still be queued after timeout. Close behind it.
      process.send(journal.subject, CloseEndpoint(process.new_subject()))
      Error(error)
    }
  }
}

fn exchange(
  journal: Journal,
  make: fn(process.Subject(Result(a, Error))) -> Message,
) -> Result(a, Error) {
  use owner <- result.try(
    process.subject_owner(journal.subject) |> result.replace_error(Closed),
  )
  use Nil <- result.try(case process.is_alive(owner) {
    True -> Ok(Nil)
    False -> Error(Closed)
  })
  let reply = process.new_subject()
  let monitor = process.monitor(owner)
  process.send(journal.subject, make(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) { Error(Uncertain) })
    |> process.selector_receive(30_000)

  // A lost reply cannot establish whether Started or completion committed.
  process.demonitor_process(monitor)
  result.unwrap(answer, Error(Uncertain))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case state, message {
    Waiting(config), Initialise(mode, reply) -> {
      case initialise(config, mode) {
        Ok(connection) -> {
          process.send(reply, Ok(Nil))
          actor.continue(Ready(config, connection))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.stop()
        }
      }
    }
    Ready(config, connection), Run(command, reply) -> {
      let outcome = transact(connection, config, command)
      process.send(reply, outcome)
      case outcome {
        Error(Uncertain) | Error(Corrupt) | Error(BindingMismatch) ->
          actor.stop()
        Ok(_) | Error(_) -> actor.continue(state)
      }
    }
    Ready(config, connection), FencePreparation(original, reply) -> {
      let outcome = fence_transaction(connection, config, original)
      process.send(reply, outcome)
      case outcome {
        Error(Uncertain) | Error(Corrupt) | Error(BindingMismatch) ->
          actor.stop()
        Ok(_) | Error(_) -> actor.continue(state)
      }
    }
    Waiting(_), FencePreparation(_, reply) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Ready(config, connection), ReadInput(key, reply) -> {
      let outcome = input_transaction(connection, config, key)
      process.send(reply, outcome)
      case outcome {
        Error(Uncertain) | Error(Corrupt) | Error(BindingMismatch) ->
          actor.stop()
        Ok(_) | Error(_) -> actor.continue(state)
      }
    }
    Waiting(_), ReadInput(_, reply) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Ready(config, connection), Custody(command, reply) -> {
      let outcome = custody_request(connection, config, command)
      process.send(reply, outcome)
      case outcome {
        Error(Uncertain) | Error(Corrupt) | Error(BindingMismatch) ->
          actor.stop()
        Ok(_) | Error(_) -> actor.continue(state)
      }
    }
    Waiting(_), Custody(_, reply) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Ready(config, connection), Metadata(command, reply) -> {
      let outcome = metadata_transaction(connection, config, command)
      process.send(reply, outcome)
      case outcome {
        Error(Uncertain) | Error(Corrupt) | Error(BindingMismatch) ->
          actor.stop()
        Ok(_) | Error(_) -> actor.continue(state)
      }
    }
    Waiting(_), Metadata(_, reply) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Ready(_, connection), CloseEndpoint(reply) -> {
      process.send(reply, sqlight.close(connection) |> sql_error)
      actor.stop()
    }
    Waiting(_), CloseEndpoint(reply) -> {
      process.send(reply, Ok(Nil))
      actor.stop()
    }
    Waiting(_), Run(_, reply) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
    Ready(_, _), Initialise(_, reply) -> {
      process.send(reply, Error(Closed))
      actor.continue(state)
    }
  }
}

fn initialise(config: Config, mode: Mode) -> Result(sqlight.Connection, Error) {
  use exists <- result.try(
    simplifile.exists(config.path, False) |> result.replace_error(Uncertain),
  )
  use Nil <- result.try(case mode, exists {
    Fresh, True -> Error(AlreadyExists)
    Recover, False -> Error(Missing)
    Fresh, False | Recover, True -> Ok(Nil)
  })
  use connection <- result.try(sqlight.open(config.path) |> sql_error)
  let outcome = setup(connection, config, mode)
  case outcome {
    Ok(Nil) -> Ok(connection)
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      let _ = sqlight.close(connection)
      Error(error)
    }
  }
}

fn setup(
  connection: sqlight.Connection,
  config: Config,
  mode: Mode,
) -> Result(Nil, Error) {
  use Nil <- result.try(
    sqlight.exec("PRAGMA busy_timeout=5000", connection) |> sql_error,
  )
  use modes <- result.try(
    sqlight.query(
      "PRAGMA journal_mode=WAL",
      connection,
      [],
      decode.field(0, decode.string, decode.success),
    )
    |> sql_error,
  )
  use Nil <- result.try(case modes {
    ["wal"] -> Ok(Nil)
    _ -> Error(Uncertain)
  })
  use Nil <- result.try(
    sqlight.exec(
      "PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE",
      connection,
    )
    |> sql_error,
  )
  let outcome = {
    use Nil <- result.try(case mode {
      Fresh -> {
        use Nil <- result.try(
          sqlight.exec(resource_schema.schema, connection) |> sql_error,
        )
        statement(
          connection,
          sql.initialize_resources(
            snapshot(config.enrolled),
            config.limits.rows,
            config.limits.bytes,
          ),
        )
      }
      Recover -> Ok(Nil)
    })
    use inventory <- result.try(inventory(connection, config))

    // Retain only bounded addresses while validating each large body separately.
    list.try_fold(inventory.rows, set.new(), fn(seen, row) {
      use checked <- result.try(checked_row(connection, config, row))
      case set.contains(seen, checked.1.address) {
        True -> Error(Corrupt)
        False -> Ok(set.insert(seen, checked.1.address))
      }
    })
    |> result.replace(Nil)
  }
  complete_transaction(connection, outcome)
}

fn snapshot(enrolled: enrollment.SessionEnrollment) -> BitArray {
  // Smart construction already bounded this exact canonical snapshot.
  result.lazy_unwrap(enrollment.encode(enrolled), fn() { <<>> })
}

fn inventory(
  connection: sqlight.Connection,
  config: Config,
) -> Result(Inventory, Error) {
  use formats <- result.try(
    query(connection, sql.resource_format()) |> result.replace_error(Corrupt),
  )
  use Nil <- result.try(case formats {
    [sql.ResourceFormat(1)] -> Error(BindingMismatch)
    [sql.ResourceFormat(2)] -> Ok(Nil)
    _ -> Error(Corrupt)
  })
  use metadata <- result.try(
    query(connection, sql.resource_metadata()) |> result.replace_error(Corrupt),
  )
  use mode <- result.try(case metadata {
    [sql.ResourceMetadata(actual, mode, rows, bytes)]
      if rows == config.limits.rows && bytes == config.limits.bytes
    -> {
      use Nil <- result.try(case actual == snapshot(config.enrolled) {
        True -> Ok(Nil)
        False -> Error(BindingMismatch)
      })
      case mode {
        0 -> Ok(Open)
        1 -> Ok(SealedScope)
        _ -> Error(Corrupt)
      }
    }
    [_] -> Error(BindingMismatch)
    _ -> Error(Corrupt)
  })
  use rows <- result.try(
    query(connection, sql.resource_headers(config.limits.rows + 1))
    |> result.replace_error(Corrupt),
  )
  use reserved <- result.try(
    list.try_fold(rows, 0, fn(total, row) {
      use id <- result.try(
        bit_array.to_string(row.id) |> result.replace_error(Corrupt),
      )
      use parsed <- result.try(
        ids.parse_entry_id(id) |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(
        case row.valid == 1 && ids.entry_id_to_string(parsed) == id {
          True -> Ok(Nil)
          False -> Error(Corrupt)
        },
      )
      Ok(total + reservation(row))
    }),
  )
  use Nil <- result.try(
    case
      list.drop(rows, config.limits.rows) == []
      && reserved <= config.limits.bytes
    {
      True -> Ok(Nil)
      False -> Error(Corrupt)
    },
  )
  use _ <- result.try(
    list.try_fold(rows, set.new(), fn(seen, row) {
      case set.contains(seen, row.id) {
        True -> Error(Corrupt)
        False -> Ok(set.insert(seen, row.id))
      }
    }),
  )
  use _ <- result.try(
    list.try_fold(rows, set.new(), fn(seen, row) {
      case row.native_id {
        <<>> -> Ok(seen)
        id ->
          case set.contains(seen, id) {
            True -> Error(Corrupt)
            False -> Ok(set.insert(seen, id))
          }
      }
    }),
  )
  Ok(Inventory(mode, rows))
}

fn reservation(row: sql.ResourceHeaders) -> Int {
  // All original blobs plus UUID and both digest slots remain reserved forever.
  row.address_size + row.header_size + row.input_size + 663_826
}

fn retained(
  connection: sqlight.Connection,
  config: Config,
  row: sql.ResourceHeaders,
) -> Result(Status, Error) {
  checked_row(connection, config, row) |> result.map(fn(checked) { checked.0 })
}

fn checked_row(
  connection: sqlight.Connection,
  config: Config,
  row: sql.ResourceHeaders,
) -> Result(#(Status, Validated), Error) {
  use bodies <- result.try(
    query(connection, sql.resource_bodies(row.id))
    |> result.replace_error(Corrupt),
  )
  use body <- result.try(case bodies {
    [body] -> Ok(body)
    _ -> Error(Corrupt)
  })
  use key <- result.try(decode_header(body.service_header))
  use validated <- result.try(
    validate(config.enrolled, Input(key, body.input))
    |> result.replace_error(Corrupt),
  )
  use Nil <- result.try(
    case
      validated.id == row.id
      && validated.address == body.address
      && validated.header == body.service_header
      && validated.role == row.role
      && validated.digest == row.input_digest
      && bit_array.byte_size(body.input) == row.input_size
      && bit_array.byte_size(body.address) == row.address_size
      && bit_array.byte_size(body.service_header) == row.header_size
      && bit_array.byte_size(body.ready) == row.ready_size
    {
      True -> Ok(Nil)
      False -> Error(Corrupt)
    },
  )
  use ready <- result.try(case body.ready {
    <<>> -> Ok(None)
    bytes -> {
      use Nil <- result.try(case digest(bytes) == row.ready_digest {
        True -> Ok(Nil)
        False -> Error(Corrupt)
      })
      ready_for(config.enrolled, validated, bytes)
      |> result.map(Some)
      |> result.replace_error(Corrupt)
    }
  })
  let status = case row.phase, ready {
    0, None -> Ok(Reserved)
    1, None | 3, _ -> Ok(Unknown(ready))
    2, Some(ready) -> Ok(Prepared(ready))
    4, _ -> Ok(Released(ready))
    _, _ -> Error(Corrupt)
  }
  use status <- result.try(status)
  use _ <- result.try(checked_custody(
    config.enrolled,
    validated,
    row,
    body,
    status,
  ))
  Ok(#(status, validated))
}

fn decode_header(bytes: BitArray) -> Result(command.ServiceKey, Error) {
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(Corrupt),
  )
  use value <- result.try(json.parse(text) |> result.replace_error(Corrupt))
  command.decode_service(value) |> result.replace_error(Corrupt)
}

fn transact(
  connection: sqlight.Connection,
  config: Config,
  command: Command,
) -> Result(Answer, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = {
    use inventory <- result.try(inventory(connection, config))
    execute(connection, config, inventory, command)
  }
  complete_transaction(connection, outcome)
}

fn fence_transaction(
  connection: sqlight.Connection,
  config: Config,
  original: Validated,
) -> Result(PreparationFence, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = {
    use inventory <- result.try(inventory(connection, config))
    fence_input(connection, config, inventory, original)
  }
  complete_transaction(connection, outcome)
}

fn fence_input(
  connection: sqlight.Connection,
  config: Config,
  inventory: Inventory,
  original: Validated,
) -> Result(PreparationFence, Error) {
  let row = list.find(inventory.rows, fn(row) { row.id == original.id })
  case row, inventory.mode {
    Error(_), SealedScope -> {
      use addresses <- result.try(
        query(connection, sql.resource_address(original.address))
        |> result.replace_error(Corrupt),
      )

      // The scope seal suffices only when neither original identity fence exists.
      case addresses {
        [] -> Ok(ScopeFenced)
        [_] -> Error(Conflict)
        _ -> Error(Corrupt)
      }
    }
    _, _ -> {
      // Reserve shares the complete immutable comparison and missing-row capacity
      // guard. It executes under this same lock, never as a separate actor ask.
      use answer <- result.try(execute(
        connection,
        config,
        inventory,
        Reserve(original),
      ))
      case row {
        Ok(row) if row.phase == 3 || row.phase == 4 ->
          Ok(InputFenced(answer.status))
        Ok(_) | Error(_) -> {
          use Nil <- result.try(phase_change(
            connection,
            sql.fence_resource_preparation(original.id),
            fn(row) { row.phase },
            3,
          ))
          Ok(InputFenced(Unknown(historical(answer.status))))
        }
      }
    }
  }
}

fn input_transaction(
  connection: sqlight.Connection,
  config: Config,
  key: command.ServiceKey,
) -> Result(Input, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = {
    use inventory <- result.try(inventory(connection, config))
    let address =
      bit_array.from_string(
        remote_tool.child_address(command.service_origin(key)),
      )
    use addresses <- result.try(
      query(connection, sql.resource_address(address))
      |> result.replace_error(Corrupt),
    )
    use id <- result.try(case addresses {
      [] -> Error(Missing)
      [sql.ResourceAddress(id)] -> Ok(id)
      _ -> Error(Corrupt)
    })
    use row <- result.try(
      list.find(inventory.rows, fn(row) { row.id == id })
      |> result.replace_error(Corrupt),
    )
    use checked <- result.try(checked_row(connection, config, row))
    let original = checked.1.original

    // A changed key reaches this same logical slot and must not borrow its body.
    case original.key == key && checked.1.address == address {
      True -> Ok(original)
      False -> Error(Conflict)
    }
  }
  complete_transaction(connection, outcome)
}

fn metadata_transaction(
  connection: sqlight.Connection,
  config: Config,
  command: MetadataCommand,
) -> Result(ScopeMode, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = {
    use inventory <- result.try(inventory(connection, config))
    case command, inventory.mode {
      ObserveMode, mode -> Ok(mode)
      SealScope, SealedScope -> Ok(SealedScope)
      SealScope, Open -> {
        use Nil <- result.try(phase_change(
          connection,
          sql.seal_resources(),
          fn(row) { row.mode },
          1,
        ))
        Ok(SealedScope)
      }
    }
  }
  complete_transaction(connection, outcome)
}

fn require_open(mode: ScopeMode) -> Result(Nil, Error) {
  case mode {
    Open -> Ok(Nil)
    SealedScope -> Error(Sealed)
  }
}

fn command_input(command: Command) -> Validated {
  case command {
    Reserve(original)
    | Inspect(original)
    | TakeClaim(original)
    | AdmitFirst(original)
    | CommitReady(original, _)
    | LoseResources(original)
    | RetireResources(original) -> original
  }
}

fn execute(
  connection: sqlight.Connection,
  config: Config,
  inventory: Inventory,
  command: Command,
) -> Result(Answer, Error) {
  let original = command_input(command)
  case list.find(inventory.rows, fn(row) { row.id == original.id }) {
    Error(_) -> {
      use addresses <- result.try(
        query(connection, sql.resource_address(original.address))
        |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(case addresses {
        [] -> Ok(Nil)
        _ -> Error(Conflict)
      })
      case command {
        AdmitFirst(_) -> {
          use Nil <- result.try(require_open(inventory.mode))
          use _ <- result.try(insert(
            connection,
            config,
            inventory.rows,
            original,
          ))
          use Nil <- result.try(phase_change(
            connection,
            sql.claim_resource(original.id),
            fn(row) { row.phase },
            1,
          ))
          Ok(Answer(Unknown(None), Granted))
        }
        Reserve(_) -> {
          use Nil <- result.try(require_open(inventory.mode))
          insert(connection, config, inventory.rows, original)
        }
        Inspect(_)
        | TakeClaim(_)
        | CommitReady(_, _)
        | LoseResources(_)
        | RetireResources(_) -> Error(Missing)
      }
    }
    Ok(row) -> {
      use status <- result.try(retained(connection, config, row))
      use bodies <- result.try(
        query(connection, sql.resource_bodies(row.id))
        |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(case bodies {
        [body]
          if body.input == original.original.body
          && body.service_header == original.header
          && body.address == original.address
        -> Ok(Nil)
        _ -> Error(Conflict)
      })
      transition(
        connection,
        config.enrolled,
        inventory.mode,
        row,
        status,
        command,
      )
    }
  }
}

fn insert(
  connection: sqlight.Connection,
  config: Config,
  rows: List(sql.ResourceHeaders),
  original: Validated,
) -> Result(Answer, Error) {
  let reserved = list.fold(rows, 0, fn(total, row) { total + reservation(row) })
  let required =
    bit_array.byte_size(original.address)
    + bit_array.byte_size(original.header)
    + bit_array.byte_size(original.original.body)
    + 663_826
  use Nil <- result.try(
    case
      list.drop(rows, config.limits.rows - 1) == []
      && reserved + required <= config.limits.bytes
    {
      True -> Ok(Nil)
      False -> Error(Capacity)
    },
  )
  use inserted <- result.try(query(
    connection,
    sql.insert_resource(
      original.id,
      original.address,
      original.header,
      original.role,
      original.digest,
      bit_array.byte_size(original.original.body),
      original.original.body,
    ),
  ))
  use Nil <- result.try(case inserted {
    [sql.InsertResource(id)] if id == original.id -> Ok(Nil)
    _ -> Error(Uncertain)
  })
  Ok(Answer(Reserved, Withheld))
}

fn transition(
  connection: sqlight.Connection,
  enrolled: enrollment.SessionEnrollment,
  mode: ScopeMode,
  row: sql.ResourceHeaders,
  status: Status,
  command: Command,
) -> Result(Answer, Error) {
  case command, status {
    TakeClaim(_), Reserved -> {
      use Nil <- result.try(require_open(mode))
      use Nil <- result.try(phase_change(
        connection,
        sql.claim_resource(row.id),
        fn(row) { row.phase },
        1,
      ))
      Ok(Answer(Unknown(None), Granted))
    }
    CommitReady(original, bytes), Unknown(None) if row.phase == 1 -> {
      use ready <- result.try(ready_for(enrolled, original, bytes))
      use Nil <- result.try(phase_change(
        connection,
        sql.commit_resource_ready(
          digest(bytes),
          bit_array.byte_size(bytes),
          bytes,
          row.id,
        ),
        fn(row) { row.phase },
        2,
      ))
      Ok(Answer(Prepared(ready), Withheld))
    }
    CommitReady(_, bytes), Prepared(ready) -> {
      use original <- result.try(
        resources.encode(ready) |> result.replace_error(Corrupt),
      )
      case bytes == original {
        True -> Ok(Answer(status, Withheld))
        False -> Error(Conflict)
      }
    }
    CommitReady(_, _), _ -> Error(Conflict)
    LoseResources(_), Unknown(_) if row.phase == 3 ->
      Ok(Answer(status, Withheld))
    LoseResources(_), Unknown(_) | LoseResources(_), Prepared(_) -> {
      use Nil <- result.try(phase_change(
        connection,
        sql.mark_resource_unknown(row.id),
        fn(row) { row.phase },
        3,
      ))
      Ok(Answer(Unknown(historical(status)), Withheld))
    }
    LoseResources(_), Released(_) -> Ok(Answer(status, Withheld))
    LoseResources(_), Reserved -> Error(Conflict)
    RetireResources(_), Released(_) -> Ok(Answer(status, Withheld))
    RetireResources(_), Reserved -> Error(Conflict)
    RetireResources(_), _ -> {
      use Nil <- result.try(phase_change(
        connection,
        sql.release_resource(row.id),
        fn(row) { row.phase },
        4,
      ))
      Ok(Answer(Released(historical(status)), Withheld))
    }
    Reserve(_), _ | Inspect(_), _ | TakeClaim(_), _ | AdmitFirst(_), _ ->
      Ok(Answer(status, Withheld))
  }
}

fn historical(status: Status) -> Option(resources.Ready) {
  case status {
    Reserved -> None
    Unknown(ready) | Released(ready) -> ready
    Prepared(ready) -> Some(ready)
  }
}

fn custody_request(
  connection: sqlight.Connection,
  config: Config,
  command: CustodyCommand,
) -> Result(CustodyAnswer, Error) {
  use first <- result.try(custody_transaction(connection, config, command, None))
  case first {
    NeedReadback -> {
      // Only new positive facts need another actor; no resource writer lock is held.
      use readback <- result.try(read_for_command(config, command))
      custody_transaction(connection, config, command, Some(readback))
    }
    NativeAnswer(_)
    | CompileAnswer(_)
    | RetainedAnswer(_)
    | LaunchAnswer(_, _, _) -> Ok(first)
  }
}

fn custody_transaction(
  connection: sqlight.Connection,
  config: Config,
  command: CustodyCommand,
  readback: Option(NativeReadback),
) -> Result(CustodyAnswer, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> sql_error,
  )
  let outcome = {
    use inventory <- result.try(inventory(connection, config))
    let original = custody_original(command)
    use row <- result.try(
      list.find(inventory.rows, fn(row) { row.id == original.id })
      |> result.replace_error(Missing),
    )
    use status <- result.try(retained(connection, config, row))
    use bodies <- result.try(
      query(connection, sql.resource_bodies(row.id))
      |> result.replace_error(Corrupt),
    )
    use body <- result.try(case bodies {
      [body]
        if body.input == original.original.body
        && body.service_header == original.header
        && body.address == original.address
      -> Ok(body)
      [_] -> Error(Conflict)
      _ -> Error(Corrupt)
    })
    use custody <- result.try(checked_custody(
      config.enrolled,
      original,
      row,
      body,
      status,
    ))
    custody_transition(
      connection,
      config,
      inventory.mode,
      row,
      status,
      custody,
      command,
      readback,
    )
  }
  complete_transaction(connection, outcome)
}

fn custody_original(command: CustodyCommand) -> Validated {
  case command {
    ObserveNative(original)
    | AssociateNative(original, _, _, _)
    | AssociateLiveNative(original, _, _, _)
    | ObserveCompile(original)
    | SettleCompile(original, _, _)
    | FailPreparation(original, _, _)
    | AcknowledgeCompile(original, _) -> original
  }
}

fn custody_transition(
  connection: sqlight.Connection,
  config: Config,
  mode: ScopeMode,
  row: sql.ResourceHeaders,
  status: Status,
  custody: CustodyRow,
  command: CustodyCommand,
  readback: Option(NativeReadback),
) -> Result(CustodyAnswer, Error) {
  case command {
    ObserveNative(_) -> Ok(NativeAnswer(custody.native))
    ObserveCompile(_) -> Ok(CompileAnswer(custody.compiled))
    AssociateNative(original, ref, key, digest) -> {
      case custody.native {
        Associated(saved_ref, saved_key, saved_digest, _) -> {
          case #(ref, key, digest) == #(saved_ref, saved_key, saved_digest) {
            True -> Ok(NativeAnswer(custody.native))
            False -> Error(Conflict)
          }
        }
        Unassociated ->
          associate_new(
            connection,
            config,
            row,
            status,
            original,
            ref,
            key,
            digest,
            readback,
          )
      }
    }
    AssociateLiveNative(original, ref, key, digest) -> {
      use Nil <- result.try(require_open(mode))
      live_association(
        connection,
        config,
        row,
        status,
        custody.native,
        original,
        ref,
        key,
        digest,
        readback,
      )
    }
    SettleCompile(original, value, bytes) -> {
      case custody.compiled {
        CompileRetained(retained, _) -> exact_retained(retained, bytes)
        CompilePending ->
          settle_new(
            connection,
            row,
            custody.native,
            original,
            value,
            bytes,
            readback,
          )
      }
    }
    FailPreparation(_, value, bytes) -> {
      case custody.compiled {
        CompileRetained(retained, _) -> exact_retained(retained, bytes)
        CompilePending -> {
          use Nil <- result.try(
            case
              row.phase == 1
              && row.ready_size == 0
              && custody.native == Unassociated
              && completion.native_association(value) == None
            {
              True -> Ok(Nil)
              False -> Error(Conflict)
            },
          )
          use retained <- result.try(retain_value(value, bytes))
          use Nil <- result.try(blob_change(
            connection,
            sql.fail_resource_preparation(
              identity.digest_bytes(retained.digest),
              bytes,
              row.id,
            ),
            fn(row) { row.completion_digest },
            identity.digest_bytes(retained.digest),
          ))
          Ok(RetainedAnswer(retained))
        }
      }
    }
    AcknowledgeCompile(_, digest) -> {
      case custody.compiled {
        CompilePending -> Error(Missing)
        CompileRetained(retained, receipt) -> {
          use Nil <- result.try(case retained.digest == digest {
            True -> Ok(Nil)
            False -> Error(Conflict)
          })
          use Nil <- result.try(case receipt {
            ReceiptAcknowledged -> Ok(Nil)
            ReceiptPending ->
              phase_change(
                connection,
                sql.acknowledge_resource_compile(
                  row.id,
                  identity.digest_bytes(digest),
                ),
                fn(row) { row.outer_receipt },
                1,
              )
          })
          Ok(CompileAnswer(CompileRetained(retained, ReceiptAcknowledged)))
        }
      }
    }
  }
}

fn live_association(
  connection: sqlight.Connection,
  config: Config,
  row: sql.ResourceHeaders,
  status: Status,
  native: NativeStatus,
  original: Validated,
  ref: command.CommandRef,
  key: identity.RequestKey,
  digest: identity.Digest,
  readback: Option(NativeReadback),
) -> Result(CustodyAnswer, Error) {
  // The immutable association is the durable one-shot admission fence. Historical
  // duplicates cannot reconstruct a launch continuation after a lost commit reply.
  use Nil <- result.try(case row.phase == 2 && native == Unassociated {
    True -> Ok(Nil)
    False -> Error(Conflict)
  })
  use Nil <- result.try(case readback {
    None -> Ok(Nil)
    Some(material) -> live_authority(material)
  })
  use answer <- result.try(associate_new(
    connection,
    config,
    row,
    status,
    original,
    ref,
    key,
    digest,
    readback,
  ))
  case answer {
    NeedReadback -> Ok(NeedReadback)
    NativeAnswer(Associated(ref, key, digest, _)) ->
      Ok(LaunchAnswer(ref, key, digest))
    NativeAnswer(Unassociated)
    | CompileAnswer(_)
    | RetainedAnswer(_)
    | LaunchAnswer(_, _, _) -> Error(Corrupt)
  }
}

fn live_authority(material: NativeReadback) -> Result(Nil, Error) {
  use bytes <- result.try(option.to_result(material.authority, Conflict))
  use value <- result.try(
    wire.decode_value(bytes) |> result.replace_error(Conflict),
  )
  use canonical <- result.try(
    wire.encode_value(value) |> result.replace_error(Conflict),
  )

  // The native actor supplied the absolute deadline in its own clock era. It may
  // be negative; only the original native continuation can judge its expiration.
  case material.prepared.lifetime, value {
    wire.Finite(ceiling),
      mp.ArrayValue([
        mp.IntValue(generation),
        mp.IntValue(deadline),
        mp.IntValue(budget),
      ])
      if canonical == bytes
      && generation > 0
      && generation <= 2_147_483_647
      && deadline != 0
      && budget >= 1000
      && budget < ceiling
    -> Ok(Nil)
    _, _ -> Error(Conflict)
  }
}

fn exact_retained(
  retained: RetainedCompile,
  bytes: BitArray,
) -> Result(CustodyAnswer, Error) {
  case retained.bytes == bytes {
    True -> Ok(RetainedAnswer(retained))
    False -> Error(Conflict)
  }
}

fn associate_new(
  connection: sqlight.Connection,
  config: Config,
  row: sql.ResourceHeaders,
  status: Status,
  original: Validated,
  ref: command.CommandRef,
  key: identity.RequestKey,
  digest: identity.Digest,
  readback: Option(NativeReadback),
) -> Result(CustodyAnswer, Error) {
  use Nil <- result.try(case historical(status) {
    Some(resources.CompileReady(_)) if row.completion_size == 0 -> Ok(Nil)
    Some(resources.LaunchReady(_)) -> Error(UnsupportedRole)
    _ -> Error(Conflict)
  })
  case readback {
    None -> Ok(NeedReadback)
    Some(material) -> {
      use prepared <- result.try(native_template(
        config.enrolled,
        original,
        status,
        ref,
        key,
        digest,
        material.bytes,
      ))
      let id = native_id(key)
      use owners <- result.try(
        query(connection, sql.resource_native_owner(Some(id)))
        |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(case owners {
        [] -> Ok(Nil)
        _ -> Error(Conflict)
      })
      let encoded = journal_codec.encode(journal_codec.Admit(key, digest))
      use Nil <- result.try(case bit_array.byte_size(encoded) == 106 {
        True -> Ok(Nil)
        False -> Error(Corrupt)
      })
      use Nil <- result.try(blob_change(
        connection,
        sql.associate_resource_native(
          ref_bytes(ref),
          Some(id),
          encoded,
          material.bytes,
          row.id,
        ),
        fn(row) { option.lazy_unwrap(row.native_id, fn() { <<>> }) },
        id,
      ))
      Ok(NativeAnswer(Associated(ref, key, digest, prepared)))
    }
  }
}

fn settle_new(
  connection: sqlight.Connection,
  row: sql.ResourceHeaders,
  native: NativeStatus,
  original: Validated,
  value: completion.CompileCompletion,
  bytes: BitArray,
  readback: Option(NativeReadback),
) -> Result(CustodyAnswer, Error) {
  use association <- result.try(matching_completion(native, value))
  case readback {
    None -> Ok(NeedReadback)
    Some(material) -> {
      use Nil <- result.try(case native {
        Associated(_, _, _, prepared) if prepared == material.prepared -> Ok(Nil)
        _ -> Error(Conflict)
      })
      use Nil <- result.try(case material.terminal {
        Some(terminal) if terminal == association.terminal -> Ok(Nil)
        _ -> Error(Conflict)
      })
      use terminal_digest <- result.try(
        wire.digest(association.terminal) |> result.replace_error(InvalidInput),
      )

      // Terminal bytes can precede reducer settlement; matching committed phase is required.
      use Nil <- result.try(case admission.phase(material.evidence) {
        admission.Terminal(saved, _, _)
          | admission.Refused(saved, _)
          | admission.Retired(saved)
          | admission.RetiredRefusal(saved)
          if saved == terminal_digest
        -> Ok(Nil)
        _ -> Error(Conflict)
      })
      use Nil <- result.try(
        case completion.original(value) == original.original.key {
          True -> Ok(Nil)
          False -> Error(Conflict)
        },
      )
      use retained <- result.try(retain_value(value, bytes))
      use Nil <- result.try(blob_change(
        connection,
        sql.commit_resource_compile(
          identity.digest_bytes(retained.digest),
          bytes,
          row.id,
        ),
        fn(row) { row.completion_digest },
        identity.digest_bytes(retained.digest),
      ))
      Ok(RetainedAnswer(retained))
    }
  }
}

fn matching_completion(
  native: NativeStatus,
  value: completion.CompileCompletion,
) -> Result(completion.NativeAssociation, Error) {
  case native, completion.native_association(value) {
    Associated(_, key, digest, _), Some(association)
      if key == association.key && digest == association.digest
    -> Ok(association)
    _, _ -> Error(Conflict)
  }
}

fn retain_value(
  value: completion.CompileCompletion,
  bytes: BitArray,
) -> Result(RetainedCompile, Error) {
  use hash <- result.try(wire.digest(bytes) |> result.replace_error(Corrupt))
  Ok(RetainedCompile(value, bytes, hash))
}

fn read_for_command(
  config: Config,
  command: CustodyCommand,
) -> Result(NativeReadback, Error) {
  case command {
    AssociateNative(_, _, key, digest)
    | AssociateLiveNative(_, _, key, digest) ->
      native_readback(config.native, key, digest)
    SettleCompile(_, value, _) -> {
      use association <- result.try(case completion.native_association(value) {
        Some(value) -> Ok(value)
        None -> Error(Conflict)
      })
      native_readback(config.native, association.key, association.digest)
    }
    ObserveNative(_)
    | ObserveCompile(_)
    | FailPreparation(_, _, _)
    | AcknowledgeCompile(_, _) -> Error(Corrupt)
  }
}

fn native_readback(
  book: native_journal.Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(NativeReadback, Error) {
  use items <- result.try(
    native_journal.payloads(book, key, digest)
    |> result.replace_error(Uncertain),
  )
  use request <- result.try(
    list.find(items, fn(item) {
      case item {
        payload.Request(_) -> True
        payload.Authority(_)
        | payload.Output(_, _)
        | payload.Terminal(_)
        | payload.Cancellation(_) -> False
      }
    })
    |> result.replace_error(Conflict),
  )
  use bytes <- result.try(case request {
    payload.Request(bytes) -> Ok(bytes)
    payload.Authority(_)
    | payload.Output(_, _)
    | payload.Terminal(_)
    | payload.Cancellation(_) -> Error(Conflict)
  })
  use prepared <- result.try(
    wire.decode_prepared(bytes) |> result.replace_error(InvalidInput),
  )
  use canonical <- result.try(
    wire.encode_prepared(prepared) |> result.replace_error(InvalidInput),
  )
  use computed <- result.try(
    wire.prepared_digest(prepared) |> result.replace_error(InvalidInput),
  )
  use Nil <- result.try(case canonical == bytes && computed == digest {
    True -> Ok(Nil)
    False -> Error(Conflict)
  })

  // Payload retention can precede Admit; only the actual journal supplies this fact.
  use evidence <- result.try(
    native_journal.inspect(book, key, digest)
    |> result.map_error(fn(error) {
      case error {
        native_journal.Rejected(_) -> Conflict
        _ -> Uncertain
      }
    }),
  )
  let terminal =
    list.find(items, fn(item) {
      case item {
        payload.Terminal(_) -> True
        payload.Authority(_)
        | payload.Output(_, _)
        | payload.Request(_)
        | payload.Cancellation(_) -> False
      }
    })
    |> option.from_result
    |> option_terminal
  let authority =
    list.find_map(items, fn(item) {
      case item {
        payload.Authority(bytes) -> Ok(bytes)
        payload.Request(_)
        | payload.Output(_, _)
        | payload.Terminal(_)
        | payload.Cancellation(_) -> Error(Nil)
      }
    })
    |> option.from_result
  Ok(NativeReadback(prepared, bytes, evidence, authority, terminal))
}

fn option_terminal(value: Option(payload.Item)) -> Option(BitArray) {
  case value {
    Some(payload.Terminal(bytes)) -> Some(bytes)
    _ -> None
  }
}

fn checked_custody(
  enrolled: enrollment.SessionEnrollment,
  original: Validated,
  row: sql.ResourceHeaders,
  body: sql.ResourceBodies,
  status: Status,
) -> Result(CustodyRow, Error) {
  use Nil <- result.try(
    case
      bit_array.byte_size(body.command_ref) == row.ref_size
      && bit_array.byte_size(body.native_identity) == row.identity_size
      && bit_array.byte_size(body.native_prepared) == row.prepared_size
      && bit_array.byte_size(body.completion) == row.completion_size
    {
      True -> Ok(Nil)
      False -> Error(Corrupt)
    },
  )
  use native <- result.try(case body.native_identity {
    <<>> -> Ok(Unassociated)
    record -> {
      use scope <- result.try(native_scope(enrolled))
      use decoded <- result.try(
        journal_codec.decode(record, scope) |> result.replace_error(Corrupt),
      )
      use pair <- result.try(case decoded {
        journal_codec.Admit(key, digest) -> Ok(#(key, digest))
        journal_codec.Apply(_, _, _) | journal_codec.CloseEpoch ->
          Error(Corrupt)
      })
      use Nil <- result.try(
        case
          native_id(pair.0) == row.native_id
          && journal_codec.encode(decoded) == record
          && original.role == 0
        {
          True -> Ok(Nil)
          False -> Error(Corrupt)
        },
      )
      use ref <- result.try(decode_ref(body.command_ref))
      use prepared <- result.try(
        native_template(
          enrolled,
          original,
          status,
          ref,
          pair.0,
          pair.1,
          body.native_prepared,
        )
        |> result.replace_error(Corrupt),
      )
      Ok(Associated(ref, pair.0, pair.1, prepared))
    }
  })
  use compiled <- result.try(case body.completion {
    <<>> -> Ok(CompilePending)
    bytes -> {
      use Nil <- result.try(
        case original.role == 0 && digest(bytes) == row.completion_digest {
          True -> Ok(Nil)
          False -> Error(Corrupt)
        },
      )
      use value <- result.try(
        completion.decode(enrolled, original.original.key, bytes)
        |> result.replace_error(Corrupt),
      )
      use Nil <- result.try(case native, completion.native_association(value) {
        Unassociated, None
          if row.ready_size == 0
          && row.phase == 3
          || row.ready_size == 0
          && row.phase == 4
        -> Ok(Nil)
        Associated(_, _, _, _), Some(_) ->
          matching_completion(native, value)
          |> result.replace(Nil)
          |> result.replace_error(Corrupt)
        _, _ -> Error(Corrupt)
      })
      use receipt <- result.try(case row.outer_receipt {
        0 -> Ok(ReceiptPending)
        1 -> Ok(ReceiptAcknowledged)
        _ -> Error(Corrupt)
      })
      use retained <- result.try(retain_value(value, bytes))
      Ok(CompileRetained(retained, receipt))
    }
  })
  Ok(CustodyRow(native, compiled))
}

fn native_template(
  enrolled: enrollment.SessionEnrollment,
  original: Validated,
  status: Status,
  ref: command.CommandRef,
  key: identity.RequestKey,
  digest: identity.Digest,
  bytes: BitArray,
) -> Result(wire.Prepared, Error) {
  use locations <- result.try(case historical(status) {
    Some(resources.CompileReady(locations)) -> Ok(locations)
    _ -> Error(Conflict)
  })
  use prepared <- result.try(
    wire.decode_prepared(bytes) |> result.replace_error(InvalidInput),
  )
  use canonical <- result.try(
    wire.encode_prepared(prepared) |> result.replace_error(InvalidInput),
  )
  use hash <- result.try(
    wire.prepared_digest(prepared) |> result.replace_error(InvalidInput),
  )
  use scope <- result.try(native_scope(enrolled))
  let #(operation, step) = #(
    command.coordinates(original.original.key).1,
    command.coordinates(original.original.key).2,
  )
  let #(native_operation, _) = identity.key_fields(key)
  let #(registration, _) = enrollment.digests(enrolled)
  use Nil <- result.try(
    case
      canonical == bytes
      && bit_array.byte_size(bytes) <= 131_072
      && hash == digest
      && identity.key_scope(key) == scope
      && native_operation == ids.op_id_to_string(operation)
      && prepared.step == workspace.step_string(step)
      && string.lowercase(
        bit_array.base16_encode(identity.digest_bytes(prepared.registration)),
      )
      == registration
      && prepared.stream == wire.Logs
    {
      True -> Ok(Nil)
      False -> Error(Conflict)
    },
  )
  use actual <- result.try(case prepared.request.policy {
    Some(policy) -> Ok(policy)
    None -> Error(InvalidInput)
  })
  use Nil <- result.try(
    policy.validate(actual) |> result.replace_error(InvalidInput),
  )
  use Nil <- result.try(case prepared.lifetime {
    wire.Finite(ms) if ms >= actual.limits.wall_s * 1000 -> Ok(Nil)
    _ -> Error(Conflict)
  })
  use original_input <- result.try(
    input.decode_compile(original.original.body)
    |> result.replace_error(InvalidInput),
  )
  use expected <- result.try(
    service_command.compile_from_input(
      enrolled,
      original.original.key,
      original_input,
      locations,
      actual.limits.wall_s,
    )
    |> result.replace_error(Conflict),
  )
  let proposal = service_command.offer(expected)
  let data = offer.data(proposal)

  // The pure meet admits narrowing and added protections without re-running clearance.
  let #(bounded, _) = policy.compose(data.requirements, actual, [])
  use Nil <- result.try(
    case
      ref == offer.reference(proposal)
      && prepared.request.argv == data.argv
      && prepared.request.env == data.env
      && prepared.request.cwd == data.cwd
      && normalize_policy(bounded) == normalize_policy(actual)
    {
      True -> Ok(Nil)
      False -> Error(Conflict)
    },
  )
  Ok(prepared)
}

fn normalize_policy(value: policy.SandboxPolicy) -> policy.SandboxPolicy {
  // Composition may reorder only these semantically unordered policy dimensions.
  policy.SandboxPolicy(
    ..value,
    protected: list.sort(value.protected, string.compare),
    env_allow: list.sort(value.env_allow, string.compare),
  )
}

fn native_scope(
  enrolled: enrollment.SessionEnrollment,
) -> Result(identity.Scope, Error) {
  let #(session, binding) =
    workspace.scope_fields(enrollment.native_facts(enrolled).scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, name) = workspace.selector_fields(selector)
  use name <- result.try(
    identity.workspace_id(name) |> result.replace_error(BindingMismatch),
  )
  use executor <- result.try(
    identity.executor_id(executor) |> result.replace_error(BindingMismatch),
  )
  use session_epoch <- result.try(
    identity.epoch(session_epoch) |> result.replace_error(BindingMismatch),
  )
  use workspace_epoch <- result.try(
    identity.epoch(workspace_epoch) |> result.replace_error(BindingMismatch),
  )
  Ok(identity.scope(session, name, executor, session_epoch, workspace_epoch))
}

fn native_id(key: identity.RequestKey) -> BitArray {
  bit_array.from_string(identity.key_fields(key).1)
}

fn ref_bytes(ref: command.CommandRef) -> BitArray {
  command.encode_ref(ref) |> json.to_string |> bit_array.from_string
}

fn decode_ref(bytes: BitArray) -> Result(command.CommandRef, Error) {
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(Corrupt),
  )
  use value <- result.try(json.parse(text) |> result.replace_error(Corrupt))
  use ref <- result.try(
    command.decode_ref(value) |> result.replace_error(Corrupt),
  )
  case ref_bytes(ref) == bytes {
    True -> Ok(ref)
    False -> Error(Corrupt)
  }
}

fn blob_change(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
  field: fn(a) -> BitArray,
  expected: BitArray,
) -> Result(Nil, Error) {
  use rows <- result.try(query(connection, generated))
  case rows {
    [row] ->
      case field(row) == expected {
        True -> Ok(Nil)
        False -> Error(Uncertain)
      }
    _ -> Error(Uncertain)
  }
}

fn phase_change(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
  phase: fn(a) -> Int,
  expected: Int,
) -> Result(Nil, Error) {
  use rows <- result.try(query(connection, generated))
  case rows {
    [row] -> {
      case phase(row) == expected {
        True -> Ok(Nil)
        False -> Error(Uncertain)
      }
    }
    _ -> Error(Uncertain)
  }
}

fn complete_transaction(
  connection: sqlight.Connection,
  outcome: Result(a, Error),
) -> Result(a, Error) {
  case outcome {
    Ok(value) -> {
      use Nil <- result.try(sqlight.exec("COMMIT", connection) |> sql_error)
      Ok(value)
    }
    Error(error) -> {
      case sqlight.exec("ROLLBACK", connection) {
        Ok(Nil) -> Error(error)
        Error(_) -> Error(Uncertain)
      }
    }
  }
}

fn statement(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param)),
) -> Result(Nil, Error) {
  let #(text, parameters) = generated
  query(connection, #(text, parameters, decode.success(Nil)))
  |> result.replace(Nil)
}

fn query(
  connection: sqlight.Connection,
  generated: #(String, List(dev.Param), decode.Decoder(a)),
) -> Result(List(a), Error) {
  let #(text, parameters, decoder) = generated
  use arguments <- result.try(
    list.try_map(parameters, fn(value) {
      case value {
        dev.ParamInt(value) -> Ok(sqlight.int(value))
        dev.ParamBitArray(value) -> Ok(sqlight.blob(value))
        dev.ParamNullable(Some(dev.ParamBitArray(value))) ->
          Ok(sqlight.blob(value))
        dev.ParamString(_)
        | dev.ParamFloat(_)
        | dev.ParamBool(_)
        | dev.ParamTimestamp(_)
        | dev.ParamDate(_)
        | dev.ParamList(_)
        | dev.ParamDynamic(_)
        | dev.ParamNullable(_) -> Error(Uncertain)
      }
    }),
  )
  sqlight.query(text, connection, arguments, decoder) |> sql_error
}

fn sql_error(value: Result(a, sqlight.Error)) -> Result(a, Error) {
  result.replace_error(value, Uncertain)
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  case state {
    Ready(_, connection) -> {
      let _ = sqlight.close(connection)
      Nil
    }
    Waiting(_) -> Nil
  }
}

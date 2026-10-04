//// A bounded pure admission book for one executor and authority epoch pair.
////
//// Admission reserves a retained key before it can authorize native work.
//// `reduce` changes Admitted to LaunchIntent exactly once. Recovery of that
//// intent preserves uncertainty: the native action may have happened, so it
//// never returns Launch again. Native retirement and the owner's durable result
//// receipt are independent facts; `Compact` requires both and retains a replay
//// fence for the key. No operation deletes a key or frees a retained slot.
////
//// An Admitted request can instead become Refused, even after epoch closure.
//// That phase proves NativeRetired because no launch intent ever existed, but
//// still requires a durable owner receipt. RetiredRefusal preserves this origin
//// after compaction; launched work can never acquire refusal evidence.
////
//// ## Adapter effect order
////
//// A durable adapter must serialize all decisions against the latest committed
//// book, or use a successful compare-and-swap. It must persist every returned
//// `next` state BEFORE acknowledging admission or a result, or performing Launch.
//// Transition values are ordinary duplicable values, not linear launch tokens.
//// The adapter must perform a successful transition's Launch at most once and
//// must never replay stored effects on recovery. A crash after persisting intent
//// but before launching sacrifices liveness to preserve at-most-once execution.
////
//// The adapter supplies authenticated authority and native retirement evidence.
//// A connection drop supplies neither a terminal result nor retirement. An owner
//// receipt is submitted only after the exact result is durably committed there.
//// `new` is for an unused scope; reinitializing a previously used scope loses its
//// replay fences. Disposal of a whole book requires a permanent durable closure
//// fence and settled custody/receipts outside this module. Closed scopes cannot
//// reopen. There is no codec, persistence, network or local Dispatcher wiring.

import executor/remote/identity
import gleam/dict.{type Dict}
import gleam/result

/// The lifetime bound on retained keys, including compacted replay fences.
pub opaque type Capacity {
  /// A validated value in 1..65536.
  Capacity(
    /// The maximum retained-key count, including compacted fences.
    value: Int,
  )
}

/// An immutable book for one exact binding, with no reopening or deletion API.
pub opaque type Book {
  /// Only module transitions can construct admitted records.
  Book(
    /// The complete authority binding validated for every request.
    scope: identity.Scope,
    /// The maximum retained-key count, not the number currently running.
    capacity: Capacity,
    /// Whether new admissions and first launches remain authorized.
    gate: Gate,
    /// Every accepted key remains until the whole epoch is permanently fenced.
    records: Dict(identity.RequestKey, Evidence),
  )
}

type Gate {
  Open
  Closed
}

/// Whether native work is proven absent, independently of its terminal result.
pub type NativeCustody {
  /// Native work may remain; disconnection cannot change this fact.
  NativeUnconfirmed

  /// Native work is proven absent; pre-launch refusal establishes this directly.
  NativeRetired
}

/// Whether the owner has durably committed the exact terminal result.
pub type OwnerReceipt {
  /// A delivered result or volatile acknowledgement is insufficient.
  ReceiptPending

  /// The adapter has confirmed the owner's durable result receipt.
  ReceiptDurable
}

/// Read-only lifecycle evidence; constructing a phase cannot change a book.
pub type Phase {
  /// Capacity is reserved and a first launch may be authorized while open.
  Admitted

  /// Launch was authorized; native action may have happened, even after restart.
  LaunchIntent(
    /// Retirement can be observed before the terminal result arrives.
    custody: NativeCustody,
  )

  /// A definite refusal before launch intent; NativeRetired holds by construction.
  Refused(
    /// Fixed-size evidence naming the adapter's retained refusal result.
    result_digest: identity.Digest,
    /// Whether the owner durably committed this exact refusal.
    receipt: OwnerReceipt,
  )

  /// One fixed launched-work result, with two obligations before compaction.
  Terminal(
    /// Fixed-size evidence naming the adapter's retained result.
    result_digest: identity.Digest,
    /// Whether native work is proven retired.
    custody: NativeCustody,
    /// Whether the owner durably committed this exact result.
    receipt: OwnerReceipt,
  )

  /// Both obligations held; the bounded key and digests remain as replay fences.
  Retired(
    /// Retained to detect conflicting terminal and receipt retries.
    result_digest: identity.Digest,
  )

  /// A compacted refusal retains its origin so launched results cannot mimic it.
  RetiredRefusal(
    /// Retained to detect conflicting refusal and receipt retries.
    result_digest: identity.Digest,
  )
}

/// An admitted request's exact digest and lifecycle, constructed only by the book.
pub opaque type Evidence {
  /// A bounded record that never stores arbitrary result or command payloads.
  Evidence(
    /// The stable key to which this evidence belongs.
    key: identity.RequestKey,
    /// The original canonical command/policy/input digest.
    request_digest: identity.Digest,
    /// The lifecycle and its independent custody/receipt obligations.
    phase: Phase,
  )
}

/// A pure observation or authorization applied to an already admitted key.
pub type Event {
  /// Request the first native launch; a recovered intent never launches again.
  AuthorizeLaunch

  /// Settle an Admitted request without launch, including under a closed epoch.
  /// Once launch intent exists, even recovered intent, this event is refused.
  RefuseBeforeLaunch(
    /// Digest naming the exact refusal result the adapter durably retains.
    result_digest: identity.Digest,
  )

  /// Observe one fixed result for authorized work; it does not prove retirement.
  ObserveTerminal(
    /// Digest naming the exact result the adapter durably retains.
    result_digest: identity.Digest,
  )

  /// Confirm native retirement from affirmative evidence, never connection loss.
  ConfirmRetirement

  /// Confirm that the owner already durably committed the exact result.
  ConfirmOwnerReceipt(
    /// Must match the book's terminal result digest.
    result_digest: identity.Digest,
  )

  /// Compact only settled evidence into a retained replay fence.
  Compact
}

/// Native actions permitted after the corresponding next state is committed.
pub type Effect {
  /// Inspection, duplicate processing and settlement authorize no native launch.
  NoLaunch

  /// Perform this key's first launch once, after persisting LaunchIntent.
  Launch(
    /// The exact logical request to launch; no lookup through a mutable route.
    key: identity.RequestKey,
  )
}

/// One decision and its required persistence order; this value is not linear.
pub type Transition {
  /// Commit `next` before acknowledgements or effects; serialize against old state.
  Transition(
    /// The complete successor book, including any launch or replay fence.
    next: Book,
    /// Existing or updated evidence for the exact requested key.
    evidence: Evidence,
    /// The native authorization, performed at most once after commit.
    effect: Effect,
  )
}

/// Named refusals retain no caller-controlled diagnostic strings.
pub type AdmissionError {
  /// Capacity construction was outside 1..65536.
  CapacityRange

  /// Session, workspace, executor or either epoch differs from the book.
  ScopeMismatch

  /// A retained key was retried with changed command/policy/input evidence.
  RequestConflict

  /// A new key or an unlaunched admission cannot begin under a closed epoch.
  EpochClosed

  /// All retained slots are reserved; compaction does not release them.
  Saturated

  /// A lifecycle event named a key never admitted in this book.
  UnknownRequest

  /// A result or retirement was reported before launch authorization.
  NotLaunched

  /// Launch was already authorized; work may have run, so refusal is unsafe.
  LaunchAlreadyAuthorized

  /// A terminal, refusal or receipt contradicts the fixed result digest.
  ResultConflict

  /// An owner receipt arrived before any terminal result was recorded.
  MissingTerminal

  /// Compaction lacks a terminal result, native retirement or durable receipt.
  NotForgettable
}

type Authorization {
  NoAuthorization
  FirstAuthorization
}

/// Validates the lifetime bound on retained keys, before constructing a book.
///
/// ## Examples
///
/// ```gleam
/// assert admission.capacity(1) |> result.is_ok
/// assert admission.capacity(0) == Error(admission.CapacityRange)
/// ```
pub fn capacity(value: Int) -> Result(Capacity, AdmissionError) {
  case value >= 1 && value <= 65_536 {
    True -> Ok(Capacity(value))
    False -> Error(CapacityRange)
  }
}

/// Creates an empty book for an unused authenticated scope. The adapter must
/// never use this function to recover or reopen a previously used scope.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(workspace) = identity.workspace_id("loom")
/// let assert Ok(executor) = identity.executor_id("dev")
/// let assert Ok(epoch) = identity.epoch(1)
/// let scope = identity.scope(session, workspace, executor, epoch, epoch)
/// let assert Ok(bound) = admission.capacity(1)
/// assert admission.retained_count(admission.new(scope, bound)) == 0
/// ```
pub fn new(scope: identity.Scope, capacity: Capacity) -> Book {
  Book(scope:, capacity:, gate: Open, records: dict.new())
}

/// Reserves a lifetime evidence slot before accepting a new key. Exact retries
/// return current evidence even when closed or saturated. Scope and digest
/// conflicts never change the book. Persist `next` before acknowledging admission.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(workspace) = identity.workspace_id("loom")
/// let assert Ok(executor) = identity.executor_id("dev")
/// let assert Ok(epoch) = identity.epoch(1)
/// let scope = identity.scope(session, workspace, executor, epoch, epoch)
/// let assert Ok(operation) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(request) = identity.request_id("00000000-0000-7000-8000-000000000003")
/// let key = identity.request_key(scope, operation, request)
/// let assert Ok(digest) = identity.digest(<<0:size(256)>>)
/// let assert Ok(capacity) = admission.capacity(1)
/// let book = admission.new(scope, capacity)
/// let assert Ok(first) = admission.admit(book, key, digest)
/// let assert Ok(retry) = admission.admit(first.next, key, digest)
/// assert retry.evidence == first.evidence
/// assert retry.effect == admission.NoLaunch
/// ```
pub fn admit(
  book: Book,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(Transition, AdmissionError) {
  use Nil <- result.try(validate_scope(book, key))

  // Lookup precedes closure and capacity: delayed same-key requests recover
  // evidence rather than losing it to the state of new admission.
  case dict.get(book.records, key) {
    Ok(evidence) -> {
      use Nil <- result.try(validate_digest(evidence, digest))
      Ok(Transition(book, evidence, NoLaunch))
    }
    Error(Nil) -> reserve(book, key, digest)
  }
}

/// Reduces an event against an admitted key. Only an open book's Admitted row
/// can emit Launch; the successor is LaunchIntent before native action occurs.
/// RefuseBeforeLaunch instead settles that row with proven native absence and
/// a pending owner receipt, even after close. Launch intent prevents refusal.
/// Persist `next` before acting or acknowledging. Recovery reuses the book and
/// never re-performs an earlier returned effect.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(workspace) = identity.workspace_id("loom")
/// let assert Ok(executor) = identity.executor_id("dev")
/// let assert Ok(epoch) = identity.epoch(1)
/// let scope = identity.scope(session, workspace, executor, epoch, epoch)
/// let assert Ok(operation) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(request) = identity.request_id("00000000-0000-7000-8000-000000000003")
/// let key = identity.request_key(scope, operation, request)
/// let assert Ok(digest) = identity.digest(<<0:size(256)>>)
/// let assert Ok(capacity) = admission.capacity(1)
/// let book = admission.new(scope, capacity)
/// let assert Ok(accepted) = admission.admit(book, key, digest)
/// let book = accepted.next
/// let assert Ok(first) = admission.reduce(book, key, digest, admission.AuthorizeLaunch)
/// let assert Ok(retry) = admission.reduce(first.next, key, digest, admission.AuthorizeLaunch)
/// assert first.effect == admission.Launch(key)
/// assert retry.effect == admission.NoLaunch
/// ```
pub fn reduce(
  book: Book,
  key: identity.RequestKey,
  digest: identity.Digest,
  event: Event,
) -> Result(Transition, AdmissionError) {
  use evidence <- result.try(inspect(book, key, digest))
  use changed <- result.try(apply_event(book.gate, evidence.phase, event))
  let #(phase, effect) = changed
  let updated = Evidence(..evidence, phase:)
  let next = Book(..book, records: dict.insert(book.records, key, updated))
  let effect = case effect {
    NoAuthorization -> NoLaunch
    FirstAuthorization -> Launch(key)
  }
  Ok(Transition(next, updated, effect))
}

/// Retrieves exact evidence without native authorization, including after close.
/// A mismatched scope cannot inspect a row; a changed digest is a conflict.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(workspace) = identity.workspace_id("loom")
/// let assert Ok(executor) = identity.executor_id("dev")
/// let assert Ok(epoch) = identity.epoch(1)
/// let scope = identity.scope(session, workspace, executor, epoch, epoch)
/// let assert Ok(operation) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(request) = identity.request_id("00000000-0000-7000-8000-000000000003")
/// let key = identity.request_key(scope, operation, request)
/// let assert Ok(digest) = identity.digest(<<0:size(256)>>)
/// let assert Ok(capacity) = admission.capacity(1)
/// let book = admission.new(scope, capacity)
/// let assert Ok(accepted) = admission.admit(book, key, digest)
/// assert admission.inspect(accepted.next, key, digest) == Ok(accepted.evidence)
/// ```
pub fn inspect(
  book: Book,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(Evidence, AdmissionError) {
  use Nil <- result.try(validate_scope(book, key))
  use evidence <- result.try(
    dict.get(book.records, key) |> result.map_error(fn(_) { UnknownRequest }),
  )
  use Nil <- result.try(validate_digest(evidence, digest))
  Ok(evidence)
}

/// Permanently closes new admission and first-launch authorization. Settlement
/// and duplicate inspection remain available. The adapter persists this book
/// before acknowledging closure; disconnection is not a call to `close`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(workspace) = identity.workspace_id("loom")
/// let assert Ok(executor) = identity.executor_id("dev")
/// let assert Ok(epoch) = identity.epoch(1)
/// let scope = identity.scope(session, workspace, executor, epoch, epoch)
/// let assert Ok(operation) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(request) = identity.request_id("00000000-0000-7000-8000-000000000003")
/// let key = identity.request_key(scope, operation, request)
/// let assert Ok(digest) = identity.digest(<<0:size(256)>>)
/// let assert Ok(capacity) = admission.capacity(1)
/// let book = admission.new(scope, capacity)
/// assert admission.close(admission.close(book)) == admission.close(book)
/// ```
pub fn close(book: Book) -> Book {
  Book(..book, gate: Closed)
}

/// Counts lifetime reservations, including Retired replay fences.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(workspace) = identity.workspace_id("loom")
/// let assert Ok(executor) = identity.executor_id("dev")
/// let assert Ok(epoch) = identity.epoch(1)
/// let scope = identity.scope(session, workspace, executor, epoch, epoch)
/// let assert Ok(operation) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(request) = identity.request_id("00000000-0000-7000-8000-000000000003")
/// let key = identity.request_key(scope, operation, request)
/// let assert Ok(digest) = identity.digest(<<0:size(256)>>)
/// let assert Ok(capacity) = admission.capacity(1)
/// let book = admission.new(scope, capacity)
/// let assert Ok(accepted) = admission.admit(book, key, digest)
/// assert admission.retained_count(accepted.next) == 1
/// ```
pub fn retained_count(book: Book) -> Int {
  dict.size(book.records)
}

/// Projects read-only lifecycle evidence; callers cannot inject it into a book.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(workspace) = identity.workspace_id("loom")
/// let assert Ok(executor) = identity.executor_id("dev")
/// let assert Ok(epoch) = identity.epoch(1)
/// let scope = identity.scope(session, workspace, executor, epoch, epoch)
/// let assert Ok(operation) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(request) = identity.request_id("00000000-0000-7000-8000-000000000003")
/// let key = identity.request_key(scope, operation, request)
/// let assert Ok(digest) = identity.digest(<<0:size(256)>>)
/// let assert Ok(capacity) = admission.capacity(1)
/// let book = admission.new(scope, capacity)
/// let assert Ok(accepted) = admission.admit(book, key, digest)
/// assert admission.phase(accepted.evidence) == admission.Admitted
/// ```
pub fn phase(evidence: Evidence) -> Phase {
  evidence.phase
}

fn validate_scope(
  book: Book,
  key: identity.RequestKey,
) -> Result(Nil, AdmissionError) {
  case identity.key_scope(key) == book.scope {
    True -> Ok(Nil)
    False -> Error(ScopeMismatch)
  }
}

fn validate_digest(
  evidence: Evidence,
  digest: identity.Digest,
) -> Result(Nil, AdmissionError) {
  case evidence.request_digest == digest {
    True -> Ok(Nil)
    False -> Error(RequestConflict)
  }
}

fn reserve(
  book: Book,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(Transition, AdmissionError) {
  case book.gate, dict.size(book.records) >= book.capacity.value {
    Closed, _ -> Error(EpochClosed)
    Open, True -> Error(Saturated)
    Open, False -> {
      let evidence = Evidence(key, digest, Admitted)
      let next = Book(..book, records: dict.insert(book.records, key, evidence))
      Ok(Transition(next, evidence, NoLaunch))
    }
  }
}

fn apply_event(
  gate: Gate,
  phase: Phase,
  event: Event,
) -> Result(#(Phase, Authorization), AdmissionError) {
  case event {
    AuthorizeLaunch -> authorize_launch(gate, phase)
    RefuseBeforeLaunch(digest) -> refuse_before_launch(phase, digest)
    ObserveTerminal(digest) -> observe_terminal(phase, digest)
    ConfirmRetirement -> confirm_retirement(phase)
    ConfirmOwnerReceipt(digest) -> confirm_owner_receipt(phase, digest)
    Compact -> compact(phase)
  }
}

fn authorize_launch(
  gate: Gate,
  phase: Phase,
) -> Result(#(Phase, Authorization), AdmissionError) {
  case phase, gate {
    Admitted, Closed -> Error(EpochClosed)
    Admitted, Open -> Ok(#(LaunchIntent(NativeUnconfirmed), FirstAuthorization))

    // An intent survives the uncertain native window. Neither a retry nor
    // loading the committed book after restart can authorize a second launch.
    // Settled rows, including definite refusals, also remain fenced forever.
    LaunchIntent(_), _
    | Refused(_, _), _
    | Terminal(_, _, _), _
    | Retired(_), _
    | RetiredRefusal(_), _
    -> Ok(#(phase, NoAuthorization))
  }
}

fn refuse_before_launch(
  phase: Phase,
  digest: identity.Digest,
) -> Result(#(Phase, Authorization), AdmissionError) {
  // The absence of committed launch intent proves native custody is retired.
  // A separate phase retains that proof without confusing it with cleanup of
  // launched work. Closure blocks launch but must leave this settlement open.
  case phase {
    Admitted -> Ok(#(Refused(digest, ReceiptPending), NoAuthorization))
    Refused(existing, _) | RetiredRefusal(existing) -> {
      use Nil <- result.try(match_result(existing, digest))
      Ok(#(phase, NoAuthorization))
    }

    // Even an identical digest cannot establish that authorized work never ran.
    // Persisted intent, terminal results and their fences all retain that fact.
    LaunchIntent(_) | Terminal(_, _, _) | Retired(_) ->
      Error(LaunchAlreadyAuthorized)
  }
}

fn observe_terminal(
  phase: Phase,
  digest: identity.Digest,
) -> Result(#(Phase, Authorization), AdmissionError) {
  case phase {
    Admitted | Refused(_, _) | RetiredRefusal(_) -> Error(NotLaunched)
    LaunchIntent(custody) ->
      Ok(#(Terminal(digest, custody, ReceiptPending), NoAuthorization))
    Terminal(existing, _, _) | Retired(existing) -> {
      use Nil <- result.try(match_result(existing, digest))
      Ok(#(phase, NoAuthorization))
    }
  }
}

fn confirm_retirement(
  phase: Phase,
) -> Result(#(Phase, Authorization), AdmissionError) {
  case phase {
    Admitted -> Error(NotLaunched)
    LaunchIntent(_) -> Ok(#(LaunchIntent(NativeRetired), NoAuthorization))
    Terminal(digest, _, receipt) ->
      Ok(#(Terminal(digest, NativeRetired, receipt), NoAuthorization))
    Refused(_, _) | Retired(_) | RetiredRefusal(_) ->
      Ok(#(phase, NoAuthorization))
  }
}

fn confirm_owner_receipt(
  phase: Phase,
  digest: identity.Digest,
) -> Result(#(Phase, Authorization), AdmissionError) {
  case phase {
    Admitted | LaunchIntent(_) -> Error(MissingTerminal)
    Refused(existing, _) -> {
      use Nil <- result.try(match_result(existing, digest))
      Ok(#(Refused(existing, ReceiptDurable), NoAuthorization))
    }
    Terminal(existing, custody, _) -> {
      use Nil <- result.try(match_result(existing, digest))
      Ok(#(Terminal(existing, custody, ReceiptDurable), NoAuthorization))
    }
    Retired(existing) | RetiredRefusal(existing) -> {
      use Nil <- result.try(match_result(existing, digest))
      Ok(#(phase, NoAuthorization))
    }
  }
}

fn compact(phase: Phase) -> Result(#(Phase, Authorization), AdmissionError) {
  // Compaction drops the obligation fields only after both obligations hold.
  // Keeping the key and both digests prevents a late retry from becoming new.
  case phase {
    Refused(digest, ReceiptDurable) ->
      Ok(#(RetiredRefusal(digest), NoAuthorization))
    Terminal(digest, NativeRetired, ReceiptDurable) ->
      Ok(#(Retired(digest), NoAuthorization))
    Retired(_) | RetiredRefusal(_) -> Ok(#(phase, NoAuthorization))
    Admitted
    | LaunchIntent(_)
    | Refused(_, ReceiptPending)
    | Terminal(_, _, _) -> Error(NotForgettable)
  }
}

fn match_result(
  expected: identity.Digest,
  supplied: identity.Digest,
) -> Result(Nil, AdmissionError) {
  case expected == supplied {
    True -> Ok(Nil)
    False -> Error(ResultConflict)
  }
}

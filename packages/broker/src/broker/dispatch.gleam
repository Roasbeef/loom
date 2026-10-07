//// The seam between the broker and whatever owns a helper while a call
//// runs.
////
//// The broker decides *whether* a call may run: it composes the policy,
//// reserves pooled budget, mints the capability token and judges the
//// clearance against the abort epoch. It does not need to know *how* the
//// call runs. Everything that touches a `Helper` once those decisions are
//// made — borrowing one from the pool, sending `exec_start`, forwarding
//// output, enforcing the aggregate wall deadline, noticing that the caller
//// died, cancelling, feeding stdin, and returning the helper — sits behind
//// the `Dispatcher` in this module. The broker holds a record of functions
//// and never imports an implementation, so a second implementation can be
//// swapped in without the broker changing.
////
//// ## What crosses the seam
////
//// One call crosses it in three steps.
////
//// 1. The broker builds a `Dispatch` for a cleared call: the request, its
////    exact operation/step context, the wall deadline, the clock, the process
////    whose death should cancel the
////    call, and two closures — `deliver` for each output chunk, `settle`
////    for the one terminal verdict — through which the dispatcher reports
////    back. The dispatcher never learns the broker's message type.
//// 2. `Dispatcher.start` answers with an `Execution` (the call is running)
////    or a `StartRefusal` (nothing is running and nothing is held). The
////    broker keeps the `Execution` in its active-call table; its closures
////    are the only way the broker reaches the helper behind it.
//// 3. The dispatcher calls `settle` **exactly once** per started
////    execution, and the broker answers by calling `Execution.release`
////    while it processes that settlement. If the process that would have
////    called `settle` dies first, the broker's monitor on
////    `Execution.guarantor` fires and the broker calls `Execution.abandon`
////    instead, which stops the execution and returns what was lent. Those
////    two paths are the whole of the settlement guarantee: either `settle`
////    ran and `release` follows, or `abandon` runs; never both.
////
//// ## Why the helper's return lives behind the seam
////
//// Returning the helper is part of ending an execution, so it is the
//// dispatcher's job, but the broker chooses the moment. `release` is
//// called while the broker processes the execution's `Settle`, and
//// `abandon` returns the helper on the unsettled path. Tying the return to
//// the broker's own processing is what keeps a helper from being lent to
//// a second call while a stale `abandon` could still cancel it: the broker
//// calls exactly one of the two, and only after it knows which way the
//// execution ended. The broker holds no `Helper` at all after `start`,
//// which lets an implementation own its helpers however it likes.
////
//// ## Why this is not a behaviour of its own
////
//// `broker/executor` is the implementation. This module defines vocabulary
//// and nothing else: no process, no I/O. The seam stays a record of
//// functions, and not a direct call to the service, so the broker's tests
//// can hand it a fake dispatcher.

import broker/exec
import broker/framing.{type OutputStream}
import broker/internal/call
import core/clock.{type Clock}
import core/ids.{type EntryId, type OpId}
import core/remote_tool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/option.{type Option}
import gleam/result

/// How long a relay waits, after it has asked the helper to stop, for the
/// helper's terminal event before it declares the execution unkillable and
/// settles `CancelEscalated`. It is the seam's constant, shared by both
/// dispatchers, so the two lanes cannot disagree on how long a cancel may
/// take: the helper's own ladder is TERM, then KILL two seconds later, and
/// its machine escalates three seconds after that, which this exceeds.
pub const relay_grace_ms = 5000

/// Whether a stdin chunk is the last one. The seam's own two-variant type
/// so that a call site reads `EndOfInput` rather than `True`.
pub type Eof {
  /// More input may follow; the child's stdin stays open.
  MoreInput

  /// This chunk is the last; the child's stdin closes after it.
  EndOfInput
}

/// A stable execution identity: which dispatcher instance minted it and
/// the position within that instance. Two executions of one dispatcher
/// never share an identity, and an identity from an earlier incarnation can
/// never equal one from a later incarnation, so a late message about a
/// finished execution cannot be mistaken for one about a newer execution.
///
/// Opaque so that identities come only from `execution_id`, and so that
/// the pair can grow a field without touching a call site.
pub opaque type ExecutionId {
  ExecutionId(
    /// The dispatcher instance that minted this identity.
    incarnation: Int,
    /// Monotone within an incarnation.
    seq: Int,
  )
}

/// Builds an execution identity.
///
/// ## Examples
///
/// ```gleam
/// let id = dispatch.execution_id(incarnation: 0, seq: 7)
/// assert dispatch.seq(id) == 7
/// ```
///
pub fn execution_id(incarnation incarnation: Int, seq seq: Int) -> ExecutionId {
  ExecutionId(incarnation:, seq:)
}

/// The dispatcher instance that minted an identity.
///
/// ## Examples
///
/// ```gleam
/// let id = dispatch.execution_id(incarnation: 2, seq: 7)
/// assert dispatch.incarnation(id) == 2
/// ```
///
pub fn incarnation(id: ExecutionId) -> Int {
  id.incarnation
}

/// An identity's position within its incarnation.
///
/// ## Examples
///
/// ```gleam
/// let id = dispatch.execution_id(incarnation: 2, seq: 7)
/// assert dispatch.seq(id) == 7
/// ```
///
pub fn seq(id: ExecutionId) -> Int {
  id.seq
}

/// One output chunk, as the caller sees it. It is the dispatcher's own
/// copy of the helper's output event so that the seam does not expose the
/// helper's event type.
pub type Chunk {
  Chunk(
    /// Which of the child's output streams the bytes came from.
    stream: OutputStream,
    /// The bytes themselves.
    data: BitArray,
    /// Cumulative bytes seen on this stream, including any the helper
    /// dropped once the stream's cap was reached.
    total_bytes: Int,
    /// Whether the helper has started dropping output on this stream. The
    /// field mirrors `exec.Output.truncated`, which the helper's wire
    /// format fixes as a flag.
    truncated: Bool,
  )
}

/// How an execution ended, from the dispatcher's side. Exactly the two
/// terminal events a helper can produce, so that the broker's outcome type
/// maps onto it one for one.
pub type Terminal {
  /// The execution completed under the demanded enforcement.
  Completed(result: exec.ExecResult)

  /// The execution settled as an in-band failure: a refusal at dispatch, a
  /// dead channel, degraded enforcement, a cancel that had to be escalated.
  Failed(failure: exec.ExecFailure)
}

/// The cleared operation and step, copied from CallSpec without substitution.
/// These are logical coordinates; seq, token and transport generations cannot
/// reconstruct them. A remote adapter validates the step with core/workspace.step
/// (1..1024 UTF-8 bytes, no controls) at its external boundary. The local broker
/// preserves all internally generated names, including job and build suffixes.
pub type CallContext {
  /// Context comes from the actual cleared call, never a fresh operation ID.
  CallContext(
    /// The durable operation which owns the call.
    operation: OpId,
    /// The exact internal step name; external admission must bound it.
    step: String,
    /// Optional durable parent provenance, never an authorization grant.
    /// Remote admission requires it; local unmanaged callers supply `None`.
    origin: Option(remote_tool.ChildOrigin),
  )
}

/// What the broker hands a dispatcher for one cleared call. Every field is
/// a decision the broker already made; the dispatcher carries them out.
pub type Dispatch {
  Dispatch(
    /// Original one-use system permission; ordinary calls carry None.
    system_reservation: Option(SystemReservationRef),
    /// Logical identity from the cleared CallSpec, independent of call seq.
    context: CallContext,
    /// The cleared request, token and final policy included.
    request: exec.ExecRequest,
    /// The identity's position within the dispatcher's incarnation. The
    /// broker supplies it from its own call counter so that an execution's
    /// identity matches the call id the broker already uses. The counter
    /// advances on every attempt, whether `start` answered `Ok` or a
    /// refusal, so a number is never offered twice within a broker's life
    /// and a dispatcher may rely on that.
    seq: Int,
    /// The aggregate wall deadline in the clock's milliseconds, or `0` for
    /// none. A dispatcher cancels the execution when it passes.
    deadline_ms: Int,
    /// The session's clock, which `deadline_ms` is measured against.
    clock: Clock,
    /// The process whose death cancels the execution, when the call's
    /// event subject names a live owner. A tool effect killed mid-call can
    /// no longer cancel its own execution, and without this watch the
    /// command would run on to its wall limit with nobody left to want its
    /// output.
    caller: Option(Pid),
    /// Called for every output chunk, in order, before `settle`.
    deliver: fn(Chunk) -> Nil,
    /// Called exactly once per started execution, with the terminal
    /// verdict, after the last `deliver`.
    settle: fn(Terminal) -> Nil,
  )
}

/// Why a dispatch did not start. In both cases nothing is running, nothing
/// is held, and neither `deliver` nor `settle` will be called.
pub type StartRefusal {
  /// No helper could be borrowed. The broker maps it exactly as it mapped a
  /// failed checkout before the seam existed, so the congestion wait for a
  /// full pool is unchanged.
  NoHelper(error: exec.CheckoutError)

  /// The dispatcher could not set up its own machinery in time. The broker
  /// answers `BrokerUnavailable`.
  NotStarted
}

/// A started execution, as the broker holds it. The closures are the only
/// way the broker reaches the helper behind it.
pub type Execution {
  Execution(
    /// The execution's identity.
    id: ExecutionId,
    /// The process whose unsettled death means `settle` will never be
    /// called. The broker monitors it; on its death the broker calls
    /// `abandon`.
    guarantor: Pid,
    /// Asks the execution to stop. Idempotent.
    cancel: fn() -> Nil,
    /// Sends a chunk of stdin to the execution. Ignored once nothing is
    /// running.
    stdin: fn(BitArray, Eof) -> Nil,
    /// Return whatever the dispatcher lent for this execution. The broker
    /// calls it exactly once, while processing the execution's `Settle`,
    /// and never after `abandon`.
    release: fn() -> Nil,
    /// The guarantor died unsettled: stop the execution and return what
    /// was lent, as `release` would have. The broker calls it at most
    /// once, never after `settle` has run, and never together with
    /// `release`.
    abandon: fn() -> Nil,
  )
}

/// The seam. A record of functions, so the broker never imports an
/// implementation.
pub type Dispatcher {
  Dispatcher(
    /// Starts one cleared call. The call is running when this returns
    /// `Ok`: stdin sent after the return reaches the helper after the
    /// `exec_start` that began the call.
    start: fn(Dispatch) -> Result(Execution, StartRefusal),
  )
}

/// The immutable trusted native declaration retained before Broker clearance.
pub type SystemCommandDeclaration {
  SystemCommandDeclaration(
    /// The original configured owner label in the native envelope.
    owner: String,
    /// The original durable work operation.
    operation: OpId,
    /// Its exact fixed phase.
    step: String,
    /// The retained complete command arguments.
    argv: List(String),
    /// The retained ordered environment.
    env: List(#(String, String)),
    /// The executor-side working directory.
    cwd: String,
    /// The original finite deadline, never renewed by congestion.
    deadline_ms: Int,
  )
}

/// The actual cleared coordinates, excluding Dispatch callbacks.
pub type ClearedSystemCommand {
  ClearedSystemCommand(
    /// The complete request the Broker actually cleared.
    request: exec.ExecRequest,
    /// The original actual operation.
    operation: OpId,
    /// The original actual phase.
    step: String,
    /// The unchanged Broker deadline.
    deadline_ms: Int,
    /// The actual events-subject owner.
    caller: Option(Pid),
  )
}

/// One local routing permission to the original custodian's typed subject.
/// There is deliberately no codec or durable constructor from history.
pub opaque type SystemReservationRef {
  /// Only an original actor inventory entry gives these coordinates meaning.
  SystemReservationRef(
    /// The exact original auxiliary subject, never a registered replacement.
    subject: Subject(SystemReservationMessage),
    /// Fresh BEAM identity of the actual opaque pending value.
    reference: Reference,
    /// Complete direct system child allocated once in SQLite.
    origin: remote_tool.ChildOrigin,
    /// Original immutable work UUID, retained before clearance.
    request_id: EntryId,
  )
}

/// Closed original-owner requests; messages contain no executable callbacks.
pub type SystemReservationMessage {
  /// Consumes one actual pending permission before payload admission.
  ReserveSystem(
    /// Original actor and one-use inventory identity.
    ref: SystemReservationRef,
    /// The unchanged actual Broker projection, without callbacks.
    cleared: ClearedSystemCommand,
    /// Complete canonical Prepared envelope with original scope and deadline.
    envelope: BitArray,
    /// A bounded original ask receives known Fresh admission only.
    reply: Subject(Result(#(EntryId, BitArray), Nil)),
  )

  /// Cancels the same durable identity before or after native admission.
  CancelSystem(
    /// The same original identity even after permission consumption.
    ref: SystemReservationRef,
    /// The bounded ask observes durable sticky cancellation.
    reply: Subject(Result(Nil, Nil)),
  )
}

/// Mints a local reference only after the custodian retained FreshPending.
/// Its fresh Reference must name an actual entry in that original actor.
///
/// ## Examples
///
/// `system_reservation_ref(subject, reference, origin, uuid)` has no wire encoding.
pub fn system_reservation_ref(
  subject: Subject(SystemReservationMessage),
  reference: Reference,
  origin: remote_tool.ChildOrigin,
  request_id: EntryId,
) -> SystemReservationRef {
  SystemReservationRef(subject, reference, origin, request_id)
}

/// Projects routing coordinates for exact original-subject validation.
///
/// ## Examples
///
/// `system_reservation_fields(ref)` never resolves a registered replacement.
pub fn system_reservation_fields(
  ref: SystemReservationRef,
) -> #(
  Subject(SystemReservationMessage),
  Reference,
  remote_tool.ChildOrigin,
  EntryId,
) {
  #(ref.subject, ref.reference, ref.origin, ref.request_id)
}

/// Asks the original subject to consume its permission and commit exact bytes.
/// Timeout or a lost reply supplies no reservation and cannot rearm the entry.
///
/// ## Examples
///
/// `reserve_system(ref, actual, bytes, 5000)` returns the original committed UUID.
pub fn reserve_system(
  ref: SystemReservationRef,
  cleared: ClearedSystemCommand,
  envelope: BitArray,
  waiting: Int,
) -> Result(#(EntryId, BitArray), Nil) {
  use answer <- result.try(
    call.try_call(ref.subject, waiting: waiting, sending: fn(reply) {
      ReserveSystem(ref, cleared, envelope, reply)
    })
    |> result.replace_error(Nil),
  )
  answer
}

/// Sends sticky cancellation to the same original subject and identity.
///
/// ## Examples
///
/// `cancel_system(ref, 5000)` does not reconstruct reserve permission.
pub fn cancel_system(
  ref: SystemReservationRef,
  waiting: Int,
) -> Result(Nil, Nil) {
  use answer <- result.try(
    call.try_call(ref.subject, waiting: waiting, sending: fn(reply) {
      CancelSystem(ref, reply)
    })
    |> result.replace_error(Nil),
  )
  answer
}

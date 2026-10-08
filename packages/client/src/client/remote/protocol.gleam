//// The closed vocabulary two nodes speak when a session's tool calls run on
//// another machine (protocol-change/078, "Node vocabulary").
////
//// An orchestrator holds the conversation and an executor holds the checkout.
//// They are mutually trusted Erlang peers, but the messages between them are
//// still held to a narrow shape: every field is a string, an integer, a bit
//// array, a list, one of the plain-data runtime types (`ToolRun`,
//// `ToolOutcome`, `Authority`, the escalation `Refused` and `Decision`) or a
//// `Subject`. No function, port or handle to node-local storage crosses. That
//// is what lets each side change its internals without a wire change, and it is
//// why the executor's workspace is handed an `OwnerServices` made of messages
//// instead of a borrowed runtime (see `client/owner_services`).
////
//// ## Three conversations
////
//// - `HostMessage` goes from an orchestrator to the executor's node-level host
////   (`client/remote/host`). It attaches a runtime incarnation to its scope,
////   runs one tool call, asks what became of a call, acknowledges a result and
////   closes the scope.
//// - `OwnerMessage` goes from the executor's workspace back to the session's
////   owner port on the orchestrator (`client/remote/owner_port`). It is the
////   wire form of `OwnerServices`, one constructor per function.
//// - The replies are ordinary values sent to the `Subject` a request carries.
////
//// ## What a reply means
////
//// A request that was refused carries a `Refusal`, which says why nothing
//// happened. `RunLost` is different: the call was admitted and the executor
//// can no longer say how it ended, so the caller must not run it again. A
//// `Lookup` answers a query by call key from the executor's execution ledger,
//// and `Missing` is only trustworthy after an attach, because the attach token
//// is what stops a dead runtime's late request from creating the row.
////
//// There is no cancel message. The executor monitors the process that sent each
//// `Run`, and the death of that process (an abort) cancels the call.

import broker/framing.{type CapOutcome}
import client/escalate
import client/notice
import client/owner_services.{type FactFault, type OwnerCapCall}
import client/wiring.{type Authority}
import codemode/satellite.{type CapDenial}
import core/ids.{type Seq}
import core/json.{type JsonValue}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option}
import runtime/api
import runtime/effects.{type ToolOutcome, type ToolRun}
import tools/agent
import tools/tool

/// A tool call's identity: the one the orchestrator's planner already uses and
/// the executor's ledger keys its rows by.
pub type Key {
  Key(
    /// The orchestrator session that owns the call, and so its scope.
    session: String,
    /// The operation the call belongs to, as text.
    op: String,
    /// The step within the operation.
    step: String,
    /// The call's position among the step's tool calls.
    source_index: Int,
  )
}

/// How a scope's cleanup ended, as the workspace plane reported it. A lost
/// reply or a timeout is never a witness; only the plane's own retirement
/// result is.
pub type CloseOutcome {
  /// Every child of the scope is gone.
  AllRetired

  /// The plane could not prove that `count` children are gone. This scope gets
  /// no automatic successor.
  UnknownCleanup(count: Int)
}

/// The calls of one session whose results the orchestrator has not
/// acknowledged. The orchestrator acknowledges the ones its own store already
/// holds, which is how a lost `Ack` stops leaking a ledger row.
pub type Unacked {
  Unacked(
    /// Calls with a stored result.
    terminal: List(Key),
    /// Calls whose outcome the executor lost.
    unknown: List(Key),
  )
}

/// The reply to a successful attach. `census` is whatever the workspace plane
/// reported about its machine at startup, and the host does not look inside it.
pub type Attached(census) {
  Attached(
    /// The startup census of the scope's workspace plane.
    census: census,
    /// The scope's unacknowledged calls when the attach took effect.
    unacked: Unacked,
  )
}

/// Why a request changed nothing. The cases follow the ledger's rules, so the
/// text an operator reads names the rule that refused.
pub type Refusal {
  /// The request's attach token is not the scope's current one: a newer
  /// runtime incarnation attached, and this request is from a dead one.
  StaleToken

  /// The request's incarnation is not the scope's. `stored` is the scope's.
  StaleIncarnation(stored: Int)

  /// The scope is not open, so it admits no call.
  ScopeNotOpen

  /// The scope is mid-close.
  ScopeClosing

  /// The scope closed with unknown cleanup and has no automatic successor.
  UncleanClose(count: Int)

  /// The executor already holds `limit` scopes that are not cleanly closed.
  CapacityExhausted(limit: Int)

  /// The call's result reservation would pass the ledger's byte budget.
  BudgetExhausted(limit: Int)

  /// The session's scope is for another workspace.
  WorkspaceMismatch(stored: String)

  /// The session has no scope on this executor.
  NoSuchScope

  /// The scope has no workspace plane, because building it failed or the
  /// executor restarted since it was built. Attach again.
  NoPlane(reason: String)

  /// An argument was outside its domain.
  Invalid(reason: String)

  /// The executor could not complete the operation, such as a ledger fault.
  ExecutorFault(reason: String)

  /// The executor could not be reached. A host never sends this; the
  /// orchestrator's surface uses it for its own bounded waits.
  Unreachable(reason: String)
}

/// How a `Run` request ended.
pub type RunAnswer {
  /// The call ran to the end, and this is its outcome.
  RunFinished(outcome: ToolOutcome)

  /// The call was admitted and its outcome is lost: the executor restarted,
  /// cancelled it, or its worker died. It may have run. Do not run it again.
  RunLost

  /// The call was not admitted.
  RunRefused(refusal: Refusal)
}

/// What the ledger holds for one call key.
pub type Lookup {
  /// No row. After an attach, the call never reached the executor and cannot.
  Missing

  /// The call is running now.
  Admitted

  /// The call ended, and this is its stored outcome.
  Terminal(outcome: ToolOutcome)

  /// The call's outcome is lost.
  Unknown
}

/// What an orchestrator says to the executor's host.
///
/// `census` is the type of the workspace plane's startup census, which only the
/// two ends of an integration need to agree on.
pub type HostMessage(census) {
  /// Sent by every runtime incarnation before its first run or recovery. It
  /// starts or adopts the scope at `incarnation` and makes `token` its only
  /// valid attach token, which is the fence against a dead runtime's in-flight
  /// `Run`. `owner_port` is where the scope's workspace calls back.
  Attach(
    session: String,
    workspace: String,
    incarnation: Int,
    token: BitArray,
    owner_port: Subject(OwnerMessage),
    reply: Subject(Result(Attached(census), Refusal)),
  )

  /// Runs one tool call, idempotently by `key`. It is admitted only if
  /// `incarnation` and `token` equal the scope's. The host monitors the
  /// process that owns `reply`: its death other than `noconnection` cancels
  /// the call.
  Run(
    key: Key,
    incarnation: Int,
    token: BitArray,
    run: ToolRun,
    authority: Authority,
    reply: Subject(RunAnswer),
  )

  /// Asks what the ledger holds for `key`, in any scope state.
  Query(key: Key, reply: Subject(Result(Lookup, Refusal)))

  /// Asks for the session's unacknowledged calls without attaching.
  ListUnacked(session: String, reply: Subject(Result(Unacked, Refusal)))

  /// The orchestrator durably staged this call's result; the row may go. No
  /// reply: a lost `Ack` is found again by `ListUnacked`.
  Ack(key: Key)

  /// Closes the scope and reports how the cleanup ended.
  Close(
    session: String,
    workspace: String,
    incarnation: Int,
    reply: Subject(Result(CloseOutcome, Refusal)),
  )
}

/// What the executor's workspace says to the session's owner port. One
/// constructor per `OwnerServices` function, with the reply a `Subject`.
pub type OwnerMessage {
  /// Decides a policy refusal. `remaining_ms` is how long the call may still
  /// wait. The executor sends a remaining duration, never a deadline, because
  /// the two machines' clocks differ.
  Escalate(
    refused: escalate.Refused,
    remaining_ms: Int,
    reply: Subject(escalate.Decision),
  )

  /// `FactAccess.cell`.
  FactGet(key: String, reply: Subject(Result(Option(api.FactCell), FactFault)))

  /// `FactAccess.put`, the compare-and-set.
  FactPut(
    key: String,
    value: JsonValue,
    expected: Option(Seq),
    reply: Subject(Result(Seq, FactFault)),
  )

  /// `FactAccess.put_blind`.
  FactPutBlind(
    key: String,
    value: JsonValue,
    reply: Subject(Result(Nil, FactFault)),
  )

  /// `FactAccess.delete`.
  FactDelete(key: String, reply: Subject(Result(Nil, FactFault)))

  /// `FactAccess.list`.
  FactList(
    prefix: String,
    reply: Subject(Result(List(#(String, JsonValue)), FactFault)),
  )

  /// A background job's completion notice for a strand.
  Notify(
    strand: String,
    work: notice.Work,
    text: String,
    reply: Subject(Result(notice.Delivered, String)),
  )

  /// Whether a strand has an open run.
  StrandActivity(
    strand: String,
    reply: Subject(Result(notice.Activity, String)),
  )

  /// The idle heartbeat's wake of a strand.
  Wake(strand: String, text: String, reply: Subject(Result(Nil, String)))

  /// Whether a strand's active tool list holds a tool.
  Holds(
    caller: agent.Caller,
    tool: String,
    reply: Subject(Result(Nil, agent.Refusal)),
  )

  /// A running tool's rolling output tail. A cast: a dropped tail costs a
  /// terminal one frame.
  Tail(run: ToolRun, tail: tool.OutputTail)

  /// An owner-bound code-mode capability call.
  Capability(call: OwnerCapCall, reply: Subject(Result(CapOutcome, CapDenial)))
}

/// The key of one call of a session's tool run.
///
/// ## Examples
///
/// ```gleam
/// // protocol.key_of("session-1", run)
/// ```
pub fn key_of(session: String, run: ToolRun) -> Key {
  Key(
    session:,
    op: ids.op_id_to_string(run.operation),
    step: run.step_id,
    source_index: run.source_index,
  )
}

/// The sentence a model or an operator reads for a refusal.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.describe(protocol.StaleToken)
///   == "the executor holds a newer attachment for this session"
/// ```
pub fn describe(refusal: Refusal) -> String {
  case refusal {
    StaleToken -> "the executor holds a newer attachment for this session"
    StaleIncarnation(stored:) ->
      "the executor's scope is at incarnation " <> int.to_string(stored)
    ScopeNotOpen -> "the executor's scope for this session is not open"
    ScopeClosing -> "the executor's scope for this session is closing"
    UncleanClose(count:) ->
      "the executor could not prove "
      <> int.to_string(count)
      <> " children of the closed scope are gone"
    CapacityExhausted(limit:) ->
      "the executor already holds "
      <> int.to_string(limit)
      <> " scopes that are not cleanly closed"
    BudgetExhausted(limit:) ->
      "the executor's ledger is full at "
      <> int.to_string(limit)
      <> " bytes of unacknowledged results"
    WorkspaceMismatch(stored:) ->
      "the executor's scope for this session is for the workspace " <> stored
    NoSuchScope -> "the executor has no scope for this session"
    NoPlane(reason:) ->
      "the executor has no workspace for this session: " <> reason
    Invalid(reason:) -> "the executor refused the request: " <> reason
    ExecutorFault(reason:) -> "the executor failed: " <> reason
    Unreachable(reason:) -> "the executor could not be reached: " <> reason
  }
}

/// The text a model reads when a remote call's outcome is lost. It says
/// plainly that the call may have run, because the model's next move depends
/// on it.
pub const unknown_outcome_text =
  "the execution may have run, and its outcome is unknown: the executor restarted or abandoned the call before it finished"

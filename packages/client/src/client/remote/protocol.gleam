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
//// is what stops a dead runtime's late request from creating the row. A call
//// that must never run twice is asked about with `QueryOrFence` instead, which
//// turns a missing row into a stored "did not start", so no late `Run` for the
//// same key can start the call after the answer was given.
////
//// There is no cancel message for a tool call. The executor monitors the
//// process that sent each `Run`, and the death of that process (an abort)
//// cancels the call.
////
//// ## Background executions
////
//// A background code-mode program on a remote session is a long-lived call
//// with a key of its own, `execution_key`: the launching operation, the step
//// `async/<id>` and source index 0. The orchestrator keeps the durable record
//// and starts the program with `StartExecution`, which the host admits by key
//// exactly as it admits a `Run`. `StopExecution` is the one stop message: it is
//// sent when the orchestrator's record has closed, and in one ledger
//// transaction it turns a running row lost or bars a key with no row, so a late
//// start from a dead worker never runs. The executor reaches the record back
//// through `LaunchExecution` and `InteractExecution`, and the program's inputs
//// and progress travel as ordinary owner-bound `Capability` calls.
////
//// ## MCP façades
////
//// `Attach` carries an `McpPlan`: the façades of the MCP servers the
//// orchestrator runs, which the executor compiles programs against without
//// holding a client, and the names of the servers the orchestrator expects the
//// executor to run from its own configuration. No command line and no secret
//// crosses.

import broker/framing.{type CapOutcome}
import client/escalate
import client/notice
import client/owner_services.{
  type ExecutionTerms, type FactFault, type OwnerCapCall,
}
import client/wiring.{type Authority}
import codemode/satellite.{type CapDenial}
import core/ids.{type OpId, type Seq}
import core/json.{type JsonValue}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option}
import gleam/string
import runtime/api
import runtime/effects.{type ToolOutcome, type ToolRun}
import tools/agent
import tools/codemode as codemode_tool
import tools/tool

/// The version of this vocabulary. Every `Attach` carries the sender's, and the
/// host refuses any other value with `VersionMismatch`, so two builds that
/// disagree about the messages learn it at the first exchange and not from a
/// crash on a term one of them does not recognise. Change it whenever a
/// constructor or field of `HostMessage`, `OwnerMessage` or a reply changes.
///
/// Version 2 added `Attached.executor_now_ms`, the executor's clock read when
/// the reply is sent. Version 1 carried that reading inside the census, where
/// it was as old as the scope.
///
/// Version 3 added background executions (`StartExecution`, `StopExecution`,
/// `LaunchExecution`, `InteractExecution`, `Unacked.executions` and
/// `Lookup.Executed`) and the MCP plan an `Attach` carries.
pub const version = 3

/// The name an execution's ledger row is admitted under, in the column a tool
/// call's row holds its tool name in. No tool is named this, so a row is known
/// to be an execution's without reading its step.
pub const execution_tool = "execution"

/// The prefix of an execution's step: `async/<id>` is both the record's broker
/// step and the step of its ledger key.
pub const execution_step_prefix = "async/"

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
    /// Background executions still running. The orchestrator stops the ones
    /// whose record has closed.
    executions: List(Key),
  )
}

/// The reply to a successful attach. `census` is whatever the workspace plane
/// reported about its machine at startup, and the host does not look inside it.
pub type Attached(census) {
  Attached(
    /// The startup census of the scope's workspace plane.
    census: census,
    /// The executor's wall clock when this reply was sent, in Unix
    /// milliseconds. The host reads it for each reply, not once per scope, so a
    /// rebound attach to a scope built an hour ago still reports the executor's
    /// time now. The orchestrator compares it with its own clock at receipt to
    /// rebase the absolute deadlines its non-tool callers put into a
    /// `CallSpec`.
    executor_now_ms: Int,
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

  /// The peer speaks another version of this vocabulary. `supported` is the
  /// host's own (`protocol.version`).
  VersionMismatch(supported: Int)

  /// The session's scope is for another workspace.
  WorkspaceMismatch(stored: String)

  /// The session has no scope on this executor.
  NoSuchScope

  /// The scope has no workspace plane, because building it failed or the
  /// executor restarted since it was built. Attach again.
  NoPlane(reason: String)

  /// The session's workspace plane is still being built. Nothing changed; ask
  /// again shortly.
  PlaneBuilding

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

  /// There was no row, and the host stored a "did not start" outcome for the
  /// key, so a late `Run` for it is answered with that outcome and never
  /// starts. Only `QueryOrFence` answers this; `Query` writes nothing and
  /// answers `Missing` instead, and `QueryOrFence` never answers `Missing`.
  Fenced

  /// A background execution ended, and this is the execution value it
  /// stored. A tool call's key never answers this.
  Executed(value: JsonValue)
}

/// How a `StartExecution` ended.
pub type ExecutionAnswer {
  /// The program ended, and this is the execution value of its run.
  ExecutionFinished(value: JsonValue)

  /// The execution was admitted and its outcome is lost: the executor
  /// restarted, the program was stopped, or its worker died. It may have run.
  ExecutionLost

  /// The execution was not admitted.
  ExecutionRefused(refusal: Refusal)
}

/// One generated MCP façade, as the orchestrator that runs the server sends
/// it: the `codegen.Generated` the server's listing produced, under the
/// server's name.
pub type Facade {
  Facade(
    /// The server's catalogue name, the `<name>` in `mcp.<name>`.
    server: String,
    /// The module a program imports, `cap/mcp/<name>`.
    module_name: String,
    /// The module's Gleam source, which the hermetic build compiles.
    source: String,
    /// The declaration surface the description and `cap://` reads render.
    surface: String,
  )
}

/// The MCP servers a session's code mode reaches, as an attach states them.
pub type McpPlan {
  McpPlan(
    /// The façades of the servers the orchestrator runs. Calls to them are
    /// sent back over the owner port.
    served: List(Facade),
    /// The names of the servers the orchestrator expects the executor to run
    /// from the executor's own configuration.
    expected: List(String),
  )
}

/// What an orchestrator says to the executor's host.
///
/// `census` is the type of the workspace plane's startup census, which only the
/// two ends of an integration need to agree on.
pub type HostMessage(census) {
  /// Sent once by each session open, before its first run or recovery.
  /// `version` is the sender's `protocol.version`. It starts or adopts the
  /// scope at `incarnation` and makes `token` its only
  /// valid attach token, which is the fence against an earlier open's in-flight
  /// `Run`. `owner_port` is where the scope's workspace calls back.
  Attach(
    version: Int,
    session: String,
    workspace: String,
    incarnation: Int,
    token: BitArray,
    owner_port: Subject(OwnerMessage),
    mcp: McpPlan,
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

  /// Asks what the ledger holds for `key`, and when it holds nothing stores a
  /// "did not start" outcome for the key in the same transaction (`Fenced`).
  /// `incarnation` is the asking runtime's, checked against the scope's. This
  /// is the recovery question for a call whose replay is not safe: the answer
  /// stays true whichever order a dead runtime's late `Run` and this request
  /// reach the host in.
  QueryOrFence(
    key: Key,
    incarnation: Int,
    reply: Subject(Result(Lookup, Refusal)),
  )

  /// Asks for the session's unacknowledged calls without attaching.
  ListUnacked(session: String, reply: Subject(Result(Unacked, Refusal)))

  /// The orchestrator durably staged this call's result; the row may go. No
  /// reply: a lost `Ack` is found again by `ListUnacked`.
  Ack(key: Key)

  /// Runs one background program, idempotently by `key`
  /// (`execution_key`). It is admitted only if `incarnation` and `token` equal
  /// the scope's, as a `Run` is, and the host watches the process that owns
  /// `reply` the same way. `remaining_ms` is the time left before the
  /// orchestrator's record expires, read on the orchestrator's clock when the
  /// message is sent; the executor builds the program's deadline from it on
  /// its own clock when it admits the key, and a re-send's smaller value is
  /// ignored.
  StartExecution(
    key: Key,
    incarnation: Int,
    token: BitArray,
    terms: ExecutionTerms,
    remaining_ms: Int,
    reply: Subject(ExecutionAnswer),
  )

  /// The orchestrator's record of this execution has closed. A running program
  /// is stopped and its row turned lost; a key with no row is barred, so a
  /// late `StartExecution` never starts. No reply: a lost stop is sent again by
  /// the orchestrator's reconciler, which reads `Unacked.executions`.
  StopExecution(key: Key, incarnation: Int)

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

  /// The executor's `code_mode` tool was asked to launch a background
  /// program. The owner claims the record and answers the handle.
  LaunchExecution(
    terms: ExecutionTerms,
    reply: Subject(Result(JsonValue, String)),
  )

  /// The executor's `code_mode` tool was asked to check, join, cancel or send
  /// to a background execution the strand owns.
  InteractExecution(
    strand: String,
    handle: String,
    interaction: codemode_tool.Interaction,
    within_ms: Int,
    reply: Subject(Result(JsonValue, String)),
  )
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

/// The ledger key of a background execution: the launching operation, the
/// execution's own step `async/<id>`, and source index 0, since the step alone
/// names one execution.
///
/// ## Examples
///
/// ```gleam
/// // protocol.execution_key("session-1", op, "a1b2").step == "async/a1b2"
/// ```
pub fn execution_key(session: String, op: OpId, id: String) -> Key {
  Key(
    session:,
    op: ids.op_id_to_string(op),
    step: execution_step_prefix <> id,
    source_index: 0,
  )
}

/// The execution identity in a key whose step is an execution's, or
/// `Error(Nil)` for a tool call's key.
///
/// ## Examples
///
/// ```gleam
/// assert protocol.execution_id(protocol.Key("s", "op", "async/ab", 0))
///   == Ok("ab")
/// assert protocol.execution_id(protocol.Key("s", "op", "turn-1", 0))
///   == Error(Nil)
/// ```
pub fn execution_id(key: Key) -> Result(String, Nil) {
  case string.starts_with(key.step, execution_step_prefix) {
    True ->
      Ok(string.drop_start(key.step, string.length(execution_step_prefix)))
    False -> Error(Nil)
  }
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
    VersionMismatch(supported:) ->
      "the executor speaks protocol version "
      <> int.to_string(supported)
      <> " and this orchestrator does not"
    WorkspaceMismatch(stored:) ->
      "the executor's scope for this session is for the workspace " <> stored
    NoSuchScope -> "the executor has no scope for this session"
    NoPlane(reason:) ->
      "the executor has no workspace for this session: " <> reason
    PlaneBuilding ->
      "the executor is still preparing this session's workspace; try again shortly"
    Invalid(reason:) -> "the executor refused the request: " <> reason
    ExecutorFault(reason:) -> "the executor failed: " <> reason
    Unreachable(reason:) -> "the executor could not be reached: " <> reason
  }
}

/// The outcome text of a call that never started. The host stores it when it
/// fences a key, and the runtime stages the same sentence when recovery says a
/// call was not started, so the model reads one wording for both.
pub const did_not_run_text =
  "the call never reached the executor and did not run"

/// The text a model reads when a remote call's outcome is lost. It says
/// plainly that the call may have run, because the model's next move depends
/// on it.
pub const unknown_outcome_text =
  "the execution may have run, and its outcome is unknown: the executor restarted or abandoned the call before it finished"

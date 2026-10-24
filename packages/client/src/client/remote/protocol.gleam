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
//// The executor asks the owner port for the session's `McpPlan`
//// (`AskMcpPlan`) while it builds the scope's plane: the façades of the MCP
//// servers the orchestrator runs, which the executor compiles programs against
//// without holding a client, and the names of the servers the orchestrator
//// expects the executor to run from its own configuration. No command line and
//// no secret crosses. The plan is not a field of `Attach`, because `Attach`
//// keeps one shape across versions (see `version`).

import broker/framing.{type CapOutcome}
import broker/policy
import client/escalate
import client/evolution/record
import client/extension/archive
import client/extension/hooks
import client/notice
import client/owner_services.{
  type ExecutionTerms, type FactFault, type OwnerCapCall,
}
import client/wiring.{type Authority, Authority}
import codemode/satellite.{type CapDenial}
import core/ids.{type OpId, type Seq}
import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
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
/// `Lookup.Executed`) and the MCP plan the executor asks the owner for
/// (`AskMcpPlan`).
///
/// Version 4 added the refusal `WorktreeFailed` and the branch a worktree
/// session's census carries (`client/remote/remote_census`), for workspaces in
/// worktree mode (protocol-change/095). The step from 3 is a wire change of
/// two shapes, and every executor must upgrade with its orchestrators, because
/// the host refuses the other version at the first attach.
///
/// Version 5 added the remote evolution vocabulary of protocol-change/098: eight
/// `HostMessage` constructors (`EvolutionSnapshot`, `EvolutionEvaluate`,
/// `EvolutionStage`, `EvolutionRun`, `EvolutionHook`, `EvolutionTransition`,
/// `EvolutionRetire` and `EvolutionInventory`), the plain-data types they
/// carry (`Coordinates`, `Handle`, `Staged`, `Prepared`, `TransitionStep`,
/// `TransitionAnswer`, `Target`, `Activation` and `EvolutionRequest`), the four
/// refusals `UnknownHandle`, `AlreadyPublished`, `StaleGeneration` and
/// `NoEvolution`, and the census field `RemoteCensus.evolution`, which says
/// whether the executor can compile candidates and under which identity. The
/// step from 4 changes the shape of the census an `Attached` carries as well as
/// adding messages, so every executor must upgrade with its orchestrators.
/// Trials and core upgrades are not in this version; they come with the
/// changes that serve them, under their own bumps.
///
/// `Attach` must keep the shape it had in version 2. It is the first
/// message a peer of any version sends, and the host matches the term it
/// receives against this module's constructors: an `Attach` of another arity
/// matches no arm, and the host, and with it the executor daemon, exits instead
/// of answering `VersionMismatch`. Anything a later version needs at attach
/// travels in a message sent after the version check has passed, as the MCP
/// plan does. Every other message may change shape, because a peer of another
/// version never gets past the attach to send it.
pub const version = 5

/// The name an execution's ledger row is admitted under, in the column a tool
/// call's row holds its tool name in. No tool is named this, so a row is known
/// to be an execution's without reading its step.
pub const execution_tool = "execution"

/// The prefix of the name an evolution call's ledger row is admitted under:
/// `evolution:test` for a candidate's check, `evolution:<tool>` for a promoted
/// tool and `evolution:program` for a program. No tool is named with the
/// prefix, so the row is known to be evolution's, and it is never an
/// execution's (`execution_tool`).
pub const evolution_tool_prefix = "evolution:"

/// The most bytes of Git's message a `WorktreeFailed` carries.
pub const max_worktree_reason = 512

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

  /// The workspace is in worktree mode and the executor could not make or
  /// reopen the session's Git worktree. `reason` is Git's message, cut to
  /// `max_worktree_reason` printable bytes. Whatever the attempt began was
  /// undone, so the next attach starts clean.
  WorktreeFailed(reason: String)

  /// The generation handle names nothing the executor holds: it never issued
  /// it, or the executor restarted since, so the handle belongs to a previous
  /// boot.
  UnknownHandle

  /// The successor was already published, so it can no longer be aborted. The
  /// caller's generation is the new one.
  AlreadyPublished

  /// The executor already serves a generation of the selection that is newer
  /// than the one asked for, or one that was superseded. `serving` is the
  /// executor's.
  StaleGeneration(serving: Int)

  /// The scope has no evolution plane, so it can neither compile nor serve a
  /// candidate. `reason` says why, in the words the census carries.
  NoEvolution(reason: String)

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

/// The MCP servers a session's code mode reaches, as the owner port answers
/// `AskMcpPlan`.
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

/// What a tool call's door knows about the call, as far as the executor needs
/// it to run evolution work on the session's behalf. It is the `Key` the
/// ledger files the call under, the strand that dispatched it, the grants its
/// escalation approvals consumed, and the stored `Authority` the executor
/// revalidates against its own filesystem before widening the call's policy.
/// Nothing machine-local crosses: the executor supplies its own workspace,
/// base policy, environment and clock when it rebuilds the context.
/// `coordinates_of` is the one place the two are related.
pub type Coordinates {
  Coordinates(
    /// The call's ledger key: session, operation, step and source index.
    key: Key,
    /// The strand whose driver dispatched the call.
    strand: String,
    /// The grants the call's consumed approvals hold.
    grants: List(policy.Grant),
    /// The directory additions and standing grants the call runs under.
    authority: Authority,
  )
}

/// Names one generation the executor staged. `boot` is sixteen strong random
/// bytes drawn each time the scope's evolution actor starts, so a handle that
/// outlives an executor restart can never name a generation of the next boot;
/// `ordinal` counts the actor's stages. A handle is an opaque token the
/// orchestrator stores and sends back, and it is never reused.
pub type Handle {
  Handle(boot: BitArray, ordinal: Int)
}

/// How a staged generation takes over from its predecessor. The orchestrator
/// builds the matching `live.Generation` mode from it, because a plain
/// extension sent through the stateful path would be refused by the executor.
pub type Activation {
  /// The predecessor is retired and the successor staged from nothing.
  Replacement

  /// The generation's live contract opts in to `Prepare`, `Publish` and
  /// `Abort`: a compatible successor can take over its state in place.
  InPlace
}

/// What a successful stage tells the orchestrator, which is everything it needs
/// to build a `live.Generation` over messages.
pub type Staged {
  Staged(
    /// The generation's handle, sent back with every later message about it.
    handle: Handle,
    /// The extension's manifest name. Every hook refusal is attributed to it.
    name: String,
    /// The tools the generation serves, as declarations. The run closures are
    /// built on the orchestrator and send `EvolutionRun`.
    tools: List(tool.Described),
    /// The hook events the manifest declared. The orchestrator's bus skips an
    /// undeclared event before any message is sent.
    hooks: List(String),
    /// Whether the generation admits an in-place successor.
    activation: Activation,
    /// The handles of generations this stage superseded. They are already
    /// stopped; the orchestrator retires each so a failed stop is retried
    /// under custody.
    superseded: List(Handle),
  )
}

/// What a successful `Prepare` tells the orchestrator: the successor's handle
/// and the declarations of the tools it will serve once published.
pub type Prepared {
  Prepared(successor: Handle, tools: List(tool.Described))
}

/// One step of an in-place upgrade. `Prepare` builds the successor beside the
/// serving generation; `Publish` makes it the serving one; `Abort` discards it.
pub type TransitionStep {
  /// Builds `candidate` as the successor of `handle`, under `selection`.
  Prepare(
    handle: Handle,
    selection: record.Selection,
    candidate: record.Candidate,
  )

  /// Makes `successor` the serving generation in place of `handle`.
  Publish(handle: Handle, successor: Handle)

  /// Discards the unpublished `successor` of `handle`.
  Abort(handle: Handle, successor: Handle)
}

/// How the executor answered a `TransitionStep`.
pub type TransitionAnswer {
  /// The successor is built and waits to be published or aborted.
  TransitionPrepared(prepared: Prepared)

  /// The successor now serves. Answered again for a repeated `Publish`.
  TransitionPublished

  /// The successor is discarded, or never existed.
  TransitionAborted
}

/// What an `EvolutionRun` runs.
pub type Target {
  /// A tool of a staged generation, by name.
  Promoted(handle: Handle, tool: String)

  /// A program candidate, which is compiled for each call and never staged.
  Program(candidate: record.Candidate)
}

/// The six evolution requests that change no call row, as the host hands them
/// to the plane once the scope's fence has passed. Each carries the message's
/// fields without the fence (incarnation and token) and the subject its answer
/// goes to. `EvolutionEvaluate` and `EvolutionRun` are not here: they are
/// keyed calls, and the host admits them as it admits a `Run`.
pub type EvolutionRequest {
  /// Captures a candidate's source from `directory` of the workspace.
  SnapshotRequest(
    coordinates: Coordinates,
    directory: String,
    reply: Subject(Result(archive.Tree, Refusal)),
  )

  /// Builds and starts one approved selection.
  StageRequest(
    selection: record.Selection,
    candidate: record.Candidate,
    reply: Subject(Result(Staged, Refusal)),
  )

  /// Delivers one hook event to a generation's extension.
  HookRequest(
    handle: Handle,
    event: String,
    payload: MsgPackValue,
    within_ms: Int,
    reply: Subject(Result(MsgPackValue, hooks.HookFailure)),
  )

  /// Moves an in-place upgrade one step.
  TransitionRequest(
    step: TransitionStep,
    reply: Subject(Result(TransitionAnswer, Refusal)),
  )

  /// Stops and removes one generation.
  RetireRequest(handle: Handle, reply: Subject(Result(CloseOutcome, Refusal)))

  /// Asks a generation for its helper census.
  InventoryRequest(handle: Handle, reply: Subject(Result(JsonValue, Refusal)))
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
  /// `Run`. `owner_port` is where the scope's workspace calls back. Its shape
  /// is fixed across versions; see `version`.
  Attach(
    version: Int,
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

  /// Captures a candidate's source from `directory`, read-only and repeatable.
  /// The scope's `incarnation` and `token` are checked before the plane is
  /// asked. The orchestrator checks only the shape of `directory`; the
  /// executor resolves it under its own workspace.
  EvolutionSnapshot(
    incarnation: Int,
    token: BitArray,
    coordinates: Coordinates,
    directory: String,
    reply: Subject(Result(archive.Tree, Refusal)),
  )

  /// Runs a candidate's author tests. A keyed call: admitted by
  /// `coordinates.key` as a background execution is, so a re-send joins the
  /// live check or reads the stored report, which is a JSON value.
  EvolutionEvaluate(
    incarnation: Int,
    token: BitArray,
    coordinates: Coordinates,
    candidate: record.Candidate,
    reply: Subject(ExecutionAnswer),
  )

  /// Builds and starts the approved `selection`.
  EvolutionStage(
    session: String,
    incarnation: Int,
    token: BitArray,
    selection: record.Selection,
    candidate: record.Candidate,
    reply: Subject(Result(Staged, Refusal)),
  )

  /// Runs a promoted tool or a program. A keyed call: admitted by
  /// `coordinates.key` as a `Run` is, and answered with the tool's outcome.
  EvolutionRun(
    incarnation: Int,
    token: BitArray,
    coordinates: Coordinates,
    target: Target,
    args: JsonValue,
    reply: Subject(RunAnswer),
  )

  /// Delivers a hook event to a generation's extension, within `within_ms`.
  EvolutionHook(
    session: String,
    incarnation: Int,
    token: BitArray,
    handle: Handle,
    event: String,
    payload: MsgPackValue,
    within_ms: Int,
    reply: Subject(Result(MsgPackValue, hooks.HookFailure)),
  )

  /// Moves an in-place upgrade one step.
  EvolutionTransition(
    session: String,
    incarnation: Int,
    token: BitArray,
    step: TransitionStep,
    reply: Subject(Result(TransitionAnswer, Refusal)),
  )

  /// Stops and removes a generation. Retiring a handle the executor does not
  /// hold answers `AllRetired`, so a retry after a lost reply is safe.
  EvolutionRetire(
    session: String,
    incarnation: Int,
    token: BitArray,
    handle: Handle,
    reply: Subject(Result(CloseOutcome, Refusal)),
  )

  /// Asks a generation for its helper census. It changes nothing, so it has no
  /// token: the scope must be open at `incarnation`, and no more.
  EvolutionInventory(
    session: String,
    incarnation: Int,
    handle: Handle,
    reply: Subject(Result(JsonValue, Refusal)),
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

  /// The executor is building the scope's plane and asks which MCP servers
  /// its code mode reaches. Sent once per build, after the attach's version
  /// check passed, so both ends speak this version.
  AskMcpPlan(reply: Subject(McpPlan))
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

/// The coordinates of one door call: its key, strand, consumed grants and the
/// authority it runs under, and nothing else. The context's closures and its
/// machine-local fields (workspace, base policy, environment, clock, blob
/// root) stay on the orchestrator, because the executor rebuilds them from its
/// own machine and revalidates the authority against its own filesystem.
///
/// The context holds one grant list, the call's consumed grants, so the
/// authority's `standing` is that list.
///
/// ## Examples
///
/// ```gleam
/// // protocol.coordinates_of("session-1", ctx).key.step == ctx.step_id
/// ```
pub fn coordinates_of(session: String, ctx: tool.Ctx) -> Coordinates {
  Coordinates(
    key: Key(
      session:,
      op: ids.op_id_to_string(ctx.op_id),
      step: ctx.step_id,
      source_index: ctx.source_index,
    ),
    strand: ctx.strand,
    grants: ctx.grants,
    authority: Authority(access: ctx.directory_access, standing: ctx.grants),
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
    WorktreeFailed(reason:) ->
      "the executor could not make this session's Git worktree: " <> reason
    UnknownHandle -> "the executor holds no generation with that handle"
    AlreadyPublished ->
      "the executor already published that successor, so it cannot be aborted"
    StaleGeneration(serving:) ->
      "the executor already serves generation "
      <> int.to_string(serving)
      <> " of this selection"
    NoEvolution(reason:) ->
      "the executor cannot build evolution candidates for this session: "
      <> reason
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

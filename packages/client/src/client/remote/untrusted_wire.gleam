//// The frames an orchestrator and an untrusted executor exchange
//// (protocol-change/109).
////
//// A trusted executor is an Erlang peer, and the messages of
//// `client/remote/protocol` travel to it as terms, each carrying the `Subject`
//// its answer goes to. An untrusted executor is never a peer. The two machines
//// speak over one TLS connection the orchestrator dialled, in frames of JSON,
//// and nothing that names a process crosses. This module is the shape of those
//// frames: the same requests, replies, owner requests and answers as 078's
//// vocabulary, each with its subject taken out. `client/remote/untrusted_codec`
//// turns them into bytes and back, `client/remote/untrusted_link` is the
//// orchestrator's end and `client/remote/untrusted_gateway` the executor's.
////
//// ## Where the subjects went
////
//// A reply subject becomes a request id the orchestrator's link mints and keeps
//// the subject under, so a `Response` names the one request it answers. The
//// owner port's subject in an `Attach` becomes a `binding`: random bytes the
//// link mints for that attach, which the executor names on every `Callback` it
//// sends for the session and which the link checks before any owner sees the
//// callback. The executor plane's broker subject in the census has no wire form
//// at all, and the orchestrator puts a refusing handle in its place
//// (`remote_census_of`).
////
//// ## Kinds
////
//// The receiver of a `Response` or an `Answer` knows which request it sent, so
//// it decodes the reply against the kind that request expects (`response_kind`,
//// `answer_kind`) instead of trusting a tag the sender chose. A reply of
//// another kind is a protocol violation, not a value.
////
//// ## Flow
////
//// `response_kind` → `answer_kind` → `census_of` → `remote_census_of`
////
//// 1. `response_kind` and `answer_kind` say what reply a request or a callback
////    waits for, and `None` for the three that wait for none (`AckRequest`,
////    `StopExecutionRequest` and `TailCast`).
//// 2. `census_of` is the executor's projection of its census onto the wire,
////    and `remote_census_of` the orchestrator's way back, with the two fields
////    the orchestrator decides for itself.

import broker/broker
import broker/framing.{type CapOutcome}
import client/escalate
import client/notice
import client/owner_services.{
  type ExecutionTerms, type FactFault, type OwnerCapCall,
}
import client/remote/blob_transfer
import client/remote/protocol.{
  type CloseOutcome, type ExecutionAnswer, type GitIdentity, type Key,
  type Lookup, type McpPlan, type Refusal, type RunAnswer, type Unacked,
}
import client/remote/remote_census.{
  type McpStatus, type RemoteCensus, type StateCensus, RemoteCensus,
}
import client/state_object.{type State}
import client/state_transfer
import client/wiring.{type Authority}
import client/workspace_plane
import codemode/satellite.{type CapDenial}
import core/ids.{type Seq}
import core/json.{type JsonValue}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import runtime/api
import runtime/effects.{type ToolRun}
import tools/agent
import tools/codemode as codemode_tool
import tools/tool

/// The version of these frames, which `Hello` and `Welcome` carry beside
/// `protocol.version`. A change to any frame, request, reply, callback or
/// answer here changes it.
///
/// Version 2 added background code mode (slice 2 of protocol-change/109): the
/// requests `StartExecutionRequest` and `StopExecutionRequest`, the response
/// `ExecutionAnswered`, the callbacks `LaunchExecutionCall` and
/// `InteractExecutionCall`, and their answers.
///
/// Version 3 added placed blobs and outcomes fetched in pieces
/// (protocol-change/110): the frame `Oversized`, the requests
/// `BlobStatusRequest`, `BlobPutRequest` and `OutcomePieceRequest`, and their
/// responses.
///
/// Version 4 added the host seam's plan (protocol-change/111): the answer to
/// `AskMcpPlan` carries an optional `host` member, so an executor of version 3
/// would read a plan with no seam. The two versions are refused at the
/// handshake instead of silently serving a session more modules than its host
/// offered.
pub const version = 4

/// The largest frame either side sends or accepts, in bytes of body. The TLS
/// socket enforces it before a frame is buffered, so a larger one closes the
/// connection. It holds the 16 MiB result reservation of 078 once it has grown
/// by a third as base64, and the envelope around it.
pub const max_frame_bytes = 33_554_432

/// The largest piece of a repository state a frame carries, so a
/// `state_chunk` or a fetched piece fits in a frame with room for its
/// description and the base64 growth.
pub const max_piece_bytes = 16_777_216

/// The largest encoded tool outcome the orchestrator fetches in pieces when it
/// does not fit a frame (protocol-change/110): three frames' worth, which holds
/// a fix proof's 48 MiB of transcripts after JSON escaping. An `Oversized`
/// above it is answered to the asker as a lost outcome.
pub const max_outcome_bytes = 100_663_296

/// The bytes of a binding. Sixteen random bytes from the operating system's
/// strong source are not guessed.
pub const binding_bytes = 16

/// One frame, in either direction. Which frames a side accepts is the
/// receiver's rule, not the type's: an orchestrator accepts only `Welcome`,
/// `Response`, `Callback` and `Oversized`, and an executor only `Hello`,
/// `Request`, `Cancel` and `Answer`.
pub type Frame {
  /// The orchestrator's first frame on a connection.
  Hello(
    /// The sender's `version` of these frames.
    wire: Int,
    /// The sender's `protocol.version`.
    protocol: Int,
  )

  /// The executor's answer to `Hello`, with its own two numbers.
  Welcome(
    /// The executor's `version` of these frames.
    wire: Int,
    /// The executor's `protocol.version`.
    protocol: Int,
  )

  /// A request from the orchestrator. `id` is the link's, never reused.
  Request(id: Int, request: Request)

  /// The orchestrator no longer wants the answer to request `id`, because the
  /// process that asked has died. On a `run` that is an abort.
  Cancel(id: Int)

  /// The executor's reply to request `id`.
  Response(id: Int, response: Response)

  /// An owner request from the executor's plane for the session the
  /// `binding` was minted for. `id` increases by one per callback on the
  /// binding.
  Callback(binding: BitArray, id: Int, callback: Callback)

  /// The orchestrator's answer to callback `id` on `binding`.
  Answer(binding: BitArray, id: Int, answer: Answer)

  /// The executor's reply to request `id` in place of a `Response` that would
  /// not fit a frame: the reply holds a tool outcome whose encoding
  /// (`untrusted_codec.encode_outcome_bytes`) is `size` bytes with the SHA-256
  /// `digest`, which the orchestrator fetches with `OutcomePieceRequest`.
  Oversized(id: Int, size: Int, digest: String)
}

/// A `HostMessage` of 078 without its reply subject. Only the requests the
/// link carries are here (slices 1 and 2: tool calls, the ledger, state
/// transport and background executions); the link answers the evolution
/// requests itself without sending them.
pub type Request {
  /// `Attach`, with the binding the orchestrator minted in place of the owner
  /// port's subject.
  AttachRequest(
    /// The sender's `protocol.version`, as `Attach` carries it.
    version: Int,
    /// The orchestrator session.
    session: String,
    /// The workspace, as the executor names it.
    workspace: String,
    /// The scope incarnation this open attaches under.
    incarnation: Int,
    /// The attach token.
    token: BitArray,
    /// The binding the executor names on every callback for this attach.
    binding: BitArray,
  )

  /// `Run`.
  RunRequest(
    /// The call's key.
    key: Key,
    /// The incarnation the call was sent under.
    incarnation: Int,
    /// The attach token.
    token: BitArray,
    /// The call.
    run: ToolRun,
    /// The call's stored authority.
    authority: Authority,
  )

  /// `Query`.
  QueryRequest(key: Key)

  /// `QueryOrFence`.
  QueryOrFenceRequest(key: Key, incarnation: Int)

  /// `ListUnacked`.
  ListUnackedRequest(session: String)

  /// `Ack`, which has no reply.
  AckRequest(key: Key)

  /// `Close`.
  CloseRequest(session: String, workspace: String, incarnation: Int)

  /// `StateCapture`.
  StateCaptureRequest(
    /// The session whose scope's tree is captured.
    session: String,
    /// The incarnation the capture is asked under.
    incarnation: Int,
    /// The attach token.
    token: BitArray,
    /// What the capture may be thin against.
    basis: state_object.Basis,
    /// Whether the working tree is read.
    content: state_object.Content,
  )

  /// `StateApply`.
  StateApplyRequest(
    /// The session whose scope's tree receives the state.
    session: String,
    /// The incarnation the apply is asked under.
    incarnation: Int,
    /// The attach token.
    token: BitArray,
    /// The state, already held by the executor's store.
    state: State,
  )

  /// `StateChunk`: one piece of a state, sent to the executor.
  StateChunkRequest(piece: state_transfer.Piece)

  /// `StateStatus`.
  StateStatusRequest(hash: String)

  /// `StateFetch`: one piece of a state the executor holds, asked for by the
  /// orchestrator.
  StateFetchRequest(hash: String, offset: Int)

  /// How far a blob has got on the executor, for the session `binding` was
  /// minted for; a complete blob is claimed for it (protocol-change/110).
  BlobStatusRequest(binding: BitArray, digest: String)

  /// One piece of a blob the orchestrator places for the session `binding`
  /// was minted for.
  BlobPutRequest(binding: BitArray, piece: blob_transfer.Piece)

  /// The piece at `offset` of the encoded outcome the executor's ledger holds
  /// for `key`, after an `Oversized` reply. It is answered from `Query`, which
  /// never starts or joins a call.
  OutcomePieceRequest(key: Key, offset: Int)

  /// `StartExecution`: runs one background program, idempotently by `key`.
  StartExecutionRequest(
    /// The execution's key (`protocol.execution_key`).
    key: Key,
    /// The incarnation the execution was started under.
    incarnation: Int,
    /// The attach token.
    token: BitArray,
    /// What the launching call captured.
    terms: ExecutionTerms,
    /// The time the orchestrator's record has left, on its own clock.
    remaining_ms: Int,
  )

  /// `StopExecution`, which has no reply: the orchestrator's record of the
  /// execution has closed.
  StopExecutionRequest(key: Key, incarnation: Int)
}

/// The census an untrusted executor reports: `RemoteCensus` without the two
/// fields the orchestrator decides for itself, the broker subject (which
/// cannot cross) and the evolution census (which the link does not carry).
pub type Census {
  Census(
    /// The workspace plane's startup census.
    census: workspace_plane.Census,
    /// The workspace tools the plane offers, as the plane describes them.
    tools: List(tool.Described),
    /// The facts the system prompt is rendered from.
    prompt: workspace_plane.PromptFacts,
    /// The executor-side MCP servers and how each started.
    mcp: List(McpStatus),
    /// The session's branch, for a workspace in worktree mode.
    branch: Option(String),
    /// Whether the plane can capture and apply repository states.
    states: StateCensus,
  )
}

/// The reply to one `Request`, as the executor's host gave it.
pub type Response {
  /// The reply to `AttachRequest`.
  AttachAnswered(answer: Result(protocol.Attached(Census), Refusal))

  /// The reply to `RunRequest`.
  RunAnswered(answer: RunAnswer)

  /// The reply to `QueryRequest` and `QueryOrFenceRequest`.
  LookupAnswered(answer: Result(Lookup, Refusal))

  /// The reply to `ListUnackedRequest`.
  UnackedAnswered(answer: Result(Unacked, Refusal))

  /// The reply to `CloseRequest`.
  CloseAnswered(answer: Result(CloseOutcome, Refusal))

  /// The reply to `StateCaptureRequest`.
  CaptureAnswered(answer: Result(Option(State), Refusal))

  /// The reply to `StateApplyRequest`: the ref the state was applied as.
  ApplyAnswered(answer: Result(String, Refusal))

  /// The reply to `StateChunkRequest`.
  ChunkAnswered(verdict: state_transfer.Verdict)

  /// The reply to `StateStatusRequest`.
  StatusAnswered(answer: Result(state_transfer.Stage, String))

  /// The reply to `StateFetchRequest`.
  FetchAnswered(fetched: state_transfer.Fetched)

  /// The reply to `StartExecutionRequest`.
  ExecutionAnswered(answer: ExecutionAnswer)

  /// The reply to `BlobStatusRequest`.
  BlobStatusAnswered(answer: Result(blob_transfer.Stage, String))

  /// The reply to `BlobPutRequest`.
  BlobPutAnswered(verdict: blob_transfer.Verdict)

  /// The reply to `OutcomePieceRequest`.
  OutcomePieceAnswered(piece: OutcomePiece)
}

/// One piece of an encoded tool outcome, or why there is none.
pub type OutcomePiece {
  /// The bytes at `offset` of the outcome's encoding, which is `size` bytes in
  /// all with SHA-256 `digest`, as the executor encoded it for this answer.
  OutcomeServed(size: Int, digest: String, offset: Int, bytes: BitArray)

  /// The ledger holds no ended outcome for the key.
  OutcomeNotHeld(reason: String)
}

/// Which `Response` a request waits for. The receiver decodes a response
/// against this and nothing else.
pub type ResponseKind {
  /// `AttachAnswered`.
  AttachKind

  /// `RunAnswered`.
  RunKind

  /// `LookupAnswered`.
  LookupKind

  /// `UnackedAnswered`.
  UnackedKind

  /// `CloseAnswered`.
  CloseKind

  /// `CaptureAnswered`.
  CaptureKind

  /// `ApplyAnswered`.
  ApplyKind

  /// `ChunkAnswered`.
  ChunkKind

  /// `StatusAnswered`.
  StatusKind

  /// `FetchAnswered`.
  FetchKind

  /// `BlobStatusAnswered`.
  BlobStatusKind

  /// `BlobPutAnswered`.
  BlobPutKind

  /// `OutcomePieceAnswered`.
  OutcomePieceKind

  /// `ExecutionAnswered`.
  ExecutionKind
}

/// An `OwnerMessage` of 078 without its reply subject.
pub type Callback {
  /// `Escalate`.
  EscalateCall(refused: escalate.Refused, remaining_ms: Int)

  /// `FactGet`.
  FactGetCall(key: String)

  /// `FactPut`.
  FactPutCall(key: String, value: JsonValue, expected: Option(Seq))

  /// `FactPutBlind`.
  FactPutBlindCall(key: String, value: JsonValue)

  /// `FactDelete`.
  FactDeleteCall(key: String)

  /// `FactList`.
  FactListCall(prefix: String)

  /// `Notify`.
  NotifyCall(strand: String, work: notice.Work, text: String)

  /// `StrandActivity`.
  StrandActivityCall(strand: String)

  /// `Wake`.
  WakeCall(strand: String, text: String)

  /// `Holds`.
  HoldsCall(caller: agent.Caller, tool: String)

  /// `Tail`, which is a cast: it has no answer, and a lost one is a lost tail.
  TailCast(run: ToolRun, tail: tool.OutputTail)

  /// `Capability`.
  CapabilityCall(call: OwnerCapCall)

  /// `AskMcpPlan`.
  McpPlanCall

  /// `AskGitIdentity`.
  GitIdentityCall

  /// `LaunchExecution`: the executor's `code_mode` call asks the owner to
  /// claim a background execution's record.
  LaunchExecutionCall(terms: ExecutionTerms)

  /// `InteractExecution`: the executor's `code_mode` call checks, joins,
  /// cancels or sends to an execution the strand owns.
  InteractExecutionCall(
    /// The calling strand, which must own the handle.
    strand: String,
    /// The execution's handle.
    handle: String,
    /// What the call does to it.
    interaction: codemode_tool.Interaction,
    /// How long a join may wait, in milliseconds.
    within_ms: Int,
  )
}

/// The owner's answer to one `Callback`.
pub type Answer {
  /// The answer to `EscalateCall`.
  Decided(decision: escalate.Decision)

  /// The answer to `FactGetCall`.
  FactCellAnswered(answer: Result(Option(api.FactCell), FactFault))

  /// The answer to `FactPutCall`.
  FactSeqAnswered(answer: Result(Seq, FactFault))

  /// The answer to `FactPutBlindCall` and `FactDeleteCall`.
  FactDoneAnswered(answer: Result(Nil, FactFault))

  /// The answer to `FactListCall`.
  FactListAnswered(answer: Result(List(#(String, JsonValue)), FactFault))

  /// The answer to `NotifyCall`.
  NotifyAnswered(answer: Result(notice.Delivered, String))

  /// The answer to `StrandActivityCall`.
  ActivityAnswered(answer: Result(notice.Activity, String))

  /// The answer to `WakeCall`.
  WakeAnswered(answer: Result(Nil, String))

  /// The answer to `HoldsCall`.
  HoldsAnswered(answer: Result(Nil, agent.Refusal))

  /// The answer to `CapabilityCall`.
  CapabilityAnswered(answer: Result(CapOutcome, CapDenial))

  /// The answer to `McpPlanCall`.
  McpPlanAnswered(plan: McpPlan)

  /// The answer to `GitIdentityCall`.
  GitIdentityAnswered(identity: Option(GitIdentity))

  /// The answer to `LaunchExecutionCall`: the handle the owner minted, or why
  /// it would not.
  LaunchAnswered(answer: Result(JsonValue, String))

  /// The answer to `InteractExecutionCall`.
  InteractAnswered(answer: Result(JsonValue, String))
}

/// Which `Answer` a callback waits for.
pub type AnswerKind {
  /// `Decided`.
  DecidedKind

  /// `FactCellAnswered`.
  FactCellKind

  /// `FactSeqAnswered`.
  FactSeqKind

  /// `FactDoneAnswered`.
  FactDoneKind

  /// `FactListAnswered`.
  FactListKind

  /// `NotifyAnswered`.
  NotifyKind

  /// `ActivityAnswered`.
  ActivityKind

  /// `WakeAnswered`.
  WakeKind

  /// `HoldsAnswered`.
  HoldsKind

  /// `CapabilityAnswered`.
  CapabilityKind

  /// `McpPlanAnswered`.
  McpPlanKind

  /// `GitIdentityAnswered`.
  GitIdentityKind

  /// `LaunchAnswered`.
  LaunchKind

  /// `InteractAnswered`.
  InteractKind
}

/// The reason the orchestrator records in place of an untrusted executor's
/// evolution census.
pub const no_evolution_reason =
  "evolution is not carried over an untrusted executor link"

/// The reply a request waits for, or `None` for `AckRequest` and
/// `StopExecutionRequest`, which wait for nothing.
///
/// ## Examples
///
/// ```gleam
/// assert untrusted_wire.response_kind(untrusted_wire.QueryRequest(key))
///   == Some(untrusted_wire.LookupKind)
/// ```
pub fn response_kind(request: Request) -> Option(ResponseKind) {
  // Each request names the one reply its host answers with, so a response of
  // any other kind can only be a peer that is not following the protocol.
  case request {
    AttachRequest(..) -> Some(AttachKind)
    RunRequest(..) -> Some(RunKind)
    QueryRequest(..) | QueryOrFenceRequest(..) -> Some(LookupKind)
    ListUnackedRequest(..) -> Some(UnackedKind)
    AckRequest(..) -> None
    CloseRequest(..) -> Some(CloseKind)
    StateCaptureRequest(..) -> Some(CaptureKind)
    StateApplyRequest(..) -> Some(ApplyKind)
    StateChunkRequest(..) -> Some(ChunkKind)
    StateStatusRequest(..) -> Some(StatusKind)
    StateFetchRequest(..) -> Some(FetchKind)
    BlobStatusRequest(..) -> Some(BlobStatusKind)
    BlobPutRequest(..) -> Some(BlobPutKind)
    OutcomePieceRequest(..) -> Some(OutcomePieceKind)
    StartExecutionRequest(..) -> Some(ExecutionKind)
    StopExecutionRequest(..) -> None
  }
}

/// The answer a callback waits for, or `None` for `TailCast`, which waits for
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// assert untrusted_wire.answer_kind(untrusted_wire.McpPlanCall)
///   == Some(untrusted_wire.McpPlanKind)
/// ```
pub fn answer_kind(callback: Callback) -> Option(AnswerKind) {
  // The answer kinds mirror the reply subjects' types in `OwnerMessage`.
  case callback {
    EscalateCall(..) -> Some(DecidedKind)
    FactGetCall(..) -> Some(FactCellKind)
    FactPutCall(..) -> Some(FactSeqKind)
    FactPutBlindCall(..) | FactDeleteCall(..) -> Some(FactDoneKind)
    FactListCall(..) -> Some(FactListKind)
    NotifyCall(..) -> Some(NotifyKind)
    StrandActivityCall(..) -> Some(ActivityKind)
    WakeCall(..) -> Some(WakeKind)
    HoldsCall(..) -> Some(HoldsKind)
    TailCast(..) -> None
    CapabilityCall(..) -> Some(CapabilityKind)
    McpPlanCall -> Some(McpPlanKind)
    GitIdentityCall -> Some(GitIdentityKind)
    LaunchExecutionCall(..) -> Some(LaunchKind)
    InteractExecutionCall(..) -> Some(InteractKind)
  }
}

/// The executor's census as the wire carries it: everything but the broker
/// subject and the evolution census.
///
/// ## Examples
///
/// ```gleam
/// // let wire = untrusted_wire.census_of(remote)
/// // wire.tools == remote.tools
/// ```
pub fn census_of(remote: RemoteCensus) -> Census {
  Census(
    census: remote.census,
    tools: remote.tools,
    prompt: remote.prompt,
    mcp: remote.mcp,
    branch: remote.branch,
    states: remote.states,
  )
}

/// The orchestrator's `RemoteCensus` for a census an untrusted executor sent.
/// `broker` is the handle the orchestrator chose for the plane's broker, which
/// for slice 1 refuses every call, and the evolution census is the
/// orchestrator's ruling that this link carries none.
///
/// ## Examples
///
/// ```gleam
/// // let remote = untrusted_wire.remote_census_of(wire, refusing_broker)
/// // remote.evolution == remote_census.Uncompiled(untrusted_wire.no_evolution_reason)
/// ```
pub fn remote_census_of(
  census: Census,
  broker: Subject(broker.Msg),
) -> RemoteCensus {
  RemoteCensus(
    census: census.census,
    tools: census.tools,
    prompt: census.prompt,
    broker:,
    mcp: census.mcp,
    branch: census.branch,
    evolution: remote_census.Uncompiled(no_evolution_reason),
    states: census.states,
  )
}

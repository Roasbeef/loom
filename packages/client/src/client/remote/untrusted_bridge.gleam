//// Where 078's subjects meet the untrusted wire (protocol-change/109).
////
//// The orchestrator's surface and owner port speak `HostMessage` and
//// `OwnerMessage`, each carrying the `Subject` its answer goes to, and the
//// executor's host and workspace plane do the same. The untrusted link carries
//// none of those subjects. This module is the translation at each end, so the
//// processes on either side keep speaking 078's vocabulary and the link and
//// the gateway only move frames.
////
//// ## The orchestrator's half
////
//// `outbound` takes a `HostMessage` the surface sent and either makes it a
//// wire `Request`, keeping its subject as a typed `Reply`, or answers it at
//// once when slice 1 does not carry it. `deliver` hands a decoded `Response`
//// to the `Reply` it answers, and `refuse` answers a `Reply` with a refusal
//// when no response will come. `owner_answer` runs a `Callback` against the
//// session's owner port, which is how a callback that passed the link's checks
//// reaches the owner, and `refused_answer` is the in-band failure a callback
//// gets instead when it did not pass them.
////
//// ## The executor's half
////
//// `ask_host` turns a wire `Request` back into a `HostMessage` with a reply
//// subject owned by the calling process, sends it to the host and waits, so
//// the host monitors that process exactly as it monitors a trusted
//// orchestrator's effect process. `callback_of` turns an `OwnerMessage` the
//// plane sent into a wire `Callback`, keeping its subject as an `OwnerReply`,
//// and `answer_owner` and `fail_owner` answer that subject.
////
//// ## Failure values
////
//// A message that cannot be answered by its peer is answered here with the
//// in-band failure its type allows, the same values `client/remote/owner_link`
//// returns when the owner is unreachable, so the plane and the surface see
//// nothing they have not seen from a trusted link.
////
//// ## Flow
////
//// `outbound` → `deliver` → `refuse` → `owner_answer` → `refused_answer` →
//// `ask_host` → `callback_of` → `answer_owner` → `fail_owner`

import broker/broker
import broker/framing
import broker/internal/call
import client/escalate
import client/extension/hooks
import client/notice
import client/owner_services
import client/remote/address.{type Address}
import client/remote/owner_link
import client/remote/protocol.{type HostMessage, type OwnerMessage}
import client/remote/remote_census.{type RemoteCensus}
import client/remote/untrusted_wire.{
  type Answer, type AnswerKind, type Callback, type Request, type Response,
  type ResponseKind,
}
import client/state_object.{type State}
import client/state_transfer
import codemode/satellite
import core/ids.{type Seq}
import core/json.{type JsonValue}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import runtime/api
import tools/agent

/// What the orchestrator does with one `HostMessage`.
pub type Outbound {
  /// Send `request`. `reply` is where its response goes, or `None` for an
  /// `Ack`. `requester` is the process whose death cancels it. `port` is the
  /// owner port an `Attach` named, which the link records under the binding
  /// the request carries.
  Send(
    /// The wire request.
    request: Request,
    /// Where the response goes.
    reply: Option(Reply),
    /// The process that asked, when it can be found.
    requester: Option(Pid),
    /// For an attach, the session and its owner port.
    port: Option(#(String, Subject(OwnerMessage))),
  )

  /// The message is not carried by slice 1 and has been answered with a
  /// refusal already.
  Answered
}

/// A `HostMessage`'s reply subject, typed by what it waits for.
pub type Reply {
  /// `Attach`'s.
  AttachReply(
    subject: Subject(Result(protocol.Attached(RemoteCensus), protocol.Refusal)),
  )

  /// `Run`'s.
  RunReply(subject: Subject(protocol.RunAnswer))

  /// `Query`'s and `QueryOrFence`'s.
  LookupReply(subject: Subject(Result(protocol.Lookup, protocol.Refusal)))

  /// `ListUnacked`'s.
  UnackedReply(subject: Subject(Result(protocol.Unacked, protocol.Refusal)))

  /// `Close`'s.
  CloseReply(subject: Subject(Result(protocol.CloseOutcome, protocol.Refusal)))

  /// `StateCapture`'s.
  CaptureReply(subject: Subject(Result(Option(State), protocol.Refusal)))

  /// `StateApply`'s.
  ApplyReply(subject: Subject(Result(String, protocol.Refusal)))

  /// `StateChunk`'s.
  ChunkReply(subject: Subject(state_transfer.Verdict))

  /// `StateStatus`'s.
  StatusReply(subject: Subject(Result(state_transfer.Stage, String)))

  /// `StateFetch`'s.
  FetchReply(subject: Subject(state_transfer.Fetched))
}

/// An `OwnerMessage`'s reply subject, typed by what it waits for.
pub type OwnerReply {
  /// `Escalate`'s.
  DecisionReply(subject: Subject(escalate.Decision))

  /// `FactGet`'s.
  FactCellReply(
    subject: Subject(Result(Option(api.FactCell), owner_services.FactFault)),
  )

  /// `FactPut`'s.
  FactSeqReply(subject: Subject(Result(Seq, owner_services.FactFault)))

  /// `FactPutBlind`'s and `FactDelete`'s.
  FactDoneReply(subject: Subject(Result(Nil, owner_services.FactFault)))

  /// `FactList`'s.
  FactListReply(
    subject: Subject(
      Result(List(#(String, JsonValue)), owner_services.FactFault),
    ),
  )

  /// `Notify`'s.
  NotifyReply(subject: Subject(Result(notice.Delivered, String)))

  /// `StrandActivity`'s.
  ActivityReply(subject: Subject(Result(notice.Activity, String)))

  /// `Wake`'s.
  WakeReply(subject: Subject(Result(Nil, String)))

  /// `Holds`'s.
  HoldsReply(subject: Subject(Result(Nil, agent.Refusal)))

  /// `Capability`'s.
  CapabilityReply(
    subject: Subject(Result(framing.CapOutcome, satellite.CapDenial)),
  )

  /// `AskMcpPlan`'s.
  McpPlanReply(subject: Subject(protocol.McpPlan))

  /// `AskGitIdentity`'s.
  GitIdentityReply(subject: Subject(Option(protocol.GitIdentity)))
}

/// What the executor's proxy does with one `OwnerMessage`.
pub type Forward {
  /// Send `callback`; `reply` is where its answer goes, or `None` for a tail.
  Forwarded(callback: Callback, reply: Option(OwnerReply))

  /// Not carried by slice 1, and already answered with a failure.
  Declined
}

/// The text a message that slice 1 does not carry is refused with.
pub const not_carried = "not carried over an untrusted executor link"

/// The longest an escalation's answer is waited for, whatever the executor
/// says the call has left. A human decision can take a while, and a hostile
/// executor must not hold a forwarder for longer than a call could run.
pub const max_escalation_ms = 3_600_000

// The extra time an escalation's forwarder waits beyond the call's remaining
// time, for the owner's round trip; `owner_link` allows the same.
const escalate_slack_ms = 2000

// How long a fact, notice, wake or tool-list check may take at the owner, as
// `owner_link` allows.
const record_wait_ms = 15_000

// How long an owner-bound capability may take, as `owner_link` allows.
const capability_wait_ms = 120_000

// The capability denial code a callback the link refused carries. It is not
// `owner_unavailable`, because the owner is there and said no.
const refused_code = "owner_refused"

/// What the orchestrator does with a `HostMessage` the surface sent to the
/// link. `bind` is called once, for an `Attach`, with the session and its
/// owner port, and answers the binding that replaces the port on the wire: the
/// session's current one when the port is the same (a re-sent attach), or a
/// new one.
///
/// A message slice 1 does not carry (a background execution, an evolution
/// request) is answered here with a refusal that names this link, and is
/// never sent.
///
/// ## Examples
///
/// ```gleam
/// // case untrusted_bridge.outbound(message, fn(_session, _port) { binding }) {
/// //   untrusted_bridge.Send(request:, ..) -> send(request)
/// //   untrusted_bridge.Answered -> Nil
/// // }
/// ```
pub fn outbound(
  message: HostMessage(RemoteCensus),
  bind: fn(String, Subject(OwnerMessage)) -> BitArray,
) -> Outbound {
  // Each constructor keeps its fields and gives up its reply subject, which
  // the link keeps beside the request id it sends instead.
  case message {
    protocol.Attach(
      version:,
      session:,
      workspace:,
      incarnation:,
      token:,
      owner_port:,
      reply:,
    ) ->
      Send(
        request: untrusted_wire.AttachRequest(
          version:,
          session:,
          workspace:,
          incarnation:,
          token:,
          binding: bind(session, owner_port),
        ),
        reply: Some(AttachReply(reply)),
        requester: owner_of(reply),
        port: Some(#(session, owner_port)),
      )

    protocol.Run(key:, incarnation:, token:, run:, authority:, reply:) ->
      sent(
        untrusted_wire.RunRequest(key:, incarnation:, token:, run:, authority:),
        RunReply(reply),
        owner_of(reply),
      )

    protocol.Query(key:, reply:) ->
      sent(
        untrusted_wire.QueryRequest(key),
        LookupReply(reply),
        owner_of(reply),
      )

    protocol.QueryOrFence(key:, incarnation:, reply:) ->
      sent(
        untrusted_wire.QueryOrFenceRequest(key:, incarnation:),
        LookupReply(reply),
        owner_of(reply),
      )

    protocol.ListUnacked(session:, reply:) ->
      sent(
        untrusted_wire.ListUnackedRequest(session),
        UnackedReply(reply),
        owner_of(reply),
      )

    protocol.Ack(key:) ->
      Send(
        request: untrusted_wire.AckRequest(key),
        reply: None,
        requester: None,
        port: None,
      )

    protocol.Close(session:, workspace:, incarnation:, reply:) ->
      sent(
        untrusted_wire.CloseRequest(session:, workspace:, incarnation:),
        CloseReply(reply),
        owner_of(reply),
      )

    _ -> state_outbound(message)
  }
}

/// The state transport's five messages, and the messages slice 1 answers
/// without sending, split from `outbound` so each match reads as one table.
fn state_outbound(message: HostMessage(RemoteCensus)) -> Outbound {
  // The state messages are carried as they are; everything else that reaches
  // this arm is a message the untrusted link does not carry yet.
  case message {
    protocol.StateCapture(
      session:,
      incarnation:,
      token:,
      basis:,
      content:,
      reply:,
    ) ->
      sent(
        untrusted_wire.StateCaptureRequest(
          session:,
          incarnation:,
          token:,
          basis:,
          content:,
        ),
        CaptureReply(reply),
        owner_of(reply),
      )

    protocol.StateApply(session:, incarnation:, token:, state:, reply:) ->
      sent(
        untrusted_wire.StateApplyRequest(session:, incarnation:, token:, state:),
        ApplyReply(reply),
        owner_of(reply),
      )

    protocol.StateChunk(piece:, reply:) ->
      sent(
        untrusted_wire.StateChunkRequest(piece),
        ChunkReply(reply),
        owner_of(reply),
      )

    protocol.StateStatus(hash:, reply:) ->
      sent(
        untrusted_wire.StateStatusRequest(hash),
        StatusReply(reply),
        owner_of(reply),
      )

    protocol.StateFetch(hash:, offset:, reply:) ->
      sent(
        untrusted_wire.StateFetchRequest(hash:, offset:),
        FetchReply(reply),
        owner_of(reply),
      )

    _ -> uncarried(message)
  }
}

/// Answers a message slice 1 does not carry with the refusal its reply type
/// allows. The carried constructors never reach this function; their arms
/// answer nothing and exist only so the match stays exhaustive.
fn uncarried(message: HostMessage(RemoteCensus)) -> Outbound {
  let refusal = protocol.Invalid(not_carried)

  // Each reply type has one way to say "refused"; a stop needs no answer.
  case message {
    protocol.StartExecution(reply:, ..)
    | protocol.EvolutionEvaluate(reply:, ..) ->
      process.send(reply, protocol.ExecutionRefused(refusal))
    protocol.StopExecution(..) -> Nil
    protocol.EvolutionSnapshot(reply:, ..) ->
      process.send(reply, Error(refusal))
    protocol.EvolutionStage(reply:, ..) -> process.send(reply, Error(refusal))
    protocol.EvolutionRun(reply:, ..) ->
      process.send(reply, protocol.RunRefused(refusal))
    protocol.EvolutionHook(reply:, ..) ->
      process.send(reply, Error(hooks.Refused(not_carried)))
    protocol.EvolutionTransition(reply:, ..) ->
      process.send(reply, Error(refusal))
    protocol.EvolutionRetire(reply:, ..) -> process.send(reply, Error(refusal))
    protocol.EvolutionInventory(reply:, ..) ->
      process.send(reply, Error(refusal))
    protocol.Attach(..)
    | protocol.Run(..)
    | protocol.Query(..)
    | protocol.QueryOrFence(..)
    | protocol.ListUnacked(..)
    | protocol.Ack(..)
    | protocol.Close(..)
    | protocol.StateCapture(..)
    | protocol.StateApply(..)
    | protocol.StateChunk(..)
    | protocol.StateStatus(..)
    | protocol.StateFetch(..) -> Nil
  }

  Answered
}

/// A carried request with a reply.
fn sent(request: Request, reply: Reply, requester: Option(Pid)) -> Outbound {
  Send(request:, reply: Some(reply), requester:, port: None)
}

/// The process that owns a reply subject, which is the process whose death
/// cancels the request: the effect process for a `Run`.
fn owner_of(subject: Subject(reply)) -> Option(Pid) {
  process.subject_owner(subject) |> option.from_result
}

/// The response a reply waits for, which is the only kind the link decodes a
/// response to it as.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_bridge.kind_of(untrusted_bridge.RunReply(reply)) == untrusted_wire.RunKind
/// ```
pub fn kind_of(reply: Reply) -> ResponseKind {
  // One reply subject type answers to one response kind.
  case reply {
    AttachReply(..) -> untrusted_wire.AttachKind
    RunReply(..) -> untrusted_wire.RunKind
    LookupReply(..) -> untrusted_wire.LookupKind
    UnackedReply(..) -> untrusted_wire.UnackedKind
    CloseReply(..) -> untrusted_wire.CloseKind
    CaptureReply(..) -> untrusted_wire.CaptureKind
    ApplyReply(..) -> untrusted_wire.ApplyKind
    ChunkReply(..) -> untrusted_wire.ChunkKind
    StatusReply(..) -> untrusted_wire.StatusKind
    FetchReply(..) -> untrusted_wire.FetchKind
  }
}

/// Hands a decoded response to the subject it answers. An attach's census is
/// rebuilt with `broker` in place of the plane's broker subject, which cannot
/// cross. `Error(Nil)` means the response is not of the reply's kind, which
/// the link's decoding already rules out.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = untrusted_bridge.deliver(reply, response, refusing_broker)
/// ```
pub fn deliver(
  reply: Reply,
  response: Response,
  broker: Subject(broker.Msg),
) -> Result(Nil, Nil) {
  // Each reply takes exactly its own response. The last arm is the pairs the
  // kind check already refused, kept so a mismatch can never send a value of
  // the wrong type.
  case reply, response {
    AttachReply(subject), untrusted_wire.AttachAnswered(answer) ->
      Ok(process.send(
        subject,
        result.map(answer, fn(attached) {
          protocol.Attached(
            census: untrusted_wire.remote_census_of(attached.census, broker),
            executor_now_ms: attached.executor_now_ms,
            unacked: attached.unacked,
          )
        }),
      ))
    RunReply(subject), untrusted_wire.RunAnswered(answer) ->
      Ok(process.send(subject, answer))
    LookupReply(subject), untrusted_wire.LookupAnswered(answer) ->
      Ok(process.send(subject, answer))
    UnackedReply(subject), untrusted_wire.UnackedAnswered(answer) ->
      Ok(process.send(subject, answer))
    CloseReply(subject), untrusted_wire.CloseAnswered(answer) ->
      Ok(process.send(subject, answer))
    CaptureReply(subject), untrusted_wire.CaptureAnswered(answer) ->
      Ok(process.send(subject, answer))
    ApplyReply(subject), untrusted_wire.ApplyAnswered(answer) ->
      Ok(process.send(subject, answer))
    ChunkReply(subject), untrusted_wire.ChunkAnswered(verdict) ->
      Ok(process.send(subject, verdict))
    StatusReply(subject), untrusted_wire.StatusAnswered(answer) ->
      Ok(process.send(subject, answer))
    FetchReply(subject), untrusted_wire.FetchAnswered(fetched) ->
      Ok(process.send(subject, fetched))
    _, _ -> Error(Nil)
  }
}

/// Answers a reply with `refusal`, in the form its type allows, when no
/// response will come.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_bridge.refuse(reply, protocol.Unreachable("the link is full"))
/// ```
pub fn refuse(reply: Reply, refusal: protocol.Refusal) -> Nil {
  let reason = protocol.describe(refusal)

  // The state transport's three piece replies have no `Refusal` in their
  // types, so they carry its description instead.
  case reply {
    AttachReply(subject) -> process.send(subject, Error(refusal))
    RunReply(subject) -> process.send(subject, protocol.RunRefused(refusal))
    LookupReply(subject) -> process.send(subject, Error(refusal))
    UnackedReply(subject) -> process.send(subject, Error(refusal))
    CloseReply(subject) -> process.send(subject, Error(refusal))
    CaptureReply(subject) -> process.send(subject, Error(refusal))
    ApplyReply(subject) -> process.send(subject, Error(refusal))
    ChunkReply(subject) -> process.send(subject, state_transfer.Failed(reason))
    StatusReply(subject) -> process.send(subject, Error(reason))
    FetchReply(subject) ->
      process.send(subject, state_transfer.FetchFailed(reason))
  }
}

/// Runs a callback that passed the link's checks against the session's owner
/// port, waiting as `owner_link` would, and answers with what the owner said
/// or with the in-band failure for an owner that did not answer. A tail is a
/// cast and answers `None`. This blocks, so the link runs it in a task.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_bridge.owner_answer(port, untrusted_wire.McpPlanCall)
/// // == Some(untrusted_wire.McpPlanAnswered(plan))
/// ```
pub fn owner_answer(
  port: Subject(OwnerMessage),
  callback: Callback,
) -> Option(Answer) {
  let unavailable = owner_link.unavailable_text

  // Each callback is the `OwnerMessage` of the same name with a reply subject
  // this process owns; a fault while waiting becomes the type's failure.
  case callback {
    untrusted_wire.EscalateCall(refused:, remaining_ms:) -> {
      let remaining_ms = int.clamp(remaining_ms, min: 0, max: max_escalation_ms)
      call.try_call(
        port,
        waiting: remaining_ms + escalate_slack_ms,
        sending: protocol.Escalate(refused, remaining_ms, _),
      )
      |> result.unwrap(escalate.Settle)
      |> untrusted_wire.Decided
      |> Some
    }

    untrusted_wire.FactGetCall(key:) ->
      asked(port, protocol.FactGet(key, _))
      |> result.lazy_unwrap(fn() { Error(owner_services.Failed(unavailable)) })
      |> untrusted_wire.FactCellAnswered
      |> Some

    untrusted_wire.FactPutCall(key:, value:, expected:) ->
      asked(port, protocol.FactPut(key, value, expected, _))
      |> result.lazy_unwrap(fn() { Error(owner_services.Failed(unavailable)) })
      |> untrusted_wire.FactSeqAnswered
      |> Some

    untrusted_wire.FactPutBlindCall(key:, value:) ->
      asked(port, protocol.FactPutBlind(key, value, _))
      |> result.lazy_unwrap(fn() { Error(owner_services.Failed(unavailable)) })
      |> untrusted_wire.FactDoneAnswered
      |> Some

    untrusted_wire.FactDeleteCall(key:) ->
      asked(port, protocol.FactDelete(key, _))
      |> result.lazy_unwrap(fn() { Error(owner_services.Failed(unavailable)) })
      |> untrusted_wire.FactDoneAnswered
      |> Some

    untrusted_wire.FactListCall(prefix:) ->
      asked(port, protocol.FactList(prefix, _))
      |> result.lazy_unwrap(fn() { Error(owner_services.Failed(unavailable)) })
      |> untrusted_wire.FactListAnswered
      |> Some

    _ -> notice_answer(port, callback)
  }
}

/// The notices, the tool-list check, tails, capabilities and the two plane
/// questions, split from `owner_answer` so each match reads as one table.
fn notice_answer(
  port: Subject(OwnerMessage),
  callback: Callback,
) -> Option(Answer) {
  let unavailable = owner_link.unavailable_text

  // As in `owner_answer`: the same message, a reply subject owned here, and
  // the owner-unavailable failure when no answer comes.
  case callback {
    untrusted_wire.NotifyCall(strand:, work:, text:) ->
      asked(port, protocol.Notify(strand, work, text, _))
      |> result.lazy_unwrap(fn() { Error(unavailable) })
      |> untrusted_wire.NotifyAnswered
      |> Some

    untrusted_wire.StrandActivityCall(strand:) ->
      asked(port, protocol.StrandActivity(strand, _))
      |> result.lazy_unwrap(fn() { Error(unavailable) })
      |> untrusted_wire.ActivityAnswered
      |> Some

    untrusted_wire.WakeCall(strand:, text:) ->
      asked(port, protocol.Wake(strand, text, _))
      |> result.lazy_unwrap(fn() { Error(unavailable) })
      |> untrusted_wire.WakeAnswered
      |> Some

    untrusted_wire.HoldsCall(caller:, tool:) ->
      asked(port, protocol.Holds(caller, tool, _))
      |> result.unwrap(Error(agent.AgencyUnavailable))
      |> untrusted_wire.HoldsAnswered
      |> Some

    untrusted_wire.TailCast(run:, tail:) -> {
      process.send(port, protocol.Tail(run, tail))
      None
    }

    untrusted_wire.CapabilityCall(call: owner_call) ->
      call.try_call(
        port,
        waiting: capability_wait_ms,
        sending: protocol.Capability(owner_call, _),
      )
      |> result.lazy_unwrap(fn() {
        Error(satellite.CapDenial(owner_link.unavailable_code, unavailable))
      })
      |> untrusted_wire.CapabilityAnswered
      |> Some

    untrusted_wire.McpPlanCall ->
      asked(port, protocol.AskMcpPlan)
      |> result.lazy_unwrap(fn() { protocol.McpPlan(served: [], expected: []) })
      |> untrusted_wire.McpPlanAnswered
      |> Some

    untrusted_wire.GitIdentityCall ->
      call.try_call(
        port,
        waiting: owner_link.identity_wait_ms,
        sending: protocol.AskGitIdentity,
      )
      |> result.unwrap(None)
      |> untrusted_wire.GitIdentityAnswered
      |> Some

    untrusted_wire.EscalateCall(..)
    | untrusted_wire.FactGetCall(..)
    | untrusted_wire.FactPutCall(..)
    | untrusted_wire.FactPutBlindCall(..)
    | untrusted_wire.FactDeleteCall(..)
    | untrusted_wire.FactListCall(..) -> owner_answer(port, callback)
  }
}

/// A monitored call to the owner port with the record budget.
fn asked(
  port: Subject(OwnerMessage),
  make: fn(Subject(reply)) -> OwnerMessage,
) -> Result(reply, call.CallFault) {
  call.try_call(port, waiting: record_wait_ms, sending: make)
}

/// The answer a callback gets when the link refused it: the failure its type
/// allows, carrying `reason`, so the plane reads a refusal and never a value
/// the owner did not give. A tail has no answer.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_bridge.refused_answer(untrusted_wire.EscalateCall(refused, 10), "no call in flight")
/// // == Some(untrusted_wire.Decided(escalate.Settle))
/// ```
pub fn refused_answer(callback: Callback, reason: String) -> Option(Answer) {
  // An escalation the link refused settles as refused, as with no escalation
  // plane; every other kind carries the reason in its own error.
  case callback {
    untrusted_wire.EscalateCall(..) ->
      Some(untrusted_wire.Decided(escalate.Settle))
    untrusted_wire.FactGetCall(..) ->
      Some(
        untrusted_wire.FactCellAnswered(Error(owner_services.Failed(reason))),
      )
    untrusted_wire.FactPutCall(..) ->
      Some(untrusted_wire.FactSeqAnswered(Error(owner_services.Failed(reason))))
    untrusted_wire.FactPutBlindCall(..) | untrusted_wire.FactDeleteCall(..) ->
      Some(
        untrusted_wire.FactDoneAnswered(Error(owner_services.Failed(reason))),
      )
    untrusted_wire.FactListCall(..) ->
      Some(
        untrusted_wire.FactListAnswered(Error(owner_services.Failed(reason))),
      )
    untrusted_wire.NotifyCall(..) ->
      Some(untrusted_wire.NotifyAnswered(Error(reason)))
    untrusted_wire.StrandActivityCall(..) ->
      Some(untrusted_wire.ActivityAnswered(Error(reason)))
    untrusted_wire.WakeCall(..) ->
      Some(untrusted_wire.WakeAnswered(Error(reason)))
    untrusted_wire.HoldsCall(..) ->
      Some(untrusted_wire.HoldsAnswered(Error(agent.PlaneFailed(reason))))
    untrusted_wire.TailCast(..) -> None
    untrusted_wire.CapabilityCall(..) ->
      Some(
        untrusted_wire.CapabilityAnswered(
          Error(satellite.CapDenial(refused_code, reason)),
        ),
      )
    untrusted_wire.McpPlanCall ->
      Some(untrusted_wire.McpPlanAnswered(protocol.McpPlan([], [])))
    untrusted_wire.GitIdentityCall ->
      Some(untrusted_wire.GitIdentityAnswered(None))
  }
}

/// Runs one wire request against the executor's host from the calling
/// process, which owns the reply subject the host sees and so is the process
/// whose death the host reads as an abort. Waits for the host's answer, or for
/// its `DOWN`, which is answered as an executor fault. An `Ack` has no answer.
///
/// `owner_port` is the proxy that stands in for the session's owner port, and
/// only an attach uses it.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_bridge.ask_host(host, untrusted_wire.QueryRequest(key), None)
/// // == Some(untrusted_wire.LookupAnswered(Ok(protocol.Missing)))
/// ```
pub fn ask_host(
  host: Address(HostMessage(RemoteCensus)),
  request: Request,
  owner_port: Option(Subject(OwnerMessage)),
) -> Option(Response) {
  let fault = protocol.ExecutorFault("the executor's host is gone")

  // Each request is the `HostMessage` of the same name with a reply subject
  // this process owns.
  case request, owner_port {
    untrusted_wire.AttachRequest(
      version:,
      session:,
      workspace:,
      incarnation:,
      token:,
      binding: _,
    ),
      Some(port)
    ->
      Some(asked_host(
        host,
        protocol.Attach(
          version,
          session,
          workspace,
          incarnation,
          token,
          port,
          _,
        ),
        fn(answer) {
          untrusted_wire.AttachAnswered(result.map(answer, projected))
        },
        untrusted_wire.AttachAnswered(Error(fault)),
      ))

    untrusted_wire.AttachRequest(..), None ->
      Some(
        untrusted_wire.AttachAnswered(
          Error(protocol.Invalid("an attach needs an owner port")),
        ),
      )

    untrusted_wire.RunRequest(key:, incarnation:, token:, run:, authority:), _
    ->
      Some(asked_host(
        host,
        protocol.Run(key, incarnation, token, run, authority, _),
        untrusted_wire.RunAnswered,
        untrusted_wire.RunAnswered(protocol.RunRefused(fault)),
      ))

    untrusted_wire.AckRequest(key:), _ -> {
      address.deliver(host, protocol.Ack(key))
      None
    }

    _, _ -> Some(ledger_ask(host, request, fault))
  }
}

/// The ledger's and the state transport's questions, split from `ask_host`
/// so each match reads as one table.
fn ledger_ask(
  host: Address(HostMessage(RemoteCensus)),
  request: Request,
  fault: protocol.Refusal,
) -> Response {
  let reason = protocol.describe(fault)

  // As in `ask_host`; the two arms that `ask_host` answers itself only keep
  // this match exhaustive and are never reached.
  case request {
    untrusted_wire.QueryRequest(key:) ->
      asked_host(
        host,
        protocol.Query(key, _),
        untrusted_wire.LookupAnswered,
        untrusted_wire.LookupAnswered(Error(fault)),
      )
    untrusted_wire.QueryOrFenceRequest(key:, incarnation:) ->
      asked_host(
        host,
        protocol.QueryOrFence(key, incarnation, _),
        untrusted_wire.LookupAnswered,
        untrusted_wire.LookupAnswered(Error(fault)),
      )
    untrusted_wire.ListUnackedRequest(session:) ->
      asked_host(
        host,
        protocol.ListUnacked(session, _),
        untrusted_wire.UnackedAnswered,
        untrusted_wire.UnackedAnswered(Error(fault)),
      )
    untrusted_wire.CloseRequest(session:, workspace:, incarnation:) ->
      asked_host(
        host,
        protocol.Close(session, workspace, incarnation, _),
        untrusted_wire.CloseAnswered,
        untrusted_wire.CloseAnswered(Error(fault)),
      )
    untrusted_wire.StateCaptureRequest(
      session:,
      incarnation:,
      token:,
      basis:,
      content:,
    ) ->
      asked_host(
        host,
        protocol.StateCapture(session, incarnation, token, basis, content, _),
        untrusted_wire.CaptureAnswered,
        untrusted_wire.CaptureAnswered(Error(fault)),
      )
    untrusted_wire.StateApplyRequest(session:, incarnation:, token:, state:) ->
      asked_host(
        host,
        protocol.StateApply(session, incarnation, token, state, _),
        untrusted_wire.ApplyAnswered,
        untrusted_wire.ApplyAnswered(Error(fault)),
      )
    untrusted_wire.StateChunkRequest(piece:) ->
      asked_host(
        host,
        protocol.StateChunk(piece, _),
        untrusted_wire.ChunkAnswered,
        untrusted_wire.ChunkAnswered(state_transfer.Failed(reason)),
      )
    untrusted_wire.StateStatusRequest(hash:) ->
      asked_host(
        host,
        protocol.StateStatus(hash, _),
        untrusted_wire.StatusAnswered,
        untrusted_wire.StatusAnswered(Error(reason)),
      )
    untrusted_wire.StateFetchRequest(hash:, offset:) ->
      asked_host(
        host,
        protocol.StateFetch(hash, offset, _),
        untrusted_wire.FetchAnswered,
        untrusted_wire.FetchAnswered(state_transfer.FetchFailed(reason)),
      )
    untrusted_wire.AttachRequest(..)
    | untrusted_wire.RunRequest(..)
    | untrusted_wire.AckRequest(..) ->
      untrusted_wire.LookupAnswered(
        Error(protocol.Invalid("misrouted request")),
      )
  }
}

/// Sends one request to the host with a reply subject owned by this process
/// and waits for the reply or the host's `DOWN`. There is no deadline: a call
/// ends on the executor's own clock, and the host answers every request it
/// admits.
fn asked_host(
  host: Address(HostMessage(RemoteCensus)),
  make: fn(Subject(reply)) -> HostMessage(RemoteCensus),
  wrap: fn(reply) -> Response,
  lost: Response,
) -> Response {
  let reply = process.new_subject()

  // Watching before sending means a host that is already gone answers with
  // its `DOWN` instead of with silence.
  let watch = address.watch(host)
  address.deliver(host, make(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, wrap)
    |> process.select_specific_monitor(watch, fn(_down) { lost })
    |> process.selector_receive_forever
  process.demonitor_process(watch)
  answer
}

/// An attach reply's census, projected onto the wire.
fn projected(
  attached: protocol.Attached(RemoteCensus),
) -> protocol.Attached(untrusted_wire.Census) {
  protocol.Attached(
    census: untrusted_wire.census_of(attached.census),
    executor_now_ms: attached.executor_now_ms,
    unacked: attached.unacked,
  )
}

/// What the executor's proxy does with an `OwnerMessage` the plane sent: a
/// wire callback and the subject its answer goes to, or, for a background
/// execution's two messages, a refusal sent at once.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_bridge.callback_of(protocol.AskMcpPlan(reply))
/// // == untrusted_bridge.Forwarded(untrusted_wire.McpPlanCall, Some(untrusted_bridge.McpPlanReply(reply)))
/// ```
pub fn callback_of(message: OwnerMessage) -> Forward {
  // Each owner message keeps its fields and gives up its reply subject, which
  // the proxy keeps beside the callback id it sends instead.
  case message {
    protocol.Escalate(refused:, remaining_ms:, reply:) ->
      Forwarded(
        untrusted_wire.EscalateCall(refused:, remaining_ms:),
        Some(DecisionReply(reply)),
      )
    protocol.FactGet(key:, reply:) ->
      Forwarded(untrusted_wire.FactGetCall(key), Some(FactCellReply(reply)))
    protocol.FactPut(key:, value:, expected:, reply:) ->
      Forwarded(
        untrusted_wire.FactPutCall(key:, value:, expected:),
        Some(FactSeqReply(reply)),
      )
    protocol.FactPutBlind(key:, value:, reply:) ->
      Forwarded(
        untrusted_wire.FactPutBlindCall(key:, value:),
        Some(FactDoneReply(reply)),
      )
    protocol.FactDelete(key:, reply:) ->
      Forwarded(untrusted_wire.FactDeleteCall(key), Some(FactDoneReply(reply)))
    protocol.FactList(prefix:, reply:) ->
      Forwarded(untrusted_wire.FactListCall(prefix), Some(FactListReply(reply)))
    protocol.Notify(strand:, work:, text:, reply:) ->
      Forwarded(
        untrusted_wire.NotifyCall(strand:, work:, text:),
        Some(NotifyReply(reply)),
      )
    protocol.StrandActivity(strand:, reply:) ->
      Forwarded(
        untrusted_wire.StrandActivityCall(strand),
        Some(ActivityReply(reply)),
      )
    protocol.Wake(strand:, text:, reply:) ->
      Forwarded(untrusted_wire.WakeCall(strand:, text:), Some(WakeReply(reply)))
    protocol.Holds(caller:, tool:, reply:) ->
      Forwarded(
        untrusted_wire.HoldsCall(caller:, tool:),
        Some(HoldsReply(reply)),
      )
    protocol.Tail(run:, tail:) ->
      Forwarded(untrusted_wire.TailCast(run:, tail:), None)
    protocol.Capability(call:, reply:) ->
      Forwarded(
        untrusted_wire.CapabilityCall(call),
        Some(CapabilityReply(reply)),
      )
    protocol.AskMcpPlan(reply:) ->
      Forwarded(untrusted_wire.McpPlanCall, Some(McpPlanReply(reply)))
    protocol.AskGitIdentity(reply:) ->
      Forwarded(untrusted_wire.GitIdentityCall, Some(GitIdentityReply(reply)))
    protocol.LaunchExecution(reply:, ..) -> {
      process.send(reply, Error(not_carried))
      Declined
    }
    protocol.InteractExecution(reply:, ..) -> {
      process.send(reply, Error(not_carried))
      Declined
    }
  }
}

/// The answer an owner reply waits for, which is the only kind the proxy
/// decodes an answer to it as.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_bridge.answer_kind_of(untrusted_bridge.McpPlanReply(reply)) == untrusted_wire.McpPlanKind
/// ```
pub fn answer_kind_of(reply: OwnerReply) -> AnswerKind {
  // One owner reply subject type answers to one answer kind.
  case reply {
    DecisionReply(..) -> untrusted_wire.DecidedKind
    FactCellReply(..) -> untrusted_wire.FactCellKind
    FactSeqReply(..) -> untrusted_wire.FactSeqKind
    FactDoneReply(..) -> untrusted_wire.FactDoneKind
    FactListReply(..) -> untrusted_wire.FactListKind
    NotifyReply(..) -> untrusted_wire.NotifyKind
    ActivityReply(..) -> untrusted_wire.ActivityKind
    WakeReply(..) -> untrusted_wire.WakeKind
    HoldsReply(..) -> untrusted_wire.HoldsKind
    CapabilityReply(..) -> untrusted_wire.CapabilityKind
    McpPlanReply(..) -> untrusted_wire.McpPlanKind
    GitIdentityReply(..) -> untrusted_wire.GitIdentityKind
  }
}

/// Hands a decoded answer to the owner reply it answers. `Error(Nil)` means
/// the answer is not of the reply's kind, which the proxy's decoding already
/// rules out.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = untrusted_bridge.answer_owner(reply, answer)
/// ```
pub fn answer_owner(reply: OwnerReply, answer: Answer) -> Result(Nil, Nil) {
  // Each reply takes exactly its own answer; the last arm is the mismatches
  // the kind check refused, kept so a wrong kind is never sent.
  case reply, answer {
    DecisionReply(subject), untrusted_wire.Decided(decision) ->
      Ok(process.send(subject, decision))
    FactCellReply(subject), untrusted_wire.FactCellAnswered(answer) ->
      Ok(process.send(subject, answer))
    FactSeqReply(subject), untrusted_wire.FactSeqAnswered(answer) ->
      Ok(process.send(subject, answer))
    FactDoneReply(subject), untrusted_wire.FactDoneAnswered(answer) ->
      Ok(process.send(subject, answer))
    FactListReply(subject), untrusted_wire.FactListAnswered(answer) ->
      Ok(process.send(subject, answer))
    NotifyReply(subject), untrusted_wire.NotifyAnswered(answer) ->
      Ok(process.send(subject, answer))
    ActivityReply(subject), untrusted_wire.ActivityAnswered(answer) ->
      Ok(process.send(subject, answer))
    WakeReply(subject), untrusted_wire.WakeAnswered(answer) ->
      Ok(process.send(subject, answer))
    HoldsReply(subject), untrusted_wire.HoldsAnswered(answer) ->
      Ok(process.send(subject, answer))
    CapabilityReply(subject), untrusted_wire.CapabilityAnswered(answer) ->
      Ok(process.send(subject, answer))
    McpPlanReply(subject), untrusted_wire.McpPlanAnswered(plan) ->
      Ok(process.send(subject, plan))
    GitIdentityReply(subject), untrusted_wire.GitIdentityAnswered(identity) ->
      Ok(process.send(subject, identity))
    _, _ -> Error(Nil)
  }
}

/// Answers an owner reply with the failure `owner_link` gives when the owner
/// is unreachable: the orchestrator has no connection, or the connection
/// dropped before it answered.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_bridge.fail_owner(untrusted_bridge.DecisionReply(reply))
/// // -> the escalation settles as refused
/// ```
pub fn fail_owner(reply: OwnerReply) -> Nil {
  let unavailable = owner_link.unavailable_text

  // The same table as `owner_link`'s module documentation.
  case reply {
    DecisionReply(subject) -> process.send(subject, escalate.Settle)
    FactCellReply(subject) ->
      process.send(subject, Error(owner_services.Failed(unavailable)))
    FactSeqReply(subject) ->
      process.send(subject, Error(owner_services.Failed(unavailable)))
    FactDoneReply(subject) ->
      process.send(subject, Error(owner_services.Failed(unavailable)))
    FactListReply(subject) ->
      process.send(subject, Error(owner_services.Failed(unavailable)))
    NotifyReply(subject) -> process.send(subject, Error(unavailable))
    ActivityReply(subject) -> process.send(subject, Error(unavailable))
    WakeReply(subject) -> process.send(subject, Error(unavailable))
    HoldsReply(subject) -> process.send(subject, Error(agent.AgencyUnavailable))
    CapabilityReply(subject) ->
      process.send(
        subject,
        Error(satellite.CapDenial(owner_link.unavailable_code, unavailable)),
      )
    McpPlanReply(subject) -> process.send(subject, protocol.McpPlan([], []))
    GitIdentityReply(subject) -> process.send(subject, None)
  }
}

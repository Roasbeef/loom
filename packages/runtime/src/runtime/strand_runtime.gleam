//// The strand driver: the actor that interprets the pure machine's
//// actions against the writer and the injected effect seam.
////
//// The loop is the machine's drive contract, verbatim: load registers →
//// build `PlannerInputs` (a fresh id generator every pass) →
//// `next_action` → on `Transition`/`Finish` commit and re-plan; on
//// `Dispatch` commit the intent transaction *then* start the effect,
//// feeding its outcome back as the matching observation; on
//// `AwaitEffect(key)` resolve the key — wait on the live effect, run the
//// named hook, or (for a crash-restored `effect_pending` with no live
//// continuation) report the orphan observation; on `Wait` schedule a
//// retry timer or a poll permit. `StaleExpectation` on commit means
//// reload and re-plan; `Fault` means fault the strand (stop abnormally —
//// the supervisor restarts it, and recovery is the same loop over the
//// restored registers, spec §3.1). `strand.last_result` is never read.
////
//// Live effects run on spawned processes the driver monitors; their
//// outcomes come back as ordinary messages. A tool process that dies without
//// reporting settles as a synthetic tool error. A provider process instead
//// faults the driver: its reaper cancels the published stream owner and the
//// replacement waits for that owner to drain before recovery may dispatch.
//// Converting such a death directly into a retryable provider result would
//// let the current incarnation retry beside cleanup it no longer owns.
//// Every effect process is also linked to the incarnation's **reaper** (a tiny
//// trapping companion process that dies when the driver does), so a
//// driver restart cannot leak a live effect into the next incarnation:
//// the exclusivity gate and the replay decision both read the
//// incarnation-local `live` list, and both are sound only because no
//// effect outlives its incarnation.
////
//// Doorbells: `Nudge` triggers a re-plan and its loss is harmless by
//// construction — the periodic `PollTick` (the checkpoint poll) finds
//// queued work anyway, and any commit racing the strand's own commits
//// surfaces as a stale expectation, forcing a reload that sees the new
//// state.

import core/clock.{type Clock}
import core/corruption
import core/entry
import core/ids.{type EntryId, type OpId, type Seq}
import core/json.{type JsonValue}
import core/message.{
  type AgentMessage, type DeferredHandle, type ToolCall, AssistantMessage,
  AssistantToolCall, ToolResultMessage, ToolResultText,
}
import core/register
import core/tx
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import machine/classification
import machine/codec
import machine/operation.{
  type NormalizedRetryPolicy, type Operation, type OperationState,
  type PendingEntry, type StructuralPreparation, type SummaryGeneration,
  Assistant, AwaitingDeferred, Compacting, CompactionState,
  DeferredEffectPending, DeferredSuspended, Generating, GenerationReady,
  NavigationState, RunState, SummarizedNavigation, Tools,
}
import machine/planner.{type Observation, NoObservation}
import machine/queue
import machine/strand.{type StrandConfiguration, type StrandState}
import provider/stream
import runtime/effects.{type Effects}
import runtime/escalation
import runtime/internal/provider_custodian
import runtime/writer
import session/session
import storage/storage
import telemetry/context
import telemetry/field
import telemetry/log.{type Logger}

/// Driver configuration.
///
/// Constructor invariants: `writer` names the session's StorageWriter
/// (a name, not a subject, so restarts re-resolve it); `stream_options`
/// is the runtime-owned opaque options bag snapshotted into generation
/// steps; `retry_policy` is the normalized policy snapshotted likewise;
/// `poll_interval_ms` is the checkpoint-poll period (positive);
/// `claim_reaper` publishes this incarnation's effect reaper and does not
/// return until the ledger has acknowledged older generations as drained;
/// `logger` is injected (§0.2) and need not carry a strand — `start`
/// scopes it to the strand it is starting.
pub type Options {
  Options(
    writer: Name(writer.Message),
    strand: String,
    effects: Effects,
    stream_options: JsonValue,
    retry_policy: NormalizedRetryPolicy,
    poll_interval_ms: Int,
    claim_reaper: fn(String, Pid) -> List(Pid),
    logger: Logger,
  )
}

/// Which dispatched effect an outcome belongs to. Tokens are compared
/// structurally against the durable state's reserved identities, so an
/// outcome from a previous incarnation's effect can never be mistaken for
/// a live one.
pub type EffectToken {
  /// A pending assistant generation.
  AssistantEffect(operation: OpId, step_id: String, response_entry: EntryId)
  /// A pending tool execution (or safe replay).
  ToolEffect(
    operation: OpId,
    step_id: String,
    source_index: Int,
    result_entry: EntryId,
  )
  /// A pending deferred fetch.
  PollEffect(
    operation: OpId,
    step_id: String,
    poll: Int,
    response_entry: EntryId,
  )
  /// A pending nested summary request.
  SummaryEffect(operation: OpId, task_id: String, attempt: Int, index: Int)
}

/// Messages understood by the driver. `Nudge` is the public doorbell;
/// the rest are internal wiring exposed only through the api module's
/// functions.
pub opaque type Message {
  /// Reports the ledger-authored prior-generation drain acknowledgement.
  PredecessorsResolved(Result(Nil, String))
  /// Re-plan now. Loss is harmless: the poll tick finds queued work.
  Nudge
  /// The periodic checkpoint poll; also grants one deferred poll permit.
  PollTick
  /// A retry wait elapsed.
  RetryDue
  /// Commit the durable abort marker for the open operation, then cancel
  /// live effects and reconcile.
  RequestAbort
  /// A provider-shaped effect delivered its terminal event.
  ProviderDone(token: EffectToken, terminal: stream.StreamEvent)
  /// A tool effect settled.
  ToolDone(token: EffectToken, outcome: effects.ToolOutcome)
  /// A monitored effect process exited.
  EffectExit(down: process.Down)
}

type ReaperMessage {
  Adopt(effect: Pid, stop: fn() -> Nil, reply_with: Subject(Bool))
  TrackProvider(
    effect: Pid,
    handle: stream.StreamHandle,
    reply_with: Subject(Bool),
  )
}

type ReaperEvent {
  ReaperCommand(ReaperMessage)
  LinkedExit(process.ExitMessage)
  OwnedStreamDown(process.Down)
}

type Reaper {
  Reaper(commands: Subject(ReaperMessage), pid: Pid)
}

type AdoptedEffect {
  AdoptedEffect(
    pid: Pid,
    stop: fn() -> Nil,
    provider: ProviderOwnership,
    exited: Bool,
  )
}

// Provider ownership has a publication phase because the reaper must
// distinguish "not a provider" from "a provider with no asynchronous work".
// A watched owner is retained even after the effect exits; only its monitor's
// Down proves the transitive stream subtree has drained.
type ProviderOwnership {
  ProviderUnpublished
  ProviderDrained
  ProviderWatching(handle: stream.StreamHandle, monitor: process.Monitor)
}

type ProviderWaitEvent {
  ProviderStream(stream.StreamEvent)
  StopProvider
  ProviderCancelExpired
}

// Timeout and cooperative stop have different ownership consequences. A
// proper type keeps that distinction visible instead of assigning protocol
// meaning to `True` and `False` at every cancellation branch.
type ProviderWaitFailure {
  ProviderStopped
  ProviderWaitExpired
}

// Registration makes the named mailbox reachable before the drain claim can
// finish. This phase prevents early or stale traffic from driving effects
// until the prior generation's original monitors have opened the barrier.
type RecoveryGate {
  AwaitingPredecessors(abort_requested: Bool)
  RecoveryReady
}

type Live {
  Live(
    token: EffectToken,
    pid: Pid,
    stop: fn() -> Nil,
    monitor: process.Monitor,
    /// The captured identity of the dispatching intent, for synthetic
    /// failure settlements.
    configuration: StrandConfiguration,
    /// The source tool call, for synthetic tool failure results.
    call: Option(ToolCall),
  )
}

type State {
  State(
    // This direct subject is bound to this incarnation's PID. Effects and
    // timers report here so their messages disappear with the process that
    // dispatched them instead of crossing a restart boundary.
    internal: Subject(Message),
    writer: Subject(writer.Message),
    strand: String,
    effects: Effects,
    clock: Clock,
    stream_options: JsonValue,
    retry_policy: NormalizedRetryPolicy,
    poll_interval_ms: Int,
    recovery_gate: RecoveryGate,
    /// This driver's logger, already scoped to the strand. Every log
    /// call narrows *from* this value rather than reading ambient
    /// state, which is what carries `{session, strand, op, step}` into
    /// the effect processes spawned below (see `telemetry/context`).
    logger: Logger,
    /// This incarnation's reaper process: every effect process links to
    /// it at birth, and it kills itself (taking the linked effects with
    /// it) the moment this driver process dies. See `start_reaper`.
    reaper: Reaper,
    live: List(Live),
    observations: List(Observation),
    poll_permit: Bool,
    retry_wake: Option(Int),
    /// The grants the most recent tool clearance consumed, held only
    /// between that clearance and the dispatch it authorizes. It is a
    /// one-slot carry rather than durable state because that is exactly
    /// its lifetime: `clear_tool_call` consumes the approvals attributed
    /// to one call, the very next planning pass turns that clearance into
    /// a `ToolRequest` intent, and `start_effect` spends the slot. It is
    /// keyed by the call's coordinates so a slot left behind by a
    /// clearance whose dispatch never happened (a stale commit that
    /// re-plans, a fault) can never widen a *different* call.
    cleared: Option(Cleared),
  )
}

// The carry between one clearance and the dispatch it authorizes: whose
// call it belongs to, and what its consumption won.
type Cleared {
  Cleared(step_id: String, source_index: Int, grants: List(JsonValue))
}

// Everything one planning pass reads: the restored projection of spec
// §3.1, re-read through the writer on every pass so live operation and
// crash recovery are literally the same code.
type Loaded {
  Loaded(
    op: Operation,
    op_state: OperationState,
    op_state_seq: Seq,
    strand_state: StrandState,
    strand_state_seq: Seq,
    leaf: Option(EntryId),
    configuration: StrandConfiguration,
    configuration_seq: Seq,
    batch_source: Option(AgentMessage),
    deferred_source: Option(DeferredHandle),
    preparation: Option(StructuralPreparation),
    pending: Dict(String, PendingEntry),
    tool_args_keys: List(String),
    preparation_keys: List(String),
  )
}

type LoadOutcome {
  Idle
  Open(Loaded)
}

// The result of a drive attempt, mapped onto `actor.Next` by the
// handlers.
type Outcome {
  Continue(State)
  Halt(String)
}

/// Starts a strand driver registered under `name`. The initialized actor first
/// waits on the prior-generation drain barrier, then drives immediately, so an
/// open operation restored from storage resumes without external input — crash
/// recovery and cold start are the same path.
///
/// ## Examples
///
/// ```gleam
/// // strand_runtime.start(options, name)
/// ```
///
pub fn start(
  options: Options,
  name: Name(Message),
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(5000, fn(subject) {
    // The public subject may be a registered name which does not exist until
    // this initializer returns. It deliberately stays out of State: callers
    // use that durable address, while callbacks must be unable to capture it
    // and cross an incarnation boundary. The direct endpoint also lets a fast
    // first claim acknowledge recovery before actor registration completes.
    let internal = process.new_subject()
    let reaper = start_reaper(options, internal)
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select(internal)
      |> process.select_monitors(EffectExit)
    let logger = log.for_strand(options.logger, options.strand)
    // Every line this incarnation writes is correlated from here on;
    // the driver process itself also stamps the context so an OTP crash
    // report about *this* process is not orphaned.
    log.adopt(logger)
    // The reaper performs the potentially long predecessor claim after it has
    // handed its command subject back to this initializer. The actor can
    // therefore enter its receive loop without weakening the claim handshake.
    actor.initialised(State(
      internal:,
      writer: process.named_subject(options.writer),
      strand: options.strand,
      effects: options.effects,
      clock: options.effects.clock,
      stream_options: options.stream_options,
      retry_policy: options.retry_policy,
      poll_interval_ms: options.poll_interval_ms,
      recovery_gate: AwaitingPredecessors(abort_requested: False),
      logger:,
      reaper:,
      live: [],
      observations: [],
      poll_permit: False,
      retry_wake: None,
      cleared: None,
    ))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// The driver as a supervision child.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(builder, strand_runtime.supervised(options, name))
/// ```
///
pub fn supervised(
  options: Options,
  name: Name(Message),
) -> ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(options, name) })
}

/// Rings the strand's doorbell: re-plan at the next opportunity.
///
/// ## Examples
///
/// ```gleam
/// // strand_runtime.nudge(subject)
/// ```
///
pub fn nudge(strand: Subject(Message)) -> Nil {
  process.send(strand, Nudge)
}

/// Asks the strand to durably request cancellation of its open operation
/// and cancel its live effects. Fire-and-forget; the abort marker is
/// committed by the strand process so it serializes with the strand's own
/// transitions. Idempotent — repeats reuse the durable marker.
///
/// ## Examples
///
/// ```gleam
/// // strand_runtime.request_abort(subject)
/// ```
///
pub fn request_abort(strand: Subject(Message)) -> Nil {
  process.send(strand, RequestAbort)
}

// --- message handling -----------------------------------------------------

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let logger = state.logger
  case state.recovery_gate, message {
    AwaitingPredecessors(abort_requested:), PredecessorsResolved(resolved) -> {
      case resolved {
        Ok(Nil) -> {
          // Recovery and its poll clock both begin after the ledger-authored
          // acknowledgement. Before this point, queued doorbells are harmless
          // because no durable work has crossed the effect boundary.
          state.effects.timers.after(state.poll_interval_ms, fn() {
            wake(state.internal, PollTick)
          })
          log.info(logger, "strand.started", [])
          let state = State(..state, recovery_gate: RecoveryReady)
          case abort_requested {
            True -> finish(logger, abort(state))
            False -> finish(logger, drive(state))
          }
        }
        Error(reason) -> finish(logger, Halt(reason))
      }
    }
    AwaitingPredecessors(_), RequestAbort ->
      // Abort is the one pre-barrier message carrying unique intent. Retain it
      // in state; doorbells and stale effect events need no queue because the
      // first post-barrier drive reloads durable truth.
      actor.continue(
        State(
          ..state,
          recovery_gate: AwaitingPredecessors(abort_requested: True),
        ),
      )
    AwaitingPredecessors(_), _ -> actor.continue(state)
    RecoveryReady, PredecessorsResolved(_) -> actor.continue(state)
    RecoveryReady, Nudge -> finish(logger, drive(state))
    RecoveryReady, PollTick -> {
      let internal = state.internal
      state.effects.timers.after(state.poll_interval_ms, fn() {
        wake(internal, PollTick)
      })
      let out = drive(State(..state, poll_permit: True))
      case out {
        Continue(next) ->
          finish(logger, Continue(State(..next, poll_permit: False)))
        Halt(reason) -> finish(logger, Halt(reason))
      }
    }
    RecoveryReady, RetryDue ->
      finish(logger, drive(State(..state, retry_wake: None)))
    RecoveryReady, RequestAbort -> finish(logger, abort(state))
    RecoveryReady, ProviderDone(token:, terminal:) ->
      finish(logger, provider_done(state, token, terminal))
    RecoveryReady, ToolDone(token:, outcome:) ->
      finish(logger, tool_done(state, token, outcome))
    RecoveryReady, EffectExit(down:) -> finish(logger, effect_exit(state, down))
  }
}

// A halt is the one thing the strand cannot recover from on its own —
// the supervisor restarts it and it re-reads durable state — so it is
// the level policy's `error`, and the last chance to say why before the
// process is gone.
fn finish(logger: Logger, outcome: Outcome) -> actor.Next(State, Message) {
  case outcome {
    Continue(state) -> actor.continue(state)
    Halt(reason) -> {
      log.error(logger, "strand.halted", [
        field.text(key: "reason", value: reason),
      ])
      actor.stop_abnormal(reason)
    }
  }
}

// The logger for one step of one operation: the scope every effect is
// dispatched and settled under, and the scope the effect process itself
// carries once it is spawned.
fn step_logger(state: State, token: EffectToken) -> Logger {
  let #(operation, step_id) = case token {
    AssistantEffect(operation:, step_id:, ..) -> #(operation, step_id)
    ToolEffect(operation:, step_id:, ..) -> #(operation, step_id)
    PollEffect(operation:, step_id:, ..) -> #(operation, step_id)
    SummaryEffect(operation:, task_id:, ..) -> #(operation, task_id)
  }
  log.for_step(state.logger, op: ids.op_id_to_string(operation), step: step_id)
}

// What kind of effect a token names, for the `kind` field. A closed set,
// so a log consumer can index on it.
fn effect_kind(token: EffectToken) -> String {
  case token {
    AssistantEffect(..) -> "provider"
    ToolEffect(..) -> "tool"
    PollEffect(..) -> "poll"
    SummaryEffect(..) -> "summary"
  }
}

// The driver's two escape hatches out of a handler, mirroring
// `machine/planner`'s `or_fault`: a superseded effect (already taken by
// an earlier drive, or a `Down` racing its own cleanup) is a silent
// no-op — `or_continue` — while a durable-state read or a decode failure
// stops the strand — `or_halt`. Both exist because neither `Outcome`
// alternative is a bare `Result`, so `result.try` cannot serve.
fn or_continue(
  option: Option(a),
  otherwise state: State,
  then callback: fn(a) -> Outcome,
) -> Outcome {
  case option {
    None -> Continue(state)
    Some(value) -> callback(value)
  }
}

fn or_halt(result: Result(a, String), then: fn(a) -> Outcome) -> Outcome {
  case result {
    Error(reason) -> Halt(reason)
    Ok(value) -> then(value)
  }
}

fn provider_done(
  state: State,
  token: EffectToken,
  terminal: stream.StreamEvent,
) -> Outcome {
  // Not live any more: a superseded effect. Drop it.
  use #(live, state) <- or_continue(take_live(state, token), otherwise: state)
  log.debug(step_logger(state, token), "effect.settled", [
    field.text(key: "kind", value: effect_kind(token)),
    field.text(key: "outcome", value: terminal_name(terminal)),
  ])
  // A live entry whose operation is no longer the strand's current one
  // belongs to an operation that reached its terminal transaction
  // without needing this outcome (a cancelled structural or
  // deferred-suspend finish). Feeding it forward would hand the *next*
  // operation a mismatched observation.
  use owns <- or_halt(current_operation_owns(state, token))
  use <- bool.guard(when: !owns, return: Continue(state))
  let #(now, state) = read_clock(state)
  use observation <- or_halt(provider_terminal_observation(
    token,
    live,
    terminal,
    now,
  ))
  drive(push_observation(state, observation))
}

// The observation a provider terminal event settles into, per effect
// kind — a settled response for the two that carry the machine's
// settled-assistant shape, the summary task's own reply for the third,
// and a fault for the shapes that cannot occur (a tool token, or a delta
// arriving as a terminal event).
fn provider_terminal_observation(
  token: EffectToken,
  live: Live,
  terminal: stream.StreamEvent,
  now: Int,
) -> Result(Observation, String) {
  case token {
    AssistantEffect(..) ->
      settled_observation(live, terminal, now, fn(settled) {
        planner.ObservedAssistantSettled(settled:, overflow_preparation: None)
      })
    PollEffect(..) ->
      settled_observation(live, terminal, now, fn(settled) {
        planner.ObservedDeferredSettled(settled:)
      })
    SummaryEffect(..) ->
      case terminal {
        stream.Settled(message: _, usage:) ->
          Ok(planner.ObservedSummaryReturned(usage:))
        stream.Failed(error: _) ->
          Ok(planner.ObservedSummaryReturned(usage: effects.zero_usage()))
        stream.Delta(..) ->
          Error("provider stream delivered a delta as its terminal event")
      }
    ToolEffect(..) -> Error("a tool effect delivered a provider terminal event")
  }
}

// The terminal event's name, for the `outcome` field. A closed set.
fn terminal_name(terminal: stream.StreamEvent) -> String {
  case terminal {
    stream.Settled(..) -> "settled"
    stream.Failed(..) -> "failed"
    stream.Delta(..) -> "delta"
  }
}

// Whether the strand's durable current operation is the one the token's
// effect was dispatched for.
fn current_operation_owns(
  state: State,
  token: EffectToken,
) -> Result(Bool, String) {
  let operation = case token {
    AssistantEffect(operation:, ..)
    | ToolEffect(operation:, ..)
    | PollEffect(operation:, ..)
    | SummaryEffect(operation:, ..) -> operation
  }
  use decoded <- result.try(read_decoded(
    state,
    register.StrandState,
    state.strand,
    codec.decode_strand_state,
  ))
  case decoded {
    None -> Ok(False)
    Some(#(_seq, strand_state)) ->
      Ok(strand_state.current_operation == Some(operation))
  }
}

// Bridges a provider terminal event into the machine's settled shape:
// settled responses pass through; failures become zero-usage error
// responses carrying the retryability convention (see runtime/effects).
fn settled_observation(
  live: Live,
  terminal: stream.StreamEvent,
  now: Int,
  wrap: fn(classification.SettledAssistantMessage) -> Observation,
) -> Result(Observation, String) {
  use message <- result.try(case terminal {
    stream.Settled(message: settled, usage: _) -> Ok(stream.message(settled))
    stream.Failed(error:) ->
      Ok(effects.settle_failure(error, live.configuration, now))
    stream.Delta(..) ->
      Error("provider stream delivered a delta as its terminal event")
  })
  classification.settle(message)
  |> result.map(wrap)
  |> result.map_error(corruption.describe)
}

fn tool_done(
  state: State,
  token: EffectToken,
  outcome: effects.ToolOutcome,
) -> Outcome {
  case take_live(state, token), token {
    None, _ -> Continue(state)
    Some(#(live, state)), ToolEffect(source_index:, ..) -> {
      log.debug(step_logger(state, token), "effect.settled", [
        field.text(key: "kind", value: effect_kind(token)),
        field.text(key: "outcome", value: tool_outcome_name(outcome)),
      ])
      let #(now, state) = read_clock(state)
      use observation <- or_halt(tool_observation(
        live,
        outcome,
        source_index,
        now,
      ))
      drive(push_observation(state, observation))
    }
    Some(_), _ -> Halt("tool outcome arrived under a non-tool effect token")
  }
}

fn tool_observation(
  live: Live,
  outcome: effects.ToolOutcome,
  source_index: Int,
  now: Int,
) -> Result(Observation, String) {
  case outcome {
    effects.ToolCompleted(result:, terminate:) ->
      Ok(planner.ObservedToolSettled(source_index:, result:, terminate:))
    effects.ToolFailed(reason:) ->
      case live.call {
        Some(call) ->
          Ok(planner.ObservedToolSettled(
            source_index:,
            result: synthetic_tool_error(call, reason, now),
            terminate: False,
          ))
        None -> Error("tool effect settled without a recorded source call")
      }
  }
}

// The tool outcome's name, for the `outcome` field. A tool that failed
// and said so is the system working, so this never raises the level:
// an in-band failure is `debug` like any other settlement.
fn tool_outcome_name(outcome: effects.ToolOutcome) -> String {
  case outcome {
    effects.ToolCompleted(result: _, terminate: _) -> "completed"
    effects.ToolFailed(reason: _) -> "failed"
  }
}

fn effect_exit(state: State, down: process.Down) -> Outcome {
  case down {
    process.PortDown(..) -> Continue(state)
    process.ProcessDown(pid:, ..) -> {
      // Unknown pid: the effect already reported (or was cancelled) and
      // this Down raced the cleanup. Ignore.
      use live <- or_continue(
        list.find(state.live, fn(live) { live.pid == pid })
          |> option.from_result,
        otherwise: state,
      )
      // The effect process died without reporting. Tools have no descendant
      // ownership after the worker dies, so an in-band synthetic result is
      // safe. A provider may still have a transport subtree: halt the driver
      // and let the old reaper's published owner become the restart barrier.
      log.warn(step_logger(state, live.token), "effect.exited", [
        field.text(key: "kind", value: effect_kind(live.token)),
      ])
      case live.token {
        AssistantEffect(..) | PollEffect(..) | SummaryEffect(..) ->
          Halt("a provider effect exited before its stream owner drained")
        ToolEffect(..) ->
          tool_done(
            state,
            live.token,
            effects.ToolFailed(
              reason: "the tool effect process exited before settling",
            ),
          )
      }
    }
  }
}

fn abort(state: State) -> Outcome {
  case abort_commit(state, 8) {
    AbortFailed(reason) -> Halt(reason)
    // ORCH-L5: exhausting the stale-retry ladder must not drop the abort
    // (the request is fire-and-forget, so nobody would learn it was
    // lost) and must not halt the strand (a restart disrupts the running
    // operation and spends supervisor tolerance for a transient race).
    // The marker is not durable yet, so re-deliver the request to
    // ourselves after a pacing delay and keep running: request_abort is
    // idempotent, every retry re-reads the durable state, and the loop
    // converges as soon as the concurrent committers quiet down.
    AbortRaceLost -> {
      let internal = state.internal
      state.effects.timers.after(state.poll_interval_ms, fn() {
        wake(internal, RequestAbort)
      })
      Continue(state)
    }
    AbortDurable(state) -> {
      // Interrupt live effects after the durable marker (pi §4.6 order),
      // but keep them registered: an effect that already delivered a
      // real settlement — still queued in this mailbox — settles under
      // its reserved ids as aborted *retaining its reported usage*
      // (ORCH-M3), while one that dies unreported settles through the
      // monitor as a synthetic zero-usage abort.
      log.info(state.logger, "operation.aborted", [])
      let state = interrupt_live_effects(state)
      drive(state)
    }
  }
}

// What one abort request attempt concluded.
type AbortAttempt {
  /// The marker is durable (or there was nothing to abort).
  AbortDurable(State)
  /// The marker commit kept losing its seq race; nothing is durable yet.
  AbortRaceLost
  /// A read or commit failed hard.
  AbortFailed(String)
}

// Commits the cancel_requested marker with a bounded stale-retry loop.
fn abort_commit(state: State, attempts: Int) -> AbortAttempt {
  use <- bool.guard(when: attempts <= 0, return: AbortRaceLost)
  case load(state) {
    Error(reason) -> AbortFailed(reason)
    Ok(Idle) -> AbortDurable(state)
    Ok(Open(loaded)) -> abort_commit_open(state, loaded, attempts)
  }
}

fn abort_commit_open(
  state: State,
  loaded: Loaded,
  attempts: Int,
) -> AbortAttempt {
  let #(now, state) = read_clock(state)
  case
    queue.request_abort(loaded.op, loaded.op_state, loaded.op_state_seq, now)
  {
    queue.AbortAlreadyRequested(..) -> AbortDurable(state)
    queue.AbortPlanned(tx: plan_tx, ..) ->
      commit_abort_marker(state, plan_tx, attempts)
  }
}

fn commit_abort_marker(
  state: State,
  plan_tx: tx.Tx,
  attempts: Int,
) -> AbortAttempt {
  case writer.commit(state.writer, plan_tx) {
    Ok(_) -> AbortDurable(state)
    Error(tx.StaleExpectation(..)) -> abort_commit(state, attempts - 1)
    Error(tx.Corruption(report:)) -> AbortFailed(corruption.describe(report))
    Error(tx.Faulted(reason:)) -> AbortFailed(reason)
    // Fenced out: another writer owns the session, so the cancellation
    // marker cannot be made durable here and retrying would meet the
    // same fence.
    Error(tx.LeaseLost(held_by:)) ->
      AbortFailed(tx.describe_lease_loss(held_by))
  }
}

// Kills every live effect process without unregistering it. The kill and
// any settlement the effect already sent are signals from the same pid,
// so their order is preserved: a settlement delivered before death is
// consumed as the real observation (with its real usage), and the
// monitor's Down then finds the entry gone; an unreported death reaches
// `effect_exit` and settles synthetically. Either way reconciliation
// sees exactly one outcome per reserved id.
fn interrupt_live_effects(state: State) -> State {
  list.each(state.live, fn(live) { live.stop() })
  state
}

// --- the drive loop -------------------------------------------------------

const fuel = 10_000

fn drive(state: State) -> Outcome {
  drive_loop(state, fuel)
}

fn drive_loop(state: State, fuel: Int) -> Outcome {
  use <- bool.guard(when: fuel <= 0, return: out_of_fuel)
  case load(state) {
    Error(reason) -> Halt(reason)
    Ok(Idle) -> Continue(state)
    Ok(Open(loaded)) -> {
      let #(observation, state) = pop_observation(state)
      plan(state, loaded, observation, fuel)
    }
  }
}

const out_of_fuel = Halt(
  "the driver made no durable progress within its fuel bound",
)

fn plan(
  state: State,
  loaded: Loaded,
  observation: Observation,
  fuel: Int,
) -> Outcome {
  use <- bool.guard(when: fuel <= 0, return: out_of_fuel)
  let #(now, state) = read_clock(state)
  let inputs = build_inputs(state, loaded, observation, now)
  case planner.next_action(loaded.op, loaded.op_state, inputs) {
    planner.Fault(report:) ->
      Halt("planner fault: " <> corruption.describe(report))
    planner.Wait(until: planner.RetryNotBefore(at:)) ->
      park_retry(state, at, now)
    planner.Wait(until: planner.DeferredPollDue(source_entry: _)) ->
      // The next PollTick grants a permit and re-plans.
      Continue(state)
    planner.AwaitEffect(key:) ->
      await_effect_action(state, loaded, key, observation, now, fuel)
    planner.Transition(next: _, tx: plan_tx) ->
      commit_then(state, plan_tx, observation, fuel, fn(state) {
        drive_loop(state, fuel - 1)
      })
    // The one durable state change worth an `info` line per operation:
    // the operation reached a terminal result.
    planner.Finish(result: _, tx: plan_tx) ->
      commit_then(state, plan_tx, observation, fuel, fn(state) {
        log.info(
          log.scoped(
            state.logger,
            context.anonymous
              |> context.with_op(ids.op_id_to_string(loaded.op.id)),
          ),
          "operation.settled",
          [],
        )
        drive_loop(state, fuel - 1)
      })
    planner.Dispatch(intent:, next: _, tx: plan_tx) ->
      commit_then(state, plan_tx, observation, fuel, fn(state) {
        case start_effect(state, loaded, intent) {
          Ok(state) -> drive_loop(state, fuel - 1)
          Error(reason) -> Halt(reason)
        }
      })
  }
}

// `AwaitEffect`'s resolution: a fault halts, a live wait re-queues an
// unconsumed real observation, and a resolved key re-enters `plan` with
// the refined observation (a cleared escalation also carries its grants
// forward onto `state.cleared` for the dispatch it authorizes).
fn await_effect_action(
  state: State,
  loaded: Loaded,
  key: planner.EffectKey,
  observation: Observation,
  now: Int,
  fuel: Int,
) -> Outcome {
  case resolve_key(state, loaded, key, observation, now) {
    KeyHalt(reason) -> Halt(reason)
    KeyWait ->
      // Parked on a live effect. An unconsumed real observation goes
      // back to the front of the queue.
      case observation {
        NoObservation -> Continue(state)
        other -> Continue(push_observation_front(state, other))
      }
    KeyObservation(refined) -> plan(state, loaded, refined, fuel - 1)
    KeyCleared(observation: refined, cleared:) ->
      plan(State(..state, cleared: Some(cleared)), loaded, refined, fuel - 1)
  }
}

fn commit_then(
  state: State,
  plan_tx: tx.Tx,
  observation: Observation,
  fuel: Int,
  continue: fn(State) -> Outcome,
) -> Outcome {
  case writer.commit(state.writer, plan_tx) {
    Ok(_) -> continue(state)
    // A concurrent admission won the seq race: reload and re-plan with
    // the observation preserved.
    Error(tx.StaleExpectation(..)) -> {
      let state = case observation {
        NoObservation -> state
        other -> push_observation_front(state, other)
      }
      drive_loop(state, fuel - 1)
    }
    Error(tx.Corruption(report:)) ->
      Halt("commit corruption: " <> corruption.describe(report))
    Error(tx.Faulted(reason:)) -> Halt("storage faulted: " <> reason)
    // Not a fault to reload past: this process is no longer the
    // session's writer, so the strand stops and the tree's reopen path
    // is the only thing that can resolve it.
    Error(tx.LeaseLost(held_by:)) -> Halt(tx.describe_lease_loss(held_by))
  }
}

// A message for a strand that may have died since it was arranged: a
// timer whose deadline outlived its strand, or an effect reporting an
// outcome to the incarnation that dispatched it. Losing either is
// harmless — the durable state decides everything, and a restarted
// strand re-plans from it — but raising at an unregistered name inside
// someone else's process is not: it turns an ordinary reboot into a
// crash report from a process the supervisor knows nothing about.
fn wake(subject: Subject(Message), message: Message) -> Nil {
  case process.subject_owner(subject) {
    Ok(pid) ->
      case process.is_alive(pid) {
        True -> process.send(subject, message)
        False -> Nil
      }
    Error(Nil) -> Nil
  }
}

fn park_retry(state: State, at: Int, now: Int) -> Outcome {
  case state.retry_wake {
    Some(wake) if wake == at -> Continue(state)
    _ -> {
      let delay = int_max(1, at - now)
      let internal = state.internal
      log.warn(state.logger, "retry.armed", [
        field.count(key: "delay_ms", value: delay),
      ])
      state.effects.timers.after(delay, fn() { wake(internal, RetryDue) })
      Continue(State(..state, retry_wake: Some(at)))
    }
  }
}

// --- effect-key resolution -----------------------------------------------

type KeyResolution {
  KeyObservation(Observation)
  /// A tool clearance passed, carrying whatever grants its consumption
  /// won. Distinct from `KeyObservation` because the grants must reach
  /// the dispatch that follows: the observation alone would strand them
  /// at the query, which is exactly the severed channel this variant
  /// exists to close.
  KeyCleared(observation: Observation, cleared: Cleared)
  KeyWait
  KeyHalt(String)
}

fn resolve_key(
  state: State,
  loaded: Loaded,
  key: planner.EffectKey,
  observation: Observation,
  now: Int,
) -> KeyResolution {
  let hooks = state.effects.hooks
  case key {
    planner.RunStartKey(operation:) ->
      KeyObservation(
        planner.ObservedRunStart(messages: hooks.run_start(operation)),
      )
    planner.AdmissionKey(operation:, step_id:, attempt:) ->
      KeyObservation(
        planner.ObservedAdmission(
          admission: hooks.admission(effects.AdmissionQuery(
            operation:,
            step_id:,
            attempt:,
            configuration: admission_configuration(loaded),
            stream_options: state.stream_options,
          )),
        ),
      )
    planner.RunEndKey(operation:) ->
      KeyObservation(
        planner.ObservedRunEnd(follow_up: hooks.run_end(operation)),
      )
    planner.AssistantKey(operation:, step_id:, response_entry:) -> {
      use <- bool.guard(
        when: has_live(
          state,
          AssistantEffect(operation:, step_id:, response_entry:),
        ),
        return: KeyWait,
      )
      // A restored effect_pending with no live continuation: the
      // request's outcome is unknown (spec §3.1). Loom persists no frame
      // lists (spec-gaps WP-D item 2), so the reconstructed partial is
      // always empty.
      KeyObservation(planner.ObservedAssistantOrphaned(partial: []))
    }
    planner.OverflowPreparationKey(operation:, response_entry: _) ->
      overflow_preparation_key(state, hooks, operation, observation)
    planner.ToolClearanceKey(operation:, step_id:, source_index:) ->
      tool_clearance_key(state, loaded, operation, step_id, source_index, now)
    planner.ToolKey(operation:, step_id:, source_index:, result_entry: _) ->
      tool_key(state, loaded, operation, step_id, source_index)
    planner.PollAdmissionKey(operation: _, step_id: _, poll: _) ->
      KeyObservation(
        planner.ObservedResolution(resolution: hooks.resolution(
          loaded.configuration,
        )),
      )
    planner.PollKey(operation:, step_id:, poll:, response_entry:) -> {
      use <- bool.guard(
        when: has_live(
          state,
          PollEffect(operation:, step_id:, poll:, response_entry:),
        ),
        return: KeyWait,
      )
      KeyObservation(planner.ObservedDeferredOrphaned)
    }
    planner.DecisionKey(operation:, task_id:) ->
      KeyObservation(
        planner.ObservedStructuralDecision(verdict: hooks.structural_decision(
          operation,
          task_id,
        )),
      )
    planner.SummaryKey(operation:, task_id:, attempt:) ->
      summary_key(state, loaded, hooks, operation, task_id, attempt)
    planner.SummaryProgressKey(operation:, task_id:, attempt:) ->
      KeyObservation(
        planner.ObservedSummaryProgress(progress: hooks.summary_progress(
          operation,
          task_id,
          attempt,
        )),
      )
  }
}

// The observation-or-fault shape shared by the key resolvers below: a
// step that reads a source call can fail only because the durable state
// it reads is missing what the operation's own transitions guarantee —
// which is a fault, not a wait.
fn or_key_halt(
  result: Result(a, String),
  then: fn(a) -> KeyResolution,
) -> KeyResolution {
  case result {
    Error(reason) -> KeyHalt(reason)
    Ok(value) -> then(value)
  }
}

fn overflow_preparation_key(
  state: State,
  hooks: effects.Hooks,
  operation: OpId,
  observation: Observation,
) -> KeyResolution {
  case observation {
    planner.ObservedAssistantSettled(settled:, overflow_preparation: _) ->
      KeyObservation(planner.ObservedAssistantSettled(
        settled:,
        overflow_preparation: Some(
          hooks.overflow_preparation(effects.OverflowQuery(
            operation:,
            strand: state.strand,
          )),
        ),
      ))
    _ ->
      KeyHalt(
        "an overflow preparation was requested without a settled response in hand",
      )
  }
}

fn tool_clearance_key(
  state: State,
  loaded: Loaded,
  operation: OpId,
  step_id: String,
  source_index: Int,
  now: Int,
) -> KeyResolution {
  use call <- or_key_halt(source_call(loaded, source_index))
  // Per-tool scheduling (pi §3.8 at per-tool granularity): under
  // parallel settings the planner asks to clear the next planned call
  // while earlier effects run; an `Exclusive` tool must not start beside
  // anything, and nothing starts beside a live `Exclusive` tool. Parking
  // is safe: only a live tool effect causes it, and that effect's
  // settlement re-plans.
  use <- bool.guard(when: !tool_may_start(state, call.name), return: KeyWait)
  clear_tool_call(state, loaded, operation, step_id, source_index, call, now)
}

fn tool_key(
  state: State,
  loaded: Loaded,
  operation: OpId,
  step_id: String,
  source_index: Int,
) -> KeyResolution {
  // Any pending call's observation satisfies the key.
  use <- bool.guard(
    when: has_live_tool(state, operation, step_id),
    return: KeyWait,
  )
  use call <- or_key_halt(source_call(loaded, source_index))
  // Loom has no durable tool checkpoints (no list store — spec-gaps
  // WP-D item 2), so the checkpoint is always absent.
  KeyObservation(planner.ObservedToolOrphaned(
    source_index:,
    replay_still_safe: state.effects.tools.replay_still_safe(call.name),
    checkpoint: None,
  ))
}

fn summary_key(
  state: State,
  loaded: Loaded,
  hooks: effects.Hooks,
  operation: OpId,
  task_id: String,
  attempt: Int,
) -> KeyResolution {
  case summary_generation(loaded.op_state) {
    Some(operation.SummaryEffectPending(request: Some(request), ..)) -> {
      let token =
        SummaryEffect(operation:, task_id:, attempt:, index: request.index)
      use <- bool.guard(when: has_live(state, token), return: KeyWait)
      KeyObservation(planner.ObservedSummaryOrphaned)
    }
    _ ->
      KeyObservation(
        planner.ObservedResolution(resolution: hooks.resolution(
          loaded.configuration,
        )),
      )
  }
}

// The configuration an admission describes: the step-start snapshot the
// dispatch will read (`GenerationContext.configuration`), never the
// strand's live register. The two can differ — a `set_config` lands on a
// strand mid-run, between a retry wait and its next attempt — and the
// three durable values admission mints (intended output limit, context
// window, `request_api`) must describe the identity the request actually
// reaches, or overflow classification judges the wrong ceiling. The
// planner only asks `AdmissionKey` from `GenerationReady`, so the
// fallback arm is unreachable today; it answers from the live register,
// which is every admission's source before the snapshot was threaded
// here, rather than inventing a refusal for a state that cannot ask.
// The poll sibling (`PollAdmissionKey`) is left on the live register
// deliberately: `resolution` reads no facts from its argument at all.
fn admission_configuration(loaded: Loaded) -> StrandConfiguration {
  case loaded.op_state {
    RunState(phase: Assistant(generation: GenerationReady(context:, ..)), ..) ->
      context.configuration
    _ -> loaded.configuration
  }
}

fn summary_generation(state: OperationState) -> Option(SummaryGeneration) {
  case state {
    RunState(phase: Compacting(structural: Generating(generation:, ..), ..), ..) ->
      Some(generation)
    CompactionState(structural: Generating(generation:, ..), ..) ->
      Some(generation)
    NavigationState(
      navigation: SummarizedNavigation(
        structural: Generating(generation:, ..),
        ..,
      ),
      ..,
    ) -> Some(generation)
    _ -> None
  }
}

// --- effect dispatch ------------------------------------------------------

fn start_effect(
  state: State,
  loaded: Loaded,
  intent: planner.EffectIntent,
) -> Result(State, String) {
  case intent {
    planner.ProviderRequest(
      operation:,
      step_id:,
      attempt:,
      context: generation_context,
      stream_options:,
      response_entry:,
      ..,
    ) -> {
      use projected <- with_projection(state, loaded.leaf)
      let spec =
        effects.GenerationRequest(
          operation:,
          step_id:,
          attempt:,
          configuration: generation_context.configuration,
          context: projected,
          stream_options:,
        )
      Ok(spawn_provider(
        state,
        AssistantEffect(operation:, step_id:, response_entry:),
        generation_context.configuration,
        spec,
      ))
    }
    planner.ToolRequest(
      operation:,
      step_id:,
      source_index:,
      call:,
      effective_arguments:,
      replay:,
      result_entry:,
    ) -> {
      // The grants this call's own clearance consumed, and nothing else:
      // a carry left by any other call is dropped rather than spent
      // here, which keeps an approval worth exactly the one execution of
      // exactly the one call a human approved.
      let #(grants, state) = take_cleared(state, step_id, source_index)
      Ok(spawn_tool(
        state,
        ToolEffect(operation:, step_id:, source_index:, result_entry:),
        loaded.configuration,
        effects.ToolRun(
          operation:,
          step_id:,
          source_index:,
          strand: state.strand,
          call:,
          arguments: effective_arguments,
          replay:,
          grants:,
        ),
      ))
    }
    planner.ToolReplay(
      operation:,
      step_id:,
      source_index:,
      call:,
      arguments_key:,
      result_entry:,
    ) -> {
      use arguments <- result.try(read_tool_arguments(state, arguments_key))
      Ok(spawn_tool(
        state,
        ToolEffect(operation:, step_id:, source_index:, result_entry:),
        loaded.configuration,
        effects.ToolRun(
          operation:,
          step_id:,
          source_index:,
          strand: state.strand,
          call:,
          arguments:,
          replay: operation.ReplaySafe,
          // A replay is a re-execution of a call whose clearance
          // belonged to a dead incarnation. Whatever approval that
          // clearance consumed is already marked spent, so replaying
          // under it would be the one direction that turns a single
          // approval into two widened executions.
          grants: [],
        ),
      ))
    }
    planner.DeferredFetch(
      operation:,
      step_id:,
      poll:,
      response_entry:,
      configuration:,
      stream_options:,
      ..,
    ) -> {
      use handle <- result.try(option.to_result(
        loaded.deferred_source,
        "a deferred fetch was dispatched without a source handle",
      ))
      Ok(spawn_provider(
        state,
        PollEffect(operation:, step_id:, poll:, response_entry:),
        configuration,
        effects.PollRequest(
          operation:,
          step_id:,
          poll:,
          handle:,
          configuration:,
          stream_options:,
        ),
      ))
    }
    planner.SummaryProviderRequest(
      operation:,
      task_id:,
      attempt:,
      request_index:,
      context: summary_context,
      ..,
    ) ->
      Ok(spawn_provider(
        state,
        SummaryEffect(operation:, task_id:, attempt:, index: request_index),
        summary_context.configuration,
        effects.SummaryRequest(
          operation:,
          task_id:,
          attempt:,
          request_index:,
          preparation: loaded.preparation,
          configuration: summary_context.configuration,
          stream_options: summary_context.stream_options,
        ),
      ))
  }
}

// Takes the clearance carry, if it belongs to this call. Any other
// carry is discarded with it: a clearance whose dispatch never happened
// has already had its approval marked consumed, and holding the grants
// for a later call would spend them somewhere nobody approved.
fn take_cleared(
  state: State,
  step_id: String,
  source_index: Int,
) -> #(List(JsonValue), State) {
  let grants = case state.cleared {
    Some(Cleared(step_id: held_step, source_index: held_index, grants:))
      if held_step == step_id && held_index == source_index
    -> grants
    _ -> []
  }
  #(grants, State(..state, cleared: None))
}

fn with_projection(
  state: State,
  leaf: Option(EntryId),
  continue: fn(List(AgentMessage)) -> Result(State, String),
) -> Result(State, String) {
  case leaf {
    None -> continue([])
    Some(start) -> {
      let q =
        storage.branch_scan(from: start)
        |> storage.branch_stop_at_kind(storage.Compaction)
      use entries <- result.try(
        writer.scan_branch(state.writer, q)
        |> result.map_error(fn(error) {
          "context projection failed: " <> describe_read_error(error)
        }),
      )
      continue(session.project_scan(entries))
    }
  }
}

// --- the effect reaper -----------------------------------------------------
//
// A strand-actor restart must not leak its live effect processes: the
// exclusivity gate (`tool_may_start`) and the orphan-versus-live decision
// (`resolve_key`) both consult the incarnation-local `live` list, so an
// effect that outlived its incarnation would run *concurrently* with the
// replacement's recovery — a `ReplaySafe` tool re-executed beside its
// still-running first execution, an assistant request retried while the
// original still streams and bills, an `Exclusive` tool started beside
// the previous incarnation's. The fix is a kernel-level ownership chain:
// no effect process may outlive the driver incarnation that dispatched
// it.
//
// Linking effects to the driver directly would force the driver to trap exits,
// entangling supervision shutdown with effect settlement. Each incarnation
// instead owns one linked reaper. An effect must link to it *and* receive an
// adoption acknowledgement before running user-visible work. The reaper can
// therefore enumerate every effect that crossed the execution boundary.
//
// Driver death begins a drain rather than merely broadcasting exit signals.
// The reaper invokes every adopted effect's stop capability and stays alive
// until every linked exit has arrived. Tool effects use a hard stop; provider
// effects cancel cooperatively and do not exit until the public stream owner
// has drained. The long-lived strand registry remembers all still-live reapers
// for a logical strand; a replacement driver claims its own reaper, then waits
// for every older one to disappear before it nudges recovery. This is the
// barrier the old timing argument lacked: recovery cannot dispatch beside a
// predecessor that is merely scheduled to die.

fn start_reaper(options: Options, internal: Subject(Message)) -> Reaper {
  let driver = process.self()
  let ready = process.new_subject()
  let pid =
    process.spawn(fn() {
      process.trap_exits(True)
      let commands = process.new_subject()
      process.send(ready, commands)
      // The reaper itself makes the ledger claim. If the driver dies while the
      // ledger is still draining an older generation, its trapped exit remains
      // queued here and this PID stays alive until the ledger has installed its
      // original monitor. A disposable helper could die with the driver first,
      // leaving the ledger to observe only `noproc` and correctly poison the
      // session because the reaper's exit reason had been lost.
      let resolved =
        options.claim_reaper(options.strand, process.self())
        |> await_previous_reapers(4000)
      process.send(internal, PredecessorsResolved(resolved))
      reap(driver, commands, [])
    })
  let commands = process.receive_forever(ready)
  Reaper(commands:, pid:)
}

fn reap(
  driver: Pid,
  commands: Subject(ReaperMessage),
  effects: List(AdoptedEffect),
) -> Nil {
  let event =
    process.new_selector()
    |> process.select_map(commands, ReaperCommand)
    |> process.select_trapped_exits(LinkedExit)
    |> process.select_monitors(OwnedStreamDown)
    |> process.selector_receive_forever()
  case event {
    ReaperCommand(Adopt(effect:, stop:, reply_with:)) -> {
      let accepted = process.is_alive(driver) && process.is_alive(effect)
      process.send(reply_with, accepted)
      case accepted {
        True ->
          reap(driver, commands, [
            AdoptedEffect(
              pid: effect,
              stop:,
              provider: ProviderUnpublished,
              exited: False,
            ),
            ..effects
          ])
        False -> reap(driver, commands, effects)
      }
    }
    ReaperCommand(TrackProvider(effect:, handle:, reply_with:)) -> {
      let #(effects, accepted) = publish_provider_owner(effects, effect, handle)
      let committed = accepted && process.is_alive(driver)
      process.send(reply_with, committed)
      case committed {
        True -> reap(driver, commands, effects)
        // Publication is irreversible even when driver death rejects the
        // worker's start permit. The worker will cancel locally, while the
        // reaper retains its independent owner monitor in case that worker
        // dies before cleanup finishes.
        False -> reap(driver, commands, effects)
      }
    }
    LinkedExit(process.ExitMessage(pid:, reason: _)) ->
      case pid == driver {
        True -> drain(commands, effects)
        False -> reap(driver, commands, effect_departed(effects, pid))
      }
    OwnedStreamDown(down) ->
      case provider_owner_departed(effects, down) {
        Ok(effects) -> reap(driver, commands, effects)
        Error(Nil) -> process.kill(process.self())
      }
  }
}

fn drain(
  commands: Subject(ReaperMessage),
  effects: List(AdoptedEffect),
) -> Nil {
  list.each(effects, fn(effect) { effect.stop() })
  await_drain(commands, effects)
}

fn await_drain(
  commands: Subject(ReaperMessage),
  effects: List(AdoptedEffect),
) -> Nil {
  case effects {
    [] -> Nil
    [_, ..] -> {
      let event =
        process.new_selector()
        |> process.select_map(commands, ReaperCommand)
        |> process.select_trapped_exits(LinkedExit)
        |> process.select_monitors(OwnedStreamDown)
        |> process.selector_receive_forever()
      case event {
        ReaperCommand(Adopt(effect: _, stop: _, reply_with:)) -> {
          process.send(reply_with, False)
          await_drain(commands, effects)
        }
        ReaperCommand(TrackProvider(effect:, handle:, reply_with:)) -> {
          let #(effects, _published) =
            publish_provider_owner(effects, effect, handle)
          // Publication is irreversible even after draining begins. Rejecting
          // the begin permit stops new work, but retaining the monitor covers
          // the worker-death race in which only the reaper remains able to
          // prove that the already-created owner has disappeared.
          process.send(reply_with, False)
          await_drain(commands, effects)
        }
        LinkedExit(process.ExitMessage(pid:, reason: _)) ->
          await_drain(commands, effect_departed(effects, pid))
        OwnedStreamDown(down) ->
          case provider_owner_departed(effects, down) {
            Ok(effects) -> await_drain(commands, effects)
            Error(Nil) -> process.kill(process.self())
          }
      }
    }
  }
}

fn publish_provider_owner(
  effects: List(AdoptedEffect),
  published_by: Pid,
  handle: stream.StreamHandle,
) -> #(List(AdoptedEffect), Bool) {
  case effects {
    [] -> #([], False)
    [effect, ..rest] if effect.pid == published_by ->
      case effect.provider, effect.exited {
        ProviderUnpublished, False -> {
          let ownership = monitor_provider_owner(handle)
          #([AdoptedEffect(..effect, provider: ownership), ..rest], True)
        }
        _, _ -> #(effects, False)
      }
    [effect, ..rest] -> {
      let #(rest, accepted) = publish_provider_owner(rest, published_by, handle)
      #([effect, ..rest], accepted)
    }
  }
}

fn monitor_provider_owner(handle: stream.StreamHandle) -> ProviderOwnership {
  case handle.owner {
    None -> ProviderDrained
    Some(owner) -> {
      let monitor = process.monitor(owner)
      // Even an already-dead owner remains unadjudicated until this original
      // monitor supplies its reason. An is_alive pre-filter would collapse a
      // lost witness into the same state as a normal drain.
      ProviderWatching(handle:, monitor:)
    }
  }
}

// An effect Down is not necessarily a drain. A published provider owner stays
// in the ledger until its independent monitor fires; everything else can be
// forgotten as soon as the worker itself is gone.
fn effect_departed(
  effects: List(AdoptedEffect),
  departed: Pid,
) -> List(AdoptedEffect) {
  case effects {
    [] -> []
    [effect, ..rest] if effect.pid == departed ->
      case effect.provider {
        ProviderWatching(handle:, ..) -> {
          stream.cancel(handle)
          [AdoptedEffect(..effect, exited: True), ..rest]
        }
        ProviderUnpublished | ProviderDrained -> rest
      }
    [effect, ..rest] -> [effect, ..effect_departed(rest, departed)]
  }
}

fn provider_owner_departed(
  effects: List(AdoptedEffect),
  down: process.Down,
) -> Result(List(AdoptedEffect), Nil) {
  case down {
    process.PortDown(..) -> Ok(effects)
    process.ProcessDown(reason: process.Killed, ..)
    | process.ProcessDown(reason: process.Abnormal(_), ..) -> Error(Nil)
    process.ProcessDown(monitor:, reason: process.Normal, ..) ->
      Ok(
        list.filter_map(effects, fn(effect) {
          case effect.provider {
            ProviderWatching(monitor: watched, ..) if watched == monitor ->
              case effect.exited {
                True -> Error(Nil)
                False -> Ok(AdoptedEffect(..effect, provider: ProviderDrained))
              }
            _ -> Ok(effect)
          }
        }),
      )
  }
}

fn await_previous_reapers(
  previous: List(Pid),
  within_ms: Int,
) -> Result(Nil, String) {
  list.try_each(previous, fn(reaper) {
    let monitor = process.monitor(reaper)
    let down =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive(within_ms)
    process.demonitor_process(monitor)
    case down {
      Ok(process.ProcessDown(reason: process.Normal, ..)) -> Ok(Nil)
      Ok(process.ProcessDown(reason: process.Killed, ..))
      | Ok(process.ProcessDown(reason: process.Abnormal(_), ..))
      | Ok(process.PortDown(..))
      | Error(Nil) -> Error("the previous effect generation did not drain")
    }
  })
}

// A worker links before asking for adoption. If the reaper is already gone,
// or starts draining before it can acknowledge, the worker exits without
// running. Once acknowledged, the reaper has recorded the pid and cannot
// finish its own drain until this worker is dead.
fn spawn_effect(
  reaper: Reaper,
  logger: Logger,
  body: fn() -> Nil,
) -> #(Pid, fn() -> Nil) {
  let pid =
    process.spawn_unlinked(fn() {
      let self = process.self()
      adopt_and_run(reaper, logger, fn() { process.kill(self) }, body)
    })
  #(pid, fn() { process.kill(pid) })
}

// Provider effects receive a cooperative stop because their process is the
// top-level drain witness. Killing it would start cleanup below it while
// allowing the reaper to report completion too early.
fn spawn_provider_effect(
  reaper: Reaper,
  logger: Logger,
  body: fn(Subject(Nil)) -> Nil,
) -> #(Pid, fn() -> Nil) {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let stop = process.new_subject()
      process.send(ready, stop)
      adopt_and_run(reaper, logger, fn() { process.send(stop, Nil) }, fn() {
        body(stop)
      })
    })
  let stop = process.receive_forever(ready)
  #(pid, fn() { process.send(stop, Nil) })
}

fn adopt_and_run(
  reaper: Reaper,
  logger: Logger,
  stop: fn() -> Nil,
  body: fn() -> Nil,
) -> Nil {
  let Reaper(commands:, pid: reaper_pid) = reaper
  let reaper_monitor = process.monitor(reaper_pid)
  case process.link(reaper_pid) {
    False -> process.demonitor_process(reaper_monitor)
    True -> {
      let reply = process.new_subject()
      process.send(commands, Adopt(process.self(), stop, reply))
      // Admission is bounded by the reaper's monitor, not a scheduling guess.
      // Timing out a live but delayed reaper would make this effect disappear
      // without either running its body or reporting a terminal result.
      let accepted =
        process.new_selector()
        |> process.select_map(reply, fn(value) { value })
        |> process.select_specific_monitor(reaper_monitor, fn(_down) { False })
        |> process.selector_receive_forever()
      process.demonitor_process(reaper_monitor)
      case accepted {
        True -> {
          // The context travels inside `body`; stamping it here also
          // correlates a crash report emitted by this worker process.
          log.adopt(logger)
          body()
        }
        False -> process.unlink(reaper_pid)
      }
    }
  }
}

// The worker publishes the stream's transitive owner before it waits for one
// byte. This acknowledgement transfers the restart barrier to the reaper. If
// the reaper is already draining, ownership stays here: cancel and wait before
// this worker is allowed to exit.
fn track_provider_owner(reaper: Reaper, handle: stream.StreamHandle) -> Bool {
  let Reaper(commands:, pid: reaper_pid) = reaper
  let reaper_monitor = process.monitor(reaper_pid)
  let reply = process.new_subject()
  process.send(commands, TrackProvider(process.self(), handle, reply))
  // The reply commits an ownership transfer. Only that reply or the reaper's
  // Down can resolve it; a wall-clock timeout cannot tell whether the reaper
  // recorded the owner and would create an ambiguous double custodian.
  let accepted =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(reaper_monitor, fn(_down) { False })
    |> process.selector_receive_forever()
  process.demonitor_process(reaper_monitor)
  accepted
}

fn spawn_provider(
  state: State,
  token: EffectToken,
  configuration: StrandConfiguration,
  spec: effects.RequestSpec,
) -> State {
  let parent = state.internal
  let driver = process.self()
  let surface = state.effects.provider
  let logger = step_logger(state, token)
  log.debug(logger, "effect.dispatched", [
    field.text(key: "kind", value: effect_kind(token)),
    field.text(key: "model", value: configuration.model.model_id),
  ])
  let #(pid, stop) =
    spawn_provider_effect(state.reaper, logger, fn(stop) {
      let provider_custodian.Prepared(handle:, begin:) =
        provider_custodian.prepare(surface, spec)
      let drain = stream.watch_drain(handle)
      case track_provider_owner(state.reaper, handle) {
        False -> {
          stream.cancel(handle)
          require_provider_drain(drain)
        }
        True -> {
          begin()
          case
            await_provider(
              handle,
              stop,
              driver,
              effects.provider_timeout_ms(surface),
            )
          {
            None -> stream.release_drain(drain)
            Some(terminal) -> {
              // The terminal and the owner drain are separate facts. Keeping
              // this effect private until the public owner exits prevents both
              // the current driver and a replacement from dispatching beside
              // the old subtree.
              require_provider_drain(drain)
              wake(parent, ProviderDone(token:, terminal:))
            }
          }
        }
      }
    })
  let monitor = process.monitor(pid)
  State(..state, live: [
    Live(token:, pid:, stop:, monitor:, configuration:, call: None),
    ..state.live
  ])
}

// The cancellation grace is an acknowledgement window, not another provider
// timeout. A request owner normally answers immediately after it has handed
// cancellation to its active transport; the short bound keeps a broken owner
// from delaying the strand after the original wait has already expired.
// `Some(terminal)` belongs to a still-live driver. `None` means driver death
// transferred the only remaining obligation to the reaper's owner monitor, so
// this effect exits without fabricating or forwarding an outcome.
const provider_cancel_grace_ms = 2000

fn await_provider(
  handle: stream.StreamHandle,
  stop: Subject(Nil),
  driver: Pid,
  timeout_ms: Int,
) -> Option(stream.StreamEvent) {
  case next_provider_event(handle, stop, timeout_ms) {
    Ok(stream.Delta(..)) -> await_provider(handle, stop, driver, timeout_ms)
    Ok(stream.Settled(..) as terminal) | Ok(stream.Failed(..) as terminal) ->
      Some(terminal)
    Error(ProviderStopped) -> {
      stream.cancel(handle)
      case process.is_alive(driver) {
        True -> await_provider_cancel(handle, stop, driver)
        // The reaper sent this stop after observing the driver's Down. No
        // caller remains to consume a terminal, and the reaper independently
        // retains `handle.owner`, so exiting transfers teardown to that
        // monitor instead of spending a grace interval on discarded output.
        False -> None
      }
    }
    Error(ProviderWaitExpired) -> {
      stream.cancel(handle)
      await_provider_cancel(handle, stop, driver)
    }
  }
}

fn await_provider_cancel(
  handle: stream.StreamHandle,
  stop: Subject(Nil),
  driver: Pid,
) -> Option(stream.StreamEvent) {
  let deadline = process.new_subject()
  let _timer = process.send_after(deadline, provider_cancel_grace_ms, Nil)
  let selector =
    process.new_selector()
    |> process.select_map(handle.events, ProviderStream)
    |> process.select_map(stop, fn(_nil) { StopProvider })
    |> process.select_map(deadline, fn(_nil) { ProviderCancelExpired })
  await_provider_cancel_selected(selector, driver)
}

// This loop retains the selector carrying the one scheduled deadline. Late
// deltas are discarded without refreshing the grace period, so a noisy or
// broken transport cannot keep an effect live forever after cancellation.
fn await_provider_cancel_selected(
  selector: process.Selector(ProviderWaitEvent),
  driver: Pid,
) -> Option(stream.StreamEvent) {
  case process.selector_receive_forever(selector) {
    ProviderStream(stream.Delta(..)) ->
      await_provider_cancel_selected(selector, driver)
    ProviderStream(stream.Settled(..) as terminal)
    | ProviderStream(stream.Failed(..) as terminal) -> Some(terminal)
    StopProvider ->
      case process.is_alive(driver) {
        True -> {
          Some(stream.Failed(error: stream.CancellationUnconfirmed))
        }
        False -> None
      }
    ProviderCancelExpired ->
      Some(stream.Failed(error: stream.CancellationUnconfirmed))
  }
}

// The private selector event keeps stream traffic and the reaper's cooperative
// stop distinct. `ProviderWaitFailure` carries the distinction into the
// timeout branch without assigning protocol meaning to a Boolean.
fn next_provider_event(
  handle: stream.StreamHandle,
  stop: Subject(Nil),
  within_ms: Int,
) -> Result(stream.StreamEvent, ProviderWaitFailure) {
  let selector =
    process.new_selector()
    |> process.select_map(handle.events, ProviderStream)
    |> process.select_map(stop, fn(_nil) { StopProvider })
  case process.selector_receive(selector, within_ms) {
    Ok(ProviderStream(event)) -> Ok(event)
    Ok(StopProvider) -> Error(ProviderStopped)
    Ok(ProviderCancelExpired) | Error(Nil) -> Error(ProviderWaitExpired)
  }
}

// The reaper can safely retire this effect only after the provider owner's
// normal Down proves its whole registered subtree drained. An abnormal Down
// must remain abnormal at this boundary so the enclosing reaper cannot mistake
// lost ownership for a completed effect.
fn require_provider_drain(witness: stream.DrainWitness) -> Nil {
  case stream.await_drain_forever(witness) {
    stream.Drained -> Nil
    stream.TimedOut | stream.ProofLost -> process.kill(process.self())
  }
}

fn spawn_tool(
  state: State,
  token: EffectToken,
  configuration: StrandConfiguration,
  run: effects.ToolRun,
) -> State {
  let parent = state.internal
  let runner = state.effects.tools.run
  let call = run.call
  let logger = step_logger(state, token)
  log.debug(logger, "effect.dispatched", [
    field.text(key: "kind", value: effect_kind(token)),
    field.text(key: "tool", value: run.call.name),
    field.flag(key: "replay", value: run.replay == operation.ReplaySafe),
  ])
  let #(pid, stop) =
    spawn_effect(state.reaper, logger, fn() {
      let outcome = runner(run)
      wake(parent, ToolDone(token:, outcome:))
    })
  let monitor = process.monitor(pid)
  State(..state, live: [
    Live(token:, pid:, stop:, monitor:, configuration:, call: Some(call)),
    ..state.live
  ])
}

// --- loading and validation (spec §3.1) -----------------------------------

fn load(state: State) -> Result(LoadOutcome, String) {
  use strand_cell <- result.try(read_decoded(
    state,
    register.StrandState,
    state.strand,
    codec.decode_strand_state,
  ))
  case strand_cell {
    None -> Error("strand.state is missing for strand " <> state.strand)
    Some(#(strand_state_seq, strand_state)) ->
      case strand_state.current_operation {
        None -> Ok(Idle)
        Some(op_id) ->
          load_operation(state, op_id, strand_state, strand_state_seq)
      }
  }
}

fn load_operation(
  state: State,
  op_id: OpId,
  strand_state: StrandState,
  strand_state_seq: Seq,
) -> Result(LoadOutcome, String) {
  let op_key = ids.op_id_to_string(op_id)
  use meta_cell <- result.try(read_decoded(
    state,
    register.OpMeta,
    op_key,
    codec.decode_operation,
  ))
  use state_cell <- result.try(read_decoded(
    state,
    register.OpState,
    op_key,
    codec.decode_state,
  ))
  use configuration_cell <- result.try(read_decoded(
    state,
    register.StrandConfig,
    state.strand,
    codec.decode_configuration,
  ))
  use leaf_cell <- result.try(read_leaf(state))
  case meta_cell, state_cell, configuration_cell {
    None, _, _ | _, None, _ ->
      Error("strand.state names an operation whose registers are missing")
    _, _, None -> Error("strand.config is missing for strand " <> state.strand)
    Some(#(_, op)),
      Some(#(op_state_seq, op_state)),
      Some(#(configuration_seq, configuration))
    -> {
      use Nil <- result.try(validate_meta(state, op, op_id))
      use batch_source <- result.try(load_batch_source(state, op_state))
      use deferred_source <- result.try(load_deferred_source(state, op_state))
      use pending <- result.try(load_pending(state))
      use tool_args_keys <- result.try(list_keys(
        state,
        register.OpToolArgs,
        op_key,
      ))
      use preparation_keys <- result.try(list_keys(
        state,
        register.OpPreparation,
        op_key,
      ))
      use preparation <- result.try(load_preparation(state, preparation_keys))
      Ok(
        Open(Loaded(
          op:,
          op_state:,
          op_state_seq:,
          strand_state:,
          strand_state_seq:,
          leaf: leaf_cell,
          configuration:,
          configuration_seq:,
          batch_source:,
          deferred_source:,
          preparation:,
          pending:,
          tool_args_keys:,
          preparation_keys:,
        )),
      )
    }
  }
}

fn validate_meta(
  state: State,
  op: Operation,
  op_id: OpId,
) -> Result(Nil, String) {
  case op.id == op_id, op.strand == state.strand {
    True, True -> Ok(Nil)
    False, _ -> Error("op.meta id disagrees with strand.state")
    _, False -> Error("op.meta names a different strand")
  }
}

// The batch's source assistant message is required whenever the phase is
// Tools; a missing or non-assistant entry is terminal corruption.
fn load_batch_source(
  state: State,
  op_state: OperationState,
) -> Result(Option(AgentMessage), String) {
  case op_state {
    RunState(phase: Tools(batch:), ..) -> {
      use message <- result.try(entry_message(state, batch.assistant_entry))
      message
      |> option.to_result("the tool batch's source assistant entry is missing")
      |> result.map(Some)
    }
    _ -> Ok(None)
  }
}

fn load_deferred_source(
  state: State,
  op_state: OperationState,
) -> Result(Option(DeferredHandle), String) {
  let source = case op_state {
    RunState(
      phase: AwaitingDeferred(deferred: DeferredSuspended(source_entry:, ..)),
      ..,
    ) -> Some(source_entry)
    RunState(
      phase: AwaitingDeferred(deferred: DeferredEffectPending(source_entry:, ..)),
      ..,
    ) -> Some(source_entry)
    _ -> None
  }
  case source {
    None -> Ok(None)
    Some(entry_id) -> {
      use message <- result.try(entry_message(state, entry_id))
      case message {
        Some(AssistantMessage(deferred: Some(handle), ..)) -> Ok(Some(handle))
        Some(_) | None -> Error("the deferred source entry carries no handle")
      }
    }
  }
}

fn entry_message(
  state: State,
  id: EntryId,
) -> Result(Option(AgentMessage), String) {
  use found <- result.try(
    writer.get_entries(state.writer, [id])
    |> result.map_error(describe_read_error),
  )
  case dict.get(found, id) {
    Error(Nil) -> Ok(None)
    Ok(entry.MessageEntry(message:, ..)) -> Ok(Some(message))
    Ok(_) -> Ok(None)
  }
}

fn load_pending(state: State) -> Result(Dict(String, PendingEntry), String) {
  use cells <- result.try(
    writer.list_registers(state.writer, register.PendingEntry, None)
    |> result.map_error(describe_read_error),
  )
  cells
  |> list.try_map(fn(pair) {
    let #(key, storage.Register(value:, ..)) = pair
    codec.decode_pending_entry(value.payload)
    |> result.map(fn(pending) { #(key, pending) })
    |> result.map_error(corruption.describe)
  })
  |> result.map(dict.from_list)
}

fn load_preparation(
  state: State,
  keys: List(String),
) -> Result(Option(StructuralPreparation), String) {
  case keys {
    [] -> Ok(None)
    [key, ..] -> {
      use cell <- result.try(
        writer.get_register(state.writer, register.OpPreparation, key)
        |> result.map_error(describe_read_error),
      )
      case cell {
        None -> Ok(None)
        Some(storage.Register(value:, ..)) ->
          codec.decode_preparation(value.payload)
          |> result.map(Some)
          |> result.map_error(corruption.describe)
      }
    }
  }
}

fn list_keys(
  state: State,
  ns: register.RegisterNs,
  prefix: String,
) -> Result(List(String), String) {
  case writer.list_registers(state.writer, ns, Some(prefix)) {
    Ok(cells) -> Ok(list.map(cells, fn(pair) { pair.0 }))
    Error(error) -> Error(describe_read_error(error))
  }
}

fn read_decoded(
  state: State,
  ns: register.RegisterNs,
  key: String,
  decode: fn(JsonValue) -> Result(payload, corruption.CorruptionReport),
) -> Result(Option(#(Seq, payload)), String) {
  case writer.get_register(state.writer, ns, key) {
    Error(error) -> Error(describe_read_error(error))
    Ok(None) -> Ok(None)
    Ok(Some(storage.Register(value:, seq:))) ->
      case decode(value.payload) {
        Ok(payload) -> Ok(Some(#(seq, payload)))
        Error(report) -> Error(corruption.describe(report))
      }
  }
}

fn read_leaf(state: State) -> Result(Option(EntryId), String) {
  case writer.get_register(state.writer, register.StrandLeaf, state.strand) {
    Error(error) -> Error(describe_read_error(error))
    Ok(None) -> Error("strand.leaf is missing for strand " <> state.strand)
    Ok(Some(storage.Register(value:, ..))) ->
      case register.read_leaf(value) {
        Ok(leaf) -> Ok(leaf)
        Error(report) -> Error(corruption.describe(report))
      }
  }
}

// Whether a call of the named tool may start now, given the live tool
// effects: an `Exclusive` tool starts only alone, and nothing starts
// beside a live `Exclusive` tool. With no live tool effects the answer
// is always yes, so sequential batches are unaffected.
fn tool_may_start(state: State, name: String) -> Bool {
  let mode = state.effects.tools.execution_mode
  let live_tools =
    list.filter_map(state.live, fn(live) {
      case live.token, live.call {
        ToolEffect(..), Some(call) -> Ok(call.name)
        _, _ -> Error(Nil)
      }
    })
  case live_tools {
    [] -> True
    running ->
      mode(name) == effects.ConcurrentExecution
      && list.all(running, fn(other) {
        mode(other) == effects.ConcurrentExecution
      })
  }
}

// Clearance for one planned call: select the approvals attributed to
// *exactly this call*, consume them, and only then clear through the
// tool surface with the grants the consumption actually won.
//
// Two orderings matter here, both security boundaries (design §5.3):
//
// - **Attribution before anything.** An approval names the exact
//   `{operation, strand, step, source index, call id}` its denial was
//   raised for; a clearance loads only its own approvals, so a grant a
//   human approved for one call can never widen a different call, on
//   this strand or any other. Unscoped records match nothing — failing
//   to widen is the safe direction.
// - **Consume before clearing.** The capability is *exercised* the
//   moment `tools.clear` composes the grants into policy, so the CAS
//   that enforces "one re-execution per approval" must win before that
//   moment, not after it. A lost CAS (a concurrent decision or an
//   explicit consume won the record) drops that record's grants and the
//   clearance proceeds under whatever remains — usually the base policy
//   — instead of dispatching under a grant somebody else already spent.
//   A crash between the consumption commit and the dispatch spends the
//   approval without an execution: fail-safe, never a silent widening.
fn clear_tool_call(
  state: State,
  loaded: Loaded,
  operation: OpId,
  step_id: String,
  source_index: Int,
  call: ToolCall,
  now: Int,
) -> KeyResolution {
  use approved <- or_key_halt(approved_escalations(state))
  let scope =
    escalation.CallScope(
      operation:,
      strand: state.strand,
      step_id:,
      source_index:,
      call_id: call.id,
    )
  let matching =
    list.filter(approved, fn(cell) {
      let #(_seq, record) = cell
      escalation.scoped_to(record, scope)
    })
  use grants <- or_key_halt(consume_escalations(state, matching))
  case
    state.effects.tools.clear(effects.ClearanceQuery(
      operation:,
      step_id:,
      source_index:,
      call:,
      configuration: loaded.configuration,
      grants:,
    ))
  {
    effects.Cleared(effective_arguments:, replay:) ->
      KeyCleared(
        observation: planner.ObservedToolCleared(
          source_index:,
          effective_arguments:,
          replay:,
        ),
        cleared: Cleared(step_id:, source_index:, grants:),
      )
    effects.ClearanceRefused(reason:) ->
      KeyObservation(planner.ObservedToolRefused(
        source_index:,
        result: synthetic_tool_error(call, reason, now),
      ))
  }
}

// The session's approved, unconsumed escalations with the seqs their
// consumption commits must expect. Corrupt records fault the strand —
// they are durable state, and partial trust is a bug class.
fn approved_escalations(
  state: State,
) -> Result(List(#(Seq, escalation.Escalation)), String) {
  use cells <- result.try(
    writer.list_registers(
      state.writer,
      register.FactCustom,
      Some(escalation.key_prefix),
    )
    |> result.map_error(describe_read_error),
  )
  cells
  |> list.try_map(fn(pair) {
    let #(_key, storage.Register(value:, seq:)) = pair
    escalation.decode(value.payload)
    |> result.map(fn(record) { #(seq, record) })
    |> result.map_error(corruption.describe)
  })
  |> result.map(
    list.filter(_, fn(cell) {
      let #(_seq, record) = cell
      record.status == escalation.Approved
    }),
  )
}

// Marks each passed escalation consumed, CAS-guarded by the seq it was
// read at, and returns the grants of exactly the records whose
// consumption commit *won*. A stale expectation means a concurrent
// decision won the record — an explicit consume, a rejection, another
// clearance — so that record's grants are dropped rather than used: the
// caller clears with only the grants it durably owns, which is what
// makes one approval worth at most one widened execution.
fn consume_escalations(
  state: State,
  matching: List(#(Seq, escalation.Escalation)),
) -> Result(List(JsonValue), String) {
  list.try_fold(matching, [], fn(won, cell) {
    let #(seq, record) = cell
    let key = escalation.register_key(record.id)
    let consumed = escalation.consume(record)
    let plan_tx =
      tx.Tx(
        writes: [
          tx.SetRegister(
            ns: register.FactCustom,
            key:,
            value: register.value(escalation.encode(consumed)),
          ),
        ],
        expected: [
          tx.Expect(ns: register.FactCustom, key:, seq: option.Some(seq)),
        ],
      )
    case writer.commit(state.writer, plan_tx) {
      Ok(_) -> Ok(list.append(won, record.grants))
      Error(tx.StaleExpectation(..)) -> Ok(won)
      Error(tx.Corruption(report:)) -> Error(corruption.describe(report))
      Error(tx.Faulted(reason:)) -> Error(reason)
      Error(tx.LeaseLost(held_by:)) -> Error(tx.describe_lease_loss(held_by))
    }
  })
}

fn read_tool_arguments(state: State, key: String) -> Result(JsonValue, String) {
  case writer.get_register(state.writer, register.OpToolArgs, key) {
    Error(error) -> Error(describe_read_error(error))
    Ok(None) -> Error("a safe replay named absent tool arguments: " <> key)
    Ok(Some(storage.Register(value:, ..))) -> Ok(value.payload)
  }
}

fn build_inputs(
  state: State,
  loaded: Loaded,
  observation: Observation,
  now: Int,
) -> planner.PlannerInputs {
  planner.PlannerInputs(
    now:,
    generator: ids.generator(
      clock.fixed(at: now),
      seed: state.effects.entropy(),
    ),
    op_state_seq: loaded.op_state_seq,
    strand_state: loaded.strand_state,
    strand_state_seq: loaded.strand_state_seq,
    leaf: loaded.leaf,
    configuration: loaded.configuration,
    configuration_seq: loaded.configuration_seq,
    stream_options: state.stream_options,
    retry_policy: state.retry_policy,
    pending: loaded.pending,
    // Custom-entry projectors are WP-C-full (M3): none are registered.
    projected_custom_types: [],
    batch_source: loaded.batch_source,
    deferred_source: loaded.deferred_source,
    preparation: loaded.preparation,
    tool_args_keys: loaded.tool_args_keys,
    preparation_keys: loaded.preparation_keys,
    threshold: state.effects.hooks.threshold(effects.ThresholdQuery(
      operation: loaded.op.id,
      strand: state.strand,
    )),
    poll_permit: state.poll_permit,
    observation:,
  )
}

// --- small helpers --------------------------------------------------------

fn source_call(loaded: Loaded, source_index: Int) -> Result(ToolCall, String) {
  case loaded.batch_source {
    None -> Error("a tool key was resolved without a batch source message")
    Some(AssistantMessage(content:, ..)) ->
      case
        content
        |> list.drop(source_index)
        |> list.first
      {
        Ok(AssistantToolCall(call:)) -> Ok(call)
        Ok(_) | Error(Nil) -> Error("no tool call at the batch's source index")
      }
    Some(_) -> Error("the batch source entry is not an assistant message")
  }
}

fn synthetic_tool_error(
  call: ToolCall,
  reason: String,
  now: Int,
) -> AgentMessage {
  ToolResultMessage(
    tool_call_id: call.id,
    tool_name: call.name,
    content: [ToolResultText(text: reason, text_signature: None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: True,
    timestamp: now,
  )
}

fn has_live(state: State, token: EffectToken) -> Bool {
  list.any(state.live, fn(live) { live.token == token })
}

fn has_live_tool(state: State, operation: OpId, step_id: String) -> Bool {
  list.any(state.live, fn(live) {
    case live.token {
      ToolEffect(operation: op, step_id: step, ..) ->
        op == operation && step == step_id
      _ -> False
    }
  })
}

fn take_live(state: State, token: EffectToken) -> Option(#(Live, State)) {
  case list.find(state.live, fn(live) { live.token == token }) {
    Error(Nil) -> None
    Ok(live) -> {
      process.demonitor_process(monitor: live.monitor)
      Some(#(live, remove_live(state, token)))
    }
  }
}

fn remove_live(state: State, token: EffectToken) -> State {
  State(
    ..state,
    live: list.filter(state.live, fn(live) { live.token != token }),
  )
}

fn push_observation(state: State, observation: Observation) -> State {
  State(..state, observations: list.append(state.observations, [observation]))
}

fn push_observation_front(state: State, observation: Observation) -> State {
  State(..state, observations: [observation, ..state.observations])
}

fn pop_observation(state: State) -> #(Observation, State) {
  case state.observations {
    [] -> #(NoObservation, state)
    [first, ..rest] -> #(first, State(..state, observations: rest))
  }
}

fn read_clock(state: State) -> #(Int, State) {
  let #(now, clock) = clock.read(state.clock)
  #(now, State(..state, clock:))
}

fn describe_read_error(error: storage.StorageError) -> String {
  case error {
    storage.CorruptRow(report:) -> corruption.describe(report)
    storage.UnknownEntry(id:) -> "unknown entry " <> ids.entry_id_to_string(id)
    storage.BackendFault(reason:) -> reason
    storage.HandleClosed -> "storage handle closed"
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

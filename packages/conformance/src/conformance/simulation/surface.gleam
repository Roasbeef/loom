//// The scripted effect surface a simulated session runs against: the
//// provider, the tools, the hooks, the clock, and the timers, built from
//// one script and one fault schedule.
////
//// Two things here are worth reading twice.
////
//// *Keying.* A provider script must answer the same way on a crashed run
//// as on a clean one, or convergence would be comparing two different
//// conversations. So nothing is keyed by a counter: a generation request
//// is answered by the *phase* of its projected context — how many
//// assistant messages are in it, and whether a summary is — and a tool
//// execution by its scripted call id. Errored, aborted, and deferred
//// responses never enter a projection, so a synthetic settlement written
//// by recovery cannot shift the phase.
////
//// *Hooks that do something.* The runtime's default hooks decline every
//// structural decision and never cross a threshold, which is exactly why
//// the enumerated harness never reached compaction. These hooks trip the
//// threshold from the durable projection (so the decision is the same
//// after a crash), supply or generate summaries, and prepare overflow
//// compactions.

import conformance/simulation/control.{type Control}
import conformance/simulation/fault.{type Schedule}
import conformance/simulation/script.{type Script, type Settle, type Trigger}
import conformance/simulation/vclock.{type Clockwork}
import core/json
import core/message.{
  type AgentMessage, AssistantMessage, AssistantText, AssistantToolCall,
  DeferredHandle, ToolCall, ToolResultMessage, ToolResultText, UserMessage,
  UserText,
}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/operation.{
  type ReplayPolicy, BranchSummaryPreparation, CompactionPreparation,
  CompactionSettings, FileOperations, ReplaySafe,
}
import machine/planner.{
  Admitted, ModelResolved, Prepared, SummaryNeedsRequest, SummaryProduced,
  ThresholdExceeded, ThresholdNotExceeded, VerdictGenerate, VerdictSupplied,
}
import provider/stream
import runtime/api
import runtime/effects.{type Effects}
import session/session.{type Session}

/// The api name every simulated response carries; a deferred handle must
/// match it to be structurally valid.
pub const api_name = "fake"

/// The provider and model identity simulated sessions run under.
pub const provider_name = "acme"

/// The model id simulated sessions run under.
pub const model_id = "loom-1"

/// The summary text structural hooks produce. It carries the marker, so
/// a projection can be asked whether it has been compacted.
pub const summary_text = "[summary] the conversation so far"

/// How long a provider effect waits for its terminal event before
/// settling as a transport failure. Deliberately short: it is the one
/// wall-clock wait a simulated session still makes, and only a scripted
/// timeout fault reaches it.
pub const provider_timeout_ms = 60

/// Builds the effect surface. `raw` is the *uninstrumented* session,
/// which the hooks read so that a scheduled read fault aimed at the
/// driver cannot be swallowed by a hook.
///
/// ## Examples
///
/// ```gleam
/// // surface.build(ctl, vc, script, schedule, raw, strand: "main")
/// ```
///
pub fn build(
  ctl: Control,
  vc: Clockwork,
  script: Script,
  schedule: Schedule,
  raw: Session,
  strand strand: String,
) -> Effects {
  effects.Effects(
    clock: vclock.clock(vc),
    entropy: fn() { 1_000_000 + control.bump(ctl, "entropy") * 104_729 },
    timers: vclock.timers(vc),
    provider: effects.ProviderSurface(
      request: fn(spec) { request(ctl, vc, script, schedule, spec) },
      timeout_ms: provider_timeout_ms,
    ),
    tools: effects.ToolSurface(
      clear: fn(query: effects.ClearanceQuery) {
        case list.key_find(script.registry, query.call.name) {
          Ok(replay) ->
            effects.Cleared(effective_arguments: query.call.arguments, replay:)
          Error(Nil) ->
            effects.ClearanceRefused(
              reason: "unknown tool: " <> query.call.name,
            )
        }
      },
      run: fn(run) { execute(ctl, vc, script, schedule, run) },
      replay_still_safe: fn(name) {
        list.key_find(script.registry, name) == Ok(ReplaySafe)
      },
    ),
    hooks: hooks(ctl, script, raw, strand),
  )
}

// --- the provider ---------------------------------------------------------

fn request(
  ctl: Control,
  vc: Clockwork,
  script: Script,
  schedule: Schedule,
  spec: effects.RequestSpec,
) -> stream.StreamHandle {
  let index = control.bump(ctl, "effect")
  let events = process.new_subject()
  let handle = stream.StreamHandle(events:)
  case effect_fault(ctl, vc, schedule, index, loss_allowed: retryable(spec)) {
    Killed | Starved -> handle
    Ran -> {
      mark_request(ctl, spec)
      intervene(ctl, script, trigger_of_request(spec))
      case settlement(script, spec) {
        Some(settle) -> {
          mark_settlement(ctl, settle)
          note_summary_settled(ctl, spec, settle)
          send_settlement(events, settle)
          handle
        }
        None -> handle
      }
    }
  }
}

// A nested summary request that actually settled. The structural hook
// counts these rather than attempts, so a request lost to a fault leads
// to another request rather than to a summary conjured out of nothing.
fn note_summary_settled(
  ctl: Control,
  spec: effects.RequestSpec,
  settle: Settle,
) -> Nil {
  case spec, settle {
    effects.SummaryRequest(task_id:, ..), script.Answer(..) -> {
      let _count = control.bump(ctl, "summary_settled:" <> task_id)
      Nil
    }
    _, _ -> Nil
  }
}

fn mark_request(ctl: Control, spec: effects.RequestSpec) -> Nil {
  case spec {
    effects.GenerationRequest(..) -> control.mark(ctl, "generation-request")
    effects.PollRequest(..) -> control.mark(ctl, "deferred-poll")
    effects.SummaryRequest(..) -> control.mark(ctl, "summary-request")
  }
}

fn mark_settlement(ctl: Control, settle: Settle) -> Nil {
  case settle {
    script.Answer(..) -> Nil
    script.Calls(..) -> control.mark(ctl, "tool-batch")
    script.Transient -> control.mark(ctl, "retry-ladder")
    script.Defer -> control.mark(ctl, "deferred-suspend")
    script.Overflow -> control.mark(ctl, "overflow-compaction")
  }
}

fn trigger_of_request(spec: effects.RequestSpec) -> Option(Trigger) {
  case spec {
    effects.GenerationRequest(context:, ..) ->
      Some(script.DuringTurn(turn: turn_of(context)))
    effects.PollRequest(..) | effects.SummaryRequest(..) -> None
  }
}

fn settlement(script: Script, spec: effects.RequestSpec) -> Option(Settle) {
  case spec {
    effects.GenerationRequest(context:, ..) ->
      Some(script.settle_for(
        run_op(script),
        turn: turn_of(context),
        summaries: summaries_of(context),
      ))
    effects.PollRequest(..) -> Some(script.poll_answer)
    effects.SummaryRequest(..) ->
      Some(script.Answer(text: "nested summary output", tokens: 2))
  }
}

fn run_op(script: Script) -> script.Op {
  case script.ops {
    [first, ..] -> first
    [] -> script.RunOp(prompt: "task", settles: [], post: answer_settle())
  }
}

fn answer_settle() -> Settle {
  script.Answer(text: "settled", tokens: 3)
}

/// The phase coordinate of a projected context: how many assistant
/// messages it holds.
///
/// ## Examples
///
/// ```gleam
/// // surface.turn_of(context)
/// ```
///
pub fn turn_of(context: List(AgentMessage)) -> Int {
  list.fold(context, 0, fn(count, message) {
    case message {
      AssistantMessage(..) -> count + 1
      _ -> count
    }
  })
}

/// How many summaries a projected context holds.
///
/// ## Examples
///
/// ```gleam
/// // surface.summaries_of(context)
/// ```
///
pub fn summaries_of(context: List(AgentMessage)) -> Int {
  script.summaries_in(list.map(context, text_of))
}

fn text_of(message: AgentMessage) -> String {
  case message {
    UserMessage(content:, ..) ->
      string.join(
        list.map(content, fn(block) {
          case block {
            UserText(text:, ..) -> text
            _ -> ""
          }
        }),
        " ",
      )
    _ -> ""
  }
}

fn send_settlement(
  events: process.Subject(stream.StreamEvent),
  settle: Settle,
) -> Nil {
  case settle {
    script.Transient -> process.send(events, stream.Failed(error: transient()))
    other -> {
      let message = response(other)
      case stream.settle(message) {
        Ok(settled) ->
          process.send(
            events,
            stream.Settled(message: settled, usage: usage_of(message)),
          )
        // A settlement the provider package refuses to settle would be a
        // bug in this script, not in the harness under test; report it
        // as a transport failure so the run still terminates.
        Error(_) -> process.send(events, stream.Failed(error: transient()))
      }
    }
  }
}

fn usage_of(message: AgentMessage) -> message.Usage {
  case message {
    AssistantMessage(usage:, ..) -> usage
    _ -> effects.zero_usage()
  }
}

fn transient() -> stream.ProviderError {
  stream.HttpError(
    status: 500,
    api_error_type: "server_error",
    message: "scripted transient failure",
    retry_after_ms: None,
  )
}

fn response(settle: Settle) -> AgentMessage {
  case settle {
    script.Answer(text:, tokens:) ->
      assistant(
        [AssistantText(text:, text_signature: None)],
        message.Stop,
        tokens,
        None,
      )
    script.Calls(calls:, tokens:) ->
      assistant(
        [
          AssistantText(text: "calling", text_signature: None),
          ..list.map(calls, fn(call: script.Call) {
            AssistantToolCall(call: ToolCall(
              id: call.id,
              name: call.tool,
              arguments: json.Object([]),
              thought_signature: None,
              namespace: None,
            ))
          })
        ],
        message.ToolUse,
        tokens,
        None,
      )
    script.Defer ->
      assistant(
        [],
        message.Deferred,
        0,
        Some(DeferredHandle(
          provider: provider_name,
          model_id:,
          api: api_name,
          id: "deferred-1",
          expires_at: None,
          poll_after_ms: None,
          data: None,
        )),
      )
    // A length stop whose output is below the intended output limit is
    // the harness-side overflow signal.
    script.Overflow ->
      assistant(
        [AssistantText(text: "truncated by the window", text_signature: None)],
        message.Length,
        1,
        None,
      )
    script.Transient ->
      assistant(
        [AssistantText(text: "unused", text_signature: None)],
        message.Stop,
        0,
        None,
      )
  }
}

fn assistant(
  content: List(message.AssistantBlock),
  stop: message.StopReason,
  tokens: Int,
  deferred: Option(message.DeferredHandle),
) -> AgentMessage {
  AssistantMessage(
    content:,
    api: api_name,
    provider: provider_name,
    model: model_id,
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: usage(tokens),
    stop_reason: stop,
    deferred:,
    error_message: None,
    raw_stop_reason: None,
    end_turn: case stop {
      message.Stop -> Some(True)
      _ -> None
    },
    timestamp: 0,
  )
}

/// A usage aggregate reporting `tokens` total, all output.
///
/// ## Examples
///
/// ```gleam
/// assert surface.usage(4).total_tokens == 4
/// ```
///
pub fn usage(tokens: Int) -> message.Usage {
  message.Usage(
    input: 0,
    output: tokens,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: tokens,
    cost: message.UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}

// --- tools ----------------------------------------------------------------

fn execute(
  ctl: Control,
  vc: Clockwork,
  script: Script,
  schedule: Schedule,
  run: effects.ToolRun,
) -> effects.ToolOutcome {
  let index = control.bump(ctl, "effect")
  let _invocations =
    control.bump(ctl, "tool:" <> run.call.name <> ":" <> run.call.id)
  case effect_fault(ctl, vc, schedule, index, loss_allowed: False) {
    Killed | Starved ->
      effects.ToolFailed(reason: "the tree was killed mid-execution")
    Ran -> {
      intervene(ctl, script, Some(script.DuringCall(call: run.call.id)))
      let #(text, is_error) = case list.key_find(script.tools, run.call.name) {
        Ok(script.ToolOk(text:)) -> #(text, False)
        Ok(script.ToolErr(text:)) -> #(text, True)
        Error(Nil) -> #("out:" <> run.call.name, False)
      }
      effects.ToolCompleted(
        result: ToolResultMessage(
          tool_call_id: run.call.id,
          tool_name: run.call.name,
          content: [ToolResultText(text:, text_signature: None)],
          details: None,
          usage: None,
          added_tool_names: None,
          is_error:,
          timestamp: 0,
        ),
        terminate: False,
      )
    }
  }
}

// --- effect faults --------------------------------------------------------

type EffectFate {
  /// Run the script.
  Ran
  /// The tree was killed; nothing this effect produces will be heard.
  Killed
  /// This effect never settles.
  Starved
}

// Losing a provider effect outright — the process dies, or it never
// settles and the surface times it out — is transparent only where a
// retry ladder stands behind it. A deferred poll has none: pi §3.2 gives
// every poll error a response-provenance failure drain, so losing one is
// a semantic change and the schedule skips it there.
fn retryable(spec: effects.RequestSpec) -> Bool {
  case spec {
    effects.GenerationRequest(..) | effects.SummaryRequest(..) -> True
    effects.PollRequest(..) -> False
  }
}

fn effect_fault(
  ctl: Control,
  vc: Clockwork,
  schedule: Schedule,
  index: Int,
  loss_allowed loss_allowed: Bool,
) -> EffectFate {
  list.fold(schedule.faults, Ran, fn(fate, item) {
    case fate, item {
      Ran, fault.CrashDuringEffect(index: at) if at == index ->
        case control.claim(ctl, "crash@e" <> int.to_string(index)) {
          False -> Ran
          True -> {
            control.note_crash(ctl)
            control.mark(ctl, "crash-during-effect")
            kill_tree(ctl)
            Killed
          }
        }
      Ran, fault.ProviderEffectDies(index: at) if at == index ->
        case
          loss_allowed && control.claim(ctl, "died@e" <> int.to_string(index))
        {
          False -> Ran
          True -> {
            control.mark(ctl, "effect-process-died")
            process.kill(process.self())
            Starved
          }
        }
      Ran, fault.ProviderEffectTimesOut(index: at) if at == index ->
        case
          loss_allowed
          && control.claim(ctl, "timeout@e" <> int.to_string(index))
        {
          False -> Ran
          True -> {
            control.mark(ctl, "effect-timed-out")
            Starved
          }
        }
      Ran, fault.SlowEffect(index: at, delay_ms:) if at == index ->
        case control.claim(ctl, "slow@e" <> int.to_string(index)) {
          False -> Ran
          True -> {
            control.mark(ctl, "slow-effect")
            vclock.park(vc, delay_ms)
            Ran
          }
        }
      _, _ -> fate
    }
  })
}

// Kill the writer, not the session supervisor: the supervisor is the top
// of the tree and nothing restarts it, whereas killing its rest-for-one
// first child takes the strand down with it and reboots both — which is
// the crash the session is supposed to survive. The effect process
// running this code is orphaned by that, which is the point: it is the
// mid-flight interruption a commit-boundary crash can never produce.
fn kill_tree(ctl: Control) -> Nil {
  case control.runtime(ctl) {
    None -> Nil
    Some(runtime) ->
      case process.subject_owner(process.named_subject(runtime.tree.writer)) {
        Ok(pid) -> process.kill(pid)
        Error(Nil) -> Nil
      }
  }
}

// --- interventions --------------------------------------------------------

fn intervene(ctl: Control, script: Script, trigger: Option(Trigger)) -> Nil {
  case trigger {
    None -> Nil
    Some(trigger) ->
      list.each(script.interventions, fn(intervention) {
        case script.trigger_of(intervention) == trigger {
          False -> Nil
          True ->
            case
              control.claim(
                ctl,
                "intervention:" <> string.inspect(intervention),
              )
            {
              False -> Nil
              True -> {
                control.mark(ctl, intervention_path(intervention))
                apply(ctl, intervention)
              }
            }
        }
      })
  }
}

/// The coverage path an intervention reaches.
///
/// ## Examples
///
/// ```gleam
/// // surface.intervention_path(script.Abort(script.AtTerminalCommit))
/// ```
///
pub fn intervention_path(intervention: script.Intervention) -> String {
  case intervention, script.trigger_of(intervention) {
    script.Abort(..), script.AtTerminalCommit -> "abort-at-terminal-commit"
    script.Abort(..), _ -> "abort-during-effect"
    script.Steer(..), _ -> "steer-during-effect"
    script.FollowUp(..), _ -> "follow-up-during-effect"
  }
}

/// Applies one intervention against the live session. Exposed because
/// the writer's post-commit seam fires terminal-commit interventions
/// from outside any effect.
///
/// ## Examples
///
/// ```gleam
/// // surface.apply(ctl, script.Abort(script.AtTerminalCommit))
/// ```
///
pub fn apply(ctl: Control, intervention: script.Intervention) -> Nil {
  case control.runtime(ctl) {
    None -> Nil
    Some(runtime) -> {
      let _outcome =
        control.attempt(
          fn() {
            case intervention {
              script.Steer(text:, ..) ->
                discard(api.steer_quietly(runtime, user(text)))
              script.FollowUp(text:, ..) ->
                discard(api.follow_up(runtime, user(text)))
              script.Abort(..) -> api.abort(runtime)
            }
          },
          within_ms: 2000,
        )
      Nil
    }
  }
}

fn discard(outcome: Result(a, b)) -> Nil {
  case outcome {
    Ok(_) | Error(_) -> Nil
  }
}

/// A user message with one text block.
///
/// ## Examples
///
/// ```gleam
/// // surface.user("hello")
/// ```
///
pub fn user(text: String) -> AgentMessage {
  UserMessage(content: [UserText(text:, text_signature: None)], timestamp: 0)
}

// --- hooks ----------------------------------------------------------------

fn hooks(
  ctl: Control,
  script: Script,
  raw: Session,
  strand: String,
) -> effects.Hooks {
  effects.Hooks(
    run_start: fn(_) { [] },
    admission: fn(query: effects.AdmissionQuery) {
      Admitted(
        stream_options: query.stream_options,
        intended_output_limit: 1_000_000,
        context_window: 1_000_000,
      )
    },
    run_end: fn(_) { None },
    threshold: fn(_query) {
      case script.threshold_after {
        None -> ThresholdNotExceeded
        Some(after) -> {
          let context = projection(raw, strand)
          case
            summaries_of(context) == 0
            && turn_of(context) >= after
            && context != []
          {
            False -> ThresholdNotExceeded
            True -> {
              control.mark(ctl, "threshold-compaction")
              ThresholdExceeded(outcome: compaction(context))
            }
          }
        }
      }
    },
    overflow_preparation: fn(_) {
      let context = projection(raw, strand)
      compaction(context)
    },
    structural_decision: fn(_op, _task) {
      case script.structural {
        script.Supplied -> {
          control.mark(ctl, "structural-supplied")
          VerdictSupplied(summary: summary_text, usage: None)
        }
        script.Generated(..) -> {
          control.mark(ctl, "structural-generated")
          VerdictGenerate
        }
      }
    },
    summary_progress: fn(_op, task, _attempt) {
      let wanted = case script.structural {
        script.Generated(split: True) -> 2
        _ -> 1
      }
      case control.read(ctl, "summary_settled:" <> task) >= wanted {
        True -> SummaryProduced(summary: summary_text, usage: None)
        False -> SummaryNeedsRequest
      }
    },
    resolution: fn(_) { ModelResolved },
  )
}

/// The strand's current projected context, read straight from the store.
/// Hooks decide from durable state so that a decision taken before a
/// crash is taken again after it.
///
/// ## Examples
///
/// ```gleam
/// // surface.projection(session, "main")
/// ```
///
pub fn projection(raw: Session, strand: String) -> List(AgentMessage) {
  case session.strand_leaf(raw, strand) {
    Ok(Some(cell)) ->
      case session.project_context(raw, cell.value) {
        Ok(messages) -> messages
        Error(_) -> []
      }
    _ -> []
  }
}

fn compaction(context: List(AgentMessage)) -> planner.PreparationOutcome {
  case compaction_preparation(context) {
    None -> planner.EmptyPreparation
    Some(preparation) -> Prepared(preparation:)
  }
}

/// The compaction preparation a threshold, an overflow, or a standalone
/// compaction operation summarizes from.
///
/// ## Examples
///
/// ```gleam
/// // surface.compaction_preparation(context)
/// ```
///
pub fn compaction_preparation(
  context: List(AgentMessage),
) -> Option(operation.StructuralPreparation) {
  case context {
    [] -> None
    messages ->
      Some(CompactionPreparation(
        messages_to_summarize: messages,
        turn_prefix_messages: [],
        retained_tail: [],
        is_split_turn: False,
        tokens_before: 1000,
        previous_summary: None,
        file_ops: FileOperations(read: [], written: [], edited: []),
        settings: CompactionSettings(
          enabled: True,
          reserve_tokens: 0,
          keep_recent_tokens: 0,
        ),
      ))
  }
}

/// The branch-summary preparation a summarized navigation needs.
///
/// ## Examples
///
/// ```gleam
/// // surface.branch_summary(context)
/// ```
///
pub fn branch_summary(
  context: List(AgentMessage),
) -> Option(operation.StructuralPreparation) {
  case context {
    [] -> None
    messages ->
      Some(BranchSummaryPreparation(
        messages:,
        file_ops: FileOperations(read: [], written: [], edited: []),
        total_tokens: 100,
      ))
  }
}

/// The replay policy table simulated sessions register.
///
/// ## Examples
///
/// ```gleam
/// // surface.registry_of(script)
/// ```
///
pub fn registry_of(script: Script) -> List(#(String, ReplayPolicy)) {
  script.registry
}

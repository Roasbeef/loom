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
import gleam/bool
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
  type ThresholdStatus, Prepared, SummaryNeedsRequest, SummaryProduced,
  ThresholdExceeded, ThresholdNotExceeded, VerdictGenerate, VerdictSupplied,
}
import provider/stream
import runtime/api
import runtime/effects.{type Effects}
import runtime/escalation
import runtime/hooks
import runtime/supervisor
import session/session.{type Session}

/// The api name every simulated response carries; a deferred handle must
/// match it to be structurally valid.
pub const api_name = "fake"

/// The provider and model identity simulated sessions run under.
pub const provider_name = "acme"

/// The model id simulated sessions run under.
pub const model_id = "loom-1"

/// The model id a simulated subagent strand is configured with. Its
/// generation requests are answered by identity, not by the main
/// script's turns, so a child's settlement is the same in both runs
/// regardless of how much shared history it forked over.
pub const sub_model_id = "loom-sub"

/// The subagent strand's name (the runner re-exports it). The surface
/// needs it so a strand-restart fault kills the driver actually serving
/// the faulted effect — a subagent's generation must restart the
/// subagent, not main.
pub const sub_strand = "sub:1"

/// The text of the durable cross-strand message the runner sends back to
/// the main strand once the subagent finishes. A generation whose newest
/// user input is this report is answered directly — never from the
/// scripted turns, whose phase coordinates the run may have rewound past
/// (a navigation moves the leaf back, and replaying turn 0 would re-mint
/// scripted call ids that must name exactly one call in the tree).
pub const cross_report = "subagent reports: verified"

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
      request: fn(spec) { request(ctl, vc, script, schedule, strand, spec) },
      timeout_ms: provider_timeout_ms,
    ),
    tools: effects.ToolSurface(
      clear: fn(query: effects.ClearanceQuery) {
        clearance(ctl, script, strand, query)
      },
      run: fn(run) { execute(ctl, vc, script, schedule, strand, run) },
      replay_still_safe: fn(name) {
        list.key_find(script.registry, name) == Ok(ReplaySafe)
      },
      // Scripted tools may always overlap; per-tool exclusivity has its
      // own dedicated runtime test.
      execution_mode: fn(_name) { effects.ConcurrentExecution },
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
  strand: String,
  spec: effects.RequestSpec,
) -> stream.StreamHandle {
  let index = control.bump(ctl, "effect")
  let events = process.new_subject()
  let handle = stream.StreamHandle(events:)
  let on_strand = strand_of_spec(spec, strand)
  case
    effect_fault(
      ctl,
      vc,
      schedule,
      index,
      strand: on_strand,
      loss_allowed: retryable(spec),
    )
  {
    Killed | Starved -> handle
    Ran -> {
      mark_request(ctl, spec)
      intervene(ctl, script, trigger_of_request(spec))
      case settlement(script, spec) {
        Some(settle) -> {
          mark_settlement(ctl, settle)
          send_settlement(events, settle)
          handle
        }
        None -> handle
      }
    }
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

// A subagent request never fires a `DuringTurn` intervention: those name
// the main strand's turns, and a child forked over shared history would
// otherwise claim them at an unrelated moment.
fn trigger_of_request(spec: effects.RequestSpec) -> Option(Trigger) {
  case spec {
    effects.GenerationRequest(context:, configuration:, ..) ->
      case configuration.model.model_id == sub_model_id {
        True -> None
        False -> Some(script.DuringTurn(turn: turn_of(context)))
      }
    effects.PollRequest(..) | effects.SummaryRequest(..) -> None
  }
}

fn settlement(script: Script, spec: effects.RequestSpec) -> Option(Settle) {
  case spec {
    effects.GenerationRequest(context:, configuration:, ..) ->
      case
        configuration.model.model_id == sub_model_id,
        newest_user_text(context) == cross_report
      {
        True, _ -> Some(script.Answer(text: "subagent verified", tokens: 2))
        False, True ->
          Some(script.Answer(text: "acknowledged: verified", tokens: 1))
        False, False ->
          Some(script.settle_for(
            run_op(script),
            turn: turn_of(context),
            summaries: summaries_of(context),
          ))
      }
    effects.PollRequest(..) -> Some(script.poll_answer)
    effects.SummaryRequest(..) ->
      Some(script.Answer(text: "nested summary output", tokens: 2))
  }
}

// The newest user message's text in a projected context, "" when none.
fn newest_user_text(context: List(AgentMessage)) -> String {
  list.fold(context, "", fn(found, message) {
    case message {
      UserMessage(..) -> text_of(message)
      _ -> found
    }
  })
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

// Clearance for one planned call. Ordinary scripts clear by registry
// lookup alone; an `escalate` script additionally drives the durable
// escalation machinery through its first clearance (see
// `escalation_dance`), and a `parallel` script marks the per-call
// frontier when it clears a later call of a batch — under sequential
// scheduling that clearance only happens after the earlier call settled,
// so reaching it under parallel settings is the overlapping-frontier
// path itself.
fn clearance(
  ctl: Control,
  script: Script,
  strand: String,
  query: effects.ClearanceQuery,
) -> effects.Clearance {
  case list.key_find(script.registry, query.call.name) {
    Error(Nil) ->
      effects.ClearanceRefused(reason: "unknown tool: " <> query.call.name)
    Ok(replay) -> {
      case script.parallel && query.source_index >= 1 {
        True -> control.mark(ctl, "parallel-tools")
        False -> Nil
      }
      case script.escalate {
        True -> escalation_dance(ctl, strand, query, replay)
        False ->
          effects.Cleared(effective_arguments: query.call.arguments, replay:)
      }
    }
  }
}

// The escalation dance, fired exactly once per session (the claim
// outlives every restart): at the first clearance the script performs,
// raise an escalation scoped to exactly that call, approve it, and kill
// the strand driver — this hook runs inside the driver's own process —
// so the replan re-clears the *same durable coordinates* with the
// approval in place. The re-clearance then consumes the grant before
// this hook sees it (consume-before-clear), which the `escalation-
// consumed` mark records. The raise and approve run on a disposable
// process (`control.attempt`) so a schedule that kills the writer
// mid-commit costs the approval, not the run: a re-clearance that finds
// no grant clears under the base policy, which converges to the same
// transcript because the scripted tools ignore grants entirely.
fn escalation_dance(
  ctl: Control,
  strand: String,
  query: effects.ClearanceQuery,
  replay: ReplayPolicy,
) -> effects.Clearance {
  case control.claim(ctl, "escalation-dance") {
    True -> {
      control.mark(ctl, "escalation-raised")
      let _approved =
        control.attempt(
          ctl,
          at: "escalation",
          action: fn() { raise_and_approve(ctl, strand, query) },
          within_ms: 3000,
        )
      // Restart the driver (not the tree): recovery replans from the
      // durable Tools phase and resolves this clearance again.
      process.kill(process.self())
      effects.ClearanceRefused(reason: "unreachable: the driver was killed")
    }
    False -> {
      case query.grants {
        [] -> Nil
        _ -> control.mark(ctl, "escalation-consumed")
      }
      effects.Cleared(effective_arguments: query.call.arguments, replay:)
    }
  }
}

fn raise_and_approve(
  ctl: Control,
  strand: String,
  query: effects.ClearanceQuery,
) -> Result(Nil, Nil) {
  case control.runtime(ctl) {
    None -> Error(Nil)
    Some(runtime) -> {
      let scope =
        escalation.CallScope(
          operation: query.operation,
          strand:,
          step_id: query.step_id,
          source_index: query.source_index,
          call_id: query.call.id,
        )
      let denial =
        json.Object([
          #("reason", json.String("scripted denial")),
          #("wanted", json.Array([scripted_grant()])),
        ])
      case api.raise_escalation_for(runtime, "esc-sim", denial, scope: scope) {
        Error(_) -> Error(Nil)
        Ok(Nil) ->
          case api.approve_escalation(runtime, "esc-sim", [scripted_grant()]) {
            Ok(Nil) -> Ok(Nil)
            Error(_) -> Error(Nil)
          }
      }
    }
  }
}

fn scripted_grant() -> json.JsonValue {
  json.Object([#("grant", json.String("scripted"))])
}

fn execute(
  ctl: Control,
  vc: Clockwork,
  script: Script,
  schedule: Schedule,
  strand: String,
  run: effects.ToolRun,
) -> effects.ToolOutcome {
  let index = control.bump(ctl, "effect")
  let _invocations =
    control.bump(ctl, "tool:" <> run.call.name <> ":" <> run.call.id)
  case effect_fault(ctl, vc, schedule, index, strand:, loss_allowed: False) {
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

// Which strand's driver is serving a request spec: the subagent answers
// by its own durable model identity, everything else runs on the main
// strand the surface was built for.
fn strand_of_spec(spec: effects.RequestSpec, main: String) -> String {
  case spec {
    effects.GenerationRequest(configuration:, ..)
    | effects.PollRequest(configuration:, ..)
    | effects.SummaryRequest(configuration:, ..) ->
      case configuration.model.model_id == sub_model_id {
        True -> sub_strand
        False -> main
      }
  }
}

fn effect_fault(
  ctl: Control,
  vc: Clockwork,
  schedule: Schedule,
  index: Int,
  strand strand: String,
  loss_allowed loss_allowed: Bool,
) -> EffectFate {
  list.fold(schedule.faults, Ran, fn(fate, item) {
    case fate, item {
      Ran, fault.CrashDuringEffect(index: at) if at == index ->
        claimed_effect(ctl, "crash@e" <> int.to_string(index), fn() {
          control.note_crash(ctl)
          control.mark(ctl, "crash-during-effect")
          kill_tree(ctl)
          Killed
        })
      Ran, fault.RestartStrand(index: at) if at == index ->
        claimed_effect(ctl, "strandkill@e" <> int.to_string(index), fn() {
          control.mark(ctl, "strand-restart-during-effect")
          // Kill only this effect's own driver: the partial crash.
          // The dying incarnation's reaper takes this very effect
          // process down with it, so nothing is settled from here —
          // and anything sent regardless is dropped by the wake
          // guard, because the incarnation it addresses is gone.
          kill_strand(ctl, strand)
          Killed
        })
      Ran, fault.ProviderEffectDies(index: at) if at == index ->
        case loss_allowed {
          False -> Ran
          True ->
            claimed_effect(ctl, "died@e" <> int.to_string(index), fn() {
              control.mark(ctl, "effect-process-died")
              process.kill(process.self())
              Starved
            })
        }
      Ran, fault.ProviderEffectTimesOut(index: at) if at == index ->
        case loss_allowed {
          False -> Ran
          True ->
            claimed_effect(ctl, "timeout@e" <> int.to_string(index), fn() {
              control.mark(ctl, "effect-timed-out")
              Starved
            })
        }
      Ran, fault.SlowEffect(index: at, delay_ms:) if at == index ->
        claimed_effect(ctl, "slow@e" <> int.to_string(index), fn() {
          control.mark(ctl, "slow-effect")
          vclock.park(vc, delay_ms)
          Ran
        })
      _, _ -> fate
    }
  })
}

// A fault fires only once: the first fold pass to reach it claims the
// one-shot slot and runs its consequence, every later pass (or a losing
// race with another fault at the same index) finds it already claimed
// and leaves the fate alone.
fn claimed_effect(
  ctl: Control,
  key: String,
  on_claim: fn() -> EffectFate,
) -> EffectFate {
  use <- bool.guard(when: !control.claim(ctl, key), return: Ran)
  on_claim()
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

// Kill one strand's driver and nothing else: the factory restarts it
// alone, while the writer keeps serving every other strand's commits.
// This is the interruption neither a commit-boundary crash nor a tree
// kill can produce — the tree survives, so the restarted incarnation's
// recovery races whatever the dead incarnation left behind.
fn kill_strand(ctl: Control, strand: String) -> Nil {
  case control.runtime(ctl) {
    None -> Nil
    Some(runtime) ->
      case supervisor.strand_subject(runtime.tree, strand) {
        Error(Nil) -> Nil
        Ok(subject) ->
          case process.subject_owner(subject) {
            Ok(pid) -> process.kill(pid)
            Error(Nil) -> Nil
          }
      }
  }
}

// --- interventions --------------------------------------------------------

// Everything this trigger is due fires together, on one disposable
// process, in script order.
//
// A steer and a follow-up scripted at the same turn are two halves of
// one scripted moment, and the trigger that names them is a *phase* —
// once the first of them commits, the projection has moved and that
// phase never comes round again. Firing them one process at a time
// leaves the gap between them exposed to the dying strand incarnation's
// reaper: it lands in the gap, takes the effect process down before the
// second admission is even attempted, and the second turn is gone for
// the rest of the run. One unlinked carrier makes the group
// all-or-nothing with respect to that.
//
// Measured honestly, closing this window did not move the observed rate
// of the divergence it was suspected of causing (issue #44, seed 53):
// the dominant cause is a carrier that is itself lost, which no
// arrangement of the callers can prevent and which the run records
// instead. The window was real, so it is closed; it was not the bug.
fn intervene(ctl: Control, script: Script, trigger: Option(Trigger)) -> Nil {
  case trigger {
    None -> Nil
    Some(trigger) ->
      case
        list.filter(script.interventions, fn(intervention) {
          script.trigger_of(intervention) == trigger
        })
      {
        [] -> Nil
        [_, ..] as due -> apply_all(ctl, due, awaited: True)
      }
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
/// `awaited` decides whether the caller waits for the admission to
/// commit. An effect script waits, because the whole point of steering
/// from inside a live effect is that the steer is durable *before* the
/// settlement that must then lose its seq race to it. The writer's
/// post-commit seam must not wait: admission calls back into that same
/// writer, so waiting there deadlocks it for the length of the timeout.
///
/// ## Examples
///
/// ```gleam
/// // surface.apply(ctl, script.Abort(script.AtTerminalCommit), awaited: False)
/// ```
///
pub fn apply(
  ctl: Control,
  intervention: script.Intervention,
  awaited awaited: Bool,
) -> Nil {
  apply_all(ctl, [intervention], awaited:)
}

// Nothing to admit against until the runtime handle is published; a
// trigger that fires before then simply has no session to reach.
fn apply_all(
  ctl: Control,
  due: List(script.Intervention),
  awaited awaited: Bool,
) -> Nil {
  case control.runtime(ctl) {
    None -> Nil
    Some(runtime) -> apply_on(ctl, runtime, due, awaited)
  }
}

// Each admission reports whether it landed, and a refusal that should
// not have happened is recorded rather than dropped. Every `api.ApiError`
// reaches the caller having written nothing, so a refused steer is a
// turn the transcript has permanently lost: from there the faulted run
// is a different conversation from the fault-free one, and the runner
// would report it one check later as an unexplained one-turn divergence
// rather than as the harness fault it is.
//
// The note goes to `control.note`, which the runner collects into
// `Report.violations` and fails the seed on. Recording the drop rather
// than rescheduling around it is deliberate: seeds are drawn against
// the fault schedule, so adding a step to it would renumber every
// commit-indexed fault and retire the pinned corpus as a before/after
// oracle. A note changes no schedule, and on a green run this path
// does not fire at all.
fn apply_on(
  ctl: Control,
  runtime: api.Runtime,
  due: List(script.Intervention),
  awaited: Bool,
) -> Nil {
  // Claiming, admitting, and recording all happen on the carrier, so
  // the group survives its caller: an effect process reaped halfway
  // through still leaves a run whose scripted turns all landed and were
  // all accounted for.
  let act = fn() {
    list.each(due, fn(intervention) {
      claim_perform_record(ctl, runtime, intervention)
    })
  }
  case awaited {
    True ->
      case control.attempt(ctl, at: "intervene", action: act, within_ms: 2000) {
        control.Answered(Nil) -> Nil
        // The disposable process carrying the admissions died addressing
        // a tree that was mid-restart, or it did not answer inside the
        // window. Neither says a commit failed — one may have landed
        // with only the reply lost — so both are marked, not noted:
        // faulting the seed here would fail it for something the
        // harness cannot prove. A steer that truly vanished still
        // fails, one check later, on the line-for-line projection
        // comparison. Which of the two happened is recorded separately,
        // by `attempt` itself, and reaches the runner as `Report.waits`.
        control.Raised | control.Expired ->
          control.mark(ctl, "admission-unobserved")
      }
    False -> control.detached(act)
  }
}

// The one-shot claim, the admission it entitles, and the record of how
// that admission went are one indivisible step.
//
// The claim outlives every restart, so whoever takes it owes the run a
// turn. Taking it on the effect process and admitting from somewhere
// else leaves a window — two synchronous calls wide — in which the dying
// strand incarnation's reaper can kill the effect process between the
// two. The claim is spent, nothing was written, the intervention never
// fires again, and the faulted run quietly ends one user turn short of
// the fault-free one. That is not a fault being survived; it is the
// harness dropping a scripted turn, and it reads at the end as an
// unexplained `convergence/projection` divergence. `control.attempt`
// spawns *unlinked*, so a carrier that holds the claim cannot be reaped
// before it has admitted, and an awaited caller still gets the admission
// ordered ahead of the settlement it is about to send.
//
// What this cannot do is save a carrier that is itself lost. That case
// is not prevented here; it is recorded, by the `intervening@` /
// `intervened@` pair below, and reported.
fn claim_perform_record(
  ctl: Control,
  runtime: api.Runtime,
  intervention: script.Intervention,
) -> Nil {
  let path = intervention_path(intervention)
  case
    control.claim_intervention(
      ctl,
      "intervention:" <> string.inspect(intervention),
      path,
    )
  {
    // Already spent: this intervention has fired, and a run that fired
    // it twice would be a different session from the fault-free one.
    False -> Nil
    True -> {
      control.mark(ctl, path)
      // The claim opened a debt and this settles it, whichever way the
      // admission goes. The pair is what lets a failing run say the
      // difference between "this scripted turn was admitted" and "this
      // scripted turn was claimed by a process that never came back":
      // an `intervening@` with no `intervened@` after it is the second,
      // and the runner reports it as harness damage rather than as an
      // unexplained divergence (`runner.timing_line`).
      let outcome = perform(runtime, intervention)
      control.intervened(ctl, path)
      record_landing(ctl, intervention, outcome)
    }
  }
}

fn perform(
  runtime: api.Runtime,
  intervention: script.Intervention,
) -> Result(Nil, String) {
  case intervention {
    script.Steer(text:, ..) ->
      landed("steer", api.steer_quietly(runtime, user(text)))
    script.FollowUp(text:, ..) ->
      landed("follow-up", api.follow_up(runtime, user(text)))
    // Abort is fire-and-forget by design (api §4.6): it returns nothing
    // to honor, and the runner already treats an aborted run's
    // transcript as a race rather than a convergence claim.
    script.Abort(..) -> {
      api.abort(runtime)
      Ok(Nil)
    }
  }
}

fn record_landing(
  ctl: Control,
  intervention: script.Intervention,
  verdict: Result(Nil, String),
) -> Nil {
  case verdict, landing(intervention) {
    Ok(Nil), _ -> Nil
    Error(dropped), MustLand -> control.note(ctl, dropped)
    // A refusal this trigger is entitled to. Marked so the run still
    // reports that it happened, since a mark costs a coverage line and
    // a note costs the seed.
    Error(_dropped), MayBeRefused -> control.mark(ctl, "admission-refused-late")
  }
}

// What an intervention's trigger entitles its admission to.
type Landing {
  /// The queue must accept it; a refusal is a harness fault.
  MustLand
  /// A refusal is the documented outcome, not a drop.
  MayBeRefused
}

// A live trigger fires from inside an effect that belongs to an open
// run, so the queue is there to accept it. `AtTerminalCommit` fires
// after the terminal transaction is already durable, where the
// operation the item would attach to no longer exists — and whether a
// later operation catches the item instead is a race with no property
// behind it (see the note on `script.live_trigger`).
fn landing(intervention: script.Intervention) -> Landing {
  case script.trigger_of(intervention) {
    script.DuringTurn(..) | script.DuringCall(..) -> MustLand
    script.AtTerminalCommit -> MayBeRefused
  }
}

// One admission's verdict, worded as the note the runner would print.
// Every `api.ApiError` reaches here having written nothing, so a refusal
// is always a wholly lost turn and never a partial one.
fn landed(
  what: String,
  outcome: Result(a, api.ApiError),
) -> Result(Nil, String) {
  case outcome {
    Ok(_) -> Ok(Nil)
    Error(error) ->
      Error(
        "admission/"
        <> what
        <> ": refused with "
        <> string.inspect(error)
        <> ", so the transcript lost a turn",
      )
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

// The scripted threshold: unset means never exceeded, and once set it
// trips only once the durable projection itself agrees — no unsummarized
// generation turns and at least `after` turns of them — so the decision
// is the same after a crash as it was before one.
fn threshold_decision(
  ctl: Control,
  raw: Session,
  strand: String,
  threshold_after: Option(Int),
) -> ThresholdStatus {
  case threshold_after {
    None -> ThresholdNotExceeded
    Some(after) -> threshold_past_turn(ctl, raw, strand, after)
  }
}

fn threshold_past_turn(
  ctl: Control,
  raw: Session,
  strand: String,
  after: Int,
) -> ThresholdStatus {
  let context = projection(raw, strand)
  let exceeded =
    summaries_of(context) == 0 && turn_of(context) >= after && context != []
  use <- bool.guard(when: !exceeded, return: ThresholdNotExceeded)
  control.mark(ctl, "threshold-compaction")
  ThresholdExceeded(outcome: compaction(context))
}

// The simulation hooks, built through the production hook registry
// (`runtime/hooks`) so production wiring and the simulation share one
// seam; only the script-driven slots are replaced.
fn hooks(
  ctl: Control,
  script: Script,
  raw: Session,
  strand: String,
) -> effects.Hooks {
  hooks.new()
  |> hooks.with_admission(hooks.admission(
    api: api_name,
    intended_output_limit: 1_000_000,
    context_window: 1_000_000,
  ))
  |> hooks.with_threshold(fn(_query) {
    threshold_decision(ctl, raw, strand, script.threshold_after)
  })
  |> hooks.with_overflow_preparation(fn(_) {
    let context = projection(raw, strand)
    compaction(context)
  })
  |> hooks.with_structural_decision(fn(_op, _task) {
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
  })
  |> hooks.with_summary_progress(fn(_op, task, _attempt) {
    // Counted at the commit boundary (`simulation/store`), not at the
    // surface: only a settlement the ledger durably paid for counts, so
    // one delivered-but-lost with a halted strand's mailbox leads to
    // another request rather than to a summary conjured out of nothing.
    let wanted = case script.structural {
      script.Generated(split: True) -> 2
      _ -> 1
    }
    case control.read(ctl, "summary_settled:" <> task) >= wanted {
      True -> SummaryProduced(summary: summary_text, usage: None)
      False -> SummaryNeedsRequest
    }
  })
  |> hooks.build
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

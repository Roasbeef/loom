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
import core/register
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
import storage/storage
import weft

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

// The one message a starved provider effect's control subject ever
// carries: the racer's own `weft.adopt_leaf` cancel closure sends it, and
// the racer's whole body is the one-arm `case` that receives it.
type SimulatedCancel {
  ReleaseStarved
}

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

const intervention_retry_delay_ms = 5

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
  let consumer = process.self()
  let events = process.new_subject()
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
    Killed -> stream.immediate(events:, cancel: fn() { Nil })
    Starved ->
      // The scripted provider timeout has already won before the runtime's
      // outer deadline asks the handle to stop. Releasing that preselected
      // transport failure on cancel preserves the fault's retry semantics;
      // it is not a cancellation terminal and owns no external process.
      // `weft.cancel_witnessed` is idempotent at the scope itself (a second
      // `CancelRun` finds `scope.cancelling` already set and does nothing),
      // so a repeated cancel costs nothing rather than fabricating a second
      // terminal event.
      starved_handle(events, consumer)
    Ran -> {
      mark_request(ctl, spec)
      intervene(ctl, script, trigger_of_request(spec))
      case settlement(script, spec) {
        Some(settle) -> {
          mark_settlement(ctl, settle)
          send_settlement(events, settle)
          stream.immediate(events:, cancel: fn() { Nil })
        }
        None -> stream.immediate(events:, cancel: fn() { Nil })
      }
    }
  }
}

fn starved_handle(
  events: process.Subject(stream.StreamEvent),
  consumer: process.Pid,
) -> stream.StreamHandle {
  let witnessed =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        // The racer is the only process that ever blocks. `begin` itself
        // parks it under the ledger and returns at once, so weft's
        // cancellation — which kills every worker unconditionally — costs
        // this task nothing it still needs; only the racer, adopted as an
        // owner, is asked to stop rather than killed. `adopt_leaf` names it
        // a leaf: the racer owns no descendants of its own, so any exit of
        // it, not only a normal one, completes the drain, and a stray kill
        // of the racer cannot manufacture a false `DrainProofLost` for
        // work that never had any.
        //
        // `control` must be minted *inside* the racer, not out here: a
        // `Subject` only ever receives on the process that created it
        // (`gleam_erlang`'s `owner` field), so a subject built on `begin`'s
        // own worker would route every send to a process that has already
        // returned by the time `cancel` fires, and the racer's receive
        // would wait on an empty mailbox forever. The `ready` handoff below
        // is the parked-work pattern once more, one level in: the racer
        // publishes its own subject back before `begin` may adopt it.
        let ready = process.new_subject()
        let racer =
          process.spawn_unlinked(fn() {
            let control = process.new_subject()
            process.send(ready, control)
            case process.receive_forever(control) {
              ReleaseStarved ->
                process.send(
                  events,
                  stream.Failed(error: stream.TransportFailed(
                    reason: "simulated provider effect timeout",
                  )),
                )
            }
          })
        let control = process.receive_forever(ready)
        let _adoption =
          weft.adopt_leaf(ledger, owner: racer, cancel: fn() {
            process.send(control, ReleaseStarved)
          })
        Ok(Nil)
      }),
    ])
    // This is the exact handshake the old code hand-rolled inside the
    // racer: a monitor on `consumer`, raced against the release message.
    // Naming the consumer here instead fires the very `cancel` closure
    // weft already calls for an explicit release, so the racer no longer
    // carries a second selector branch of its own — a killed effect and a
    // released handle both arrive as one `ReleaseStarved` send. Only the
    // explicit release's send has anyone left to read it: `events` is
    // owned by `consumer`, so the send a killed effect triggers lands on a
    // subject nobody owns anymore and is silently dropped, which is what
    // keeps "explicit release settles a transport failure, a killed
    // effect settles nothing" true without the racer testing which one
    // happened.
    |> weft.cancel_when_exits(consumer)
    |> weft.start_witnessed
  stream.owned(events:, owner: weft.witness_pid(witnessed), cancel: fn() {
    weft.cancel_witnessed(witnessed)
  })
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

// A live trigger no longer fires its intervention itself. It used to —
// and that was the bug (issue #57, diagnosed under #44): the effect
// process reaching a `DuringTurn`/`DuringCall` trigger is exactly the
// process a `RestartStrand` fault reaps, and firing from inside it meant
// the claim and the carrier could die together, with nothing else ever
// positioned to retry the scripted turn. So this only asks whether the
// script has anything due here — a pure, cheap check that keeps every
// ordinary effect (the overwhelming majority, scripted with nothing
// concurrent at all) from paying for a round trip — and, when it does,
// hands the trigger to the runner and blocks. The runner is never inside
// the tree a schedule can reach, so it is what actually fires the
// intervention, in `fire_due`, from its own drive loop.
//
// The block is still what makes `steer-during-effect` mean anything: the
// caller does not resume — and so does not send its settlement — until
// the runner reports the intervention landed, which is what lets the
// settlement lose its seq race to the steer by construction rather than
// by luck.
fn intervene(ctl: Control, script: Script, trigger: Option(Trigger)) -> Nil {
  case trigger {
    None -> Nil
    Some(trigger) ->
      case interventions_due(script, trigger) {
        [] -> Nil
        [_, ..] -> control.await_intervention(ctl, trigger)
      }
  }
}

fn interventions_due(
  script: Script,
  trigger: Trigger,
) -> List(script.Intervention) {
  list.filter(script.interventions, fn(intervention) {
    script.trigger_of(intervention) == trigger
  })
}

/// Fires every intervention scripted at `trigger`, together. Called from
/// the runner's drive loop once it has taken a pending trigger off
/// `control.take_pending_interventions` — never from inside an effect;
/// see `intervene`'s comment for why that distinction is the whole
/// point.
///
/// Everything due at one trigger fires on one disposable process. Queue
/// admissions retain script order and precede aborts from that same logical
/// moment. A steer and a follow-up scripted at the same turn are two halves of
/// one scripted moment, and the trigger that names them is a *phase*. If the
/// carrier dies between them, the atomic facts written with the completed
/// prefix identify exactly which admissions landed; another carrier retries
/// only the unresolved suffix.
///
/// ## Examples
///
/// ```gleam
/// // surface.fire_due(ctl, script, raw, script.DuringTurn(turn: 1))
/// ```
///
pub fn fire_due(
  ctl: Control,
  script: Script,
  raw: Session,
  trigger: Trigger,
) -> Nil {
  case interventions_due(script, trigger) {
    [] -> Nil
    [_, ..] as due -> apply_all(ctl, raw, due, awaited: True)
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
/// // surface.apply(ctl, raw, script.Abort(script.AtTerminalCommit), awaited: False)
/// ```
///
pub fn apply(
  ctl: Control,
  raw: Session,
  intervention: script.Intervention,
  awaited awaited: Bool,
) -> Nil {
  apply_all(ctl, raw, [intervention], awaited:)
}

// Nothing to admit against until the runtime handle is published; a
// trigger that fires before then simply has no session to reach.
fn apply_all(
  ctl: Control,
  raw: Session,
  due: List(script.Intervention),
  awaited awaited: Bool,
) -> Nil {
  case control.runtime(ctl) {
    None -> Nil
    Some(runtime) -> apply_on(ctl, raw, runtime, due, awaited)
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
  raw: Session,
  runtime: api.Runtime,
  due: List(script.Intervention),
  awaited: Bool,
) -> Nil {
  let claimed = claim_interventions(ctl, due)
  case claimed, awaited {
    [], _ -> Nil
    [_, ..], True -> admit_claimed(ctl, raw, runtime, claimed)
    [_, ..], False ->
      control.detached(fn() { admit_claimed(ctl, raw, runtime, claimed) })
  }
}

// Claim on the runner before any disposable carrier starts. The instrumented
// store folds the same intervention identity into its queue transaction, so a
// carrier that loses its reply can be retried without admitting the payload
// twice. The in-memory claim says the schedule owes a turn; the durable fact
// says whether that turn already entered the queue.
fn claim_interventions(
  ctl: Control,
  due: List(script.Intervention),
) -> List(script.Intervention) {
  list.filter(due, fn(intervention) {
    let path = intervention_path(intervention)
    case
      control.claim_intervention(
        ctl,
        "intervention:" <> script.intervention_key(intervention),
        path,
      )
    {
      False -> False
      True -> {
        control.mark(ctl, path)
        True
      }
    }
  })
}

fn admit_claimed(
  ctl: Control,
  raw: Session,
  runtime: api.Runtime,
  claimed: List(script.Intervention),
) -> Nil {
  let action = fn() {
    // An abort is an asynchronous cast, while steer and follow-up wait for
    // their queue transactions. Sending an abort first made the BEAM scheduler
    // decide whether another intervention from the same logical moment saw an
    // active run. Queueing first gives the fault-free oracle one stable
    // baseline without weakening the abort race exercised after this boundary.
    let #(admissions, aborts) =
      list.partition(claimed, fn(intervention) {
        case intervention {
          script.Abort(..) -> False
          script.Steer(..) | script.FollowUp(..) -> True
        }
      })
    list.append(admissions, aborts)
    |> list.map(fn(intervention) {
      #(intervention, perform(runtime, intervention))
    })
  }
  case control.attempt(ctl, at: "intervene", action:, within_ms: 2000) {
    control.Answered(outcomes) -> settle_answered(ctl, raw, outcomes)
    control.Raised | control.Expired -> {
      let unresolved = settle_durable(ctl, raw, claimed)
      case unresolved, process.is_alive(runtime.tree.supervisor) {
        [], _ -> Nil
        [_, ..], True -> {
          // A reply-losing crash can be followed by a full rest-for-one tree
          // rebuild. The root supervisor is the readiness boundary: while it
          // lives, its permanent writer must either return or make the root
          // fail. Retry until one of those process facts occurs rather than
          // spending a wall-clock budget whose result depends on runner load.
          process.sleep(intervention_retry_delay_ms)
          admit_claimed(ctl, raw, runtime, unresolved)
        }
        [_, ..], False -> control.mark(ctl, "admission-unobserved")
      }
    }
  }
}

fn settle_answered(
  ctl: Control,
  raw: Session,
  outcomes: List(#(script.Intervention, Result(Nil, String))),
) -> Nil {
  list.each(outcomes, fn(outcome) {
    let #(intervention, result) = outcome
    control.intervened(ctl, intervention_path(intervention))
    case intervention_admitted(raw, intervention) {
      True -> Nil
      False -> record_landing(ctl, intervention, result)
    }
  })
}

// Close every debt whose atomic fact proves the queue transaction landed and
// return only the ambiguous admissions for another carrier to retry.
fn settle_durable(
  ctl: Control,
  raw: Session,
  claimed: List(script.Intervention),
) -> List(script.Intervention) {
  list.filter(claimed, fn(intervention) {
    case intervention_admitted(raw, intervention) {
      False -> True
      True -> {
        control.intervened(ctl, intervention_path(intervention))
        False
      }
    }
  })
}

fn intervention_admitted(
  raw: Session,
  intervention: script.Intervention,
) -> Bool {
  let key =
    intervention
    |> script.intervention_key
    |> script.intervention_fact_key
  case storage.get_register(raw.store, register.FactCustom, key) {
    Ok(Some(_cell)) -> True
    Ok(None) | Error(_) -> False
  }
}

fn perform(
  runtime: api.Runtime,
  intervention: script.Intervention,
) -> Result(Nil, String) {
  case intervention {
    script.Steer(text:, ..) ->
      landed(
        "steer",
        api.steer_quietly(runtime, intervention_user(intervention, text)),
      )
    script.FollowUp(text:, ..) ->
      landed(
        "follow-up",
        api.follow_up(runtime, intervention_user(intervention, text)),
      )

    // Abort is fire-and-forget by design (api §4.6): it returns nothing
    // to honor, and the runner already treats an aborted run's
    // transcript as a race rather than a convergence claim.
    script.Abort(..) -> {
      api.abort(runtime)
      Ok(Nil)
    }
  }
}

/// Builds the user message for one simulated steer or follow-up.
///
/// Its opaque signature is the intervention's deterministic identity. The
/// instrumented store recognizes that identity and commits its admission
/// marker atomically with the pending queue entry.
///
/// ## Examples
///
/// ```gleam
/// // surface.intervention_user(intervention, "please redirect")
/// ```
///
pub fn intervention_user(
  intervention: script.Intervention,
  text: String,
) -> AgentMessage {
  UserMessage(
    content: [
      UserText(
        text:,
        text_signature: Some(script.intervention_key(intervention)),
      ),
    ],
    timestamp: 0,
  )
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

//// The hook registry: the one seam production wiring, tests, and the
//// simulation runner all build their `effects.Hooks` through.
////
//// A registry starts from safe defaults — no injected messages, requests
//// admitted with effectively unlimited windows, thresholds never
//// crossed, structural decisions declined, identities resolved — and
//// each slot is replaced with a pipeable setter, so a caller states only
//// what it changes. `build` produces the `effects.Hooks` record the
//// strand driver consumes.
////
//// Two hook constructors cover the config-driven cases the defaults
//// leave inert: `admission` fixes the resolved api and request limits,
//// and `threshold` derives the threshold-compaction signal from the
//// strand's *durable* projection — hooks must decide from durable state
//// so a decision taken before a crash is taken again after it (the same
//// rule the simulation hooks follow).

import core/ids.{type OpId}
import core/message.{type AgentMessage}
import gleam/list
import gleam/option.{type Option, None}
import machine/operation.{
  type CompactionSettings, CompactionPreparation, FileOperations,
}
import machine/planner.{
  type ModelResolution, type PreparationOutcome, type RequestAdmission,
  type StructuralVerdict, type SummaryProgress, type ThresholdStatus, Admitted,
  EmptyPreparation, Prepared, ThresholdExceeded, ThresholdNotExceeded,
}
import machine/strand.{type StrandConfiguration}
import runtime/effects.{type AdmissionQuery, type Hooks, type ThresholdQuery}

/// A hook registry under construction. Fields mirror `effects.Hooks`
/// slot for slot; setters replace one slot each.
pub type Registry {
  Registry(hooks: Hooks)
}

/// A registry holding the default hooks.
///
/// ## Examples
///
/// ```gleam
/// // hooks.new() |> hooks.with_threshold(signal) |> hooks.build
/// ```
///
pub fn new() -> Registry {
  Registry(hooks: effects.default_hooks())
}

/// The finished hooks record.
///
/// ## Examples
///
/// ```gleam
/// // hooks.build(registry)
/// ```
///
pub fn build(registry: Registry) -> Hooks {
  registry.hooks
}

/// Replaces the `before_run` slot: messages injected at run start.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_run_start(registry, fn(_op) { [rules_message] })
/// ```
///
pub fn with_run_start(
  registry: Registry,
  run_start: fn(OpId) -> List(AgentMessage),
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, run_start:))
}

/// Replaces the pre-request admission slot.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_admission(registry, hooks.admission(api: "anthropic",
/// //   intended_output_limit: 8192, context_window: 200_000))
/// ```
///
pub fn with_admission(
  registry: Registry,
  admission: fn(AdmissionQuery) -> RequestAdmission,
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, admission:))
}

/// Replaces the `before_run_end` slot: an optional born-placed follow-up.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_run_end(registry, fn(_op) { None })
/// ```
///
pub fn with_run_end(
  registry: Registry,
  run_end: fn(OpId) -> Option(AgentMessage),
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, run_end:))
}

/// Replaces the threshold-compaction slot.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_threshold(registry, hooks.threshold(...))
/// ```
///
pub fn with_threshold(
  registry: Registry,
  threshold: fn(ThresholdQuery) -> ThresholdStatus,
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, threshold:))
}

/// Replaces the overflow-preparation slot.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_overflow_preparation(registry, prepare)
/// ```
///
pub fn with_overflow_preparation(
  registry: Registry,
  overflow_preparation: fn(OpId) -> PreparationOutcome,
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, overflow_preparation:))
}

/// Replaces the structural-decision slot.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_structural_decision(registry, decide)
/// ```
///
pub fn with_structural_decision(
  registry: Registry,
  structural_decision: fn(OpId, String) -> StructuralVerdict,
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, structural_decision:))
}

/// Replaces the summary-progress slot.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_summary_progress(registry, progress)
/// ```
///
pub fn with_summary_progress(
  registry: Registry,
  summary_progress: fn(OpId, String, Int) -> SummaryProgress,
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, summary_progress:))
}

/// Replaces the identity-resolution slot.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_resolution(registry, resolve)
/// ```
///
pub fn with_resolution(
  registry: Registry,
  resolution: fn(StrandConfiguration) -> ModelResolution,
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, resolution:))
}

/// An admission hook with fixed limits and the resolved adapter api the
/// request will be made against. The api is captured durably into the
/// generation intent so deferred-handle validity compares against the
/// request identity (ORCH-L4).
///
/// ## Examples
///
/// ```gleam
/// // hooks.admission(api: "anthropic-messages",
/// //   intended_output_limit: 8192, context_window: 200_000)
/// ```
///
pub fn admission(
  api api: String,
  intended_output_limit intended_output_limit: Int,
  context_window context_window: Int,
) -> fn(AdmissionQuery) -> RequestAdmission {
  fn(query: AdmissionQuery) {
    Admitted(
      stream_options: query.stream_options,
      intended_output_limit:,
      context_window:,
      api:,
    )
  }
}

/// A threshold-compaction hook driven by run settings and the durable
/// projection: the signal fires once the estimated projected size
/// reaches `trigger_tokens`, and the preparation keeps the newest
/// messages within `settings.keep_recent_tokens` as the retained tail
/// while everything older is summarized. Deciding from the durable
/// projection (not process state) makes the decision crash-stable.
///
/// `projection` reads the named strand's current projected context;
/// `estimate` prices one message in tokens.
///
/// ## Examples
///
/// ```gleam
/// // hooks.threshold(settings, trigger_tokens: 100_000,
/// //   projection: read_projection, estimate: estimate_tokens)
/// ```
///
pub fn threshold(
  settings: CompactionSettings,
  trigger_tokens trigger_tokens: Int,
  projection projection: fn(String) -> List(AgentMessage),
  estimate estimate: fn(AgentMessage) -> Int,
) -> fn(ThresholdQuery) -> ThresholdStatus {
  fn(query: ThresholdQuery) {
    case settings.enabled {
      False -> ThresholdNotExceeded
      True -> {
        let messages = projection(query.strand)
        let total = list.fold(messages, 0, fn(sum, m) { sum + estimate(m) })
        case total >= trigger_tokens && total > 0 {
          False -> ThresholdNotExceeded
          True ->
            ThresholdExceeded(outcome: prepare(
              messages,
              total,
              settings,
              estimate,
            ))
        }
      }
    }
  }
}

// Splits the projection into a summarized prefix and a retained-tail
// suffix within the keep-recent budget.
fn prepare(
  messages: List(AgentMessage),
  total: Int,
  settings: CompactionSettings,
  estimate: fn(AgentMessage) -> Int,
) -> PreparationOutcome {
  let #(tail_reversed, _spent) =
    messages
    |> list.reverse
    |> list.fold(#([], 0), fn(acc, message) {
      let #(kept, spent) = acc
      let cost = estimate(message)
      case spent + cost <= settings.keep_recent_tokens {
        True -> #([message, ..kept], spent + cost)
        False -> #(kept, settings.keep_recent_tokens + 1)
      }
    })
  let retained_tail = tail_reversed
  let keep = list.length(retained_tail)
  let to_summarize = list.take(messages, list.length(messages) - keep)
  case to_summarize {
    [] -> EmptyPreparation
    _ ->
      Prepared(preparation: CompactionPreparation(
        messages_to_summarize: to_summarize,
        turn_prefix_messages: [],
        retained_tail:,
        is_split_turn: False,
        tokens_before: total,
        previous_summary: None,
        file_ops: FileOperations(read: [], written: [], edited: []),
        settings:,
      ))
  }
}

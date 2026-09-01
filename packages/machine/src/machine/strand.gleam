//// Strand-scoped register payload types.
////
//// A configured strand is three registers — `strand.leaf`, `strand.config`,
//// `strand.state` — plus `strand.last_result` once its first operation has
//// ended. `core` stores these as tagged JSON payloads; this module owns the
//// configuration and state types (transcribed from pi's harness spec §2.3
//// and §3.3, with pi's "lane" renamed to "strand" throughout), and
//// `machine/codec` owns the total codecs between them and the stored
//// payloads. The terminal-result payload lives in `machine/operation`,
//// next to the machinery that computes it.

import core/ids.{type EntryId, type OpId}
import gleam/option.{type Option}

/// The resolved provider/model identity a strand is configured to use.
///
/// Constructor invariants: both fields are non-empty durable strings; they
/// are stored identities, resolved against the live provider registry only
/// at effect-admission boundaries, never at read time.
pub type ModelIdentity {
  ModelIdentity(provider: String, model_id: String)
}

/// How much reasoning effort the strand requests from its model. Mirrors
/// pi's `ThinkingLevel` union verbatim; wire forms are the lowercase names
/// (`"off"`, `"minimal"`, `"low"`, `"medium"`, `"high"`, `"xhigh"`,
/// `"max"`).
pub type ThinkingLevel {
  /// No visible reasoning requested.
  ThinkingOff

  /// Minimal reasoning effort.
  ThinkingMinimal

  /// Low reasoning effort.
  ThinkingLow

  /// Medium reasoning effort.
  ThinkingMedium

  /// High reasoning effort.
  ThinkingHigh

  /// Extra-high reasoning effort.
  ThinkingXHigh

  /// Maximum reasoning effort.
  ThinkingMax
}

/// Total strand configuration — the `strand.config` register payload.
///
/// Constructor invariants: the value is always total; a setter replaces the
/// whole value and is never a patch (pi §2.3). `active_tool_names` lists
/// the tools the strand's next generation step may request, in registry
/// order.
pub type StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity,
    thinking_level: ThinkingLevel,
    active_tool_names: List(String),
  )
}

/// The `strand.state` register payload: operation ownership plus the
/// strand-owned next-run queue.
///
/// Constructor invariants: `current_operation` names the strand's single
/// open operation, or `None` when idle — at most one operation is ever open
/// per strand (pi invariant 17). `pending_next_run` holds reserved entry
/// ids in acceptance order; each id's payload lives at `pending.entry/{id}`
/// until a run acceptance consumes it or a queue cancellation deletes it.
/// These ids are strand-owned: terminal transactions preserve them.
pub type StrandState {
  StrandState(current_operation: Option(OpId), pending_next_run: List(EntryId))
}

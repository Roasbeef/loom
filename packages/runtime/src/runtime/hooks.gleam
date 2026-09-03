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
//// Constructors cover the config-driven cases the defaults leave inert:
//// `admission` fixes the resolved api and request limits, and
//// `threshold` / `overflow` derive the two compaction signals from the
//// strand's *durable* projection. Hooks must decide from durable state
//// so a decision taken before a crash is taken again after it (the same
//// rule the simulation hooks follow).
////
//// ## Counting a context the way the provider does
////
//// The threshold is pi's inequality — compact once the context passes
//// `context_window - reserve_tokens` — over pi's accounting, which is
//// not an estimate when it does not have to be. `context_tokens` takes
//// the newest settled assistant message's *provider-reported* usage and
//// adds a characters-over-four estimate only for what came after it. An
//// estimate-only fold drifts against the provider on exactly the axis
//// that matters — cache reads, thinking tokens, the provider's own
//// serialization overhead — and it drifts low, which is the dangerous
//// direction: a run that believes it has room overflows instead of
//// compacting.
////
//// The fold needs one guard. A `CompactionEntry` carries a **copy** of
//// its retained tail, so the assistant messages at the head of a
//// post-compaction projection report the usage of requests made
//// *before* that compaction — numbers describing a context that no
//// longer exists, and always far larger than the one that replaced it.
//// Reading one would re-fire the threshold on the very next turn,
//// forever. `Projected.carried` names how many leading messages came
//// from that entry and the fold starts after them, which is pi's
//// "reject usage older than the latest compaction" in the shape Loom's
//// projection makes available.
////
//// ## Where a compaction may cut
////
//// `preparation` walks the projection newest-first until
//// `keep_recent_tokens` is spent, then moves the boundary **later**
//// until it lands on a user, assistant, or custom message. A tool
//// result is never a cut point (pi): severed from the assistant turn
//// that called it, it would open the retained tail as an answer to a
//// question the model can no longer see. Moving later — rather than
//// earlier — keeps a call and its results together on the *summarized*
//// side, so no orphan is created in either direction. A consequence
//// worth naming: the cut always lands on a turn boundary, so this
//// builder never produces pi's split-turn case, and
//// `CompactionPreparation.is_split_turn` is correspondingly always
//// `False` here.

import core/entry.{type UsageRow}
import core/ids.{type OpId}
import core/json
import core/message.{type AgentMessage}
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/operation.{
  type CompactionSettings, CompactionPreparation, FileOperations,
}
import machine/planner.{
  type ModelResolution, type PreparationOutcome, type RequestAdmission,
  type StructuralVerdict, type SummaryProgress, type ThresholdStatus, Admitted,
  EmptyPreparation, Prepared, ThresholdExceeded, ThresholdNotExceeded,
}
import machine/strand.{type StrandConfiguration}
import runtime/effects.{
  type AdmissionQuery, type CompactionCue, type Hooks, type OverflowQuery,
  type ThresholdQuery,
}
import session/session.{type Session}
import storage/storage

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
  overflow_preparation: fn(OverflowQuery) -> PreparationOutcome,
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

/// Replaces the `context` slot: the transform applied to a generation
/// attempt's projected context before the request goes out.
///
/// The slot exists for the extension hook bus
/// (`client/extension/hooks`), which folds every installed extension's
/// `context` hook over the list in load order. Nothing in the harness
/// itself installs one, and the default is identity, so a host that
/// never sets this dispatches the projection it read.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_context(registry, fn(_op, messages) { messages })
/// ```
///
pub fn with_context(
  registry: Registry,
  context: fn(OpId, List(AgentMessage)) -> List(AgentMessage),
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, context:))
}

/// Replaces the `before_compact` slot: attributed blocks appended to
/// the summarizer's input for one dispatched compaction.
///
/// Like `with_context`, this exists for the extension hook bus and
/// nothing in the harness itself installs one. The default answers with
/// no notes, so a host that never sets this summarizes exactly the
/// preparation it froze.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_compaction_note(registry, fn(_op, _cue) { [] })
/// ```
///
pub fn with_compaction_note(
  registry: Registry,
  compaction_note: fn(OpId, CompactionCue) -> List(String),
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, compaction_note:))
}

/// Replaces the `usage` slot: one committed cost-ledger row, announced
/// after the transaction that wrote it returned.
///
/// The default does nothing. A host that sets this is asking to be told
/// what a session cost as it is spent, which is what a tracing
/// extension subscribes for; nothing in the harness reads the answer,
/// because there is no answer.
///
/// ## Examples
///
/// ```gleam
/// // hooks.with_usage(registry, fn(_op, _row) { Nil })
/// ```
///
pub fn with_usage(
  registry: Registry,
  usage: fn(OpId, UsageRow) -> Nil,
) -> Registry {
  Registry(hooks: effects.Hooks(..registry.hooks, usage:))
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

// --- what a compaction decides from ----------------------------------------

/// A strand's durable projection, plus the two facts a compaction
/// decision needs that a bare message list cannot carry.
///
/// Constructor invariants: `messages` is the strand's projected context,
/// oldest first, exactly as `session.project_context` returns it;
/// `carried` counts the leading messages contributed by a
/// `CompactionEntry` at the head of the branch scan — its summary,
/// projected as one user message, plus every message of its retained
/// tail — and is `0` when no compaction heads the branch;
/// `previous_summary` is that entry's summary text, when there was one.
pub type Projected {
  Projected(
    messages: List(AgentMessage),
    carried: Int,
    previous_summary: Option(String),
  )
}

/// A projection with no compaction on its branch: nothing carried,
/// nothing summarized before.
///
/// ## Examples
///
/// ```gleam
/// // hooks.uncompacted([message]).carried == 0
/// ```
///
pub fn uncompacted(messages: List(AgentMessage)) -> Projected {
  Projected(messages:, carried: 0, previous_summary: None)
}

/// Reads one strand's durable projection from the session store, with
/// the two compaction facts alongside it.
///
/// The read goes straight to the store rather than through the writer,
/// which is what makes it callable from a hook: both storage backends
/// are actor-backed, so the access is serialized with every other one,
/// and *durable* is the point — a threshold decision taken before a
/// crash must be taken again after it.
///
/// The cost is real and worth naming. `PlannerInputs.threshold` is a
/// value, not a thunk, so the driver computes it on **every** pass over
/// an open operation — a branch scan and a projection per poll tick,
/// per doorbell, per settled effect. Two things bound it: an idle
/// strand never reaches `build_inputs` at all, and `threshold` checks
/// `settings.enabled` before it ever calls a projection, so a host with
/// compaction off pays nothing. The scan itself stops at the newest
/// compaction on the path, so the window it grows in is exactly the one
/// compaction closes. If this ever shows up in a profile, the fix is a
/// memo keyed on the strand leaf's register seq — the branch is a
/// function of the leaf, and entries are write-once — rather than a
/// laxer read.
///
/// A strand with no leaf, or a read that fails, projects as empty. That
/// reads downstream as "nothing to compact", which is the safe
/// direction: a strand must not be halted because a token count could
/// not be taken.
///
/// ## Examples
///
/// ```gleam
/// // hooks.project(session, "main").carried
/// ```
///
pub fn project(session: Session, strand: String) -> Projected {
  case session.strand_leaf(session, strand) {
    Ok(Some(session.Cell(value: Some(leaf), ..))) ->
      project_from_leaf(session, leaf)

    // A strand with no leaf, or a read that fails, projects as empty —
    // see the doc comment above for why that is the safe direction.
    _ -> uncompacted([])
  }
}

fn project_from_leaf(session: Session, leaf: ids.EntryId) -> Projected {
  let scan =
    storage.branch_scan(from: leaf)
    |> storage.branch_stop_at_kind(storage.Compaction)
  case storage.scan_branch(session.store, scan) {
    Error(_unreadable) -> uncompacted([])
    Ok(newest_first) -> project_from_scan(newest_first)
  }
}

fn project_from_scan(newest_first: List(entry.Entry)) -> Projected {
  let messages = session.project_scan(newest_first)

  // The scan stops *inclusively* at the first compaction, so a
  // compaction — when there is one — is the oldest entry it returned,
  // and the projection opens with that entry's summary followed by its
  // retained tail.
  case list.last(newest_first) {
    Ok(entry.CompactionEntry(summary:, retained_tail:, ..)) ->
      Projected(
        messages:,
        carried: 1 + list.length(retained_tail),
        previous_summary: Some(summary),
      )
    _ -> uncompacted(messages)
  }
}

/// What one message costs, estimated as characters over four — the
/// standard rough conversion, and the only accounting available for a
/// message no provider has priced yet.
///
/// Everything that reaches the wire counts: text, thinking, serialized
/// tool-call arguments, tool-result text. An image counts as a flat
/// `image_characters`, because its base64 payload is an order of
/// magnitude larger than what a provider bills for it.
///
/// ## Examples
///
/// ```gleam
/// // hooks.estimate_message(four_hundred_characters_of_user_text) == 100
/// ```
///
pub fn estimate_message(message: AgentMessage) -> Int {
  let characters = case message {
    message.UserMessage(content:, ..) -> sum(content, user_block_characters)
    message.AssistantMessage(content:, ..) ->
      sum(content, assistant_block_characters)
    message.ToolResultMessage(content:, tool_name:, ..) ->
      string.length(tool_name) + sum(content, tool_result_block_characters)
    message.CustomMessage(schema:, payload:) ->
      string.length(schema) + string.length(json.to_string(payload))
  }
  characters / 4
}

fn user_block_characters(block: message.UserBlock) -> Int {
  case block {
    message.UserText(text:, ..) -> string.length(text)
    message.UserImage(..) -> image_characters
  }
}

fn assistant_block_characters(block: message.AssistantBlock) -> Int {
  case block {
    message.AssistantText(text:, ..) -> string.length(text)
    message.AssistantThinking(thinking:, ..) -> string.length(thinking)
    message.AssistantToolCall(call:) ->
      string.length(call.name) + string.length(json.to_string(call.arguments))
  }
}

fn tool_result_block_characters(block: message.ToolResultBlock) -> Int {
  case block {
    message.ToolResultText(text:, ..) -> string.length(text)
    message.ToolResultImage(..) -> image_characters
  }
}

/// The flat character-equivalent an image block is priced at, chosen so
/// `estimate_message` lands near a provider's per-image charge rather
/// than at the size of the base64 payload.
pub const image_characters = 6000

/// What a projected context currently costs the provider: the newest
/// durable provider-reported usage on the branch, plus an estimate for
/// everything committed after it (pi's `estimateContextTokens`).
///
/// `Projected.carried` is the stale-usage guard — see the module doc.
/// With no usable durable usage (a fresh strand, or one whose only
/// assistant messages were carried over by a compaction) the whole
/// projection is estimated instead. That is the conservative direction:
/// an estimate of the small post-compaction context, never the
/// provider's memory of the large pre-compaction one.
///
/// ## Examples
///
/// ```gleam
/// // hooks.context_tokens(projected, hooks.estimate_message)
/// ```
///
pub fn context_tokens(
  projected: Projected,
  estimate: fn(AgentMessage) -> Int,
) -> Int {
  let fresh = list.drop(projected.messages, projected.carried)
  case newest_reported(fresh, 0, None) {
    None -> sum(projected.messages, estimate)
    Some(#(index, reported)) ->
      reported + sum(list.drop(fresh, index + 1), estimate)
  }
}

// The index and reported total of the newest assistant message carrying
// a non-zero usage. Synthetic settlements (aborts, transport failures)
// report zero and are skipped — they never described a real request, and
// an error response is dropped from the projection anyway.
fn newest_reported(
  messages: List(AgentMessage),
  index: Int,
  found: Option(#(Int, Int)),
) -> Option(#(Int, Int)) {
  case messages {
    [] -> found
    [message.AssistantMessage(usage:, ..), ..rest] ->
      case usage.total_tokens > 0 {
        True ->
          newest_reported(rest, index + 1, Some(#(index, usage.total_tokens)))
        False -> newest_reported(rest, index + 1, found)
      }
    [_, ..rest] -> newest_reported(rest, index + 1, found)
  }
}

/// The compaction preparation for a projection: the newest messages
/// within `settings.keep_recent_tokens` become the retained tail, cut at
/// a turn boundary, and everything older is what the summarizer is sent.
/// `EmptyPreparation` when there would be nothing to summarize, which
/// the machine reads as "mark the boundary checked and carry on".
///
/// The one preparation builder in the harness: the threshold hook, the
/// overflow hook, and a manual `Compact` command all go through it, so
/// all three compact the same way and a change to the cut rule cannot
/// apply to only some of them.
///
/// A previous compaction's summary is *not* re-summarized: it travels as
/// `previous_summary`, which selects the summary pack's iterative-update
/// prompt. Its retained tail is, though — those messages survived one
/// compaction and would otherwise be dropped silently by the next.
///
/// ## Examples
///
/// ```gleam
/// // hooks.preparation(projected, settings, hooks.estimate_message, 150_000)
/// ```
///
pub fn preparation(
  projected: Projected,
  settings: CompactionSettings,
  estimate: fn(AgentMessage) -> Int,
  tokens_before tokens_before: Int,
) -> PreparationOutcome {
  // The carried summary heads the projection as one user message. It is
  // input to the *update* prompt, not part of the transcript being
  // summarized, so it is dropped from the body here.
  let body = case projected.previous_summary {
    Some(_) -> list.drop(projected.messages, 1)
    None -> projected.messages
  }
  let tail = cut(recent(body, settings.keep_recent_tokens, estimate))
  let to_summarize = list.take(body, list.length(body) - list.length(tail))
  case to_summarize {
    [] -> EmptyPreparation
    _ ->
      Prepared(preparation: CompactionPreparation(
        messages_to_summarize: to_summarize,
        turn_prefix_messages: [],
        retained_tail: tail,
        // The cut always lands on a turn boundary, so this builder never
        // splits a turn. See the module doc.
        is_split_turn: False,
        tokens_before:,
        previous_summary: projected.previous_summary,
        // Cumulative file-operation tracking is Stage C1; the summary
        // pack already renders the block when the lists are non-empty.
        file_ops: FileOperations(read: [], written: [], edited: []),
        settings:,
      ))
  }
}

// The newest messages fitting the keep-recent budget, oldest first. The
// walk stops at the first message that does not fit rather than skipping
// it: a retained tail must be a contiguous suffix of the projection.
fn recent(
  messages: List(AgentMessage),
  budget: Int,
  estimate: fn(AgentMessage) -> Int,
) -> List(AgentMessage) {
  recent_loop(list.reverse(messages), budget, estimate, [])
}

fn recent_loop(
  newest_first: List(AgentMessage),
  remaining: Int,
  estimate: fn(AgentMessage) -> Int,
  kept: List(AgentMessage),
) -> List(AgentMessage) {
  case newest_first {
    [] -> kept
    [message, ..rest] -> {
      let cost = estimate(message)
      case cost <= remaining {
        True -> recent_loop(rest, remaining - cost, estimate, [message, ..kept])
        False -> kept
      }
    }
  }
}

// Moves a candidate tail's start later until it is a valid cut point: a
// tool result at the head of a retained tail is an answer to a call the
// model can no longer see, so it belongs on the summarized side with the
// assistant turn that made it.
fn cut(tail: List(AgentMessage)) -> List(AgentMessage) {
  case tail {
    [message.ToolResultMessage(..), ..rest] -> cut(rest)
    kept -> kept
  }
}

/// A threshold-compaction hook: pi's inequality over pi's accounting.
/// The signal fires once `context_tokens` passes
/// `context_window - settings.reserve_tokens`, and the preparation is
/// `preparation`'s. Deciding from the durable projection (not process
/// state) makes the decision crash-stable.
///
/// `projection` reads the named strand's current durable projection;
/// `estimate` prices one not-yet-reported message.
///
/// ## Examples
///
/// ```gleam
/// // hooks.threshold(settings, context_window: 200_000,
/// //   projection: read_projection, estimate: hooks.estimate_message)
/// ```
///
pub fn threshold(
  settings: CompactionSettings,
  context_window context_window: Int,
  projection projection: fn(String) -> Projected,
  estimate estimate: fn(AgentMessage) -> Int,
) -> fn(ThresholdQuery) -> ThresholdStatus {
  fn(query: ThresholdQuery) {
    use <- bool.guard(when: !settings.enabled, return: ThresholdNotExceeded)
    let projected = projection(query.strand)
    let total = context_tokens(projected, estimate)
    let exceeded = total > 0 && total > context_window - settings.reserve_tokens
    use <- bool.guard(when: !exceeded, return: ThresholdNotExceeded)
    ThresholdExceeded(outcome: preparation(
      projected,
      settings,
      estimate,
      tokens_before: total,
    ))
  }
}

/// The overflow-recovery preparation hook: the same builder the
/// threshold uses, asked unconditionally.
///
/// A provider that reports overflow has already decided the context does
/// not fit, so there is no inequality left to evaluate — the only
/// question is whether there is anything to compact. Sharing the builder
/// is what makes the machine's one-shot overflow recovery
/// (`enter_overflow_compaction`) do the same thing a threshold
/// compaction does, rather than the run draining as `context_overflow`.
///
/// ## Examples
///
/// ```gleam
/// // hooks.overflow(settings, projection: read_projection,
/// //   estimate: hooks.estimate_message)
/// ```
///
pub fn overflow(
  settings: CompactionSettings,
  projection projection: fn(String) -> Projected,
  estimate estimate: fn(AgentMessage) -> Int,
) -> fn(OverflowQuery) -> PreparationOutcome {
  fn(query: OverflowQuery) {
    let projected = projection(query.strand)
    preparation(
      projected,
      settings,
      estimate,
      tokens_before: context_tokens(projected, estimate),
    )
  }
}

fn sum(items: List(a), cost: fn(a) -> Int) -> Int {
  list.fold(items, 0, fn(total, item) { total + cost(item) })
}

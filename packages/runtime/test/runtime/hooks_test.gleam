//// The hook registry: slot replacement, the usage-aware context fold,
//// the cut-point rule, and the two compaction signals built over them.
////
//// The arithmetic here is the difference between compaction firing and
//// a run draining as `context_overflow`, and two of its rules are
//// invisible in the happy path: the stale-usage guard (a compaction's
//// retained-tail copy reports the size of the context it *replaced*)
//// and the cut-point rule (a retained tail may not open on a tool
//// result). Both are pinned directly rather than through a whole
//// session.

import core/clock as core_clock
import core/ids as core_ids
import core/json as core_json
import core/message as core_message
import gleam/option.{None, Some}
import gleam/string
import machine/operation.{
  type CompactionSettings, CompactionPreparation, CompactionSettings,
}
import machine/planner.{
  Admitted, EmptyPreparation, Prepared, ThresholdExceeded, ThresholdNotExceeded,
}
import machine/strand as machine_strand
import runtime/effects.{AdmissionQuery, OverflowQuery, ThresholdQuery}
import runtime/hooks
import support/fake

fn query() -> effects.ThresholdQuery {
  ThresholdQuery(operation: an_op(), strand: "main")
}

fn an_op() -> core_ids.OpId {
  let #(op, _generator) =
    core_ids.mint_op(core_ids.generator(core_clock.fixed(at: 1), seed: 3))
  op
}

fn settings(keep: Int, reserve: Int) -> CompactionSettings {
  CompactionSettings(
    enabled: True,
    reserve_tokens: reserve,
    keep_recent_tokens: keep,
  )
}

// One token apiece, so a message count reads as a token count.
fn one(_message: core_message.AgentMessage) -> Int {
  1
}

pub fn admission_hook_carries_the_api_test() {
  let admit =
    hooks.admission(
      api: "acme-api",
      intended_output_limit: 4096,
      context_window: 100_000,
    )
  let assert Admitted(api: "acme-api", intended_output_limit: 4096, ..) =
    admit(AdmissionQuery(
      operation: an_op(),
      step_id: "s1",
      attempt: 1,
      configuration: support_configuration(),
      stream_options: core_json.Object([]),
    ))
}

// --- the context fold ------------------------------------------------------

pub fn an_estimate_is_characters_over_four_test() {
  assert hooks.estimate_message(fake.user("abcdefgh")) == 2
}

// With no provider number to lean on, everything is estimated.
pub fn a_fresh_strand_is_estimated_end_to_end_test() {
  let projected = hooks.uncompacted([fake.user("a"), fake.user("b")])
  assert hooks.context_tokens(projected, one) == 2
}

// pi's fold: the newest reported total, plus an estimate for what came
// after it. The reported number already prices everything before.
pub fn the_newest_reported_usage_replaces_everything_before_it_test() {
  let projected =
    hooks.uncompacted([
      fake.user("a"),
      fake.answer("first", 900),
      fake.user("b"),
      fake.answer("second", 5000),
      fake.user("c"),
    ])
  // 5000 reported, plus the one message committed after it.
  assert hooks.context_tokens(projected, one) == 5001
}

// The guard. The first three messages are a compaction's summary and its
// retained-tail copy; the assistant among them reports the size of the
// context the compaction *replaced*. Reading it would re-fire the
// threshold on every turn for the rest of the session.
pub fn carried_usage_is_never_read_test() {
  let projected =
    hooks.Projected(
      messages: [
        fake.user("[summary] …"),
        fake.user("b"),
        fake.answer("pre-compaction turn", 190_000),
        fake.user("c"),
      ],
      carried: 3,
      previous_summary: Some("[summary] …"),
    )
  // Nothing after the carried region reports usage, so the whole
  // projection is estimated: four messages at one apiece.
  assert hooks.context_tokens(projected, one) == 4
}

pub fn a_post_compaction_report_is_read_test() {
  let projected =
    hooks.Projected(
      messages: [
        fake.user("[summary] …"),
        fake.user("b"),
        fake.answer("pre-compaction turn", 190_000),
        fake.user("c"),
        fake.answer("post-compaction turn", 12_000),
      ],
      carried: 3,
      previous_summary: Some("[summary] …"),
    )
  assert hooks.context_tokens(projected, one) == 12_000
}

// A synthetic settlement (an abort, a transport failure) reports zero
// and describes no request; the fold must walk past it to the last real
// number rather than treating the context as empty.
pub fn a_zero_usage_settlement_is_skipped_test() {
  let projected =
    hooks.uncompacted([fake.answer("real", 7000), fake.answer("synthetic", 0)])
  assert hooks.context_tokens(projected, one) == 7001
}

// --- the preparation builder ----------------------------------------------

pub fn the_tail_is_the_newest_messages_within_the_budget_test() {
  let projected =
    hooks.uncompacted([
      fake.user("m1"),
      fake.user("m2"),
      fake.user("m3"),
      fake.user("m4"),
      fake.user("m5"),
    ])
  let assert Prepared(preparation: CompactionPreparation(
    messages_to_summarize:,
    retained_tail:,
    tokens_before: 5,
    is_split_turn: False,
    previous_summary: None,
    ..,
  )) = hooks.preparation(projected, settings(3, 0), one, tokens_before: 5)
  assert messages_to_summarize == [fake.user("m1"), fake.user("m2")]
  assert retained_tail == [fake.user("m3"), fake.user("m4"), fake.user("m5")]
}

// The cut moves *later* off a tool result, never earlier: a retained
// tail that opened on a result would be an answer to a call the model
// can no longer see. Here the budget of three would keep the result, so
// the boundary slides past it and the tail is the two messages after.
pub fn a_tail_never_opens_on_a_tool_result_test() {
  let projected =
    hooks.uncompacted([
      fake.user("m1"),
      fake.tool_use("calling", [#("c1", "bash")], 0),
      tool_result("c1", "bash"),
      fake.user("m4"),
      fake.answer("done", 0),
    ])
  let assert Prepared(preparation: CompactionPreparation(
    messages_to_summarize:,
    retained_tail:,
    ..,
  )) = hooks.preparation(projected, settings(3, 0), one, tokens_before: 5)
  assert retained_tail == [fake.user("m4"), fake.answer("done", 0)]
  // The call and its result stay together on the summarized side.
  assert messages_to_summarize
    == [
      fake.user("m1"),
      fake.tool_use("calling", [#("c1", "bash")], 0),
      tool_result("c1", "bash"),
    ]
}

// A previous summary is input to the update prompt, not transcript: it
// must not be handed back to the summarizer as something to summarize.
// Its retained tail is, though — those messages survived one compaction
// and the next one would otherwise drop them silently.
pub fn a_carried_summary_is_not_re_summarized_test() {
  let projected =
    hooks.Projected(
      messages: [
        fake.user("[summary] earlier work"),
        fake.user("carried-1"),
        fake.user("fresh-1"),
        fake.user("fresh-2"),
      ],
      carried: 2,
      previous_summary: Some("[summary] earlier work"),
    )
  let assert Prepared(preparation: CompactionPreparation(
    messages_to_summarize:,
    retained_tail:,
    previous_summary: Some("[summary] earlier work"),
    ..,
  )) = hooks.preparation(projected, settings(2, 0), one, tokens_before: 4)
  assert messages_to_summarize == [fake.user("carried-1")]
  assert retained_tail == [fake.user("fresh-1"), fake.user("fresh-2")]
}

pub fn nothing_older_than_the_tail_is_an_empty_preparation_test() {
  let projected = hooks.uncompacted([fake.user("m1"), fake.user("m2")])
  assert hooks.preparation(projected, settings(50, 0), one, tokens_before: 2)
    == EmptyPreparation
}

// --- the two signals -------------------------------------------------------

pub fn the_threshold_is_the_window_less_the_reserve_test() {
  // Three sizeable turns, then a priced assistant response and one
  // message after it: 85_000 reported plus one estimated.
  let projection = fn(_strand) {
    hooks.uncompacted([
      bulky(),
      bulky(),
      bulky(),
      fake.answer("turn", 85_000),
      fake.user("next"),
    ])
  }
  // 85_001 against a 100_000 window: under a 10k reserve, over a 20k one.
  let quiet =
    hooks.threshold(
      settings(20_000, 10_000),
      context_window: 100_000,
      projection:,
      estimate: hooks.estimate_message,
    )
  assert quiet(query()) == ThresholdNotExceeded
  let firing =
    hooks.threshold(
      settings(20_000, 20_000),
      context_window: 100_000,
      projection:,
      estimate: hooks.estimate_message,
    )
  let assert ThresholdExceeded(outcome: Prepared(preparation: CompactionPreparation(
    messages_to_summarize:,
    retained_tail:,
    tokens_before: 85_001,
    ..,
  ))) = firing(query())
  // The keep-recent budget of 20_000 holds one bulky turn and the two
  // small messages after it; the two older bulky turns are summarized.
  assert messages_to_summarize == [bulky(), bulky()]
  assert retained_tail
    == [bulky(), fake.answer("turn", 85_000), fake.user("next")]
}

// A user turn of 10_000 estimated tokens.
fn bulky() -> core_message.AgentMessage {
  fake.user(string.repeat("x", 40_000))
}

pub fn disabled_settings_never_fire_test() {
  let signal =
    hooks.threshold(
      CompactionSettings(
        enabled: False,
        reserve_tokens: 0,
        keep_recent_tokens: 0,
      ),
      context_window: 1,
      projection: fn(_strand) { hooks.uncompacted([fake.user("m1")]) },
      estimate: fn(_message) { 1000 },
    )
  assert signal(query()) == ThresholdNotExceeded
}

pub fn an_empty_strand_never_fires_test() {
  let signal =
    hooks.threshold(
      settings(0, 0),
      context_window: 0,
      projection: fn(_strand) { hooks.uncompacted([]) },
      estimate: one,
    )
  assert signal(query()) == ThresholdNotExceeded
}

// Overflow asks no question about size — the provider already answered
// it — and shares the threshold's builder, so the two compact alike.
pub fn overflow_prepares_unconditionally_test() {
  let prepare =
    hooks.overflow(
      settings(1, 0),
      projection: fn(_strand) {
        hooks.uncompacted([fake.user("m1"), fake.user("m2")])
      },
      estimate: one,
    )
  let assert Prepared(preparation: CompactionPreparation(
    messages_to_summarize: [_],
    retained_tail: [_],
    ..,
  )) = prepare(OverflowQuery(operation: an_op(), strand: "main"))
}

pub fn overflow_on_an_empty_strand_has_nothing_to_prepare_test() {
  let prepare =
    hooks.overflow(
      settings(1, 0),
      projection: fn(_strand) { hooks.uncompacted([]) },
      estimate: one,
    )
  assert prepare(OverflowQuery(operation: an_op(), strand: "main"))
    == EmptyPreparation
}

fn tool_result(id: String, name: String) -> core_message.AgentMessage {
  core_message.ToolResultMessage(
    tool_call_id: id,
    tool_name: name,
    content: [core_message.ToolResultText(text: "ok", text_signature: None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: 0,
  )
}

fn support_configuration() -> machine_strand.StrandConfiguration {
  machine_strand.StrandConfiguration(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: machine_strand.ThinkingOff,
    active_tool_names: [],
  )
}

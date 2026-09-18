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
import core/entry
import core/ids as core_ids
import core/json as core_json
import core/message as core_message
import core/register
import core/tx.{InsertEntry, SetRegister, Tx}
import gleam/list
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
import session/session
import storage/storage
import support/fake

fn query() -> effects.ThresholdQuery {
  query_of(hooks.uncompacted([]))
}

// The driver hands the hook its projection in the query; a test does the
// same rather than lending the hook a reader.
fn query_of(projected: hooks.Projected) -> effects.ThresholdQuery {
  ThresholdQuery(
    operation: an_op(),
    strand: "main",
    messages: projected.messages,
    carried: projected.carried,
    previous_summary: projected.previous_summary,
  )
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
      origins: list.repeat(None, 4),
      reference_session: None,
      copied_from: None,
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
      origins: list.repeat(None, 5),
      reference_session: None,
      copied_from: None,
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
      fake.answer("m3", 0),
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
  assert retained_tail
    == [fake.answer("m3", 0), fake.user("m4"), fake.user("m5")]
}

// Align backward so the retained results always include their calls.
pub fn a_tail_never_opens_on_a_tool_result_test() {
  let call = fake.tool_use("calling", [#("c1", "bash")], 0)
  let result = tool_result("c1", "bash")
  let tail = [call, result, fake.user("m4"), fake.answer("done", 0)]
  let projected = hooks.uncompacted([fake.user("m1"), ..tail])
  let assert Prepared(CompactionPreparation(
    retained_tail:,
    messages_to_summarize:,
    ..,
  )) = hooks.preparation(projected, settings(3, 0), one, tokens_before: 5)
    as "older input can be compacted"
  assert retained_tail == tail
  assert messages_to_summarize == [fake.user("m1")]
}

pub fn unread_tool_batch_survives_a_budget_smaller_than_its_results_test() {
  let tail = [
    fake.tool_use("calling", [#("c1", "bash"), #("c2", "bash")], 0),
    tool_result("c1", "bash"),
    tool_result("c2", "bash"),
    fake.user("queued correction"),
    fake.user("queued requirement"),
  ]
  let projected = hooks.uncompacted([fake.user("older"), ..tail])
  let assert Prepared(CompactionPreparation(
    retained_tail:,
    messages_to_summarize:,
    ..,
  )) = hooks.preparation(projected, settings(1, 0), one, tokens_before: 6)
    as "the whole unread exchange must survive the cut"
  assert retained_tail == tail
  assert messages_to_summarize == [fake.user("older")]
}

pub fn input_before_the_first_assistant_is_never_compacted_away_test() {
  let projected =
    hooks.uncompacted([fake.user("requirement"), fake.user("correction")])
  assert hooks.preparation(projected, settings(0, 0), one, tokens_before: 2)
    == EmptyPreparation
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
        fake.answer("fresh-1", 0),
        fake.user("fresh-2"),
      ],
      carried: 2,
      previous_summary: Some("[summary] earlier work"),
      origins: list.repeat(None, 4),
      reference_session: None,
      copied_from: None,
    )
  let assert Prepared(preparation: CompactionPreparation(
    messages_to_summarize:,
    retained_tail:,
    previous_summary: Some("[summary] earlier work"),
    ..,
  )) = hooks.preparation(projected, settings(2, 0), one, tokens_before: 4)
  assert messages_to_summarize == [fake.user("carried-1")]
  assert retained_tail == [fake.answer("fresh-1", 0), fake.user("fresh-2")]
}

pub fn nothing_older_than_the_tail_is_an_empty_preparation_test() {
  let projected = hooks.uncompacted([fake.user("m1"), fake.user("m2")])
  assert hooks.preparation(projected, settings(50, 0), one, tokens_before: 2)
    == EmptyPreparation
}

pub fn an_observed_large_result_becomes_an_exact_reference_test() {
  let generator = core_ids.generator(core_clock.fixed(at: 7), seed: 91)
  let #(session_id, generator) = core_ids.mint_session(generator)
  let #(cut_id, generator) = core_ids.mint_entry(generator)
  let #(call_id, generator) = core_ids.mint_entry(generator)
  let #(result_id, generator) = core_ids.mint_entry(generator)
  let #(user_id, generator) = core_ids.mint_entry(generator)
  let #(new_call_id, generator) = core_ids.mint_entry(generator)
  let #(new_result_id, _generator) = core_ids.mint_entry(generator)
  let call = fake.tool_use("calling", [#("same", "bash")], 0)
  let result = large_tool_result("same", "bash", False)
  let newest_call = fake.tool_use("newest", [#("new", "bash")], 0)
  let newest_result = large_tool_result("new", "bash", False)
  let projected =
    hooks.Projected(
      messages: [
        fake.user("cut"),
        call,
        result,
        fake.user("next"),
        newest_call,
        newest_result,
      ],
      carried: 0,
      previous_summary: None,
      origins: [
        Some(cut_id),
        Some(call_id),
        Some(result_id),
        Some(user_id),
        Some(new_call_id),
        Some(new_result_id),
      ],
      reference_session: Some(session_id),
      copied_from: None,
    )
  let assert Prepared(CompactionPreparation(retained_tail:, ..)) =
    hooks.preparation(projected, settings(5, 0), one, tokens_before: 6)
    as "one old message makes the retained exchange publishable"
  let assert [kept_call, referenced, _, kept_newest_call, kept_newest_result] =
    retained_tail
  assert kept_call == call
  assert kept_newest_call == newest_call
  assert kept_newest_result == newest_result
  let text = result_text(referenced)
  assert string.contains(text, "[loom tool-result reference]")
  assert string.contains(text, core_ids.session_id_to_string(session_id))
  assert string.contains(text, core_ids.entry_id_to_string(result_id))
  assert string.byte_size(text) < string.byte_size(string.repeat("x", 8192))
}

pub fn failed_small_image_and_ambiguous_results_stay_verbatim_test() {
  let generator = core_ids.generator(core_clock.fixed(at: 8), seed: 92)
  let #(session_id, generator) = core_ids.mint_session(generator)
  let #(cut_id, generator) = core_ids.mint_entry(generator)
  let #(call_id, generator) = core_ids.mint_entry(generator)
  let #(failed_id, generator) = core_ids.mint_entry(generator)
  let #(small_id, generator) = core_ids.mint_entry(generator)
  let #(image_id, generator) = core_ids.mint_entry(generator)
  let #(ambiguous_id, generator) = core_ids.mint_entry(generator)
  let #(newest_id, _generator) = core_ids.mint_entry(generator)
  let call =
    fake.tool_use(
      "calling",
      [
        #("failed", "bash"),
        #("small", "bash"),
        #("image", "bash"),
        #("dup", "bash"),
        #("dup", "bash"),
      ],
      0,
    )
  let failed = large_tool_result("failed", "bash", True)
  let small = tool_result("small", "bash")
  let image = image_tool_result("image", "bash")
  let ambiguous = large_tool_result("dup", "bash", False)
  let newest = fake.answer("observed", 0)
  let messages = [
    fake.user("cut"),
    call,
    failed,
    small,
    image,
    ambiguous,
    newest,
  ]
  let projected =
    hooks.Projected(
      messages:,
      carried: 0,
      previous_summary: None,
      origins: [
        Some(cut_id),
        Some(call_id),
        Some(failed_id),
        Some(small_id),
        Some(image_id),
        Some(ambiguous_id),
        Some(newest_id),
      ],
      reference_session: Some(session_id),
      copied_from: None,
    )
  let assert Prepared(CompactionPreparation(retained_tail:, ..)) =
    hooks.preparation(projected, settings(6, 0), one, tokens_before: 7)
  assert retained_tail == list.drop(messages, 1)
}

pub fn an_orphaned_call_disables_positional_references_test() {
  let assert Ok(opened) = session.open_memory(core_clock.fixed(at: 0))
  let generator = core_ids.generator(core_clock.fixed(at: 9), seed: 93)
  let assert Ok(#(session_id, generator)) = session.ensure_id(opened, generator)
  let #(old_id, generator) = core_ids.mint_entry(generator)
  let #(carried_user_id, generator) = core_ids.mint_entry(generator)
  let #(call_id, generator) = core_ids.mint_entry(generator)
  let #(result_id, generator) = core_ids.mint_entry(generator)
  let #(checkpoint_id, generator) = core_ids.mint_entry(generator)
  let #(fresh_user_id, generator) = core_ids.mint_entry(generator)
  let #(fresh_answer_id, generator) = core_ids.mint_entry(generator)
  let #(orphan_id, _generator) = core_ids.mint_entry(generator)
  let carried_user = fake.user("carried")
  let call = fake.tool_use("calling", [#("old-call", "bash")], 0)
  let result = large_tool_result("old-call", "bash", False)
  let assert Ok(_) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          InsertEntry(entry.MessageEntry(
            old_id,
            None,
            0,
            0,
            fake.user("old"),
            False,
          )),
          InsertEntry(entry.MessageEntry(
            carried_user_id,
            Some(old_id),
            0,
            0,
            carried_user,
            False,
          )),
          InsertEntry(entry.MessageEntry(
            call_id,
            Some(carried_user_id),
            0,
            0,
            call,
            False,
          )),
          InsertEntry(entry.MessageEntry(
            result_id,
            Some(call_id),
            0,
            0,
            result,
            False,
          )),
          InsertEntry(entry.CompactionEntry(
            checkpoint_id,
            Some(result_id),
            0,
            0,
            "checkpoint",
            [carried_user, call, result],
            10_000,
            True,
            None,
          )),
          InsertEntry(entry.MessageEntry(
            fresh_user_id,
            Some(checkpoint_id),
            0,
            0,
            fake.user("fresh"),
            False,
          )),
          InsertEntry(entry.MessageEntry(
            fresh_answer_id,
            Some(fresh_user_id),
            0,
            0,
            fake.answer("observed", 0),
            False,
          )),
          InsertEntry(entry.MessageEntry(
            orphan_id,
            Some(fresh_answer_id),
            0,
            0,
            fake.tool_use("orphan", [#("missing", "bash")], 0),
            False,
          )),
          SetRegister(
            ns: register.StrandLeaf,
            key: "main",
            value: register.leaf_value(Some(orphan_id)),
          ),
        ],
        expected: [],
      ),
    )
  let projected =
    hooks.project(opened, "main")
    |> hooks.with_tool_references(opened, session_id)
  let assert Prepared(CompactionPreparation(retained_tail:, ..)) =
    hooks.preparation(projected, settings(5, 0), one, tokens_before: 8)
  let assert [kept_call, referenced, _, _, _, synthetic] = retained_tail
  assert kept_call == call
  let assert core_message.ToolResultMessage(is_error: True, ..) = synthetic
  assert referenced == result
  assert !string.contains(
    result_text(referenced),
    "[loom tool-result reference]",
  )
}

pub fn an_exact_copied_tail_keeps_its_original_result_identity_test() {
  let assert Ok(opened) = session.open_memory(core_clock.fixed(at: 0))
  let generator = core_ids.generator(core_clock.fixed(at: 10), seed: 94)
  let assert Ok(#(session_id, generator)) = session.ensure_id(opened, generator)
  let #(root_id, generator) = core_ids.mint_entry(generator)
  let #(call_id, generator) = core_ids.mint_entry(generator)
  let #(result_id, generator) = core_ids.mint_entry(generator)
  let #(checkpoint_id, generator) = core_ids.mint_entry(generator)
  let #(fresh_user_id, generator) = core_ids.mint_entry(generator)
  let #(fresh_answer_id, _generator) = core_ids.mint_entry(generator)
  let root = fake.user("carried")
  let call = fake.tool_use("calling", [#("old-call", "bash")], 0)
  let result = large_tool_result("old-call", "bash", False)
  let assert Ok(_) =
    storage.commit(
      opened.store,
      Tx(
        writes: [
          InsertEntry(entry.MessageEntry(root_id, None, 0, 0, root, False)),
          InsertEntry(entry.MessageEntry(
            call_id,
            Some(root_id),
            0,
            0,
            call,
            False,
          )),
          InsertEntry(entry.MessageEntry(
            result_id,
            Some(call_id),
            0,
            0,
            result,
            False,
          )),
          InsertEntry(entry.CompactionEntry(
            checkpoint_id,
            Some(result_id),
            0,
            0,
            "checkpoint",
            [root, call, result],
            10_000,
            True,
            None,
          )),
          InsertEntry(entry.MessageEntry(
            fresh_user_id,
            Some(checkpoint_id),
            0,
            0,
            fake.user("fresh"),
            False,
          )),
          InsertEntry(entry.MessageEntry(
            fresh_answer_id,
            Some(fresh_user_id),
            0,
            0,
            fake.answer("observed", 0),
            False,
          )),
          SetRegister(
            ns: register.StrandLeaf,
            key: "main",
            value: register.leaf_value(Some(fresh_answer_id)),
          ),
        ],
        expected: [],
      ),
    )
  let projected =
    hooks.project(opened, "main")
    |> hooks.with_tool_references(opened, session_id)
  let assert Prepared(CompactionPreparation(retained_tail:, ..)) =
    hooks.preparation(projected, settings(4, 0), one, tokens_before: 6)
  let assert [kept_call, referenced, _, _] = retained_tail
  assert kept_call == call
  assert string.contains(
    result_text(referenced),
    "[loom tool-result reference]",
  )
  assert string.contains(
    result_text(referenced),
    core_ids.entry_id_to_string(result_id),
  )
}

// --- the two signals -------------------------------------------------------

pub fn the_threshold_is_the_window_less_the_reserve_test() {
  // Three sizeable turns, then a priced assistant response and one
  // message after it: 85_000 reported plus one estimated.
  let projected =
    hooks.uncompacted([
      bulky(),
      bulky(),
      bulky(),
      fake.answer("turn", 85_000),
      fake.user("next"),
    ])
  // 85_001 against a 100_000 window: under a 10k reserve, over a 20k one.
  let quiet =
    hooks.threshold(
      settings(20_000, 10_000),
      context_window: 100_000,
      estimate: hooks.estimate_message,
    )
  assert quiet(query_of(projected)) == ThresholdNotExceeded
  let firing =
    hooks.threshold(
      settings(20_000, 20_000),
      context_window: 100_000,
      estimate: hooks.estimate_message,
    )
  let assert ThresholdExceeded(outcome: Prepared(preparation: CompactionPreparation(
    messages_to_summarize:,
    retained_tail:,
    tokens_before: 85_001,
    ..,
  ))) = firing(query_of(projected))
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
      estimate: fn(_message) { 1000 },
    )
  assert signal(query_of(hooks.uncompacted([fake.user("m1")])))
    == ThresholdNotExceeded
}

pub fn an_empty_strand_never_fires_test() {
  let signal = hooks.threshold(settings(0, 0), context_window: 0, estimate: one)
  assert signal(query()) == ThresholdNotExceeded
}

// Overflow asks no question about size — the provider already answered
// it — and shares the threshold's builder, so the two compact alike.
pub fn overflow_prepares_unconditionally_test() {
  let prepare =
    hooks.overflow(
      settings(1, 0),
      projection: fn(_strand) {
        hooks.uncompacted([fake.user("m1"), fake.answer("m2", 0)])
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

fn large_tool_result(
  id: String,
  name: String,
  is_error: Bool,
) -> core_message.AgentMessage {
  core_message.ToolResultMessage(
    tool_call_id: id,
    tool_name: name,
    content: [
      core_message.ToolResultText(
        text: string.repeat("x", 8192),
        text_signature: None,
      ),
    ],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error:,
    timestamp: 0,
  )
}

fn image_tool_result(id: String, name: String) -> core_message.AgentMessage {
  core_message.ToolResultMessage(
    tool_call_id: id,
    tool_name: name,
    content: [
      core_message.ToolResultText(string.repeat("x", 8192), None),
      core_message.ToolResultImage(string.repeat("YQ==", 2048), "image/png"),
    ],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: 0,
  )
}

fn result_text(result: core_message.AgentMessage) -> String {
  let assert core_message.ToolResultMessage(
    content: [core_message.ToolResultText(text:, ..)],
    ..,
  ) = result
    as "the reference is one text result"
  text
}

fn support_configuration() -> machine_strand.StrandConfiguration {
  machine_strand.StrandConfiguration(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: machine_strand.ThinkingOff,
    active_tool_names: [],
  )
}

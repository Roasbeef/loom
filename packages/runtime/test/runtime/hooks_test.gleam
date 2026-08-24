//// The hook registry: slot replacement and the config-driven threshold
//// hook's projection arithmetic.

import core/clock as core_clock
import core/ids as core_ids
import core/json as core_json
import machine/operation.{CompactionPreparation, CompactionSettings}
import machine/planner.{
  Admitted, Prepared, ThresholdExceeded, ThresholdNotExceeded,
}
import machine/strand as machine_strand
import runtime/effects.{AdmissionQuery, ThresholdQuery}
import runtime/hooks
import support/fake

fn query() -> effects.ThresholdQuery {
  let #(op, _generator) =
    core_ids.mint_op(core_ids.generator(core_clock.fixed(at: 1), seed: 3))
  ThresholdQuery(operation: op, strand: "main")
}

pub fn admission_hook_carries_the_api_test() {
  let admit =
    hooks.admission(
      api: "acme-api",
      intended_output_limit: 4096,
      context_window: 100_000,
    )
  let #(op, _generator) =
    core_ids.mint_op(core_ids.generator(core_clock.fixed(at: 1), seed: 3))
  let assert Admitted(api: "acme-api", intended_output_limit: 4096, ..) =
    admit(AdmissionQuery(
      operation: op,
      step_id: "s1",
      attempt: 1,
      configuration: support_configuration(),
      stream_options: core_json.Object([]),
    ))
}

pub fn threshold_hook_fires_and_splits_the_tail_test() {
  let settings =
    CompactionSettings(enabled: True, reserve_tokens: 0, keep_recent_tokens: 3)
  let messages = [
    fake.user("m1"),
    fake.user("m2"),
    fake.user("m3"),
    fake.user("m4"),
    fake.user("m5"),
  ]
  let signal =
    hooks.threshold(
      settings,
      trigger_tokens: 5,
      projection: fn(_strand) { messages },
      estimate: fn(_message) { 1 },
    )
  let assert ThresholdExceeded(outcome: Prepared(preparation: CompactionPreparation(
    messages_to_summarize:,
    retained_tail:,
    tokens_before: 5,
    ..,
  ))) = signal(query())
  // The newest three messages fit the keep-recent budget; the older two
  // are summarized.
  assert messages_to_summarize == [fake.user("m1"), fake.user("m2")]
  assert retained_tail == [fake.user("m3"), fake.user("m4"), fake.user("m5")]
}

pub fn threshold_hook_stays_quiet_below_the_trigger_test() {
  let settings =
    CompactionSettings(enabled: True, reserve_tokens: 0, keep_recent_tokens: 3)
  let signal =
    hooks.threshold(
      settings,
      trigger_tokens: 100,
      projection: fn(_strand) { [fake.user("m1")] },
      estimate: fn(_message) { 1 },
    )
  assert signal(query()) == ThresholdNotExceeded
}

pub fn disabled_settings_never_fire_test() {
  let settings =
    CompactionSettings(enabled: False, reserve_tokens: 0, keep_recent_tokens: 0)
  let signal =
    hooks.threshold(
      settings,
      trigger_tokens: 1,
      projection: fn(_strand) { [fake.user("m1")] },
      estimate: fn(_message) { 1000 },
    )
  assert signal(query()) == ThresholdNotExceeded
}

fn support_configuration() -> machine_strand.StrandConfiguration {
  machine_strand.StrandConfiguration(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: machine_strand.ThinkingOff,
    active_tool_names: [],
  )
}

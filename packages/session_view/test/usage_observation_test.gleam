//// Missing token measurements cannot reset a live context or cache watch.
//// Request totals retain their evidence; per-response projections only change
//// when the final attempt has an observable token reading.

import core/accounting
import core/message
import core/usage_evidence
import gleam/dict
import gleam/option.{type Option, None, Some}
import session_view/cache_watch
import session_view/event_fold
import session_view/inbox
import session_view/model.{type Shared, Shared} as session_model
import session_view/msg
import session_view/protocol
import session_view/step

pub fn unknown_zero_push_preserves_context_cache_rate_and_notice_test() {
  let known = observed(warm(), Some(5), starting())
  let known =
    Shared(
      ..known,
      stamp: msg.Stamp(2000, 2000),
      generation_started_ms: Some(1000),
    )
  let after = observed(missing(), Some(6), known)
  assert after.roster == known.roster
  assert after.cache == known.cache
  assert after.cache_notices == known.cache_notices
  assert after.output_rate_tps == known.output_rate_tps
  assert after.generation_started_ms == known.generation_started_ms
  assert after.notice == known.notice
  assert dict.get(after.roster.pushed, "main") == Ok(#("op", 40_600))
  assert after.usage == known.usage
}

pub fn legacy_unknown_zero_retains_aggregate_uncertainty_without_projection_test() {
  let known = observed(warm(), None, starting())
  let after = observed(missing(), None, known)
  assert after.cache == known.cache
  assert after.roster == known.roster
  assert after.notice == known.notice
  assert after.output_rate_tps == known.output_rate_tps
  assert after.usage.total_tokens == known.usage.total_tokens
  assert after.usage.evidence == usage_evidence.partial(usage_evidence.Api)
  assert cache_watch.outlook(after.cache, "main", 2000)
    == cache_watch.outlook(known.cache, "main", 2000)
}

pub fn reported_zero_and_historical_nonzero_remain_observable_test() {
  let known = observed(warm(), Some(5), starting())
  let zero =
    message.Usage(
      ..missing(),
      evidence: usage_evidence.reported(usage_evidence.Api),
    )
  let after = observed(zero, Some(6), known)
  assert dict.get(after.roster.pushed, "main") == Ok(#("op", 0))
  assert after.notice == "0 tokens this turn"
  let historical =
    message.Usage(
      ..warm(),
      evidence: usage_evidence.unknown(usage_evidence.Other),
    )
  let restored = observed(historical, Some(7), after)
  assert dict.get(restored.roster.pushed, "main") == Ok(#("op", 40_600))
  let partial_zero =
    message.Usage(..zero, evidence: usage_evidence.partial(usage_evidence.Api))
  let partial = observed(partial_zero, Some(8), restored)
  assert dict.get(partial.roster.pushed, "main") == Ok(#("op", 0))
}

pub fn fallback_aggregate_does_not_become_context_or_own_push_totals_test() {
  let final = warm()
  let aggregate = accounting.add_usage(final, final)
  let before = starting()
  let after =
    event_fold.apply_event(
      before,
      protocol.UsageChanged("main", Some(5), Some("op"), aggregate, Some(final)),
    )
  assert dict.get(after.roster.pushed, "main") == Ok(#("op", 40_600))
  assert after.usage == before.usage
}

fn starting() -> Shared(String, Nil, String, String) {
  let shared =
    step.new(
      "main",
      "session",
      msg.Stamp(1000, 1000),
      inbox.new("frames"),
      inbox.new("replay"),
    )
  Shared(..shared, peer: session_model.Attached, generation_started_ms: Some(0))
}

fn observed(
  usage: message.Usage,
  seq: Option(Int),
  shared: Shared(String, Nil, String, String),
) -> Shared(String, Nil, String, String) {
  event_fold.apply_event(
    shared,
    protocol.UsageChanged("main", seq, Some("op"), usage, Some(usage)),
  )
}

fn missing() -> message.Usage {
  message.Usage(
    ..accounting.zero_usage(),
    evidence: usage_evidence.unknown(usage_evidence.Api),
  )
}

fn warm() -> message.Usage {
  message.Usage(
    ..accounting.zero_usage(),
    input: 200,
    output: 400,
    cache_read: 40_000,
    total_tokens: 40_600,
    evidence: usage_evidence.reported(usage_evidence.Api),
  )
}

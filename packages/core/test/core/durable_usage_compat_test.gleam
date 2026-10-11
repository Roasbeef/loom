//// Rows written by earlier builds of protocol 081 must keep decoding.
////
//// Each literal below is the exact text an earlier encoder produced for a
//// value the evidence constructors can still build. The tests decode the
//// literal and compare it with the equivalent value built through the
//// constructors, so a reshaping of the in-memory representation cannot
//// change what durable rows mean. The `mixed` forms are the exception to
//// the byte-identical encoding check: the arrangement no longer exists as a
//// value, so it is decoded but re-encoded as `other`.

import core/accounting
import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence as evidence
import gleam/option.{None, Some}
import gleam/string

const none_text =
  "{\"version\":1,\"tokens\":\"complete\",\"billing\":\"no-provider\",\"cost\":{\"kind\":\"no-expense\"}}"

const unknown_api_text =
  "{\"version\":1,\"tokens\":\"unknown\",\"billing\":\"api\",\"cost\":{\"kind\":\"unavailable\"}}"

const reported_plan_text =
  "{\"version\":1,\"tokens\":\"complete\",\"billing\":\"chatgpt-plan\",\"cost\":{\"kind\":\"unavailable\"}}"

const partial_other_text =
  "{\"version\":1,\"tokens\":\"partial\",\"billing\":\"other\",\"cost\":{\"kind\":\"unavailable\"}}"

const priced_api_text =
  "{\"version\":1,\"tokens\":\"complete\",\"billing\":\"other\",\"cost\":{\"kind\":\"estimated\",\"coverage\":\"complete\",\"basis\":\"api-rates\"}}"

const partial_plan_priced_text =
  "{\"version\":1,\"tokens\":\"partial\",\"billing\":\"chatgpt-plan\",\"cost\":{\"kind\":\"estimated\",\"coverage\":\"partial\",\"basis\":\"chatgpt-reference-rates\"}}"

const mixed_text =
  "{\"version\":1,\"tokens\":\"complete\",\"billing\":\"mixed\",\"cost\":{\"kind\":\"estimated\",\"coverage\":\"complete\",\"basis\":\"mixed-rates\"}}"

fn parse(text: String) -> json.JsonValue {
  let assert Ok(value) = json.parse(text) as "golden text is valid JSON"
  value
}

// Decodes the literal, then checks that today's encoder still writes it.
fn round_trips(text: String, expected: evidence.Evidence) -> Nil {
  assert evidence.decode(parse(text)) == Ok(expected)
  assert json.to_string(evidence.encode(expected)) == text
}

pub fn earlier_evidence_encodings_still_decode_and_encode_test() {
  round_trips(none_text, evidence.none())
  round_trips(unknown_api_text, evidence.unknown(evidence.Api))
  round_trips(reported_plan_text, evidence.reported(evidence.ChatGptPlan))
  round_trips(partial_other_text, evidence.partial(evidence.Other))
  round_trips(priced_api_text, evidence.priced_api())
  round_trips(
    partial_plan_priced_text,
    evidence.with_price(
      evidence.partial(evidence.ChatGptPlan),
      evidence.ChatGptReferenceRates,
    ),
  )
}

pub fn earlier_mixed_evidence_decodes_to_the_merged_arrangement_test() {
  let api =
    evidence.with_price(evidence.reported(evidence.Api), evidence.ApiRates)
  let plan =
    evidence.with_price(
      evidence.reported(evidence.ChatGptPlan),
      evidence.ChatGptReferenceRates,
    )
  let merged = evidence.add(api, plan)
  assert evidence.decode(parse(mixed_text)) == Ok(merged)
  assert merged
    == evidence.Remote(
      evidence.Other,
      evidence.Reported(
        evidence.Complete,
        evidence.Priced(evidence.Complete, evidence.MixedRates),
      ),
    )
  assert json.to_string(evidence.encode(merged))
    == string.replace(mixed_text, "mixed\"", "other\"")
}

const usage_text =
  "{\"input\":80,\"output\":20,\"cacheRead\":30,\"cacheWrite\":10,\"cacheWrite1h\":4,\"reasoning\":7,\"totalTokens\":140,\"cost\":{\"input\":0.8,\"output\":0.4,\"cacheRead\":0.03,\"cacheWrite\":0.1,\"total\":1.33},\"evidence\":{\"version\":1,\"tokens\":\"complete\",\"billing\":\"other\",\"cost\":{\"kind\":\"estimated\",\"coverage\":\"complete\",\"basis\":\"api-rates\"}}}"

const historical_usage_text =
  "{\"input\":3,\"output\":4,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":7,\"cost\":{\"input\":0.0,\"output\":0.0,\"cacheRead\":0.0,\"cacheWrite\":0.0,\"total\":0.0}}"

fn priced_usage() -> message.Usage {
  message.Usage(
    input: 80,
    output: 20,
    cache_read: 30,
    cache_write: 10,
    cache_write_1h: Some(4),
    reasoning: Some(7),
    total_tokens: 140,
    cost: message.UsageCost(0.8, 0.4, 0.03, 0.1, 1.33),
    evidence: evidence.priced_api(),
  )
}

pub fn earlier_usage_encoding_still_decodes_and_encodes_test() {
  assert codec.decode_usage(parse(usage_text)) == Ok(priced_usage())
  assert json.to_string(codec.encode_usage(priced_usage())) == usage_text
}

pub fn usage_without_evidence_still_reads_as_unknown_test() {
  let assert Ok(usage) = codec.decode_usage(parse(historical_usage_text))
  assert usage.input == 3
  assert usage.evidence == evidence.unknown(evidence.Other)
}

pub fn usage_claiming_no_expense_with_counts_is_still_refused_test() {
  let text =
    "{\"input\":3,\"output\":4,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":7,\"cost\":{\"input\":0.0,\"output\":0.0,\"cacheRead\":0.0,\"cacheWrite\":0.0,\"total\":0.0},\"evidence\":"
    <> none_text
    <> "}"
  let assert Error(_) = codec.decode_usage(parse(text))
}

const details_text =
  "{\"phase\":\"summary\",\"loom.request-accounting.v1\":{\"version\":1,\"attempt_count\":2,\"last\":{\"input\":50,\"output\":10,\"cacheRead\":40,\"cacheWrite\":5,\"totalTokens\":105,\"cost\":{\"input\":0.25,\"output\":0.2,\"cacheRead\":0.04,\"cacheWrite\":0.05,\"total\":0.54},\"evidence\":{\"version\":1,\"tokens\":\"complete\",\"billing\":\"other\",\"cost\":{\"kind\":\"estimated\",\"coverage\":\"complete\",\"basis\":\"api-rates\"}}}}}"

fn row(usage: message.Usage, details: json.JsonValue) -> entry.UsageRow {
  let #(id, _) = ids.mint_usage(ids.generator(clock.fixed(at: 1), seed: 9))
  entry.UsageRow(
    id:,
    seq: 1,
    entry_id: None,
    adjustment: False,
    usage:,
    details: Some(details),
  )
}

fn second_attempt() -> message.Usage {
  message.Usage(
    input: 50,
    output: 10,
    cache_read: 40,
    cache_write: 5,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 105,
    cost: message.UsageCost(0.25, 0.2, 0.04, 0.05, 0.54),
    evidence: evidence.priced_api(),
  )
}

fn two_attempts() -> accounting.RequestAccounting {
  accounting.append(accounting.from_usage(priced_usage()), second_attempt())
}

pub fn earlier_request_accounting_details_still_decode_test() {
  let report = two_attempts()
  let stored = row(accounting.total(report), parse(details_text))
  assert accounting.decode_row(stored) == Ok(report)
}

pub fn request_accounting_details_encode_as_earlier_builds_did_test() {
  let details =
    accounting.details(two_attempts(), [#("phase", json.String("summary"))])
  assert details == parse(details_text)
}

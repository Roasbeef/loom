//// The fields protocol-change/126 and the addendum to 120 add to an approval
//// item: the raise time, the network word and the policy today.
////
//// Each decodes when present. A damaged one is absent and costs the item
//// nothing, and an item from an older daemon, with none of them, decodes as it
//// always did.

import core/json
import gleam/option.{None, Some}
import web_view/approval_evidence

fn record(extra: List(#(String, json.JsonValue))) -> json.JsonValue {
  json.Object([
    #("id", json.String("esc-1")),
    #("revision", json.Int(4)),
    #("tool", json.String("code_mode")),
    ..extra
  ])
}

fn reply(item: json.JsonValue) -> json.JsonValue {
  json.Object([
    #(
      "approvals",
      json.Object([#("count", json.Int(1)), #("items", json.Array([item]))]),
    ),
  ])
}

pub fn the_raise_time_and_the_words_decode_when_present_test() {
  let item =
    record([
      #("raised_at", json.Int(1_763_400_000_000)),
      #("network", json.String("off")),
      #(
        "policy",
        json.Object([
          #("sandbox", json.String("workspace-write")),
          #("network", json.String("off")),
        ]),
      ),
    ])
  let assert Ok(approval_evidence.Evidence(items: [item], ..)) =
    approval_evidence.decode(reply(item))
  assert item.raised_at == Some(1_763_400_000_000)
  assert item.network == Some(approval_evidence.NetworkOff)
  assert item.policy == Some(approval_evidence.Policy("workspace-write", "off"))
}

pub fn an_item_from_before_the_fields_has_none_of_them_test() {
  let assert Ok(approval_evidence.Evidence(items: [item], ..)) =
    approval_evidence.decode(reply(record([])))
  assert item.raised_at == None
  assert item.network == None
  assert item.policy == None
}

pub fn a_damaged_added_field_is_absent_and_costs_nothing_test() {
  let damaged =
    record([
      #("raised_at", json.String("noon")),
      #("network", json.String("maybe")),
      #("policy", json.Object([#("sandbox", json.String("x"))])),
    ])
  let assert Ok(approval_evidence.Evidence(items: [item], ..)) =
    approval_evidence.decode(reply(damaged))
  assert item.raised_at == None
  assert item.network == None
  assert item.policy == None
  assert item.tool == "code_mode"

  let negative = record([#("raised_at", json.Int(-5))])
  let assert Ok(approval_evidence.Evidence(items: [item], ..)) =
    approval_evidence.decode(reply(negative))
  assert item.raised_at == None
}

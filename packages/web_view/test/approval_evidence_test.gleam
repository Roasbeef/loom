//// The decoder of an approval read (`web_view/approval_evidence`): total, one
//// damaged record costs only itself, and a count never falls below what the
//// reply carried (protocol-change/120, "Approval evidence").

import core/json
import gleam/option.{None, Some}
import web_view/approval_evidence.{Item, Wanted}

fn record(id: String) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("revision", json.Int(4)),
    #("tool", json.String("bash")),
    #("preview", json.String("ls")),
    #("source", json.String("policy")),
    #("reason", json.String("no")),
    #(
      "wanted",
      json.Array([
        json.Object([
          #("kind", json.String("network")),
          #("detail", json.String("full")),
        ]),
        json.Object([#("detail", json.String("nothing"))]),
      ]),
    ),
    #("asked", json.Int(2)),
  ])
}

fn reply(count: Int, items: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #(
      "approvals",
      json.Object([#("count", json.Int(count)), #("items", json.Array(items))]),
    ),
  ])
}

pub fn a_record_decodes_with_its_wanted_grants_test() {
  assert approval_evidence.decode(reply(1, [record("esc-1")]))
    == Ok(
      approval_evidence.Evidence(count: 1, items: [
        Item(
          id: "esc-1",
          revision: 4,
          tool: "bash",
          preview: Some("ls"),
          source: "policy",
          reason: "no",
          wanted: [Wanted(kind: "network", detail: "full")],
          asked: 2,
          raised_at: None,
          network: None,
          policy: None,
        ),
      ]),
    )
}

pub fn a_damaged_record_costs_only_itself_test() {
  let damaged = json.Object([#("id", json.String("esc-2"))])
  let assert Ok(evidence) =
    approval_evidence.decode(reply(2, [damaged, record("esc-1")]))
  assert evidence.count == 2
  assert evidence.items != []
}

pub fn a_count_below_the_items_is_read_as_the_larger_test() {
  let assert Ok(evidence) =
    approval_evidence.decode(reply(0, [record("esc-1")]))
  assert evidence.count == 1
}

pub fn a_reply_that_is_not_one_is_no_evidence_test() {
  assert approval_evidence.decode(json.Null) == Error(Nil)
  assert approval_evidence.decode(json.Object([])) == Error(Nil)
  assert approval_evidence.decode(reply(-1, [])) == Error(Nil)
  let none =
    json.Object([#("id", json.String("x")), #("revision", json.Int(1))])
  let assert Ok(evidence) = approval_evidence.decode(reply(1, [none]))
  assert evidence.items
    == [
      Item(
        id: "x",
        revision: 1,
        tool: "",
        preview: None,
        source: "",
        reason: "",
        wanted: [],
        asked: 0,
        raised_at: None,
        network: None,
        policy: None,
      ),
    ]
}

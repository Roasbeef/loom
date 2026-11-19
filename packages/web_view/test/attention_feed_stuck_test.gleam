//// A stuck item's added fields (protocol-change/120, the addendum on stuck
//// strands): the reason, the provider's retry hint and the parent strand.
////
//// A row from an older daemon has none of them and still decodes, and a
//// damaged one is absent.

import core/json
import gleam/list
import gleam/option.{None, Some}
import web_view/attention_feed.{Stuck}

fn row(items: List(json.JsonValue)) -> json.JsonValue {
  let section = fn(count, items) {
    json.Object([#("count", json.Int(count)), #("items", json.Array(items))])
  }
  json.Object([
    #("state", json.String("ok")),
    #("asks", section(0, [])),
    #("finds", section(0, [])),
    #("stuck", section(list.length(items), items)),
  ])
}

pub fn a_stuck_item_decodes_its_reason_hint_and_parent_test() {
  let full =
    json.Object([
      #("strand", json.String("sub:main/a")),
      #("failed_at", json.Int(1_763_402_000_000)),
      #("reason", json.String("provider_error")),
      #("retry_after_ms", json.Int(30_000)),
      #("parent", json.String("main")),
    ])
  let old = json.Object([#("strand", json.String("sub:main/b"))])
  let assert Ok(decoded) = attention_feed.decode_row(row([full, old]))
  assert decoded.stuck.items
    == [
      Stuck(
        "sub:main/a",
        Some(1_763_402_000_000),
        Some("provider_error"),
        Some(30_000),
        Some("main"),
      ),
      Stuck("sub:main/b", None, None, None, None),
    ]
}

pub fn a_damaged_added_field_is_absent_test() {
  let damaged =
    json.Object([
      #("strand", json.String("sub:main/a")),
      #("reason", json.Int(3)),
      #("retry_after_ms", json.String("soon")),
      #("parent", json.Null),
    ])
  let assert Ok(decoded) = attention_feed.decode_row(row([damaged]))
  assert decoded.stuck.items == [Stuck("sub:main/a", None, None, None, None)]
}

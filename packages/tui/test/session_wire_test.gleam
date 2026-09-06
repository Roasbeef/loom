//// Reply identity and version are checked before a live body reaches the view.

import core/json
import gleam/list
import gleam/string
import tui/session_wire

fn reply(version, id, event, body) {
  json.to_string(
    json.Object([
      #("v", json.Int(version)),
      #("reply_to", json.Int(id)),
      #("event", json.String(event)),
      #("body", body),
    ]),
  )
}

pub fn session_wire_correlates_every_response_and_never_falls_back_to_v1_test() {
  let body = json.Object([#("status", json.String("admitted"))])
  assert session_wire.decode(reply(2, 4, "mutation_outcome", body), 4)
    == Ok(session_wire.Mutation("admitted"))
  list.each(
    [
      reply(1, 4, "mutation_outcome", body),
      reply(2, 3, "mutation_outcome", body),
      reply(2, 4, "entry", json.Object([])),
      reply(
        2,
        4,
        "mutation_outcome",
        json.Object([#("status", json.String("maybe"))]),
      ),
      string.repeat(" ", 65_537),
    ],
    fn(frame) {
      let assert Error(_) = session_wire.decode(frame, 4)
        as "wrong version, late reply, unsolicited event and oversized input fail closed"
    },
  )
}

pub fn session_wire_snapshot_credit_keeps_explicit_index_and_transport_identity_test() {
  let assert Ok(json.Object(fields)) =
    json.parse(session_wire.next(17, "cut-a", 3))
    as "generated credit is a total v2 envelope"
  assert list.key_find(fields, "v") == Ok(json.Int(2))
  assert list.key_find(fields, "id") == Ok(json.Int(17))
  assert list.key_find(fields, "cmd") == Ok(json.String("snapshot_next"))
  assert list.key_find(fields, "body")
    == Ok(
      json.Object([
        #("snapshot_id", json.String("cut-a")),
        #("index", json.Int(3)),
      ]),
    )
}

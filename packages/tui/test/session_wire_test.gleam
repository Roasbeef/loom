//// Reply identity and version are checked before a live body reaches the view.

import core/json
import gleam/list
import gleam/string
import tui/protocol
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

fn pushed(fields) {
  json.to_string(json.Object([#("v", json.Int(2)), ..fields]))
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

pub fn session_wire_decodes_every_pushed_shape_and_drops_unknown_names_test() {
  assert session_wire.decode(
      pushed([
        #("event", json.String("committed")),
        #("seq", json.Int(41)),
        #("body", json.Object([#("strand", json.String("main"))])),
      ]),
      4,
    )
    == Ok(session_wire.Pushed(protocol.Committed(strand: "main", seq: 41)))

  assert session_wire.decode(
      pushed([
        #("event", json.String("stream_delta")),
        #(
          "body",
          json.Object([
            #("strand", json.String("main")),
            #("op", json.String("op-1")),
            #("kind", json.String("text")),
            #("text", json.String("hel")),
          ]),
        ),
      ]),
      4,
    )
    == Ok(
      session_wire.Pushed(protocol.StreamDelta(
        strand: "main",
        operation: "op-1",
        kind: "text",
        text: "hel",
      )),
    )

  // Presence and attachment say only that the next capture differs, so both
  // land on the one variant the channel treats as a capture trigger.
  list.each(["presence", "attachment"], fn(name) {
    assert session_wire.decode(
        pushed([
          #("event", json.String(name)),
          #("body", json.Object([#("peers", json.Array([]))])),
        ]),
        4,
      )
      == Ok(session_wire.Pushed(protocol.MetadataChanged(name)))
  })

  assert session_wire.decode(
      pushed([
        #("event", json.String("error")),
        #(
          "body",
          json.Object([
            #("code", json.String("code_conflict")),
            #("message", json.String("strand is busy")),
          ]),
        ),
      ]),
      4,
    )
    == Ok(
      session_wire.Pushed(protocol.ServerError(
        code: "code_conflict",
        message: "strand is busy",
      )),
    )

  // A daemon ahead of this terminal must not be able to close its socket, so
  // an unknown pushed name decodes rather than failing.
  assert session_wire.decode(
      pushed([
        #("event", json.String("weather")),
        #("body", json.Object([])),
      ]),
      4,
    )
    == Ok(session_wire.Pushed(protocol.Ignored("weather")))
}

pub fn session_wire_accepts_a_queued_prompt_and_still_refuses_a_late_reply_test() {
  let queued = json.Object([#("status", json.String("queued"))])
  assert session_wire.decode(reply(2, 4, "mutation_outcome", queued), 4)
    == Ok(session_wire.Mutation("queued"))

  // Correlation is unchanged for anything that names a request: a frame for
  // request three cannot be read as the answer to request four, and the one
  // that pretends to be a push is not one because it named an identity.
  let assert Error(_) = session_wire.decode(reply(2, 3, "committed", queued), 4)
    as "a mismatched reply identity fails closed, pushed vocabulary or not"
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

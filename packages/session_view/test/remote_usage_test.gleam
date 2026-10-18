//// The spend of children on other orchestrators, as a snapshot carries it
//// (protocol-change/084, phase 2): the wire form, the absent field of an older
//// daemon, a damaged entry, and the words a status bar uses.

import core/json
import session_view/remote_usage.{RemoteUsage}
import session_view/remote_usage_words

fn box() -> remote_usage.RemoteUsage {
  RemoteUsage(
    orchestrator: "box",
    input: 12_300,
    output: 678,
    cache_read: 5,
    cache_write: 7,
    cost: 0.5,
  )
}

pub fn an_entry_round_trips_test() {
  assert remote_usage.decode(remote_usage.encode(box())) == Ok(box())
  assert remote_usage.tokens(box()) == 12_978
}

pub fn an_absent_field_is_no_entries_and_a_damaged_one_is_an_error_test() {
  assert remote_usage.decode_all([]) == Ok([])
  assert remote_usage.decode_all([
      #("remote_usage", json.Array([remote_usage.encode(box())])),
    ])
    == Ok([box()])
  let assert Error(_) =
    remote_usage.decode_all([#("remote_usage", json.String("box"))])
  let assert Error(_) =
    remote_usage.decode_all([#("remote_usage", json.Array([json.Null]))])
}

pub fn a_negative_count_or_a_nameless_entry_is_refused_test() {
  let with = fn(field, value) {
    let assert json.Object(fields) = remote_usage.encode(box())
    json.Object([#(field, value), ..fields])
  }
  let assert Error(_) = remote_usage.decode(with("input", json.Int(-1)))
  let assert Error(_) =
    remote_usage.decode(with("orchestrator", json.String("")))
  let assert Error(_) = remote_usage.decode(with("cost", json.String("free")))
}

pub fn the_words_name_each_orchestrator_test() {
  assert remote_usage_words.line([]) == ""
  assert remote_usage_words.line([box()]) == "box in 12.3k out 678"
  assert remote_usage_words.line([
      box(),
      RemoteUsage(..box(), orchestrator: "desk", input: 40, output: 2),
    ])
    == "box in 12.3k out 678 · desk in 40 out 2"
}

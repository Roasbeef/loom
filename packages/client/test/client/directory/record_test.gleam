//// The owner record's stored shape and its total decoder (protocol-change/081).
//// The payload crosses Ra's durable log, so anything that is not a version 1
//// record with valid names is refused rather than read as absent.

import client/directory/record.{Local, Moving, Record, Serving}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom

const alpha = "alpha@10.0.0.1"

const op = "0192f3c1-0000-7000-8000-000000000001"

// A stored payload as Khepri hands it back: the encoded value seen as data.
fn as_stored(payload: record.Payload) -> Dynamic {
  coerce(payload)
}

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> Dynamic

pub fn a_serving_record_round_trips_test() {
  let owned = Record(owner: alpha, state: Serving)
  assert record.decode(as_stored(record.encode(owned))) == Ok(owned)
}

pub fn a_moving_record_round_trips_test() {
  let moving = Record(owner: alpha, state: Moving(op:, to: "bravo@10.0.0.4"))
  assert record.decode(as_stored(record.encode(moving))) == Ok(moving)
}

pub fn a_local_record_round_trips_as_its_own_state_test() {
  let local = Record(owner: alpha, state: Local)
  assert record.decode(as_stored(record.encode(local))) == Ok(local)

  // It is stored as the atom `local`, which no move's expected value matches.
  let stored =
    coerce(#(atom.create("loom_owner"), 1, alpha, atom.create("local")))
  assert record.decode(stored) == Ok(local)
}

pub fn the_stored_term_is_the_documented_tuple_test() {
  let stored = as_stored(record.encode(Record(owner: alpha, state: Serving)))
  let decoder = {
    use tag <- decode.field(0, atom.decoder())
    use version <- decode.field(1, decode.int)
    use owner <- decode.field(2, decode.string)
    use state <- decode.field(3, atom.decoder())
    decode.success(#(atom.to_string(tag), version, owner, atom.to_string(state)))
  }
  assert decode.run(stored, decoder) == Ok(#("loom_owner", 1, alpha, "serving"))
}

pub fn another_version_is_refused_test() {
  let stored =
    coerce(#(atom.create("loom_owner"), 2, alpha, atom.create("serving")))
  let assert Error(_) = record.decode(stored) as "a version 2 record is refused"
  Nil
}

pub fn a_malformed_owner_is_refused_test() {
  let stored =
    coerce(#(atom.create("loom_owner"), 1, "not a node", atom.create("serving")))
  let assert Error(_) = record.decode(stored) as "a bad node name is refused"
  Nil
}

pub fn a_malformed_move_identity_is_refused_test() {
  let stored =
    coerce(#(
      atom.create("loom_owner"),
      1,
      alpha,
      #(atom.create("moving"), "", "bravo@10.0.0.4"),
    ))
  let assert Error(_) = record.decode(stored) as "an empty op is refused"
  Nil
}

pub fn an_unknown_state_is_refused_test() {
  let stored =
    coerce(#(atom.create("loom_owner"), 1, alpha, atom.create("deleted")))
  let assert Error(_) = record.decode(stored) as "an unknown state is refused"
  Nil
}

pub fn the_migration_marker_is_recognized_test() {
  assert record.is_migrated(coerce(record.migrated()))
  assert !record.is_migrated(coerce(#(atom.create("loom_migrated"), 2)))
}

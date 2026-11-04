//// Tests for the role pins a registration carries (protocol-change/107): the
//// stored object's codec, the round trip through the catalogue, the migration
//// of 080's `model` column, and the refusal of damaged values.

import core/clock
import core/ids
import gleam/dynamic/decode
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import qcheck
import sqlight
import storage/catalogue
import support/fixtures

fn fresh_path(name: String) -> String {
  fixtures.scratch("catalogue-pins-" <> name) <> "/catalogue.db"
}

fn registration(seed: Int) -> catalogue.Registration {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed:)
  let #(id, _) = ids.mint_session(generator)
  let id = ids.session_id_to_string(id)
  catalogue.Registration(
    id:,
    path: "/unopened-loom-catalogue-test/" <> id <> ".db",
    workspace: "/workspace/pins",
    name: "pins",
    configuration: "/configuration/loom.toml",
    created_at: 1_700_000_000_000,
    request_key: "pins-request-" <> string.inspect(seed),
    state: catalogue.Reserved,
    profile: option.None,
    pins: [],
    executor: "",
    pool: "",
    subtitle: option.None,
  )
}

fn raw(path: String, script: String) -> Result(Nil, sqlight.Error) {
  use connection <- result.try(sqlight.open(path))
  let ran = sqlight.exec(script, on: connection)
  use Nil <- result.try(sqlight.close(connection))
  ran
}

// Every role with a key, in the fixed order.
fn all_pins() -> List(#(catalogue.PinnedRole, String)) {
  list.map(catalogue.pinned_roles, fn(role) {
    #(role, "key-" <> catalogue.pinned_role_name(role))
  })
}

pub fn pins_encode_in_the_fixed_role_order_test() {
  assert catalogue.encode_pins([]) == ""
  assert catalogue.encode_pins([#(catalogue.PinMain, "a")])
    == "{\"main\":\"a\"}"
  assert catalogue.encode_pins([
      #(catalogue.PinMain, "a"),
      #(catalogue.PinVision, "b"),
    ])
    == "{\"main\":\"a\",\"vision\":\"b\"}"
}

pub fn the_seven_pairs_with_longest_keys_fit_the_column_test() {
  let key = string.repeat("k", catalogue.model_key_limit)
  let pins = list.map(catalogue.pinned_roles, fn(role) { #(role, key) })
  let text = catalogue.encode_pins(pins)
  assert string.byte_size(text) <= catalogue.pins_limit
  assert catalogue.decode_pins(text) == Ok(pins)
}

pub fn decode_refuses_anything_but_the_canonical_object_test() {
  // Not an object, a name outside the closed set, a repeat, a misorder, an
  // empty key and an over-long key are all damage and never "no pins".
  list.each(
    [
      "null",
      "[]",
      "{}",
      "\"main\"",
      "{\"custom\":\"a\"}",
      "{\"main\":\"a\",\"main\":\"b\"}",
      "{\"vision\":\"a\",\"main\":\"b\"}",
      "{\"main\":\"\"}",
      "{\"main\":1}",
      "{\"main\":\"" <> string.repeat("k", 65) <> "\"}",
      "{\"main\": \"a\"}",
    ],
    fn(text) {
      assert catalogue.decode_pins(text) == Error(Nil)
    },
  )
}

pub fn pins_round_trip_for_any_subset_of_roles_test() {
  let subsets =
    qcheck.generic_list(
      elements_from: qcheck.bounded_int(from: 0, to: 1),
      length_from: qcheck.return(7),
    )

  qcheck.default_config()
  |> qcheck.with_test_count(500)
  |> qcheck.with_seed(qcheck.seed(1070))
  |> qcheck.run(subsets, fn(mask) {
    let pins =
      list.zip(catalogue.pinned_roles, mask)
      |> list.filter(fn(pair) { pair.1 == 1 })
      |> list.map(fn(pair) {
        #(pair.0, "model " <> catalogue.pinned_role_name(pair.0))
      })
    assert catalogue.decode_pins(catalogue.encode_pins(pins)) == Ok(pins)
  })
}

pub fn a_registration_keeps_every_pin_through_reads_and_a_restart_test() {
  let path = fresh_path("round-trip")
  let assert Ok(store) = catalogue.open(path) as "fresh catalogue opens"
  let pinned =
    catalogue.Registration(
      ..registration(1),
      profile: option.Some("deepseek"),
      pins: all_pins(),
    )
  assert catalogue.reserve(store, pinned) == Ok(pinned)
  assert catalogue.close(store) == Ok(Nil)

  let assert Ok(restored) = catalogue.open(path) as "catalogue reopens"
  assert catalogue.get(restored, pinned.id) == Ok(pinned)
  assert catalogue.by_request_key(restored, pinned.request_key) == Ok(pinned)
  let assert Ok(page) = catalogue.page(restored, after: "")
  assert page.records == [pinned]
  assert catalogue.close(restored) == Ok(Nil)
}

pub fn a_retry_must_repeat_its_pins_test() {
  let assert Ok(store) = catalogue.open(fresh_path("retry"))
    as "catalogue opens"
  let record =
    catalogue.Registration(..registration(2), pins: [
      #(catalogue.PinMain, "a"),
      #(catalogue.PinVision, "eyes"),
    ])
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.reserve(store, record) == Ok(record)

  // One more pin, one fewer, and another key are each a different request.
  let more =
    catalogue.Registration(
      ..record,
      pins: list.append(record.pins, [#(catalogue.PinRouter, "r")]),
    )
  let fewer =
    catalogue.Registration(..record, pins: [#(catalogue.PinMain, "a")])
  let other =
    catalogue.Registration(..record, pins: [
      #(catalogue.PinMain, "a"),
      #(catalogue.PinVision, "other"),
    ])
  assert catalogue.reserve(store, more) == Error(catalogue.Conflict)
  assert catalogue.reserve(store, fewer) == Error(catalogue.Conflict)
  assert catalogue.reserve(store, other) == Error(catalogue.Conflict)
  assert catalogue.close(store) == Ok(Nil)
}

pub fn a_write_of_misordered_repeated_or_oversized_pins_is_refused_test() {
  let assert Ok(store) = catalogue.open(fresh_path("refused"))
    as "catalogue opens"
  list.index_map(
    [
      [#(catalogue.PinVision, "a"), #(catalogue.PinMain, "b")],
      [#(catalogue.PinMain, "a"), #(catalogue.PinMain, "b")],
      [#(catalogue.PinMain, "")],
      [#(catalogue.PinMain, string.repeat("k", 65))],
    ],
    fn(pins, index) {
      let record = catalogue.Registration(..registration(10 + index), pins:)
      let assert Error(catalogue.Invalid(_)) = catalogue.reserve(store, record)
    },
  )
  assert catalogue.close(store) == Ok(Nil)
}

pub fn version_twenty_models_become_main_pins_test() {
  let path = fresh_path("migration")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let plain = registration(20)
  let pinned = catalogue.Registration(..registration(21), pins: [])
  assert catalogue.reserve(store, plain) == Ok(plain)
  assert catalogue.reserve(store, pinned) == Ok(pinned)
  assert catalogue.close(store) == Ok(Nil)

  // A version-twenty file holds the single `model` column of protocol-change
  // 080 and no `pins`; one session carries a model and one does not.
  let assert Ok(Nil) =
    raw(
      path,
      "ALTER TABLE catalogue_sessions ADD COLUMN model TEXT NOT NULL DEFAULT ''; ALTER TABLE catalogue_sessions DROP COLUMN pins; UPDATE catalogue_sessions SET model = 'eyes\"quoted' WHERE session_id = '"
        <> pinned.id
        <> "'; PRAGMA user_version=20",
    )
    |> result.replace_error(Nil)

  let assert Ok(migrated) = catalogue.open(path) as "version twenty migrates"
  assert catalogue.get(migrated, plain.id) == Ok(plain)
  assert catalogue.get(migrated, pinned.id)
    == Ok(
      catalogue.Registration(..pinned, pins: [
        #(catalogue.PinMain, "eyes\"quoted"),
      ]),
    )
  assert catalogue.close(migrated) == Ok(Nil)

  // The old column is gone, so nothing reads it again.
  let assert Ok(connection) = sqlight.open(path)
  let columns =
    sqlight.query(
      "SELECT name FROM pragma_table_info('catalogue_sessions') WHERE name IN ('model', 'pins')",
      on: connection,
      with: [],
      expecting: decode.at([0], decode.string),
    )
  assert sqlight.close(connection) == Ok(Nil)
  assert columns == Ok(["pins"])
}

pub fn a_damaged_pins_value_fails_the_read_test() {
  let path = fresh_path("damaged")
  let assert Ok(store) = catalogue.open(path) as "fixture catalogue opens"
  let record = catalogue.Registration(..registration(30), pins: all_pins())
  assert catalogue.reserve(store, record) == Ok(record)
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(Nil) =
    raw(path, "UPDATE catalogue_sessions SET pins = '{\"custom\":\"a\"}'")
    |> result.replace_error(Nil)

  let assert Ok(damaged) = catalogue.open(path) as "damaged catalogue opens"
  let assert Error(catalogue.Invalid(_)) = catalogue.get(damaged, record.id)
  assert catalogue.close(damaged) == Ok(Nil)
}

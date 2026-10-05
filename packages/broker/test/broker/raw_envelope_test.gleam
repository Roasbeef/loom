//// Raw transport extraction preserves header compatibility while leaving body
//// allocation to the boundary which owns that body. Header rejection and body
//// slicing are tested independently of terminal semantic validation.

import broker/framing
import core/msgpack
import core/report_value
import gleam/bit_array
import gleam/list
import gleam/option.{None}

fn field(key: String, value: BitArray) -> BitArray {
  let assert Ok(key) = msgpack.encode(msgpack.StringValue(key)) as "key encodes"
  <<key:bits, value:bits>>
}

fn payload(fields: List(BitArray)) -> BitArray {
  <<0x84, { bit_array.concat(fields) }:bits>>
}

fn fields(body: BitArray) -> List(BitArray) {
  [
    field("v", <<1>>),
    field("id", <<0>>),
    field("kind", <<0xa7, "outcome":utf8>>),
    field("body", body),
  ]
}

fn permutations(items: List(a)) -> List(List(a)) {
  case items {
    [] -> [[]]
    _ ->
      list.flat_map(
        list.index_map(items, fn(item, index) { #(item, index) }),
        fn(pair) {
          let others =
            items
            |> list.index_map(fn(item, index) { #(item, index) })
            |> list.filter(fn(item) { item.1 != pair.1 })
            |> list.map(fn(item) { item.0 })
          permutations(others) |> list.map(fn(rest) { [pair.0, ..rest] })
        },
      )
  }
}

pub fn all_header_orders_preserve_exact_success_and_failure_test() {
  let outcomes = [
    report_value.Completed(msgpack.BinaryValue(<<0, 255>>)),
    report_value.Errored(
      "failure",
      msgpack.MapValue([#(msgpack.IntValue(7), msgpack.FloatValue(1.0))]),
    ),
  ]
  list.each(outcomes, fn(outcome) {
    let assert Ok(body) = report_value.encode_terminal(outcome)
      as "terminal encodes"
    let orders = permutations(fields(body))
    assert list.length(orders) == 24
    list.each(orders, fn(order) {
      let assert Ok(raw) = framing.decode_raw_envelope(payload(order))
        as "header order accepted"
      assert framing.raw_kind(raw) == "outcome"
      assert framing.raw_body(raw) == body
      assert report_value.decode_terminal(framing.raw_body(raw)) == Ok(outcome)
    })
  })
}

pub fn nonminimal_header_encodings_remain_accepted_test() {
  let body = <<0x82, 0xa5, "value":utf8, 0, 0xa2, "ok":utf8, 0xc3>>
  let payload = <<
    0xdf,
    4:size(32),
    0xd9,
    1,
    "v":utf8,
    0xcf,
    1:size(64),
    0xda,
    2:size(16),
    "id":utf8,
    0xd3,
    0:size(64),
    0xdb,
    4:size(32),
    "kind":utf8,
    0xda,
    7:size(16),
    "outcome":utf8,
    0xd9,
    4,
    "body":utf8,
    body:bits,
  >>
  let assert Ok(raw) = framing.decode_raw_envelope(payload)
    as "nonminimal header accepted"
  assert framing.raw_body(raw) == body
  assert report_value.decode_terminal(body)
    == Ok(report_value.Completed(msgpack.IntValue(0)))
}

pub fn invalid_and_ambiguous_headers_are_rejected_test() {
  let body = <<0x80>>
  let valid = fields(body)
  let invalid = [
    <<0xc0>>,
    <<0x85, { bit_array.concat(valid) }:bits, { field("extra", <<0>>) }:bits>>,
    <<0x83, { bit_array.concat(list.drop(valid, 1)) }:bits>>,
    payload([field("v", <<2>>), ..list.drop(valid, 1)]),
    payload([
      field("v", <<1>>),
      field("id", <<0xff>>),
      field("kind", <<0xa7, "outcome":utf8>>),
      field("body", body),
    ]),
    payload([
      field("v", <<1>>),
      field("id", <<0xcb, 0:64>>),
      field("kind", <<0xa7, "outcome":utf8>>),
      field("body", body),
    ]),
    payload([field("v", <<0x90>>), ..list.drop(valid, 1)]),
    payload([
      field("v", <<1>>),
      field("id", <<0>>),
      field("kind", <<0x90>>),
      field("body", body),
    ]),
    payload([
      field("v", <<1>>),
      field("id", <<0>>),
      field("kind", <<0xa1, 255>>),
      field("body", body),
    ]),
    payload([<<0, 1>>, ..list.drop(valid, 1)]),
    payload([field("unknown", <<1>>), ..list.drop(valid, 1)]),
    <<{ payload(valid) }:bits, 0xc0>>,
    <<0x84, { bit_array.concat(list.take(valid, 3)) }:bits>>,
    <<0x84, { bit_array.concat(valid) }:bits, 1:size(1)>>,
  ]
  list.each(invalid, fn(bytes) {
    let assert Error(_) = framing.decode_raw_envelope(bytes)
      as "bad header rejected"
  })

  // Both classifier orders must remain ambiguous, rather than choosing a kind.
  list.each([#("outcome", "other"), #("other", "outcome")], fn(kinds) {
    let assert Ok(a) = msgpack.encode(msgpack.StringValue(kinds.0))
      as "kind encodes"
    let assert Ok(b) = msgpack.encode(msgpack.StringValue(kinds.1))
      as "kind encodes"
    let duplicate =
      payload([
        field("v", <<1>>),
        field("kind", a),
        field("kind", b),
        field("body", body),
      ])
    let assert Error(_) = framing.decode_raw_envelope(duplicate)
      as "duplicate kind refused"
  })
  list.each(["v", "id", "body"], fn(key) {
    let duplicate =
      payload([
        field("v", <<1>>),
        field("id", <<0>>),
        field(key, case key {
          "body" -> <<0x80>>
          _ -> <<1>>
        }),
        field(key, case key {
          "body" -> <<0x80>>
          _ -> <<1>>
        }),
      ])
    let assert Error(_) = framing.decode_raw_envelope(duplicate)
      as "duplicate required key refused"
  })
}

fn nested(depth: Int, acc: BitArray) -> BitArray {
  case depth {
    0 -> acc
    _ -> nested(depth - 1, <<0x91, acc:bits>>)
  }
}

pub fn envelope_spends_one_of_the_transport_depth_levels_test() {
  let assert Ok(raw) =
    framing.decode_raw_envelope(payload(fields(nested(255, <<0xc0>>))))
    as "255 body containers accepted"
  assert framing.raw_body(raw) == nested(255, <<0xc0>>)
  let assert Error(_) =
    framing.decode_raw_envelope(payload(fields(nested(256, <<0xc0>>))))
    as "256 body containers refused"
  let body = <<
    0x82,
    0xa2,
    "ok":utf8,
    0xc3,
    0xa5,
    "value":utf8,
    { nested(254, <<0xc0>>) }:bits,
  >>
  let assert Ok(raw) = framing.decode_raw_envelope(payload(fields(body)))
    as "full report depth accepted"
  let assert Ok(_) = report_value.decode_terminal(framing.raw_body(raw))
    as "full report depth decodes"
}

pub fn ordinary_capability_nodes_and_unknown_body_semantics_remain_unchanged_test() {
  let args = msgpack.ArrayValue(list.repeat(msgpack.NilValue, 70_000))
  let frame = framing.Frame(7, framing.CapCall(<<0>>, "test", args, 5))
  let assert Ok(bytes) = framing.encode_payload(frame)
    as "ordinary frame encodes"
  let assert Ok(raw) = framing.decode_raw_envelope(bytes)
    as "ordinary raw scan has no report node limit"
  assert framing.raw_kind(raw) == "cap_call"
  assert framing.decode_payload(bytes) == Ok(frame)
  list.each([<<0xc0>>, <<0x81, 0xa1, 255, 0>>, <<0x82, 0, 0, 0, 1>>], fn(body) {
    let bytes =
      payload([
        field("v", <<1>>),
        field("id", <<0>>),
        field("kind", <<0xa1, "x":utf8>>),
        field("body", body),
      ])
    let assert Ok(_) = framing.decode_raw_envelope(bytes)
      as "raw extraction promises only syntax"
    let assert Error(_) = framing.decode_payload(bytes)
      as "unknown body semantics still rejected"
  })
  let frame =
    framing.Frame(
      0,
      framing.CapResult(framing.CapOk(msgpack.IntValue(7)), None),
    )
  let assert Ok(bytes) = framing.encode_payload(frame) as "result encodes"
  let assert Ok(_) = framing.decode_raw_envelope(bytes)
    as "result raw extraction succeeds"
  assert framing.decode_payload(bytes) == Ok(frame)
}

import core/bounded_msgpack
import core/msgpack as mp
import gleam/bit_array
import gleam/list
import support/generate

pub fn string_byte_limit_test() {
  let bytes = <<0xda, 8192:size(16), 0:size(65_536)>>
  assert bounded_msgpack.decode(bytes) == mp.decode(bytes)
  let oversized = <<0xda, 8193:size(16), 0:size(65_544)>>
  let assert Ok(_) = mp.decode(oversized)
    as "The oversized string is valid MessagePack."
  let assert Error(_) = bounded_msgpack.decode(oversized)
    as "The fixed string byte limit refuses it."
}

pub fn binary_byte_limit_test() {
  let bytes = <<0xc6, 131_072:size(32), 0:size(1_048_576)>>
  assert bounded_msgpack.decode(bytes)
    == Ok(mp.BinaryValue(<<0:size(1_048_576)>>))
  let oversized = <<0xc6, 131_073:size(32), 0:size(1_048_584)>>
  let assert Ok(_) = mp.decode(oversized)
    as "The oversized binary is valid MessagePack."
  let assert Error(_) = bounded_msgpack.decode(oversized)
    as "The fixed binary byte limit refuses it."
}

pub fn total_byte_limit_overrides_individually_legal_binaries_test() {
  // Both payloads fit their own limit; only their enclosing frame exceeds it.
  let boundary = <<
    0x92,
    0xc6,
    131_072:size(32),
    0:size(1_048_576),
    0xc6,
    131_061:size(32),
    0:size(1_048_488),
  >>
  assert bit_array.byte_size(boundary) == 262_144
  assert bounded_msgpack.decode(boundary) == mp.decode(boundary)
  let oversized = <<
    0x92,
    0xc6,
    131_072:size(32),
    0:size(1_048_576),
    0xc6,
    131_062:size(32),
    0:size(1_048_496),
  >>
  assert bit_array.byte_size(oversized) == 262_145
  let assert Ok(_) = mp.decode(oversized)
    as "The oversized frame is valid MessagePack."
  let assert Error(_) = bounded_msgpack.decode(oversized)
    as "The complete frame has one byte too many."
  let assert Error(_) = bounded_msgpack.decode(<<>>)
    as "An empty frame contains no value."
}

pub fn container_element_and_entry_limits_test() {
  let items = list.repeat(mp.NilValue, 128)
  let assert Ok(payload) = mp.encode(mp.ArrayValue(items))
    as "The array boundary encodes."
  assert bounded_msgpack.decode(payload) == Ok(mp.ArrayValue(items))

  // Length width never changes the accepted count for arrays or maps.
  let body = <<0:size(1024)>>
  assert bounded_msgpack.decode(<<0xdd, 128:size(32), body:bits>>)
    == Ok(mp.ArrayValue(list.repeat(mp.IntValue(0), 128)))
  let assert Error(_) =
    bounded_msgpack.decode(<<0xdc, 129:size(16), 0:size(1032)>>)
    as "Array16 refuses 129 elements."
  let assert Error(_) =
    bounded_msgpack.decode(<<0xdd, 129:size(32), 0:size(1032)>>)
    as "Array32 refuses 129 elements."
  let pairs =
    list.map(generate.range(0, 127), fn(n) { #(mp.IntValue(n), mp.NilValue) })
  let assert Ok(<<0xde, _:size(16), entries:bits>>) =
    mp.encode(mp.MapValue(pairs))
    as "The map boundary uses map16."
  assert bounded_msgpack.decode(<<0xde, 128:size(16), entries:bits>>)
    == Ok(mp.MapValue(pairs))
  assert bounded_msgpack.decode(<<0xdf, 128:size(32), entries:bits>>)
    == Ok(mp.MapValue(pairs))
  let extra = <<0xcc, 128, 0xc0>>
  let assert Error(_) =
    bounded_msgpack.decode(<<0xde, 129:size(16), entries:bits, extra:bits>>)
    as "Map16 refuses 129 entries."
  let assert Error(_) =
    bounded_msgpack.decode(<<0xdf, 129:size(32), entries:bits, extra:bits>>)
    as "Map32 refuses 129 entries."
}

pub fn aggregate_node_budget_across_siblings_test() {
  // The root and sixteen child containers consume seventeen nodes themselves.
  // The leaf budget is shared across siblings, rather than reset per array.
  let boundary = sibling_arrays(111)
  let assert Ok(bytes) = mp.encode(boundary) as "The 2048-node tree encodes."
  assert bounded_msgpack.decode(bytes) == Ok(boundary)
  let oversized = sibling_arrays(112)
  let assert Ok(bytes) = mp.encode(oversized) as "The 2049-node tree encodes."
  assert mp.decode(bytes) == Ok(oversized)
  let assert Error(_) = bounded_msgpack.decode(bytes)
    as "Sibling arrays exceed the aggregate node budget."
}

pub fn depth_limit_test() {
  let boundary = nested(16, mp.NilValue)
  let assert Ok(bytes) = mp.encode(boundary)
    as "The depth-sixteen value encodes."
  assert bounded_msgpack.decode(bytes) == Ok(boundary)
  let assert Ok(bytes) = mp.encode(nested(17, mp.NilValue))
    as "The deeper value remains ordinary MessagePack."
  let assert Error(_) = bounded_msgpack.decode(bytes)
    as "A value at depth seventeen is refused."

  // An empty container still counts as a node, but has no deeper child.
  let boundary = nested(16, mp.ArrayValue([]))
  let assert Ok(bytes) = mp.encode(boundary)
    as "The deepest empty container encodes."
  assert bounded_msgpack.decode(bytes) == Ok(boundary)
  let assert Ok(bytes) = mp.encode(nested(17, mp.ArrayValue([])))
    as "The deeper empty container encodes."
  let assert Error(_) = bounded_msgpack.decode(bytes)
    as "An empty container at depth seventeen is refused."
}

pub fn truncated_lengths_and_scalar_payloads_test() {
  let cases = [
    <<0xd9>>,
    <<0xda, 0>>,
    <<0xdb, 0, 0, 0>>,
    <<0xc4>>,
    <<0xc5, 0>>,
    <<0xc6, 0, 0, 0>>,
    <<0xdc, 0>>,
    <<0xdd, 0, 0, 0>>,
    <<0xde, 0>>,
    <<0xdf, 0, 0, 0>>,
    <<0xda, 8192:size(16), 1>>,
    <<0xc6, 131_072:size(32), 1>>,
    <<0xdd, 128:size(32), 0xc0>>,
    <<0xdf, 128:size(32), 0xc0>>,
    <<0xcc>>,
    <<0xd0>>,
    <<0xcd, 0>>,
    <<0xd1, 0>>,
    <<0xce, 0>>,
    <<0xd2, 0>>,
    <<0xcf, 0>>,
    <<0xd3, 0>>,
    <<0xcb, 0>>,
  ]
  list.each(cases, fn(bytes) {
    let assert Error(_) = bounded_msgpack.decode(bytes)
      as "Incomplete headers and payloads are refused."
  })
  let assert Ok(bytes) = mp.encode(nested(16, mp.NilValue))
    as "The deep complete value encodes."
  let assert Ok(truncated) =
    bit_array.slice(bytes, 0, bit_array.byte_size(bytes) - 1)
    as "Only the final leaf is removed."
  let assert Error(_) = bounded_msgpack.decode(truncated)
    as "A deep missing leaf is refused."
}

pub fn semantic_corruption_and_unsupported_tags_test() {
  let cases = [
    <<0xc1>>,
    <<0xc7>>,
    <<0xc8>>,
    <<0xc9>>,
    <<0xca>>,
    <<0xd4>>,
    <<0xd5>>,
    <<0xd6>>,
    <<0xd7>>,
    <<0xd8>>,
    <<0xc0, 0xc0>>,
    <<0xc0, 1:size(1)>>,
    <<1:size(1)>>,
    <<0xa1, 0xff>>,
    <<0x82, 1, 0, 1, 1>>,
    <<0xcb, 0x7ff0000000000000:size(64)>>,
    <<0xcb, 0xfff0000000000000:size(64)>>,
    <<0xcb, 0x7ff8000000000001:size(64)>>,
  ]
  list.each(cases, fn(bytes) {
    let assert Error(_) = bounded_msgpack.decode(bytes)
      as "Malformed data remains a total refusal."
  })
}

pub fn valid_subset_matches_ordinary_decoder_test() {
  list.each(generate.range(1, 100), fn(n) {
    let #(value, _) = generate.msgpack_value(generate.seed(n), 4)
    let assert Ok(bytes) = mp.encode(value)
      as "The bounded generated value encodes."
    assert bounded_msgpack.decode(bytes) == Ok(value)
  })

  // Noncanonical length widths are valid input; canonicality belongs to encoding.
  assert bounded_msgpack.decode(<<0xdb, 1:size(32), "x":utf8>>)
    == Ok(mp.StringValue("x"))
  assert bounded_msgpack.decode(<<0xc6, 1:size(32), 7>>)
    == Ok(mp.BinaryValue(<<7>>))
}

fn sibling_arrays(last_count: Int) -> mp.MsgPackValue {
  mp.ArrayValue([
    mp.ArrayValue(list.repeat(mp.NilValue, last_count)),
    ..list.repeat(mp.ArrayValue(list.repeat(mp.NilValue, 128)), 15)
  ])
}

fn nested(depth: Int, leaf: mp.MsgPackValue) -> mp.MsgPackValue {
  case depth {
    0 -> leaf
    _ -> nested(depth - 1, mp.ArrayValue([leaf]))
  }
}

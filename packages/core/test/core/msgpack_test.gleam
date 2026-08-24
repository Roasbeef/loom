import core/msgpack
import gleam/bit_array
import gleam/list
import support/generate

// --- golden vectors -----------------------------------------------------
//
// Hand-computed canonical byte sequences, asserted byte-exact in both
// directions. The same vectors are stored as files under
// protocol/msgpack-fixtures/ for cross-language conformance (ADR-003).

fn golden(value: msgpack.MsgPackValue, bytes: BitArray) -> Nil {
  assert msgpack.encode(value) == Ok(bytes)
  assert msgpack.decode(bytes) == Ok(value)
  Nil
}

pub fn golden_nil_test() {
  golden(msgpack.NilValue, <<0xc0>>)
}

pub fn golden_bools_test() {
  golden(msgpack.BoolValue(False), <<0xc2>>)
  golden(msgpack.BoolValue(True), <<0xc3>>)
}

pub fn golden_positive_fixint_test() {
  golden(msgpack.IntValue(0), <<0x00>>)
  golden(msgpack.IntValue(1), <<0x01>>)
  golden(msgpack.IntValue(127), <<0x7f>>)
}

pub fn golden_negative_fixint_test() {
  golden(msgpack.IntValue(-1), <<0xff>>)
  golden(msgpack.IntValue(-32), <<0xe0>>)
}

pub fn golden_uint_widths_test() {
  golden(msgpack.IntValue(128), <<0xcc, 0x80>>)
  golden(msgpack.IntValue(255), <<0xcc, 0xff>>)
  golden(msgpack.IntValue(256), <<0xcd, 0x01, 0x00>>)
  golden(msgpack.IntValue(65_535), <<0xcd, 0xff, 0xff>>)
  golden(msgpack.IntValue(65_536), <<0xce, 0x00, 0x01, 0x00, 0x00>>)
  golden(msgpack.IntValue(4_294_967_295), <<0xce, 0xff, 0xff, 0xff, 0xff>>)
  golden(msgpack.IntValue(4_294_967_296), <<
    0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
  >>)
  golden(msgpack.IntValue(18_446_744_073_709_551_615), <<
    0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
  >>)
}

pub fn golden_int_widths_test() {
  golden(msgpack.IntValue(-33), <<0xd0, 0xdf>>)
  golden(msgpack.IntValue(-128), <<0xd0, 0x80>>)
  golden(msgpack.IntValue(-129), <<0xd1, 0xff, 0x7f>>)
  golden(msgpack.IntValue(-32_768), <<0xd1, 0x80, 0x00>>)
  golden(msgpack.IntValue(-32_769), <<0xd2, 0xff, 0xff, 0x7f, 0xff>>)
  golden(msgpack.IntValue(-2_147_483_648), <<0xd2, 0x80, 0x00, 0x00, 0x00>>)
  golden(msgpack.IntValue(-2_147_483_649), <<
    0xd3, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff,
  >>)
  golden(msgpack.IntValue(-9_223_372_036_854_775_808), <<
    0xd3, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  >>)
}

pub fn golden_float_test() {
  golden(msgpack.FloatValue(1.5), <<
    0xcb, 0x3f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  >>)
  golden(msgpack.FloatValue(-2.0), <<
    0xcb, 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  >>)
}

pub fn golden_fixstr_test() {
  golden(msgpack.StringValue(""), <<0xa0>>)
  golden(msgpack.StringValue("hello"), <<0xa5, "hello":utf8>>)
  golden(msgpack.StringValue("héllo"), <<0xa6, "héllo":utf8>>)
}

pub fn golden_str8_test() {
  // 32 characters: one past the fixstr limit.
  let text = "abcdefghijklmnopqrstuvwxyzabcdef"
  golden(msgpack.StringValue(text), <<0xd9, 0x20, text:utf8>>)
}

pub fn golden_bin_test() {
  golden(msgpack.BinaryValue(<<>>), <<0xc4, 0x00>>)
  golden(msgpack.BinaryValue(<<1, 2, 3>>), <<0xc4, 0x03, 1, 2, 3>>)
}

pub fn golden_fixarray_test() {
  golden(msgpack.ArrayValue([]), <<0x90>>)
  golden(
    msgpack.ArrayValue([
      msgpack.IntValue(1),
      msgpack.IntValue(2),
      msgpack.IntValue(3),
    ]),
    <<0x93, 0x01, 0x02, 0x03>>,
  )
}

pub fn golden_array16_test() {
  // 16 elements: one past the fixarray limit.
  let items = list.map(generate.range(0, 15), msgpack.IntValue)
  golden(msgpack.ArrayValue(items), <<
    0xdc, 0x00, 0x10, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
    0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
  >>)
}

pub fn golden_fixmap_test() {
  golden(msgpack.MapValue([]), <<0x80>>)
  golden(msgpack.MapValue([#(msgpack.StringValue("a"), msgpack.IntValue(1))]), <<
    0x81,
    0xa1,
    "a":utf8,
    0x01,
  >>)
}

pub fn golden_nested_test() {
  // {"k": [nil, true, -1]}
  golden(
    msgpack.MapValue([
      #(
        msgpack.StringValue("k"),
        msgpack.ArrayValue([
          msgpack.NilValue,
          msgpack.BoolValue(True),
          msgpack.IntValue(-1),
        ]),
      ),
    ]),
    <<0x81, 0xa1, "k":utf8, 0x93, 0xc0, 0xc3, 0xff>>,
  )
}

// --- boundary widths beyond the goldens ---------------------------------

pub fn str16_and_bin16_roundtrip_test() {
  // 256 bytes: one past the str8/bin8 limit.
  let text = repeat_string("x", 256)
  let assert Ok(<<0xda, 0x01, 0x00, _:bytes>>) =
    msgpack.encode(msgpack.StringValue(text))
  roundtrip(msgpack.StringValue(text))

  let #(bytes, _seed) = generate.byte_array(generate.seed(1), 256)
  let assert Ok(<<0xc5, 0x01, 0x00, _:bytes>>) =
    msgpack.encode(msgpack.BinaryValue(bytes))
  roundtrip(msgpack.BinaryValue(bytes))
}

pub fn map16_roundtrip_test() {
  // 16 entries: one past the fixmap limit.
  let entries =
    list.map(generate.range(0, 15), fn(n) {
      #(msgpack.IntValue(n), msgpack.IntValue(n))
    })
  let assert Ok(<<0xde, 0x00, 0x10, _:bytes>>) =
    msgpack.encode(msgpack.MapValue(entries))
  roundtrip(msgpack.MapValue(entries))
}

fn repeat_string(char: String, times: Int) -> String {
  list.fold(generate.range(1, times), from: "", with: fn(acc, _) { acc <> char })
}

// --- encode errors ------------------------------------------------------

pub fn encode_rejects_out_of_range_integers_test() {
  assert msgpack.encode(msgpack.IntValue(18_446_744_073_709_551_616))
    == Error(msgpack.IntegerOutOfRange(18_446_744_073_709_551_616))
  assert msgpack.encode(msgpack.IntValue(-9_223_372_036_854_775_809))
    == Error(msgpack.IntegerOutOfRange(-9_223_372_036_854_775_809))
}

pub fn encode_rejects_ragged_binary_test() {
  let assert Error(msgpack.UnencodableLength(_)) =
    msgpack.encode(msgpack.BinaryValue(<<1:size(3)>>))
}

// --- duplicate map keys -------------------------------------------------

pub fn decode_rejects_duplicate_map_keys_test() {
  // {"a": 1, "a": 2}: a duplicated key has no single meaning across
  // decoders (first- versus last-occurrence precedence), so decode
  // refuses to pick one.
  let assert Error(_report) =
    msgpack.decode(<<0x82, 0xa1, "a":utf8, 0x01, 0xa1, "a":utf8, 0x02>>)
  // Non-string keys compare structurally: {0: nil, 0: nil}.
  let assert Error(_report) = msgpack.decode(<<0x82, 0x00, 0xc0, 0x00, 0xc0>>)
  // A duplicate inside a nested map is rejected the same way.
  let assert Error(_report) =
    msgpack.decode(<<
      0x81, 0xa1, "k":utf8, 0x82, 0xa1, "a":utf8, 0x01, 0xa1, "a":utf8, 0x02,
    >>)
  // The same key in two different maps is fine.
  let assert Ok(_) =
    msgpack.decode(<<
      0x82, 0xa1, "x":utf8, 0x81, 0xa1, "a":utf8, 0x01, 0xa1, "y":utf8, 0x81,
      0xa1, "a":utf8, 0x02,
    >>)
}

// --- nesting depth ------------------------------------------------------

// `count` one-element array headers wrapping an empty array: nesting
// depth `count + 1`.
fn nested_arrays(count: Int) -> BitArray {
  list.fold(generate.range(1, count), from: <<0x90>>, with: fn(inner, _) {
    <<0x91, inner:bits>>
  })
}

pub fn decode_depth_at_bound_still_decodes_test() {
  let assert Ok(_value) = msgpack.decode(nested_arrays(msgpack.max_depth - 1))
  // Maps at the bound too: {"k": {"k": ... {}}}.
  let nested_maps =
    list.fold(
      generate.range(1, msgpack.max_depth - 1),
      from: <<0x80>>,
      with: fn(inner, _) { <<0x81, 0xa1, "k":utf8, inner:bits>> },
    )
  let assert Ok(_value) = msgpack.decode(nested_maps)
}

pub fn decode_depth_past_bound_rejected_test() {
  let assert Error(_report) = msgpack.decode(nested_arrays(msgpack.max_depth))
  let nested_maps =
    list.fold(
      generate.range(1, msgpack.max_depth),
      from: <<0x80>>,
      with: fn(inner, _) { <<0x81, 0xa1, "k":utf8, inner:bits>> },
    )
  let assert Error(_report) = msgpack.decode(nested_maps)
  // Far past the bound — thousands of one-byte fixarray headers, the
  // cheap adversarial shape — is refused in-band, not by exhausting the
  // decoder.
  let deep = bit_array.concat(list.repeat(<<0x91>>, times: 100_000))
  let assert Error(_report) = msgpack.decode(deep)
}

// --- roundtrip properties -----------------------------------------------

fn roundtrip(value: msgpack.MsgPackValue) -> Nil {
  let assert Ok(bytes) = msgpack.encode(value)
  assert msgpack.decode(bytes) == Ok(value)
  Nil
}

pub fn roundtrip_property_test() {
  roundtrip_loop(generate.seed(31), 200)
}

fn roundtrip_loop(seed: generate.Seed, remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let #(value, seed) = generate.msgpack_value(seed, 4)
      roundtrip(value)
      roundtrip_loop(seed, remaining - 1)
    }
  }
}

pub fn roundtrip_unicode_strings_test() {
  let seed = generate.seed(32)
  let #(texts, _seed) = generate.list_of(seed, 100, generate.small_string)
  list.each(texts, fn(text) { roundtrip(msgpack.StringValue(text)) })
}

// --- adversarial inputs -------------------------------------------------

pub fn adversarial_corpus_test() {
  let corpus = [
    // empty input
    <<>>,
    // truncated multi-byte integers
    <<0xcc>>,
    <<0xcd, 0x01>>,
    <<0xce, 0x00, 0x01>>,
    <<0xcf, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>,
    <<0xd0>>,
    <<0xd3, 0xff>>,
    // truncated float
    <<0xcb, 0x3f, 0xf8>>,
    // NaN float64: the BEAM cannot represent it
    <<0xcb, 0x7f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01>>,
    // positive infinity float64
    <<0xcb, 0x7f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>,
    // str with missing payload bytes
    <<0xa5, "hi":utf8>>,
    <<0xd9, 0x05, "hi":utf8>>,
    <<0xda, 0x00, 0x05, "hi":utf8>>,
    // str with invalid utf-8 payload
    <<0xa2, 0xff, 0xfe>>,
    // bin with missing payload bytes
    <<0xc4, 0x04, 0x01>>,
    // array announcing more items than present
    <<0x92, 0x01>>,
    <<0xdc, 0x00, 0x03, 0x01>>,
    // map with a key but no value
    <<0x81, 0xa1, "a":utf8>>,
    <<0xde, 0x00, 0x02, 0x00, 0x00, 0x00>>,
    // the never-used byte
    <<0xc1>>,
    // float32 is outside the supported subset
    <<0xca, 0x3f, 0xc0, 0x00, 0x00>>,
    // ext family is outside the supported subset
    <<0xc7, 0x01, 0x00, 0xff>>,
    <<0xd4, 0x01, 0xff>>,
    <<0xd8, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff>>,
    // trailing bytes after a complete value
    <<0xc0, 0x00>>,
    <<0x01, 0x02>>,
    // non-byte-aligned input
    <<1:size(3)>>,
    <<0xc0, 1:size(3)>>,
    // duplicated map keys, string and integer
    <<0x82, 0xa1, "a":utf8, 0x01, 0xa1, "a":utf8, 0x02>>,
    <<0x82, 0x07, 0xc0, 0x07, 0xc0>>,
    // containers nested past the depth bound
    nested_arrays(msgpack.max_depth),
    bit_array.concat(list.repeat(<<0x91>>, times: 50_000)),
  ]
  list.each(corpus, fn(bytes) {
    let assert Error(_report) = msgpack.decode(bytes)
  })
}

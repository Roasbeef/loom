import core/bounded_msgpack
import core/clock
import core/ids
import core/internal/msgpack_scan
import core/msgpack as mp
import core/report_value as rv
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

fn empty_log() -> rv.CallLog {
  rv.CallLog(0, 0, 0, 0, 0, 0, [])
}

fn metadata() -> rv.Metadata {
  let assert Ok(metadata) =
    rv.metadata(
      "sha256-" <> digest,
      rv.Enforcement(
        rv.Unreported("not launched"),
        rv.Reported(["filesystem"], ["network"], rv.Degraded),
      ),
      empty_log(),
    )
    as "The fixture observations meet the fixed metadata contract."
  metadata
}

fn wrap(value: mp.MsgPackValue) -> BitArray {
  let assert Ok(bytes) =
    mp.encode(
      mp.MapValue([
        #(mp.StringValue("ok"), mp.BoolValue(True)),
        #(mp.StringValue("value"), value),
      ]),
    )
    as "The fixture is MessagePack encodable."
  bytes
}

fn complete(terminal: BitArray, metadata: BitArray) -> BitArray {
  <<
    "LOOMRV01":utf8,
    bit_array.byte_size(terminal):size(32),
    bit_array.byte_size(metadata):size(32),
    terminal:bits,
    metadata:bits,
  >>
}

fn segments(bytes: BitArray) -> #(BitArray, BitArray) {
  let assert <<
    "LOOMRV01":utf8,
    t:size(32),
    m:size(32),
    terminal:bytes-size(t),
    metadata:bytes-size(m),
  >> = bytes
    as "The fixture has an exact bundle header."
  #(terminal, metadata)
}

pub fn fidelity_and_typed_metadata_roundtrip_test() {
  let value =
    mp.MapValue([
      #(mp.IntValue(3), mp.BinaryValue(<<0, 255>>)),
      #(mp.FloatValue(3.0), mp.ArrayValue([mp.IntValue(1), mp.FloatValue(1.0)])),
      #(mp.BinaryValue(<<0>>), mp.StringValue("a\u{0000}b")),
    ])
  let log =
    rv.CallLog(1, 9, 4, 1, 1, 1, [
      rv.CallRecord("fs.read", Some("path"), rv.CallOk, None, 0, 1),
      rv.CallRecord("fs.write", None, rv.CallFailed, Some("refused"), 1, 2),
      rv.CallRecord("process.exec", None, rv.CallCancelled, None, 2, 3),
      rv.CallRecord("mcp.tool", Some(""), rv.CallUnsettled, Some(""), 3, 4),
    ])
  // Complete preserves the producer flag even when it has skipped layers.
  let enforcement =
    rv.Enforcement(
      rv.Reported(["fs"], ["net"], rv.Complete),
      rv.Unreported("missing"),
    )
  let assert Ok(meta) = rv.metadata("sha256-" <> digest, enforcement, log)
    as "All distinctions in the fixture are valid metadata."
  let assert Ok(report) = rv.from_outcome(rv.Completed(value), meta)
    as "The complete outcome is within the report profile."
  let assert Ok(decoded) = rv.decode(rv.bytes(report))
    as "The canonical report decodes."
  assert decoded == report
  assert rv.outcome(decoded) == rv.Completed(value)
  assert rv.calls(rv.report_metadata(decoded)) == log
  assert rv.enforcement(rv.report_metadata(decoded)) == enforcement
  assert rv.manifest_hash(rv.report_metadata(decoded)) == "sha256-" <> digest
}

pub fn controlled_error_roundtrip_test() {
  let error =
    rv.Errored(
      "full\u{0000}message",
      mp.MapValue([
        #(mp.BinaryValue(<<255>>), mp.IntValue(42)),
      ]),
    )
  let assert Ok(report) = rv.from_outcome(error, metadata())
    as "Error messages and binary details are complete program data."
  assert rv.decode(rv.bytes(report)) == Ok(report)
  assert rv.outcome(report) == error
}

pub fn exact_terminal_byte_ceiling_large_nul_scalar_test() {
  // The canonical Outcome header costs eleven bytes; str32 costs five more.
  let payload = rv.max_terminal_bytes - 16
  let raw = <<
    0x82,
    0xa2,
    "ok":utf8,
    0xc3,
    0xa5,
    "value":utf8,
    0xdb,
    payload:size(32),
    0:size(
      payload
      * 8
    ),
  >>
  assert bit_array.byte_size(raw) == rv.max_terminal_bytes
  let assert Ok(outcome) = rv.decode_terminal(raw)
    as "A near-16-MiB NUL scalar is admitted without any JSON expansion."
  assert rv.encode_terminal(outcome) == Ok(raw)
  let assert Ok(report) = rv.complete(raw, metadata())
    as "Complete custody accepts the same original terminal profile."
  assert rv.decode(rv.bytes(report)) == Ok(report)
  let oversized = <<
    0x82,
    0xa2,
    "ok":utf8,
    0xc3,
    0xa5,
    "value":utf8,
    0xdb,
    { payload + 1 }:size(32),
    0:size(
      { payload + 1 }
      * 8
    ),
  >>
  assert rv.decode_terminal(oversized) |> result.is_error
  assert rv.encode_terminal(
      rv.Completed(mp.StringValue(string.repeat("\u{0000}", payload + 1))),
    )
    |> result.is_error
}

pub fn exact_shared_node_budget_across_siblings_test() {
  // Outcome and its array use five nodes, including both map keys.
  let at = wrap(mp.ArrayValue(list.repeat(mp.NilValue, 65_531)))
  assert rv.decode_terminal(at) |> result.is_ok
  assert rv.encode_terminal(
      rv.Completed(mp.ArrayValue(list.repeat(mp.NilValue, 65_531))),
    )
    == Ok(at)
  assert rv.decode_terminal(
      wrap(mp.ArrayValue(list.repeat(mp.NilValue, 65_532))),
    )
    |> result.is_error
  let siblings =
    mp.ArrayValue([
      mp.ArrayValue(list.repeat(mp.NilValue, 32_764)),
      mp.ArrayValue(list.repeat(mp.NilValue, 32_764)),
    ])
  assert rv.decode_terminal(wrap(siblings)) |> result.is_ok
  let excess =
    mp.ArrayValue([
      mp.ArrayValue(list.repeat(mp.NilValue, 32_765)),
      mp.ArrayValue(list.repeat(mp.NilValue, 32_765)),
    ])
  assert rv.decode_terminal(wrap(excess)) |> result.is_error
  assert rv.encode_terminal(rv.Completed(excess)) |> result.is_error
}

fn nest(value: mp.MsgPackValue, depth: Int) -> mp.MsgPackValue {
  case depth {
    0 -> value
    _ -> nest(mp.ArrayValue([value]), depth - 1)
  }
}

pub fn value_depth_254_and_first_excess_test() {
  let at = nest(mp.NilValue, 254)
  assert rv.decode_terminal(wrap(at)) |> result.is_ok
  assert rv.encode_terminal(rv.Completed(at)) == Ok(wrap(at))
  let excess = nest(mp.NilValue, 255)
  assert rv.decode_terminal(wrap(excess)) |> result.is_error
  assert rv.encode_terminal(rv.Completed(excess)) |> result.is_error
  // An empty leaf container still consumes a container level.
  let empty_excess = nest(mp.ArrayValue([]), 254)
  assert rv.decode_terminal(wrap(empty_excess)) |> result.is_error
  assert rv.encode_terminal(rv.Completed(empty_excess)) |> result.is_error
}

pub fn map_keys_consume_shared_nodes_test() {
  let pairs =
    list.repeat(Nil, 32_765)
    |> list.index_map(fn(_, i) { #(mp.IntValue(i + 1), mp.NilValue) })
  let at = mp.MapValue(pairs)
  assert rv.decode_terminal(wrap(at)) |> result.is_ok
  assert rv.encode_terminal(rv.Completed(at)) |> result.is_ok
  let excess = mp.MapValue([#(mp.IntValue(0), mp.NilValue), ..pairs])
  assert rv.decode_terminal(wrap(excess)) |> result.is_error
  assert rv.encode_terminal(rv.Completed(excess)) |> result.is_error
}

pub fn raw_container_limits_and_native_profile_unchanged_test() {
  let array = <<0xdc, 129:size(16), 0:size(129 * 8)>>
  assert bounded_msgpack.decode(array) |> result.is_error
  assert msgpack_scan.terminal(array) |> result.is_ok
  let native_at = <<0xdc, 128:size(16), 0:size(128 * 8)>>
  assert bounded_msgpack.decode(native_at) |> result.is_ok
  assert msgpack_scan.metadata(array) |> result.is_error
  assert msgpack_scan.terminal(<<0xdd, 65_537:size(32)>>) |> result.is_error
  assert msgpack_scan.terminal(<<0xdf, 32_769:size(32)>>) |> result.is_error
  assert msgpack_scan.terminal(<<0xdb, 16_777_217:size(32)>>) |> result.is_error
}

pub fn alternate_encodings_are_not_complete_reports_test() {
  let prefix = <<0x82, 0xa2, "ok":utf8, 0xc3, 0xa5, "value":utf8>>
  let alternatives = [
    <<0xcc, 1>>,
    <<0xcd, 128:size(16)>>,
    <<0xce, 256:size(32)>>,
    <<0xcf, 65_536:size(64)>>,
    <<0xd0, -1:size(8)>>,
    <<0xd1, -33:size(16)>>,
    <<0xd2, -129:size(32)>>,
    <<0xd3, -32_769:size(64)>>,
    <<0xd9, 1, "x":utf8>>,
    <<0xda, 32:size(16), 0:size(256)>>,
    <<0xdb, 256:size(32), 0:size(2048)>>,
    <<0xc5, 1:size(16), 0>>,
    <<0xc6, 256:size(32), 0:size(2048)>>,
    <<0xdc, 1:size(16), 0xc0>>,
    <<0xdd, 16:size(32), 0:size(128)>>,
    <<0xde, 1:size(16), 0, 0>>,
    <<
      0xdf,
      16:size(32),
      0,
      0,
      1,
      0,
      2,
      0,
      3,
      0,
      4,
      0,
      5,
      0,
      6,
      0,
      7,
      0,
      8,
      0,
      9,
      0,
      10,
      0,
      11,
      0,
      12,
      0,
      13,
      0,
      14,
      0,
      15,
      0,
    >>,
  ]
  list.each(alternatives, fn(value) {
    let raw = <<prefix:bits, value:bits>>
    assert mp.decode(raw) |> result.is_ok
    assert rv.decode_terminal(raw) |> result.is_error
  })
}

pub fn malformed_and_nonfinite_terminals_test() {
  let prefix = <<0x82, 0xa2, "ok":utf8, 0xc3, 0xa5, "value":utf8>>
  list.each(
    [
      <<0xc1>>,
      <<0xca, 0:size(32)>>,
      <<0xc7, 0, 0>>,
      <<0xd4, 0, 0>>,
      <<0xcb, 0x7ff0000000000000:size(64)>>,
      <<0xcb, 0xfff0000000000000:size(64)>>,
      <<0xcb, 0x7ff8000000000001:size(64)>>,
      <<0xa1, 0xff>>,
      <<0xd9>>,
      <<0xdb, 0xffffffff:size(32)>>,
      <<0x82, 0, 0, 0, 1>>,
    ],
    fn(value) {
      assert rv.decode_terminal(<<prefix:bits, value:bits>>) |> result.is_error
    },
  )
  assert rv.decode_terminal(<<prefix:bits, 0xc0, 0xc0>>) |> result.is_error
  assert rv.decode_terminal(<<prefix:bits, 0xc0, 1:size(1)>>) |> result.is_error
  assert rv.encode_terminal(rv.Completed(mp.BinaryValue(<<1:size(1)>>)))
    |> result.is_error
  assert rv.encode_terminal(
      rv.Completed(
        mp.MapValue([
          #(mp.NilValue, mp.IntValue(1)),
          #(mp.NilValue, mp.IntValue(2)),
        ]),
      ),
    )
    |> result.is_error
  assert rv.encode_terminal(
      rv.Completed(mp.IntValue(18_446_744_073_709_551_616)),
    )
    |> result.is_error
}

pub fn bundle_header_and_closed_outcome_tests_test() {
  let assert Ok(report) = rv.from_outcome(rv.Completed(mp.NilValue), metadata())
    as "The baseline bundle is valid."
  let bytes = rv.bytes(report)
  let #(terminal, meta) = segments(bytes)
  list.each(
    [
      <<>>,
      <<"LOOMRV00":utf8, 0:size(64)>>,
      <<"LOOMRV01":utf8, 0:size(32), 1:size(32), 0>>,
      <<"LOOMRV01":utf8, 16_777_217:size(32), 1:size(32)>>,
      <<"LOOMRV01":utf8, 1:size(32), 262_145:size(32)>>,
      <<"LOOMRV01":utf8, 0xffffffff:size(32), 0xffffffff:size(32)>>,
      <<"LOOMRV01":utf8, 12:size(32), 1:size(32), 0>>,
      <<bytes:bits, 0>>,
      <<bytes:bits, 1:size(1)>>,
      complete(terminal, <<0xc0>>),
      complete(<<0xc0>>, meta),
    ],
    fn(bad) {
      assert rv.decode(bad) |> result.is_error
    },
  )
  list.each(
    [
      mp.MapValue([#(mp.StringValue("ok"), mp.IntValue(1))]),
      mp.MapValue([#(mp.StringValue("ok"), mp.BoolValue(True))]),
      mp.MapValue([
        #(mp.StringValue("ok"), mp.BoolValue(False)),
        #(mp.StringValue("message"), mp.IntValue(1)),
        #(mp.StringValue("details"), mp.NilValue),
      ]),
    ],
    fn(value) {
      let assert Ok(raw) = mp.encode(value)
        as "The malformed shape is valid MessagePack."
      assert rv.decode_terminal(raw) |> result.is_error
    },
  )
}

pub fn bounded_call_metadata_and_counter_relationships_test() {
  let record =
    rv.CallRecord(
      string.repeat("c", 64),
      Some(string.repeat("a", 96)),
      rv.CallFailed,
      Some(string.repeat("e", 48)),
      18_446_744_073_709_551_615,
      18_446_744_073_709_551_615,
    )
  let log =
    rv.CallLog(
      18_446_744_073_709_551_615,
      18_446_744_073_709_551_615,
      128,
      128,
      0,
      0,
      list.repeat(record, 128),
    )
  let enforcement =
    rv.Enforcement(rv.Unreported(string.repeat("r", 8192)), rv.Unreported(""))
  assert rv.metadata("sha256-" <> digest, enforcement, log) |> result.is_ok
  list.each(
    [
      rv.CallLog(
        ..log,
        items: list.repeat(record, 129),
        total: 129,
        failed: 129,
      ),
      rv.CallLog(..log, total: 127),
      rv.CallLog(..log, cancelled: 1),
      rv.CallLog(..log, failed: -1),
      rv.CallLog(..log, started_unix_ms: -1),
      rv.CallLog(..log, elapsed_ms: 18_446_744_073_709_551_616),
      rv.CallLog(..log, items: [
        rv.CallRecord(..record, cap: string.repeat("c", 65)),
      ]),
      rv.CallLog(..log, items: [
        rv.CallRecord(..record, args: Some(string.repeat("a", 97))),
      ]),
      rv.CallLog(..log, items: [
        rv.CallRecord(..record, error: Some(string.repeat("e", 49))),
      ]),
      rv.CallLog(..log, items: [rv.CallRecord(..record, start_ms: -1)]),
      rv.CallLog(..log, items: [rv.CallRecord(..record, duration_ms: -1)]),
    ],
    fn(log) {
      assert rv.metadata("sha256-" <> digest, enforcement, log)
        |> result.is_error
    },
  )
  assert rv.metadata(string.repeat("a", 65), enforcement, empty_log())
    |> result.is_error
  assert rv.metadata(string.repeat("A", 64), enforcement, empty_log())
    |> result.is_error
  assert rv.metadata(
      "sha256-" <> digest,
      rv.Enforcement(rv.Unreported(string.repeat("r", 8193)), rv.Unreported("")),
      empty_log(),
    )
    |> result.is_error
}

pub fn exact_stage_byte_and_combined_entry_limits_test() {
  let layer = string.repeat("x", 8192)
  let at =
    rv.Reported(list.repeat(layer, 7), [string.repeat("x", 8118)], rv.Complete)
  // Seven maximum strings plus the final string and fixed schema cost 65,536.
  let assert Ok(meta) =
    rv.metadata(
      "sha256-" <> digest,
      rv.Enforcement(at, rv.Unreported("")),
      empty_log(),
    )
    as "The stage is exactly at its canonical byte ceiling."
  let assert Ok(report) = rv.from_outcome(rv.Completed(mp.NilValue), meta)
    as "A bounded stage is complete owner metadata."
  assert rv.decode(rv.bytes(report)) == Ok(report)
  let excess =
    rv.Reported(list.repeat(layer, 7), [string.repeat("x", 8119)], rv.Complete)
  assert rv.metadata(
      "sha256-" <> digest,
      rv.Enforcement(excess, rv.Unreported("")),
      empty_log(),
    )
    |> result.is_error
  assert rv.metadata(
      "sha256-" <> digest,
      rv.Enforcement(
        rv.Reported(list.repeat("", 64), list.repeat("", 64), rv.Complete),
        rv.Unreported(""),
      ),
      empty_log(),
    )
    |> result.is_ok
  assert rv.metadata(
      "sha256-" <> digest,
      rv.Enforcement(
        rv.Reported(list.repeat("", 65), list.repeat("", 64), rv.Complete),
        rv.Unreported(""),
      ),
      empty_log(),
    )
    |> result.is_error
}

pub fn canonical_reference_validation_test() {
  let generator = ids.generator(clock.fixed(0), seed: 1)
  let #(session, generator) = ids.mint_session(generator)
  let #(entry, _generator) = ids.mint_entry(generator)
  let assert Ok(reference) =
    rv.reference(session, entry, digest, rv.max_bundle_bytes)
    as "Typed identities and a bounded canonical digest make a data name."
  let text = rv.ref_to_string(reference)
  assert string.byte_size(text) <= 160
  assert rv.parse_ref(text) == Ok(reference)
  assert rv.ref_session(reference) == session
  assert rv.ref_result_entry(reference) == entry
  assert rv.ref_digest(reference) == digest
  assert rv.ref_byte_length(reference) == rv.max_bundle_bytes
  let prefix =
    "result://"
    <> ids.session_id_to_string(session)
    <> "/"
    <> ids.entry_id_to_string(entry)
    <> "/"
    <> digest
    <> "/"
  list.each(
    [
      "result://bad",
      text <> "/",
      string.uppercase(text),
      prefix <> "017039376",
      prefix <> "+17039376",
      prefix <> "17039376.0",
      prefix <> "0",
      prefix <> "17039377",
      prefix <> "-1",
      prefix <> "9999999999999999999999999999999",
      "result://00000000-0000-4000-8000-000000000000/"
        <> ids.entry_id_to_string(entry)
        <> "/"
        <> digest
        <> "/18",
      string.repeat("r", 161),
    ],
    fn(bad) {
      assert rv.parse_ref(bad) |> result.is_error
    },
  )
  assert rv.reference(session, entry, string.repeat("g", 64), 18)
    |> result.is_error
  assert rv.reference(session, entry, digest, 17) |> result.is_error
}

fn replace_object(
  value: mp.MsgPackValue,
  name: String,
  replacement: mp.MsgPackValue,
) -> mp.MsgPackValue {
  let assert mp.MapValue(entries) = value as "The fixture is an object."
  mp.MapValue(
    list.map(entries, fn(entry) {
      case entry.0 {
        mp.StringValue(key) if key == name -> #(entry.0, replacement)
        _ -> entry
      }
    }),
  )
}

pub fn metadata_closed_schema_and_order_fidelity_test() {
  let assert Ok(report) = rv.from_outcome(rv.Completed(mp.NilValue), metadata())
    as "The fixture holds checked metadata."
  let #(terminal, encoded_metadata) = segments(rv.bytes(report))
  let assert Ok(mp.MapValue(entries)) = mp.decode(encoded_metadata)
    as "The metadata segment is independently tagged."
  let value = mp.MapValue(entries)
  let assert Ok(reordered) = mp.encode(mp.MapValue(list.reverse(entries)))
    as "Canonical MessagePack preserves input map order."
  let bytes = complete(terminal, reordered)
  let assert Ok(decoded) = rv.decode(bytes)
    as "Field order is not a new schema discriminator."
  assert rv.bytes(decoded) == bytes
  assert rv.report_metadata(decoded) |> rv.calls == empty_log()
  let unknown =
    mp.MapValue([#(mp.StringValue("unknown"), mp.NilValue), ..entries])
  let duplicate =
    mp.MapValue([
      #(mp.StringValue("kind"), mp.StringValue("loom_report_metadata_v1")),
      ..entries
    ])
  list.each(
    [
      unknown,
      duplicate,
      replace_object(value, "kind", mp.StringValue("report")),
      replace_object(
        value,
        "manifest_hash",
        mp.StringValue(string.repeat("A", 64)),
      ),
      replace_object(value, "sandbox", mp.BinaryValue(<<0>>)),
      replace_object(value, "calls", mp.NilValue),
    ],
    fn(value) {
      let assert Ok(raw) = mp.encode(value)
        as "Schema corruption is still encodable."
      assert rv.decode(complete(terminal, raw)) |> result.is_error
    },
  )
  // An over-wide map header encodes the same metadata term but is noncanonical.
  let assert <<_header, rest:bits>> = encoded_metadata
    as "The metadata map uses fixmap."
  assert rv.decode(complete(terminal, <<0xde, 4:size(16), rest:bits>>))
    |> result.is_error
}

pub fn independent_metadata_raw_bounds_test() {
  let value =
    mp.ArrayValue(
      list.append(
        list.repeat(mp.ArrayValue(list.repeat(mp.NilValue, 128)), 63),
        [mp.ArrayValue(list.repeat(mp.NilValue, 63))],
      ),
    )
  let assert Ok(at) = mp.encode(value)
    as "The metadata node-bound fixture is encodable."
  assert msgpack_scan.metadata(at) |> result.is_ok
  let excess =
    mp.ArrayValue(
      list.append(
        list.repeat(mp.ArrayValue(list.repeat(mp.NilValue, 128)), 63),
        [mp.ArrayValue(list.repeat(mp.NilValue, 64))],
      ),
    )
  let assert Ok(over) = mp.encode(excess)
    as "The excess has just one more sibling node."
  assert msgpack_scan.metadata(over) |> result.is_error
  let assert Ok(depth_at) = mp.encode(nest(mp.NilValue, 16))
    as "Sixteen metadata container levels are representable."
  assert msgpack_scan.metadata(depth_at) |> result.is_ok
  let assert Ok(depth_over) = mp.encode(nest(mp.NilValue, 17))
    as "The first excess level is encodable by the generic codec."
  assert msgpack_scan.metadata(depth_over) |> result.is_error
  assert msgpack_scan.metadata(<<0xda, 8192:size(16), 0:size(8192 * 8)>>)
    |> result.is_ok
  assert msgpack_scan.metadata(<<0xda, 8193:size(16), 0:size(8193 * 8)>>)
    |> result.is_error
  // Thirty-two strings use a three-byte array header and three bytes per string.
  let first = <<0xda, 8192:size(16), 0:size(8192 * 8)>>
  let head = bit_array.concat(list.repeat(first, 31))
  let remaining = 262_144 - 3 - { 31 * 8195 } - 3
  let at = <<
    0xdc,
    32:size(16),
    head:bits,
    0xda,
    remaining:size(16),
    0:size(
      remaining
      * 8
    ),
  >>
  assert bit_array.byte_size(at) == 262_144
  assert msgpack_scan.metadata(at) |> result.is_ok
  let over = <<
    0xdc,
    32:size(16),
    head:bits,
    0xda,
    { remaining + 1 }:size(16),
    0:size(
      { remaining + 1 }
      * 8
    ),
  >>
  assert msgpack_scan.metadata(over) |> result.is_error
}

// The production compiler emits a prefixed fingerprint; a report URI instead
// carries a bare digest of the whole stored bundle. Neither name substitutes for
// the other, and both constructors must preserve their distinct contracts.
pub fn artifact_fingerprint_is_preserved_without_weakening_reference_digest_test() {
  let stages = rv.Enforcement(rv.Unreported("build"), rv.Unreported("node"))
  let fingerprint = "sha256-" <> digest
  let assert Ok(meta) = rv.metadata(fingerprint, stages, empty_log())
    as "The actual compiler fingerprint is accepted verbatim."
  let assert Ok(bundle) = rv.from_outcome(rv.Completed(mp.NilValue), meta)
    as "The complete report preserves the original observation."
  let assert Ok(decoded) = rv.decode(rv.bytes(bundle))
    as "Stored metadata accepts the same canonical fingerprint."
  assert rv.manifest_hash(rv.report_metadata(decoded)) == fingerprint
  list.each(
    [
      digest,
      "SHA256-" <> digest,
      fingerprint <> "0",
      "sha256-" <> string.repeat("A", 64),
    ],
    fn(invalid) {
      assert rv.metadata(invalid, stages, empty_log()) |> result.is_error
    },
  )
  let session = ids.mint_session(ids.generator(clock.fixed(0), 1)).0
  let entry = ids.mint_entry(ids.generator(clock.fixed(0), 2)).0
  assert rv.reference(session, entry, fingerprint, 64) |> result.is_error
  assert rv.reference(session, entry, digest, 64) |> result.is_ok
}

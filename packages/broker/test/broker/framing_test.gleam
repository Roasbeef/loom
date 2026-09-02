import broker/framing
import broker/policy
import core/msgpack
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import simplifile

fn sample_frames() -> List(framing.Frame) {
  [
    framing.Frame(
      id: 1,
      body: framing.Hello(proto: 1, peer: "exec-helper", features: [
        "rlimits",
        "pgroup",
        "bwrap",
      ]),
    ),
    framing.Frame(
      id: 2,
      body: framing.ExecStart(
        argv: ["/bin/echo", "hello"],
        env: [#("PATH", "/usr/bin"), #("HOME", "/work")],
        cwd: "/work",
        policy: Some(policy.workspace_default("/work")),
        token: <<1, 2, 3, 4>>,
        limits: None,
      ),
    ),
    framing.Frame(id: 2, body: framing.ExecStdin(data: <<"stdin">>, eof: True)),
    framing.Frame(
      id: 2,
      body: framing.ExecOut(
        stream: framing.Stdout,
        data: <<"hello\n">>,
        bytes: 6,
        truncated: False,
      ),
    ),
    framing.Frame(
      id: 2,
      body: framing.ExecExit(
        code: 0,
        signal: 0,
        stdout_bytes: 6,
        stderr_bytes: 0,
        stdout_truncated: False,
        stderr_truncated: False,
        enforcement: ["bwrap", "seccomp-net"],
        degraded: False,
        wall_ms: 12,
        timed_out: False,
        cancelled: False,
      ),
    ),
    framing.Frame(
      id: 3,
      body: framing.CapCall(
        token: <<9, 9>>,
        cap: "fs.read",
        args: msgpack.MapValue([
          #(msgpack.StringValue("path"), msgpack.StringValue("/work/a")),
        ]),
        deadline_ms: 1000,
      ),
    ),
    framing.Frame(
      id: 3,
      body: framing.CapResult(
        outcome: framing.CapOk(value: msgpack.StringValue("contents")),
        usage: None,
      ),
    ),
    framing.Frame(
      id: 3,
      body: framing.CapResult(
        outcome: framing.CapErr(code: "denied", message: "no token"),
        usage: Some(msgpack.IntValue(1)),
      ),
    ),
    framing.Frame(
      id: 5,
      body: framing.HookCall(
        token: <<7, 7, 7>>,
        kind: "tool",
        name: "search",
        args: msgpack.MapValue([
          #(msgpack.StringValue("strand"), msgpack.StringValue("main")),
          #(msgpack.StringValue("args"), msgpack.StringValue("{}")),
        ]),
        deadline_ms: 30_000,
      ),
    ),
    framing.Frame(
      id: 6,
      body: framing.HookCall(
        token: <<>>,
        kind: "event",
        name: "session_start",
        args: msgpack.NilValue,
        deadline_ms: 1,
      ),
    ),
    framing.Frame(
      id: 5,
      body: framing.HookResult(
        outcome: framing.CapOk(value: msgpack.ArrayValue([])),
      ),
    ),
    framing.Frame(
      id: 6,
      body: framing.HookResult(
        outcome: framing.CapErr(code: "unhandled", message: "no handler"),
      ),
    ),
    framing.Frame(id: 2, body: framing.Cancel),
    framing.Frame(id: 4, body: framing.Heartbeat),
    framing.Frame(
      id: 0,
      body: framing.ErrorBody(code: "malformed_frame", message: "boom"),
    ),
  ]
}

pub fn roundtrip_every_kind_test() {
  list.each(sample_frames(), fn(frame) {
    let assert Ok(payload) = framing.encode_payload(frame)
    assert framing.decode_payload(payload) == Ok(frame)
    // And through the length-prefixed wire form + deframer.
    let assert Ok(wire_bytes) = framing.encode(frame)
    let pushed = framing.push(framing.deframer(), wire_bytes)
    assert pushed.inbound == [framing.Known(frame)]
    assert pushed.fault == option.None
  })
}

pub fn negative_id_unencodable_test() {
  let assert Error(_) =
    framing.encode(framing.Frame(id: -1, body: framing.Heartbeat))
}

// Golden cross-language fixture for the hello frame payload (the
// msgpack map without the length prefix), pinned alongside the policy
// fixtures. First run writes; later runs must reproduce byte for byte.
pub fn golden_hello_frame_fixture_test() {
  let frame =
    framing.Frame(
      id: 1,
      body: framing.Hello(proto: 1, peer: "broker", features: []),
    )
  let assert Ok(payload) = framing.encode_payload(frame)
  let path = "../../protocol/msgpack-fixtures/frame_hello_1.bin"
  case simplifile.read_bits(path) {
    Ok(stored) -> {
      assert stored == payload
      assert framing.decode_payload(stored) == Ok(frame)
    }
    Error(simplifile.Enoent) -> {
      let assert Ok(Nil) = simplifile.write_bits(path, payload)
      Nil
    }
    Error(_) -> panic as "fixture directory unreadable"
  }
}

// --- strict, total decoding ---------------------------------------------

fn envelope(
  v v: msgpack.MsgPackValue,
  id id: msgpack.MsgPackValue,
  kind kind: msgpack.MsgPackValue,
  body body: msgpack.MsgPackValue,
) -> BitArray {
  let assert Ok(bytes) =
    msgpack.encode(
      msgpack.MapValue([
        #(msgpack.StringValue("v"), v),
        #(msgpack.StringValue("id"), id),
        #(msgpack.StringValue("kind"), kind),
        #(msgpack.StringValue("body"), body),
      ]),
    )
  bytes
}

pub fn unknown_kind_reported_in_band_test() {
  let payload =
    envelope(
      v: msgpack.IntValue(1),
      id: msgpack.IntValue(7),
      kind: msgpack.StringValue("mystery"),
      body: msgpack.MapValue([]),
    )
  assert framing.decode_payload(payload)
    == Error(framing.UnknownKind(id: 7, kind: "mystery"))
}

pub fn version_mismatch_reported_test() {
  let payload =
    envelope(
      v: msgpack.IntValue(2),
      id: msgpack.IntValue(1),
      kind: msgpack.StringValue("heartbeat"),
      body: msgpack.MapValue([]),
    )
  assert framing.decode_payload(payload)
    == Error(framing.UnsupportedVersion(version: 2))
}

pub fn malformed_corpus_never_crashes_test() {
  let assert Ok(hello_map) = msgpack.encode(msgpack.MapValue([]))
  let corpus = [
    #("empty", <<>>),
    #("junk", <<0xde, 0xad, 0xbe, 0xef, 0x01>>),
    #("bare int", encode_value(msgpack.IntValue(5))),
    #("bare string", encode_value(msgpack.StringValue("hello"))),
    #("empty map", hello_map),
    #(
      "missing body",
      encode_value(
        msgpack.MapValue([
          #(msgpack.StringValue("v"), msgpack.IntValue(1)),
          #(msgpack.StringValue("id"), msgpack.IntValue(1)),
          #(msgpack.StringValue("kind"), msgpack.StringValue("heartbeat")),
        ]),
      ),
    ),
    #(
      "extra envelope key",
      encode_value(
        msgpack.MapValue([
          #(msgpack.StringValue("v"), msgpack.IntValue(1)),
          #(msgpack.StringValue("id"), msgpack.IntValue(1)),
          #(msgpack.StringValue("kind"), msgpack.StringValue("heartbeat")),
          #(msgpack.StringValue("body"), msgpack.MapValue([])),
          #(msgpack.StringValue("evil"), msgpack.IntValue(666)),
        ]),
      ),
    ),
    #(
      "id as string",
      envelope(
        v: msgpack.IntValue(1),
        id: msgpack.StringValue("1"),
        kind: msgpack.StringValue("heartbeat"),
        body: msgpack.MapValue([]),
      ),
    ),
    #(
      "negative id",
      envelope(
        v: msgpack.IntValue(1),
        id: msgpack.IntValue(-1),
        kind: msgpack.StringValue("heartbeat"),
        body: msgpack.MapValue([]),
      ),
    ),
    #(
      "body not a map",
      envelope(
        v: msgpack.IntValue(1),
        id: msgpack.IntValue(1),
        kind: msgpack.StringValue("heartbeat"),
        body: msgpack.IntValue(0),
      ),
    ),
    #(
      "hello missing proto",
      envelope(
        v: msgpack.IntValue(1),
        id: msgpack.IntValue(1),
        kind: msgpack.StringValue("hello"),
        body: msgpack.MapValue([
          #(msgpack.StringValue("peer"), msgpack.StringValue("x")),
          #(msgpack.StringValue("features"), msgpack.ArrayValue([])),
        ]),
      ),
    ),
    #(
      "exec_out bad stream",
      envelope(
        v: msgpack.IntValue(1),
        id: msgpack.IntValue(1),
        kind: msgpack.StringValue("exec_out"),
        body: msgpack.MapValue([
          #(msgpack.StringValue("stream"), msgpack.StringValue("stdmid")),
          #(msgpack.StringValue("data"), msgpack.BinaryValue(<<>>)),
          #(msgpack.StringValue("bytes"), msgpack.IntValue(0)),
          #(msgpack.StringValue("truncated"), msgpack.BoolValue(False)),
        ]),
      ),
    ),
    #(
      "exec_exit unknown body key",
      envelope(
        v: msgpack.IntValue(1),
        id: msgpack.IntValue(1),
        kind: msgpack.StringValue("exec_exit"),
        body: msgpack.MapValue([
          #(msgpack.StringValue("surprise"), msgpack.IntValue(1)),
        ]),
      ),
    ),
  ]
  list.each(corpus, fn(item) {
    let #(name, payload) = item
    case framing.decode_payload(payload) {
      Error(framing.Malformed(_)) -> Nil
      Error(framing.UnsupportedVersion(_)) -> Nil
      Error(framing.UnknownKind(..)) ->
        panic as { "expected malformed, got unknown kind: " <> name }
      Ok(_) -> panic as { "malformed input accepted: " <> name }
    }
  })
}

pub fn nil_arrays_tolerated_test() {
  // Go encodes nil slices as msgpack nil: enforcement and data fields
  // must decode as empty.
  let payload =
    envelope(
      v: msgpack.IntValue(1),
      id: msgpack.IntValue(2),
      kind: msgpack.StringValue("exec_exit"),
      body: msgpack.MapValue([
        #(msgpack.StringValue("code"), msgpack.IntValue(0)),
        #(msgpack.StringValue("signal"), msgpack.IntValue(0)),
        #(msgpack.StringValue("stdout_bytes"), msgpack.IntValue(0)),
        #(msgpack.StringValue("stderr_bytes"), msgpack.IntValue(0)),
        #(msgpack.StringValue("stdout_truncated"), msgpack.BoolValue(False)),
        #(msgpack.StringValue("stderr_truncated"), msgpack.BoolValue(False)),
        #(msgpack.StringValue("enforcement"), msgpack.NilValue),
        #(msgpack.StringValue("degraded"), msgpack.BoolValue(True)),
        #(msgpack.StringValue("wall_ms"), msgpack.IntValue(1)),
        #(msgpack.StringValue("timed_out"), msgpack.BoolValue(False)),
        #(msgpack.StringValue("cancelled"), msgpack.BoolValue(False)),
      ]),
    )
  let assert Ok(framing.Frame(
    id: 2,
    body: framing.ExecExit(enforcement: [], ..),
  )) = framing.decode_payload(payload)
}

fn encode_value(value: msgpack.MsgPackValue) -> BitArray {
  let assert Ok(bytes) = msgpack.encode(value)
  bytes
}

// --- the pure incremental deframer --------------------------------------

pub fn deframer_carries_partial_frames_test() {
  let assert Ok(wire_bytes) =
    framing.encode(framing.Frame(id: 1, body: framing.Heartbeat))
  let size = bit_array.byte_size(wire_bytes)
  let assert Ok(head) = bit_array.slice(from: wire_bytes, at: 0, take: size - 1)
  let assert Ok(tail) = bit_array.slice(from: wire_bytes, at: size - 1, take: 1)
  let assert framing.Pushed(
    deframer: carry,
    inbound: none_yet,
    fault: option.None,
  ) = framing.push(framing.deframer(), head)
  assert none_yet == []
  let pushed = framing.push(carry, tail)
  assert pushed.inbound
    == [framing.Known(framing.Frame(id: 1, body: framing.Heartbeat))]
}

// The chunking property: pushing a stream byte-by-byte produces exactly
// the frames of pushing it whole, for a stream mixing every body kind
// and an unknown-kind frame.
pub fn deframer_per_byte_chunking_property_test() {
  let unknown =
    envelope(
      v: msgpack.IntValue(1),
      id: msgpack.IntValue(99),
      kind: msgpack.StringValue("mystery"),
      body: msgpack.MapValue([]),
    )
  let unknown_wire = <<bit_array.byte_size(unknown):size(32), unknown:bits>>
  let stream =
    sample_frames()
    |> list.map(fn(frame) {
      let assert Ok(wire_bytes) = framing.encode(frame)
      wire_bytes
    })
    |> list.append([unknown_wire])
    |> bit_array.concat
  let whole = framing.push(framing.deframer(), stream)
  assert whole.fault == option.None

  let bytes = split_bytes(stream)
  let #(final, collected) =
    list.fold(bytes, #(framing.deframer(), []), fn(acc, one_byte) {
      let #(deframer, seen) = acc
      let pushed = framing.push(deframer, one_byte)
      assert pushed.fault == option.None
      #(pushed.deframer, list.append(seen, pushed.inbound))
    })
  assert collected == whole.inbound
  // Nothing is left mid-frame at the end.
  let flushed = framing.push(final, <<>>)
  assert flushed.inbound == []
}

fn split_bytes(bytes: BitArray) -> List(BitArray) {
  split_bytes_loop(bytes, [])
}

fn split_bytes_loop(
  bytes: BitArray,
  accumulator: List(BitArray),
) -> List(BitArray) {
  case bytes {
    <<head, rest:bits>> -> split_bytes_loop(rest, [<<head>>, ..accumulator])
    _ -> list.reverse(accumulator)
  }
}

pub fn deframer_oversized_length_faults_test() {
  let pushed =
    framing.push(framing.deframer(), <<0xff, 0xff, 0xff, 0xff, 0x00>>)
  assert pushed.fault
    == option.Some(framing.OversizedFrame(declared_bytes: 4_294_967_295))
}

pub fn deframer_corrupt_frame_faults_after_good_frames_test() {
  let assert Ok(good) =
    framing.encode(framing.Frame(id: 1, body: framing.Heartbeat))
  let junk = <<0xde, 0xad, 0xbe>>
  let bad = <<bit_array.byte_size(junk):size(32), junk:bits>>
  let pushed = framing.push(framing.deframer(), bit_array.concat([good, bad]))
  // The good frame before the corruption is still delivered.
  assert pushed.inbound
    == [framing.Known(framing.Frame(id: 1, body: framing.Heartbeat))]
  let assert option.Some(framing.CorruptFrame(_)) = pushed.fault
}

pub fn deframer_stays_dead_after_fault_test() {
  let junk = <<0xff, 0xff, 0xff, 0xff, 0x00>>
  let first = framing.push(framing.deframer(), junk)
  let assert option.Some(fault) = first.fault
  let assert Ok(good) =
    framing.encode(framing.Frame(id: 1, body: framing.Heartbeat))
  let second = framing.push(first.deframer, good)
  assert second.inbound == []
  assert second.fault == option.Some(fault)
}

pub fn deframer_version_mismatch_faults_test() {
  let payload =
    envelope(
      v: msgpack.IntValue(3),
      id: msgpack.IntValue(1),
      kind: msgpack.StringValue("heartbeat"),
      body: msgpack.MapValue([]),
    )
  let wire_bytes = <<bit_array.byte_size(payload):size(32), payload:bits>>
  let pushed = framing.push(framing.deframer(), wire_bytes)
  assert pushed.fault == option.Some(framing.VersionMismatch(version: 3))
}

// Fuzz-flavoured: random byte salads either produce a fault or wait for
// more input; they never crash and never fabricate frames.
pub fn deframer_random_salad_never_crashes_test() {
  let salads = [
    <<>>,
    <<0>>,
    <<0, 0>>,
    <<0, 0, 0, 0>>,
    <<0, 0, 0, 1, 0xc1>>,
    <<0, 0, 0, 2, 0x81, 0xa1>>,
    <<0, 0, 0, 5, 0x93, 1, 2, 3, 0xc0>>,
    <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>,
    <<0, 0, 0, 3, 0xa2, 0x68, 0x69>>,
  ]
  list.each(salads, fn(salad) {
    let pushed = framing.push(framing.deframer(), salad)
    list.each(pushed.inbound, fn(inbound) {
      case inbound {
        framing.Known(_) -> panic as "fabricated a frame from a salad"
        framing.UnknownInbound(..) -> panic as "fabricated an unknown frame"
      }
    })
  })
}

// --- the hook pair (protocol-change/012) ---------------------------------
//
// The two kinds the harness asks with. They are decoded by the same
// strict rules as every other kind — exact key set, every field required
// — and these cases pin that rather than the round trip, which
// `roundtrip_every_kind_test` already covers for both.

fn hook_envelope(
  kind: String,
  entries: List(#(String, msgpack.MsgPackValue)),
) -> BitArray {
  envelope(
    v: msgpack.IntValue(1),
    id: msgpack.IntValue(9),
    kind: msgpack.StringValue(kind),
    body: msgpack.MapValue(
      list.map(entries, fn(entry) { #(msgpack.StringValue(entry.0), entry.1) }),
    ),
  )
}

pub fn hook_call_rejects_missing_field_test() {
  let payload =
    hook_envelope("hook_call", [
      #("token", msgpack.BinaryValue(<<1>>)),
      #("kind", msgpack.StringValue("tool")),
      #("name", msgpack.StringValue("search")),
      #("args", msgpack.NilValue),
    ])
  let assert Error(framing.Malformed(..)) = framing.decode_payload(payload)
}

pub fn hook_call_rejects_unknown_field_test() {
  let payload =
    hook_envelope("hook_call", [
      #("token", msgpack.BinaryValue(<<1>>)),
      #("kind", msgpack.StringValue("tool")),
      #("name", msgpack.StringValue("search")),
      #("args", msgpack.NilValue),
      #("deadline_ms", msgpack.IntValue(10)),
      #("strand", msgpack.StringValue("main")),
    ])
  let assert Error(framing.Malformed(..)) = framing.decode_payload(payload)
}

pub fn hook_call_rejects_wrong_typed_field_test() {
  let payload =
    hook_envelope("hook_call", [
      #("token", msgpack.StringValue("not-bytes")),
      #("kind", msgpack.StringValue("tool")),
      #("name", msgpack.StringValue("search")),
      #("args", msgpack.NilValue),
      #("deadline_ms", msgpack.IntValue(10)),
    ])
  let assert Error(framing.Malformed(..)) = framing.decode_payload(payload)
}

pub fn hook_result_rejects_missing_error_test() {
  let payload = hook_envelope("hook_result", [#("ok", msgpack.BoolValue(False))])
  let assert Error(framing.Malformed(..)) = framing.decode_payload(payload)
}

// `usage` is a `cap_result` field and not a `hook_result` one: an
// invocation reserves no budget of its own, so the key set is exact
// rather than a superset of the pair it mirrors.
pub fn hook_result_rejects_usage_test() {
  let payload =
    hook_envelope("hook_result", [
      #("ok", msgpack.BoolValue(True)),
      #("value", msgpack.NilValue),
      #("usage", msgpack.IntValue(1)),
    ])
  let assert Error(framing.Malformed(..)) = framing.decode_payload(payload)
}

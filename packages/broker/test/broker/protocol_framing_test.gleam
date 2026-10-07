//// Protocol 076's exact maps preserve ordinary formats and credited coordinates.

import broker/framing
import core/msgpack
import gleam/bit_array
import gleam/list
import gleam/option.{None}
import gleam/string

pub fn credited_frame_shapes_roundtrip_with_exact_original_fields_test() {
  let bodies = [
    framing.ProtocolStart(
      framing.ProtocolRequest(["true"], [], "/work", None, <<1>>, None),
      framing.ServerProtocol,
    ),
    framing.ProtocolStart(
      framing.ProtocolRequest(["true"], [], "/work", None, <<1>>, None),
      framing.FiniteCollected,
    ),
    framing.ProtocolInput(99, 1, 123, <<"data">>, framing.InputContinues),
    framing.ProtocolInput(99, 2, 124, <<>>, framing.InputEOF),
    framing.ProtocolInputAccepted(99, 1, 123),
    framing.ProtocolInputRefused(99, 2, 124, framing.InputPending),
    framing.ProtocolOutput(
      99,
      1,
      framing.Stdout,
      <<"data">>,
      4,
      framing.OutputComplete,
    ),
    framing.ProtocolOutput(
      99,
      2,
      framing.Stderr,
      <<>>,
      0,
      framing.OutputTruncated,
    ),
    framing.ProtocolOutputConsumed(99, 1),
    framing.ProtocolReusable(99),
  ]
  list.each(bodies, fn(body) {
    let frame = framing.Frame(99, body)
    let assert Ok(bytes) = framing.encode_payload(frame)
      as "credited body encodes"
    assert framing.decode_payload(bytes) == Ok(frame)
  })
}

pub fn ordinary_start_and_exit_omit_credited_fields_test() {
  list.each(
    [
      framing.ExecStart(["true"], [], "/work", None, <<1>>, None),
      framing.ExecExit(0, 0, 0, 0, False, False, [], False, 0, False, False),
    ],
    fn(body) {
      let assert Ok(bytes) = framing.encode_payload(framing.Frame(7, body))
        as "ordinary body encodes"
      let assert Ok(msgpack.MapValue(envelope)) = msgpack.decode(bytes)
        as "ordinary envelope remains a map"
      let assert Ok(msgpack.MapValue(fields)) =
        list.key_find(envelope, msgpack.StringValue("body"))
        as "ordinary body remains a map"
      assert list.key_find(fields, msgpack.StringValue("mode")) == Error(Nil)
      assert list.key_find(fields, msgpack.StringValue("protocol"))
        == Error(Nil)
      assert list.key_find(fields, msgpack.StringValue("execution_id"))
        == Error(Nil)
    },
  )
  assert framing.envelope_version == 1
  assert framing.exec_protocol_version == 4
}

pub fn credited_input_ceiling_and_positive_identity_decode_before_admission_test() {
  list.each(
    [
      framing.ProtocolInput(
        9,
        1,
        8,
        bit_array.from_string(string.repeat("a", 8193)),
        framing.InputContinues,
      ),
      framing.ProtocolInput(0, 1, 8, <<>>, framing.InputEOF),
      framing.ProtocolInput(9, 0, 8, <<>>, framing.InputEOF),
      framing.ProtocolInput(9, 1, 0, <<>>, framing.InputEOF),
    ],
    fn(body) {
      let assert Ok(bytes) = framing.encode_payload(framing.Frame(9, body))
        as "invalid fixture encodes as data"
      let assert Error(_) = framing.decode_payload(bytes)
        as "invalid credited admission refuses"
    },
  )
}

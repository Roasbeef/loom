import broker/framing
import core/ids
import core/msgpack as mp
import executor/remote/identity
import executor/remote/wire
import gleam/list

pub fn hello_accepts_only_the_current_helper_protocol_test() {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "The fixture session is valid."
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "The fixture workspace is valid."
  let assert Ok(executor) = identity.executor_id("executor")
    as "The fixture executor is valid."
  let assert Ok(epoch) = identity.epoch(1) as "The fixture epoch is valid."
  let scope = identity.scope(session, workspace, executor, epoch, epoch)
  let envelope =
    wire.Envelope(wire.Owner, "owner", "executor", 1, scope, wire.Hello)
  let assert Ok(bytes) = wire.encode(envelope) as "The current Hello encodes."
  assert wire.decode(bytes, wire.Owner, "owner", "executor", scope)
    == Ok(envelope)

  // Both adjacent versions must fail before this header can admit a route.
  let assert Ok(mp.ArrayValue(fields)) = mp.decode(bytes)
    as "The encoded envelope is a canonical array."
  list.each(
    [framing.exec_protocol_version - 1, framing.exec_protocol_version + 1],
    fn(version) {
      let changed =
        list.take(fields, 7)
        |> list.append([
          mp.ArrayValue([mp.IntValue(0), mp.IntValue(version), mp.IntValue(2)]),
        ])
      let assert Ok(changed) = mp.encode(mp.ArrayValue(changed))
        as "The mismatched Hello is otherwise well formed."
      assert wire.decode(changed, wire.Owner, "owner", "executor", scope)
        == Error(wire.Invalid)
    },
  )
}

pub fn shared_preflight_preserves_wire_invalid_mapping_test() {
  let cases = [
    <<0xda, 8193:size(16), 0:size(65_544)>>,
    <<0xc6, 131_073:size(32), 0:size(1_048_584)>>,
    <<0xdd, 129:size(32), 0:size(1032)>>,
    <<0xc0, 0xc0>>,
    <<0xc0, 1:size(1)>>,
    <<0x82, 1, 0, 1, 1>>,
    <<0xcb, 0x7ff0000000000000:size(64)>>,
  ]
  list.each(cases, fn(bytes) {
    assert wire.decode_value(bytes) == Error(wire.Invalid)
  })

  // Individually legal child arrays cannot renew the enclosing node allowance.
  let oversized =
    mp.ArrayValue(list.repeat(mp.ArrayValue(list.repeat(mp.NilValue, 128)), 16))
  let assert Ok(bytes) = mp.encode(oversized)
    as "The oversized tree is valid MessagePack."
  assert wire.decode_value(bytes) == Error(wire.Invalid)
  assert wire.encode_value(oversized) == Error(wire.Invalid)
  assert wire.encode_value(mp.StringValue(string_of_zeros()))
    == Error(wire.Invalid)
}

pub fn shared_preflight_preserves_canonical_wire_values_test() {
  let value =
    mp.ArrayValue([
      mp.NilValue,
      mp.BoolValue(True),
      mp.IntValue(-129),
      mp.IntValue(256),
      mp.FloatValue(1.5),
      mp.StringValue("héllo"),
      mp.BinaryValue(<<1, 2, 3>>),
      mp.MapValue([#(mp.StringValue("key"), mp.ArrayValue([]))]),
    ])
  let assert Ok(bytes) = mp.encode(value) as "The canonical value encodes."
  assert wire.encode_value(value) == Ok(bytes)
  assert wire.decode_value(bytes) == Ok(value)
}

fn string_of_zeros() -> String {
  let assert Ok(mp.StringValue(text)) =
    mp.decode(<<0xda, 8193:size(16), 0:size(65_544)>>)
    as "The wire encoder test uses a valid oversized string."
  text
}

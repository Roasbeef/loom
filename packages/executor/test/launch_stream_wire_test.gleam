//// Closed stream boundaries bind the complete original Launch authority.
//// These probes keep consumption distinct from transfer acknowledgements and
//// preserve independent node, transport and resource observations on close.

import codemode/enforcement
import codemode/run_channel as channel
import core/command
import core/ids
import core/remote_tool
import core/workspace
import executor/remote/identity
import executor/remote/internal/beam_protocol as protocol
import executor/remote/internal/launch_stream_wire as wire
import gleam/list
import gleam/string

fn pin(generation: Int) -> protocol.Binding {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Original session."
  let assert Ok(workspace_id) = identity.workspace_id("checkout")
    as "Original workspace."
  let assert Ok(executor) = identity.executor_id("executor")
    as "Original executor."
  let assert Ok(epoch) = identity.epoch(1) as "Original epoch."
  protocol.Binding(
    "owner",
    "executor",
    generation,
    identity.scope(session, workspace_id, executor, epoch, epoch),
  )
}

fn key() -> command.ServiceKey {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Original session."
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Original operation."
  let assert Ok(parent_id) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000003")
    as "Parent identity."
  let assert Ok(parent) =
    remote_tool.key(
      session,
      operation,
      "parent",
      0,
      string.repeat("a", 64),
      parent_id,
    )
    as "Original parent."
  let assert Ok(scope) =
    workspace.scope_from_fields(
      ids.session_id_to_string(session),
      "checkout",
      "executor",
      1,
      1,
    )
    as "Full original scope."
  let assert Ok(step) = workspace.step("physical:run") as "Launch step."
  let assert Ok(id) = ids.parse_entry_id("00000000-0000-7000-8000-000000000004")
    as "Launch identity."
  let assert Ok(key) =
    command.service_key(
      parent,
      command.LaunchService,
      scope,
      operation,
      step,
      id,
      string.repeat("b", 64),
      string.repeat("c", 64),
      string.repeat("d", 64),
    )
    as "Full Launch key."
  key
}

pub fn canonical_binding_and_nonce_generation_are_exact_test() {
  let assert Ok(original) = wire.binding(pin(1), key(), <<1:size(256)>>)
    as "Exact binding."
  assert wire.decode_binding(pin(1), wire.bytes(original)) == Ok(original)
  assert wire.decode_binding(pin(2), wire.bytes(original)) == Error(Nil)
  assert wire.binding(pin(1), key(), <<1:size(248)>>) == Error(Nil)
  let assert Ok(other) = wire.binding(pin(1), key(), <<2:size(256)>>)
    as "Distinct original nonce."
  let assert Ok(packet) = wire.encode(original, wire.Bound)
    as "Owner bind confirmation."
  assert wire.decode(original, packet) == Ok(wire.Bound)
  assert wire.decode(other, packet) == Error(Nil)
  assert wire.decode(original, <<packet:bits, 0>>) == Error(Nil)
}

pub fn payload_prefix_chunk_and_sequence_bounds_test() {
  let assert Ok(original) = wire.binding(pin(1), key(), <<1:size(256)>>)
    as "Exact binding."
  let accepted = [
    wire.Header(channel.ToHost, 1, 4),
    wire.Header(channel.ToNode, 1, 16_777_220),
    wire.ChunkAck(channel.ToHost, 1, 0),
    wire.Chunk(channel.ToNode, 1, 0, <<0:size(524_288)>>),
    wire.Consumed(channel.ToHost, 1, channel.Final),
  ]
  list.each(accepted, fn(packet) {
    let assert Ok(bytes) = wire.encode(original, packet) as "Bounded packet."
    assert wire.decode(original, bytes) == Ok(packet)
  })
  let rejected = [
    wire.Header(channel.ToHost, 0, 4),
    wire.Header(channel.ToHost, 1, 3),
    wire.Header(channel.ToHost, 1, 16_777_221),
    wire.Chunk(channel.ToHost, 1, 1, <<0>>),
    wire.Chunk(channel.ToHost, 1, 0, <<>>),
    wire.Chunk(channel.ToHost, 1, 0, <<0:size(524_296)>>),
  ]
  list.each(rejected, fn(packet) {
    assert wire.encode(original, packet) == Error(Nil)
  })
}

pub fn close_preserves_three_independent_observations_test() {
  let assert Ok(original) = wire.binding(pin(1), key(), <<1:size(256)>>)
    as "Exact binding."
  let closed =
    channel.CloseResult(
      enforcement.Unreported("Original native has not settled"),
      channel.TransportJoined,
      channel.ResourcesUnresolved(
        "Original dispatched native still holds resources",
      ),
    )
  let assert Ok(bytes) = wire.encode(original, wire.Closed(closed))
    as "Closed observations."
  assert wire.decode(original, bytes) == Ok(wire.Closed(closed))
}

pub fn lifetime_prefix_charge_is_not_refunded_by_consumption_or_retirement_test() {
  let assert Ok(window) =
    channel.activate_direction(channel.prepare_direction(
      channel.new_incarnation(),
      channel.ToHost,
    ))
    as "Original activated direction."
  let assert Ok(length) = channel.payload_length(channel.max_payload_bytes)
    as "Maximum exact payload."
  let window =
    list.fold([1, 2, 3], window, fn(window, _) {
      let assert Ok(#(window, reserved)) = channel.reserve_frame(window, length)
        as "Original complete wire charge."
      let assert Ok(window) = channel.publish_frame(window, reserved)
        as "Original publication."
      let #(window, consumed) =
        channel.consume_frame(
          window,
          channel.reservation(reserved).0,
          channel.Continue,
        )
      assert consumed == channel.Consumed
      window
    })
  assert channel.remaining_bytes(window) == 16_777_204
  assert channel.reserve_frame(window, length)
    == Error(channel.AllowanceExhausted)
  assert channel.remaining_bytes(channel.retire_direction(window)) == 16_777_204
}

/// Runs the bounded codec and original-window controls.
///
/// ## Examples
/// `gleam run -m launch_stream_wire_test` checks the closed byte boundary.
pub fn main() {
  canonical_binding_and_nonce_generation_are_exact_test()
  payload_prefix_chunk_and_sequence_bounds_test()
  close_preserves_three_independent_observations_test()
  lifetime_prefix_charge_is_not_refunded_by_consumption_or_retirement_test()
}

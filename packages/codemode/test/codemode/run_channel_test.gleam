//// Direction controls distinguish original admission from actual consumption.
//// A copied opaque value is not linear authority: serial owner state, exact
//// sequence and terminal retirement are the properties exercised here.

import codemode/run_channel as channel
import gleam/bit_array

fn active(
  incarnation: channel.Incarnation,
  direction: channel.Direction,
) -> channel.Window {
  let assert Ok(window) =
    channel.activate_direction(channel.prepare_direction(incarnation, direction))
    as "original prepared direction activates"
  window
}

fn length(bytes: Int) -> channel.PayloadLength {
  let assert Ok(length) = channel.payload_length(bytes)
    as "fixture size admitted"
  length
}

pub fn reservation_precedes_publication_and_consumption_test() {
  let incarnation = channel.new_incarnation()
  let prepared = channel.prepare_direction(incarnation, channel.ToHost)
  assert channel.reserve_frame(prepared, length(9))
    == Error(channel.WindowUnavailable)
  let window = active(incarnation, channel.ToHost)
  let assert Ok(#(reserved, reservation)) =
    channel.reserve_frame(window, length(9))
    as "body capacity charged first"
  assert channel.remaining_bytes(reserved) == channel.lifetime_wire_bytes - 13
  assert channel.status(reserved) == channel.ReservedWindow
  let #(frame, _) = channel.reservation(reservation)
  assert channel.consume_frame(reserved, frame, channel.Continue)
    == #(reserved, channel.Ignored)
  assert channel.reserve_frame(reserved, length(0))
    == Error(channel.WindowUnavailable)

  // Receiver acknowledgement cannot act before the original publication.
  let assert Ok(pending) = channel.publish_frame(reserved, reservation)
    as "exact publication"
  assert channel.publish_frame(pending, reservation)
    == Error(channel.StaleReservation)
  assert channel.reserve_frame(pending, length(0))
    == Error(channel.WindowUnavailable)
  let #(available, accepted) =
    channel.consume_frame(pending, frame, channel.Continue)
  assert accepted == channel.Consumed
  assert channel.remaining_bytes(available) == channel.lifetime_wire_bytes - 13
  assert channel.consume_frame(available, frame, channel.Continue)
    == #(available, channel.Ignored)
}

pub fn exact_incarnation_direction_and_sequence_are_required_test() {
  let incarnation = channel.new_incarnation()
  let host = active(incarnation, channel.ToHost)
  let node = active(incarnation, channel.ToNode)
  let other = active(channel.new_incarnation(), channel.ToHost)
  let assert Ok(#(host, reservation)) = channel.reserve_frame(host, length(0))
    as "host reserved"
  let assert Ok(host) = channel.publish_frame(host, reservation)
    as "host published"
  let #(original, _) = channel.reservation(reservation)
  let assert Ok(#(_node, wrong_direction)) =
    channel.reserve_frame(node, length(0))
    as "other direction reserved"
  let assert Ok(#(_other, wrong_incarnation)) =
    channel.reserve_frame(other, length(0))
    as "other incarnation reserved"
  assert channel.consume_frame(
      host,
      channel.reservation(wrong_direction).0,
      channel.Continue,
    )
    == #(host, channel.Ignored)
  assert channel.consume_frame(
      host,
      channel.reservation(wrong_incarnation).0,
      channel.Continue,
    )
    == #(host, channel.Ignored)

  // Sequence advances only after exact consumption; the prior ACK remains stale.
  let #(host, accepted) =
    channel.consume_frame(host, original, channel.Continue)
  assert accepted == channel.Consumed
  let assert Ok(#(host, next)) = channel.reserve_frame(host, length(0))
    as "next sequence reserved"
  let assert Ok(host) = channel.publish_frame(host, next) as "next published"
  assert channel.coordinates(channel.reservation(next).0).2 == 2
  assert channel.consume_frame(host, original, channel.Continue)
    == #(host, channel.Ignored)
}

pub fn final_consumption_and_cancellation_never_revive_window_test() {
  let host = active(channel.new_incarnation(), channel.ToHost)
  let assert Ok(#(host, reservation)) = channel.reserve_frame(host, length(1))
    as "original reserved"
  let assert Ok(host) = channel.publish_frame(host, reservation)
    as "original published"
  let #(frame, _) = channel.reservation(reservation)
  let #(finished, accepted) = channel.consume_frame(host, frame, channel.Final)
  assert accepted == channel.Consumed
  assert channel.status(finished) == channel.FinishedWindow
  assert channel.reserve_frame(finished, length(0))
    == Error(channel.ChannelRetired)
  assert channel.activate_direction(finished) == Error(channel.ChannelRetired)

  // Independent cancellation wins over a racing original final ACK.
  let retired = channel.retire_direction(host)
  assert channel.consume_frame(retired, frame, channel.Final)
    == #(retired, channel.Ignored)
  assert channel.status(retired) == channel.RetiredWindow
  assert channel.activate_direction(retired) == Error(channel.ChannelRetired)
  assert channel.remaining_bytes(retired) == channel.remaining_bytes(host)
}

pub fn declared_and_complete_frame_bounds_are_exact_test() {
  assert channel.payload_length(-1) == Error(channel.InvalidFrame)
  assert channel.payload_length(channel.max_payload_bytes + 1)
    == Error(channel.InvalidFrame)
  assert channel.wire_length(length(channel.max_payload_bytes))
    == channel.max_wire_bytes
  assert { channel.max_wire_bytes + channel.max_chunk_bytes - 1 }
    / channel.max_chunk_bytes
    == channel.max_frame_chunks
  let assert Ok(payload) = channel.from_wire(<<2:32, 0x91, 0xc0>>)
    as "one exact complete frame"
  assert channel.payload(payload) == <<0x91, 0xc0>>
  assert channel.wire_bytes(payload) == <<2:32, 0x91, 0xc0>>
  assert channel.from_wire(<<2:32, 0xc0>>) == Error(channel.InvalidFrame)
  assert channel.from_wire(<<1:32, 0xc0, 0>>) == Error(channel.InvalidFrame)
  assert channel.from_wire(<<1:32, 0xc0, 1:1>>) == Error(channel.InvalidFrame)
  assert channel.from_wire(<<{ channel.max_payload_bytes + 1 }:32>>)
    == Error(channel.InvalidFrame)
}

pub fn body_must_match_original_reserved_length_test() {
  let window = active(channel.new_incarnation(), channel.ToHost)
  let assert Ok(#(_window, reservation)) =
    channel.reserve_frame(window, length(1))
    as "one body byte reserved"
  assert channel.finish_payload(reservation, <<>>)
    == Error(channel.InvalidFrame)
  assert channel.finish_payload(reservation, <<0xc0, 0>>)
    == Error(channel.InvalidFrame)
  assert channel.finish_payload(reservation, <<0xc0, 1:1>>)
    == Error(channel.InvalidFrame)
  let assert Ok(payload) = channel.finish_payload(reservation, <<0xc0>>)
    as "exact original body completed"
  assert bit_array.byte_size(channel.wire_bytes(payload)) == 5
}

fn spend(window: channel.Window, bytes: Int) -> channel.Window {
  let assert Ok(#(window, reservation)) =
    channel.reserve_frame(window, length(bytes))
    as "capacity before delivery"
  let assert Ok(window) = channel.publish_frame(window, reservation)
    as "original publication"
  channel.consume_frame(
    window,
    channel.reservation(reservation).0,
    channel.Continue,
  ).0
}

pub fn cumulative_allowance_counts_prefix_and_never_refunds_test() {
  let window = active(channel.new_incarnation(), channel.ToHost)
  let window = spend(window, channel.max_payload_bytes)
  let window = spend(window, channel.max_payload_bytes)
  let window = spend(window, channel.max_payload_bytes)
  assert channel.remaining_bytes(window) == 16_777_204
  assert channel.reserve_frame(window, length(channel.max_payload_bytes))
    == Error(channel.AllowanceExhausted)
  let window = spend(window, 16_777_200)
  assert channel.remaining_bytes(window) == 0
  assert channel.reserve_frame(window, length(0))
    == Error(channel.AllowanceExhausted)
  let retired = channel.retire_direction(window)
  assert channel.remaining_bytes(retired) == 0
  assert channel.reserve_frame(retired, length(0))
    == Error(channel.ChannelRetired)
}

pub fn serialized_writer_retains_grant_until_exact_consumption_test() {
  let window = active(channel.new_incarnation(), channel.ToNode)
  let assert Ok(grant) = channel.write_grant(window)
    as "original writer granted"
  let assert Ok(payload) = channel.from_wire(<<1:32, 0xc0>>) as "bounded reply"
  let assert Ok(#(held, reservation)) = channel.reserve_write(grant, payload)
    as "charged before offer"
  assert channel.reserve_write(held, payload)
    == Error(channel.WindowUnavailable)
  let #(next, accepted) =
    channel.consume_write(held, channel.reservation(reservation).0)
  assert accepted == channel.Consumed
  assert channel.consume_write(next, channel.reservation(reservation).0)
    == #(next, channel.Ignored)
  let assert Ok(#(held, _next_ref)) = channel.reserve_write(next, payload)
    as "next sequence only after consume"
  let retired = channel.retire_write(held)
  assert channel.reserve_write(retired, payload)
    == Error(channel.ChannelRetired)
  assert channel.consume_write(retired, channel.reservation(reservation).0)
    == #(retired, channel.Ignored)
}

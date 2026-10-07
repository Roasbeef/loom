//// Closed Launch stream bytes retain original authority without local callbacks.
////
//// `binding` pins the complete Launch key, administrative Hello and fresh nonce.
//// `encode` and `decode` authenticate every packet against that immutable digest.
//// Chunks only advance byte transfer; `Consumed` names actual final-recipient
//// consumption. Local incarnations and grants never enter these wire values.
////
//// ## Flow
////
//// `binding` checks original authority; `bytes` and `decode_binding` preserve it.
//// `encode` and `decode` bound packets; `close_value` and `read_close` retain
//// transport, resource and node observations as distinct closed data.

import codemode/enforcement
import codemode/run_channel as channel
import core/bounded_msgpack
import core/command
import core/json
import core/msgpack as mp
import core/workspace
import executor/remote/identity
import executor/remote/internal/beam_protocol as protocol
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/result
import gleam/string

/// Checked original authority, without a live continuation.
@internal
pub opaque type Binding {
  Binding(key: command.ServiceKey, bytes: BitArray, digest: BitArray)
}

/// Closed stream operations; no operation contains a callback or subject.
@internal
pub type Packet {
  /// The original paused local connection was handed to its bridge.
  Ready

  /// The owner installed the exact authenticated executor door.
  Bound

  /// Original host custody is installed; activate once.
  Activate

  /// Reserve the exact complete wire length before receiving its body.
  Header(direction: channel.Direction, sequence: Int, wire_bytes: Int)

  /// One exact bounded byte segment, never actual frame consumption.
  Chunk(
    direction: channel.Direction,
    sequence: Int,
    offset: Int,
    bytes: BitArray,
  )

  /// The receiver retained this original byte offset only.
  ChunkAck(direction: channel.Direction, sequence: Int, offset: Int)

  /// The actual host or socket writer consumed the original frame.
  Consumed(
    direction: channel.Direction,
    sequence: Int,
    disposition: channel.Consumption,
  )

  /// The original inbound producer ended after its previous consumed frame.
  End(sequence: Int, reason: String)

  /// Independent original shutdown, outside metadata credits.
  Close

  /// Actual local close observations, without a report COMMIT claim.
  Closed(result: channel.CloseResult)
}

/// Constructs canonical original binding after checking full scope and role.
///
/// ## Examples
/// `binding(pin, key, nonce)` requires exactly 32 nonce bytes.
@internal
pub fn binding(
  pin: protocol.Binding,
  key: command.ServiceKey,
  nonce: BitArray,
) -> Result(Binding, Nil) {
  let #(session, workspace_id, executor, session_epoch, workspace_epoch) =
    identity.scope_fields(pin.scope)
  use scope <- result.try(
    workspace.scope_from_fields(
      session,
      workspace_id,
      executor,
      session_epoch,
      workspace_epoch,
    )
    |> result.replace_error(Nil),
  )
  use Nil <- result.try(
    case
      command.service_role(key),
      command.coordinates(key).0 == scope,
      bit_array.byte_size(nonce) == 32
      && pin.generation > 0
      && pin.executor == executor
    {
      command.LaunchService, True, True -> Ok(Nil)
      _, _, _ -> Error(Nil)
    },
  )
  use hello <- result.try(protocol.header(
    pin,
    protocol.Native(protocol.Control),
  ))
  let key_bytes =
    command.encode_service(key) |> json.to_string |> bit_array.from_string
  use Nil <- result.try(
    case
      bit_array.byte_size(key_bytes) <= 8192
      && bit_array.byte_size(hello) <= 1024
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  let bytes = <<
    "LLB",
    1,
    bit_array.byte_size(hello):16,
    hello:bits,
    bit_array.byte_size(key_bytes):16,
    key_bytes:bits,
    nonce:bits,
  >>
  Ok(Binding(key, bytes, crypto.hash(crypto.Sha256, bytes)))
}

/// Returns bounded canonical binding bytes only.
///
/// ## Examples
/// `bytes(original)` contains neither token bytes nor local references.
@internal
pub fn bytes(binding: Binding) -> BitArray {
  binding.bytes
}

/// Returns the exact original key selected by this checked binding.
///
/// ## Examples
/// `key(original)` never allocates a replacement identity.
@internal
pub fn key(binding: Binding) -> command.ServiceKey {
  binding.key
}

/// Decodes against provisioned administrative facts before stream installation.
///
/// ## Examples
/// `decode_binding(pin, <<>>)` refuses an absent binding.
@internal
pub fn decode_binding(
  pin: protocol.Binding,
  bytes: BitArray,
) -> Result(Binding, Nil) {
  use Nil <- result.try(case bit_array.byte_size(bytes) <= 9260 {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use #(text, nonce) <- result.try(case bytes {
    <<
      "LLB",
      1,
      size:16,
      _hello:bytes-size(size),
      count:16,
      text:bytes-size(count),
      nonce:bytes-size(32),
    >>
      if size <= 1024 && count <= 8192
    -> Ok(#(text, nonce))
    _ -> Error(Nil)
  })
  use text <- result.try(bit_array.to_string(text))
  use value <- result.try(json.parse(text) |> result.replace_error(Nil))
  use key <- result.try(
    command.decode_service(value) |> result.replace_error(Nil),
  )
  use checked <- result.try(binding(pin, key, nonce))
  case checked.bytes == bytes {
    True -> Ok(checked)
    False -> Error(Nil)
  }
}

/// Encodes one bounded packet under the original binding digest.
///
/// ## Examples
/// `encode(original, Close)` emits no effect identity of its own.
@internal
pub fn encode(binding: Binding, packet: Packet) -> Result(BitArray, Nil) {
  use payload <- result.try(packet_bytes(packet))
  Ok(<<"LLS", 1, binding.digest:bits, payload:bits>>)
}

/// Refuses a changed original binding before exposing any packet.
///
/// ## Examples
/// `decode(original, <<>>)` returns `Error(Nil)`.
@internal
pub fn decode(binding: Binding, bytes: BitArray) -> Result(Packet, Nil) {
  use Nil <- result.try(case bit_array.byte_size(bytes) <= 262_180 {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use packet <- result.try(case bytes {
    <<"LLS", 1, digest:bytes-size(32), payload:bytes>>
      if digest == binding.digest
    -> read_packet(payload)
    _ -> Error(Nil)
  })
  use canonical <- result.try(encode(binding, packet))
  case canonical == bytes {
    True -> Ok(packet)
    False -> Error(Nil)
  }
}

fn packet_bytes(packet: Packet) -> Result(BitArray, Nil) {
  case packet {
    Bound -> Ok(<<9>>)
    Ready -> Ok(<<0>>)
    Activate -> Ok(<<1>>)
    Header(direction, sequence, size)
      if sequence > 0
      && sequence <= 0x7FFFFFFFFFFFFFFF
      && size >= 4
      && size <= channel.max_wire_bytes
    -> Ok(<<2, direction_tag(direction), sequence:64, size:32>>)
    Chunk(direction, sequence, offset, bytes)
      if sequence > 0
      && sequence <= 0x7FFFFFFFFFFFFFFF
      && offset >= 0
      && offset < channel.max_wire_bytes
      && offset % channel.max_chunk_bytes == 0
    -> {
      use Nil <- result.try(
        case
          bit_array.byte_size(bytes) > 0
          && bit_array.byte_size(bytes) <= channel.max_chunk_bytes
          && bit_array.bit_size(bytes) % 8 == 0
        {
          True -> Ok(Nil)
          False -> Error(Nil)
        },
      )
      Ok(<<3, direction_tag(direction), sequence:64, offset:32, bytes:bits>>)
    }
    ChunkAck(direction, sequence, offset)
      if sequence > 0
      && sequence <= 0x7FFFFFFFFFFFFFFF
      && offset >= 0
      && offset <= channel.max_wire_bytes
    -> Ok(<<4, direction_tag(direction), sequence:64, offset:32>>)
    Consumed(direction, sequence, disposition)
      if sequence > 0 && sequence <= 0x7FFFFFFFFFFFFFFF
    ->
      Ok(<<
        5,
        direction_tag(direction),
        sequence:64,
        consumption_tag(disposition),
      >>)
    End(sequence, reason) if sequence >= 0 && sequence <= 0x7FFFFFFFFFFFFFFF -> {
      use Nil <- result.try(bound_text(reason))
      Ok(<<6, sequence:64, bit_array.from_string(reason):bits>>)
    }
    Close -> Ok(<<7>>)
    Closed(report) -> {
      use bytes <- result.try(
        mp.encode(close_value(report)) |> result.replace_error(Nil),
      )
      use _ <- result.try(
        bounded_msgpack.decode(bytes) |> result.replace_error(Nil),
      )
      Ok(<<8, bytes:bits>>)
    }
    Header(_, _, _)
    | Chunk(_, _, _, _)
    | ChunkAck(_, _, _)
    | Consumed(_, _, _)
    | End(_, _) -> Error(Nil)
  }
}

fn read_packet(bytes: BitArray) -> Result(Packet, Nil) {
  case bytes {
    <<9>> -> Ok(Bound)
    <<0>> -> Ok(Ready)
    <<1>> -> Ok(Activate)
    <<2, direction, sequence:64, size:32>> -> {
      use direction <- result.try(read_direction(direction))
      Ok(Header(direction, sequence, size))
    }
    <<3, direction, sequence:64, offset:32, bytes:bytes>> -> {
      use direction <- result.try(read_direction(direction))
      Ok(Chunk(direction, sequence, offset, bytes))
    }
    <<4, direction, sequence:64, offset:32>> -> {
      use direction <- result.try(read_direction(direction))
      Ok(ChunkAck(direction, sequence, offset))
    }
    <<5, direction, sequence:64, consumed>> -> {
      use direction <- result.try(read_direction(direction))
      use disposition <- result.try(case consumed {
        0 -> Ok(channel.Continue)
        1 -> Ok(channel.Final)
        _ -> Error(Nil)
      })
      Ok(Consumed(direction, sequence, disposition))
    }
    <<6, sequence:64, bytes:bytes>> -> {
      use text <- result.try(bit_array.to_string(bytes))
      Ok(End(sequence, text))
    }
    <<7>> -> Ok(Close)
    <<8, bytes:bytes>> -> {
      use value <- result.try(
        bounded_msgpack.decode(bytes) |> result.replace_error(Nil),
      )
      read_close(value) |> result.map(Closed)
    }
    _ -> Error(Nil)
  }
}

fn direction_tag(direction: channel.Direction) -> Int {
  case direction {
    channel.ToHost -> 0
    channel.ToNode -> 1
  }
}

fn read_direction(tag: Int) -> Result(channel.Direction, Nil) {
  case tag {
    0 -> Ok(channel.ToHost)
    1 -> Ok(channel.ToNode)
    _ -> Error(Nil)
  }
}

fn consumption_tag(disposition: channel.Consumption) -> Int {
  case disposition {
    channel.Continue -> 0
    channel.Final -> 1
  }
}

fn bound_text(text: String) -> Result(Nil, Nil) {
  case string.byte_size(text) <= 8192 {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

fn close_value(report: channel.CloseResult) -> mp.MsgPackValue {
  let node = case report.node {
    enforcement.Unreported(reason) ->
      mp.ArrayValue([mp.IntValue(0), mp.StringValue(reason)])
    enforcement.Reported(entries, degraded) ->
      mp.ArrayValue([
        mp.IntValue(1),
        mp.ArrayValue(list.map(entries, mp.StringValue)),
        mp.BoolValue(degraded),
      ])
  }
  let transport = case report.transport {
    channel.TransportJoined -> mp.ArrayValue([mp.IntValue(0)])
    channel.TransportUnresolved(reason) ->
      mp.ArrayValue([mp.IntValue(1), mp.StringValue(reason)])
  }
  let resources = case report.resources {
    channel.ResourcesReleased -> mp.ArrayValue([mp.IntValue(0)])
    channel.ResourcesUnresolved(reason) ->
      mp.ArrayValue([mp.IntValue(1), mp.StringValue(reason)])
  }
  mp.ArrayValue([node, transport, resources])
}

fn read_close(value: mp.MsgPackValue) -> Result(channel.CloseResult, Nil) {
  use #(node, transport, resources) <- result.try(case value {
    mp.ArrayValue([node, transport, resources]) ->
      Ok(#(node, transport, resources))
    _ -> Error(Nil)
  })
  use node <- result.try(case node {
    mp.ArrayValue([mp.IntValue(0), mp.StringValue(reason)]) ->
      Ok(enforcement.Unreported(reason))
    mp.ArrayValue([
      mp.IntValue(1),
      mp.ArrayValue(entries),
      mp.BoolValue(degraded),
    ]) -> {
      use entries <- result.try(
        list.try_map(entries, fn(entry) {
          case entry {
            mp.StringValue(text) -> Ok(text)
            _ -> Error(Nil)
          }
        }),
      )
      Ok(enforcement.Reported(entries, degraded))
    }
    _ -> Error(Nil)
  })
  use transport <- result.try(case transport {
    mp.ArrayValue([mp.IntValue(0)]) -> Ok(channel.TransportJoined)
    mp.ArrayValue([mp.IntValue(1), mp.StringValue(reason)]) ->
      Ok(channel.TransportUnresolved(reason))
    _ -> Error(Nil)
  })
  use resources <- result.try(case resources {
    mp.ArrayValue([mp.IntValue(0)]) -> Ok(channel.ResourcesReleased)
    mp.ArrayValue([mp.IntValue(1), mp.StringValue(reason)]) ->
      Ok(channel.ResourcesUnresolved(reason))
    _ -> Error(Nil)
  })
  Ok(channel.CloseResult(node, transport, resources))
}

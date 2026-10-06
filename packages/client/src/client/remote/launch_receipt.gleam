//// Closed native receipt scanner for whole Launch completion comparison.
////
//// Existing dispatcher receipts can exceed the generic 256-KiB MessagePack
//// profile. This fixed nonrecursive outer scan admits at most 64 bounded output
//// chunks and one bounded terminal, then checks their canonical re-encoding.
//// It transfers no native handle, dispatch permission or retirement witness.

import client/remote/command_binding
import client/remote/custodian
import core/command
import executor/remote/beam_endpoint as transport
import executor/remote/identity
import executor/remote/native
import executor/remote/wire
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import weft/poll

/// Reads the canonical original terminal without accepting a generic wire value.
///
/// ## Examples
/// `terminal(<<>>) == Error(Nil)`.
@internal
pub fn terminal(bytes: BitArray) -> Result(BitArray, Nil) {
  use <- bool.guard(bit_array.byte_size(bytes) > 2_097_152, Error(Nil))
  use body <- result.try(case bytes {
    <<0x92, rest:bits>> -> Ok(rest)
    _ -> Error(Nil)
  })
  use #(count, outputs) <- result.try(receipt_array(body))
  use #(chunks, remaining) <- result.try(receipt_chunks(outputs, count, []))
  use #(terminal, trailing) <- result.try(receipt_binary(remaining, 32_768))
  use <- bool.guard(trailing != <<>>, Error(Nil))
  use canonical <- result.try(
    custodian.receipt(chunks, terminal) |> result.replace_error(Nil),
  )
  use <- bool.guard(canonical != bytes, Error(Nil))
  Ok(terminal)
}

/// Collects only exact historical native bytes under the original fixed grace.
/// It neither replays outputs to the live host nor submits another execution.
///
/// ## Examples
/// `collect(binding, endpoint, ref, key, digest, terminal, deadline, now)`.
@internal
pub fn collect(
  binding: command_binding.Binding,
  endpoint: transport.Config,
  ref: command.CommandRef,
  key: identity.RequestKey,
  digest: identity.Digest,
  terminal: BitArray,
  deadline: Int,
  now: fn() -> Int,
) -> Result(Nil, Nil) {
  use <- bool.guard(bit_array.byte_size(terminal) > 32_768, Error(Nil))
  let collected =
    poll.fold_until(
      within: int.max(0, deadline - now()),
      every: poll.Fixed(25),
      clock: poll.monotonic(),
      from: #(0, 0, []),
      attempt: fn(state) {
        let #(cursor, total, reversed) = state
        let bounded =
          transport.Config(
            ..endpoint,
            within_ms: int.min(endpoint.within_ms, int.max(1, deadline - now())),
          )
        case
          transport.exchange_command(
            bounded,
            ref,
            wire.Query(key, digest, cursor),
          )
        {
          Ok(wire.Output(actual, content, ordinal, bytes))
            if actual == key && content == digest && ordinal == cursor
          -> {
            let size = bit_array.byte_size(bytes)
            case cursor < 64 && size <= 16_384 && total + size <= 1_048_576 {
              True ->
                case native.decode_output(bytes) {
                  Ok(_) ->
                    poll.Pending(
                      #(cursor + 1, total + size, [bytes, ..reversed]),
                    )
                  Error(_) -> poll.Broken(Nil)
                }
              False -> poll.Broken(Nil)
            }
          }
          Ok(wire.Terminal(actual, content, bytes))
            if actual == key && content == digest && bytes == terminal
          ->
            case native.decode_terminal(bytes) {
              Ok(_) -> poll.Settled(list.reverse(reversed))
              Error(_) -> poll.Broken(Nil)
            }
          Ok(wire.Evidence(actual, content, _, _))
            if actual == key && content == digest
          -> poll.Pending(state)
          _ -> poll.Broken(Nil)
        }
      },
    )
  case collected {
    poll.Answer(outputs) ->
      command_binding.receive(
        binding,
        command.native_origin(ref),
        key,
        digest,
        outputs,
        terminal,
      )
      |> result.replace_error(Nil)
    _ -> Error(Nil)
  }
}

fn receipt_array(bytes: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<tag, rest:bits>> if tag >= 0x90 && tag <= 0x9f -> Ok(#(tag - 0x90, rest))
    <<0xdc, count:16, rest:bits>> if count <= 64 -> Ok(#(count, rest))
    <<0xdd, count:32, rest:bits>> if count <= 64 -> Ok(#(count, rest))
    _ -> Error(Nil)
  }
}

fn receipt_chunks(
  bytes: BitArray,
  count: Int,
  reversed: List(BitArray),
) -> Result(#(List(BitArray), BitArray), Nil) {
  case count {
    0 -> Ok(#(list.reverse(reversed), bytes))
    _ -> {
      use #(chunk, rest) <- result.try(receipt_binary(bytes, 16_384))
      receipt_chunks(rest, count - 1, [chunk, ..reversed])
    }
  }
}

fn receipt_binary(
  bytes: BitArray,
  limit: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  use #(size, body) <- result.try(case bytes {
    <<0xc4, size, rest:bits>> -> Ok(#(size, rest))
    <<0xc5, size:16, rest:bits>> -> Ok(#(size, rest))
    <<0xc6, size:32, rest:bits>> -> Ok(#(size, rest))
    _ -> Error(Nil)
  })
  use <- bool.guard(
    size > limit || size > bit_array.byte_size(body),
    Error(Nil),
  )
  case body {
    <<value:size(size)-bytes, rest:bits>> -> Ok(#(value, rest))
    _ -> Error(Nil)
  }
}

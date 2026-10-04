//// Bounded workspace content over the existing small authenticated TLS frames.
////
//// A transfer has one fixed header followed by exact 64-KiB chunks, except its
//// final chunk. The header commits the direction, total length and SHA-256;
//// each chunk commits its offset. The receiver refuses the length before
//// retaining content, and never asks the peer to allocate an arbitrary frame.
//// At most 144 invocation chunks, 512 workspace completion chunks or four
//// Compile completion chunks are admitted. Closed direction tags remain 0, 1
//// and 2 respectively; existing frames retain their exact encoding.
////
//// This boundary transfers bytes, not execution permission. Its caller must
//// authenticate the application scope before receiving and validate the
//// semantic codec before journaling or executing. The caller also owns a
//// finite whole-exchange weft deadline and bounded connection credits. Per-frame
//// TLS deadlines alone cannot bound a whole transfer. No mailbox or writer
//// queue is created here; a single synchronous caller owns each socket.
////
//// Chunks accumulate in reverse order and concatenate once. Temporary memory
//// can include the retained chunks and the completed binary together; the
//// byte ceiling is a content bound, not a VM resident-memory claim. Discard the
//// connection after any refusal; a partially consumed stream is not reusable.

import executor/remote/tls
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tools/workspace_codec

/// Fixed payload size below the existing 256-KiB TLS frame ceiling.
pub const chunk_bytes = 65_536

// Compile completion's closed codec uses core/bounded_msgpack's 256-KiB
// aggregate limit. This is a semantic content ceiling, independent of the TLS
// frame ceiling; the fixed chunk protocol still carries it in four frames.
const max_compile_completion_bytes = 262_144

/// The semantic direction fixes the total admissible content before allocation.
pub type Kind {
  /// One canonical invocation, bounded to nine MiB.
  Invocation

  /// One canonical completion, bounded to thirty-two MiB.
  Completion

  /// One closed physical Compile completion, bounded to 256 KiB.
  CompileCompletion
}

/// A validated bounded sender, with no socket or authority of its own.
pub opaque type Sender {
  Sender(kind: Kind, bytes: BitArray, offset: Int)
}

/// Only a checked header can construct a receiver's remaining byte budget.
pub opaque type Receiver {
  Receiver(
    kind: Kind,
    total: Int,
    digest: BitArray,
    offset: Int,
    chunks: List(BitArray),
  )
}

/// Completion exists only after exact lengths, ordering and digest agree.
pub type Progress {
  /// The next frame must begin at this receiver's exact next offset.
  Receiving(receiver: Receiver)

  /// All bytes arrived intact; semantic validation and custody still follow.
  Complete(bytes: BitArray)
}

/// Fixed errors do not retain peer input or suggest retrying an effect.
pub type Error {
  /// The complete content or header exceeds its direction's byte ceiling.
  InvalidLength

  /// Version, direction, offset, chunk size or final digest differs.
  InvalidFrame

  /// The authenticated stream failed after a possibly partial exchange.
  TransportUncertain
}

/// Creates the header and cursor before sending any bytes.
///
/// ## Examples
///
/// `begin_send(Invocation, bytes)` refuses empty or oversized content.
pub fn begin_send(
  kind: Kind,
  bytes: BitArray,
) -> Result(#(BitArray, Sender), Error) {
  let size = bit_array.byte_size(bytes)
  use Nil <- result.try(check_length(kind, size))
  use Nil <- result.try(case bit_array.bit_size(bytes) == size * 8 {
    True -> Ok(Nil)
    False -> Error(InvalidLength)
  })
  let digest = crypto.hash(crypto.Sha256, bytes)
  let header = <<"LWC", 1, tag(kind), size:32, digest:bits>>
  Ok(#(header, Sender(kind, bytes, 0)))
}

/// Produces exactly one bounded frame and advances its immutable cursor.
///
/// ## Examples
///
/// A sender at the end returns `None`, never an empty data frame.
pub fn next(sender: Sender) -> Option(#(BitArray, Sender)) {
  case sender.bytes {
    <<>> -> None
    bytes -> {
      let count = int.min(chunk_bytes, bit_array.byte_size(bytes))
      case bytes {
        <<chunk:bytes-size(count), rest:bits>> -> {
          let frame = <<
            "LWD",
            1,
            tag(sender.kind),
            sender.offset:32,
            chunk:bits,
          >>
          Some(#(frame, Sender(sender.kind, rest, sender.offset + count)))
        }

        // Only begin_send constructs an aligned cursor. This arm is total even
        // if a future internal representation changes its slicing invariant.
        _ -> None
      }
    }
  }
}

/// Checks direction and the finite total before retaining the first chunk.
///
/// ## Examples
///
/// `begin_receive(Invocation, completion_header)` returns `InvalidFrame`.
pub fn begin_receive(kind: Kind, header: BitArray) -> Result(Receiver, Error) {
  case header {
    <<"LWC", 1, direction, total:32, digest:bytes-size(32)>> -> {
      use Nil <- result.try(check_tag(kind, direction))
      use Nil <- result.try(check_length(kind, total))
      Ok(Receiver(kind, total, digest, 0, []))
    }
    _ -> Error(InvalidFrame)
  }
}

/// Accepts one exact next chunk, without allowing tiny-chunk amplification.
///
/// ## Examples
///
/// Repeating a previous offset returns `InvalidFrame` before retaining it.
pub fn accept(receiver: Receiver, frame: BitArray) -> Result(Progress, Error) {
  let count = int.min(chunk_bytes, receiver.total - receiver.offset)
  case frame {
    <<"LWD", 1, direction, offset:32, chunk:bytes-size(count)>> -> {
      use Nil <- result.try(check_tag(receiver.kind, direction))
      use Nil <- result.try(case offset == receiver.offset {
        True -> Ok(Nil)
        False -> Error(InvalidFrame)
      })
      let chunks = [chunk, ..receiver.chunks]
      let next_offset = offset + count

      // The last frame closes the length budget. Only the digest check can
      // release a complete body; a corrupt peer cannot publish partial success.
      case next_offset == receiver.total {
        False ->
          Ok(Receiving(Receiver(..receiver, offset: next_offset, chunks:)))
        True -> {
          let bytes = chunks |> list.reverse |> bit_array.concat
          case crypto.hash(crypto.Sha256, bytes) == receiver.digest {
            True -> Ok(Complete(bytes))
            False -> Error(InvalidFrame)
          }
        }
      }
    }
    _ -> Error(InvalidFrame)
  }
}

/// Sends bounded content synchronously inside the caller's exchange deadline.
///
/// ## Examples
///
/// `send(socket, Invocation, canonical_request)` grants no execution authority.
pub fn send(
  socket: tls.Connection,
  kind: Kind,
  bytes: BitArray,
) -> Result(Nil, Error) {
  use #(header, sender) <- result.try(begin_send(kind, bytes))
  use Nil <- result.try(tls.send(socket, header) |> transport)
  send_chunks(socket, sender)
}

/// Receives bounded content inside the caller's whole-exchange deadline.
///
/// ## Examples
///
/// `receive(socket, Completion)` returns exact bytes for durable owner receipt.
pub fn receive(socket: tls.Connection, kind: Kind) -> Result(BitArray, Error) {
  use header <- result.try(tls.receive(socket) |> transport)
  use receiver <- result.try(begin_receive(kind, header))
  receive_chunks(socket, receiver)
}

fn send_chunks(socket: tls.Connection, sender: Sender) -> Result(Nil, Error) {
  case next(sender) {
    None -> Ok(Nil)
    Some(#(frame, rest)) -> {
      use Nil <- result.try(tls.send(socket, frame) |> transport)
      send_chunks(socket, rest)
    }
  }
}

fn receive_chunks(
  socket: tls.Connection,
  receiver: Receiver,
) -> Result(BitArray, Error) {
  use frame <- result.try(tls.receive(socket) |> transport)
  use progress <- result.try(accept(receiver, frame))
  case progress {
    Receiving(next) -> receive_chunks(socket, next)
    Complete(bytes) -> Ok(bytes)
  }
}

fn check_length(kind: Kind, size: Int) -> Result(Nil, Error) {
  let maximum = case kind {
    Invocation -> workspace_codec.max_invocation_bytes
    Completion -> workspace_codec.max_completion_bytes
    CompileCompletion -> max_compile_completion_bytes
  }
  case size > 0 && size <= maximum {
    True -> Ok(Nil)
    False -> Error(InvalidLength)
  }
}

fn check_tag(kind: Kind, value: Int) -> Result(Nil, Error) {
  case tag(kind) == value {
    True -> Ok(Nil)
    False -> Error(InvalidFrame)
  }
}

fn tag(kind: Kind) -> Int {
  case kind {
    Invocation -> 0
    Completion -> 1
    CompileCompletion -> 2
  }
}

fn transport(value: Result(a, tls.Error)) -> Result(a, Error) {
  result.map_error(value, fn(_) { TransportUncertain })
}

//// The frames a laptop's lane sends to a live session feed, put back together
//// from their pieces (protocol-change/108, `108.send.1`).
////
//// A lane transmits one frame at a time, and a frame may be larger than one
//// stable-exchange envelope carries, so the laptop cuts it into pieces and
//// sends them in order, as a `Chunk` of `client/session_move` places a piece in
//// a file. This module is the box's half. It is a pure value: it holds no
//// process and reads no clock, so the feed host owns the mailbox and this module
//// owns the rules, and each rule is checked by `feed_pieces_test` under
//// fixed-seed generated interleavings.
////
//// ## What the rules promise
////
//// The laptop numbers its frames from one. The box admits the pieces of frame
//// `n` in order, and the piece that reaches the frame's `total` completes it,
//// which is the moment the feed host hands it to its command filter. Three
//// facts follow, and together they say the gateway receives each frame once and
//// whole whatever the link did to the answers.
////
//// - A piece the box has already admitted is answered again and changes
////   nothing, so the laptop may resend a piece whose answer it lost. This
////   covers a piece of the frame being assembled, and every piece of an earlier
////   frame, since the next frame number advances only when a frame completes.
//// - A piece out of order, a piece that disagrees with the frame's `total`, or
////   a piece of a frame other than the next, is refused and changes nothing.
//// - Only one frame is ever partly held. It is bounded by the page socket's own
////   frame bound, and `drop` discards it when the feed ends.
////
//// ## Flow
////
//// `new` → `admit` → `drop`
////
//// 1. `new` starts at frame one with nothing held.
//// 2. `admit` takes one piece and says whether it was held, completed a frame,
////    repeated one already admitted, or was refused.
//// 3. `drop` discards a partly received frame when the feed ends.

import client/remote_feed.{type Piece}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The frame being assembled.
type Partial {
  Partial(
    /// The frame's number.
    n: Int,
    /// The frame's whole size in bytes.
    total: Int,
    /// The bytes admitted so far, which is where the next piece must begin.
    received: Int,
    /// The pieces admitted, newest first.
    chunks: List(String),
  )
}

/// What a feed has admitted of the lane's frames. It is opaque so that every
/// change goes through a rule of this module.
pub opaque type Pieces {
  Pieces(
    /// The number the next frame must carry.
    next: Int,
    /// The one frame being assembled, if any.
    partial: Option(Partial),
  )
}

/// Why a piece is refused. A refused piece changes nothing.
pub type Refusal {
  /// The piece does not begin where the frame's admitted bytes end, or it
  /// begins a frame at an offset other than zero.
  OutOfOrder

  /// The piece is of a frame that is not the next one.
  WrongFrame

  /// The piece names a frame size other than the one its frame began with.
  Inconsistent
}

/// What admitting a piece did.
pub type Admission {
  /// The piece was new and the frame still lacks bytes.
  Held(
    /// The state after the piece.
    pieces: Pieces,
  )

  /// The piece was new and the frame is now whole.
  Completed(
    /// The state after the frame, which expects the following number.
    pieces: Pieces,
    /// The frame's text, byte for byte as the lane wrote it.
    frame: String,
  )

  /// The piece was admitted before. It is answered again and nothing changes.
  Repeated

  /// The piece is refused. Nothing changes.
  Refused(
    /// Why.
    why: Refusal,
  )
}

/// A feed that has admitted nothing: the next frame is number one.
///
/// ## Examples
///
/// ```gleam
/// assert feed_pieces.next(feed_pieces.new()) == 1
/// ```
pub fn new() -> Pieces {
  Pieces(next: 1, partial: None)
}

/// Admits one piece. The piece's own bounds (`offset + size <= total`, at most
/// `remote_feed.piece_bytes`, a total of at most `remote_feed.frame_bytes`) are
/// the codec's, so this decides only order and repetition.
///
/// ## Examples
///
/// ```gleam
/// let piece = remote_feed.Piece(feed: "f", n: 1, offset: 0, total: 2, text: "{}")
/// let assert feed_pieces.Completed(frame: "{}", ..) =
///   feed_pieces.admit(feed_pieces.new(), piece)
/// ```
pub fn admit(pieces: Pieces, piece: Piece) -> Admission {
  case piece.n < pieces.next, piece.n == pieces.next {
    // Every frame before the next one completed, so each of its pieces was
    // admitted.
    True, _ -> Repeated
    False, False -> Refused(WrongFrame)
    False, True -> continue_frame(pieces, piece)
  }
}

/// Admits a piece of the next frame, which is either the first piece of a frame
/// or one more piece of the frame being assembled.
fn continue_frame(pieces: Pieces, piece: Piece) -> Admission {
  case pieces.partial {
    None ->
      case piece.offset {
        0 -> extend(pieces.next, piece.total, 0, [], piece)
        _ -> Refused(OutOfOrder)
      }
    Some(partial) ->
      case piece.total == partial.total, piece.offset <= partial.received {
        False, _ -> Refused(Inconsistent)
        True, False -> Refused(OutOfOrder)

        // The piece starts inside what was admitted, so it was admitted.
        True, True if piece.offset < partial.received -> Repeated
        True, True ->
          extend(
            partial.n,
            partial.total,
            partial.received,
            partial.chunks,
            piece,
          )
      }
  }
}

/// Adds a piece that begins exactly where the admitted bytes end.
fn extend(
  n: Int,
  total: Int,
  received: Int,
  chunks: List(String),
  piece: Piece,
) -> Admission {
  let received = received + string.byte_size(piece.text)
  let chunks = [piece.text, ..chunks]

  // The piece that reaches the frame's size completes it, and the box then
  // expects the next number. A shorter total leaves the frame partly held.
  case received >= total {
    True ->
      Completed(
        pieces: Pieces(next: n + 1, partial: None),
        frame: string.concat(list.reverse(chunks)),
      )
    False ->
      Held(Pieces(
        next: n,
        partial: Some(Partial(n:, total:, received:, chunks:)),
      ))
  }
}

/// Discards a partly received frame, which a lapse or a detach does.
///
/// ## Examples
///
/// ```gleam
/// assert feed_pieces.held_bytes(feed_pieces.drop(feed_pieces.new())) == 0
/// ```
pub fn drop(pieces: Pieces) -> Pieces {
  Pieces(..pieces, partial: None)
}

/// The number the next frame must carry.
///
/// ## Examples
///
/// ```gleam
/// assert feed_pieces.next(feed_pieces.new()) == 1
/// ```
pub fn next(pieces: Pieces) -> Int {
  pieces.next
}

/// How many bytes of a frame are held while it is assembled.
///
/// ## Examples
///
/// ```gleam
/// assert feed_pieces.held_bytes(feed_pieces.new()) == 0
/// ```
pub fn held_bytes(pieces: Pieces) -> Int {
  case pieces.partial {
    Some(partial) -> partial.received
    None -> 0
  }
}

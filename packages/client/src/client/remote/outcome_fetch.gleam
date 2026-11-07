//// Fetching a tool outcome too large for one frame, in pieces
//// (protocol-change/110).
////
//// When an untrusted executor's reply to a `run` or a lookup would not fit a
//// frame, it sends `Oversized` with the size and SHA-256 of the outcome's
//// encoding, and the orchestrator's link asks for the encoding piece by piece.
//// This module is that fetch's bookkeeping, with no process and no socket: what
//// is held, which offset to ask for next, and when to stop. The link owns the
//// requests and the asker; it calls `begin` on an `Oversized`, `took` on each
//// piece, and `restart` when the executor describes the outcome differently.
////
//// The executor is assumed hostile, so every answer is bounded. A fetch holds at
//// most `untrusted_wire.max_outcome_bytes`. A piece of another description
//// restarts the fetch from nothing, at most `max_restarts` times. A piece at
//// another offset than the one asked is asked for again, and the steps of one
//// fetch are bounded by `max_steps`. Only bytes whose size and SHA-256 both
//// match are handed back, and only then does the link decode them.
////
//// ## Flow
////
//// `begin` → `took` → `restart`

import client/remote/blob_transfer
import client/remote/untrusted_wire.{type OutcomePiece}
import gleam/bit_array
import gleam/bool
import gleam/list

/// How many times one fetch starts over because the executor described the
/// outcome differently, or the bytes did not match. An honest executor encodes
/// the same stored outcome the same way, so a second description is already a
/// fault; three allow for an outcome that changed between the first answer and
/// the ledger's.
pub const max_restarts = 3

/// One fetch in progress.
pub opaque type Fetch {
  Fetch(
    /// The encoding's size, as last described.
    size: Int,
    /// The encoding's SHA-256, as last described.
    digest: String,
    /// The pieces held, newest first.
    chunks: List(BitArray),
    /// The bytes held.
    held: Int,
    /// The restarts spent.
    restarts: Int,
    /// The pieces taken, counted against `max_steps`.
    steps: Int,
  )
}

/// What the link does after a piece or a description.
pub type Step {
  /// Ask for the piece at `offset`, with the fetch as it now stands.
  Ask(fetch: Fetch, offset: Int)

  /// Every byte is held and matches: decode these.
  Done(bytes: BitArray)

  /// Stop, and answer the asker with the lost form of its reply.
  GiveUp(reason: String)
}

/// Starts a fetch of an outcome described as `size` bytes with SHA-256 `digest`.
/// A size of zero, or over `untrusted_wire.max_outcome_bytes`, is refused, as is
/// a digest of the wrong form.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_too_large) =
///   outcome_fetch.begin(untrusted_wire.max_outcome_bytes + 1, digest)
/// ```
pub fn begin(size: Int, digest: String) -> Result(Fetch, String) {
  use Nil <- check(size, digest)
  Ok(Fetch(size:, digest:, chunks: [], held: 0, restarts: 0, steps: 0))
}

/// The bytes a fetch holds, which is the offset it asks for next.
///
/// ## Examples
///
/// ```gleam
/// // outcome_fetch.held(fetch) == 0
/// ```
pub fn held(fetch: Fetch) -> Int {
  fetch.held
}

/// Whether a fetch is of the outcome described as `size` and `digest`.
///
/// ## Examples
///
/// ```gleam
/// // assert outcome_fetch.describes(fetch, size, digest)
/// ```
pub fn describes(fetch: Fetch, size: Int, digest: String) -> Bool {
  fetch.size == size && fetch.digest == digest
}

/// Starts the fetch over for a new description, spending a restart. A fetch
/// that has spent `max_restarts`, or a description that `begin` would refuse,
/// gives up.
///
/// ## Examples
///
/// ```gleam
/// // outcome_fetch.restart(fetch, size, digest) == outcome_fetch.Ask(_, 0)
/// ```
pub fn restart(fetch: Fetch, size: Int, digest: String) -> Step {
  use <- bool.guard(
    when: fetch.restarts >= max_restarts,
    return: GiveUp("the executor kept describing the outcome differently"),
  )

  // A new description is held to the same bounds as the first.
  case begin(size, digest) {
    Ok(fresh) ->
      Ask(Fetch(..fresh, restarts: fetch.restarts + 1, steps: fetch.steps), 0)
    Error(reason) -> GiveUp(reason)
  }
}

/// Takes the executor's answer to the last piece asked for.
///
/// A piece of another description restarts the fetch. A piece at another
/// offset than the bytes held is asked for again. A piece that runs past the
/// size, an empty piece before the end, and an answer of nothing held each give
/// up. The piece that reaches the size is checked against the digest before
/// the bytes are handed back; a mismatch restarts the fetch.
///
/// ## Examples
///
/// ```gleam
/// // outcome_fetch.took(fetch, untrusted_wire.OutcomeServed(size, digest, 0, bytes))
/// ```
pub fn took(fetch: Fetch, piece: OutcomePiece) -> Step {
  let fetch = Fetch(..fetch, steps: fetch.steps + 1)
  use <- bool.guard(
    when: fetch.steps > max_steps(fetch.size),
    return: GiveUp("the executor did not converge on the outcome"),
  )

  // A served piece is judged against the description and the bytes held; any
  // other answer ends the fetch.
  case piece {
    untrusted_wire.OutcomeNotHeld(reason:) ->
      GiveUp("the executor holds no ended outcome: " <> reason)
    untrusted_wire.OutcomeServed(size:, digest:, offset:, bytes:) ->
      case describes(fetch, size, digest), offset == fetch.held {
        False, _ -> restart(fetch, size, digest)
        True, False -> Ask(fetch, fetch.held)
        True, True -> appended(fetch, bytes)
      }
  }
}

/// Adds a piece that starts at the bytes held, and checks the whole once the
/// size is reached.
fn appended(fetch: Fetch, bytes: BitArray) -> Step {
  let length = bit_array.byte_size(bytes)
  use <- bool.guard(
    when: length == 0 || fetch.held + length > fetch.size,
    return: GiveUp("the executor served a piece outside the outcome"),
  )
  let fetch =
    Fetch(..fetch, chunks: [bytes, ..fetch.chunks], held: fetch.held + length)
  use <- bool.guard(
    when: fetch.held < fetch.size,
    return: Ask(fetch, fetch.held),
  )
  let whole = bit_array.concat(list.reverse(fetch.chunks))

  // The digest is the last word: bytes that do not match are fetched again.
  case blob_transfer.digest_of(whole) == fetch.digest {
    True -> Done(whole)
    False -> restart(fetch, fetch.size, fetch.digest)
  }
}

/// The most pieces one fetch takes: every piece once per start, and a few
/// repeats besides.
fn max_steps(size: Int) -> Int {
  let pieces =
    { size + untrusted_wire.max_piece_bytes - 1 }
    / untrusted_wire.max_piece_bytes
  pieces * { max_restarts + 1 } + 8
}

/// Refuses a description outside the bounds, then continues.
fn check(
  size: Int,
  digest: String,
  next: fn(Nil) -> Result(Fetch, String),
) -> Result(Fetch, String) {
  use <- bool.guard(
    when: size < 1 || size > untrusted_wire.max_outcome_bytes,
    return: Error("the outcome's size is outside what the link fetches"),
  )
  use <- bool.guard(
    when: !blob_transfer.is_digest(digest),
    return: Error("the outcome's digest is not a SHA-256"),
  )
  next(Nil)
}

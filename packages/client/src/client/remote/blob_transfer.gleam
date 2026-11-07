//// Placing a blob on an untrusted executor, in pieces (protocol-change/110).
////
//// An untrusted executor has no egress, so bytes a session needs there that are
//// not a Git state, a Go module archive for instance, come from the
//// orchestrator. A **blob** is such a run of bytes, named by the lower-case hex
//// SHA-256 of its contents and its size. This module is the vocabulary both ends
//// share (a piece, the executor's verdict on it, how far a blob has got) and the
//// orchestrator's half of the transfer: `describe` reads a file's digest and
//// size, and `place` sends it through a `Link` until the executor holds it.
////
//// The executor's half is `client/remote/blob_service`, which judges every piece
//// and checks the whole blob's size and digest before the blob exists. Only the
//// orchestrator sends blob bytes; nothing here lets the executor send any.
////
//// ## Flow
////
//// `describe` → `hash_file` → `place`
////
//// 1. `describe` reads a file's size and hands it to `hash_file`, which hashes
////    it in pieces, so a blob of a gigabyte costs a piece of memory.
//// 2. `place` asks how far the blob has got, sends the piece at that offset, and
////    follows each verdict until the executor answers `Stored`, refuses, or stops
////    converging.

import client/state_object
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/int
import gleam/result
import gleam/string
import host/bootstrap
import simplifile

/// The bytes the orchestrator sends in one piece: half of
/// `untrusted_wire.max_piece_bytes`, so a 200 MiB archive is 25 exchanges and
/// one piece is a small part of a frame's budget.
pub const piece_bytes = 8_388_608

/// The most bytes one piece may carry. A receiver refuses a longer one. It is
/// `untrusted_wire.max_piece_bytes`, which fits a frame after base64.
pub const max_piece_bytes = 16_777_216

/// How many corrections of the offset one placement follows before it stops. A
/// receiver that keeps correcting is not converging.
pub const max_resyncs = 8

/// A blob's name and length. `digest` is 64 lower-case hexadecimal digits.
pub type Blob {
  Blob(
    /// The SHA-256 of the blob's bytes, in lower-case hex.
    digest: String,
    /// The blob's length in bytes, at least 1.
    size: Int,
  )
}

/// One piece of a blob, carrying the blob's description so the receiver keeps
/// no announcement and a resumed placement says the same as the first.
pub type Piece {
  Piece(
    /// The blob the piece belongs to.
    blob: Blob,
    /// Where in the blob the piece starts.
    offset: Int,
    /// The piece, between 1 and `max_piece_bytes` bytes.
    bytes: BitArray,
  )
}

/// The executor's answer to a piece.
pub type Verdict {
  /// The piece is held, or was held already; `held` is the bytes held now.
  Accepted(held: Int)

  /// The whole blob is held, its size and digest checked, and it is claimed for
  /// the binding that sent the piece.
  Stored

  /// The piece did not start where the executor stands, which is `expected`.
  /// The sender continues from there.
  OutOfOrder(expected: Int)

  /// The executor said no, for a reason sending again cannot cure: a malformed
  /// description, a blob over a bound, a binding it does not hold, or a whole
  /// blob that did not match its description.
  Refused(reason: String)

  /// The executor could not decide, for a reason that may pass.
  Failed(reason: String)
}

/// How far a blob has got on the executor.
pub type Stage {
  /// The executor holds none of it.
  Absent

  /// The executor holds the first `held` bytes.
  Partial(held: Int)

  /// The executor holds the whole blob, checked, and the binding that asked
  /// has claimed it.
  Complete
}

/// The two questions a placement asks of an executor. `Error(Nil)` is silence:
/// the link is down or the answer was late. It is never a refusal.
pub type Link {
  Link(
    /// How far a blob has got, by digest. `Ok(Error(reason))` is an executor
    /// that could not say or would not claim the blob.
    stage: fn(String) -> Result(Result(Stage, String), Nil),
    /// Sends one piece and waits for the verdict.
    put: fn(Piece) -> Result(Verdict, Nil),
  )
}

/// Why a placement ended without the blob in place.
pub type Failure {
  /// The executor refused, finally.
  Declined(reason: String)

  /// The executor did not answer. Placing again resumes where it stands.
  Silent

  /// The executor could not decide, or the file could not be read.
  Faulted(reason: String)

  /// The executor kept answering without getting closer to the end.
  Stalled
}

/// A placement that ended with the blob in place.
pub type Placed {
  Placed(
    /// The blob.
    blob: Blob,
    /// The pieces sent, zero when the executor already held it.
    sent: Int,
  )
}

/// Where a placement stands.
type Progress {
  Progress(offset: Int, sent: Int, resyncs: Int)
}

/// Whether the offset a verdict named moved the placement on or corrected it.
type Step {
  /// The executor accepted the piece and named the bytes it holds.
  Continued

  /// The executor named another offset than the one sent.
  Corrected
}

/// Whether `text` is a blob's digest: 64 lower-case hexadecimal digits. Only
/// such a text ever becomes a file name.
///
/// ## Examples
///
/// ```gleam
/// assert !blob_transfer.is_digest("ABC")
/// ```
pub fn is_digest(text: String) -> Bool {
  state_object.is_hash(text)
}

/// Checks a description: a well-formed digest and a size of at least 1.
///
/// ## Examples
///
/// ```gleam
/// assert blob_transfer.valid(blob_transfer.Blob("x", 1))
///   == Error("the digest is not 64 lower-case hexadecimal digits")
/// ```
pub fn valid(blob: Blob) -> Result(Blob, String) {
  use <- bool.guard(
    when: !is_digest(blob.digest),
    return: Error("the digest is not 64 lower-case hexadecimal digits"),
  )
  use <- bool.guard(
    when: blob.size < 1,
    return: Error("a blob is at least one byte"),
  )
  Ok(blob)
}

/// The lower-case hex SHA-256 of some bytes, the form a blob is named by.
///
/// ## Examples
///
/// ```gleam
/// assert string.length(blob_transfer.digest_of(<<"x">>)) == 64
/// ```
pub fn digest_of(bytes: BitArray) -> String {
  crypto.hash(crypto.Sha256, bytes) |> hex
}

/// Hashes a file in pieces of `piece_bytes` and answers its description, so the
/// file is read once and never held whole.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(blob) = blob_transfer.describe("/srv/cache/mod.tar")
/// ```
pub fn describe(path: String) -> Result(Blob, String) {
  use info <- result.try(
    simplifile.file_info(path)
    |> result.map_error(fn(error) {
      "the blob cannot be inspected: " <> simplifile.describe_error(error)
    }),
  )
  use digest <- result.try(hash_file(path, info.size))
  valid(Blob(digest:, size: info.size))
}

/// Hashes the first `size` bytes of a file, `piece_bytes` at a time. A file
/// shorter than `size` is an error, because the description would be a lie.
///
/// ## Examples
///
/// ```gleam
/// // blob_transfer.hash_file("/srv/cache/mod.tar", 4096)
/// ```
pub fn hash_file(path: String, size: Int) -> Result(String, String) {
  hashing(path, size, 0, crypto.new_hasher(crypto.Sha256))
}

/// One step of `hash_file`: the piece at `offset`, folded into the hasher.
fn hashing(
  path: String,
  size: Int,
  offset: Int,
  hasher: crypto.Hasher,
) -> Result(String, String) {
  use <- bool.lazy_guard(when: offset >= size, return: fn() {
    Ok(hex(crypto.digest(hasher)))
  })
  use bytes <- result.try(bootstrap.read_range(
    path,
    offset,
    int.min(piece_bytes, size - offset),
  ))

  // A read that comes back empty before the size is a file that shrank.
  case bit_array.byte_size(bytes) {
    0 -> Error("the file is shorter than its size")
    length ->
      hashing(path, size, offset + length, crypto.hash_chunk(hasher, bytes))
  }
}

/// Places the file at `path`, described as `blob`, on the executor `link`
/// reaches, and answers once the executor holds it.
///
/// The executor is asked how far the blob has got first, so a blob it holds is
/// claimed and nothing is sent, and an interrupted placement resumes at the
/// bytes it holds. Each piece is read from the file at the offset the executor
/// last reported, which is never trusted beyond the blob's size. The loop is
/// bounded by the pieces the blob needs plus `max_resyncs`.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(blob) = blob_transfer.describe(path)
/// // let assert Ok(placed) = blob_transfer.place(path, blob, link)
/// ```
pub fn place(path: String, blob: Blob, link: Link) -> Result(Placed, Failure) {
  use blob <- result.try(valid(blob) |> result.map_error(Faulted))

  // The stage decides where to begin; a blob already held is the no-op that
  // makes placing the same archive twice cheap.
  case link.stage(blob.digest) {
    Error(Nil) -> Error(Silent)
    Ok(Error(reason)) -> Error(Declined(reason))
    Ok(Ok(Complete)) -> Ok(Placed(blob:, sent: 0))
    Ok(Ok(Partial(held:))) ->
      sending(path, blob, link, Progress(offset: held, sent: 0, resyncs: 0))
    Ok(Ok(Absent)) ->
      sending(path, blob, link, Progress(offset: 0, sent: 0, resyncs: 0))
  }
}

/// Sends the piece at the current offset and follows the verdict.
fn sending(
  path: String,
  blob: Blob,
  link: Link,
  progress: Progress,
) -> Result(Placed, Failure) {
  let budget = pieces_in(blob) + max_resyncs
  use <- bool.guard(
    when: progress.sent + progress.resyncs > budget,
    return: Error(Stalled),
  )
  use piece <- result.try(piece_at(path, blob, progress.offset))
  let progress = Progress(..progress, sent: progress.sent + 1)

  // Every verdict but `Stored` and `Accepted` ends the placement, and only an
  // offset that lies inside the blob is followed.
  case link.put(piece) {
    Error(Nil) -> Error(Silent)
    Ok(Stored) -> Ok(Placed(blob:, sent: progress.sent))
    Ok(Refused(reason:)) -> Error(Declined(reason))
    Ok(Failed(reason:)) -> Error(Faulted(reason))
    Ok(Accepted(held:)) -> followed(path, blob, link, progress, held, Continued)
    Ok(OutOfOrder(expected:)) ->
      followed(path, blob, link, progress, expected, Corrected)
  }
}

/// Continues at the offset a verdict named, counting a correction.
fn followed(
  path: String,
  blob: Blob,
  link: Link,
  progress: Progress,
  offset: Int,
  step: Step,
) -> Result(Placed, Failure) {
  use <- bool.guard(
    when: offset < 0 || offset >= blob.size,
    return: Error(Faulted("the executor named an offset outside the blob")),
  )

  // Only a correction spends the placement's allowance of resyncs.
  let resyncs = case step {
    Corrected -> progress.resyncs + 1
    Continued -> progress.resyncs
  }

  sending(path, blob, link, Progress(..progress, offset:, resyncs:))
}

/// How many pieces a blob is cut into.
fn pieces_in(blob: Blob) -> Int {
  { blob.size + piece_bytes - 1 } / piece_bytes
}

/// Reads the piece of the file at `offset`.
fn piece_at(path: String, blob: Blob, offset: Int) -> Result(Piece, Failure) {
  let length = int.min(piece_bytes, blob.size - offset)
  use bytes <- result.try(
    bootstrap.read_range(path, offset, length) |> result.map_error(Faulted),
  )
  use <- bool.guard(
    when: bit_array.byte_size(bytes) != length,
    return: Error(Faulted("the file is shorter than the blob's size")),
  )
  Ok(Piece(blob:, offset:, bytes:))
}

/// Lower-case hexadecimal of some bytes.
fn hex(bytes: BitArray) -> String {
  bit_array.base16_encode(bytes) |> string.lowercase
}

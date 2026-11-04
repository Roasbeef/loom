//// Moving a repository state between two nodes' stores, one piece at a time
//// (protocol-change/107, "Send").
////
//// A state is a bundle the sender's store holds under its hash
//// (`client/state_store`). It crosses a link in pieces of at most `chunk_bytes`,
//// the size `client/session_move` uses for a session file, each carrying the
//// state's description and the offset it starts at, and each answered with a
//// verdict before the next is sent. This module is the vocabulary of those
//// messages, the receiving end that writes them into a store, the sending end
//// that cuts a held bundle into them, and the loops that drive a transfer to its
//// end. It performs no process work of its own. The orchestrator port and the
//// executor host carry the messages (`client/remote/orchestrator_port`,
//// `client/remote/host`), `client/state_service` gives the store one owner, and
//// `client/remote/state_link` turns an address into the `Link` the loops use.
////
//// ## What differs from a session move
////
//// A session move restarts from zero after any failure. A state transfer
//// resumes. The receiver answers every piece with the number of bytes it now
//// holds, `StateStatus` asks the same without sending a piece, and a sender that
//// lost its connection asks, then continues at that offset. A piece at the wrong
//// offset is refused with the offset the receiver expects, and the sender goes
//// on from there. A piece the receiver already holds is accepted again and the
//// answer says where the receiver stands, which is what makes a resent piece
//// harmless. A finished state is never written twice: a piece for a state the
//// store already holds is accepted with the whole size, and `StateStatus` says
//// `Complete`.
////
//// ## What the receiver trusts
////
//// Nothing in a piece. The description is validated, its size is compared with
//// the store's limit before any byte is written, the piece must lie inside the
//// declared size and be no larger than `chunk_bytes`, and the last piece makes
//// the state only if the bytes' size and SHA-256 are the description's. A
//// mismatch discards the half-written file and stores nothing. The description's
//// commits and the bundle's own header are compared at apply
//// (`client/state_object.verify_bundle`), where a repository is about to be
//// touched.
////
//// ## Flow
////
//// `take` → `stage` → `serve` → `send` → `relay` → `pull` → `transfer`
////
//// 1. `take` is the receiver's answer to one piece, and `stage` its answer to
////    a status question. `serve` cuts one piece out of a held state for a peer
////    that fetches.
//// 2. `send` pushes a state this node holds to a link, `relay` copies a state
////    from one link to another without holding it, and `pull` fetches a state
////    from a link into this node's store.
//// 3. All three are `transfer` over a different source of pieces and a different
////    place to put them. It asks where the destination stands, takes the piece
////    at that offset from the source, hands it to the destination and continues
////    at the offset the destination reports, until the destination holds the
////    whole state or a verdict, a silence or the piece budget ends it.

import client/state_object.{type State}
import client/state_store.{type Store}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import host/bootstrap

/// The largest piece sent in one message, in bytes: the session move's, so one
/// lost message costs the same and the link's other traffic moves between pieces.
pub const chunk_bytes = 262_144

/// How many times one transfer follows a receiver's correction of the offset
/// before it gives up. A receiver that keeps correcting is not converging.
pub const max_resyncs = 8

/// One piece of a state's bundle, with enough to place it without any other
/// state at the receiver.
pub type Piece {
  Piece(
    /// The state the piece belongs to, declared with every piece so the
    /// receiver needs no memory of an announcement and a resumed transfer
    /// carries the same words as the first.
    state: State,
    /// Where in the bundle the piece starts.
    offset: Int,
    /// The piece itself, between one byte and `chunk_bytes`.
    bytes: BitArray,
  )
}

/// Why a receiver said no. Each is about what it found in the piece or in its
/// store, so a sender treats the answer as final except for `OutOfOrder`, which
/// says where to go on from.
pub type Refusal {
  /// The description is not one: its hash, size or commit ids are malformed.
  BadState(reason: String)

  /// The piece does not lie inside the declared size, or is empty or longer
  /// than `chunk_bytes`.
  BadPiece(reason: String)

  /// The declared size is more than this node's store admits. Nothing was
  /// written.
  TooLarge(limit: Int)

  /// The store has no room for the piece. The half-written file was removed.
  NoRoom(reason: String)

  /// The piece did not start where the receiver stands. `expected` is the bytes
  /// it holds, which is where the sender continues.
  OutOfOrder(expected: Int)

  /// The whole bundle arrived and is not the one described. It was discarded
  /// and nothing was stored.
  Mismatch(reason: String)

  /// This node keeps no state store.
  NotServing
}

/// The receiver's answer to a piece.
pub type Verdict {
  /// The piece is held, or was held already. `held` is the bytes the receiver
  /// has now, the whole size once the state is complete.
  Accepted(held: Int)

  /// The receiver looked and said no.
  Refused(refusal: Refusal)

  /// The receiver could not decide, for a reason that may pass. The sender asks
  /// again.
  Failed(reason: String)
}

/// How far a state has got at one node.
pub type Stage {
  /// The node holds no bytes of it.
  Absent

  /// The node holds a prefix of `held` bytes and no record.
  Partial(held: Int)

  /// The node holds the whole state and its record.
  Complete
}

/// What a node answers to a request for one piece of a state it holds.
pub type Fetched {
  /// The piece starting at the offset asked for, with the state's description.
  Served(piece: Piece)

  /// The node holds no such state.
  NotHeld

  /// The node could not read the piece, for the reason given.
  FetchFailed(reason: String)
}

/// What a node does with the three questions about a state, as the orchestrator
/// port and the executor host call it. The daemon supplies it, so neither carrier
/// knows the store. Each function is called from a run of its own, linked to the
/// carrier and cancelled with the requester, so one may take as long as it
/// needs.
pub type Endpoint {
  Endpoint(
    /// Takes one piece into the store.
    take: fn(Piece) -> Verdict,
    /// How far a state has got, given its hash. `Error` is a store that could
    /// not say, which is never read as `Absent`.
    stage: fn(String) -> Result(Stage, String),
    /// Cuts one piece out of a held state, given the hash and the offset.
    serve: fn(String, Int) -> Fetched,
  )
}

/// A way to reach a node's three answers. `Error(Nil)` is silence: the node is
/// unreachable, nothing is registered there, or the answer was late. It is not a
/// refusal, and the same question may be asked again.
pub type Link {
  Link(
    /// Asks how far a state has got.
    stage: fn(String) -> Result(Stage, Nil),
    /// Sends one piece and waits for the verdict.
    piece: fn(Piece) -> Result(Verdict, Nil),
    /// Asks for the piece at an offset of a state the node holds.
    fetch: fn(String, Int) -> Result(Fetched, Nil),
  )
}

/// How a transfer ended.
pub type Outcome {
  /// The destination holds the whole state.
  Delivered

  /// The destination refused, for a reason that resending cannot cure.
  Declined(refusal: Refusal)

  /// A node did not answer. Nothing is lost: the same transfer starts again at
  /// whatever the destination holds.
  Silent

  /// A node could not decide, or could not be read, for the reason given.
  Faulted(reason: String)

  /// The destination kept answering without getting closer to the end, or the
  /// source offered no piece for the offset it asked for.
  Stalled
}

/// A source of pieces: the piece at an offset, or the outcome that ends the
/// transfer when there is none.
type Source =
  fn(Int) -> Result(Piece, Outcome)

/// Where pieces go: the verdict for a piece, or silence.
type Sink =
  fn(Piece) -> Result(Verdict, Nil)

/// Where a transfer stands: the offset to send next, the pieces sent, and the
/// corrections followed.
type Progress {
  Progress(offset: Int, sent: Int, resyncs: Int)
}

/// The endpoint of a node that keeps no states: every piece is refused with
/// `NotServing`, it holds nothing, and it has nothing to serve.
///
/// ## Examples
///
/// ```gleam
/// assert state_transfer.declining().stage("anything") == Ok(state_transfer.Absent)
/// ```
pub fn declining() -> Endpoint {
  Endpoint(
    take: fn(_piece) { Refused(NotServing) },
    stage: fn(_hash) { Ok(Absent) },
    serve: fn(_hash, _offset) { NotHeld },
  )
}

/// The endpoint over a store the caller owns and serializes, reading the clock
/// the caller supplies.
///
/// ## Examples
///
/// ```gleam
/// // state_transfer.endpoint(store, fn() { bootstrap.system_time_ms() / 1000 })
/// ```
pub fn endpoint(store: Store, now_s: fn() -> Int) -> Endpoint {
  Endpoint(
    take: fn(piece) { take(store, piece, now_s()) },
    stage: fn(hash) { stage(store, hash) },
    serve: fn(hash, offset) { serve(store, hash, offset) },
  )
}

/// A refusal in words, for a log line and for the reason an aborted transfer
/// reports.
///
/// ## Examples
///
/// ```gleam
/// assert state_transfer.describe(state_transfer.OutOfOrder(expected: 5))
///   == "a piece did not start at offset 5"
/// ```
pub fn describe(refusal: Refusal) -> String {
  case refusal {
    BadState(reason:) -> "the state is not valid: " <> reason
    BadPiece(reason:) -> "the piece is not valid: " <> reason
    TooLarge(limit:) ->
      "the state is more than the "
      <> int.to_string(limit)
      <> " bytes this node stores"
    NoRoom(reason:) -> "this node has no room: " <> reason
    OutOfOrder(expected:) ->
      "a piece did not start at offset " <> int.to_string(expected)
    Mismatch(reason:) ->
      "the received state is not the one described: " <> reason
    NotServing -> "this node keeps no state store"
  }
}

// --- the receiving end ------------------------------------------------------------

/// Takes one piece into the store.
///
/// The piece is judged before the disk is touched: a malformed description, a
/// size over the store's limit and a piece outside the declared size are each
/// refused without a byte written. A state the store already holds answers
/// `Accepted` with its size, so the last piece of a finished transfer is
/// harmless when repeated. Otherwise the piece must start at the bytes held: a
/// piece beyond them is refused with the offset expected, and one wholly inside
/// them is a repeat and is accepted again with the bytes held, never written. The
/// piece that reaches the declared size makes the state through
/// `state_store.finish`, which compares the hash and the size and stores nothing
/// on a mismatch.
///
/// ## Examples
///
/// ```gleam
/// // state_transfer.take(store, state_transfer.Piece(state, 0, bytes), now_s)
/// ```
pub fn take(store: Store, piece: Piece, now_s: Int) -> Verdict {
  case judged(store, piece) {
    Error(refusal) -> Refused(refusal)
    Ok(Nil) -> held_verdict(store, piece, now_s)
  }
}

/// Decides, from the piece and the store's limits alone, whether the piece is
/// worth looking at the disk for.
fn judged(store: Store, piece: Piece) -> Result(Nil, Refusal) {
  let limit = state_store.limits(store).size_limit
  let length = bit_array.byte_size(piece.bytes)
  use state <- result.try(
    state_object.validate(piece.state) |> result.map_error(BadState),
  )
  use <- bool.guard(when: state.size > limit, return: Error(TooLarge(limit)))
  use <- bool.guard(
    when: length < 1 || length > chunk_bytes,
    return: Error(BadPiece("a piece is between 1 and 262144 bytes")),
  )
  use <- bool.guard(
    when: piece.offset < 0 || piece.offset + length > state.size,
    return: Error(BadPiece("the piece lies outside the declared size")),
  )
  Ok(Nil)
}

/// Answers a piece that passed `judged`, from what the store holds.
fn held_verdict(store: Store, piece: Piece, now_s: Int) -> Verdict {
  let state = piece.state

  // A complete state is answered before any half-written file is looked at,
  // because its part is gone and its pieces are not wanted again.
  case state_store.get(store, state.hash) {
    Ok(Some(_whole)) -> Accepted(held: state.size)
    Ok(None) | Error(_) ->
      case state_store.staged_bytes(store, state.hash) {
        Error(reason) -> Failed(reason)
        Ok(held) -> placed(store, piece, held, now_s)
      }
  }
}

/// Places a piece against the bytes held: at the end it is appended, inside them
/// it is a repeat, and beyond them it leaves a gap the sender must close.
///
/// A half-written file that already holds the declared size has nothing left to
/// receive and is finished, whatever the piece says. A crash between the last
/// append and the rename leaves such a file, and so does a failed finish, and no
/// later piece can add to it, so the first piece in range completes it or
/// discards it.
fn placed(store: Store, piece: Piece, held: Int, now_s: Int) -> Verdict {
  let end = piece.offset + bit_array.byte_size(piece.bytes)
  use <- bool.lazy_guard(when: held >= piece.state.size, return: fn() {
    completed(store, piece.state)
  })

  // The offset against the bytes held is the whole decision: only a piece that
  // starts exactly at the end of them adds anything.
  case int.compare(piece.offset, held) {
    order.Eq -> appended(store, piece, now_s)
    order.Gt -> Refused(OutOfOrder(expected: held))
    order.Lt ->
      case end <= held {
        True -> Accepted(held:)
        False -> Refused(OutOfOrder(expected: held))
      }
  }
}

/// Appends a piece that starts where the store stands, and completes the state
/// when it reaches the end.
fn appended(store: Store, piece: Piece, now_s: Int) -> Verdict {
  let state = piece.state

  // A rejection of the append is about room, because the piece's shape was
  // judged before this. The last piece is the one that is compared with the hash.
  case state_store.append_part(store, state, piece.bytes, now_s) {
    Error(state_store.Rejected(reason:)) -> Refused(NoRoom(reason))
    Error(state_store.Faulted(reason:)) -> Failed(reason)
    Ok(held) if held < state.size -> Accepted(held:)
    Ok(_whole) -> completed(store, state)
  }
}

/// Finishes a half-written file that holds every byte of the state.
///
/// A mismatch is refused and stores nothing, as `state_store.finish` leaves it. A
/// fault, such as a bundle that cannot be placed, discards the file as well: it is
/// whole, no piece can add to it, and keeping it would answer every later attempt
/// with a full file that nothing finishes. The sender starts again from nothing.
fn completed(store: Store, state: State) -> Verdict {
  // Each ending leaves no half-written file: a made state renamed it, a mismatch
  // removed it, and a fault is removed here.
  case state_store.finish(store, state) {
    Ok(_made) -> Accepted(held: state.size)
    Error(state_store.Rejected(reason:)) -> Refused(Mismatch(reason))
    Error(state_store.Faulted(reason:)) -> {
      state_store.discard_part(store, state.hash)
      Failed(reason)
    }
  }
}

/// How far a state has got in the store: complete, a prefix, or nothing.
///
/// A state whose record exists but whose bundle no longer matches it is not
/// complete, so the sender sends it again and the receiver replaces it. A store
/// that cannot be read is an `Error`, which the sender must not read as `Absent`.
///
/// ## Examples
///
/// ```gleam
/// // state_transfer.stage(store, hash)
/// ```
pub fn stage(store: Store, hash: String) -> Result(Stage, String) {
  use <- bool.guard(
    when: !state_object.is_hash(hash),
    return: Error("not a state hash"),
  )

  // A whole state is complete whatever else is lying about, and anything less
  // is a prefix of some length or nothing.
  case state_store.get(store, hash) {
    Ok(Some(_whole)) -> Ok(Complete)
    Ok(None) | Error(_) ->
      state_store.staged_bytes(store, hash)
      |> result.map(fn(held) {
        case held {
          0 -> Absent
          _ -> Partial(held:)
        }
      })
  }
}

/// Cuts the piece of a held state that starts at `offset`, with the state's
/// description, so a peer can fetch what this node captured. An offset at or past
/// the end is served from the last byte, which is how a peer whose half-written
/// file already holds every byte is given a piece in range to finish with, and the
/// piece says the offset it starts at.
///
/// ## Examples
///
/// ```gleam
/// // state_transfer.serve(store, hash, 0)
/// ```
pub fn serve(store: Store, hash: String, offset: Int) -> Fetched {
  case state_store.read_piece(store, hash, offset, chunk_bytes) {
    Ok(Some(#(state, at, bytes))) -> Served(Piece(state:, offset: at, bytes:))
    Ok(None) -> NotHeld
    Error(reason) -> FetchFailed(reason)
  }
}

// --- the loops --------------------------------------------------------------------

/// Pushes a state this node holds to a link.
///
/// The bundle is read once, bounded by the store's size limit, and cut into
/// pieces from memory. The link is asked how far the state has got, so a
/// transfer that was interrupted resumes at the receiver's offset and one that
/// finished sends nothing. Any failure of the link ends the call with `Silent`,
/// and calling again is the retry.
///
/// ## Examples
///
/// ```gleam
/// // state_transfer.send(store, state.hash, link)
/// ```
pub fn send(store: Store, hash: String, link: Link) -> Outcome {
  case cut(store, hash) {
    Error(outcome) -> outcome
    Ok(source) -> transfer(fn() { link.stage(hash) }, source, link.piece)
  }
}

/// Reads a held state's bundle and offers it as a source of pieces.
fn cut(store: Store, hash: String) -> Result(Source, Outcome) {
  use held <- result.try(
    state_store.get(store, hash)
    |> result.map_error(Faulted)
    |> result.try(fn(found) {
      option.to_result(found, Faulted("this node does not hold the state"))
    }),
  )
  use bytes <- result.map(
    bootstrap.read_bounded(held.path, state_store.limits(store).size_limit)
    |> result.map_error(Faulted),
  )
  fn(offset) { Ok(slice(held.state, bytes, offset)) }
}

/// The piece of a bundle in memory that starts at `offset`.
fn slice(state: State, bytes: BitArray, offset: Int) -> Piece {
  // A receiver that holds every byte and never finished reports an offset at the
  // end, and an empty piece there would be refused. The last byte's piece is in
  // range, and the receiver finishes on the first piece it is given.
  let offset = int.min(offset, state.size - 1)
  let length = int.min(chunk_bytes, state.size - offset)

  // The bundle read from the store is the recorded size, so a slice inside it
  // always exists. An empty piece, if it ever came, would be refused by the
  // receiver as malformed rather than accepted as progress.
  let cut = case bit_array.slice(bytes, offset, length) {
    Ok(piece) -> piece
    Error(Nil) -> <<>>
  }

  Piece(state:, offset:, bytes: cut)
}

/// Copies a state from one link to another through this node, one piece at a
/// time, holding no more than a piece. This is the orchestrator's part when a
/// child's node and the parent's node are not the same.
///
/// ## Examples
///
/// ```gleam
/// // state_transfer.relay(hash, from: source_link, to: target_link)
/// ```
pub fn relay(hash: String, from from: Link, to to: Link) -> Outcome {
  transfer(fn() { to.stage(hash) }, fetching(hash, from), to.piece)
}

/// A source of pieces fetched from a link. A silence ends the transfer as
/// `Silent`, a node that does not hold the state as a refusal, and a piece for
/// another state or another offset than the one asked for is a fault. The one
/// exception is an offset at or past the end, which the source serves from the
/// last byte: the destination holds every byte and the piece is for it to finish
/// with.
fn fetching(hash: String, from: Link) -> Source {
  fn(offset) {
    case from.fetch(hash, offset) {
      Error(Nil) -> Error(Silent)
      Ok(NotHeld) -> Error(Faulted("the source does not hold the state"))
      Ok(FetchFailed(reason:)) -> Error(Faulted(reason))
      Ok(Served(piece:)) ->
        case
          piece.state.hash == hash
          && { piece.offset == offset || offset >= piece.state.size }
        {
          True -> Ok(piece)
          False -> Error(Faulted("the source served another piece than asked"))
        }
    }
  }
}

/// Fetches a state from a link into this node's store, resuming at the bytes the
/// store already holds. This is the parent's part when it pulls what a child's
/// node captured.
///
/// The store is reached through the node's `Endpoint`, the one that
/// `client/state_service` builds, and never directly. `pull` writes, and a store
/// has one writing process: a pull that held the `Store` itself would be a second
/// writer beside the service the carriers answer through. `send` takes the store
/// because it only reads, from files that are written whole.
///
/// ## Examples
///
/// ```gleam
/// // state_transfer.pull(state_service.endpoint(service), hash, from: link)
/// ```
pub fn pull(local: Endpoint, hash: String, from from: Link) -> Outcome {
  transfer(
    fn() { local.stage(hash) |> result.replace_error(Nil) },
    fetching(hash, from),
    fn(piece) { Ok(local.take(piece)) },
  )
}

/// Puts a bundle this node just made into its own store, through the node's
/// `Endpoint`, in the same pieces a peer's would arrive in.
///
/// A capture leaves a bundle file in a private stage, and the store has one
/// writing process (`client/state_service`) that takes pieces and nothing else.
/// Sending the bundle through the endpoint means the store makes the state the
/// one way it ever does, by comparing the bytes' size and SHA-256 with the
/// description, so a state a capture describes wrongly is refused here and never
/// stored. The bytes are the caller's, already read within the store's limit.
///
/// ## Examples
///
/// ```gleam
/// // state_transfer.deposit(state_service.endpoint(service), state, bytes) == Delivered
/// ```
pub fn deposit(local: Endpoint, state: State, bytes: BitArray) -> Outcome {
  transfer(
    fn() { local.stage(state.hash) |> result.replace_error(Nil) },
    fn(offset) { Ok(slice(state, bytes, offset)) },
    fn(piece) { Ok(local.take(piece)) },
  )
}

/// Drives pieces from a source to a sink until the destination holds the whole
/// state.
///
/// The destination is asked where it stands, and each piece is taken at the
/// offset the destination last reported, which is how a resumed transfer, a
/// repeated piece and a corrected offset are all the same step. The loop is
/// bounded: the pieces the state needs plus `max_resyncs` corrections. A
/// destination that has not moved closer after that is `Stalled`.
fn transfer(
  stage: fn() -> Result(Stage, Nil),
  source: Source,
  sink: Sink,
) -> Outcome {
  case stage() {
    Error(Nil) -> Silent
    Ok(Complete) -> Delivered
    Ok(Absent) -> step(Progress(offset: 0, sent: 0, resyncs: 0), source, sink)
    Ok(Partial(held:)) ->
      step(Progress(offset: held, sent: 0, resyncs: 0), source, sink)
  }
}

/// Sends the piece at the current offset and acts on the verdict.
fn step(progress: Progress, source: Source, sink: Sink) -> Outcome {
  // A source with no piece for the offset ends the transfer with its reason.
  case source(progress.offset) {
    Error(outcome) -> outcome
    Ok(piece) -> {
      let wanted = pieces_of(piece.state.size) + max_resyncs
      use <- bool.guard(when: progress.sent >= wanted, return: Stalled)
      judge(
        sink(piece),
        piece,
        Progress(..progress, sent: progress.sent + 1),
        source,
        sink,
      )
    }
  }
}

/// How many pieces a state of `size` bytes takes.
fn pieces_of(size: Int) -> Int {
  { size + chunk_bytes - 1 } / chunk_bytes
}

/// Acts on one verdict: finish, continue at the offset the receiver reports, or
/// end the transfer.
fn judge(
  answer: Result(Verdict, Nil),
  piece: Piece,
  progress: Progress,
  source: Source,
  sink: Sink,
) -> Outcome {
  case answer {
    Error(Nil) -> Silent
    Ok(Failed(reason:)) -> Faulted(reason)
    Ok(Accepted(held:)) ->
      case held >= piece.state.size {
        True -> Delivered
        False -> step(Progress(..progress, offset: held), source, sink)
      }
    Ok(Refused(OutOfOrder(expected:))) ->
      case progress.resyncs < max_resyncs {
        True ->
          step(
            Progress(
              ..progress,
              offset: expected,
              resyncs: progress.resyncs + 1,
            ),
            source,
            sink,
          )
        False -> Stalled
      }
    Ok(Refused(refusal:)) -> Declined(refusal)
  }
}

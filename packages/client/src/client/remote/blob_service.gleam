//// The executor's keeper of placed blobs (protocol-change/110).
////
//// An orchestrator places a blob for one of its sessions, piece by piece, over
//// the untrusted link. This process owns the directory the pieces land in
//// (`client/remote/blob_store`, which has no lock), judges every piece before
//// the disk is touched, and remembers which bindings have **claimed** which
//// blobs. A claim is what a session's plane needs to be handed a blob, and what
//// the bounds are counted on: a binding may claim at most `binding_blobs` blobs
//// of `binding_bytes` in all, and the bindings of one orchestrator, which the
//// gateway names by its pin, at most `link_blobs` of `link_bytes`. The
//// directory's own cap bounds the disk.
////
//// A binding claims a blob with its first accepted piece, or with a status that
//// finds the blob already held. The claim lasts until the gateway releases the
//// binding, when its session attaches again or its scope closes, and claims are
//// kept in memory only, so a restart forgets them and the orchestrator places
//// again. A blob nobody claims stays on disk until the store's retention ends.
////
//// ## Flow
////
//// `start` → `take` → `stage` → `open` → `release`
////
//// 1. `start` runs the keeper over an open store.
//// 2. `take` judges one piece for a holder, claims the blob, and places the
////    piece against the bytes held; the piece that completes a blob checks it.
//// 3. `stage` answers how far a blob has got, claiming one that is complete.
//// 4. `open` hands a session's plane the path of a blob one of its bindings
////    claimed, hashing it again the first time after a start.
//// 5. `release` forgets a binding's claims.

import broker/internal/call
import client/remote/blob_store.{type Store}
import client/remote/blob_transfer.{
  type Blob, type Piece, type Stage, type Verdict, Accepted, OutOfOrder, Refused,
  Stored,
}
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/set.{type Set}
import weft/actor

/// How long a caller waits for the keeper. Finishing a gigabyte's blob hashes
/// it, which takes seconds, and the keeper serializes its calls.
pub const answer_wait_ms = 120_000

/// The bounds on what bindings and orchestrators may claim.
pub type Bounds {
  Bounds(
    /// The most blobs one binding claims.
    binding_blobs: Int,
    /// The most bytes, by declared size, one binding claims.
    binding_bytes: Int,
    /// The most blobs one orchestrator's bindings claim together.
    link_blobs: Int,
    /// The most bytes one orchestrator's bindings claim together.
    link_bytes: Int,
  )
}

/// Sixteen blobs and two gibibytes a binding, which holds a review job's
/// archives and a proof's module cache; sixty-four blobs and four gibibytes an
/// orchestrator.
pub const default_bounds =
  Bounds(
    binding_blobs: 16,
    binding_bytes: 2_147_483_648,
    link_blobs: 64,
    link_bytes: 4_294_967_296,
  )

/// Who is placing or asking: the orchestrator's pin, the binding it named, and
/// the session the gateway's book holds that binding for.
pub type Holder {
  Holder(pin: BitArray, binding: BitArray, session: String)
}

/// A running keeper.
pub opaque type Service {
  Service(subject: Subject(Message))
}

/// What the keeper receives.
type Message {
  /// One piece from a holder.
  Take(holder: Holder, piece: Piece, reply: Subject(Verdict))

  /// How far a blob has got, for a holder.
  Ask(holder: Holder, digest: String, reply: Subject(Result(Stage, String)))

  /// A plane asks for a blob its session claimed.
  Open(session: String, digest: String, reply: Subject(Result(String, String)))

  /// A binding is gone.
  Release(pin: BitArray, binding: BitArray)
}

/// The keeper's state.
type State {
  State(
    store: Store,
    bounds: Bounds,
    now_s: fn() -> Int,
    /// Each binding's claims, by orchestrator pin and binding.
    claims: Dict(#(BitArray, BitArray), Claim),
    /// The digests hashed again since the keeper started.
    verified: Set(String),
  )
}

/// One binding's claims.
type Claim {
  Claim(
    /// The session the binding was made for.
    session: String,
    /// The claimed blobs and their sizes.
    blobs: Dict(String, Int),
  )
}

/// Starts the keeper over an open store, linked to the caller.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(service) = blob_service.start(store, blob_service.default_bounds, now_s)
/// ```
pub fn start(
  store: Store,
  bounds: Bounds,
  now_s: fn() -> Int,
) -> Result(Service, String) {
  actor.new(State(
    store:,
    bounds:,
    now_s:,
    claims: dict.new(),
    verified: set.new(),
  ))
  |> actor.on_message(handled)
  |> actor.start
  |> result.map(fn(started) { Service(started.data) })
  |> result.replace_error("the blob keeper did not start")
}

/// Takes one piece for a holder. A keeper that does not answer is a `Failed`
/// verdict, which the sender may retry.
///
/// ## Examples
///
/// ```gleam
/// // blob_service.take(service, holder, piece)
/// ```
pub fn take(service: Service, holder: Holder, piece: Piece) -> Verdict {
  call.try_call(service.subject, waiting: answer_wait_ms, sending: Take(
    holder:,
    piece:,
    reply: _,
  ))
  |> result.unwrap(blob_transfer.Failed("the blob keeper did not answer"))
}

/// How far a blob has got, claiming it for the holder when it is complete.
///
/// ## Examples
///
/// ```gleam
/// // blob_service.stage(service, holder, digest) == Ok(blob_transfer.Absent)
/// ```
pub fn stage(
  service: Service,
  holder: Holder,
  digest: String,
) -> Result(Stage, String) {
  call.try_call(service.subject, waiting: answer_wait_ms, sending: Ask(
    holder:,
    digest:,
    reply: _,
  ))
  |> result.replace_error("the blob keeper did not answer")
  |> result.flatten
}

/// The path of a blob a binding of `session` has claimed, for that session's
/// plane to read. The first `open` of a blob since the keeper started hashes it
/// again. The path names a file in a directory every jail masks; the plane
/// copies or extracts it, and checks an archive's contents itself.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(path) = blob_service.open(service, session, digest)
/// ```
pub fn open(
  service: Service,
  session: String,
  digest: String,
) -> Result(String, String) {
  call.try_call(service.subject, waiting: answer_wait_ms, sending: Open(
    session:,
    digest:,
    reply: _,
  ))
  |> result.replace_error("the blob keeper did not answer")
  |> result.flatten
}

/// Forgets a binding's claims.
///
/// ## Examples
///
/// ```gleam
/// // blob_service.release(service, pin, binding)
/// ```
pub fn release(service: Service, pin: BitArray, binding: BitArray) -> Nil {
  process.send(service.subject, Release(pin:, binding:))
}

/// The keeper's handler.
fn handled(state: State, message: Message) -> actor.Next(State, Message) {
  // Each message is one decision against the store and the claims.
  case message {
    Take(holder:, piece:, reply:) -> {
      let #(state, verdict) = taken(state, holder, piece)
      process.send(reply, verdict)
      actor.continue(state)
    }
    Ask(holder:, digest:, reply:) -> {
      let #(state, answer) = staged(state, holder, digest)
      process.send(reply, answer)
      actor.continue(state)
    }
    Open(session:, digest:, reply:) -> {
      let #(state, answer) = opened(state, session, digest)
      process.send(reply, answer)
      actor.continue(state)
    }
    Release(pin:, binding:) ->
      actor.continue(
        State(..state, claims: dict.delete(state.claims, #(pin, binding))),
      )
  }
}

/// Judges a piece, claims its blob for the holder, and places it.
fn taken(state: State, holder: Holder, piece: Piece) -> #(State, Verdict) {
  case judged(state, piece) {
    Error(reason) -> #(state, Refused(reason))
    Ok(blob) ->
      case blob_store.finished(state.store, blob.digest) {
        Ok(size) if size == blob.size -> claimed_whole(state, holder, blob)
        Ok(_other) -> #(
          state,
          Refused("this executor holds the digest with another size"),
        )
        Error(Nil) ->
          case claim(state, holder, blob) {
            Error(reason) -> #(state, Refused(reason))
            Ok(state) -> placed(state, holder, piece)
          }
      }
  }
}

/// Decides, from the piece and the limits alone, whether to look at the disk.
fn judged(state: State, piece: Piece) -> Result(Blob, String) {
  let limit = blob_store.limits(state.store).size_limit
  let length = bit_array.byte_size(piece.bytes)
  use blob <- result.try(blob_transfer.valid(piece.blob))
  use <- bool.lazy_guard(when: blob.size > limit, return: fn() {
    Error("the blob is over the " <> int.to_string(limit) <> " bytes kept here")
  })
  use <- bool.guard(
    when: length < 1 || length > blob_transfer.max_piece_bytes,
    return: Error("a piece is between 1 and 16777216 bytes"),
  )
  use <- bool.guard(
    when: piece.offset < 0 || piece.offset + length > blob.size,
    return: Error("the piece lies outside the declared size"),
  )
  Ok(blob)
}

/// A piece of a blob the store already holds whole: the claim is the whole of
/// the answer.
fn claimed_whole(
  state: State,
  holder: Holder,
  blob: Blob,
) -> #(State, Verdict) {
  case claim(state, holder, blob) {
    Ok(state) -> #(state, Stored)
    Error(reason) -> #(state, Refused(reason))
  }
}

/// Places a piece against the bytes held: at the end it is appended, wholly
/// inside them it is a repeat, and past them, or across their end, it is out of
/// order. A half-written file that already holds every byte, which a crash
/// between the last append and the rename leaves, is finished first.
fn placed(state: State, holder: Holder, piece: Piece) -> #(State, Verdict) {
  let blob = piece.blob
  let end = piece.offset + bit_array.byte_size(piece.bytes)

  // The offset against the bytes held is the whole decision once the store
  // has said how many it holds.
  case blob_store.staged_bytes(state.store, blob.digest) {
    Error(reason) -> #(state, blob_transfer.Failed(reason))
    Ok(held) if held >= blob.size -> completed(state, holder, blob)
    Ok(held) ->
      case int.compare(piece.offset, held) {
        order.Eq -> appended(state, holder, piece)
        order.Gt -> #(state, OutOfOrder(expected: held))
        order.Lt if end <= held -> #(state, Accepted(held:))
        order.Lt -> #(state, OutOfOrder(expected: held))
      }
  }
}

/// Appends a piece that starts where the store stands, and finishes the blob
/// when it reaches the end. A piece that does not fit gives the claim back.
fn appended(state: State, holder: Holder, piece: Piece) -> #(State, Verdict) {
  let blob = piece.blob
  let now = state.now_s()

  // A rejection here is about room, since the piece's shape was judged first.
  case blob_store.append(state.store, blob, piece.bytes, now, kept(state)) {
    Error(blob_store.Rejected(reason:)) -> #(
      unclaim(state, holder, blob.digest),
      Refused(reason),
    )
    Error(blob_store.Faulted(reason:)) -> #(state, blob_transfer.Failed(reason))
    Ok(held) if held < blob.size -> #(state, Accepted(held:))
    Ok(_whole) -> completed(state, holder, blob)
  }
}

/// Finishes a blob whose every byte has arrived. A match is stored and counts
/// as hashed; a mismatch stores nothing and gives the claim back.
fn completed(state: State, holder: Holder, blob: Blob) -> #(State, Verdict) {
  // The store's finish is the check: only matching bytes get a finished name.
  case blob_store.finish(state.store, blob) {
    Ok(Nil) -> #(
      State(..state, verified: set.insert(state.verified, blob.digest)),
      Stored,
    )
    Error(blob_store.Rejected(reason:)) -> #(
      unclaim(state, holder, blob.digest),
      Refused(reason),
    )
    Error(blob_store.Faulted(reason:)) -> {
      blob_store.discard(state.store, blob.digest)
      #(state, blob_transfer.Failed(reason))
    }
  }
}

/// How far a blob has got; a complete one is claimed for the holder.
fn staged(
  state: State,
  holder: Holder,
  digest: String,
) -> #(State, Result(Stage, String)) {
  use <- bool.guard(when: !blob_transfer.is_digest(digest), return: #(
    state,
    Error("not a blob digest"),
  ))

  // A finished blob is complete once it is claimed; anything less is the
  // bytes held, and asking claims nothing.
  case blob_store.finished(state.store, digest) {
    Ok(size) ->
      case claim(state, holder, blob_transfer.Blob(digest:, size:)) {
        Ok(state) -> #(state, Ok(blob_transfer.Complete))
        Error(reason) -> #(state, Error(reason))
      }
    Error(Nil) -> #(
      state,
      blob_store.staged_bytes(state.store, digest)
        |> result.map(fn(held) {
          case held {
            0 -> blob_transfer.Absent
            _ -> blob_transfer.Partial(held:)
          }
        }),
    )
  }
}

/// The path of a blob a binding of `session` claimed, hashed again the first
/// time since the keeper started.
fn opened(
  state: State,
  session: String,
  digest: String,
) -> #(State, Result(String, String)) {
  let claimed =
    dict.values(state.claims)
    |> list.any(fn(claim) {
      claim.session == session && dict.has_key(claim.blobs, digest)
    })
  use <- bool.guard(when: !claimed, return: #(
    state,
    Error("no binding of this session has claimed the blob"),
  ))

  // A blob hashed since the keeper started needs only to be there; any other
  // is hashed again before a plane is handed it.
  let checked = case set.contains(state.verified, digest) {
    True ->
      blob_store.finished(state.store, digest) |> result.replace_error(Nil)
    False -> blob_store.verify(state.store, digest) |> result.replace_error(Nil)
  }

  // A blob that is gone or no longer matches is not handed out.
  case checked {
    Ok(_size) -> #(
      State(..state, verified: set.insert(state.verified, digest)),
      Ok(blob_store.path(state.store, digest)),
    )
    Error(Nil) -> #(
      State(..state, verified: set.delete(state.verified, digest)),
      Error("the executor no longer holds the blob whole"),
    )
  }
}

/// Records that a holder claims a blob, if the claim fits the binding's and the
/// orchestrator's bounds. A blob the binding has claimed already costs nothing.
fn claim(state: State, holder: Holder, blob: Blob) -> Result(State, String) {
  let at = #(holder.pin, holder.binding)
  let own =
    dict.get(state.claims, at)
    |> result.lazy_unwrap(fn() {
      Claim(session: holder.session, blobs: dict.new())
    })
  use <- bool.guard(
    when: dict.has_key(own.blobs, blob.digest),
    return: Ok(state),
  )
  let #(link_blobs, link_bytes) = link_totals(state, holder.pin)
  let bounds = state.bounds
  use <- bool.guard(
    when: dict.size(own.blobs) + 1 > bounds.binding_blobs
      || total(own.blobs) + blob.size > bounds.binding_bytes,
    return: Error("the binding's bound on placed blobs would be passed"),
  )
  use <- bool.guard(
    when: link_blobs + 1 > bounds.link_blobs
      || link_bytes + blob.size > bounds.link_bytes,
    return: Error("the orchestrator's bound on placed blobs would be passed"),
  )
  let own = Claim(..own, blobs: dict.insert(own.blobs, blob.digest, blob.size))
  Ok(State(..state, claims: dict.insert(state.claims, at, own)))
}

/// Gives one blob's claim back.
fn unclaim(state: State, holder: Holder, digest: String) -> State {
  let at = #(holder.pin, holder.binding)

  // A binding that never claimed the blob has nothing to give back.
  case dict.get(state.claims, at) {
    Ok(own) ->
      State(
        ..state,
        claims: dict.insert(
          state.claims,
          at,
          Claim(..own, blobs: dict.delete(own.blobs, digest)),
        ),
      )
    Error(Nil) -> state
  }
}

/// The blobs and bytes an orchestrator's bindings claim together.
fn link_totals(state: State, pin: BitArray) -> #(Int, Int) {
  dict.fold(state.claims, #(0, 0), fn(sums, at, claim) {
    // Another orchestrator's claims are its own business.
    case at.0 == pin {
      True -> #(sums.0 + dict.size(claim.blobs), sums.1 + total(claim.blobs))
      False -> sums
    }
  })
}

/// The bytes of a binding's claims.
fn total(blobs: Dict(String, Int)) -> Int {
  dict.fold(blobs, 0, fn(sum, _digest, size) { sum + size })
}

/// Every digest some binding claims, which a sweep keeps.
fn kept(state: State) -> Set(String) {
  dict.fold(state.claims, set.new(), fn(kept, _at, claim) {
    set.union(kept, set.from_list(dict.keys(claim.blobs)))
  })
}

//// A state crosses between two real stores through a scripted link
//// (protocol-change/107, "Send"). Both ends are `client/state_store` over real
//// directories, and the link calls the receiver's own `take`, `stage` and `serve`,
//// so what the tests check is what a peer would see. The faults are in the link:
//// it goes silent after a given number of bytes are held, or applies a piece and
//// loses the verdict, and the tests then send again, reopen either store, and
//// look at what the receiver holds.

import client/internal/ffi_os
import client/state_object.{type State, Clean, State}
import client/state_store.{type Store, Limits}
import client/state_transfer.{
  type Link, type Piece, Absent, Accepted, Complete, Declined, Delivered,
  Faulted, Link, Partial, Piece, Refused, Silent, Stalled,
}
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import support/state_rig

// A bundle of two and a half pieces, so a transfer has a first piece, a middle
// one and a short last one.
const size = 655_360

const chunk = 262_144

fn limits() -> state_store.Limits {
  Limits(size_limit: 1_000_000, total_cap: 3_000_000, retain_s: 3600)
}

fn now() -> Int {
  bootstrap.system_time_ms() / 1000
}

fn scratch(name: String) -> String {
  let directory =
    "build/state-transfer-"
    <> name
    <> "-"
    <> int_text(ffi_os.unique_positive_integer())

  // The integer is unique within one run, so an earlier run's directory of the
  // same name is removed before this one uses it.
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let assert Ok(canonical) = bootstrap.canonical_directory(directory)
  canonical
}

fn int_text(number: Int) -> String {
  string.inspect(number)
}

fn open(root: String, limits: state_store.Limits) -> Store {
  let assert Ok(store) = state_store.open(state_store.directory(root), limits)
  store
}

// Deterministic bytes that differ from one piece to the next.
fn payload(length: Int) -> BitArray {
  let text = string.repeat("0123456789abcdef-", length / 16 + 1)
  let assert Ok(bytes) = bit_array.slice(bit_array.from_string(text), 0, length)
  bytes
}

// Puts bytes in a store as a state, the way a capture's bundle is admitted.
fn held(store: Store, root: String, bytes: BitArray) -> State {
  let path = root <> "/bundle-" <> int_text(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.write_bits(path, bytes)
  let assert Ok(state) =
    state_store.put(
      store,
      path,
      tip: "0123456789abcdef0123456789abcdef01234567",
      base: None,
      dirty: Clean,
      now_s: now(),
    )
  state
}

// The link to a node whose store is `store`: every question reaches the real
// receiver and every answer is the receiver's.
fn local(store: Store) -> Link {
  Link(
    stage: fn(hash) {
      state_transfer.stage(store, hash) |> result.replace_error(Nil)
    },
    piece: fn(piece) { Ok(state_transfer.take(store, piece, now())) },
    fetch: fn(hash, offset) { Ok(state_transfer.serve(store, hash, offset)) },
  )
}

// A link that stops answering pieces once the receiver holds `bytes` of the
// state. A drop is as good as a lost connection: the piece never arrives.
fn cut_after(store: Store, hash: String, bytes: Int) -> Link {
  Link(..local(store), piece: fn(piece) {
    let assert Ok(have) = state_store.staged_bytes(store, hash)
    case have >= bytes {
      True -> Error(Nil)
      False -> Ok(state_transfer.take(store, piece, now()))
    }
  })
}

// A link that applies the piece that carries the receiver past `bytes` and loses
// its verdict, which is the drop that leaves the sender not knowing.
fn lose_verdict_past(store: Store, hash: String, bytes: Int) -> Link {
  Link(..local(store), piece: fn(piece) {
    let assert Ok(before) = state_store.staged_bytes(store, hash)
    let verdict = state_transfer.take(store, piece, now())
    case before < bytes, verdict {
      True, Accepted(held:) if held >= bytes -> Error(Nil)
      _, _ -> Ok(verdict)
    }
  })
}

// A link that is given no piece before `offset`, and otherwise behaves as the
// receiver does.
fn resuming_at(store: Store, offset: Int) -> Link {
  Link(..local(store), piece: fn(piece: Piece) {
    assert piece.offset >= offset
    Ok(state_transfer.take(store, piece, now()))
  })
}

fn contents(store: Store, hash: String) -> BitArray {
  let assert Ok(Some(found)) = state_store.get(store, hash)
  let assert Ok(bytes) = simplifile.read_bits(found.path)
  bytes
}

fn piece_of(state: State, bytes: BitArray, offset: Int, length: Int) -> Piece {
  let assert Ok(cut) = bit_array.slice(bytes, offset, length)
  Piece(state:, offset:, bytes: cut)
}

// A state record for bytes that are not in any store.
fn described(bytes: BitArray) -> State {
  State(
    hash: state_object.hash_of(bytes),
    size: bit_array.byte_size(bytes),
    tip: "0123456789abcdef0123456789abcdef01234567",
    base: None,
    dirty: Clean,
  )
}

pub fn a_state_crosses_in_pieces_and_is_held_whole_test() {
  let sender_root = scratch("full-from")
  let receiver_root = scratch("full-to")
  let sender = open(sender_root, limits())
  let receiver = open(receiver_root, limits())
  let bytes = payload(size)
  let state = held(sender, sender_root, bytes)

  assert state_transfer.send(sender, state.hash, local(receiver)) == Delivered
  assert contents(receiver, state.hash) == bytes
  assert state_transfer.stage(receiver, state.hash) == Ok(Complete)
  assert state_store.staged_bytes(receiver, state.hash) == Ok(0)
}

pub fn a_finished_state_is_not_sent_twice_test() {
  let sender_root = scratch("twice-from")
  let receiver_root = scratch("twice-to")
  let sender = open(sender_root, limits())
  let receiver = open(receiver_root, limits())
  let state = held(sender, sender_root, payload(size))
  assert state_transfer.send(sender, state.hash, local(receiver)) == Delivered

  // A link that answers no piece would turn any piece sent into `Silent`.
  let mute = Link(..local(receiver), piece: fn(_piece) { Error(Nil) })
  assert state_transfer.send(sender, state.hash, mute) == Delivered
}

pub fn a_drop_mid_transfer_resumes_at_the_receivers_offset_test() {
  let sender_root = scratch("drop-from")
  let receiver_root = scratch("drop-to")
  let sender = open(sender_root, limits())
  let receiver = open(receiver_root, limits())
  let bytes = payload(size)
  let state = held(sender, sender_root, bytes)

  // The link dies once the receiver holds the first piece.
  let dropped = cut_after(receiver, state.hash, chunk)
  assert state_transfer.send(sender, state.hash, dropped) == Silent
  assert state_transfer.stage(receiver, state.hash) == Ok(Partial(chunk))
  assert state_store.get(receiver, state.hash) == Ok(None)

  // The healed link is given nothing before the offset the receiver holds.
  let healed = resuming_at(receiver, chunk)
  assert state_transfer.send(sender, state.hash, healed) == Delivered
  assert contents(receiver, state.hash) == bytes
}

pub fn a_lost_verdict_is_resolved_by_asking_for_the_status_test() {
  let sender_root = scratch("lost-from")
  let receiver_root = scratch("lost-to")
  let sender = open(sender_root, limits())
  let receiver = open(receiver_root, limits())
  let bytes = payload(size)
  let state = held(sender, sender_root, bytes)

  // The second piece is applied and its answer is lost, so the sender cannot
  // know the receiver holds two pieces.
  let lossy = lose_verdict_past(receiver, state.hash, chunk + 1)
  assert state_transfer.send(sender, state.hash, lossy) == Silent
  assert state_transfer.stage(receiver, state.hash) == Ok(Partial(2 * chunk))

  // The next attempt asks, and goes on after the second piece, not after the
  // first.
  let healed = resuming_at(receiver, 2 * chunk)
  assert state_transfer.send(sender, state.hash, healed) == Delivered
  assert contents(receiver, state.hash) == bytes
}

pub fn a_restart_of_the_receiver_keeps_what_it_held_test() {
  let sender_root = scratch("rr-from")
  let receiver_root = scratch("rr-to")
  let sender = open(sender_root, limits())
  let receiver = open(receiver_root, limits())
  let bytes = payload(size)
  let state = held(sender, sender_root, bytes)
  let dropped = cut_after(receiver, state.hash, 2 * chunk)
  assert state_transfer.send(sender, state.hash, dropped) == Silent

  // The receiver's store is opened again from its directory, as a restarted
  // daemon opens it.
  let restarted = open(receiver_root, limits())
  assert state_transfer.stage(restarted, state.hash) == Ok(Partial(2 * chunk))
  let resumed = resuming_at(restarted, 2 * chunk)
  assert state_transfer.send(sender, state.hash, resumed) == Delivered
  assert contents(restarted, state.hash) == bytes
}

pub fn a_restart_of_the_sender_resumes_from_the_receiver_test() {
  let sender_root = scratch("sr-from")
  let receiver_root = scratch("sr-to")
  let sender = open(sender_root, limits())
  let receiver = open(receiver_root, limits())
  let bytes = payload(size)
  let state = held(sender, sender_root, bytes)
  let dropped = cut_after(receiver, state.hash, chunk)
  assert state_transfer.send(sender, state.hash, dropped) == Silent

  // The sender keeps nothing in memory between attempts: a store opened afresh
  // over its directory sends the rest.
  let restarted = open(sender_root, limits())
  let resumed = resuming_at(receiver, chunk)
  assert state_transfer.send(restarted, state.hash, resumed) == Delivered
  assert contents(receiver, state.hash) == bytes
}

pub fn a_hash_mismatch_is_refused_and_nothing_is_stored_test() {
  let root = scratch("mismatch")
  let receiver = open(root, limits())
  let honest = payload(size)

  // The description names the honest bytes, and the pieces are of other bytes of
  // the same size.
  let state = described(honest)
  let assert Ok(prefix) = bit_array.slice(honest, 0, size - 1)
  let altered = bit_array.append(prefix, <<"!":utf8>>)
  let first = piece_of(state, altered, 0, chunk)
  let second = piece_of(state, altered, chunk, chunk)
  let last = piece_of(state, altered, 2 * chunk, size - 2 * chunk)
  assert state_transfer.take(receiver, first, now()) == Accepted(chunk)
  assert state_transfer.take(receiver, second, now()) == Accepted(2 * chunk)
  let verdict = state_transfer.take(receiver, last, now())
  let assert Refused(state_transfer.Mismatch(_)) = verdict

  // Nothing names the state, and no half of it is left to resume from.
  assert state_store.get(receiver, state.hash) == Ok(None)
  assert state_transfer.stage(receiver, state.hash) == Ok(Absent)
  assert state_store.usage(receiver) == Ok(0)
}

pub fn an_oversize_announce_is_refused_before_any_bytes_test() {
  let root = scratch("oversize")
  let receiver = open(root, limits())
  let state =
    State(
      hash: state_object.hash_of(<<"x">>),
      size: 1_000_001,
      tip: "0123456789abcdef0123456789abcdef01234567",
      base: None,
      dirty: Clean,
    )

  assert state_transfer.take(
      receiver,
      Piece(state:, offset: 0, bytes: <<1>>),
      now(),
    )
    == Refused(state_transfer.TooLarge(limit: 1_000_000))
  assert state_store.usage(receiver) == Ok(0)
}

pub fn a_piece_at_an_offset_gap_is_refused_with_the_offset_expected_test() {
  let root = scratch("gap")
  let receiver = open(root, limits())
  let bytes = payload(size)
  let state = described(bytes)

  // Nothing is held, so the second piece cannot be placed.
  let second = piece_of(state, bytes, chunk, chunk)
  assert state_transfer.take(receiver, second, now())
    == Refused(state_transfer.OutOfOrder(expected: 0))
  assert state_store.usage(receiver) == Ok(0)
}

pub fn a_duplicate_piece_is_accepted_and_written_once_test() {
  let root = scratch("duplicate")
  let receiver = open(root, limits())
  let bytes = payload(size)
  let state = described(bytes)
  let first = piece_of(state, bytes, 0, chunk)
  let second = piece_of(state, bytes, chunk, chunk)
  assert state_transfer.take(receiver, first, now()) == Accepted(chunk)
  assert state_transfer.take(receiver, second, now()) == Accepted(2 * chunk)

  // The first piece arrives again, as a resend after a lost verdict would. The
  // answer says where the receiver stands, and the file does not grow.
  assert state_transfer.take(receiver, first, now()) == Accepted(2 * chunk)
  assert state_store.staged_bytes(receiver, state.hash) == Ok(2 * chunk)
}

pub fn a_piece_that_straddles_what_is_held_is_corrected_test() {
  let root = scratch("straddle")
  let receiver = open(root, limits())
  let bytes = payload(size)
  let state = described(bytes)
  assert state_transfer.take(receiver, piece_of(state, bytes, 0, chunk), now())
    == Accepted(chunk)

  // Half of this piece is held already. It is not appended and not trusted.
  let straddling = piece_of(state, bytes, chunk / 2, chunk)
  assert state_transfer.take(receiver, straddling, now())
    == Refused(state_transfer.OutOfOrder(expected: chunk))
}

pub fn malformed_pieces_are_refused_without_a_write_test() {
  let root = scratch("malformed")
  let receiver = open(root, limits())
  let bytes = payload(size)
  let state = described(bytes)
  let empty = Piece(state:, offset: 0, bytes: <<>>)
  let long = Piece(state:, offset: 0, bytes: payload(chunk + 1))
  let past = Piece(state:, offset: size, bytes: <<1>>)
  let negative = Piece(state:, offset: -1, bytes: <<1>>)
  let unnamed = Piece(State(..state, hash: "nope"), offset: 0, bytes: <<1>>)
  let weightless = Piece(State(..state, size: 0), offset: 0, bytes: <<1>>)

  list.each([empty, long, past, negative], fn(piece) {
    let assert Refused(state_transfer.BadPiece(_)) =
      state_transfer.take(receiver, piece, now())
  })
  list.each([unnamed, weightless], fn(piece) {
    let assert Refused(state_transfer.BadState(_)) =
      state_transfer.take(receiver, piece, now())
  })
  assert state_store.usage(receiver) == Ok(0)
}

pub fn a_piece_that_does_not_fit_the_cap_frees_its_room_test() {
  let root = scratch("cap")
  let receiver =
    open(root, Limits(size_limit: 600_000, total_cap: 600_000, retain_s: 3600))

  // Another state already takes 100 000 bytes of the 600 000 the directory may
  // hold, so two pieces of this one cannot both fit.
  let _other = held(receiver, root, payload(100_000))
  let assert Ok(before) = state_store.usage(receiver)
  let bytes = payload(2 * chunk)
  let state = described(bytes)
  assert state_transfer.take(receiver, piece_of(state, bytes, 0, chunk), now())
    == Accepted(chunk)

  // The second piece would take the directory past its cap. The refusal removes
  // the half-written file, so the room it was holding is free again.
  let verdict =
    state_transfer.take(receiver, piece_of(state, bytes, chunk, chunk), now())
  let assert Refused(state_transfer.NoRoom(_)) = verdict
  assert state_store.usage(receiver) == Ok(before)
}

pub fn a_node_serves_the_piece_it_holds_at_an_offset_test() {
  let root = scratch("serve")
  let store = open(root, limits())
  let bytes = payload(size)
  let state = held(store, root, bytes)

  let assert state_transfer.Served(last) =
    state_transfer.serve(store, state.hash, 2 * chunk)
  assert last.state == state
  assert last.offset == 2 * chunk
  assert bit_array.byte_size(last.bytes) == size - 2 * chunk
  assert state_transfer.serve(store, state_object.hash_of(<<"none">>), 0)
    == state_transfer.NotHeld

  // An offset at the end is served from the last byte, with the offset it starts
  // at, so a peer whose half-written file holds every byte has a piece to finish
  // with. A negative offset is a fault.
  let assert state_transfer.Served(end) =
    state_transfer.serve(store, state.hash, size)
  assert end.offset == size - 1
  assert bit_array.byte_size(end.bytes) == 1
  let assert state_transfer.FetchFailed(_) =
    state_transfer.serve(store, state.hash, -1)
}

pub fn a_state_is_relayed_between_two_stores_without_being_held_test() {
  let from_root = scratch("relay-from")
  let to_root = scratch("relay-to")
  let source = open(from_root, limits())
  let target = open(to_root, limits())
  let bytes = payload(size)
  let state = held(source, from_root, bytes)

  let outcome =
    state_transfer.relay(state.hash, from: local(source), to: local(target))
  assert outcome == Delivered
  assert contents(target, state.hash) == bytes
}

pub fn a_state_is_pulled_and_a_pull_resumes_test() {
  let from_root = scratch("pull-from")
  let to_root = scratch("pull-to")
  let source = open(from_root, limits())
  let target = open(to_root, limits())
  let bytes = payload(size)
  let state = held(source, from_root, bytes)

  // The first pull is cut after one piece, the second continues from it.
  let cut =
    Link(..local(source), fetch: fn(hash, offset) {
      case offset >= chunk {
        True -> Error(Nil)
        False -> Ok(state_transfer.serve(source, hash, offset))
      }
    })
  let endpoint = state_transfer.endpoint(target, now)
  assert state_transfer.pull(endpoint, state.hash, from: cut) == Silent
  assert state_transfer.stage(target, state.hash) == Ok(Partial(chunk))
  assert state_transfer.pull(endpoint, state.hash, from: local(source))
    == Delivered
  assert contents(target, state.hash) == bytes
}

pub fn a_source_that_does_not_hold_the_state_is_a_fault_test() {
  let from_root = scratch("absent-from")
  let to_root = scratch("absent-to")
  let source = open(from_root, limits())
  let target = open(to_root, limits())
  let hash = state_object.hash_of(<<"never captured">>)

  let endpoint = state_transfer.endpoint(target, now)
  let outcome = state_transfer.pull(endpoint, hash, from: local(source))
  assert outcome == Faulted("the source does not hold the state")
}

pub fn a_receiver_that_never_catches_up_stalls_the_transfer_test() {
  let sender_root = scratch("stall-from")
  let sender = open(sender_root, limits())
  let state = held(sender, sender_root, payload(size))

  // A receiver that accepts every piece and still says it holds nothing is not
  // converging, and the loop ends instead of sending forever.
  let stuck =
    Link(
      stage: fn(_hash) { Ok(Absent) },
      piece: fn(_piece) { Ok(Accepted(held: 0)) },
      fetch: fn(_hash, _offset) { Ok(state_transfer.NotHeld) },
    )
  assert state_transfer.send(sender, state.hash, stuck) == Stalled
}

pub fn a_refusal_ends_the_transfer_and_names_the_reason_test() {
  let sender_root = scratch("declined-from")
  let sender = open(sender_root, limits())
  let state = held(sender, sender_root, payload(size))
  let refusing =
    Link(
      stage: fn(_hash) { Ok(Absent) },
      piece: fn(_piece) { Ok(Refused(state_transfer.NotServing)) },
      fetch: fn(_hash, _offset) { Ok(state_transfer.NotHeld) },
    )
  assert state_transfer.send(sender, state.hash, refusing)
    == Declined(state_transfer.NotServing)
}

pub fn sending_a_state_the_sender_does_not_hold_is_a_fault_test() {
  let root = scratch("unheld")
  let sender = open(root, limits())
  let receiver = open(scratch("unheld-to"), limits())
  let hash = state_object.hash_of(<<"nowhere">>)
  assert state_transfer.send(sender, hash, local(receiver))
    == Faulted("this node does not hold the state")
}

pub fn a_captured_bundle_crosses_and_still_verifies_test() {
  let rig = state_rig.rig("transfer")
  let snapshot = state_rig.capture(rig, "full", state_object.Full)
  let sender_root = scratch("real-from")
  let receiver_root = scratch("real-to")
  let sender = open(sender_root, state_store.default_limits)
  let receiver = open(receiver_root, state_store.default_limits)
  let assert Ok(state) =
    state_store.put(
      sender,
      snapshot.bundle,
      tip: snapshot.commit,
      base: snapshot.base,
      dirty: snapshot.dirty,
      now_s: now(),
    )

  assert state_transfer.send(sender, state.hash, local(receiver)) == Delivered

  // The bundle that arrived is the one a receiver's apply will accept: its
  // header names the state's tip and its bytes are the state's.
  assert state_object.verify_bundle(state, contents(receiver, state.hash))
    == Ok(Nil)
  state_rig.stop(rig)
}

// --- a half-written file that holds every byte -------------------------------------

// A receiver whose half-written file holds every byte of the state and was never
// finished, which is what a crash between the last append and the rename leaves.
// It is written through the store, as a receiver's own last append would be.
fn crashed_before_finishing(receiver: Store, state: State, bytes: BitArray) {
  let assert Ok(held) = state_store.append_part(receiver, state, bytes, now())
  assert held == size
}

pub fn a_full_part_left_by_a_crash_is_finished_by_the_next_send_test() {
  let sender_root = scratch("full-part-from")
  let receiver_root = scratch("full-part-to")
  let sender = open(sender_root, limits())
  let receiver = open(receiver_root, limits())
  let bytes = payload(size)
  let state = held(sender, sender_root, bytes)
  crashed_before_finishing(receiver, state, bytes)

  // The status says the receiver holds every byte and has no state, which is where
  // a sender used to be stuck: it had no piece to send and the receiver no way to
  // finish.
  assert state_transfer.stage(receiver, state.hash) == Ok(Partial(size))
  assert state_transfer.send(sender, state.hash, local(receiver)) == Delivered
  assert contents(receiver, state.hash) == bytes
  assert state_store.staged_bytes(receiver, state.hash) == Ok(0)
}

pub fn a_full_part_of_other_bytes_is_refused_once_and_the_next_send_delivers_test() {
  let sender_root = scratch("full-wrong-from")
  let receiver_root = scratch("full-wrong-to")
  let sender = open(sender_root, limits())
  let receiver = open(receiver_root, limits())
  let bytes = payload(size)
  let state = held(sender, sender_root, bytes)
  crashed_before_finishing(
    receiver,
    state,
    bit_array.from_string(string.repeat("z", size)),
  )

  // The bytes held are the right length and are not the state's. The first piece
  // in range finishes them, the comparison refuses, and the file is discarded.
  let assert Declined(state_transfer.Mismatch(_)) =
    state_transfer.send(sender, state.hash, local(receiver))
  assert state_store.staged_bytes(receiver, state.hash) == Ok(0)
  assert state_store.get(receiver, state.hash) == Ok(None)

  // Nothing is left to be stuck on, so the next send starts at zero and delivers.
  assert state_transfer.send(sender, state.hash, local(receiver)) == Delivered
  assert contents(receiver, state.hash) == bytes
}

// A bundle that cannot be placed: a directory with something in it is where the
// bundle's name should go, so the rename in `finish` fails after the bytes were
// compared and found right.
fn blocked_bundle(root: String, state: State) -> Nil {
  let blocker = state_store.directory(root) <> "/" <> state.hash <> ".bundle"
  let assert Ok(Nil) = simplifile.create_directory_all(blocker)
  let assert Ok(Nil) = simplifile.write(blocker <> "/occupied", "x")
  Nil
}

pub fn a_finish_that_faults_leaves_no_half_written_file_test() {
  let root = scratch("fault-finish")
  let receiver = open(root, limits())
  let bytes = payload(size)
  let state = described(bytes)
  blocked_bundle(root, state)

  // The last piece reaches the size, the bytes are right, and the bundle cannot be
  // placed. The answer is a failure the sender may retry, and no file is left that
  // would answer every retry with a full part nothing finishes.
  assert state_transfer.take(receiver, piece_of(state, bytes, 0, chunk), now())
    == Accepted(chunk)
  assert state_transfer.take(
      receiver,
      piece_of(state, bytes, chunk, chunk),
      now(),
    )
    == Accepted(2 * chunk)
  let verdict =
    state_transfer.take(
      receiver,
      piece_of(state, bytes, 2 * chunk, size - 2 * chunk),
      now(),
    )
  let assert state_transfer.Failed(_) = verdict
  assert state_store.staged_bytes(receiver, state.hash) == Ok(0)
  assert state_transfer.stage(receiver, state.hash) == Ok(Absent)
}

pub fn a_full_part_that_cannot_be_finished_is_discarded_by_the_next_piece_test() {
  let root = scratch("fault-full")
  let receiver = open(root, limits())
  let bytes = payload(size)
  let state = described(bytes)
  blocked_bundle(root, state)
  crashed_before_finishing(receiver, state, bytes)

  // Any piece in range for the state is enough to try, and a fault discards.
  let verdict =
    state_transfer.take(receiver, piece_of(state, bytes, 0, chunk), now())
  let assert state_transfer.Failed(_) = verdict
  assert state_store.staged_bytes(receiver, state.hash) == Ok(0)
}

pub fn a_full_part_is_finished_by_a_pull_through_the_endpoint_test() {
  let from_root = scratch("pull-full-from")
  let to_root = scratch("pull-full-to")
  let source = open(from_root, limits())
  let target = open(to_root, limits())
  let bytes = payload(size)
  let state = held(source, from_root, bytes)
  crashed_before_finishing(target, state, bytes)

  // The destination reports every byte held. The source serves the last byte's
  // piece for the offset at the end, and the destination finishes on it.
  let endpoint = state_transfer.endpoint(target, now)
  assert state_transfer.pull(endpoint, state.hash, from: local(source))
    == Delivered
  assert contents(target, state.hash) == bytes
  assert state_store.staged_bytes(target, state.hash) == Ok(0)
}

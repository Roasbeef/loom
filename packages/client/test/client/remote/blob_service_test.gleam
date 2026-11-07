//// The executor's keeper of placed blobs over a real directory
//// (protocol-change/110). Each test plays the gateway, naming a holder for
//// each piece as the book would, and checks what the disk holds afterwards:
//// a blob exists only once its bytes matched, every bound refuses before a
//// byte is written, and a plane is handed only a blob its session claimed.

import client/remote/blob_service.{type Holder, Holder}
import client/remote/blob_store
import client/remote/blob_transfer.{
  Absent, Accepted, Blob, Complete, OutOfOrder, Partial, Piece, Refused, Stored,
}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/set
import simplifile
import support/remote_fixtures as fixtures

const pin = <<1:size(256)>>

const other_pin = <<2:size(256)>>

/// A keeper over a fresh directory with small limits, so each bound is
/// reached in a few bytes.
fn keeper(
  label: String,
  bounds: blob_service.Bounds,
) -> #(blob_service.Service, blob_store.Store) {
  let assert Ok(store) =
    blob_store.open(
      fixtures.scratch("blobs-" <> label) <> "/placed-blobs",
      blob_store.Limits(size_limit: 1024, total_cap: 4096, retain_s: 3600),
    )
    as "the store opens"
  let assert Ok(service) = blob_service.start(store, bounds, fn() { 1_000_000 })
    as "the keeper starts"
  #(service, store)
}

/// Bounds no test reaches unless it means to.
fn roomy() -> blob_service.Bounds {
  blob_service.Bounds(
    binding_blobs: 16,
    binding_bytes: 1_000_000,
    link_blobs: 64,
    link_bytes: 1_000_000,
  )
}

fn holder(binding: Int, session: String) -> Holder {
  Holder(pin:, binding: <<binding:size(128)>>, session:)
}

/// Bytes the test can tell apart, of `size`.
fn bytes(size: Int, seed: Int) -> BitArray {
  list.repeat(seed % 256, size)
  |> list.fold(<<>>, fn(acc, byte) { <<acc:bits, byte:size(8)>> })
}

fn blob_of(content: BitArray) -> blob_transfer.Blob {
  Blob(
    digest: blob_transfer.digest_of(content),
    size: bit_array.byte_size(content),
  )
}

/// The piece of `content` at `offset`, `length` long.
fn piece(content: BitArray, offset: Int, length: Int) -> blob_transfer.Piece {
  let assert Ok(cut) = bit_array.slice(content, offset, length)
    as "the test's piece is inside the blob"
  Piece(blob: blob_of(content), offset:, bytes: cut)
}

/// Places a whole blob in pieces of `length` and answers the last verdict.
fn placed(
  service: blob_service.Service,
  holder: Holder,
  content: BitArray,
  length: Int,
) -> blob_transfer.Verdict {
  let size = bit_array.byte_size(content)
  placing(service, holder, content, length, 0, size)
}

fn placing(
  service: blob_service.Service,
  holder: Holder,
  content: BitArray,
  length: Int,
  offset: Int,
  size: Int,
) -> blob_transfer.Verdict {
  let cut = int.min(length, size - offset)
  case blob_service.take(service, holder, piece(content, offset, cut)) {
    Accepted(held:) if held < size ->
      placing(service, holder, content, length, held, size)
    verdict -> verdict
  }
}

pub fn a_blob_placed_in_pieces_is_stored_and_opened_by_its_session_test() {
  let #(service, _store) = keeper("whole", roomy())
  let content = bytes(100, 7)
  let blob = blob_of(content)
  let one = holder(1, "s1")

  assert blob_service.stage(service, one, blob.digest) == Ok(Absent)
  assert blob_service.take(service, one, piece(content, 0, 40))
    == Accepted(held: 40)
  assert blob_service.stage(service, one, blob.digest) == Ok(Partial(held: 40))
  assert blob_service.take(service, one, piece(content, 40, 60)) == Stored
  assert blob_service.stage(service, one, blob.digest) == Ok(Complete)

  let assert Ok(path) = blob_service.open(service, "s1", blob.digest)
    as "the session that placed the blob opens it"
  assert simplifile.read_bits(path) == Ok(content)
}

pub fn bytes_that_do_not_match_the_digest_store_nothing_test() {
  let #(service, store) = keeper("wrong-digest", roomy())
  let content = bytes(64, 3)
  let lie = Blob(..blob_of(content), digest: blob_transfer.digest_of(<<"no">>))
  let one = holder(1, "s1")

  assert blob_service.take(
      service,
      one,
      Piece(blob: lie, offset: 0, bytes: content),
    )
    |> refused
  assert blob_service.stage(service, one, lie.digest) == Ok(Absent)
  assert blob_store.finished(store, lie.digest) == Error(Nil)
  let assert Error(_unclaimed) = blob_service.open(service, "s1", lie.digest)
  Nil
}

pub fn a_malformed_or_oversized_piece_is_refused_before_the_disk_test() {
  let #(service, store) = keeper("malformed", roomy())
  let content = bytes(64, 5)
  let blob = blob_of(content)
  let one = holder(1, "s1")

  let checks = [
    Piece(blob: Blob(..blob, digest: "../../etc"), offset: 0, bytes: content),
    Piece(blob: Blob(..blob, size: 0), offset: 0, bytes: <<>>),
    Piece(blob:, offset: 0, bytes: <<>>),
    Piece(blob:, offset: -1, bytes: <<1>>),
    Piece(blob:, offset: 60, bytes: bytes(10, 1)),
    Piece(blob: Blob(..blob, size: 2048), offset: 0, bytes: content),
    Piece(
      blob: Blob(..blob, size: blob_transfer.max_piece_bytes + 1),
      offset: 0,
      bytes: bytes(blob_transfer.max_piece_bytes + 1, 1),
    ),
  ]
  list.each(checks, fn(bad) {
    assert blob_service.take(service, one, bad) |> refused
  })
  assert blob_store.usage(store) == Ok(0)
}

pub fn a_gap_a_repeat_and_an_overlap_are_answered_with_the_bytes_held_test() {
  let #(service, _store) = keeper("order", roomy())
  let content = bytes(100, 9)
  let one = holder(1, "s1")

  assert blob_service.take(service, one, piece(content, 0, 30))
    == Accepted(held: 30)
  assert blob_service.take(service, one, piece(content, 50, 10))
    == OutOfOrder(expected: 30)
  assert blob_service.take(service, one, piece(content, 10, 10))
    == Accepted(held: 30)
  assert blob_service.take(service, one, piece(content, 20, 20))
    == OutOfOrder(expected: 30)
  assert blob_service.take(service, one, piece(content, 30, 70)) == Stored

  // A piece of a blob that is already whole is the claim and nothing else.
  assert blob_service.take(service, one, piece(content, 0, 10)) == Stored
}

pub fn a_bindings_bounds_refuse_its_next_claim_test() {
  let bounds =
    blob_service.Bounds(..roomy(), binding_blobs: 2, binding_bytes: 150)
  let #(service, _store) = keeper("binding-bounds", bounds)
  let one = holder(1, "s1")

  assert placed(service, one, bytes(100, 1), 64) == Stored

  // A second blob would pass the binding's bytes.
  assert placed(service, one, bytes(60, 2), 64) |> refused

  // One that fits the bytes is fine, and then the count is spent.
  assert placed(service, one, bytes(40, 3), 64) == Stored
  assert placed(service, one, bytes(5, 4), 64) |> refused

  // Another binding of the same orchestrator has bounds of its own.
  assert placed(service, holder(2, "s2"), bytes(60, 2), 64) == Stored
}

pub fn an_orchestrators_bounds_span_its_bindings_test() {
  let bounds = blob_service.Bounds(..roomy(), link_blobs: 2, link_bytes: 1000)
  let #(service, _store) = keeper("link-bounds", bounds)

  assert placed(service, holder(1, "s1"), bytes(10, 1), 64) == Stored
  assert placed(service, holder(2, "s2"), bytes(10, 2), 64) == Stored
  assert placed(service, holder(3, "s3"), bytes(10, 3), 64) |> refused

  // Another orchestrator is not charged for the first one's claims.
  let stranger = Holder(pin: other_pin, binding: <<1:size(128)>>, session: "t")
  assert placed(service, stranger, bytes(10, 3), 64) == Stored
}

pub fn the_directorys_cap_refuses_and_leaves_no_half_written_file_test() {
  let #(service, store) = keeper("cap", roomy())
  let one = holder(1, "s1")

  // Four blobs of a kibibyte fill the 4096-byte cap exactly.
  list.each([1, 2, 3, 4], fn(seed) {
    assert placed(service, one, bytes(1024, seed), 1024) == Stored
  })
  assert placed(service, holder(2, "s2"), bytes(10, 9), 64) |> refused
  assert blob_store.usage(store) == Ok(4096)
}

pub fn a_held_blob_is_claimed_by_a_status_with_no_bytes_test() {
  let #(service, _store) = keeper("claim", roomy())
  let content = bytes(80, 4)
  let blob = blob_of(content)
  assert placed(service, holder(1, "s1"), content, 64) == Stored

  // Another session has not claimed it, so its plane is not handed it.
  let assert Error(_unclaimed) = blob_service.open(service, "s2", blob.digest)

  // Its status finds the blob whole and claims it; now it opens.
  assert blob_service.stage(service, holder(2, "s2"), blob.digest)
    == Ok(Complete)
  let assert Ok(_path) = blob_service.open(service, "s2", blob.digest)
    as "a claim by status opens"
  Nil
}

pub fn a_released_binding_gives_its_claims_back_test() {
  let bounds = blob_service.Bounds(..roomy(), binding_blobs: 1)
  let #(service, _store) = keeper("release", bounds)
  let one = holder(1, "s1")
  let content = bytes(30, 6)
  let blob = blob_of(content)

  assert placed(service, one, content, 64) == Stored
  blob_service.release(service, one.pin, one.binding)
  let assert Error(_released) = blob_service.open(service, "s1", blob.digest)

  // The binding's place is free again.
  assert placed(service, one, bytes(20, 7), 64) == Stored
}

pub fn a_restart_forgets_claims_and_hashes_a_blob_again_before_handing_it_out_test() {
  let directory = fixtures.scratch("blobs-restart") <> "/placed-blobs"
  let limits =
    blob_store.Limits(size_limit: 1024, total_cap: 4096, retain_s: 3600)
  let assert Ok(store) = blob_store.open(directory, limits)
  let assert Ok(first) = blob_service.start(store, roomy(), fn() { 1 })
  let content = bytes(50, 8)
  let blob = blob_of(content)
  assert placed(first, holder(1, "s1"), content, 64) == Stored

  // A second keeper over the same directory knows of no claim.
  let assert Ok(second) = blob_service.start(store, roomy(), fn() { 1 })
  let assert Error(_forgotten) = blob_service.open(second, "s1", blob.digest)

  // The blob is damaged on disk; claiming it by status still succeeds, but
  // the first open hashes it, refuses it and removes it.
  let assert Ok(Nil) =
    simplifile.write_bits(blob_store.path(store, blob.digest), bytes(50, 9))
  assert blob_service.stage(second, holder(1, "s1"), blob.digest)
    == Ok(Complete)
  let assert Error(_damaged) = blob_service.open(second, "s1", blob.digest)
  assert blob_store.finished(store, blob.digest) == Error(Nil)
}

pub fn a_half_written_file_that_holds_every_byte_is_finished_by_the_next_piece_test() {
  let #(service, store) = keeper("crash", roomy())
  let content = bytes(40, 2)
  let blob = blob_of(content)

  // A crash between the last append and the rename leaves the whole blob in
  // its half-written file.
  let assert Ok(_held) = blob_store.append(store, blob, content, 1, set.new())
  assert blob_service.take(service, holder(1, "s1"), piece(content, 0, 10))
    == Stored
  let assert Ok(_path) = blob_service.open(service, "s1", blob.digest)
    as "the finished blob opens"
  Nil
}

fn refused(verdict: blob_transfer.Verdict) -> Bool {
  case verdict {
    Refused(..) -> True
    _ -> False
  }
}

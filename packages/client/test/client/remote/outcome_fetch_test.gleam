//// The bookkeeping of an outcome fetched in pieces (protocol-change/110),
//// driven without a link: what is asked for next, when the bytes are handed
//// back, and every way a hostile executor's answer ends the fetch.

import client/remote/blob_transfer
import client/remote/outcome_fetch.{Ask, Done, GiveUp}
import client/remote/untrusted_wire.{OutcomeNotHeld, OutcomeServed}
import gleam/bit_array
import gleam/int
import gleam/list
import qcheck

/// An outcome's encoding of `size` bytes, and its digest.
fn encoding(size: Int) -> #(BitArray, String) {
  let bytes = <<0:size({ size * 8 })>>
  #(bytes, blob_transfer.digest_of(bytes))
}

/// The piece of `bytes` at `offset`, of at most `length` bytes, as served.
fn served(
  bytes: BitArray,
  digest: String,
  offset: Int,
  length: Int,
) -> untrusted_wire.OutcomePiece {
  let size = bit_array.byte_size(bytes)
  let length = int.min(length, size - offset)
  let assert Ok(cut) = bit_array.slice(bytes, offset, length)
    as "the test's piece is inside the outcome"
  OutcomeServed(size:, digest:, offset:, bytes: cut)
}

/// Feeds a fetch pieces of `length` from an honest executor until it ends.
fn honest(
  fetch: outcome_fetch.Fetch,
  bytes: BitArray,
  digest: String,
  length: Int,
) -> outcome_fetch.Step {
  case
    outcome_fetch.took(
      fetch,
      served(bytes, digest, outcome_fetch.held(fetch), length),
    )
  {
    Ask(fetch:, ..) -> honest(fetch, bytes, digest, length)
    ended -> ended
  }
}

pub fn a_description_outside_the_bounds_is_refused_test() {
  let #(_bytes, digest) = encoding(4)
  let assert Error(_zero) = outcome_fetch.begin(0, digest)
  let assert Error(_too_large) =
    outcome_fetch.begin(untrusted_wire.max_outcome_bytes + 1, digest)
  let assert Error(_not_a_digest) = outcome_fetch.begin(4, "../../etc")
  let assert Ok(_fetch) =
    outcome_fetch.begin(untrusted_wire.max_outcome_bytes, digest)
  Nil
}

pub fn pieces_in_order_hand_back_the_whole_test() {
  let #(bytes, digest) = encoding(10)
  let assert Ok(fetch) = outcome_fetch.begin(10, digest)
  assert honest(fetch, bytes, digest, 3) == Done(bytes)
}

pub fn pieces_of_any_length_within_the_bound_hand_back_the_whole_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(200)
  |> qcheck.with_seed(qcheck.seed(1110))
  |> qcheck.run(
    qcheck.tuple2(qcheck.bounded_int(1, 300), qcheck.bounded_int(1, 64)),
    fn(drawn) {
      // The step bound assumes the pieces an honest executor cuts, which are as
      // large as a frame allows; a few short ones still fit inside it.
      let #(size, drawn_length) = drawn
      let length = int.max(drawn_length, { size + 7 } / 8)
      let #(bytes, digest) = encoding(size)
      let assert Ok(fetch) = outcome_fetch.begin(size, digest)
      assert honest(fetch, bytes, digest, length) == Done(bytes)
    },
  )
}

pub fn a_piece_at_another_offset_is_asked_for_again_test() {
  let #(bytes, digest) = encoding(10)
  let assert Ok(fetch) = outcome_fetch.begin(10, digest)
  let assert Ask(fetch:, offset: 0) =
    outcome_fetch.took(fetch, served(bytes, digest, 4, 3))
  let assert Ask(offset: 3, ..) =
    outcome_fetch.took(fetch, served(bytes, digest, 0, 3))
  Nil
}

pub fn a_piece_past_the_size_or_empty_gives_up_test() {
  let #(bytes, digest) = encoding(10)
  let assert Ok(fetch) = outcome_fetch.begin(10, digest)
  let assert GiveUp(_past) =
    outcome_fetch.took(
      fetch,
      OutcomeServed(
        size: 10,
        digest:,
        offset: 0,
        bytes: bit_array.append(bytes, <<1>>),
      ),
    )
  let assert GiveUp(_empty) =
    outcome_fetch.took(
      fetch,
      OutcomeServed(size: 10, digest:, offset: 0, bytes: <<>>),
    )
  Nil
}

pub fn nothing_held_gives_up_test() {
  let #(_bytes, digest) = encoding(10)
  let assert Ok(fetch) = outcome_fetch.begin(10, digest)
  let assert GiveUp(_reason) = outcome_fetch.took(fetch, OutcomeNotHeld("gone"))
  Nil
}

pub fn a_new_description_restarts_a_bounded_number_of_times_test() {
  let #(bytes, digest) = encoding(10)
  let #(other, other_digest) = encoding(12)
  let assert Ok(fetch) = outcome_fetch.begin(10, digest)

  // Each piece of another description starts over from nothing, until the
  // restarts are spent.
  let ended =
    list.fold(
      list.repeat(Nil, outcome_fetch.max_restarts + 1),
      Ask(fetch, 0),
      fn(step, _turn) {
        case step {
          Ask(fetch:, ..) ->
            case outcome_fetch.describes(fetch, 10, digest) {
              True ->
                outcome_fetch.took(fetch, served(other, other_digest, 0, 4))
              False -> outcome_fetch.took(fetch, served(bytes, digest, 0, 4))
            }
          ended -> ended
        }
      },
    )
  let assert GiveUp(_reason) = ended
  Nil
}

pub fn bytes_that_do_not_match_the_digest_are_never_handed_back_test() {
  let #(bytes, _digest) = encoding(8)
  let lie = blob_transfer.digest_of(<<"lie">>)
  let assert Ok(fetch) = outcome_fetch.begin(8, lie)

  // Whole bytes under the wrong digest restart the fetch; when the restarts are
  // spent, it gives up rather than hand them back.
  let ended =
    list.fold(
      list.repeat(Nil, outcome_fetch.max_restarts + 1),
      Ask(fetch, 0),
      fn(step, _turn) {
        case step {
          Ask(fetch:, ..) -> outcome_fetch.took(fetch, served(bytes, lie, 0, 8))
          ended -> ended
        }
      },
    )
  let assert GiveUp(_reason) = ended
  Nil
}

pub fn an_executor_that_never_converges_is_cut_off_test() {
  let #(bytes, digest) = encoding(10)
  let assert Ok(fetch) = outcome_fetch.begin(10, digest)

  // Answering every request with the piece at offset 4 never moves the fetch.
  let ended =
    list.fold(list.repeat(Nil, 100), Ask(fetch, 0), fn(step, _turn) {
      case step {
        Ask(fetch:, ..) ->
          outcome_fetch.took(fetch, served(bytes, digest, 4, 3))
        ended -> ended
      }
    })
  let assert GiveUp(_reason) = ended
  Nil
}

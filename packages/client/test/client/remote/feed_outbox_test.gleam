//// The laptop's outbox of lane frames, checked against the box's own piece
//// rules under generated interleavings, driven by `statem`
//// (protocol-change/108, "Fixed-seed properties").
////
//// The box in this test is `feed_pieces`, the real module the feed host uses,
//// not a restatement of it. A command is the lane transmitting a frame of some
//// size, the laptop sending the piece that is due and the link doing something
//// to the answer, a request the link delayed arriving at the box again, or an
//// answer that names no piece in flight. The checks after every command:
////
//// - `once`: the frames the box completed are the frames the lane transmitted,
////   in order, each exactly once and byte for byte, however many pieces were
////   sent twice;
//// - `pieces`: every piece is at most `piece_bytes`, is text that ends on a
////   character boundary, and either ends its frame or is at least half a piece,
////   which is the floor the box holds a laptop to;
//// - `bound`: the outbox never holds more than its frame and byte bounds, and a
////   frame the bounds refuse changes nothing;
//// - `stray`: an answer that names no piece in flight changes nothing.
////
//// Every randomized test runs on a fixed, named seed.

import client/remote/feed_outbox
import client/remote/feed_pieces
import client/remote_feed
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import qcheck
import statem

/// The seed of the campaign over mixed frames and links.
const campaign_seed = 1086

/// The seed of the campaign that mostly pushes, with large frames, so the outbox
/// reaches its frame bound and its byte bound.
const pushy_seed = 1087

const runs = 120

const longest = 50

fn config(seed: Int) -> statem.Config {
  statem.default_config(seed:)
  |> statem.with_test_count(runs)
  |> statem.with_max_commands(case seed == pushy_seed {
    True -> longest * 4
    False -> longest
  })
}

// --- commands ----------------------------------------------------------------

/// How large a frame the lane transmits.
type Size {
  /// Two bytes.
  Tiny

  /// A few multibyte characters.
  Text

  /// More than two pieces of three-byte characters behind a one-byte prefix, so
  /// a piece boundary falls inside a character.
  Big

  /// More than the frame bound.
  TooBig

  /// Nothing.
  Nothing
}

/// What the link does to the answer to a piece.
type Fate {
  Delivered
  Lost
  Duplicated
}

/// How a campaign weights what the lane does.
type Mix {
  Mixed
  Pushy
}

type Command {
  Push(size: Size)
  Send(fate: Fate)
  Delayed
  Stray(n: Int, offset: Int)
}

fn command(mix: Mix) -> qcheck.Generator(Command) {
  let pushes = case mix {
    Mixed -> 25
    Pushy -> 70
  }
  qcheck.from_weighted_generators(#(pushes, qcheck.map(size(mix), Push)), [
    #(45, qcheck.map(fate(), Send)),
    #(15, qcheck.constant(Delayed)),
    #(
      15,
      qcheck.map2(qcheck.bounded_int(0, 4), qcheck.bounded_int(0, 4), Stray),
    ),
  ])
}

fn size(mix: Mix) -> qcheck.Generator(Size) {
  let big = case mix {
    Mixed -> 15
    Pushy -> 400
  }
  qcheck.from_weighted_generators(#(45, qcheck.constant(Tiny)), [
    #(30, qcheck.constant(Text)),
    #(big, qcheck.constant(Big)),
    #(5, qcheck.constant(TooBig)),
    #(5, qcheck.constant(Nothing)),
  ])
}

fn fate() -> qcheck.Generator(Fate) {
  qcheck.from_weighted_generators(#(60, qcheck.constant(Delivered)), [
    #(25, qcheck.constant(Lost)),
    #(15, qcheck.constant(Duplicated)),
  ])
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

// --- the system under test ----------------------------------------------------

type Sut {
  Sut(
    outbox: feed_outbox.Outbox,
    box: feed_pieces.Pieces,
    /// The frames the lane transmitted and the outbox accepted, in order.
    pushed: List(String),
    /// The frames the box completed, in order.
    completed: List(String),
    /// The last piece request the laptop sent, which the link may deliver again.
    last: option.Option(feed_outbox.Due),
    serial: Int,
    /// Why each frame the outbox refused was refused, as a tag.
    refused: List(String),
  )
}

fn new_sut() -> Sut {
  Sut(
    outbox: feed_outbox.new(),
    box: feed_pieces.new(),
    pushed: [],
    completed: [],
    last: None,
    serial: 0,
    refused: [],
  )
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

/// A frame of the size, unique by its serial number.
fn frame(serial: Int, size: Size) -> String {
  let head = "{\"n\":" <> int.to_string(serial)
  case size {
    Tiny -> head <> "}"
    Text -> head <> ",\"t\":\"é€😀\"}"
    Big -> "a" <> string.repeat("€", 340_000) <> head
    TooBig -> string.repeat("x", remote_feed.frame_bytes + 1)
    Nothing -> ""
  }
}

// --- running a command --------------------------------------------------------

fn execute(sut: Sut, command: Command) -> Result(Sut, statem.Violation) {
  use stepped <- result.try(case command {
    Push(size:) -> pushed(sut, size)
    Send(fate:) -> sent(sut, fate)
    Delayed -> delayed(sut)
    Stray(n:, offset:) -> stray(sut, n, offset)
  })
  use Nil <- result.try(agrees(stepped))
  Ok(stepped)
}

fn pushed(sut: Sut, size: Size) -> Result(Sut, statem.Violation) {
  let serial = sut.serial + 1
  let text = frame(serial, size)
  let bytes = string.byte_size(text)
  let before_bytes = feed_outbox.held_bytes(sut.outbox)
  let expected = case
    bytes == 0,
    bytes > remote_feed.frame_bytes,
    feed_outbox.held_frames(sut.outbox) >= feed_outbox.max_frames
    || before_bytes + bytes > feed_outbox.max_bytes
  {
    True, _, _ -> Some(feed_outbox.Empty)
    False, True, _ -> Some(feed_outbox.TooLarge)
    False, False, True -> Some(feed_outbox.Full)
    False, False, False -> None
  }
  case feed_outbox.push(sut.outbox, text), expected {
    Ok(outbox), None ->
      Ok(Sut(..sut, outbox:, pushed: list.append(sut.pushed, [text]), serial:))
    Error(why), Some(wanted) if why == wanted ->
      Ok(Sut(..sut, refused: [refusal_tag(sut, why), ..sut.refused]))
    _, _ ->
      Error(violation(
        "bound",
        "a frame of " <> int.to_string(bytes) <> " bytes was misjudged",
      ))
  }
}

/// A tag for a refusal, which says which bound a `Full` outbox hit.
fn refusal_tag(sut: Sut, why: feed_outbox.Refusal) -> String {
  case why {
    feed_outbox.Empty -> "empty"
    feed_outbox.TooLarge -> "too-large"
    feed_outbox.Full ->
      case feed_outbox.held_frames(sut.outbox) >= feed_outbox.max_frames {
        True -> "frame-bound"
        False -> "byte-bound"
      }
  }
}

/// Sends the piece that is due to the box, and lets the link do its worst to the
/// answer.
fn sent(sut: Sut, fate: Fate) -> Result(Sut, statem.Violation) {
  let #(outbox, due) = feed_outbox.take(sut.outbox)
  case due {
    None -> Ok(Sut(..sut, outbox:))
    Some(piece) -> {
      use #(box, completed) <- result.try(deliver(sut, piece))
      let answered = case fate {
        Delivered -> feed_outbox.admitted(outbox, piece.n, piece.offset)
        Duplicated ->
          feed_outbox.admitted(
            feed_outbox.admitted(outbox, piece.n, piece.offset),
            piece.n,
            piece.offset,
          )
        Lost -> feed_outbox.unanswered(outbox).0
      }
      Ok(Sut(..sut, outbox: answered, box:, completed:, last: Some(piece)))
    }
  }
}

/// A request the link delayed reaches the box again. The box answers it without
/// effect, which is the rule that makes a resend safe.
fn delayed(sut: Sut) -> Result(Sut, statem.Violation) {
  case sut.last {
    None -> Ok(sut)
    Some(piece) -> {
      use #(box, completed) <- result.map(deliver(sut, piece))
      Sut(..sut, box:, completed:)
    }
  }
}

/// Hands one piece to the real box rules. The box must never refuse a piece the
/// outbox produced, and a completed frame is recorded.
fn deliver(
  sut: Sut,
  piece: feed_outbox.Due,
) -> Result(#(feed_pieces.Pieces, List(String)), statem.Violation) {
  let request =
    remote_feed.Piece(
      feed: "0123456789abcdef0123456789abcdef",
      n: piece.n,
      offset: piece.offset,
      total: piece.total,
      text: piece.text,
    )
  use Nil <- result.try(shaped(piece))
  case feed_pieces.admit(sut.box, request) {
    feed_pieces.Held(pieces:) -> Ok(#(pieces, sut.completed))
    feed_pieces.Completed(pieces:, frame:) ->
      Ok(#(pieces, list.append(sut.completed, [frame])))
    feed_pieces.Repeated -> Ok(#(sut.box, sut.completed))
    feed_pieces.Refused(why:) ->
      Error(violation(
        "once",
        "the box refused a piece the outbox sent: " <> string.inspect(why),
      ))
  }
}

/// A piece is within the sizes the codec and the box allow.
fn shaped(piece: feed_outbox.Due) -> Result(Nil, statem.Violation) {
  let size = string.byte_size(piece.text)
  let last = piece.offset + size == piece.total
  case
    size >= 1
    && size <= remote_feed.piece_bytes
    && piece.offset + size <= piece.total
    && { last || size >= remote_feed.piece_bytes / 2 }
  {
    True -> Ok(Nil)
    False ->
      Error(violation(
        "pieces",
        "a piece of "
          <> int.to_string(size)
          <> " bytes at "
          <> int.to_string(piece.offset)
          <> " of "
          <> int.to_string(piece.total),
      ))
  }
}

/// An answer that names no piece in flight changes nothing. With a piece held,
/// one is put in flight first, so the answer meets a flight it does not name, and
/// the flight is then made due again as a lost answer would, so the campaign goes
/// on from the same place.
fn stray(sut: Sut, n: Int, offset: Int) -> Result(Sut, statem.Violation) {
  let #(flying, due) = feed_outbox.take(sut.outbox)
  let names_it = case due {
    Some(piece) -> piece.n == n && piece.offset == offset
    None -> False
  }
  case names_it || feed_outbox.admitted(flying, n, offset) == flying {
    True -> Ok(Sut(..sut, outbox: feed_outbox.unanswered(flying).0))
    False ->
      Error(violation("stray", "an answer that named no piece in flight moved"))
  }
}

// --- the checks after every command -------------------------------------------

fn agrees(sut: Sut) -> Result(Nil, statem.Violation) {
  let done = list.length(sut.completed)
  use Nil <- result.try(case list.take(sut.pushed, done) == sut.completed {
    True -> Ok(Nil)
    False ->
      Error(violation(
        "once",
        "the box completed "
          <> int.to_string(done)
          <> " frames that are not the first frames the lane transmitted",
      ))
  })
  case
    feed_outbox.held_frames(sut.outbox) <= feed_outbox.max_frames
    && feed_outbox.held_bytes(sut.outbox) <= feed_outbox.max_bytes
  {
    True -> Ok(Nil)
    False -> Error(violation("bound", "the outbox passed its bounds"))
  }
}

// --- the properties -----------------------------------------------------------

fn spec(mix: Mix) -> statem.Spec(Nil, Command, Sut) {
  statem.Spec(
    initial: Nil,
    command: fn(_) { command(mix) },
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(_, _) { Nil },
    new_sut: new_sut,
    execute: fn(sut, _, command) { execute(sut, command) },
    finish: fn(sut, _) { drained(sut) },
    teardown: fn(_) { Nil },
  )
}

/// At the end of a run the link is made honest and the outbox is driven empty:
/// every frame the lane transmitted must then reach the box whole and once.
fn drained(sut: Sut) -> Result(Nil, statem.Violation) {
  use done <- result.try(drain(sut, 0))
  case done.completed == done.pushed {
    True -> Ok(Nil)
    False ->
      Error(violation(
        "once",
        "after the link healed the box holds "
          <> int.to_string(list.length(done.completed))
          <> " of "
          <> int.to_string(list.length(done.pushed))
          <> " frames",
      ))
  }
}

fn drain(sut: Sut, steps: Int) -> Result(Sut, statem.Violation) {
  case feed_outbox.held_frames(sut.outbox) == 0 || steps > 400 {
    True -> Ok(sut)
    False -> {
      use next <- result.try(sent(sut, Delivered))
      drain(next, steps + 1)
    }
  }
}

pub fn the_outbox_hands_the_box_each_frame_once_and_whole_test() {
  checked(Mixed, campaign_seed)
}

pub fn a_full_outbox_refuses_and_still_hands_over_what_it_took_test() {
  checked(Pushy, pushy_seed)
}

fn checked(mix: Mix, seed: Int) -> Nil {
  case statem.check(spec(mix), config(seed)) {
    Ok(Nil) -> Nil

    // EUnit clips a long panic message, so the whole report also goes to
    // standard error, which EUnit does not capture.
    Error(failure) -> {
      let report = statem.report(failure, describe)
      io.println_error(report)
      panic as report
    }
  }
}

// --- direct cases ---------------------------------------------------------------

pub fn a_frame_is_cut_into_full_pieces_and_a_short_last_one_test() {
  let text = "a" <> string.repeat("€", 340_000)
  let assert Ok(outbox) = feed_outbox.push(feed_outbox.new(), text)
  let sizes = piece_sizes(outbox, [])
  assert list.length(sizes) == 3
  assert list.fold(sizes, 0, int.add) == bit_array.byte_size(<<text:utf8>>)

  // Every piece but the last is within three bytes of a full piece, which is
  // how far a boundary inside a character can pull a cut back.
  let assert [first, second, ..] = sizes
  assert first <= remote_feed.piece_bytes
  assert first >= remote_feed.piece_bytes - 3
  assert second >= remote_feed.piece_bytes - 3
}

fn piece_sizes(outbox: feed_outbox.Outbox, found: List(Int)) -> List(Int) {
  case feed_outbox.take(outbox) {
    #(_, None) -> list.reverse(found)
    #(taken, Some(piece)) ->
      piece_sizes(feed_outbox.admitted(taken, piece.n, piece.offset), [
        string.byte_size(piece.text),
        ..found
      ])
  }
}

pub fn an_unanswered_piece_is_sent_again_unchanged_with_a_growing_pause_test() {
  let assert Ok(outbox) = feed_outbox.push(feed_outbox.new(), "{}")
  let #(outbox, first) = feed_outbox.take(outbox)
  let #(outbox, pause) = feed_outbox.unanswered(outbox)
  let #(outbox, again) = feed_outbox.take(outbox)
  assert first == again
  assert pause == 250
  let #(outbox, _) = feed_outbox.take(outbox)
  let #(_, longer) = feed_outbox.unanswered(outbox)
  assert longer == 500
}

pub fn nothing_is_due_while_a_piece_is_in_flight_test() {
  let assert Ok(outbox) = feed_outbox.push(feed_outbox.new(), "{}")
  let assert Ok(outbox) = feed_outbox.push(outbox, "[]")
  let #(outbox, first) = feed_outbox.take(outbox)
  assert first != None
  assert feed_outbox.take(outbox).1 == None
}

pub fn an_answer_for_another_piece_does_not_advance_the_one_in_flight_test() {
  let assert Ok(outbox) = feed_outbox.push(feed_outbox.new(), "{}")
  let #(outbox, _) = feed_outbox.take(outbox)
  assert feed_outbox.admitted(outbox, 2, 0) == outbox
  assert feed_outbox.admitted(outbox, 1, 1) == outbox
  assert feed_outbox.held_frames(feed_outbox.admitted(outbox, 1, 0)) == 0
}

// The pushy campaign has to reach both bounds, or its checks of them are empty.
// Each command list is run through the same `execute`, and the refusals it made
// are collected.
pub fn the_pushy_campaign_reaches_both_bounds_and_the_other_refusals_test() {
  let tags =
    numbers(0, 119)
    |> list.flat_map(fn(run) {
      let commands = statem.commands(spec(Pushy), config(pushy_seed), run)
      case run_all(new_sut(), commands) {
        Ok(done) -> done.refused
        Error(_) -> []
      }
    })
  let missing =
    list.filter(["frame-bound", "byte-bound", "too-large", "empty"], fn(tag) {
      !list.contains(tags, tag)
    })
  assert missing == []
}

fn run_all(sut: Sut, commands: List(Command)) -> Result(Sut, statem.Violation) {
  case commands {
    [] -> Ok(sut)
    [command, ..rest] -> {
      use stepped <- result.try(execute(sut, command))
      run_all(stepped, rest)
    }
  }
}

/// The integers from `start` to `stop`, inclusive.
fn numbers(start: Int, stop: Int) -> List(Int) {
  case start > stop {
    True -> []
    False -> [start, ..numbers(start + 1, stop)]
  }
}

//// The pieces of the lane's frames under generated interleavings, driven by
//// `statem` (protocol-change/108, "Fixed-seed properties").
////
//// The lane transmits frames one at a time, and the laptop cuts each into pieces
//// and sends them in order. The link may lose the box's answer to a piece, so the
//// laptop sends the same piece again, and a piece that was already admitted may
//// reach the box a second time from a request the link delayed. A command is one
//// step of the laptop: the current piece is admitted and its answer reaches the
//// laptop, is lost, or the piece arrives twice; an old piece arrives again; or a
//// hostile piece arrives out of order or for the wrong frame.
////
//// The oracle is the list of frames the lane wrote. The rules, each under its own
//// tag:
////
//// - `once`: the frames the box completes are a prefix of the lane's frames, in
////   order, each exactly once and byte for byte whole, whatever was resent;
//// - `repeat`: a piece admitted before is answered as repeated and changes
////   nothing;
//// - `refuse`: a piece out of order, or of a frame other than the next, is
////   refused and changes nothing.
////
//// Every randomized test runs on a fixed, named seed.

import client/remote/feed_pieces
import client/remote_feed
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem

/// The seed of the campaign.
const campaign_seed = 1083

const runs = 250

const longest = 80

fn config() -> statem.Config {
  statem.default_config(seed: campaign_seed)
  |> statem.with_test_count(runs)
  |> statem.with_max_commands(longest)
}

// --- commands ----------------------------------------------------------------

/// What the link does to the box's answer to the laptop's current piece.
type Fate {
  /// The answer reaches the laptop, which moves on.
  Answered

  /// The answer is lost, so the laptop will send the same piece again.
  AnswerLost

  /// The request arrives twice, and the laptop moves on after the answer.
  Doubled
}

type Command {
  /// The laptop's current piece, `size` bytes long if it begins a new piece,
  /// with the link's fate for its answer.
  Send(size: Int, fate: Fate)

  /// A request the link delayed: an older piece of any earlier frame or of the
  /// frame being assembled arrives again. `pick` chooses which, by position.
  Replay(pick: Int)

  /// A piece that skips ahead of what the box admitted.
  Skip

  /// A piece of the frame after the next.
  Ahead

  /// A piece that names another size for its frame.
  Resized
}

fn command() -> qcheck.Generator(Command) {
  qcheck.from_weighted_generators(
    #(
      60,
      qcheck.map2(qcheck.bounded_int(1, 9), fate(), fn(size, fate) {
        Send(size:, fate:)
      }),
    ),
    [
      #(15, qcheck.map(qcheck.bounded_int(0, 63), Replay)),
      #(8, qcheck.constant(Skip)),
      #(8, qcheck.constant(Ahead)),
      #(9, qcheck.constant(Resized)),
    ],
  )
}

fn fate() -> qcheck.Generator(Fate) {
  qcheck.from_weighted_generators(#(55, qcheck.constant(Answered)), [
    #(25, qcheck.constant(AnswerLost)),
    #(20, qcheck.constant(Doubled)),
  ])
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

/// The integers from `start` to `stop`, inclusive.
fn numbers(start: Int, stop: Int) -> List(Int) {
  case start > stop {
    True -> []
    False -> [start, ..numbers(start + 1, stop)]
  }
}

// --- the laptop and the oracle ----------------------------------------------

/// Whether the oracle already saw a piece, which makes the box's answer
/// `Repeated`.
type Seen {
  /// The piece is new.
  Fresh

  /// The piece was sent before.
  Again
}

/// A piece the laptop has sent at least once, as it was sent.
type Sent {
  Sent(n: Int, offset: Int, total: Int, text: String)
}

type Sut {
  Sut(
    box: feed_pieces.Pieces,
    /// The frames the box completed, in order.
    completed: List(String),
    /// The number of the frame the laptop is sending.
    frame: Int,
    /// Where the laptop's next piece of that frame begins.
    offset: Int,
    /// The piece the laptop sent and has no answer for, to send again.
    pending: Option(Sent),
    /// Every piece the laptop ever sent, oldest first, for the replays.
    history: List(Sent),
  )
}

fn new_sut() -> Sut {
  Sut(
    box: feed_pieces.new(),
    completed: [],
    frame: 1,
    offset: 0,
    pending: None,
    history: [],
  )
}

/// The text of the lane's frame `n`: ASCII, so a byte cut is a character cut,
/// and long enough to need several pieces.
fn lane_frame(n: Int) -> String {
  let length = 1 + { n * 7 } % 37
  "f" <> int.to_string(n) <> ":" <> string.repeat(int.to_string(n % 10), length)
}

fn piece_of(sent: Sent) -> remote_feed.Piece {
  remote_feed.Piece(
    feed: "00000000000000000000000000000000",
    n: sent.n,
    offset: sent.offset,
    total: sent.total,
    text: sent.text,
  )
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

// --- running a command ------------------------------------------------------

fn execute(sut: Sut, command: Command) -> Result(Sut, statem.Violation) {
  use stepped <- result.try(case command {
    Send(size:, fate:) -> sent(sut, size, fate)
    Replay(pick:) -> replayed(sut, pick)
    Skip -> hostile(sut, skipping(sut))
    Ahead -> hostile(sut, ahead(sut))
    Resized -> resized(sut)
  })
  use Nil <- result.try(whole(stepped))
  Ok(stepped)
}

/// The laptop's next piece: the pending one if its answer was lost, and otherwise
/// the next `size` bytes of the current frame.
fn current(sut: Sut, size: Int) -> Sent {
  case sut.pending {
    Some(sent) -> sent
    None -> {
      let text = lane_frame(sut.frame)
      let total = string.byte_size(text)
      let take = int.min(size, total - sut.offset)
      Sent(
        n: sut.frame,
        offset: sut.offset,
        total:,
        text: slice(text, sut.offset, take),
      )
    }
  }
}

fn slice(text: String, offset: Int, length: Int) -> String {
  let assert Ok(cut) =
    bit_array.slice(bit_array.from_string(text), offset, length)
    as "the cut lies inside an ASCII frame"
  let assert Ok(piece) = bit_array.to_string(cut) as "an ASCII cut is text"
  piece
}

/// Sends the laptop's current piece and applies the link's fate.
fn sent(sut: Sut, size: Int, fate: Fate) -> Result(Sut, statem.Violation) {
  let piece = current(sut, size)
  let seen = case sut.pending {
    Some(_) -> Again
    None -> Fresh
  }
  use admitted <- result.try(admit(sut, piece, seen))
  let admitted = Sut(..admitted, history: remember(admitted.history, piece))
  case fate {
    // The box admitted the piece and its answer never came back, so the
    // laptop holds the piece to send again.
    AnswerLost -> Ok(Sut(..admitted, pending: Some(piece)))
    Answered -> Ok(advance(admitted, piece))
    Doubled -> {
      use twice <- result.try(admit(admitted, piece, Again))
      Ok(advance(twice, piece))
    }
  }
}

fn remember(history: List(Sent), piece: Sent) -> List(Sent) {
  case list.contains(history, piece) {
    True -> history
    False -> list.append(history, [piece])
  }
}

/// The laptop got an answer for `piece`: it moves to the next piece, or to the
/// next frame when this one reached the end.
fn advance(sut: Sut, piece: Sent) -> Sut {
  let next = piece.offset + string.byte_size(piece.text)
  case next >= piece.total {
    True -> Sut(..sut, frame: piece.n + 1, offset: 0, pending: None)
    False -> Sut(..sut, offset: next, pending: None)
  }
}

/// Admits a piece into the box. `repeat` says the oracle already saw it, so the
/// box must answer `Repeated` and change nothing. A completed frame is checked
/// against the lane's own text at once.
fn admit(sut: Sut, sent: Sent, seen: Seen) -> Result(Sut, statem.Violation) {
  let known = list.contains(sut.history, sent)
  case feed_pieces.admit(sut.box, piece_of(sent)), known || seen == Again {
    feed_pieces.Held(pieces:), False -> Ok(Sut(..sut, box: pieces))
    feed_pieces.Completed(pieces:, frame:), False -> {
      let expected = lane_frame(sent.n)
      case frame == expected {
        True ->
          Ok(
            Sut(
              ..sut,
              box: pieces,
              completed: list.append(sut.completed, [frame]),
            ),
          )
        False ->
          Error(violation(
            "once",
            "frame " <> int.to_string(sent.n) <> " was not handed over whole",
          ))
      }
    }
    feed_pieces.Repeated, True -> Ok(sut)
    feed_pieces.Repeated, False ->
      Error(violation("repeat", "a new piece was answered as repeated"))
    feed_pieces.Held(..), True | feed_pieces.Completed(..), True ->
      Error(violation("repeat", "a repeated piece changed the box"))
    feed_pieces.Refused(why:), _ ->
      Error(violation(
        "refuse",
        "an in-order piece was refused: " <> string.inspect(why),
      ))
  }
}

/// An old piece reaches the box again.
fn replayed(sut: Sut, pick: Int) -> Result(Sut, statem.Violation) {
  case list.length(sut.history) {
    0 -> Ok(sut)
    size ->
      case list.drop(sut.history, pick % size) {
        [old, ..] -> admit(sut, old, Again)
        [] -> Ok(sut)
      }
  }
}

/// A piece of the frame the box is assembling that begins one byte past what the
/// box admitted.
fn skipping(sut: Sut) -> Sent {
  Sent(
    n: feed_pieces.next(sut.box),
    offset: feed_pieces.held_bytes(sut.box) + 1,
    total: 1000,
    text: "z",
  )
}

/// A piece of the frame after the next.
fn ahead(sut: Sut) -> Sent {
  Sent(n: feed_pieces.next(sut.box) + 1, offset: 0, total: 4, text: "abcd")
}

/// A piece the box must refuse, which changes nothing: the next frame number and
/// the bytes held are what they were.
fn hostile(sut: Sut, piece: Sent) -> Result(Sut, statem.Violation) {
  case feed_pieces.admit(sut.box, piece_of(piece)) {
    feed_pieces.Refused(..) -> Ok(sut)
    other ->
      Error(violation(
        "refuse",
        "a hostile piece was not refused: " <> string.inspect(other),
      ))
  }
}

/// A piece of the frame being assembled that names a different total. Only a
/// frame partly received can disagree, so the command does nothing on a fresh
/// frame.
fn resized(sut: Sut) -> Result(Sut, statem.Violation) {
  case feed_pieces.held_bytes(sut.box) > 0 {
    False -> Ok(sut)
    True ->
      hostile(
        sut,
        Sent(
          n: feed_pieces.next(sut.box),
          offset: feed_pieces.held_bytes(sut.box),
          total: 5000,
          text: "q",
        ),
      )
  }
}

// --- the checks after every command ------------------------------------------

/// The frames the box completed are the lane's first frames, each once.
fn whole(sut: Sut) -> Result(Nil, statem.Violation) {
  let expected =
    numbers(1, list.length(sut.completed))
    |> list.map(lane_frame)
  case sut.completed == expected {
    True -> Ok(Nil)
    False ->
      Error(violation(
        "once",
        "the box completed " <> string.inspect(sut.completed),
      ))
  }
}

// --- the properties -----------------------------------------------------------

fn spec() -> statem.Spec(Nil, Command, Sut) {
  statem.Spec(
    initial: Nil,
    command: fn(_) { command() },
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(_, _) { Nil },
    new_sut:,
    execute: fn(sut, _, command) { execute(sut, command) },
    finish: fn(sut, _) {
      case feed_pieces.next(sut.box) == list.length(sut.completed) + 1 {
        True -> Ok(Nil)
        False -> Error(violation("once", "the next frame number drifted"))
      }
    },
    teardown: fn(_) { Nil },
  )
}

pub fn any_interleaving_of_lost_answers_and_resends_hands_over_each_frame_once_test() {
  case statem.check(spec(), config()) {
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

// --- direct cases -------------------------------------------------------------

fn piece(n: Int, offset: Int, total: Int, text: String) -> remote_feed.Piece {
  remote_feed.Piece(
    feed: "00000000000000000000000000000000",
    n:,
    offset:,
    total:,
    text:,
  )
}

pub fn a_frame_in_one_piece_completes_at_once_test() {
  let assert feed_pieces.Completed(pieces:, frame: "{}") =
    feed_pieces.admit(feed_pieces.new(), piece(1, 0, 2, "{}"))
  assert feed_pieces.next(pieces) == 2
  assert feed_pieces.held_bytes(pieces) == 0
}

pub fn a_resent_last_piece_of_a_finished_frame_is_repeated_test() {
  let assert feed_pieces.Held(first) =
    feed_pieces.admit(feed_pieces.new(), piece(1, 0, 4, "ab"))
  let assert feed_pieces.Completed(done, "abcd") =
    feed_pieces.admit(first, piece(1, 2, 4, "cd"))
  assert feed_pieces.admit(done, piece(1, 2, 4, "cd")) == feed_pieces.Repeated
  assert feed_pieces.admit(done, piece(1, 0, 4, "ab")) == feed_pieces.Repeated
}

pub fn a_piece_out_of_order_or_of_the_wrong_frame_is_refused_test() {
  let assert feed_pieces.Held(first) =
    feed_pieces.admit(feed_pieces.new(), piece(1, 0, 4, "ab"))
  assert feed_pieces.admit(first, piece(1, 3, 4, "d"))
    == feed_pieces.Refused(feed_pieces.OutOfOrder)
  assert feed_pieces.admit(first, piece(2, 0, 4, "abcd"))
    == feed_pieces.Refused(feed_pieces.WrongFrame)
  assert feed_pieces.admit(first, piece(1, 2, 9, "cd"))
    == feed_pieces.Refused(feed_pieces.Inconsistent)
  assert feed_pieces.admit(feed_pieces.new(), piece(1, 1, 4, "bcd"))
    == feed_pieces.Refused(feed_pieces.OutOfOrder)
}

pub fn dropping_discards_a_partly_received_frame_test() {
  let assert feed_pieces.Held(first) =
    feed_pieces.admit(feed_pieces.new(), piece(1, 0, 4, "ab"))
  assert feed_pieces.held_bytes(first) == 2
  assert feed_pieces.held_bytes(feed_pieces.drop(first)) == 0
}

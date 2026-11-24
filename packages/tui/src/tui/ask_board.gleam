//// The open asks the terminal knows about for its attached session, and who
//// has the keyboard.
////
//// The daemon's attention feed (protocol-change/120) says how many asks wait
//// for the owner and lists them; `attention.read` returns one in full with
//// the revision an answer must name (protocol-change/128). This module holds
//// what those reads returned as `ask_form.Form` values, decides which asks are
//// drawn, and tracks the one daemon request the asks have in flight. It is
//// pure: `tui/ask_control` performs the reads and calls these functions with
//// what came back.
////
//// ## Flow
////
//// `decode_feed` and `decode_record` → `loaded` → `focus_card` → `answered`
////
//// 1. The read job returns the feed row and the first records. `decode_feed`
////    and `decode_record` turn the daemon's documents into typed values, and
////    `loaded` replaces the board's forms with the records still open, in the
////    order they were asked, keeping the draft of an ask it already held.
//// 2. The composer keeps the keyboard until the owner presses the key that
////    names an ask, which `focus_card` records. A new ask never changes the
////    board's focus, so a keystroke meant for the composer cannot become an
////    answer.
//// 3. An accepted answer removes its form with `answered`. A refused one stays
////    as words on the form with `answer_refused`, and the next read brings the
////    ask's current revision.
////
//// ## The one request
////
//// The asks share the terminal's single control request with the session
//// picker and the project screen. `phase` says whether a read is due, resting,
//// running or sending, so the poll asks again only when the last one settled
//// and its rest has passed, and a failed request is not repeated every tick.
////
//// ## What is drawn
////
//// At most `drawn_limit` asks are drawn, oldest first, and `more` is how many
//// more the feed counted. The cap bounds the card's height and the reads one
//// poll makes; the rest are drawn as they are answered.

import core/attention
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tui/ask_form.{type Form}

/// How many asks are drawn at once.
pub const drawn_limit = 2

/// How long the board rests after a read, in milliseconds.
pub const rest_ms = 4000

/// How long the board rests after a request failed, in milliseconds.
pub const failure_rest_ms = 10_000

/// Who has the keyboard.
pub type Focus {
  /// The composer does, as it did before any ask arrived.
  Composer

  /// The form at this position in `forms` does.
  Card(index: Int)
}

/// Where the board's one daemon request stands.
pub type Phase {
  /// A read is wanted at the next tick that finds the control request free.
  ReadDue

  /// The last request settled; none is asked before this time, on the clock
  /// the step's stamp carries.
  Resting(until_ms: Int)

  /// A read is in the control request.
  Reading

  /// An answer to this ask is in the control request.
  Sending(ask: String)
}

/// The asks of one session.
pub type Board {
  Board(
    /// The session the forms belong to. Another session starts over.
    session: String,
    /// The open asks drawn, oldest first, at most `drawn_limit`.
    forms: List(Form),
    /// How many open asks the feed counted, including those not drawn.
    open: Int,
    /// Where the board's daemon request stands.
    phase: Phase,
    /// Who has the keyboard.
    focus: Focus,
    /// What the owner was last told about an answer, or none.
    notice: Option(String),
  )
}

/// An ask read in full: the record, the revision and whether it may be
/// answered.
pub type Loaded {
  Loaded(ask: attention.Ask, revision: Int, standing: ask_form.Standing)
}

/// What the feed row says about one session's open asks.
pub type Feed {
  Feed(
    /// The number of open asks routed to the owner the session read.
    count: Int,
    /// The identifiers of the asks the row listed, oldest first.
    ids: List(String),
  )
}

/// A board with nothing on it, for a terminal that has not read yet.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.empty().forms == []
/// ```
pub fn empty() -> Board {
  Board(
    session: "",
    forms: [],
    open: 0,
    phase: ReadDue,
    focus: Composer,
    notice: None,
  )
}

/// The board when a read should not wait out its rest. A rest is cut short and
/// a read already due, in flight or sending is left as it is.
///
/// The terminal calls this when the last run of the session ends, because an
/// `ask` ends its asker's run and the owner should not wait out the poll to see
/// the question.
///
/// ## Examples
///
/// ```gleam
/// let board = ask_board.read_failed(ask_board.empty(), 0)
/// assert ask_board.due(board).phase == ask_board.ReadDue
/// ```
pub fn due(board: Board) -> Board {
  case board.phase {
    Resting(..) -> Board(..board, phase: ReadDue)
    ReadDue | Reading | Sending(..) -> board
  }
}

/// The board for `session`: the same board when it already belongs to the
/// session, and a fresh one when the terminal attached to another.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.for_session(ask_board.empty(), "s-1").session == "s-1"
/// ```
pub fn for_session(board: Board, session: String) -> Board {
  case board.session == session {
    True -> board
    False -> Board(..empty(), session:)
  }
}

/// Whether the board has an ask to draw.
///
/// ## Examples
///
/// ```gleam
/// assert !ask_board.has_asks(ask_board.empty())
/// ```
pub fn has_asks(board: Board) -> Bool {
  board.forms != []
}

/// How many open asks are counted and not drawn.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.more(ask_board.Board(..ask_board.empty(), open: 3)) == 3
/// ```
pub fn more(board: Board) -> Int {
  int.max(0, board.open - list.length(board.forms))
}

/// Whether a read is due at `now_ms`: nothing is in the request and the rest
/// has passed.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.read_due(ask_board.empty(), 0)
/// ```
pub fn read_due(board: Board, now_ms: Int) -> Bool {
  case board.phase {
    ReadDue -> True
    Resting(until_ms:) -> now_ms >= until_ms
    Reading | Sending(..) -> False
  }
}

/// The board while a read is in the control request.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.reading(ask_board.empty()).phase == ask_board.Reading
/// ```
pub fn reading(board: Board) -> Board {
  Board(..board, phase: Reading)
}

/// The board while an answer to `ask` is in the control request.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.sending(ask_board.empty(), "ask-1").phase
///   == ask_board.Sending("ask-1")
/// ```
pub fn sending(board: Board, ask: String) -> Board {
  Board(..board, phase: Sending(ask), notice: None)
}

/// Whether the board's request is in the control request.
///
/// ## Examples
///
/// ```gleam
/// assert !ask_board.in_flight(ask_board.empty())
/// ```
pub fn in_flight(board: Board) -> Bool {
  case board.phase {
    Reading | Sending(..) -> True
    ReadDue | Resting(..) -> False
  }
}

/// The board after a read that returned `count` open asks and these records.
/// An ask the board already held keeps its draft, and an ask that is no longer
/// open leaves the board. A record that cannot be read is not drawn, and the
/// count still includes it.
///
/// ## Examples
///
/// ```gleam
/// let board = ask_board.loaded(ask_board.empty(), 0, [], 1000)
/// assert board.phase == ask_board.Resting(1000 + ask_board.rest_ms)
/// ```
pub fn loaded(
  board: Board,
  count: Int,
  records: List(JsonValue),
  now_ms: Int,
) -> Board {
  let fresh =
    records
    |> list.filter_map(decode_record)
    |> list.filter_map(option.to_result(_, Nil))
    |> list.take(drawn_limit)
  let forms =
    list.map(fresh, fn(loaded) {
      case held(board.forms, loaded.ask.header.id) {
        Some(form) ->
          ask_form.refreshed(form, loaded.ask, loaded.revision, loaded.standing)
        None -> ask_form.new(loaded.ask, loaded.revision, loaded.standing)
      }
    })

  settled(Board(..board, forms:, open: count), now_ms + rest_ms)
}

/// The held form for an ask identifier.
fn held(forms: List(Form), id: String) -> Option(Form) {
  list.find(forms, fn(form) { form.ask.header.id == id })
  |> option.from_result
}

/// The board once its request has settled: resting until `until_ms`, with the
/// keyboard returned to the composer when the card it was on is gone.
fn settled(board: Board, until_ms: Int) -> Board {
  // A card that is no longer drawn cannot keep the keyboard.
  let focus = case board.focus {
    Composer -> Composer
    Card(index:) ->
      // The card holds the keyboard only while its form is still there.
      case index < list.length(board.forms) {
        True -> Card(index)
        False -> Composer
      }
  }

  Board(..board, phase: Resting(until_ms), focus:)
}

/// The board after a request failed: it rests longer before asking again and
/// keeps what it already drew.
///
/// ## Examples
///
/// ```gleam
/// let board = ask_board.read_failed(ask_board.empty(), 0)
/// assert board.phase == ask_board.Resting(ask_board.failure_rest_ms)
/// ```
pub fn read_failed(board: Board, now_ms: Int) -> Board {
  settled(board, now_ms + failure_rest_ms)
}

/// The board after the daemon accepted the answer to `ask`: its form is gone,
/// the owner is told, and a read is due so the next ask is drawn.
///
/// ## Examples
///
/// ```gleam
/// let board = ask_board.answered(ask_board.empty(), "ask-1", "Answer sent.")
/// assert board.phase == ask_board.ReadDue
/// ```
pub fn answered(board: Board, ask: String, words: String) -> Board {
  let forms = list.filter(board.forms, fn(form) { form.ask.header.id != ask })
  let board = Board(..board, forms:, open: int.max(0, board.open - 1))

  Board(..settled(board, 0), phase: ReadDue, notice: Some(words))
}

/// The board after the daemon refused the answer to `ask`: the form keeps its
/// draft and shows `words`, and a read is due so the form takes the ask's
/// current revision.
///
/// ## Examples
///
/// ```gleam
/// let board = ask_board.answer_refused(ask_board.empty(), "ask-1", "Gone.")
/// assert board.phase == ask_board.ReadDue
/// ```
pub fn answer_refused(board: Board, ask: String, words: String) -> Board {
  let forms =
    list.map(board.forms, fn(form) {
      case form.ask.header.id == ask {
        True -> ask_form.refused(form, words)
        False -> form
      }
    })

  Board(..settled(Board(..board, forms:), 0), phase: ReadDue)
}

/// The board with the form at `index` replaced.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.with_form(ask_board.empty(), 0, form) == ask_board.empty()
/// ```
pub fn with_form(board: Board, index: Int, form: Form) -> Board {
  Board(
    ..board,
    forms: list.index_map(board.forms, fn(held, at) {
      case at == index {
        True -> form
        False -> held
      }
    }),
  )
}

/// The form that has the keyboard, with its position, or none when the
/// composer does.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.focused(ask_board.empty()) == option.None
/// ```
pub fn focused(board: Board) -> Option(#(Int, Form)) {
  case board.focus {
    Composer -> None
    Card(index:) ->
      board.forms
      |> list.drop(index)
      |> list.first
      |> result.map(fn(form) { #(index, form) })
      |> option.from_result
  }
}

/// Gives the keyboard to the first ask the owner can answer, when there is
/// one. An observer's asks are drawn and take no keys.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.focus_card(ask_board.empty()) == ask_board.empty()
/// ```
pub fn focus_card(board: Board) -> Board {
  let answerable =
    board.forms
    |> list.index_map(fn(form, index) { #(index, form) })
    |> list.find(fn(entry) { entry.1.standing == ask_form.MayAnswer })

  // The keyboard goes to the first ask the owner can answer, or stays put.
  case answerable {
    Ok(#(index, _)) -> Board(..board, focus: Card(index), notice: None)
    Error(Nil) -> board
  }
}

/// Moves the keyboard to the next or previous answerable ask, staying on the
/// current one when there is no other.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.cycle(ask_board.empty(), 1) == ask_board.empty()
/// ```
pub fn cycle(board: Board, by: Int) -> Board {
  // Only a board whose keyboard is on a card has a card to move away from.
  case board.focus {
    Composer -> board
    Card(index:) -> {
      let target = index + by
      let reachable =
        list.drop(board.forms, target)
        |> list.first
        |> result.map(fn(form) { form.standing == ask_form.MayAnswer })

      // The target must exist, not precede the first card, and be answerable.
      case target >= 0, reachable {
        True, Ok(True) -> Board(..board, focus: Card(target))
        True, Ok(False) | True, Error(Nil) | False, _ -> board
      }
    }
  }
}

/// Returns the keyboard to the composer. The drafts are kept.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.leave(ask_board.empty()).focus == ask_board.Composer
/// ```
pub fn leave(board: Board) -> Board {
  Board(..board, focus: Composer)
}

// --- the daemon's documents -----------------------------------------------

/// Reads one session's row of a `sessions.attention` reply: how many open asks
/// it counted and which it listed, oldest first.
///
/// A row that is not `ok` says nothing about the asks, so it is an error and
/// the board keeps what it drew.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.decode_feed(json.Null, "s-1") |> result.is_error
/// ```
pub fn decode_feed(
  document: JsonValue,
  session: String,
) -> Result(Feed, String) {
  use rows <- result.try(array_at(document, "attention"))
  use row <- result.try(
    list.find(rows, fn(row) { text_at(row, "session_id") == Ok(session) })
    |> result.replace_error("the feed has no row for this session"),
  )
  use state <- result.try(text_at(row, "state"))

  // Only a row the session answered says anything about its asks.
  case state {
    "ok" -> feed_of(row)
    other -> Error("the session's feed row is " <> other)
  }
}

/// The asks section of a feed row that is `ok`.
fn feed_of(row: JsonValue) -> Result(Feed, String) {
  use asks <- result.try(member(row, "asks"))
  use count <- result.try(int_at(asks, "count"))
  use items <- result.map(array_at(asks, "items"))
  let ids =
    list.filter_map(items, fn(item) {
      use id <- result.try(text_at(item, "id"))
      use created <- result.map(int_at(item, "created_at"))
      #(created, id)
    })
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.map(fn(entry) { entry.1 })

  Feed(count:, ids:)
}

/// Reads an `attention.read` reply into the ask it holds. An ask that is
/// answered or routed to a strand is not the owner's to answer, so it is no
/// ask here and not an error.
///
/// ## Examples
///
/// ```gleam
/// assert ask_board.decode_record(json.Null) |> result.is_error
/// ```
pub fn decode_record(document: JsonValue) -> Result(Option(Loaded), String) {
  use status <- result.try(text_at(document, "status"))
  use routing <- result.try(text_at(document, "routing"))

  // Only an open ask routed to the owner is drawn.
  case status, routing {
    "open", "owner" -> read_open(document) |> result.map(Some)
    _, _ -> Ok(None)
  }
}

/// Reads the open ask a reply holds, through the same decoder the daemon
/// stores it with: the reply hoists the stored `content` and leaves out the
/// parents, so the stored shape is put back before decoding.
fn read_open(document: JsonValue) -> Result(Loaded, String) {
  use revision <- result.try(int_at(document, "revision"))
  use why <- result.try(member(document, "why"))
  use questions <- result.try(member(document, "questions"))
  use head <- result.try(
    list.try_map(
      ["id", "kind", "status", "routing", "strand", "created_at", "anchor"],
      fn(name) {
        member(document, name) |> result.map(fn(value) { #(name, value) })
      },
    ),
  )
  let stored =
    json.Object(
      list.flatten([
        head,
        [
          #("parents", json.Array([])),
          #("content", json.Object([#("why", why), #("questions", questions)])),
        ],
      ]),
    )

  use ask <- result.map(
    attention.decode_ask(stored)
    |> result.map_error(fn(report) {
      "an ask this terminal cannot read: " <> report.expected
    }),
  )

  Loaded(ask:, revision:, standing: standing_of(document))
}

/// Whether the daemon says the caller may answer: only an explicit true.
fn standing_of(document: JsonValue) -> ask_form.Standing {
  case member(document, "may_answer") {
    Ok(json.Bool(True)) -> ask_form.MayAnswer
    Ok(json.Bool(False))
    | Ok(json.Null)
    | Ok(json.String(_))
    | Ok(json.Int(_))
    | Ok(json.Float(_))
    | Ok(json.Array(_))
    | Ok(json.Object(_))
    | Error(_) -> ask_form.ObserverOnly
  }
}

/// A member of an object, or why there is none.
fn member(value: JsonValue, name: String) -> Result(JsonValue, String) {
  // Only an object has members.
  case value {
    json.Object(fields) ->
      list.key_find(fields, name)
      |> result.map_error(fn(_) { "the daemon's reply has no `" <> name <> "`" })
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("the daemon's reply is not an object")
  }
}

/// A text member.
fn text_at(value: JsonValue, name: String) -> Result(String, String) {
  use found <- result.try(member(value, name))

  // The member must be text.
  case found {
    json.String(text) -> Ok(text)
    json.Array(_)
    | json.Object(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("`" <> name <> "` is not text")
  }
}

/// A whole-number member.
fn int_at(value: JsonValue, name: String) -> Result(Int, String) {
  use found <- result.try(member(value, name))

  // The member must be a whole number.
  case found {
    json.Int(number) -> Ok(number)
    json.Array(_)
    | json.Object(_)
    | json.String(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("`" <> name <> "` is not a number")
  }
}

/// An array member.
fn array_at(value: JsonValue, name: String) -> Result(List(JsonValue), String) {
  use found <- result.try(member(value, name))

  // The member must be a list.
  case found {
    json.Array(items) -> Ok(items)
    json.Object(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("`" <> name <> "` is not a list")
  }
}

//// Attachment-local side conversations, outside the durable transcript.
//// The daemon freezes model context; this portable module owns the bounded
//// board and panel state shared by the terminal and browser.

import core/json
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene

/// An operator's explicit side-conversation action.
pub type Action {
  /// Observe the retained conversation without inference.
  Read

  /// Append one question to the frozen context.
  Ask(text: String)

  /// Replace the frozen base and discard side exchanges.
  Refresh

  /// Release retained context and exchanges.
  Clear

  /// Cancel only this attachment's side request.
  Cancel
}

/// Panel visibility never changes a provider request.
pub type Visibility {
  /// Keep ordinary conversation in focus.
  Hidden

  /// Draw the independent side conversation.
  Visible
}

/// One completed or pending side exchange.
pub type Exchange {
  Exchange(
    /// Operator's question, kept out of the main transcript.
    question: String,
    /// Text returned by the provider, never executable.
    answer: String,
  )
}

/// A validated daemon observation, scoped by connection and strand.
pub type Board {
  Board(
    /// The source strand of the frozen base.
    strand: String,
    /// Request identity that supplied the frozen context.
    snapshot: String,
    /// Resolved provider and model used by the side request.
    model: String,
    /// Open-set status, including idle, running, ready and failed.
    status: String,
    /// Bounded exchanges against this base.
    exchanges: List(Exchange),
    /// Current refusal, cancellation, or usage explanation.
    notice: String,
  )
}

/// Presentation state carries no inference or execution capability.
pub type State {
  State(
    /// Whether the host draws the panel.
    visibility: Visibility,
    /// Last validated attachment-local board.
    board: Option(Board),
    /// The next clock reading at which a running answer may be observed.
    due: Int,
    /// Connection incarnation whose private board this panel displays.
    owner: String,
    /// Exact outstanding lane request, if any.
    pending: Option(Int),
    /// First wrapped side row displayed by a terminal, independent of history.
    scroll: Int,
  )
}

/// Starts with no retained side conversation.
///
/// ## Examples
///
/// ```gleam
/// assert btw.new().visibility == btw.Hidden
/// ```
pub fn new() -> State {
  State(Hidden, None, 0, "", None, 0)
}

/// Encodes the action vocabulary shared with the daemon.
///
/// ## Examples
///
/// ```gleam
/// assert btw.action_name(btw.Read) == "read"
/// ```
pub fn action_name(action: Action) -> String {
  case action {
    Read -> "read"
    Ask(_) -> "ask"
    Refresh -> "refresh"
    Clear -> "clear"
    Cancel -> "cancel"
  }
}

/// Decodes only the five admitted actions and bounded question text.
///
/// ## Examples
///
/// ```gleam
/// assert btw.action("read", "") == Ok(btw.Read)
/// ```
pub fn action(name: String, text: String) -> Result(Action, String) {
  case name {
    "read" -> Ok(Read)
    "refresh" -> Ok(Refresh)
    "clear" -> Ok(Clear)
    "cancel" -> Ok(Cancel)
    "ask" -> {
      use <- bool.guard(string.trim(text) == "", Error("question is empty"))
      use <- bool.guard(
        string.byte_size(text) > 8192,
        Error("question exceeds 8192 bytes"),
      )
      Ok(Ask(text))
    }
    _ -> Error("unknown side-conversation action")
  }
}

/// Serializes one bounded board without transcript envelopes.
///
/// ## Examples
///
/// ```gleam
/// // btw.encode(board)
/// ```
pub fn encode(board: Board) -> json.JsonValue {
  json.Object([
    #("strand", json.String(board.strand)),
    #("snapshot", json.String(board.snapshot)),
    #("model", json.String(board.model)),
    #("status", json.String(board.status)),
    #("notice", json.String(board.notice)),
    #(
      "exchanges",
      json.Array(
        list.map(board.exchanges, fn(item) {
          json.Object([
            #("question", json.String(item.question)),
            #("answer", json.String(item.answer)),
          ])
        }),
      ),
    ),
  ])
}

/// Refuses malformed or oversized boards before either host adopts them.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(btw.decode(json.Null))
/// ```
pub fn decode(value: json.JsonValue) -> Result(Board, String) {
  use <- bool.guard(
    string.byte_size(json.to_string(value)) > 1_048_576,
    Error("side board is too large"),
  )
  use strand <- result.try(field(value, "strand"))
  use snapshot <- result.try(field(value, "snapshot"))
  use model <- result.try(field(value, "model"))
  use status <- result.try(field(value, "status"))
  use notice <- result.try(field(value, "notice"))
  use <- bool.guard(
    string.byte_size(strand) > 256
      || string.byte_size(snapshot) > 256
      || string.byte_size(model) > 2048
      || string.byte_size(status) > 64
      || string.byte_size(notice) > 8192,
    Error("side metadata exceeds its bounds"),
  )
  use rows <- result.try(value_field(value, "exchanges"))
  use rows <- result.try(array(rows))
  use <- bool.guard(list.length(rows) > 8, Error("too many side exchanges"))
  use exchanges <- result.try(
    list.try_map(rows, fn(row) {
      use question <- result.try(field(row, "question"))
      use answer <- result.try(field(row, "answer"))
      use <- bool.guard(
        string.byte_size(question) > 8192 || string.byte_size(answer) > 32_768,
        Error("side exchange is too large"),
      )
      Ok(Exchange(question, answer))
    }),
  )
  let bytes =
    list.fold(exchanges, 0, fn(bytes, row) {
      bytes + string.byte_size(row.question) + string.byte_size(row.answer)
    })
  use <- bool.guard(
    bytes > 131_072,
    Error("side history exceeds its byte bound"),
  )
  Ok(Board(strand, snapshot, model, status, exchanges, notice))
}

fn value_field(value, name) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, name)
      |> result.map_error(fn(_) { "missing field: " <> name })
    _ -> Error("side board must be an object")
  }
}

fn array(value) {
  case value {
    json.Array(values) -> Ok(values)
    _ -> Error("exchanges must be an array")
  }
}

fn field(value, name) {
  use value <- result.try(value_field(value, name))
  case value {
    json.String(text) -> Ok(text)
    _ -> Error("invalid side board field: " <> name)
  }
}

/// Renders the same plain-text content in terminal and browser panels.
///
/// ## Examples
///
/// ```gleam
/// // btw.lines(state)
/// ```
pub fn lines(state: State) -> List(String) {
  raw_lines(state) |> list.map(text_hygiene.multiline)
}

fn raw_lines(state: State) -> List(String) {
  case state.board {
    None -> [
      "Side question",
      "Use /btw <question>. /btw refresh captures newer context.",
    ]
    Some(board) ->
      list.flatten([
        [
          "Side question · " <> board.status,
          board.model <> " · snapshot " <> board.snapshot,
        ],
        list.flat_map(board.exchanges, fn(row) {
          ["", "You: " <> row.question, "", row.answer]
        }),
        [
          "",
          board.notice,
          "/btw <follow-up> · /btw refresh · /btw cancel · /btw clear · /btw close",
        ],
      ])
  }
}

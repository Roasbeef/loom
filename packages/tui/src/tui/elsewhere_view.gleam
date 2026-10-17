//// `loom sessions elsewhere` and the last section of `loom sessions list`: the
//// sessions the daemon's other orchestrators list, as text
//// (protocol-change/085).
////
//// A session is owned by the orchestrator it was created on, so the picker and
//// `loom sessions list` show one daemon's sessions. The daemon answers
//// `sessions.elsewhere` with a group for each orchestrator it is configured to
//// ask, and this module is the terminal's reading of it. The launcher cannot
//// import the daemon's types, so the document is decoded here with a decoder of
//// its own. Decoding is total: a reply that is not shaped as expected is an
//// `Error` naming the member, a member this decoder does not know is ignored,
//// and every text and list is bounded. Every string the daemon sent is drawn
//// through `text_hygiene.single_line`, which removes control characters, so a
//// damaged reply cannot start a second row.
////
//// ## What a group says
////
//// A group is `answered`, with up to twenty rows and whether more follow, or
//// `silent`. Silent is not empty: the daemon did not hear a page from that
//// orchestrator, and the text says so in one line. An answered group with no
//// rows says that it lists none.
////
//// ## Flow
////
//// `decode` → `section_text` → `group_text`
////
//// 1. `decode` reads the document into the groups, in the order the daemon
////    gave them.
//// 2. `section_text` draws every group under one heading, or says there are no
////    other orchestrators.
//// 3. `group_text` draws one group: its name, node and address, then a row for
////    each session, or the one line that says it was silent. A group with more
////    to show names the command that reads its next page.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene
import tui/placement

/// The longest text the decoder accepts for any member, in bytes.
const text_limit = 4096

/// The most groups and the most rows in a group the decoder accepts.
const list_limit = 128

/// Whether the daemon heard a page from an orchestrator.
pub type Hearing {
  /// A page arrived, possibly with no rows on it.
  Answered

  /// Nothing arrived in time, or the orchestrator could not read its catalogue.
  Silent
}

/// Whether the orchestrator has rows beyond the ones the group shows.
pub type More {
  /// The group shows every row there is.
  Last

  /// Rows follow, and the next page begins after the last one shown.
  Further
}

/// One session another orchestrator lists.
pub type Row {
  Row(
    /// The canonical session identity.
    session_id: String,
    /// The workspace, as that orchestrator names it.
    workspace: String,
    /// The display name.
    name: String,
    /// The lifecycle word: `saved`, `resident`, and so on.
    state: String,
    /// The key of the executor that orchestrator placed the session on, when it
    /// is placed on one.
    executor: Option(String),
  )
}

/// One configured orchestrator and what it said.
pub type Group {
  Group(
    /// The orchestrator's key in the daemon's configuration.
    name: String,
    /// Its node.
    node: String,
    /// Whether it answered.
    hearing: Hearing,
    /// Its control address, when the configuration has one.
    address: Option(String),
    /// Whether rows follow the ones shown.
    more: More,
    /// The rows, in identity order.
    sessions: List(Row),
  )
}

/// Reads a `sessions.elsewhere` reply body. `orchestrators` is required, and
/// within a group `name`, `node`, `state`, `more` and `sessions` are.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = elsewhere_view.decode(json.Object([]))
/// ```
pub fn decode(document: JsonValue) -> Result(List(Group), String) {
  use found <- result.try(field(document, "orchestrators"))
  use items <- result.try(list_of(found, "orchestrators"))
  list.try_map(items, group)
}

fn group(value: JsonValue) -> Result(Group, String) {
  use name <- result.try(text_at(value, "name"))
  use node <- result.try(text_at(value, "node"))
  use state <- result.try(text_at(value, "state"))
  use hearing <- result.try(case state {
    "answered" -> Ok(Answered)
    "silent" -> Ok(Silent)
    other -> Error("state is " <> text_hygiene.single_line(other))
  })
  use more <- result.try(more_at(value))
  use listed <- result.try(field(value, "sessions"))
  use items <- result.try(list_of(listed, "sessions"))
  use sessions <- result.map(list.try_map(items, row))
  Group(
    name:,
    node:,
    hearing:,
    address: option.from_result(text_at(value, "address")),
    more:,
    sessions:,
  )
}

fn row(value: JsonValue) -> Result(Row, String) {
  use session_id <- result.try(text_at(value, "session_id"))
  use workspace <- result.try(label_at(value, "workspace"))
  use name <- result.try(label_at(value, "name"))
  use status <- result.try(field(value, "status"))
  use state <- result.map(text_at(status, "state"))
  Row(
    session_id:,
    workspace:,
    name:,
    state:,
    executor: option.from_result(text_at(value, "executor")),
  )
}

/// The groups as one section of text under a heading, or the sentence that says
/// the daemon has no other orchestrators to ask.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere_view.section_text([]) == "no other orchestrators"
/// ```
pub fn section_text(groups: List(Group)) -> String {
  case groups {
    [] -> "no other orchestrators"
    _ ->
      string.join(
        ["on other orchestrators:", ..list.map(groups, group_text)],
        "\n",
      )
  }
}

/// One group: a line naming the orchestrator, and under it a line for each
/// session or the one line that says it did not answer. A group that has more
/// rows than it shows names the command that reads them.
///
/// ## Examples
///
/// ```gleam
/// // elsewhere_view.group_text(group)
/// ```
pub fn group_text(group: Group) -> String {
  let heading = case group.address {
    Some(address) ->
      clean(group.name) <> "  " <> clean(group.node) <> "  " <> clean(address)
    None -> clean(group.name) <> "  " <> clean(group.node)
  }
  let body = case group.hearing, group.sessions {
    Silent, _ -> ["  no answer"]
    Answered, [] -> ["  no sessions"]
    Answered, rows -> list.map(rows, row_text)
  }
  let next = case group.more, list.last(group.sessions) {
    Further, Ok(last) -> [
      "  more: loom sessions elsewhere --orchestrator "
      <> clean(group.name)
      <> " --after "
      <> clean(last.session_id),
    ]
    Further, Error(Nil) | Last, _ -> []
  }
  string.join([heading, ..list.append(body, next)], "\n")
}

fn row_text(row: Row) -> String {
  "  "
  <> clean(row.session_id)
  <> "  "
  <> clean(row.state)
  <> "  "
  <> placement.label(option.map(row.executor, clean), clean(row.workspace))
  <> "  "
  <> clean(row.name)
}

fn field(value: JsonValue, key: String) -> Result(JsonValue, String) {
  case value {
    json.Object(members) ->
      list.key_find(members, key) |> result.replace_error("missing " <> key)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected an object")
  }
}

fn text_at(value: JsonValue, key: String) -> Result(String, String) {
  use found <- result.try(field(value, key))
  case found {
    json.String(word) if word != "" ->
      case string.byte_size(word) <= text_limit {
        True -> Ok(word)
        False -> Error(key <> " is longer than expected")
      }
    _ -> Error(key <> " is not text")
  }
}

// Text that may be empty, for the two members of a row that a daemon draws from
// what a person typed.
fn label_at(value: JsonValue, key: String) -> Result(String, String) {
  use found <- result.try(field(value, key))
  case found {
    json.String(word) ->
      case string.byte_size(word) <= text_limit {
        True -> Ok(word)
        False -> Error(key <> " is longer than expected")
      }
    _ -> Error(key <> " is not text")
  }
}

fn more_at(value: JsonValue) -> Result(More, String) {
  use found <- result.try(field(value, "more"))
  case found {
    json.Bool(True) -> Ok(Further)
    json.Bool(False) -> Ok(Last)
    _ -> Error("more is not a boolean")
  }
}

fn list_of(value: JsonValue, key: String) -> Result(List(JsonValue), String) {
  case value {
    json.Array(items) ->
      case list.length(items) <= list_limit {
        True -> Ok(items)
        False -> Error(key <> " is longer than expected (" <> bound() <> ")")
      }
    _ -> Error(key <> " is not a list")
  }
}

fn bound() -> String {
  int.to_string(list_limit)
}

fn clean(word: String) -> String {
  text_hygiene.single_line(word)
}

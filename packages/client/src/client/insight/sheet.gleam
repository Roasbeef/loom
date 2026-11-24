//// The label sheet the owner marks, and the reading of the marks back
//// (`docs/design-notes/insight-triage.md`, section 8.3, step 2).
////
//// The owner decides, from the rows alone, which of a session's Insights rows
//// they would open first. The sheet therefore shows a row's kind word and its
//// head and nothing else: no model output, no weight, and no order but newest
//// first. It is a Markdown checklist so the owner can mark it in any editor:
//// a checked box is "open first", and an unchecked box is "fine to skip".
////
//// ## Two files, one numbering
////
//// The sheet numbers each session's rows from one. `rows_json` writes the same
//// numbering beside it, keyed by session id and then by the row's key, so a
//// consumer can map a mark back to the classifier's row without parsing
//// prose. The request numbers its rows the same way (`client/insight/request`),
//// which is what lets a model's answer, a mark and a key meet on one number.
////
//// ## What the sheet may not carry
////
//// A head is session text, so the sheet writes it on one line and never as
//// markup the reader's editor might act on: leading and trailing spaces are
//// cut, a newline cannot occur, and a head that begins with a box of its own
//// is still read by the line's own box first.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp

/// One row of the sheet.
pub type SheetRow {
  SheetRow(
    /// The classifier's key for the row, which only `rows.json` carries.
    key: String,
    /// The kind word the page draws the row with.
    kind: String,
    /// The row's head, untrusted text.
    head: String,
  )
}

/// One session of the sheet.
pub type SheetSession {
  SheetSession(
    /// The session's identity.
    id: String,
    /// The session's name.
    name: String,
    /// When the session's last entry was stored, in Unix milliseconds.
    at: Int,
    /// The rows, newest first.
    rows: List(SheetRow),
  )
}

/// A mark on a row.
pub type Mark {
  /// The box was checked.
  Open

  /// The box was left empty.
  Skip
}

/// The calendar day of a Unix-millisecond time, in UTC, as `YYYY-MM-DD`.
///
/// ## Examples
///
/// ```gleam
/// assert sheet.date_of(0) == "1970-01-01"
/// ```
pub fn date_of(ms: Int) -> String {
  let #(date, _) =
    timestamp.from_unix_seconds(ms / 1000)
    |> timestamp.to_calendar(calendar.utc_offset)

  int.to_string(date.year)
  <> "-"
  <> two_digits(calendar.month_to_int(date.month))
  <> "-"
  <> two_digits(date.day)
}

/// A number padded to two digits.
fn two_digits(number: Int) -> String {
  string.pad_start(int.to_string(number), to: 2, with: "0")
}

/// The sheet the owner marks.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(sheet.render([]), "open first")
/// ```
pub fn render(sessions: List(SheetSession)) -> String {
  let body =
    list.index_map(sessions, fn(session, index) {
      render_session(session, index + 1)
    })

  [instructions, ..body]
  |> string.join("\n")
}

/// What the owner is asked to do.
const instructions =
  "# Which insight rows would you open first?

Each session below lists the rows a reader of its page would see under Insights, newest first. For each row, tick the box if you would open it first. Leave the box empty if it is fine to skip. Decide from the row alone: the kind word and the one-line head are all this sheet shows.

Mark every row, and save the file in place. Rows are numbered within their session, and the numbers matter.
"

/// One session's heading and checklist.
fn render_session(session: SheetSession, number: Int) -> String {
  let heading =
    "## "
    <> int.to_string(number)
    <> ". "
    <> one_line(session.name)
    <> " · "
    <> date_of(session.at)
  let identity = "Session `" <> session.id <> "`\n"
  let rows =
    list.index_map(session.rows, fn(row, index) {
      "- [ ] "
      <> int.to_string(index + 1)
      <> ". "
      <> one_line(row.kind)
      <> " · "
      <> one_line(row.head)
    })

  string.join([heading, identity, ..rows], "\n") <> "\n"
}

/// A text on one line with its ends trimmed.
fn one_line(text: String) -> String {
  string.replace(text, "\n", " ")
  |> string.replace("\r", " ")
  |> string.trim
}

/// The machine-readable twin of the sheet: for each session, each row's key
/// with its number, kind word and head.
///
/// ## Examples
///
/// ```gleam
/// assert sheet.rows_json([]) == "{}"
/// ```
pub fn rows_json(sessions: List(SheetSession)) -> String {
  json.object(
    list.map(sessions, fn(session) {
      #(
        session.id,
        json.object(
          list.index_map(session.rows, fn(row, index) {
            #(
              row.key,
              json.object([
                #("n", json.int(index + 1)),
                #("kind", json.string(row.kind)),
                #("head", json.string(row.head)),
              ]),
            )
          }),
        ),
      )
    }),
  )
  |> json.to_string
}

/// The selection as a file the other commands read: the sessions in order,
/// each with its rows.
///
/// ## Examples
///
/// ```gleam
/// assert sheet.read_selection(sheet.selection_json([])) == Ok([])
/// ```
pub fn selection_json(sessions: List(SheetSession)) -> String {
  json.array(sessions, fn(session) {
    json.object([
      #("id", json.string(session.id)),
      #("name", json.string(session.name)),
      #("at", json.int(session.at)),
      #(
        "rows",
        json.array(session.rows, fn(row) {
          json.object([
            #("key", json.string(row.key)),
            #("kind", json.string(row.kind)),
            #("head", json.string(row.head)),
          ])
        }),
      ),
    ])
  })
  |> json.to_string
}

/// The sessions of a `selection_json` text, in the order they were written.
///
/// ## Examples
///
/// ```gleam
/// assert sheet.read_selection("[]") == Ok([])
/// ```
pub fn read_selection(text: String) -> Result(List(SheetSession), String) {
  let row = {
    use key <- decode.field("key", decode.string)
    use kind <- decode.field("kind", decode.string)
    use head <- decode.field("head", decode.string)
    decode.success(SheetRow(key:, kind:, head:))
  }
  let session = {
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    use at <- decode.field("at", decode.int)
    use rows <- decode.field("rows", decode.list(row))
    decode.success(SheetSession(id:, name:, at:, rows:))
  }

  json.parse(text, decode.list(session))
  |> result.map_error(fn(_) { "the selection file does not hold sessions" })
}

/// How many rows each session of a `rows_json` text numbers.
///
/// ## Examples
///
/// ```gleam
/// assert sheet.row_counts("{\"s\":{\"k\":{\"n\":1,\"kind\":\"Failed\",\"head\":\"h\"}}}")
///   == Ok(dict.from_list([#("s", 1)]))
/// ```
pub fn row_counts(text: String) -> Result(Dict(String, Int), String) {
  let row = decode.field("n", decode.int, fn(_) { decode.success(Nil) })
  let session = decode.dict(decode.string, row)

  json.parse(text, decode.dict(decode.string, session))
  |> result.map(dict.map_values(_, fn(_, rows) { dict.size(rows) }))
  |> result.map_error(fn(_) {
    "rows.json does not hold sessions of numbered rows"
  })
}

/// The marks the owner left on a sheet, by session and row number.
///
/// A session is the one named by the `Session` line under its heading, and a
/// mark belongs to the session above it. A line that is not a heading, a
/// session line or a numbered box is ignored, so an owner's notes in the file
/// cost nothing.
///
/// ## Examples
///
/// ```gleam
/// assert sheet.marks("Session `s`\n- [x] 1. Failed · bash\n- [ ] 2. Result · done")
///   == dict.from_list([#("s", [#(1, sheet.Open), #(2, sheet.Skip)])])
/// ```
pub fn marks(text: String) -> Dict(String, List(#(Int, Mark))) {
  let #(found, _) =
    string.split(text, "\n")
    |> list.fold(#(dict.new(), None), read_mark_line)

  dict.map_values(found, fn(_, marked) { list.reverse(marked) })
}

/// Reads one line of a marked sheet into the marks gathered so far.
fn read_mark_line(
  state: #(Dict(String, List(#(Int, Mark))), option.Option(String)),
  line: String,
) -> #(Dict(String, List(#(Int, Mark))), option.Option(String)) {
  let #(found, current) = state
  let line = string.trim(line)

  // A session line opens a session, a box belongs to the session above it,
  // and any other line is the owner's own and changes nothing.
  case session_line(line), box_line(line), current {
    Ok(id), _, _ -> #(dict.insert(found, id, []), Some(id))
    Error(Nil), Ok(marked), Some(id) -> #(
      dict.upsert(found, id, fn(held) { [marked, ..option.unwrap(held, [])] }),
      current,
    )
    Error(Nil), _, _ -> state
  }
}

/// The session a `Session \`id\`` line names.
fn session_line(line: String) -> Result(String, Nil) {
  case string.starts_with(line, "Session `") && string.ends_with(line, "`") {
    True -> Ok(string.drop_start(line, 9) |> string.drop_end(1))
    False -> Error(Nil)
  }
}

/// The row number and mark of a numbered checkbox line.
fn box_line(line: String) -> Result(#(Int, Mark), Nil) {
  use #(mark, rest) <- result.try(box_prefix(line))
  use #(number, _) <- result.try(string.split_once(rest, "."))
  use row <- result.try(int.parse(number))

  Ok(#(row, mark))
}

/// The mark a checkbox line carries, and what follows its box.
fn box_prefix(line: String) -> Result(#(Mark, String), Nil) {
  case line {
    "- [ ] " <> rest -> Ok(#(Skip, rest))
    "- [x] " <> rest | "- [X] " <> rest -> Ok(#(Open, rest))
    _ -> Error(Nil)
  }
}

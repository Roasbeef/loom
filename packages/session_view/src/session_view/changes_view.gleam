//// Changes from the session's own edits: the files the agent edited and the
//// diff each edit reported, folded into a bounded board.
////
//// This fold reads no worktree. The gateway serves worktree bytes to an Owner
//// binding only and a page is capped at Operator, so the fold of the records
//// is what a page had when the Changes tab was built (owner ruling,
//// 2026-09-29, issue #569). The owner has since ruled that an owner's page and
//// an operator's page also read the workspace's own Git diff
//// (protocol-change/051, the addendum of 2026-10-05), and the web view draws
//// that when it has it. This board is what the tab draws for an observer's page,
//// for a workspace that is not a checkout, and when that read is refused or
//// fails. What a page holds here is the strand's records,
//// and a successful `fs_edit` result carries the `path` it changed and the
//// `diff` of the change as headerless unified hunks. A successful `fs_write`
//// replaces a whole file and reports no diff, but its call's `content`
//// argument is the file's new text and its result names the `path`, so the
//// fold reads that as one hunk in which every line is added. `fold` reads
//// those and nothing else. The board is therefore what the agent wrote, not what is in
//// the tree: it omits a change made outside the session (a shell command, an
//// editor) and keeps an edit the tree has since reverted. A host that shows
//// it says so, with `label`.
////
//// The fold works over the records a host holds, which is a window of the
//// strand and not necessarily all of it, so an edit older than the window is
//// not counted. That is the same limit the transcript itself has.
////
//// Everything here is bounded, because the board is drawn into every
//// viewer's document. A board holds at most `max_files` files, a file at most
//// `max_file_rows` rows, and the board at most `max_rows` rows in all, and a
//// row's text is cut to `max_row_characters` characters. A cut is counted and
//// never silent: the file says how many rows it left out, and the board says
//// how many files. The `+` and `-` totals count every edit's lines, cut or
//// not, so a bound changes what is drawn and never what is reported.
////
//// A row's `Kind` is computed here from the row's first characters and is a
//// closed type, so a host chooses a style from the type and never from the
//// text. The text is session text and is meant to be drawn as a text node.
//// The module is portable: it imports `core`, other `session_view`
//// modules and the standard library, holds no `@external`, and performs no
//// I/O, so the terminal can draw the same board.

import core/json
import core/message
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import session_view/protocol
import session_view/text_hygiene
import session_view/tool_activity

/// The most files a board holds. A further file is counted and not held.
pub const max_files = 24

/// The most rows one file holds.
pub const max_file_rows = 200

/// The most rows the whole board holds, across its files.
pub const max_rows = 600

/// The most characters one row's text keeps. A longer row ends in `…`.
pub const max_row_characters = 240

/// The most characters a path keeps. A longer path keeps its end.
pub const max_path_characters = 160

/// What a diff row is, decided from its first characters.
pub type Kind {
  /// A hunk header, `@@ -9,6 +9,12 @@`.
  Hunk

  /// A line the edit added.
  Added

  /// A line the edit removed.
  Removed

  /// An unchanged line shown for context.
  Context
}

/// How a file's changes came to be, which decides how a host words them.
pub type Origin {
  /// At least one of the changes is an `fs_edit`, whose hunks are real.
  Edited

  /// Every change is an `fs_write`, so the rows are the file's new text,
  /// each line added, and no line is known to have been removed.
  Written
}

/// One line of a diff.
pub type Row {
  Row(
    /// What the line is, which decides how a host styles it.
    kind: Kind,
    /// The line as the edit reported it, marker included, on one line and
    /// free of control characters. Session text.
    text: String,
  )
}

/// One file the session edited.
pub type File {
  File(
    /// The path as the edit named it, cut to `max_path_characters`. Session
    /// text.
    path: String,
    /// Whether the file was edited or only written whole.
    origin: Origin,
    /// Lines the file's edits added, all of them, held or not.
    added: Int,
    /// Lines the file's edits removed, all of them, held or not.
    removed: Int,
    /// The diff rows held, oldest edit first, each edit's hunks in order.
    rows: List(Row),
    /// How many rows the bounds left out of `rows`.
    cut: Int,
  )
}

/// The session's edits, folded.
pub type Board {
  Board(
    /// The files held, in the order the session first edited them.
    files: List(File),
    /// Every file the session edited, held or not.
    file_count: Int,
    /// Lines added across every edit, in every file.
    added: Int,
    /// Lines removed across every edit, in every file.
    removed: Int,
  )
}

/// A board with no edit in it.
///
/// ## Examples
///
/// ```gleam
/// assert changes_view.empty().file_count == 0
/// ```
pub fn empty() -> Board {
  Board(files: [], file_count: 0, added: 0, removed: 0)
}

/// What a host calls the board, so a reader is not led to take it for the
/// state of the tree.
///
/// ## Examples
///
/// ```gleam
/// assert changes_view.label() == "from this session's edits"
/// ```
pub fn label() -> String {
  "from this session's edits"
}

/// The board's one-line total, `2 files · +14 -2`.
///
/// ## Examples
///
/// ```gleam
/// assert changes_view.totals(changes_view.empty()) == "0 files · +0 -0"
/// ```
pub fn totals(board: Board) -> String {
  int.to_string(board.file_count)
  <> case board.file_count {
    1 -> " file"
    _ -> " files"
  }
  <> " · +"
  <> int.to_string(board.added)
  <> " -"
  <> int.to_string(board.removed)
}

/// What a file's line says about its size: `+14 -2` for a file with an edit
/// in it, and `written · 23 lines` for one the session only wrote whole,
/// where a removed count would claim a diff nobody computed.
///
/// ## Examples
///
/// ```gleam
/// // changes_view.counts_words(file) == "+14 -2"
/// ```
pub fn counts_words(file: File) -> String {
  case file.origin {
    Edited ->
      "+" <> int.to_string(file.added) <> " -" <> int.to_string(file.removed)
    Written ->
      "written · "
      <> int.to_string(file.added)
      <> case file.added {
        1 -> " line"
        _ -> " lines"
      }
  }
}

/// Folds a strand's records, newest first, as a branch holds them, into the
/// board of the edits they carry.
///
/// A call counts when its result is in the records, succeeded, and named a
/// path and a diff, or, for `fs_write`, named a path and the call carried the
/// text it wrote. A call whose result is outside the window, a failed edit,
/// and a result with no diff (an older record) add nothing. Two changes of one
/// path are one file, with the second change's rows after the first's.
///
/// ## Examples
///
/// ```gleam
/// assert changes_view.fold([]) == changes_view.empty()
/// ```
pub fn fold(records: List(protocol.EntryRecord)) -> Board {
  let changes =
    records
    |> list.reverse
    |> list.map(fn(record) { record.entry })
    |> tool_activity.calls
    |> list.filter_map(change)
  let #(order, diffs) = group(changes)
  let files =
    list.map(order, fn(path) {
      file(path, result.unwrap(dict.get(diffs, path), []))
    })

  Board(
    files: bound_rows(list.take(files, max_files), max_rows),
    file_count: list.length(files),
    added: list.fold(files, 0, fn(total, file) { total + file.added }),
    removed: list.fold(files, 0, fn(total, file) { total + file.removed }),
  )
}

/// Joins the board of an earlier stretch of a session to the board of a later
/// one, as folding both stretches' records together would have, within the
/// same bounds.
///
/// A host that keeps a summary of each settled turn instead of its records
/// folds each turn's board once, when the turn is closed, and joins them when
/// it draws the page, so the Changes tab still shows the edits of turns whose
/// records the page no longer holds. A path both boards name is one file, with
/// the later rows after the earlier ones. The count of files the later board
/// held and did not list is carried as it was, and so is the earlier one's.
///
/// ## Examples
///
/// ```gleam
/// assert changes_view.append(changes_view.empty(), changes_view.empty())
///   == changes_view.empty()
/// ```
pub fn append(earlier: Board, later: Board) -> Board {
  let #(files, fresh) =
    list.fold(later.files, #(earlier.files, 0), fn(joined, next) {
      let #(files, fresh) = joined
      case list.any(files, fn(file) { file.path == next.path }) {
        True -> #(
          list.map(files, fn(file) {
            case file.path == next.path {
              True -> combined(file, next)
              False -> file
            }
          }),
          fresh,
        )
        False -> #(list.append(files, [next]), fresh + 1)
      }
    })

  Board(
    files: bound_rows(list.take(files, max_files), max_rows),
    file_count: earlier.file_count
      + fresh
      + int.max(0, later.file_count - list.length(later.files)),
    added: earlier.added + later.added,
    removed: earlier.removed + later.removed,
  )
}

// One file's two stretches as one: the counts add, the later rows follow the
// earlier ones within the file's own bound, and what the bound drops is
// counted with what each stretch had already dropped.
fn combined(earlier: File, later: File) -> File {
  let rows = list.append(earlier.rows, later.rows)
  let held = list.take(rows, max_file_rows)
  File(
    path: earlier.path,
    origin: case earlier.origin, later.origin {
      Written, Written -> Written
      Written, Edited | Edited, Written | Edited, Edited -> Edited
    },
    added: earlier.added + later.added,
    removed: earlier.removed + later.removed,
    rows: held,
    cut: earlier.cut + later.cut + list.length(rows) - list.length(held),
  )
}

// One change a call made: its path, the diff lines it stands for and how it
// was made. Only a successful `fs_edit` or `fs_write` is one.
type Change {
  Change(path: String, diff: String, origin: Origin)
}

// One successful `fs_edit` or `fs_write` as a change, or nothing.
fn change(call: tool_activity.Call) -> Result(Change, Nil) {
  case call.invocation.name, call.outcome {
    "fs_edit",
      Some(message.ToolResultMessage(
        is_error: False,
        details: Some(json.Object(fields)),
        ..,
      ))
    -> {
      use path <- result.try(text(fields, "path"))
      use diff <- result.map(text(fields, "diff"))
      Change(path:, diff:, origin: Edited)
    }
    "fs_write",
      Some(message.ToolResultMessage(
        is_error: False,
        details: Some(json.Object(fields)),
        ..,
      ))
    -> {
      use path <- result.try(text(fields, "path"))
      use content <- result.map(written_text(call.invocation.arguments))
      Change(path:, diff: all_added(content), origin: Written)
    }
    _, _ -> Error(Nil)
  }
}

// The text an `fs_write` call carried, from its `content` argument.
fn written_text(arguments: json.JsonValue) -> Result(String, Nil) {
  case arguments {
    json.Object(fields) -> text(fields, "content")
    _ -> Error(Nil)
  }
}

// A whole file's text as one hunk's lines, each added. A final newline ends
// the last line and does not begin another, so it adds no empty row.
fn all_added(content: String) -> String {
  let lines = case list.reverse(string.split(content, "\n")) {
    ["", ..rest] -> list.reverse(rest)
    all -> list.reverse(all)
  }

  lines
  |> list.map(fn(line) { "+" <> line })
  |> string.join("\n")
}

fn text(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, Nil) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

// The paths in the order they were first changed, and each path's changes,
// oldest first.
fn group(changes: List(Change)) -> #(List(String), Dict(String, List(Change))) {
  let #(order, grouped) =
    list.fold(changes, #([], dict.new()), fn(seen, change) {
      let #(order, grouped) = seen

      case dict.get(grouped, change.path) {
        Ok(earlier) -> #(
          order,
          dict.insert(grouped, change.path, [change, ..earlier]),
        )
        Error(Nil) -> #(
          [change.path, ..order],
          dict.insert(grouped, change.path, [change]),
        )
      }
    })

  #(
    list.reverse(order),
    dict.map_values(grouped, fn(_, later) { list.reverse(later) }),
  )
}

// One file: every change's raw lines, classified and counted whole, and only
// the rows the file's bound keeps go through text hygiene. A diff can be as
// large as a record is, and this runs each time the page projects, so nothing
// proportional to the diff is done to a row that is not kept.
fn file(path: String, changes: List(Change)) -> File {
  let lines =
    list.flat_map(changes, fn(change) { string.split(change.diff, "\n") })
  let #(added, removed) = counts(lines)
  let origin = case list.all(changes, fn(change) { change.origin == Written }) {
    True -> Written
    False -> Edited
  }

  File(
    path: text_hygiene.fit_tail(
      text_hygiene.single_line(path),
      max_path_characters,
    ),
    added:,
    removed:,
    origin:,
    rows: lines |> list.take(max_file_rows) |> list.map(clipped),
    cut: int.max(0, list.length(lines) - max_file_rows),
  )
}

// A line's kind, from its first characters. A line that begins `+++` or
// `---` is an added or removed line like any other: the hunks are headerless,
// so no file header can be mistaken for one.
fn kind(line: String) -> Kind {
  case string.starts_with(line, "@@"), string.first(line) {
    True, _ -> Hunk
    False, Ok("+") -> Added
    False, Ok("-") -> Removed
    False, Ok(_) | False, Error(Nil) -> Context
  }
}

fn counts(lines: List(String)) -> #(Int, Int) {
  list.fold(lines, #(0, 0), fn(total, line) {
    case kind(line) {
      Added -> #(total.0 + 1, total.1)
      Removed -> #(total.0, total.1 + 1)
      Hunk | Context -> total
    }
  })
}

// A kept line as a row, its text cut to `max_row_characters` code points.
// Code points and not graphemes, because one base character with many
// combining marks is a single grapheme: the cut bounds the row's bytes at four
// times the limit whatever the line holds.
fn clipped(line: String) -> Row {
  let points = string.to_utf_codepoints(line)
  let text = case list.drop(points, max_row_characters) {
    [] -> line
    [_, ..] ->
      string.from_utf_codepoints(list.take(points, max_row_characters - 1))
      <> "…"
  }

  Row(kind(line), text_hygiene.single_line(text))
}

// Cuts the files' rows so that all of them together fit `budget`, taking
// from the first file on, and records what each file lost.
fn bound_rows(files: List(File), budget: Int) -> List(File) {
  case files {
    [] -> []
    [first, ..rest] -> {
      let held = list.take(first.rows, budget)
      let lost = list.length(first.rows) - list.length(held)

      [
        File(..first, rows: held, cut: first.cut + lost),
        ..bound_rows(rest, budget - list.length(held))
      ]
    }
  }
}

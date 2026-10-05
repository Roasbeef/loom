//// What `<loom-switcher>` decides: which key opens the session switcher, which
//// sessions a typed query lists, and where the highlight moves.
////
//// The switcher lists the sessions the page already draws in its sidebar, and
//// the page's own way home or to the admin page when the bar draws one. It
//// opens a row by pressing that row's own button, so the switch goes
//// through the ticket mint every other switch uses and nothing here names a
//// session or a page to the server. The element reads each row's name, workspace and
//// subtitle from the text the server rendered and hands them to this module as
//// plain strings, and this module only compares them. It never builds markup,
//// and the element draws the result as text nodes (protocol-change/051, the
//// addendum on the session switcher).
////
//// The module imports neither Lustre nor the DOM binding, so the tests load it
//// under Node (`scripts/web_client_test.sh` checks that).

import gleam/int
import gleam/list
import gleam/string

/// What a row opens: a session that is running or only saved, which the row
/// says beside the workspace so two rows with one name can be told apart, or
/// one of the principal's own pages.
pub type Kind {
  /// A process runs the session.
  Running

  /// The session is on disk and a press resumes it.
  Saved

  /// A page of the app that is not a session: the home or the admin page.
  /// Its row says what the page is for, and no workspace.
  Place
}

/// One session the sidebar offers, as the server drew it.
pub type Row {
  Row(
    /// The session's display name, or the fallback the page gives an unnamed
    /// one.
    name: String,
    /// The last segment of the session's workspace path.
    workspace: String,
    /// The first prompt's first line, or empty.
    subtitle: String,
    /// Whether a process runs it.
    kind: Kind,
  )
}

/// A row that matches the query, with its place among all the rows, which is
/// how the element finds the button to press.
pub type Match {
  Match(index: Int, row: Row)
}

/// What a key pressed in the query field does.
pub type Intent {
  /// Move the highlight to the row above.
  Up

  /// Move the highlight to the row below.
  Down

  /// Open the highlighted row.
  Choose

  /// Leave the key to the browser: it is a letter being typed, or a key the
  /// field has no use for.
  Pass
}

/// The modifier keys held with a key press, reduced to what the switcher asks.
pub type Chord {
  /// Command or Control, with neither Shift nor Alt: the chord of a shortcut.
  Primary

  /// No modifier at all.
  Bare

  /// Any other combination, which belongs to the browser.
  Other
}

/// Whether the browser's input method is composing text. A key it consumes is
/// the method's, not the list's.
pub type Phase {
  /// An input method has a candidate open.
  Composing

  /// Ordinary typing.
  Typing
}

/// Whether a key press is the shortcut that opens the switcher: `k` with
/// Command or Control, and neither Shift nor Alt.
///
/// ## Examples
///
/// ```gleam
/// assert switcher_rule.shortcut("k", switcher_rule.Primary)
/// assert !switcher_rule.shortcut("k", switcher_rule.Bare)
/// ```
pub fn shortcut(key: String, chord: Chord) -> Bool {
  case chord {
    Primary -> string.lowercase(key) == "k"
    Bare | Other -> False
  }
}

/// What a key pressed in the query field does. A key held down repeats, which
/// is wanted for the arrows, and a key that composes text (an input method's
/// candidate being confirmed with Enter) is the method's, not the list's.
///
/// ## Examples
///
/// ```gleam
/// assert switcher_rule.intent("ArrowDown", switcher_rule.Typing)
///   == switcher_rule.Down
/// assert switcher_rule.intent("Enter", switcher_rule.Composing)
///   == switcher_rule.Pass
/// ```
pub fn intent(key: String, phase: Phase) -> Intent {
  case phase, key {
    Composing, _ -> Pass
    Typing, "ArrowUp" -> Up
    Typing, "ArrowDown" -> Down
    Typing, "Enter" -> Choose
    Typing, _ -> Pass
  }
}

/// The attribute the page's own switcher chip carries, and the value that says
/// what pressing it opens. The chip is drawn by `<loom-shell>`, which cannot
/// reach the switcher's element, so the switcher recognises a press on it from
/// the attribute alone.
pub const summon_attribute = "data-opens"

/// The value of `summon_attribute` on the chip that opens the switcher.
pub const summon_value = "switcher"

/// Whether an element on a click's path is the chip that opens the switcher,
/// given the value of its `summon_attribute` or nothing when it has none.
///
/// ## Examples
///
/// ```gleam
/// assert switcher_rule.summons(Ok("switcher"))
/// assert !switcher_rule.summons(Ok("elsewhere"))
/// assert !switcher_rule.summons(Error(Nil))
/// ```
pub fn summons(value: Result(String, Nil)) -> Bool {
  value == Ok(summon_value)
}

/// The quiet words after a row's name: where it runs, what it began as, and
/// that it is only saved. A page of the app has no workspace and is never
/// saved, so its row says only what it is for.
///
/// ## Examples
///
/// ```gleam
/// let row = switcher_rule.Row("docs", "loom", "Fix the test", switcher_rule.Saved)
/// assert switcher_rule.detail(row) == "loom · Fix the test · saved"
/// ```
pub fn detail(row: Row) -> String {
  let parts = [
    row.workspace,
    row.subtitle,
    case row.kind {
      Saved -> "saved"
      Running | Place -> ""
    },
  ]
  list.filter(parts, fn(part) { part != "" }) |> string.join(" · ")
}

/// The last segment of a workspace path, which is what a row says of where the
/// session runs. A path with no segment is returned as it is.
///
/// ## Examples
///
/// ```gleam
/// assert switcher_rule.workspace_label("/home/ada/src/loom") == "loom"
/// ```
pub fn workspace_label(path: String) -> String {
  let segments =
    string.split(path, "/")
    |> list.filter(fn(segment) { segment != "" })
  case list.last(segments) {
    Ok(last) -> last
    Error(Nil) -> path
  }
}

/// The rows a query lists, in the sidebar's order, rows that match in their
/// name before rows that match only in their workspace or subtitle. A query is
/// split on spaces and every word must appear, in any case, in the row's name,
/// workspace and subtitle taken together. An empty query lists every row.
///
/// ## Examples
///
/// ```gleam
/// // switcher_rule.matching(rows, "auth")
/// ```
pub fn matching(rows: List(Row), query: String) -> List(Match) {
  let words =
    string.lowercase(query)
    |> string.split(" ")
    |> list.filter(fn(word) { word != "" })
  let all = list.index_map(rows, fn(row, index) { Match(index:, row:) })
  let #(named, other) =
    list.filter(all, fn(match) {
      contains_all(words, string.lowercase(whole(match.row)))
    })
    |> list.partition(fn(match) {
      contains_all(words, string.lowercase(match.row.name))
    })
  list.append(named, other)
}

// The text a query is compared with: everything the row says.
fn whole(row: Row) -> String {
  row.name <> " " <> row.workspace <> " " <> row.subtitle
}

fn contains_all(words: List(String), text: String) -> Bool {
  list.all(words, fn(word) { string.contains(text, word) })
}

/// The highlight after an arrow key: it wraps at either end, and a list with
/// no rows holds it at the top.
///
/// ## Examples
///
/// ```gleam
/// assert switcher_rule.moved(2, switcher_rule.Down, 3) == 0
/// assert switcher_rule.moved(0, switcher_rule.Up, 3) == 2
/// ```
pub fn moved(selected: Int, direction: Intent, count: Int) -> Int {
  case count <= 0, direction {
    True, _ -> 0
    False, Down -> { selected + 1 } % count
    False, Up -> { selected - 1 + count } % count
    False, Choose | False, Pass -> kept(selected, count)
  }
}

/// The highlight held inside a list of `count` rows, which a query that
/// shortened the list needs.
///
/// ## Examples
///
/// ```gleam
/// assert switcher_rule.kept(5, 2) == 1
/// ```
pub fn kept(selected: Int, count: Int) -> Int {
  int.max(0, int.min(selected, count - 1))
}

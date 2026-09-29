//// The slash commands the operator's composer offers as the draft is typed.
////
//// The terminal completes commands from `session_view/command.suggestions`,
//// and the page offers the same names with the same hints, less the commands
//// it does not run. The editor's text lives in the browser until it is
//// submitted, so the narrowing as the draft grows happens in the client
//// (`web_client/composer`), which needs the whole table once. This module
//// builds that table from the terminal's own and hands it over as one JSON
//// string, which the composer's element carries as an attribute.
////
//// Nothing in the table comes from the session. Every row is a command name
//// and a hint written in `session_view`, and the page's own refusal
//// (`component.page_command`) decides which rows are left out, so the list
//// never offers what pressing Send would refuse. The page loads no skills
//// catalogue, so a skill's command is not offered either, as it is not run.
////
//// The table is the terminal's in two parts: the one-word commands, and the
//// rows that complete a command's argument once its space is typed
//// (`/effort low`, `/goal check`). The second part is found rather than
//// listed here: a word whose text plus a space still has suggestions of its
//// own has an argument vocabulary, so a vocabulary the terminal gains is
//// offered on the page without a change here.

import core/json
import gleam/list
import gleam/result
import gleam/string
import session_view/command
import web_view/component

/// Every row the composer offers: the terminal's one-word commands and its
/// argument rows, without the ones the page does not run, in the terminal's
/// order.
///
/// ## Examples
///
/// ```gleam
/// assert list.any(completion.rows(), fn(row) { row.command == "/compact" })
/// assert !list.any(completion.rows(), fn(row) { row.command == "/models" })
/// ```
pub fn rows() -> List(command.Suggestion) {
  let words = command.suggestions("/")

  // A word with a closed vocabulary answers with rows of its own once its
  // space is typed. Every other word answers with itself, which is a word
  // already in the list, so only the rows with a space are new.
  let arguments =
    list.flat_map(words, fn(word) { command.suggestions(word.command <> " ") })
    |> list.filter(fn(row) { string.contains(row.command, " ") })
  list.filter(list.append(words, arguments), runs)
}

// Whether pressing Send on the row's command would run it here. A row that
// takes an argument is parsed with one, since the command alone is
// incomplete and parses as the usage message, which is not the command it
// names.
fn runs(row: command.Suggestion) -> Bool {
  let draft = case row.takes_argument {
    True -> row.command <> " x"
    False -> row.command
  }
  result.is_ok(component.page_command(command.parse(draft)))
}

/// The table as the composer's `commands` attribute holds it: an array of
/// objects `c` (the command), `d` (its hint) and `a` (whether an argument
/// follows).
///
/// ## Examples
///
/// ```gleam
/// // completion.table() == "[{\"c\":\"/abort\",\"d\":\"abort the live operation\",\"a\":false}, ..]"
/// ```
pub fn table() -> String {
  json.to_string(
    json.Array(
      list.map(rows(), fn(row) {
        json.Object([
          #("c", json.String(row.command)),
          #("d", json.String(row.description)),
          #("a", json.Bool(row.takes_argument)),
        ])
      }),
    ),
  )
}

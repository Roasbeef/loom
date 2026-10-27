//// The slash commands the operator's composer offers as the draft is typed.
////
//// The terminal completes commands from `session_view/command.suggestions`,
//// and the page offers the same names with the same hints, less the commands
//// it does not run. The editor's text lives in the browser until it is
//// submitted, so the narrowing as the draft grows happens in the client
//// (`web_client/composer`), which needs the whole table once. This module
//// builds the static command rows and adds the daemon's configured model and
//// profile names. The resulting JSON travels as escaped child text in the
//// composer's `commands` slot, so catalogue names never enter attributes.
//// The page's refusal (`component.page_command`) filters commands it cannot
//// run. `/model` is offered as an argument-taking head because its selected
//// argument runs a session command rather than a terminal selector.
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

  // A word that has argument rows is a head the operator can continue from,
  // whether or not the terminal runs it alone. The terminal's `/goal` is a
  // whole command that shows the goal's status, which the page does not run,
  // so without this the word would be filtered out and no row would lead to
  // `/goal check`. The head keeps the terminal's name and hint and is marked
  // as taking an argument, so choosing it leaves `/goal ` in the editor with
  // the argument rows listed.
  let heads =
    list.filter_map(arguments, fn(row) {
      string.split_once(row.command, " ") |> result.map(fn(split) { split.0 })
    })
  let words =
    list.map(words, fn(word) {
      case list.contains(heads, word.command) || word.command == "/model" {
        True -> command.Suggestion(..word, takes_argument: True)
        False -> word
      }
    })
  list.filter(list.append(words, arguments), runs)
}

/// Whether pressing Send on the row's command would run it here. A row that
/// takes an argument is parsed with one, since the command alone is
/// incomplete and parses as the usage message, which is not the command it
/// names.
fn runs(row: command.Suggestion) -> Bool {
  // Provide a dummy argument when the suggested command expects one.
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
  table_with([], [])
}

/// Completes model and profile arguments with the daemon's catalogue names.
/// The result travels as escaped child text, never as an HTML attribute.
///
/// ## Examples
///
/// ```gleam
/// // completion.table_with(["sonnet"], ["coding"])
/// ```
@internal
pub fn table_with(models: List(String), profiles: List(String)) -> String {
  let choices =
    list.append(
      list.map(models, fn(name) {
        command.Suggestion("/model " <> name, "switch the strand model", False)
      }),
      list.flat_map(profiles, fn(name) {
        list.map(["/profile", "/model-profile"], fn(head) {
          command.Suggestion(
            head <> " " <> name,
            "switch the session profile",
            False,
          )
        })
      }),
    )
  json.to_string(
    json.Array(
      list.map(list.append(rows(), choices), fn(row) {
        json.Object([
          #("c", json.String(row.command)),
          #("d", json.String(row.description)),
          #("a", json.Bool(row.takes_argument)),
        ])
      }),
    ),
  )
}

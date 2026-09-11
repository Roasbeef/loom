//// Shares daemon-owned skill documents across metadata reads and user input.
////
//// Only the leading text block can select a skill. Expansion precedes queue
//// admission, so held input retains the exact body and author it was given.
//// Metadata pages fit below the transport frame bound without exporting bodies.

import client/daemon/transfer
import core/json
import core/message
import gleam/bool
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import host/skill

/// Returns one byte-bounded page of commands and the next offset, if any.
///
/// ## Examples
///
/// ```gleam
/// // skills.page(catalogue, 0)
/// ```
pub fn page(
  catalogue: skill.Catalogue,
  offset: Int,
) -> Result(json.JsonValue, String) {
  let visible =
    skill.entries(catalogue)
    |> list.filter(fn(entry) { entry.user_invocation == skill.UserInvocable })
  let total = list.length(visible)
  use <- bool.guard(
    offset < 0 || offset > total,
    Error("invalid skills offset"),
  )
  let remaining = list.drop(visible, offset)
  let rows = page_rows(remaining, [])
  let next = offset + list.length(rows)
  Ok(
    json.Object([
      #("offset", json.Int(offset)),
      #("skills", json.Array(rows)),
      #("next", case next < total {
        True -> json.Int(next)
        False -> json.Null
      }),
    ]),
  )
}

fn page_rows(
  remaining: List(skill.Skill),
  rows: List(json.JsonValue),
) -> List(json.JsonValue) {
  case remaining {
    [] -> rows
    [entry, ..rest] -> {
      let row =
        json.Object([
          #("name", json.String(entry.name)),
          #("description", json.String(entry.description)),
          #("argument_hint", json.String(entry.argument_hint)),
        ])
      let candidate = list.append(rows, [row])
      case transfer.encoded_size(json.Array(candidate), 48_000) {
        Ok(_) -> page_rows(rest, candidate)
        Error(_) -> rows
      }
    }
  }
}

/// Expands a leading slash skill while preserving all other content and origin.
///
/// Unknown slash text stays ordinary input for clients with their own command
/// language. A known hidden skill is refused rather than silently invoked.
///
/// ## Examples
///
/// ```gleam
/// // skills.expand_message(catalogue, user_message)
/// ```
pub fn expand_message(
  catalogue: skill.Catalogue,
  input: message.AgentMessage,
) -> Result(message.AgentMessage, String) {
  case input {
    message.UserMessage(content: [message.UserText(text:, ..), ..rest], ..) as user -> {
      use expanded <- result.try(expand_text(catalogue, text))
      case expanded == text {
        True -> Ok(input)
        False ->
          Ok(
            message.UserMessage(..user, content: [
              message.UserText(expanded, None),
              ..rest
            ]),
          )
      }
    }
    other -> Ok(other)
  }
}

fn expand_text(
  catalogue: skill.Catalogue,
  text: String,
) -> Result(String, String) {
  case string.trim_start(text) {
    "/" <> command -> {
      let #(name, arguments) = case string.split_once(command, " ") {
        Ok(#(name, arguments)) -> #(string.trim_end(name), arguments)

        // The terminal trims a command-only paste before classification.
        // Both branches trim the selected name; supplied arguments remain
        // verbatim, including their trailing newline or tab.
        Error(Nil) -> #(string.trim_end(command), "")
      }
      case skill.lookup(catalogue, name) {
        Error(_) -> Ok(text)
        Ok(entry) ->
          case entry.user_invocation {
            skill.UserInvocable -> skill.expand(entry, arguments)
            skill.HiddenFromCommands ->
              Error("skill is not user-invocable: " <> name)
          }
      }
    }
    _ -> Ok(text)
  }
}

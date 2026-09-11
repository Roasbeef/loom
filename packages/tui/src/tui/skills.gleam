//// Decodes daemon-owned skill metadata for command completion.
////
//// The client never discovers local files for a remote session. A catalogue
//// page carries display metadata only; the daemon expands the selected body.

import core/json
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tui/command
import tui/text_hygiene

/// A contiguous page with an optional next cursor.
pub type Page {
  Page(
    /// The index of the first returned row.
    offset: Int,
    /// Commands advertised by the attached daemon.
    commands: List(command.Suggestion),
    /// The next index, absent once discovery is complete.
    next: Option(Int),
  )
}

/// Decodes a page and refuses cursors that cannot make bounded progress.
///
/// ## Examples
///
/// ```gleam
/// assert skills.decode(json.Null) == Error("skills page must be an object")
/// ```
pub fn decode(value: json.JsonValue) -> Result(Page, String) {
  use fields <- result.try(fields(value))
  use offset <- result.try(required(fields, "offset"))
  use rows <- result.try(required(fields, "skills"))
  use next <- result.try(required(fields, "next"))
  use offset <- result.try(case offset {
    json.Int(value) if value >= 0 && value <= 1024 -> Ok(value)
    _ -> Error("invalid skills offset")
  })
  use commands <- result.try(case rows {
    json.Array(rows) -> {
      use <- bool.guard(
        list.drop(rows, 1024) != [],
        Error("too many skills rows"),
      )
      list.try_map(rows, row)
    }
    _ -> Error("invalid skills rows")
  })
  let end = offset + list.length(commands)
  use <- bool.guard(end > 1024, Error("skills catalogue exceeds its bound"))
  use next <- result.try(case next {
    json.Null -> Ok(None)
    json.Int(value) if value == end && value > offset -> Ok(Some(value))
    _ -> Error("invalid skills next cursor")
  })
  Ok(Page(offset:, commands:, next:))
}

fn fields(
  value: json.JsonValue,
) -> Result(List(#(String, json.JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("skills page must be an object")
  }
}

fn required(
  fields: List(#(String, json.JsonValue)),
  key: String,
) -> Result(json.JsonValue, String) {
  list.key_find(fields, key)
  |> result.map_error(fn(_) { "missing skill metadata: " <> key })
}

fn text(
  fields: List(#(String, json.JsonValue)),
  key: String,
) -> Result(String, String) {
  use value <- result.try(required(fields, key))
  case value {
    json.String(value) -> Ok(value)
    _ -> Error("skill metadata must be text: " <> key)
  }
}

fn row(value: json.JsonValue) -> Result(command.Suggestion, String) {
  use fields <- result.try(fields(value))
  use name <- result.try(text(fields, "name"))
  use description <- result.try(text(fields, "description"))
  use hint <- result.try(text(fields, "argument_hint"))
  let description = case hint {
    "" -> description
    _ -> hint <> " — " <> description
  }
  Ok(command.Suggestion(
    "/" <> name,
    text_hygiene.single_line(description),
    True,
  ))
}

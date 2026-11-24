//// A project's settings and the daemon's proposals for them: the replies to
//// `projects.settings` and `projects.propose`, decoded totally, and the words
//// both hosts use for them (protocol-change/106, "Settings held per project").
////
//// The terminal's `loom project settings` and the web view's settings page
//// draw from the same decoders, so a key's value and the word for where it
//// came from cannot differ between them. The rules are those of the board's
//// decoders. A field that is absent is unknown and is never zero, a source
//// this client does not know is kept as text, and every string is external
//// text, passed once through `text_hygiene`: a command in a project's check
//// came from a person, and a proposal's `because` from the daemon, but a host
//// draws neither as anything but text.
////
//// ## Flow
////
//// `decode_settings` → `lines` → `value_text`

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene

/// Where a value came from, in the daemon's spelling.
pub type Source {
  /// The project holds the value itself.
  FromProject

  /// The `[project]` table sets it.
  FromFile

  /// Nobody set it, so the built-in default applies.
  FromDefault

  /// A source a newer daemon sent, kept as text.
  UnknownSource(word: String)
}

/// One key of a project's settings.
pub type Setting {
  Setting(
    /// The key, such as `check`.
    key: String,
    /// The words of the value in force. A check nobody set has none.
    value: List(String),
    /// Where the value came from.
    source: Source,
    /// Who last changed the project's own value, when anyone did.
    changed_by: Option(String),
    /// When, in milliseconds since the epoch, when anyone did.
    changed_ms: Option(Int),
  )
}

/// A project's settings as `projects.settings` replied.
pub type Settings {
  Settings(
    /// The project's id.
    project: String,
    /// The revision a write must echo.
    revision: Int,
    /// The URL that publishing would send to, when the project has a remote.
    publish_url: Option(String),
    /// The five keys, in the daemon's order.
    settings: List(Setting),
  )
}

/// A command the daemon proposes, with why.
pub type Suggestion {
  Suggestion(
    /// The command. It is the daemon's own fixed string.
    command: String,
    /// Where it came from, in the daemon's words.
    because: String,
  )
}

/// What `projects.propose` replied.
pub type Proposed {
  Proposed(
    /// The proposed check, or none.
    check: Option(Suggestion),
    /// The proposed setup, or none.
    setup: Option(Suggestion),
    /// Marker files that were present and not read.
    notes: List(String),
  )
}

/// Decodes a `projects.settings` or `projects.set_settings` body.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings_view.decode_settings(json.Null) |> result.is_error
/// ```
pub fn decode_settings(value: JsonValue) -> Result(Settings, String) {
  case value {
    json.Object(fields) -> settings_of(fields)
    _ -> Error("the settings were not an object")
  }
}

/// Decodes a `projects.propose` body.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings_view.decode_proposed(json.Null) |> result.is_error
/// ```
pub fn decode_proposed(value: JsonValue) -> Result(Proposed, String) {
  case value {
    json.Object(fields) ->
      Ok(
        Proposed(
          check: suggestion_in(fields, "check"),
          setup: suggestion_in(fields, "setup"),
          notes: case list.key_find(fields, "notes") {
            Ok(json.Array(items)) ->
              list.filter_map(items, fn(item) {
                case item {
                  json.String(text) -> Ok(text_hygiene.single_line(text))
                  _ -> Error(Nil)
                }
              })
            _ -> []
          },
        ),
      )
    _ -> Error("the proposal was not an object")
  }
}

/// The settings of a reply object. A reply with no project, no revision or no
/// rows is not settings, because a write needs the revision and a page needs
/// the rows, and neither is guessed.
fn settings_of(fields: List(#(String, JsonValue))) -> Result(Settings, String) {
  use project <- result.try(
    text_in(fields, "project")
    |> option.to_result("the settings named no project"),
  )
  use revision <- result.try(
    int_in(fields, "revision")
    |> option.to_result("the settings carried no revision"),
  )
  use rows <- result.map(rows_of(fields))
  Settings(
    project: text_hygiene.single_line(project),
    revision:,
    publish_url: text_in(fields, "publish_url")
      |> option.map(text_hygiene.single_line),
    settings: list.filter_map(rows, setting_of),
  )
}

/// The rows of the `settings` array.
fn rows_of(
  fields: List(#(String, JsonValue)),
) -> Result(List(JsonValue), String) {
  // Only an array carries rows.
  case list.key_find(fields, "settings") {
    Ok(json.Array(rows)) -> Ok(rows)
    _ -> Error("the settings carried no keys")
  }
}

/// One key's row, or nothing for a row with no usable key.
fn setting_of(row: JsonValue) -> Result(Setting, Nil) {
  // A row is an object, and it needs a key to be addressed.
  case row {
    json.Object(fields) -> {
      use key <- result.map(option.to_result(text_in(fields, "key"), Nil))
      Setting(
        key: text_hygiene.single_line(key),
        value: case list.key_find(fields, "value") {
          Ok(json.Array(items)) ->
            list.filter_map(items, fn(item) {
              case item {
                json.String(text) -> Ok(text_hygiene.single_line(text))
                _ -> Error(Nil)
              }
            })
          _ -> []
        },
        source: case text_in(fields, "source") {
          Some("project") -> FromProject
          Some("file") -> FromFile
          Some("default") -> FromDefault
          Some(other) -> UnknownSource(text_hygiene.single_line(other))
          None -> UnknownSource("")
        },
        changed_by: text_in(fields, "changed_by")
          |> option.map(text_hygiene.single_line),
        changed_ms: int_in(fields, "changed_ms"),
      )
    }
    _ -> Error(Nil)
  }
}

/// A proposal field: an object with a command, or none.
fn suggestion_in(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Option(Suggestion) {
  case list.key_find(fields, key) {
    Ok(json.Object(inner)) ->
      case text_in(inner, "command") {
        Some(command) ->
          Some(Suggestion(
            command: text_hygiene.single_line(command),
            because: text_in(inner, "because")
              |> option.map(text_hygiene.single_line)
              |> option.unwrap(""),
          ))
        None -> None
      }
    _ -> None
  }
}

/// The word for a source.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings_view.source_words(project_settings_view.FromFile) == "from loom.toml"
/// ```
pub fn source_words(source: Source) -> String {
  case source {
    FromProject -> "set for this project"
    FromFile -> "from loom.toml"
    FromDefault -> "the default"
    UnknownSource(word) -> "from " <> word
  }
}

/// A setting's value on one line: the words joined by a comma and a space, and
/// `none` for a key with no words.
///
/// ## Examples
///
/// ```gleam
/// let setting = project_settings_view.Setting("check", ["make check"], project_settings_view.FromProject, None, None)
/// assert project_settings_view.value_text(setting) == "make check"
/// ```
pub fn value_text(setting: Setting) -> String {
  case setting.value {
    [] -> "none"
    words -> string.join(words, ", ")
  }
}

/// The lines a terminal prints for the settings: one for each key, with its
/// value and where it came from, and the revision and publish URL last.
///
/// ## Examples
///
/// ```gleam
/// // project_settings_view.lines(settings)
/// ```
pub fn lines(settings: Settings) -> List(String) {
  let rows =
    list.map(settings.settings, fn(setting) {
      setting.key
      <> " = "
      <> value_text(setting)
      <> "  ("
      <> source_words(setting.source)
      <> changed_words(setting)
      <> ")"
    })
  list.append(rows, [
    publish_words(settings.publish_url),
    "revision " <> int.to_string(settings.revision),
  ])
}

/// The line that says where publishing would go.
fn publish_words(url: Option(String)) -> String {
  // A project with no remote has nowhere to publish.
  case url {
    Some(found) -> "publish would go to " <> found
    None -> "this project has no remote to publish to"
  }
}

fn changed_words(setting: Setting) -> String {
  case setting.changed_by, setting.changed_ms {
    Some(who), Some(at) -> ", changed by " <> who <> " at " <> int.to_string(at)
    _, _ -> ""
  }
}

/// The lines a terminal prints for a proposal: one for each key, and the notes.
///
/// ## Examples
///
/// ```gleam
/// let none = project_settings_view.Proposed(None, None, [])
/// assert project_settings_view.proposal_lines(none) != []
/// ```
pub fn proposal_lines(proposed: Proposed) -> List(String) {
  list.flatten([
    [suggestion_line("check", proposed.check)],
    [suggestion_line("setup", proposed.setup)],
    list.map(proposed.notes, fn(note) { "note: " <> note }),
  ])
}

/// One key's line of a proposal: the command and why, or that nothing
/// suggested one.
fn suggestion_line(key: String, found: Option(Suggestion)) -> String {
  // Only a key the daemon proposed for has a command to show.
  case found {
    Some(suggestion) ->
      key <> " = " <> suggestion.command <> "  (" <> suggestion.because <> ")"
    None -> key <> ": nothing in this repository suggests one"
  }
}

fn text_in(fields: List(#(String, JsonValue)), key: String) -> Option(String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Some(text)
    _ -> None
  }
}

fn int_in(fields: List(#(String, JsonValue)), key: String) -> Option(Int) {
  case list.key_find(fields, key) {
    Ok(json.Int(number)) -> Some(number)
    _ -> None
  }
}

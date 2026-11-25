//// The `[jev]` table: how the daemon reaches the Jev service
//// (docs/design-notes/project-jev-routing.md, section 10).
////
//// The keys sit in their own table, and not in `[project]`, because they
//// describe the service and a second caller of it would share them. The
//// origin the key is sent to is not a key: it is fixed in `jevelin`, so a
//// mistaken or hostile file cannot point a bearer key at another host.
////
//// The daemon reads the table once, when it starts. An unknown key is refused
//// by name, as `[project]` refuses one, so a misspelt `timeout_ms` does not
//// leave the default in force without a word.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import jevelin
import project/jev
import tom

/// The service's settings.
pub type Settings {
  Settings(
    /// The environment variable the key is read from, once, when the daemon
    /// starts. The key itself is never a file value.
    api_key_env: String,
    /// The model or alias sent with each request. A version id keeps a
    /// verdict stable across Jev's releases.
    model: String,
    /// The bound on one request, in milliseconds.
    timeout_ms: Int,
  )
}

/// The least a request may be bounded to, in milliseconds.
pub const min_timeout_ms = 500

/// The most a request may be bounded to, in milliseconds.
pub const max_timeout_ms = 30_000

/// The settings of a daemon whose file has no `[jev]` table.
///
/// ## Examples
///
/// ```gleam
/// assert jev_settings.defaults.timeout_ms == 3000
/// ```
pub const defaults =
  Settings(api_key_env: "JEV_API_KEY", model: jevelin.latest, timeout_ms: 3000)

/// Validates the `[jev]` table of a parsed configuration document.
///
/// ## Examples
///
/// ```gleam
/// assert jev_settings.from_document(dict.new()) == Ok(jev_settings.defaults)
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(Settings, String) {
  case dict.get(document, "jev") {
    Error(Nil) -> Ok(defaults)
    Ok(tom.Table(fields)) -> from_fields(fields)
    Ok(_) -> Error("jev must be a [jev] table")
  }
}

/// Reads the table. An unknown key is refused by name, since the daemon holds a
/// secret's variable name here and a misspelling would otherwise go unread.
fn from_fields(fields: Dict(String, tom.Toml)) -> Result(Settings, String) {
  use _ <- result.try(
    list.try_map(dict.keys(fields), fn(key) {
      case key {
        "api_key_env" | "model" | "timeout_ms" -> Ok(Nil)
        _ -> Error("unknown key `" <> key <> "` in [jev]")
      }
    }),
  )
  use api_key_env <- result.try(text(
    fields,
    "api_key_env",
    defaults.api_key_env,
    variable_name,
  ))
  use model <- result.try(text(fields, "model", defaults.model, jev.valid_model))
  use timeout_ms <- result.map(timeout(fields))
  Settings(api_key_env:, model:, timeout_ms:)
}

/// The bound on one request, or the default when absent.
fn timeout(fields: Dict(String, tom.Toml)) -> Result(Int, String) {
  // Only an integer in range is a bound; a string or a number outside it is not.
  case dict.get(fields, "timeout_ms") {
    Error(Nil) -> Ok(defaults.timeout_ms)
    Ok(tom.Int(value)) if value >= min_timeout_ms && value <= max_timeout_ms ->
      Ok(value)
    Ok(_) -> Error("jev.timeout_ms must be an integer from 500 to 30000")
  }
}

/// A string key that must satisfy `valid`, or the default when absent.
fn text(
  fields: Dict(String, tom.Toml),
  key: String,
  default: String,
  valid: fn(String) -> Bool,
) -> Result(String, String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok(default)
    Ok(tom.String(value)) ->
      case valid(value) {
        True -> Ok(value)
        False -> Error("jev." <> key <> " is not a valid value")
      }
    Ok(_) -> Error("jev." <> key <> " must be a string")
  }
}

/// Whether a name can be an environment variable: letters, digits and
/// underscores, not starting with a digit, at most 64 characters.
///
/// ## Examples
///
/// ```gleam
/// assert jev_settings.variable_name("JEV_API_KEY")
/// assert !jev_settings.variable_name("1KEY")
/// ```
pub fn variable_name(name: String) -> Bool {
  let characters = string.to_graphemes(name)

  // An empty name is no name, and the first character may not be a digit.
  case characters {
    [] -> False
    [first, ..] ->
      list.length(characters) <= 64
      && !string.contains("0123456789", first)
      && list.all(characters, fn(each) {
        string.contains(
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
          each,
        )
      })
  }
}

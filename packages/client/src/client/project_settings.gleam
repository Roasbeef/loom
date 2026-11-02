//// The `[project]` table: the numbers that bound a project's workers
//// (protocol-change/106, "Configuration").
////
//// The daemon reads it once when it starts, like `[peers]` and `[daemon]`, and
//// never rereads it. Both keys default to a value that is safe without being
//// stingy: four workers at once, and a token ceiling of five million for the
//// project. The table is the owner's alone; no session's configuration can
//// raise them for the daemon it runs under.
////
//// The keys the design lists beyond these two (`check`, `protected_paths` and
//// the sources) belong to later slices, and a key this slice does not serve is
//// refused instead of accepted and ignored, so a file that sets one fails at
//// startup and not silently.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import tom

/// The project numbers of a daemon.
pub type Settings {
  Settings(
    /// General worker slots per project. One more is reserved for a person.
    max_workers: Int,
    /// The token ceiling above which a project stops new inferred work.
    token_ceiling: Int,
  )
}

/// The settings of a daemon whose configuration has no `[project]` table.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings.defaults.max_workers == 4
/// ```
pub const defaults = Settings(max_workers: 4, token_ceiling: 5_000_000)

/// Validates the `[project]` table of a parsed configuration document.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings.from_document(dict.new()) == Ok(project_settings.defaults)
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(Settings, String) {
  case dict.get(document, "project") {
    Error(Nil) -> Ok(defaults)
    Ok(tom.Table(fields)) -> from_fields(fields)
    Ok(_) -> Error("project must be a [project] table")
  }
}

fn from_fields(fields: Dict(String, tom.Toml)) -> Result(Settings, String) {
  use _ <- result.try(
    list.try_map(dict.keys(fields), fn(key) {
      case key {
        "max_workers" | "token_ceiling" -> Ok(Nil)
        _ -> Error("unknown key `" <> key <> "` in [project]")
      }
    }),
  )
  use max_workers <- result.try(bounded(
    fields,
    "max_workers",
    defaults.max_workers,
    1,
    16,
  ))
  use token_ceiling <- result.map(bounded(
    fields,
    "token_ceiling",
    defaults.token_ceiling,
    1,
    1_000_000_000_000,
  ))
  Settings(max_workers:, token_ceiling:)
}

// An integer in `low` to `high`, or the default when the key is absent.
fn bounded(
  fields: Dict(String, tom.Toml),
  key: String,
  default: Int,
  low: Int,
  high: Int,
) -> Result(Int, String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok(default)
    Ok(tom.Int(value)) if value >= low && value <= high -> Ok(value)
    Ok(_) -> Error("project." <> key <> " must be an integer in range")
  }
}

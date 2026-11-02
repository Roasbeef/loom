//// The `[project]` table: the numbers that bound a project's workers and the
//// three keys that decide what the host does with a worker's finished work
//// (protocol-change/106, "Configuration").
////
//// The daemon reads it once when it starts, like `[peers]` and `[daemon]`, and
//// never rereads it. `max_workers` and `token_ceiling` default to values that
//// are safe without being stingy: four workers at once, and a token ceiling of
//// five million for the project. The other three default to doing nothing
//// outward, which is the point of them:
////
//// - `check` is the command the host runs against a worker's head. Unset,
////   there is no check, and a ticket whose work is done waits for a person.
//// - `setup` is the command that makes the project's template: the one step
////   that runs with the network on, from the clean base commit, so that the
////   offline check finds its dependencies. Unset, there is no template and
////   each worker and check starts from a plain clone, as before.
//// - `protected_paths` are the files whose change keeps the check from
////   running (`project/protect`). Unset, they are `protect.default_paths`.
//// - `publish` says whether the host may push a verified branch and open a
////   pull request. Unset it is `off`, and nothing leaves the machine unless
////   the owner wrote `pull_request`.
////
//// `source`, `rule`, `queue_limit` and `attention_limit` describe the event
//// sources of a project and are read by `client/project_sources`. With no
//// source the composer is the only way work starts.
////
//// The table is the owner's alone; no session's configuration can change
//// them for the daemon it runs under. A key this slice does not serve is
//// refused instead of accepted and ignored, so a file that sets one fails at
//// startup and not silently.

import client/project_sources.{type Sources}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/protect
import tom

/// The longest check command the table accepts, in bytes. A command is a line
/// a person wrote, and a longer one is a mistake.
pub const max_check_bytes = 4096

/// Whether the host may send a verified branch outward.
pub type PublishMode {
  /// Nothing leaves the machine. A verified ticket waits for a person.
  PublishOff

  /// The host may push `project/<ticket>` to the origin remote and open a pull
  /// request for it.
  PublishPullRequest
}

/// The project numbers of a daemon.
pub type Settings {
  Settings(
    /// General worker slots per project. One more is reserved for a person.
    max_workers: Int,
    /// The token ceiling above which a project stops new inferred work.
    token_ceiling: Int,
    /// The check command, or `None` for a project with no check.
    check: Option(String),
    /// The command that prepares the project's template, or `None` for a
    /// project with no template (`client/project_template`). It runs once per
    /// base commit, with the network on and in a jail, and fills the caches the
    /// offline check then reads.
    setup: Option(String),
    /// The protected path patterns, see `project/protect`.
    protected_paths: List(String),
    /// Whether the host may push and open pull requests.
    publish: PublishMode,
    /// The event sources and the rules over them (`client/project_sources`).
    sources: Sources,
  )
}

/// The settings of a daemon whose configuration has no `[project]` table.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings.defaults.max_workers == 4
/// ```
pub const defaults =
  Settings(
    max_workers: 4,
    token_ceiling: 5_000_000,
    check: None,
    setup: None,
    protected_paths: protect.default_paths,
    publish: PublishOff,
    sources: project_sources.none,
  )

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

/// Reads the `[project]` table. An unknown key is refused by name instead of
/// ignored, so a misspelt limit does not silently leave the default in force.
fn from_fields(fields: Dict(String, tom.Toml)) -> Result(Settings, String) {
  use _ <- result.try(
    list.try_map(dict.keys(fields), fn(key) {
      case key {
        "max_workers" | "token_ceiling" -> Ok(Nil)
        "check" | "setup" | "protected_paths" | "publish" -> Ok(Nil)
        "source" | "rule" | "queue_limit" | "attention_limit" -> Ok(Nil)
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
  use token_ceiling <- result.try(bounded(
    fields,
    "token_ceiling",
    defaults.token_ceiling,
    1,
    1_000_000_000_000,
  ))
  use check <- result.try(command(fields, "check"))
  use setup <- result.try(command(fields, "setup"))
  use protected_paths <- result.try(paths(fields))
  use publish <- result.try(publish_mode(fields))
  use sources <- result.map(project_sources.from_fields(fields))
  Settings(
    max_workers:,
    token_ceiling:,
    check:,
    setup:,
    protected_paths:,
    publish:,
    sources:,
  )
}

/// An integer in `low` to `high`, or the default when the key is absent.
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

/// A command key (`check` or `setup`): a non-empty line of at most
/// `max_check_bytes`, or none.
fn command(
  fields: Dict(String, tom.Toml),
  key: String,
) -> Result(Option(String), String) {
  // Absent is no command; a string is the command; anything else is refused.
  case dict.get(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(tom.String(text)) -> {
      let trimmed = string.trim(text)

      // A blank command would run nothing and pass, so it is refused instead.
      case trimmed != "" && string.byte_size(trimmed) <= max_check_bytes {
        True -> Ok(Some(trimmed))
        False ->
          Error(
            "project."
            <> key
            <> " must be a non-empty command of at most 4096 bytes",
          )
      }
    }
    Ok(_) -> Error("project." <> key <> " must be a string")
  }
}

/// The protected path patterns: strings, none of them empty. An empty list is
/// allowed and means the owner protects nothing beyond the check's own files.
fn paths(fields: Dict(String, tom.Toml)) -> Result(List(String), String) {
  case dict.get(fields, "protected_paths") {
    Error(Nil) -> Ok(defaults.protected_paths)
    Ok(tom.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          tom.String(pattern) if pattern != "" -> Ok(pattern)
          _ -> Error("project.protected_paths must hold non-empty strings")
        }
      })
    Ok(_) -> Error("project.protected_paths must be an array of strings")
  }
}

/// `off` or `pull_request`, and `off` when absent.
fn publish_mode(fields: Dict(String, tom.Toml)) -> Result(PublishMode, String) {
  case dict.get(fields, "publish") {
    Error(Nil) -> Ok(PublishOff)
    Ok(tom.String("off")) -> Ok(PublishOff)
    Ok(tom.String("pull_request")) -> Ok(PublishPullRequest)
    Ok(_) -> Error("project.publish must be \"off\" or \"pull_request\"")
  }
}

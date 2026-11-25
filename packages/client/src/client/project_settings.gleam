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

import client/jev_settings
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

/// Who decides where an incoming message goes first.
pub type Router {
  /// The router session decides every candidate, as it always has.
  ModelRouter

  /// Jev decides first, and the router session decides what Jev leaves.
  JevRouter
}

/// One entry of the agent catalogue: a name the Jev pass can choose for new
/// work, and the profile or model that work then starts with. Choosing one
/// changes which models a worker uses and nothing about its jail, tools,
/// approvals or network, which the ticket's mandate decides.
pub type Agent {
  Agent(
    /// The entry's name, as the ledger records the choice.
    name: String,
    /// The operator's own words about what the agent suits, shown to Jev.
    use_for: String,
    /// A `[profiles.<name>]` table, or none.
    profile: Option(String),
    /// A `[models.<name>]` entry, or none.
    model: Option(String),
  )
}

/// The most agents a catalogue may hold.
pub const max_agents = 16

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
    /// Who decides first. The scope is the daemon's, not a project's.
    router: Router,
    /// How sure Jev must be to attach a message to an existing ticket, as a
    /// percent from 51 to 100.
    jev_min_probability: Int,
    /// The agents Jev may choose among for new work, at most `max_agents`.
    agents: List(Agent),
    /// How the daemon reaches the Jev service (`[jev]`).
    jev: jev_settings.Settings,
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
    router: ModelRouter,
    jev_min_probability: 80,
    agents: [],
    jev: jev_settings.defaults,
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
    Ok(tom.Table(fields)) -> from_fields(fields, names_in(document))
    Ok(_) -> Error("project must be a [project] table")
  }
  |> result.try(with_jev(_, document))
}

/// Adds the `[jev]` table, which every daemon reads whether or not it has a
/// `[project]` table, since the table names the service and not the project.
fn with_jev(
  settings: Settings,
  document: Dict(String, tom.Toml),
) -> Result(Settings, String) {
  use jev <- result.map(jev_settings.from_document(document))
  Settings(..settings, jev:)
}

/// The `[profiles]` and `[models]` names of a document, which the agent
/// catalogue's entries must name.
type Names {
  Names(profiles: List(String), models: List(String))
}

fn names_in(document: Dict(String, tom.Toml)) -> Names {
  Names(
    profiles: table_keys(document, "profiles"),
    models: table_keys(document, "models"),
  )
}

fn table_keys(document: Dict(String, tom.Toml), table: String) -> List(String) {
  case dict.get(document, table) {
    Ok(tom.Table(entries)) -> dict.keys(entries)
    _ -> []
  }
}

/// Reads the `[project]` table. An unknown key is refused by name instead of
/// ignored, so a misspelt limit does not silently leave the default in force.
fn from_fields(
  fields: Dict(String, tom.Toml),
  names: Names,
) -> Result(Settings, String) {
  use _ <- result.try(
    list.try_map(dict.keys(fields), fn(key) {
      case key {
        "max_workers" | "token_ceiling" -> Ok(Nil)
        "check" | "setup" | "protected_paths" | "publish" -> Ok(Nil)
        "source" | "rule" | "queue_limit" | "attention_limit" -> Ok(Nil)
        "router" | "jev_min_probability" | "agent" -> Ok(Nil)
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
  use sources <- result.try(project_sources.from_fields(fields))
  use router <- result.try(router_choice(fields))
  use jev_min_probability <- result.try(bounded(
    fields,
    "jev_min_probability",
    defaults.jev_min_probability,
    51,
    100,
  ))
  use agents <- result.map(agent_catalogue(fields, names))
  Settings(
    max_workers:,
    token_ceiling:,
    check:,
    setup:,
    protected_paths:,
    publish:,
    sources:,
    router:,
    jev_min_probability:,
    agents:,
    jev: jev_settings.defaults,
  )
}

/// `model` or `jev`, and `model` when absent.
fn router_choice(fields: Dict(String, tom.Toml)) -> Result(Router, String) {
  case dict.get(fields, "router") {
    Error(Nil) -> Ok(ModelRouter)
    Ok(tom.String("model")) -> Ok(ModelRouter)
    Ok(tom.String("jev")) -> Ok(JevRouter)
    Ok(_) -> Error("project.router must be \"model\" or \"jev\"")
  }
}

/// The `[[project.agent]]` tables. Each has a name of 1 to 40 characters that
/// no other has, a `use_for` of 1 to 200, and a `profile` or a `model` that the
/// file defines, so a catalogue cannot name a model the daemon lacks.
fn agent_catalogue(
  fields: Dict(String, tom.Toml),
  names: Names,
) -> Result(List(Agent), String) {
  case dict.get(fields, "agent") {
    Error(Nil) -> Ok([])
    Ok(tom.ArrayOfTables(found)) ->
      case list.length(found) <= max_agents {
        True -> agents_from(found, names)
        False ->
          Error("project.agent holds more than " <> string.inspect(max_agents))
      }
    Ok(_) -> Error("project.agent must be an array of tables")
  }
}

/// Reads each table and refuses a catalogue in which two agents share a name,
/// since the ledger records a choice by name alone.
fn agents_from(
  tables: List(Dict(String, tom.Toml)),
  names: Names,
) -> Result(List(Agent), String) {
  use agents <- result.try(list.try_map(tables, agent_from(_, names)))
  let named = list.map(agents, fn(agent) { agent.name })

  // Distinct names are as many as all the names.
  case list.length(list.unique(named)) == list.length(named) {
    True -> Ok(agents)
    False -> Error("project.agent names must be distinct")
  }
}

/// Reads one agent. An unknown key is refused by name, and an entry must name
/// a profile or a model that the file defines.
fn agent_from(
  table: Dict(String, tom.Toml),
  names: Names,
) -> Result(Agent, String) {
  use _ <- result.try(
    list.try_map(dict.keys(table), fn(key) {
      case key {
        "name" | "use_for" | "profile" | "model" -> Ok(Nil)
        _ -> Error("unknown key `" <> key <> "` in [[project.agent]]")
      }
    }),
  )
  use name <- result.try(sized(table, "name", 40))
  use use_for <- result.try(sized(table, "use_for", 200))
  use profile <- result.try(named_entry(table, "profile", names.profiles))
  use model <- result.try(named_entry(table, "model", names.models))

  // An agent that changes neither the profile nor the model changes nothing.
  case profile, model {
    None, None ->
      Error(
        "project.agent `" <> name <> "` names neither a profile nor a model",
      )
    _, _ -> Ok(Agent(name:, use_for:, profile:, model:))
  }
}

/// A required string of 1 to `most` characters, trimmed.
fn sized(
  table: Dict(String, tom.Toml),
  key: String,
  most: Int,
) -> Result(String, String) {
  // A missing key and one that is not a string read the same to the owner.
  case dict.get(table, key) {
    Ok(tom.String(value)) -> within(key, string.trim(value), most)
    _ -> Error("project.agent " <> key <> " must be a string")
  }
}

/// Text that is not empty and at most `most` characters.
fn within(key: String, text: String, most: Int) -> Result(String, String) {
  // An empty or an over-long value is refused by the key's own name.
  case text != "" && string.length(text) <= most {
    True -> Ok(text)
    False ->
      Error(
        "project.agent "
        <> key
        <> " must be 1 to "
        <> string.inspect(most)
        <> " characters",
      )
  }
}

/// An optional key that must name one of `known`.
fn named_entry(
  table: Dict(String, tom.Toml),
  key: String,
  known: List(String),
) -> Result(Option(String), String) {
  case dict.get(table, key) {
    Error(Nil) -> Ok(None)
    Ok(tom.String(value)) ->
      case list.contains(known, value) {
        True -> Ok(Some(value))
        False ->
          Error(
            "project.agent "
            <> key
            <> " `"
            <> value
            <> "` is not defined in the file",
          )
      }
    Ok(_) -> Error("project.agent " <> key <> " must be a string")
  }
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
    Ok(tom.String(text)) -> command_text(key, text) |> result.map(Some)
    Ok(_) -> Error("project." <> key <> " must be a string")
  }
}

/// The one rule for a command, whether the owner wrote it in the file or set
/// it for a project: trimmed, not blank, and at most `max_check_bytes`.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings.command_text("check", "  make check ") == Ok("make check")
/// assert result.is_error(project_settings.command_text("check", "   "))
/// ```
pub fn command_text(key: String, text: String) -> Result(String, String) {
  let trimmed = string.trim(text)

  // A blank command would run nothing and pass, so it is refused instead.
  case trimmed != "" && string.byte_size(trimmed) <= max_check_bytes {
    True -> Ok(trimmed)
    False ->
      Error(
        "project."
        <> key
        <> " must be a non-empty command of at most 4096 bytes",
      )
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
          tom.String(pattern) -> Ok(pattern)
          _ -> Error("project.protected_paths must hold non-empty strings")
        }
      })
      |> result.try(path_patterns)
    Ok(_) -> Error("project.protected_paths must be an array of strings")
  }
}

/// The one rule for protected paths: every pattern is non-empty.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings.path_patterns(["Makefile"]) == Ok(["Makefile"])
/// assert result.is_error(project_settings.path_patterns([""]))
/// ```
pub fn path_patterns(patterns: List(String)) -> Result(List(String), String) {
  case list.all(patterns, fn(pattern) { pattern != "" }) {
    True -> Ok(patterns)
    False -> Error("project.protected_paths must hold non-empty strings")
  }
}

/// `off` or `pull_request`, and `off` when absent.
fn publish_mode(fields: Dict(String, tom.Toml)) -> Result(PublishMode, String) {
  case dict.get(fields, "publish") {
    Error(Nil) -> Ok(PublishOff)
    Ok(tom.String(word)) -> publish_word(word)
    Ok(_) -> Error(publish_refusal)
  }
}

const publish_refusal = "project.publish must be \"off\" or \"pull_request\""

/// The one rule for the publish word.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings.publish_word("off") == Ok(project_settings.PublishOff)
/// ```
pub fn publish_word(word: String) -> Result(PublishMode, String) {
  case word {
    "off" -> Ok(PublishOff)
    "pull_request" -> Ok(PublishPullRequest)
    _ -> Error(publish_refusal)
  }
}

/// The word for a publish mode, as the file and the wire spell it.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings.publish_mode_word(project_settings.PublishOff) == "off"
/// ```
pub fn publish_mode_word(mode: PublishMode) -> String {
  case mode {
    PublishOff -> "off"
    PublishPullRequest -> "pull_request"
  }
}

/// The one rule for the worker count.
///
/// ## Examples
///
/// ```gleam
/// assert project_settings.worker_count(4) == Ok(4)
/// assert result.is_error(project_settings.worker_count(0))
/// ```
pub fn worker_count(count: Int) -> Result(Int, String) {
  case count >= 1 && count <= 16 {
    True -> Ok(count)
    False -> Error("project.max_workers must be an integer in range")
  }
}

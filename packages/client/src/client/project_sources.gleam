//// The event sources of a project, as the owner configures them
//// (`[[project.source]]` and `[[project.rule]]`, protocol-change/106).
////
//// A source decides which outside events become triggers. The owner's
//// configuration is the only authority over that decision, so this module
//// reads it once, validates it totally, and hands the rest of the daemon plain
//// data. Nothing here reads a clock, starts a process or touches the network.
////
//// ## What the tables say
////
//// - `[[project.source]]` with `kind = "github"` names the people (`allow`)
////   and bots (`bots`) whose comments the gate may let through, the agent's
////   own `account`, and how often the poller looks (`interval_s`). The
////   repository is not configured: it is the one the project's pinned push URL
////   names, so a source cannot be pointed at a repository the project does not
////   publish to.
//// - `[[project.rule]]` names what an inferred trigger may become. A rule
////   matches when any of its literal `match` strings occurs in the trigger's
////   text, compared without case. There are no patterns. `mode` is `off`,
////   `observe` or `auto` and defaults to `observe`; the composer stays
////   explicit in every mode.
//// - `queue_limit` and `attention_limit` of `[project]` size the engine's
////   overload rules (`project/queue`).
////
//// ## Why the lists are literal
////
//// A list of logins is compared by equality and never by pattern, so a name
//// the owner did not write cannot match. Every string is bounded here, because
//// the tables are small and a long one is a mistake.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/model.{type ApprovalGrant, type Mode}
import tom

/// The most `[[project.source]]` tables. Only `github` exists in this slice.
const max_sources = 1

/// The most `[[project.rule]]` tables.
const max_rules = 32

/// The most logins one of `allow` and `bots` holds.
const max_logins = 64

/// The most literal strings one rule matches on.
const max_matches = 16

/// The longest literal a rule matches on, in bytes.
const max_match_bytes = 200

/// The longest login or name, in bytes.
const max_name_bytes = 64

/// The fewest seconds between two polls. GitHub's authenticated REST limit is
/// far above this, and a faster poll would spend it for nothing.
pub const min_interval_s = 15

/// The most seconds between two polls.
pub const max_interval_s = 86_400

/// The interval when the source names none.
pub const default_interval_s = 60

/// The sources and rules of a daemon.
pub type Sources {
  Sources(
    /// The most candidates a source may hold queued before inferred ones shed.
    queue_limit: Int,
    /// A source stops inferring while its open tickets that need a person
    /// exceed this many.
    attention_limit: Int,
    /// The GitHub source, or none when the owner configured none.
    github: Option(Github),
    /// The rules, in file order. The first rule that matches a trigger wins.
    rules: List(Rule),
  )
}

/// The GitHub source of a project.
pub type Github {
  Github(
    /// Logins of people whose comments may become explicit or inferred work.
    allow: List(String),
    /// Logins of bots whose comments may become inferred work.
    bots: List(String),
    /// The agent's own login, or none to ask GitHub who the credentials are.
    account: Option(String),
    /// Seconds between two polls.
    interval_s: Int,
  )
}

/// What an inferred trigger of a source may become.
pub type Rule {
  Rule(
    /// The rule's name, which is its identity in the ledger.
    name: String,
    /// The source the rule belongs to. Only `github` exists.
    source: String,
    /// The mode the rule starts in, until a person sets another.
    mode: Mode,
    /// Literal strings; the rule matches a trigger whose text holds any.
    matches: List(String),
    /// Whether work admitted by the rule may route approvals to a person.
    approvals: ApprovalGrant,
  )
}

/// The sources of a daemon whose configuration has none: the composer is the
/// only source, and the engine's overload limits keep their defaults.
///
/// ## Examples
///
/// ```gleam
/// assert project_sources.none.github == option.None
/// ```
pub const none =
  Sources(queue_limit: 100, attention_limit: 5, github: None, rules: [])

/// Reads `source`, `rule`, `queue_limit` and `attention_limit` out of the
/// `[project]` table's fields. The caller has already refused unknown keys.
///
/// ## Examples
///
/// ```gleam
/// assert project_sources.from_fields(dict.new()) == Ok(project_sources.none)
/// ```
pub fn from_fields(fields: Dict(String, tom.Toml)) -> Result(Sources, String) {
  use queue_limit <- result.try(bounded(
    fields,
    "queue_limit",
    none.queue_limit,
    1,
    10_000,
  ))
  use attention_limit <- result.try(bounded(
    fields,
    "attention_limit",
    none.attention_limit,
    0,
    1000,
  ))
  use github <- result.try(github_source(fields))
  use rules <- result.try(rule_tables(fields))

  // A rule that names a source the owner did not configure would never match
  // anything, so it is refused where the mistake was made.
  use Nil <- result.try(rules_have_a_source(rules, github))
  Ok(Sources(queue_limit:, attention_limit:, github:, rules:))
}

/// The tables of one array key, or none when the key is absent.
fn tables(
  fields: Dict(String, tom.Toml),
  key: String,
  limit: Int,
) -> Result(List(Dict(String, tom.Toml)), String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok([])
    Ok(tom.ArrayOfTables(found)) ->
      case list.length(found) <= limit {
        True -> Ok(found)
        False ->
          Error(
            "project." <> key <> " holds more than " <> string.inspect(limit),
          )
      }
    Ok(_) -> Error("project." <> key <> " must be an array of tables")
  }
}

/// The one GitHub source, if there is one.
fn github_source(
  fields: Dict(String, tom.Toml),
) -> Result(Option(Github), String) {
  use found <- result.try(tables(fields, "source", max_sources))

  // Zero tables is the composer alone; one is the GitHub source.
  case found {
    [] -> Ok(None)
    [first, ..] -> parse_source(first) |> result.map(Some)
  }
}

/// Reads one `[[project.source]]` table.
fn parse_source(fields: Dict(String, tom.Toml)) -> Result(Github, String) {
  let place = "project.source"
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    ["kind", "allow", "bots", "account", "interval_s"],
    place,
  ))
  use Nil <- result.try(case dict.get(fields, "kind") {
    Ok(tom.String("github")) -> Ok(Nil)
    Ok(_) | Error(Nil) -> Error(place <> ".kind must be \"github\"")
  })
  use allow <- result.try(logins(fields, "allow", place))
  use bots <- result.try(logins(fields, "bots", place))
  use account <- result.try(account(fields, place))
  use interval_s <- result.map(bounded(
    fields,
    "interval_s",
    default_interval_s,
    min_interval_s,
    max_interval_s,
  ))
  Github(allow:, bots:, account:, interval_s:)
}

/// A list of logins, empty when the key is absent.
fn logins(
  fields: Dict(String, tom.Toml),
  key: String,
  place: String,
) -> Result(List(String), String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok([])
    Ok(tom.Array(items)) ->
      case list.length(items) <= max_logins {
        True ->
          list.try_map(items, fn(item) {
            case item {
              tom.String(login) -> plain_login(login, place <> "." <> key)
              _ -> Error(place <> "." <> key <> " must hold strings")
            }
          })
        False -> Error(place <> "." <> key <> " holds more than 64 logins")
      }
    Ok(_) -> Error(place <> "." <> key <> " must be an array of strings")
  }
}

/// The agent's own login, or none.
fn account(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Option(String), String) {
  case dict.get(fields, "account") {
    Error(Nil) -> Ok(None)
    Ok(tom.String(login)) ->
      plain_login(login, place <> ".account") |> result.map(Some)
    Ok(_) -> Error(place <> ".account must be a string")
  }
}

/// A GitHub login: letters, digits, `-`, `_`, `.` and the brackets of a bot's
/// `[bot]` suffix, at most 64 bytes. The charset matters beyond tidiness,
/// because a login becomes an actor name in a message heading and in a
/// `gh api` argument.
///
/// ## Examples
///
/// ```gleam
/// assert project_sources.plain_login("dependabot[bot]", "x") == Ok("dependabot[bot]")
/// ```
///
/// ```gleam
/// assert project_sources.plain_login("a b", "x") |> result.is_error
/// ```
pub fn plain_login(login: String, place: String) -> Result(String, String) {
  let letters =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.[]"
  let plain =
    login != ""
    && string.byte_size(login) <= max_name_bytes
    && list.all(string.to_graphemes(login), fn(each) {
      string.contains(letters, each)
    })

  // A login that is not plain is refused whole, not trimmed.
  case plain {
    True -> Ok(login)
    False ->
      Error(
        place
        <> " must hold logins of letters, digits, `-`, `_`, `.` and `[bot]`, "
        <> "at most 64 bytes",
      )
  }
}

/// The rules, in file order.
fn rule_tables(fields: Dict(String, tom.Toml)) -> Result(List(Rule), String) {
  use found <- result.try(tables(fields, "rule", max_rules))
  use parsed <- result.try(list.try_map(found, parse_rule))
  use Nil <- result.map(unique_names(parsed, []))
  parsed
}

/// Reads one `[[project.rule]]` table.
fn parse_rule(fields: Dict(String, tom.Toml)) -> Result(Rule, String) {
  let place = "project.rule"
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    ["name", "source", "mode", "match", "approvals"],
    place,
  ))
  use name <- result.try(rule_name(fields, place))
  use source <- result.try(case dict.get(fields, "source") {
    Ok(tom.String("github")) -> Ok("github")
    Ok(_) | Error(Nil) -> Error(place <> ".source must be \"github\"")
  })
  use mode <- result.try(mode_of(fields, place))
  use matches <- result.try(literals(fields, place))
  use approvals <- result.map(approvals_of(fields, place))
  Rule(name:, source:, mode:, matches:, approvals:)
}

/// A rule's name: it becomes a ledger identity and a board word, so it is
/// plain.
fn rule_name(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(String, String) {
  case dict.get(fields, "name") {
    Ok(tom.String(name)) -> plain_login(name, place <> ".name")
    Ok(_) | Error(Nil) -> Error(place <> ".name is required and a string")
  }
}

/// The rule's starting mode. `observe` when the key is absent.
fn mode_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Mode, String) {
  case dict.get(fields, "mode") {
    Error(Nil) -> Ok(model.Observe)
    Ok(tom.String("off")) -> Ok(model.Off)
    Ok(tom.String("observe")) -> Ok(model.Observe)
    Ok(tom.String("auto")) -> Ok(model.Auto)
    Ok(_) -> Error(place <> ".mode must be \"off\", \"observe\" or \"auto\"")
  }
}

/// The literal strings a rule matches on. A rule with none matches nothing,
/// which is refused: it is a rule that can never fire.
fn literals(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  case dict.get(fields, "match") {
    Ok(tom.Array(items)) ->
      case items != [] && list.length(items) <= max_matches {
        True ->
          list.try_map(items, fn(item) {
            case item {
              tom.String(text) ->
                case text != "" && string.byte_size(text) <= max_match_bytes {
                  True -> Ok(text)
                  False ->
                    Error(place <> ".match holds a string of 1 to 200 bytes")
                }
              _ -> Error(place <> ".match must hold strings")
            }
          })
        False -> Error(place <> ".match holds 1 to 16 strings")
      }
    Ok(_) | Error(Nil) -> Error(place <> ".match is required, an array")
  }
}

/// Whether the rule grants approvals. A TOML boolean is read here and becomes
/// the domain's own two-variant type at once.
fn approvals_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(ApprovalGrant, String) {
  case dict.get(fields, "approvals") {
    Error(Nil) -> Ok(model.ApprovalsNotGranted)
    Ok(tom.Bool(True)) -> Ok(model.ApprovalsGranted)
    Ok(tom.Bool(False)) -> Ok(model.ApprovalsNotGranted)
    Ok(_) -> Error(place <> ".approvals must be true or false")
  }
}

/// Rule names are unique, because the name is the rule's identity.
fn unique_names(rules: List(Rule), seen: List(String)) -> Result(Nil, String) {
  case rules {
    [] -> Ok(Nil)
    [first, ..rest] ->
      case list.contains(seen, first.name) {
        True -> Error("project.rule `" <> first.name <> "` is defined twice")
        False -> unique_names(rest, [first.name, ..seen])
      }
  }
}

/// Every rule belongs to the configured source.
fn rules_have_a_source(
  rules: List(Rule),
  github: Option(Github),
) -> Result(Nil, String) {
  case rules, github {
    [], _ -> Ok(Nil)
    [_, ..], Some(_) -> Ok(Nil)
    [_, ..], None ->
      Error("project.rule needs a [[project.source]] with kind = \"github\"")
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

/// Refuses a key the table does not define, by name.
fn known_keys(
  present: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in "
        <> place
        <> " (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}

/// The first rule of the list whose literals occur in `text`, compared
/// without case. Rules are tried in file order and only those of `source`
/// are considered.
///
/// ## Examples
///
/// ```gleam
/// let rule = project_sources.Rule("ci", "github", model.Observe, ["CI failure"], model.ApprovalsNotGranted)
/// assert project_sources.matching([rule], "github", "ci failure on main") == Some(rule)
/// ```
pub fn matching(
  rules: List(Rule),
  source: String,
  text: String,
) -> Option(Rule) {
  let lowered = string.lowercase(text)
  list.find(rules, fn(rule) {
    rule.source == source
    && list.any(rule.matches, fn(literal) {
      string.contains(lowered, string.lowercase(literal))
    })
  })
  |> option.from_result
}

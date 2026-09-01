//// The model catalogue: named model configurations plus role routing,
//// read from a `loom.toml` file (or assembled from the environment) and
//// used three ways — to build the provider gateway's registry, to
//// answer the protocol's `models` command, and to resolve `set_config`
//// model switches by catalogue *name* instead of raw provider facts.
//// The same file optionally carries the MCP server tables code mode
//// exposes as generated `cap/mcp/<name>` modules.
////
//// The catalogue is a thin, declarative front-end over the registry the
//// provider gateway already has: each `[models.<name>]` entry becomes
//// one registered provider endpoint (the entry name doubling as the
//// provider name, so the durable `{provider, model_id}` identity a
//// strand stores is exactly `{catalogue-name, model_id}`), and the
//// `[roles]` table becomes the gateway's ordered fallback chains. No
//// dispatch mechanics live here.
////
//// ## The file format
////
//// A TOML document with two required top-level tables and one optional
//// one (see `docs/examples/loom.toml` for a worked, commented example):
////
//// ```toml
//// [models.<name>]
//// dialect = "anthropic" | "openai"   # which wire adapter speaks it
//// base_url = "https://..."           # optional; dialect default used
//// api_key_env = "SOME_API_KEY"       # env var *name*, never a value
//// model_id = "provider-model-id"
//// context_window = 200000
//// max_output_tokens = 32000
//// thinking = "off"                   # off|low|medium|high|unsupported
////
//// [roles]
//// main = ["<name>", "<fallback-name>", ...]
//// # likewise: subagent, plan, summarize, vision
////
//// [mcp.<name>]                       # optional; one table per server
//// command = ["server-binary", "arg"] # the stdio server's argv
//// api_key_env = "SOME_API_KEY"       # optional; env var *name*
////
//// [[rule]]                           # optional; see `client/rules`
//// name = "schema-gate"
//// triggers = ["ALTER TABLE"]
//// body = "Run the schema gate first."
//// ```
////
//// The `[[rule]]` tables are the triggered project rules and are parsed
//// by `client/rules`, not here — but they are *named* here, in the
//// top-level key check, because top-level strictness has to live in one
//// parser or a typoed table name would be refused by neither.
////
//// API keys never live in the file: `api_key_env` names an environment
//// variable, which the provider secret store reads at dispatch — the
//// same missing-key-fails-in-band story as the env-only configuration.
//// An MCP server's `api_key_env` is the same discipline at spawn time:
//// the *name* is read from the host environment when the server process
//// starts and injected into its child environment under that name.
////
//// The `[mcp.<name>]` table key becomes the `cap/mcp/<name>` Gleam
//// module a code-mode program imports, so it must be a single legal
//// lowercase-ASCII identifier segment (`[a-z][a-z0-9_]*`, no slashes) —
//// the same grammar `codemode/vet/policy` holds every import to, which
//// is where the check is borrowed from. There is no CLI surface, no
//// auto-discovery, and no live reload: an operator editing this file
//// and restarting the server *is* the trust decision.
////
//// Parsing is total and strict: any malformed document, unknown key,
//// unknown dialect/role, or dangling chain name is a worded `Error`
//// the server prints on its documented halt path — never a crash, and
//// never a silently-ignored typo. Per-model `headers` are recognized
//// but refused: the provider registry has no header slot yet (recorded
//// as a spec gap), and Baseten's OpenAI-compatible endpoints need only
//// the bearer key this format already carries.

import codemode/vet/policy as vet_policy
import core/clock.{type Clock}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/gateway as provider_gateway
import provider/http.{type Transport}
import provider/model
import provider/secret.{type SecretStore}
import tom

/// Which wire adapter an entry speaks. The two variants mirror the
/// provider gateway's two `ProviderConfig` shapes.
pub type Dialect {
  /// The Anthropic Messages API.
  Anthropic

  /// An OpenAI-compatible chat-completions API (OpenAI itself, Baseten,
  /// and every other endpoint speaking that dialect).
  OpenAiCompatible
}

/// One named catalogue entry: everything needed to register the model's
/// endpoint and to resolve it as a dispatch identity.
///
/// Constructor invariants: `name` is unique within the catalogue and is
/// the provider name durable identities store; `base_url` has no
/// trailing slash (Anthropic: the host root; OpenAI-compatible: the API
/// root ending in `/v1`); `api_key_env` is an environment variable
/// *name*, never a key value; `context_window` and `max_output_tokens`
/// are positive token counts.
pub type CatalogModel {
  CatalogModel(
    /// The catalogue name — the handle `set_config` switches by.
    name: String,
    /// Which adapter dialect the endpoint speaks.
    dialect: Dialect,
    /// The endpoint root, no trailing slash.
    base_url: String,
    /// The environment variable holding the API key.
    api_key_env: String,
    /// The provider's own model identifier.
    model_id: String,
    /// Tokens of context the model accepts (drives overflow detection).
    context_window: Int,
    /// The default output ceiling per request.
    max_output_tokens: Int,
    /// The static thinking level requests to this entry ask for.
    thinking: model.ThinkingLevel,
  )
}

/// One configured MCP server: the stdio process code mode reaches as
/// the generated `cap/mcp/<name>` module.
///
/// Constructor invariants: `name` is unique within the catalogue and is
/// a legal lowercase-ASCII module segment (`[a-z][a-z0-9_]*`), because
/// it becomes the `cap/mcp/<name>` module name a program imports;
/// `command` is a non-empty argv whose every element is a non-empty
/// string; `api_key_env` is an environment variable *name*, never a key
/// value — read from the host environment at server spawn and injected
/// into the child environment under the same name.
pub type McpServer {
  McpServer(
    /// The table key — the `<name>` in `cap/mcp/<name>`.
    name: String,
    /// The stdio server's argv, executable first.
    command: List(String),
    /// The environment variable holding the server's API key, if any.
    api_key_env: Option(String),
  )
}

/// The parsed catalogue: entries plus the role → fallback-chain table,
/// plus any configured MCP servers.
///
/// Constructor invariants (guaranteed by `parse`, owed by any direct
/// construction): entry names are unique; every chain is non-empty and
/// names only existing entries; `model.Main` is routed; `models`,
/// `roles` and `mcp_servers` are in the deterministic orders `parse`
/// produces (entries and servers sorted by name, roles in the five-role
/// canonical order).
pub type Catalog {
  Catalog(
    /// The entries, sorted by name.
    models: List(CatalogModel),
    /// Ordered fallback chains, best entry first, per routed role.
    roles: List(#(model.Role, List(String))),
    /// The MCP servers, sorted by name; `[]` when `[mcp]` is absent.
    mcp_servers: List(McpServer),
  )
}

// The five routable roles, in the canonical order listings use.
const routable_roles = [
  model.Main,
  model.Subagent,
  model.Plan,
  model.Summarize,
  model.Vision,
]

// --- parsing ---------------------------------------------------------------

/// Parses a `loom.toml` catalogue document. Total: every failure is a
/// human-worded `Error` naming the offending table or key — the message
/// the server prints when it refuses to boot on a bad config.
///
/// ## Examples
///
/// ```gleam
/// // catalog.parse(toml_text)
/// // -> Ok(catalog.Catalog(models: [...], roles: [...]))
/// ```
///
/// ```gleam
/// assert catalog.parse("")
///   == Error("the catalogue needs a [models.<name>] table")
/// ```
///
pub fn parse(text: String) -> Result(Catalog, String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(describe_parse_error),
  )

  // Top-level strictness lives here, including over the `[[rule]]`
  // tables this module never reads (`client/rules` owns their
  // contents): it has to live in exactly one parser, or a typoed table
  // name would be refused by neither.
  use Nil <- result.try(known_keys(
    dict.keys(document),
    ["models", "roles", "mcp", "rule"],
    "the top level",
  ))
  use model_tables <- result.try(
    table_entries(document, "models")
    |> result.replace_error("the catalogue needs a [models.<name>] table"),
  )
  use role_table <- result.try(
    table_entries(document, "roles")
    |> result.replace_error(
      "the catalogue needs a [roles] table routing at least main",
    ),
  )
  use models <- result.try(parse_models(model_tables))
  use roles <- result.try(parse_roles(role_table, models))
  use mcp_servers <- result.try(parse_mcp_servers(document))
  Ok(Catalog(models:, roles:, mcp_servers:))
}

// tom renders a TOML parse failure as a structured value; the server
// prints strings, so both variants are worded here.
fn describe_parse_error(error: tom.ParseError) -> String {
  case error {
    tom.Unexpected(got:, expected:) ->
      "not valid toml: expected " <> expected <> ", got `" <> got <> "`"
    tom.KeyAlreadyInUse(key:) ->
      "not valid toml: the key " <> string.join(key, ".") <> " appears twice"
  }
}

// Reads a top-level table's entries. `[models.x]` headers and inline
// `models = {x = ...}` tables are both TOML; accept either shape.
fn table_entries(
  document: Dict(String, tom.Toml),
  key: String,
) -> Result(List(#(String, tom.Toml)), Nil) {
  case dict.get(document, key) {
    Ok(tom.Table(entries)) | Ok(tom.InlineTable(entries)) ->
      Ok(dict.to_list(entries))
    _ -> Error(Nil)
  }
}

// Every model entry, sorted by name so the catalogue (and everything
// derived from it — the gateway registry, the `models` listing) is
// deterministic regardless of file order, which the TOML dict loses.
fn parse_models(
  tables: List(#(String, tom.Toml)),
) -> Result(List(CatalogModel), String) {
  use Nil <- result.try(case tables {
    [] -> Error("the [models] table is empty; define [models.<name>] entries")
    _ -> Ok(Nil)
  })
  tables
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.try_map(fn(entry) { parse_model(entry.0, entry.1) })
}

fn parse_model(name: String, value: tom.Toml) -> Result(CatalogModel, String) {
  let place = "models." <> name
  use fields <- result.try(case value {
    tom.Table(fields) | tom.InlineTable(fields) -> Ok(fields)
    _ -> Error(place <> " must be a table")
  })

  // Refuse unknown keys instead of ignoring them: a typoed
  // `api_key_env` silently ignored would dispatch with the wrong key
  // name and fail confusingly at the first request. `headers` gets its
  // own message because the field is plausible but not yet carriable.
  use Nil <- result.try(case dict.has_key(fields, "headers") {
    True ->
      Error(
        place
        <> ": per-model headers are not supported yet; the bearer key from"
        <> " api_key_env is the only credential the adapters send",
      )
    False -> Ok(Nil)
  })
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    [
      "dialect", "base_url", "api_key_env", "model_id", "context_window",
      "max_output_tokens", "thinking",
    ],
    place,
  ))
  use dialect_text <- result.try(required_string(fields, place, "dialect"))
  use dialect <- result.try(case dialect_text {
    "anthropic" -> Ok(Anthropic)
    "openai" -> Ok(OpenAiCompatible)
    other ->
      Error(
        place
        <> ".dialect must be \"anthropic\" or \"openai\", got \""
        <> other
        <> "\"",
      )
  })
  use base_url <- result.try(case optional_string(fields, place, "base_url") {
    Ok(Ok(url)) -> Ok(strip_trailing_slash(url))
    Ok(Error(Nil)) -> Ok(default_base_url(dialect))
    Error(message) -> Error(message)
  })
  use api_key_env <- result.try(required_string(fields, place, "api_key_env"))
  use model_id <- result.try(required_string(fields, place, "model_id"))
  use context_window <- result.try(positive_int(fields, place, "context_window"))
  use max_output_tokens <- result.try(positive_int(
    fields,
    place,
    "max_output_tokens",
  ))
  use thinking <- result.try(case optional_string(fields, place, "thinking") {
    Ok(Ok(level)) -> parse_thinking(place, level)
    Ok(Error(Nil)) -> Ok(model.ThinkingOff)
    Error(message) -> Error(message)
  })
  Ok(CatalogModel(
    name:,
    dialect:,
    base_url:,
    api_key_env:,
    model_id:,
    context_window:,
    max_output_tokens:,
    thinking:,
  ))
}

/// The dialect's conventional endpoint root, used when an entry names
/// none. Baseten-style entries always set their own `base_url`.
///
/// ## Examples
///
/// ```gleam
/// assert catalog.default_base_url(catalog.OpenAiCompatible)
///   == "https://api.openai.com/v1"
/// ```
///
pub fn default_base_url(dialect: Dialect) -> String {
  case dialect {
    Anthropic -> "https://api.anthropic.com"
    OpenAiCompatible -> "https://api.openai.com/v1"
  }
}

// The provider gateway's ProviderConfig invariant is "no trailing
// slash"; normalize here so config authors need not care.
fn strip_trailing_slash(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> strip_trailing_slash(string.drop_end(url, 1))
    False -> url
  }
}

// "unsupported" is the config author's word for "this model has no
// reasoning mode"; it maps to off, which sends no thinking field at
// all — exactly what such an endpoint needs to receive.
fn parse_thinking(
  place: String,
  level: String,
) -> Result(model.ThinkingLevel, String) {
  case level {
    "off" | "unsupported" -> Ok(model.ThinkingOff)
    "low" -> Ok(model.ThinkingLow)
    "medium" -> Ok(model.ThinkingMedium)
    "high" -> Ok(model.ThinkingHigh)
    other ->
      Error(
        place
        <> ".thinking must be off, low, medium, high, or unsupported, got \""
        <> other
        <> "\"",
      )
  }
}

// The optional [mcp] table: absent parses to no servers, present it
// must be a table of [mcp.<name>] entries. Sorted by name for the same
// reason models are — the TOML dict loses file order, and everything
// derived from the catalogue must be deterministic. Duplicate names
// cannot reach here: tom refuses a repeated `[mcp.<name>]` header as
// KeyAlreadyInUse before this parser runs.
fn parse_mcp_servers(
  document: Dict(String, tom.Toml),
) -> Result(List(McpServer), String) {
  use tables <- result.try(case dict.get(document, "mcp") {
    Ok(tom.Table(entries)) | Ok(tom.InlineTable(entries)) ->
      Ok(dict.to_list(entries))
    Ok(_other) -> Error("mcp must be a table of [mcp.<name>] entries")
    Error(Nil) -> Ok([])
  })
  tables
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.try_map(fn(entry) { parse_mcp_server(entry.0, entry.1) })
}

fn parse_mcp_server(
  name: String,
  value: tom.Toml,
) -> Result(McpServer, String) {
  let place = "mcp." <> name
  use Nil <- result.try(mcp_server_name(name))
  use fields <- result.try(case value {
    tom.Table(fields) | tom.InlineTable(fields) -> Ok(fields)
    _ -> Error(place <> " must be a table")
  })

  // Same strictness as models: a typoed `api_key_env` silently ignored
  // would spawn the server with no key and fail confusingly at its
  // first request.
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    ["command", "api_key_env"],
    place,
  ))
  use command <- result.try(mcp_command(fields, place))
  use api_key_env <- result.try(
    case optional_string(fields, place, "api_key_env") {
      Ok(Ok("")) -> Error(place <> ".api_key_env must be non-empty")
      Ok(Ok(env_name)) -> Ok(Some(env_name))
      Ok(Error(Nil)) -> Ok(None)
      Error(message) -> Error(message)
    },
  )
  Ok(McpServer(name:, command:, api_key_env:))
}

// The table key becomes the `cap/mcp/<name>` module a code-mode program
// imports, so it must be one legal lowercase-ASCII identifier segment —
// judged by the same grammar gate the vetting policy holds every import
// to (`vet_policy.is_legal_module_name`), with the slash excluded here
// because a server name is exactly one segment. "internal" is refused
// by name: `cap/internal/*` is the unimportable marshaling layer, and a
// `cap/mcp/internal` would sit confusingly beside it.
fn mcp_server_name(name: String) -> Result(Nil, String) {
  let legal =
    !string.contains(name, "/") && vet_policy.is_legal_module_name(name)
  case name, legal {
    "internal", _ ->
      Error(
        "mcp.internal is reserved: cap/internal/* is the capability"
        <> " marshaling layer, and a cap/mcp/internal module would sit"
        <> " confusingly beside it; pick another server name",
      )
    _, True -> mcp_name_survives_mangling(name)
    _, False ->
      Error(
        "mcp."
        <> name
        <> " is not a legal server name: the key becomes the cap/mcp/<name>"
        <> " module code-mode programs import, so it must be a single"
        <> " lowercase-ASCII identifier segment ([a-z][a-z0-9_]*)",
      )
  }
}

// The Gleam keywords a module segment may not be. The generator's name
// mangler digests any name it has to change, so a key it would change
// becomes cap/mcp/<name>_<8hex> — not the cap/mcp/<name> this module's
// doc promises. Refusing every mangle-altered shape here keeps that
// contract provable: on every config-legal name, mangling is the
// identity.
const gleam_keywords = [
  "as", "assert", "auto", "case", "const", "delegate", "derive", "echo", "else",
  "fn", "if", "implement", "import", "let", "macro", "opaque", "panic", "pub",
  "test", "todo", "type", "use",
]

// The mangler's own bound (`mcp/name`'s `max_length`), past which a name
// is truncated and digested. Restated rather than imported because this
// package does not depend on `mcp`; the tests hold both ends to 32.
const max_mangled_length = 32

fn mcp_name_survives_mangling(name: String) -> Result(Nil, String) {
  let refuse = fn(what: String) {
    Error(
      "mcp."
      <> name
      <> " "
      <> what
      <> ", which module-name mangling would rewrite — the key must name"
      <> " the cap/mcp/<name> module unchanged",
    )
  }
  case
    list.contains(gleam_keywords, name),
    string.contains(name, "__"),
    string.ends_with(name, "_"),
    // Asks whether the name is longer than the bound without walking a
    // pathological key to its end (lint R5).
    string.drop_start(name, max_mangled_length) != ""
  {
    True, _, _, _ -> refuse("is a Gleam keyword")
    _, True, _, _ -> refuse("contains a doubled underscore")
    _, _, True, _ -> refuse("ends with an underscore")
    _, _, _, True -> refuse("is longer than 32 characters")
    False, False, False, False -> Ok(Nil)
  }
}

// The server's argv: a TOML array of non-empty strings, executable
// first, so at least one element.
fn mcp_command(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(List(String), String) {
  use items <- result.try(case dict.get(fields, "command") {
    Ok(tom.Array(items)) -> Ok(items)
    Ok(_other) ->
      Error(place <> ".command must be an array of strings (the argv)")
    Error(Nil) -> Error(place <> ".command is required")
  })
  use argv <- result.try(
    list.try_map(items, fn(item) {
      case item {
        tom.String("") ->
          Error(place <> ".command elements must be non-empty strings")
        tom.String(text) -> Ok(text)
        _other ->
          Error(place <> ".command must be an array of strings (the argv)")
      }
    }),
  )
  case argv {
    [] -> Error(place <> ".command must name at least the executable")
    _some -> Ok(argv)
  }
}

// The role table: every key must be a routable role name, every value a
// non-empty array of defined entry names, and main must be routed —
// the harness cannot run a strand without a main identity.
fn parse_roles(
  entries: List(#(String, tom.Toml)),
  models: List(CatalogModel),
) -> Result(List(#(model.Role, List(String))), String) {
  use routed <- result.try(
    list.try_map(entries, fn(entry) {
      let #(role_name, value) = entry
      use role <- result.try(parse_role(role_name))
      use chain <- result.try(parse_chain(role_name, value, models))
      Ok(#(role, chain))
    }),
  )

  // Canonical role order, independent of TOML dict order, so listings
  // and snapshots are deterministic.
  let roles =
    list.filter_map(routable_roles, fn(role) {
      list.key_find(routed, role)
      |> result.map(fn(chain) { #(role, chain) })
    })
  case list.key_find(roles, model.Main) {
    Ok(_chain) -> Ok(roles)
    Error(Nil) -> Error("the [roles] table must route main")
  }
}

fn parse_role(name: String) -> Result(model.Role, String) {
  case name {
    "main" -> Ok(model.Main)
    "subagent" -> Ok(model.Subagent)
    "plan" -> Ok(model.Plan)
    "summarize" -> Ok(model.Summarize)
    "vision" -> Ok(model.Vision)
    other ->
      Error(
        "roles."
        <> other
        <> " is not a routable role (main, subagent, plan, summarize, vision)",
      )
  }
}

fn parse_chain(
  role_name: String,
  value: tom.Toml,
  models: List(CatalogModel),
) -> Result(List(String), String) {
  let place = "roles." <> role_name
  use names <- result.try(case value {
    tom.Array(items) ->
      list.try_map(items, fn(item) {
        case item {
          tom.String(name) -> Ok(name)
          _ -> Error(place <> " entries must be model names (strings)")
        }
      })
    _ -> Error(place <> " must be an array of model names, best first")
  })
  use Nil <- result.try(case names {
    [] -> Error(place <> " must name at least one model")
    _ -> Ok(Nil)
  })
  list.try_each(names, fn(name) {
    case list.find(models, fn(entry) { entry.name == name }) {
      Ok(_entry) -> Ok(Nil)
      Error(Nil) ->
        Error(place <> " names \"" <> name <> "\", which is not in [models]")
    }
  })
  |> result.map(fn(_nil) { names })
}

// Shared strictness helper: the present keys must all be known ones.
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

fn required_string(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(String, String) {
  case dict.get(fields, key) {
    Ok(tom.String(text)) if text != "" -> Ok(text)
    Ok(tom.String(_empty)) -> Error(place <> "." <> key <> " must be non-empty")
    Ok(_other) -> Error(place <> "." <> key <> " must be a string")
    Error(Nil) -> Error(place <> "." <> key <> " is required")
  }
}

// Ok(Ok(text)) present, Ok(Error(Nil)) absent, Error(message) mistyped.
fn optional_string(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(Result(String, Nil), String) {
  case dict.get(fields, key) {
    Ok(tom.String(text)) -> Ok(Ok(text))
    Ok(_other) -> Error(place <> "." <> key <> " must be a string")
    Error(Nil) -> Ok(Error(Nil))
  }
}

fn positive_int(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(Int, String) {
  case dict.get(fields, key) {
    Ok(tom.Int(value)) if value > 0 -> Ok(value)
    Ok(tom.Int(value)) ->
      Error(
        place <> "." <> key <> " must be positive, got " <> int.to_string(value),
      )
    Ok(_other) -> Error(place <> "." <> key <> " must be an integer")
    Error(Nil) -> Error(place <> "." <> key <> " is required")
  }
}

// --- lookups ---------------------------------------------------------------

/// Finds an entry by catalogue name.
///
/// ## Examples
///
/// ```gleam
/// // catalog.find(catalogue, "baseten-llama")
/// // -> Ok(catalog.CatalogModel(name: "baseten-llama", ..))
/// ```
///
pub fn find(catalog: Catalog, name: String) -> Result(CatalogModel, Nil) {
  list.find(catalog.models, fn(entry) { entry.name == name })
}

/// The entry new strands should be configured with: the head of the
/// main role's chain.
///
/// ## Examples
///
/// ```gleam
/// // catalog.main_model(catalogue) -> Ok(catalog.CatalogModel(..))
/// ```
///
pub fn main_model(catalog: Catalog) -> Result(CatalogModel, Nil) {
  use chain <- result.try(list.key_find(catalog.roles, model.Main))
  use name <- result.try(list.first(chain))
  find(catalog, name)
}

/// The roles whose fallback chain lists the named entry (anywhere in
/// the chain), in canonical role order.
///
/// ## Examples
///
/// ```gleam
/// // catalog.routed_roles(catalogue, "anthropic-opus") -> ["main", "plan"]
/// ```
///
pub fn routed_roles(catalog: Catalog, name: String) -> List(String) {
  catalog.roles
  |> list.filter(fn(route) { list.contains(route.1, name) })
  |> list.map(fn(route) { model.role_to_string(route.0) })
}

/// The roles the named entry currently resolves for — the chains it
/// heads, which is what `gateway.resolve` will pick since every
/// catalogue entry is a registered provider.
///
/// ## Examples
///
/// ```gleam
/// // catalog.active_roles(catalogue, "baseten-llama") -> ["main"]
/// ```
///
pub fn active_roles(catalog: Catalog, name: String) -> List(String) {
  catalog.roles
  |> list.filter(fn(route) { list.first(route.1) == Ok(name) })
  |> list.map(fn(route) { model.role_to_string(route.0) })
}

/// The wire name of a dialect, as the `models` listing carries it.
///
/// ## Examples
///
/// ```gleam
/// assert catalog.dialect_to_string(catalog.Anthropic) == "anthropic"
/// ```
///
pub fn dialect_to_string(dialect: Dialect) -> String {
  case dialect {
    Anthropic -> "anthropic"
    OpenAiCompatible -> "openai"
  }
}

// --- the provider gateway --------------------------------------------------

/// An entry's dispatch identity with its static model facts — what the
/// gateway's role chains carry and durable state stores.
///
/// ## Examples
///
/// ```gleam
/// // catalog.resolved(entry).provider == entry.name
/// ```
///
pub fn resolved(entry: CatalogModel) -> model.ResolvedModel {
  model.ResolvedModel(
    provider: entry.name,
    model_id: entry.model_id,
    thinking: entry.thinking,
    context_window: entry.context_window,
    max_output_tokens: entry.max_output_tokens,
  )
}

/// Builds the provider gateway from the catalogue: one registered
/// provider per entry (named by the entry, carrying its dialect,
/// base URL, and key name) and one route per role table row. Keys stay
/// in the secret store, read at dispatch — building a gateway from a
/// keyless environment succeeds and fails in-band per request.
///
/// ## Examples
///
/// ```gleam
/// // catalog.gateway(catalogue,
/// //   transport: http.httpc_transport(),
/// //   secrets: secret.env(),
/// //   clock: clock,
/// // )
/// ```
///
pub fn gateway(
  catalog: Catalog,
  transport transport: Transport,
  secrets secrets: SecretStore,
  clock clock: Clock,
) -> provider_gateway.Gateway {
  let registered =
    list.fold(
      catalog.models,
      provider_gateway.new(transport:, secrets:, clock:),
      fn(gateway, entry) {
        provider_gateway.add_provider(gateway, provider_config(entry))
      },
    )
  list.fold(catalog.roles, registered, fn(gateway, route) {
    let #(role, names) = route
    let chain =
      list.filter_map(names, fn(name) {
        find(catalog, name)
        |> result.map(resolved)
      })
    provider_gateway.route(gateway, role, chain)
  })
}

fn provider_config(entry: CatalogModel) -> provider_gateway.ProviderConfig {
  case entry.dialect {
    Anthropic ->
      provider_gateway.AnthropicProvider(
        name: entry.name,
        base_url: entry.base_url,
        api_key_secret: entry.api_key_env,
      )
    OpenAiCompatible ->
      provider_gateway.OpenAiCompatibleProvider(
        name: entry.name,
        base_url: entry.base_url,
        api_key_secret: entry.api_key_env,
      )
  }
}

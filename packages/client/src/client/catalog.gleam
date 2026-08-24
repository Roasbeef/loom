//// The model catalogue: named model configurations plus role routing,
//// read from a `loom.toml` file (or assembled from the environment) and
//// used three ways — to build the provider gateway's registry, to
//// answer the protocol's `models` command, and to resolve `set_config`
//// model switches by catalogue *name* instead of raw provider facts.
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
//// A TOML document with exactly two top-level tables (see
//// `docs/examples/loom.toml` for a worked, commented example):
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
//// ```
////
//// API keys never live in the file: `api_key_env` names an environment
//// variable, which the provider secret store reads at dispatch — the
//// same missing-key-fails-in-band story as the env-only configuration.
////
//// Parsing is total and strict: any malformed document, unknown key,
//// unknown dialect/role, or dangling chain name is a worded `Error`
//// the server prints on its documented halt path — never a crash, and
//// never a silently-ignored typo. Per-model `headers` are recognized
//// but refused: the provider registry has no header slot yet (recorded
//// as a spec gap), and Baseten's OpenAI-compatible endpoints need only
//// the bearer key this format already carries.

import core/clock.{type Clock}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
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

/// The parsed catalogue: entries plus the role → fallback-chain table.
///
/// Constructor invariants (guaranteed by `parse`, owed by any direct
/// construction): entry names are unique; every chain is non-empty and
/// names only existing entries; `model.Main` is routed; `models` and
/// `roles` are in the deterministic orders `parse` produces (entries
/// sorted by name, roles in the five-role canonical order).
pub type Catalog {
  Catalog(
    /// The entries, sorted by name.
    models: List(CatalogModel),
    /// Ordered fallback chains, best entry first, per routed role.
    roles: List(#(model.Role, List(String))),
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
  use Nil <- result.try(known_keys(
    dict.keys(document),
    ["models", "roles"],
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
  Ok(Catalog(models:, roles:))
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

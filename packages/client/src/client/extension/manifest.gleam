//// `extension.toml` — an extension's own account of itself, decoded
//// totally.
////
//// The manifest is the source of truth for what an extension *is*: its
//// name, the tools it registers, the schemas the model is shown, and the
//// network policy the broker will compose from at dispatch. `loom.toml`
//// gains nothing per extension, and the install record is the approval —
//// so if this decoder is loose, there is nothing downstream to catch it.
////
//// # Unknown keys are errors, everywhere
////
//// The same rule `client/catalog` holds `loom.toml` to, for the same
//// reason and one turn sharper. A typoed `api_key_env` in a catalogue
//// dispatches with the wrong key name and fails confusingly; a typoed
//// `hosts` in an extension's `[net]` table would silently widen or narrow
//// what the broker will reach on the extension's behalf. So every table
//// here has a closed key list, and a key outside it refuses the manifest
//// naming both the table and the key.
////
//// The `[client]` table the design note reserves for a later ruling is
//// therefore refused today, by construction rather than by a special
//// case: it is not on the top-level list.
////
//// # What this decoder cannot check alone
////
//// Three rules need the tree beside the manifest, so `decode` takes it:
//// a tool's `parameters` must name a file under `schema/` that exists and
//// parses as JSON; a tool's `entry` must name a module the package
//// actually ships; and a secret's `host` must be one of `[net].hosts`.
//// Each of the three is a promise the manifest makes about something
//// else, and a promise checked at install is one the dispatch path never
//// has to re-check.
////
//// # Tiers and hooks
////
//// `tier` decodes only `"jailed"`. A harness-resident body is phase 4 and
//// there is no loader for one, so a manifest naming the tier is refused
//// saying that rather than installed and ignored. `[[hook]]` decodes —
//// the vocabulary is fixed by the ruling and an author reading a refusal
//// should see their event name checked — but the install refuses a
//// manifest carrying one, because the harness cannot call into a
//// satellite until phase 3 adds the reverse frame.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import tom

/// The directory a tool's JSON schema must live under.
pub const schema_directory = "schema/"

/// The only tier phase 1 installs.
pub const jailed_tier = "jailed"

/// The HTTP methods `[net].methods` may name.
///
/// A closed list checked at install rather than at dispatch, because
/// `broker/egress.Method` is a closed type: a name outside this list has
/// no value to become, so a manifest carrying one would translate to a
/// policy permitting *nothing* while still reading as though it permitted
/// something. `methods = ["get"]` is the case that matters — it installs
/// clean and then refuses every request the extension makes.
pub const http_methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"]

/// The hook events the ruling fixes. Decoded now, refused at install
/// until phase 3 gives the harness a way to call into a satellite.
pub const hook_events = [
  "session_start", "before_agent_start", "context", "tool_call", "tool_result",
  "agent_end", "agent_settled",
]

/// Where an extension's body runs.
///
/// One variant, though the ruling names two. Tier H — a harness-resident
/// body — is phase 4 and there is no loader for one, so it is not a
/// variant here: a type with a constructor nothing can produce would let
/// a `case` arm be written for a state that cannot exist. The *word* is
/// still refused by name, in `tier_field`, so a manifest asking for it
/// reads "not yet installable" rather than "unknown value".
pub type Tier {
  /// Tier J: the body runs in a jailed satellite under the extension
  /// seam. The only value phase 1 accepts.
  Jailed
}

/// One tool the extension registers.
pub type Tool {
  Tool(
    /// The name the model calls, `[a-z][a-z0-9_]*`.
    name: String,
    /// The description rendered to the model, as a built-in tool's is.
    description: String,
    /// The one-line entry in the available-tools section, adopted from
    /// pi's `promptSnippet`.
    ///
    /// Required here, where pi's is optional, and the divergence is
    /// deliberate: pi *omits* a custom tool from that section when it has
    /// no snippet, so an author who forgets one ships a tool the model is
    /// never told about and cannot debug. Making it required turns that
    /// into an install-time refusal naming the tool.
    prompt_snippet: String,
    /// A path under `schema/` naming the tool's JSON Schema.
    parameters: String,
    /// The Gleam module in `src/` implementing `ext.Tool`.
    entry: String,
    /// How long one call may take.
    timeout_ms: Int,
  )
}

/// One hook the extension registers. Phase 3.
pub type Hook {
  Hook(event: String, entry: String)
}

/// One secret binding: the *name* of an environment variable, the host it
/// is for, and the header the broker puts its value in.
///
/// The value is never here, and never in any file. `api_key_env` in
/// `client/catalog` established that a key's name is configuration; this
/// is the same rule one layer down, applied to a request the broker makes
/// on the extension's behalf, so the extension's own source never sees
/// the key and the jail never holds it.
pub type Secret {
  Secret(env: String, host: String, header: String)
}

/// The egress policy the broker composes from at dispatch.
pub type Net {
  Net(
    /// Exact host names, no wildcards. A request to any other host is
    /// refused in band naming this list.
    hosts: List(String),
    /// The HTTP methods permitted.
    methods: List(String),
    /// The largest response body the broker will hand back.
    max_response_bytes: Int,
    /// A lifetime admission ceiling per execution, the same shape as the
    /// orchestration seam's spawn ceiling and for the same reason: a loop
    /// otherwise pays nothing.
    requests_per_call: Int,
    /// The secret bindings, each for a host in `hosts`.
    secrets: List(Secret),
  )
}

/// A decoded `extension.toml`.
pub type Manifest {
  Manifest(
    name: String,
    version: String,
    description: String,
    license: String,
    tier: Tier,
    tools: List(Tool),
    hooks: List(Hook),
    net: Net,
  )
}

/// What the tree tells the decoder that the manifest cannot tell itself:
/// which schema files exist and parse, and which modules the package
/// ships.
pub type Surroundings {
  Surroundings(
    /// `#(path relative to the tree root, contents)` for every file that
    /// decodes as text.
    files: List(#(String, String)),
    /// The module names `src/` ships, e.g. `weather/forecast`.
    modules: List(String),
  )
}

/// The empty net policy: an extension that names no `[net]` table reaches
/// nothing, which is the deny-by-default the whole design rests on.
///
/// ## Examples
///
/// ```gleam
/// assert manifest.no_net().hosts == []
/// ```
///
pub fn no_net() -> Net {
  Net(
    hosts: [],
    methods: [],
    max_response_bytes: 0,
    requests_per_call: 0,
    secrets: [],
  )
}

/// Decodes an `extension.toml` against the tree it came with.
///
/// Total: every failure is a sentence naming the table and the key. The
/// first failure wins, because a manifest is small and an author fixes
/// them one at a time — unlike vetting, where the whole list is what a
/// model needs in one turn.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(decoded) = manifest.decode(text, surroundings)
/// assert decoded.tier == manifest.Jailed
/// ```
///
pub fn decode(
  text: String,
  surroundings: Surroundings,
) -> Result(Manifest, String) {
  use document <- result.try(tom.parse(text) |> result.map_error(parse_reason))
  use Nil <- result.try(known_keys(
    dict.keys(document),
    ["extension", "tool", "hook", "net"],
    "the top level",
  ))
  use extension <- result.try(table(document, "extension"))
  use Nil <- result.try(known_keys(
    dict.keys(extension),
    ["name", "version", "description", "license", "tier"],
    "[extension]",
  ))
  use name <- result.try(name_field(extension, "[extension]", "name"))
  use version <- result.try(required(extension, "[extension]", "version"))
  use description <- result.try(required(
    extension,
    "[extension]",
    "description",
  ))
  use license <- result.try(required(extension, "[extension]", "license"))
  use tier <- result.try(tier_field(extension))
  use tools <- result.try(tools_of(document, surroundings))
  use hooks <- result.try(hooks_of(document, surroundings))
  use net <- result.try(net_of(document))
  Ok(Manifest(
    name:,
    version:,
    description:,
    license:,
    tier:,
    tools:,
    hooks:,
    net:,
  ))
}

/// Whether `name` is a legal extension, tool or module-segment name:
/// `[a-z][a-z0-9_]*`.
///
/// The grammar is ASCII by construction, which is what makes a byte
/// comparison against it sufficient — the same argument
/// `codemode/vet/policy` makes about module names, and for the same
/// reason: a Cyrillic lookalike is not a normalization variant of a Latin
/// letter, so a grammar gate closes what normalization cannot.
///
/// ## Examples
///
/// ```gleam
/// assert manifest.is_legal_name("web_search")
/// assert !manifest.is_legal_name("Web-Search")
/// ```
///
pub fn is_legal_name(name: String) -> Bool {
  case string.to_utf_codepoints(name) {
    [] -> False
    [first, ..rest] ->
      lowercase(first) && list.all(rest, fn(point) { name_byte(point) })
  }
}

/// Whether `name` is a legal environment-variable name for a secret
/// binding: `[A-Z_][A-Z0-9_]*`.
///
/// ## Examples
///
/// ```gleam
/// assert manifest.is_legal_env("BRAVE_API_KEY")
/// assert !manifest.is_legal_env("brave")
/// ```
///
pub fn is_legal_env(name: String) -> Bool {
  case string.to_utf_codepoints(name) {
    [] -> False
    [first, ..rest] ->
      { uppercase(first) || underscore(first) }
      && list.all(rest, fn(point) { env_byte(point) })
  }
}

// --- [[tool]] --------------------------------------------------------------

fn tools_of(
  document: Dict(String, tom.Toml),
  surroundings: Surroundings,
) -> Result(List(Tool), String) {
  use entries <- result.try(array_of_tables(document, "tool"))
  use Nil <- result.try(case entries {
    [] -> Error("an extension registers at least one [[tool]]")
    [_, ..] -> Ok(Nil)
  })
  use tools <- result.try(
    list.try_map(entries, fn(fields) { tool_of(fields, surroundings) }),
  )
  unique(list.map(tools, fn(tool) { tool.name }), "[[tool]] name")
  |> result.replace(tools)
}

fn tool_of(
  fields: Dict(String, tom.Toml),
  surroundings: Surroundings,
) -> Result(Tool, String) {
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    [
      "name", "description", "prompt_snippet", "parameters", "entry",
      "timeout_ms",
    ],
    "[[tool]]",
  ))
  use name <- result.try(name_field(fields, "[[tool]]", "name"))
  let place = "[[tool]] " <> name
  use description <- result.try(required(fields, place, "description"))
  use prompt_snippet <- result.try(required(fields, place, "prompt_snippet"))
  use parameters <- result.try(required(fields, place, "parameters"))
  use Nil <- result.try(schema_exists(parameters, place, surroundings))
  use entry <- result.try(required(fields, place, "entry"))
  use Nil <- result.try(module_exists(entry, place, surroundings))
  use timeout_ms <- result.try(positive_int(fields, place, "timeout_ms"))
  Ok(Tool(
    name:,
    description:,
    prompt_snippet:,
    parameters:,
    entry:,
    timeout_ms:,
  ))
}

// The schema is rendered to the model verbatim, so a path that resolves
// to nothing would put an extension in the registry with no arguments the
// model could ever get right. Checked here, once, rather than at every
// dispatch.
fn schema_exists(
  path: String,
  place: String,
  surroundings: Surroundings,
) -> Result(Nil, String) {
  use Nil <- result.try(
    case
      string.starts_with(path, schema_directory) && !string.contains(path, "..")
    {
      True -> Ok(Nil)
      False ->
        Error(place <> ".parameters must be a path under " <> schema_directory)
    },
  )
  use text <- result.try(
    list.key_find(surroundings.files, path)
    |> result.map_error(fn(_nil) {
      place <> ".parameters names " <> path <> ", which the tree does not hold"
    }),
  )

  // The schema is rendered to the provider verbatim on every request, so
  // one that does not parse is a tool the model can never call correctly.
  // Parsed here rather than merely looked at: a brace check would pass
  // text the provider then rejects.
  json.parse(from: text, using: decode.dynamic)
  |> result.replace(Nil)
  |> result.map_error(fn(_error) {
    place <> ".parameters names " <> path <> ", which is not valid JSON"
  })
}

fn module_exists(
  entry: String,
  place: String,
  surroundings: Surroundings,
) -> Result(Nil, String) {
  case list.contains(surroundings.modules, entry) {
    True -> Ok(Nil)
    False ->
      Error(
        place
        <> ".entry names the module "
        <> entry
        <> ", which src/ does not hold",
      )
  }
}

// --- [[hook]] --------------------------------------------------------------

fn hooks_of(
  document: Dict(String, tom.Toml),
  surroundings: Surroundings,
) -> Result(List(Hook), String) {
  use entries <- result.try(array_of_tables(document, "hook"))
  list.try_map(entries, fn(fields) { hook_of(fields, surroundings) })
}

fn hook_of(
  fields: Dict(String, tom.Toml),
  surroundings: Surroundings,
) -> Result(Hook, String) {
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    ["event", "entry"],
    "[[hook]]",
  ))
  use event <- result.try(required(fields, "[[hook]]", "event"))
  use Nil <- result.try(case list.contains(hook_events, event) {
    True -> Ok(Nil)
    False ->
      Error(
        "[[hook]].event is "
        <> event
        <> ", which is not one of "
        <> string.join(hook_events, ", "),
      )
  })
  use entry <- result.try(required(fields, "[[hook]] " <> event, "entry"))
  use Nil <- result.try(module_exists(entry, "[[hook]] " <> event, surroundings))
  Ok(Hook(event:, entry:))
}

// --- [net] -----------------------------------------------------------------

fn net_of(document: Dict(String, tom.Toml)) -> Result(Net, String) {
  case dict.get(document, "net") {
    Error(Nil) -> Ok(no_net())
    Ok(tom.Table(fields)) | Ok(tom.InlineTable(fields)) -> net_fields(fields)
    Ok(_other) -> Error("[net] must be a table")
  }
}

fn net_fields(fields: Dict(String, tom.Toml)) -> Result(Net, String) {
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    ["hosts", "methods", "max_response_bytes", "requests_per_call", "secret"],
    "[net]",
  ))
  use hosts <- result.try(string_list(fields, "[net]", "hosts"))
  use Nil <- result.try(unique(hosts, "[net].hosts entry"))
  use methods <- result.try(string_list(fields, "[net]", "methods"))
  use Nil <- result.try(known_methods(methods))
  use max_response_bytes <- result.try(positive_int(
    fields,
    "[net]",
    "max_response_bytes",
  ))
  use requests_per_call <- result.try(positive_int(
    fields,
    "[net]",
    "requests_per_call",
  ))
  use secrets <- result.try(secrets_of(fields, hosts))
  Ok(Net(hosts:, methods:, max_response_bytes:, requests_per_call:, secrets:))
}

// A method `broker/egress` cannot name is refused here rather than
// dropped later. Dropping narrows, which is the safe direction, but it
// narrows *silently*: the policy would permit nothing while the record
// and the boot log both went on quoting the list the author wrote.
fn known_methods(methods: List(String)) -> Result(Nil, String) {
  case list.filter(methods, fn(name) { !list.contains(http_methods, name) }) {
    [] -> Ok(Nil)
    unknown ->
      Error(
        "[net].methods names "
        <> string.join(list.sort(unknown, string.compare), ", ")
        <> ", which is not an HTTP method this client can send; it sends "
        <> string.join(http_methods, ", "),
      )
  }
}

fn secrets_of(
  fields: Dict(String, tom.Toml),
  hosts: List(String),
) -> Result(List(Secret), String) {
  use entries <- result.try(array_of_tables(fields, "secret"))
  list.try_map(entries, fn(entry) { secret_of(entry, hosts) })
}

fn secret_of(
  fields: Dict(String, tom.Toml),
  hosts: List(String),
) -> Result(Secret, String) {
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    ["env", "host", "header"],
    "[[net.secret]]",
  ))
  use env <- result.try(required(fields, "[[net.secret]]", "env"))
  use Nil <- result.try(case is_legal_env(env) {
    True -> Ok(Nil)
    False ->
      Error(
        "[[net.secret]].env is "
        <> env
        <> ", which is not an environment variable name ([A-Z_][A-Z0-9_]*)",
      )
  })
  use host <- result.try(required(fields, "[[net.secret]] " <> env, "host"))

  // A binding for a host the policy does not reach is a key that could
  // only ever be sent somewhere the allowlist forbids, so it is a
  // contradiction rather than dead configuration.
  use Nil <- result.try(case list.contains(hosts, host) {
    True -> Ok(Nil)
    False ->
      Error(
        "[[net.secret]] "
        <> env
        <> " binds the host "
        <> host
        <> ", which is not in [net].hosts",
      )
  })
  use header <- result.try(required(fields, "[[net.secret]] " <> env, "header"))
  Ok(Secret(env:, host:, header:))
}

// --- field readers ---------------------------------------------------------

fn tier_field(fields: Dict(String, tom.Toml)) -> Result(Tier, String) {
  use tier <- result.try(required(fields, "[extension]", "tier"))
  case tier {
    "jailed" -> Ok(Jailed)
    other ->
      Error(
        "[extension].tier is \""
        <> other
        <> "\", which is not yet installable; phase 1 installs \""
        <> jailed_tier
        <> "\" only",
      )
  }
}

fn name_field(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(String, String) {
  use name <- result.try(required(fields, place, key))
  case is_legal_name(name) {
    True -> Ok(name)
    False ->
      Error(
        place
        <> "."
        <> key
        <> " is \""
        <> name
        <> "\", which is not [a-z][a-z0-9_]*",
      )
  }
}

fn required(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(String, String) {
  case dict.get(fields, key) {
    Ok(tom.String(value)) ->
      case value {
        "" -> Error(place <> "." <> key <> " must not be empty")
        _ -> Ok(value)
      }
    Ok(_other) -> Error(place <> "." <> key <> " must be a string")
    Error(Nil) -> Error(place <> " needs a " <> key)
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
    Ok(_other) -> Error(place <> "." <> key <> " must be a whole number")
    Error(Nil) -> Error(place <> " needs a " <> key)
  }
}

fn string_list(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
) -> Result(List(String), String) {
  case dict.get(fields, key) {
    Ok(tom.Array(values)) ->
      list.try_map(values, fn(value) {
        case value {
          tom.String(text) if text != "" -> Ok(text)
          _other ->
            Error(
              place <> "." <> key <> " holds a non-empty string in each slot",
            )
        }
      })
    Ok(_other) -> Error(place <> "." <> key <> " must be an array of strings")
    Error(Nil) -> Error(place <> " needs a " <> key)
  }
}

// `[[x]]` reaches `tom` as an `ArrayOfTables`; the same table written
// inline reaches it as an `Array` of tables. Both are the author writing
// a list of tables, so both are read.
fn array_of_tables(
  document: Dict(String, tom.Toml),
  key: String,
) -> Result(List(Dict(String, tom.Toml)), String) {
  case dict.get(document, key) {
    Error(Nil) -> Ok([])
    Ok(tom.ArrayOfTables(entries)) -> Ok(entries)
    Ok(tom.Array(values)) ->
      list.try_map(values, fn(value) {
        case value {
          tom.Table(fields) | tom.InlineTable(fields) -> Ok(fields)
          _other -> Error("[[" <> key <> "]] must be a table")
        }
      })
    Ok(_other) -> Error("[[" <> key <> "]] must be a list of tables")
  }
}

fn table(
  document: Dict(String, tom.Toml),
  key: String,
) -> Result(Dict(String, tom.Toml), String) {
  case dict.get(document, key) {
    Ok(tom.Table(fields)) | Ok(tom.InlineTable(fields)) -> Ok(fields)
    Ok(_other) -> Error("[" <> key <> "] must be a table")
    Error(Nil) -> Error("the manifest needs a [" <> key <> "] table")
  }
}

fn known_keys(
  present: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  case list.filter(present, fn(key) { !list.contains(allowed, key) }) {
    [] -> Ok(Nil)
    unknown ->
      Error(
        place
        <> " does not take "
        <> string.join(list.sort(unknown, string.compare), ", ")
        <> "; it takes "
        <> string.join(allowed, ", "),
      )
  }
}

fn unique(names: List(String), what: String) -> Result(Nil, String) {
  case list.length(list.unique(names)) == list.length(names) {
    True -> Ok(Nil)
    False -> Error("every " <> what <> " must be distinct")
  }
}

fn parse_reason(error: tom.ParseError) -> String {
  case error {
    tom.Unexpected(got:, expected:) ->
      "extension.toml is not valid toml: expected "
      <> expected
      <> ", got `"
      <> got
      <> "`"
    tom.KeyAlreadyInUse(key:) ->
      "extension.toml is not valid toml: the key "
      <> string.join(key, ".")
      <> " appears twice"
  }
}

// --- the two grammars ------------------------------------------------------

fn lowercase(point: UtfCodepoint) -> Bool {
  let value = string.utf_codepoint_to_int(point)
  value >= 0x61 && value <= 0x7A
}

fn uppercase(point: UtfCodepoint) -> Bool {
  let value = string.utf_codepoint_to_int(point)
  value >= 0x41 && value <= 0x5A
}

fn digit(point: UtfCodepoint) -> Bool {
  let value = string.utf_codepoint_to_int(point)
  value >= 0x30 && value <= 0x39
}

fn underscore(point: UtfCodepoint) -> Bool {
  string.utf_codepoint_to_int(point) == 0x5F
}

fn name_byte(point: UtfCodepoint) -> Bool {
  lowercase(point) || digit(point) || underscore(point)
}

fn env_byte(point: UtfCodepoint) -> Bool {
  uppercase(point) || digit(point) || underscore(point)
}

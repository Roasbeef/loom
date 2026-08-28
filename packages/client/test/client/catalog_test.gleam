//// The catalogue's parse-and-build contract: the committed example
//// stays parseable, strictness refuses typos in-band, defaults fill
//// deterministically, and the built gateway resolves the routed chains.

import client/catalog
import core/clock
import gleam/list
import gleam/option.{None, Some}
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import simplifile

// The example the docs ship is itself a fixture: it must always parse,
// and its shape is what the rest of these tests rely on.
const example_path = "../../docs/examples/loom.toml"

fn example() -> catalog.Catalog {
  let assert Ok(text) = simplifile.read(example_path)
    as "the committed example catalogue must be readable"
  let assert Ok(parsed) = catalog.parse(text)
    as "the committed example catalogue must parse"
  parsed
}

pub fn example_parses_sorted_and_routed_test() {
  let parsed = example()
  // Entries come back sorted by name regardless of file order.
  assert list.map(parsed.models, fn(entry) { entry.name })
    == ["anthropic-opus", "baseten-oss"]
  // Roles come back in canonical order with their chains intact.
  assert parsed.roles
    == [
      #(model.Main, ["baseten-oss", "anthropic-opus"]),
      #(model.Subagent, ["baseten-oss"]),
      #(model.Summarize, ["anthropic-opus"]),
    ]
}

pub fn example_baseten_entry_is_openai_dialect_test() {
  let assert Ok(entry) = catalog.find(example(), "baseten-oss")
  assert entry.dialect == catalog.OpenAiCompatible
  assert entry.base_url == "https://inference.baseten.example/v1"
  assert entry.api_key_env == "BASETEN_API_KEY"
  // "unsupported" collapses to off: no reasoning field is ever sent.
  assert entry.thinking == model.ThinkingOff
}

pub fn defaults_fill_base_url_and_thinking_test() {
  let assert Ok(entry) = catalog.find(example(), "anthropic-opus")
  assert entry.base_url == "https://api.anthropic.com"
  assert entry.thinking == model.ThinkingOff
}

pub fn main_model_is_chain_head_test() {
  let assert Ok(entry) = catalog.main_model(example())
  assert entry.name == "baseten-oss"
}

pub fn routed_and_active_roles_test() {
  let parsed = example()
  assert catalog.routed_roles(parsed, "anthropic-opus") == ["main", "summarize"]
  assert catalog.active_roles(parsed, "anthropic-opus") == ["summarize"]
  assert catalog.routed_roles(parsed, "baseten-oss") == ["main", "subagent"]
  assert catalog.active_roles(parsed, "baseten-oss") == ["main", "subagent"]
}

pub fn resolved_identity_uses_catalogue_name_test() {
  let assert Ok(entry) = catalog.find(example(), "baseten-oss")
  let resolved = catalog.resolved(entry)
  assert resolved.provider == "baseten-oss"
  assert resolved.model_id == "openai/gpt-oss-120b"
  assert resolved.context_window == 128_000
}

pub fn gateway_resolves_routed_roles_test() {
  let gateway =
    catalog.gateway(
      example(),
      transport: http.Transport(send_streaming: fn(_request, _subject) { Nil }),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    )
  let assert Ok(main) = provider_gateway.resolve(gateway, model.Main)
  assert main.provider == "baseten-oss"
  let assert Ok(summarize) = provider_gateway.resolve(gateway, model.Summarize)
  assert summarize.provider == "anthropic-opus"
  // Unrouted roles fail in the frozen-contract shape, not a crash.
  let assert Error(model.MissingIdentity(role: model.Vision)) =
    provider_gateway.resolve(gateway, model.Vision)
}

// --- strictness ------------------------------------------------------------

const minimal = "
[models.one]
dialect = \"anthropic\"
api_key_env = \"KEY\"
model_id = \"m-1\"
context_window = 1000
max_output_tokens = 100

[roles]
main = [\"one\"]
"

pub fn minimal_catalogue_parses_test() {
  let assert Ok(parsed) = catalog.parse(minimal)
  assert list.length(parsed.models) == 1
}

pub fn empty_document_refused_test() {
  assert catalog.parse("")
    == Error("the catalogue needs a [models.<name>] table")
}

pub fn malformed_toml_reported_test() {
  let assert Error("not valid toml: " <> _detail) =
    catalog.parse("[models.broken\ndialect =")
}

pub fn unknown_model_key_refused_test() {
  let text =
    "
[models.one]
dialect = \"anthropic\"
api_key_evn = \"KEY\"
model_id = \"m-1\"
context_window = 1000
max_output_tokens = 100

[roles]
main = [\"one\"]
"
  let assert Error("unknown key `api_key_evn` in models.one" <> _rest) =
    catalog.parse(text)
}

pub fn headers_refused_with_named_reason_test() {
  let text =
    "
[models.one]
dialect = \"openai\"
api_key_env = \"KEY\"
model_id = \"m-1\"
context_window = 1000
max_output_tokens = 100
headers = { x-extra = \"1\" }

[roles]
main = [\"one\"]
"
  let assert Error("models.one: per-model headers are not supported" <> _rest) =
    catalog.parse(text)
}

pub fn unknown_dialect_refused_test() {
  let text =
    "
[models.one]
dialect = \"cohere\"
api_key_env = \"KEY\"
model_id = \"m-1\"
context_window = 1000
max_output_tokens = 100

[roles]
main = [\"one\"]
"
  let assert Error("models.one.dialect must be" <> _rest) = catalog.parse(text)
}

pub fn nonpositive_window_refused_test() {
  let text =
    "
[models.one]
dialect = \"anthropic\"
api_key_env = \"KEY\"
model_id = \"m-1\"
context_window = 0
max_output_tokens = 100

[roles]
main = [\"one\"]
"
  let assert Error("models.one.context_window must be positive" <> _rest) =
    catalog.parse(text)
}

pub fn missing_main_route_refused_test() {
  let text =
    "
[models.one]
dialect = \"anthropic\"
api_key_env = \"KEY\"
model_id = \"m-1\"
context_window = 1000
max_output_tokens = 100

[roles]
plan = [\"one\"]
"
  assert catalog.parse(text) == Error("the [roles] table must route main")
}

pub fn dangling_chain_name_refused_test() {
  let text =
    "
[models.one]
dialect = \"anthropic\"
api_key_env = \"KEY\"
model_id = \"m-1\"
context_window = 1000
max_output_tokens = 100

[roles]
main = [\"one\", \"ghost\"]
"
  let assert Error("roles.main names \"ghost\"" <> _rest) = catalog.parse(text)
}

pub fn unknown_role_refused_test() {
  let text = minimal <> "critic = [\"one\"]\n"
  let assert Error("roles.critic is not a routable role" <> _rest) =
    catalog.parse(text)
}

// --- mcp servers -------------------------------------------------------------

// One server table appended after the minimal catalogue, so every mcp
// test exercises exactly the [mcp.<key>] shape it names.
fn with_mcp_server(key: String, body: String) -> String {
  minimal <> "\n[mcp." <> key <> "]\n" <> body <> "\n"
}

pub fn absent_mcp_table_parses_to_no_servers_test() {
  let assert Ok(parsed) = catalog.parse(minimal)
  assert parsed.mcp_servers == []
}

pub fn example_mcp_server_parses_test() {
  assert example().mcp_servers
    == [
      catalog.McpServer(
        name: "github",
        command: ["mcp-server-github", "--stdio"],
        api_key_env: Some("GITHUB_TOKEN"),
      ),
    ]
}

pub fn mcp_servers_parse_sorted_test() {
  let text = minimal <> "
[mcp.zeta]
command = [\"zeta-server\"]

[mcp.alpha]
command = [\"alpha-server\", \"--stdio\"]
api_key_env = \"ALPHA_KEY\"
"
  let assert Ok(parsed) = catalog.parse(text)
  // Sorted by name regardless of file order; an absent api_key_env is
  // None, a present one carries the env var *name*.
  assert parsed.mcp_servers
    == [
      catalog.McpServer(
        name: "alpha",
        command: ["alpha-server", "--stdio"],
        api_key_env: Some("ALPHA_KEY"),
      ),
      catalog.McpServer(
        name: "zeta",
        command: ["zeta-server"],
        api_key_env: None,
      ),
    ]
}

pub fn uppercase_mcp_name_refused_test() {
  let text = with_mcp_server("Github", "command = [\"x\"]")
  let assert Error("mcp.Github is not a legal server name" <> _rest) =
    catalog.parse(text)
}

pub fn digit_first_mcp_name_refused_test() {
  let text = with_mcp_server("9lives", "command = [\"x\"]")
  let assert Error("mcp.9lives is not a legal server name" <> _rest) =
    catalog.parse(text)
}

pub fn homoglyph_mcp_name_refused_test() {
  // A Cyrillic 'с' (U+0441) in place of ASCII 'c', via a quoted key.
  let text = with_mcp_server("\"сap\"", "command = [\"x\"]")
  let assert Error("mcp.сap is not a legal server name" <> _rest) =
    catalog.parse(text)
}

pub fn slash_in_mcp_name_refused_test() {
  let text = with_mcp_server("\"tools/gh\"", "command = [\"x\"]")
  let assert Error("mcp.tools/gh is not a legal server name" <> _rest) =
    catalog.parse(text)
}

pub fn empty_mcp_name_refused_test() {
  let text = with_mcp_server("\"\"", "command = [\"x\"]")
  let assert Error("mcp. is not a legal server name" <> _rest) =
    catalog.parse(text)
}

pub fn internal_mcp_name_refused_test() {
  let text = with_mcp_server("internal", "command = [\"x\"]")
  let assert Error("mcp.internal is reserved" <> _rest) = catalog.parse(text)
}

pub fn duplicate_mcp_name_refused_by_toml_test() {
  // tom itself refuses a repeated table header, so the parser never
  // sees two entries under one name.
  let text =
    with_mcp_server("same", "command = [\"x\"]")
    <> "\n[mcp.same]\ncommand = [\"y\"]\n"
  assert catalog.parse(text)
    == Error("not valid toml: the key mcp.same appears twice")
}

pub fn missing_mcp_command_refused_test() {
  let text = with_mcp_server("one", "api_key_env = \"KEY\"")
  let assert Error("mcp.one.command is required" <> _rest) = catalog.parse(text)
}

pub fn empty_mcp_command_refused_test() {
  let text = with_mcp_server("one", "command = []")
  let assert Error("mcp.one.command must name at least the executable" <> _rest) =
    catalog.parse(text)
}

pub fn non_string_mcp_command_element_refused_test() {
  let text = with_mcp_server("one", "command = [\"x\", 3]")
  let assert Error("mcp.one.command must be an array of strings" <> _rest) =
    catalog.parse(text)
}

pub fn empty_string_mcp_command_element_refused_test() {
  let text = with_mcp_server("one", "command = [\"x\", \"\"]")
  let assert Error(
    "mcp.one.command elements must be non-empty strings" <> _rest,
  ) = catalog.parse(text)
}

pub fn non_array_mcp_command_refused_test() {
  let text = with_mcp_server("one", "command = \"x --stdio\"")
  let assert Error("mcp.one.command must be an array of strings" <> _rest) =
    catalog.parse(text)
}

pub fn unknown_mcp_key_refused_test() {
  let text = with_mcp_server("one", "command = [\"x\"]\napi_key = \"KEY\"")
  let assert Error(
    "unknown key `api_key` in mcp.one (allowed: command, api_key_env)" <> _rest,
  ) = catalog.parse(text)
}

pub fn empty_mcp_api_key_env_refused_test() {
  let text = with_mcp_server("one", "command = [\"x\"]\napi_key_env = \"\"")
  let assert Error("mcp.one.api_key_env must be non-empty" <> _rest) =
    catalog.parse(text)
}

pub fn non_table_mcp_refused_test() {
  // Prepended: appended after [roles] it would parse as roles.mcp.
  let text = "mcp = 3\n" <> minimal
  let assert Error("mcp must be a table of [mcp.<name>] entries" <> _rest) =
    catalog.parse(text)
}

pub fn trailing_slash_stripped_test() {
  let text =
    "
[models.one]
dialect = \"openai\"
base_url = \"https://inference.baseten.example/v1/\"
api_key_env = \"KEY\"
model_id = \"m-1\"
context_window = 1000
max_output_tokens = 100

[roles]
main = [\"one\"]
"
  let assert Ok(parsed) = catalog.parse(text)
  let assert Ok(entry) = catalog.find(parsed, "one")
  assert entry.base_url == "https://inference.baseten.example/v1"
}

//// The catalogue's parse-and-build contract: the committed example
//// stays parseable, strictness refuses typos in-band, defaults fill
//// deterministically, and the built gateway resolves the routed chains.

import client/catalog
import core/clock
import gleam/list
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

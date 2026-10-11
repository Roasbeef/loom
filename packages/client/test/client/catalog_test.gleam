//// The catalogue's parse-and-build contract: the committed example
//// stays parseable, strictness refuses typos in-band, defaults fill
//// deterministically, and the built gateway resolves the routed chains.

import client/catalog
import client/mcp
import core/clock
import core/json
import core/message
import core/usage_evidence
import gleam/erlang/process
import gleam/float
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import mcp/name
import provider/gateway as provider_gateway
import provider/http
import provider/internal/wire
import provider/model
import provider/pricing
import provider/secret
import provider/stream
import simplifile
import support/provider as provider_test

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
    == [
      "anthropic-opus", "baseten-kimi", "baseten-oss", "gemini-flash",
      "openai-responses",
    ]
  // Roles come back in canonical order with their chains intact.
  assert parsed.roles
    == [
      #(model.Main, ["baseten-oss", "anthropic-opus"]),
      #(model.Subagent, ["baseten-oss", "gemini-flash"]),
      #(model.Summarize, ["anthropic-opus"]),
    ]
}

pub fn example_profile_overrides_main_and_keeps_subagent_test() {
  let parsed = example()
  assert catalog.profile_names(parsed) == ["gemini"]
  let assert Ok(gemini) = catalog.select_profile(parsed, "gemini")
  assert gemini.roles
    == [
      #(model.Main, ["gemini-flash"]),
      #(model.Subagent, ["baseten-oss", "gemini-flash"]),
      #(model.Summarize, ["gemini-flash"]),
    ]
}

pub fn example_gemini_entry_takes_the_dialect_default_url_test() {
  let assert Ok(entry) = catalog.find(example(), "gemini-flash")
  assert entry.dialect == catalog.Gemini
  assert entry.base_url == "https://generativelanguage.googleapis.com/v1beta"
  assert entry.api_key_env == "GEMINI_API_KEY"
  assert entry.model_id == "gemini-3.8-flash"
  assert entry.thinking == model.ThinkingLow
  assert catalog.dialect_to_string(entry.dialect) == "gemini"
  // The gateway registers the entry under the Gemini adapter.
  let gateway =
    catalog.gateway(
      example(),
      transport: provider_test.silent(),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    )
  let assert Ok(subagent) = provider_gateway.resolve(gateway, model.Subagent)
  assert subagent.provider == "baseten-oss"
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
  assert catalog.routed_roles(parsed, "gemini-flash") == ["subagent"]
  assert catalog.active_roles(parsed, "gemini-flash") == []
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
      transport: provider_test.silent(),
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

// --- pricing ---------------------------------------------------------------

pub fn example_pricing_tables_decode_test() {
  let assert Ok(entry) = catalog.find(example(), "baseten-kimi")
  let assert Some(card) = entry.pricing
  assert card.input == 3.0
  assert card.output == 15.0

  // `0.30` is not exactly representable and the TOML parser's nearest
  // double for it differs by an ulp between Erlang builds, so the rate is
  // compared within a tolerance far tighter than a fraction of a cent
  // could ever matter. The fallback below is an equality because it is a
  // copy of `input` rather than a second parse: no `cache_write` key in
  // the table, so the input rate stands in for it.
  assert float.loosely_equals(card.cache_read, with: 0.3, tolerating: 0.000001)
  assert card.cache_write == card.input
}

pub fn a_model_with_no_pricing_table_is_unpriced_test() {
  let assert Ok(entry) = catalog.find(example(), "anthropic-opus")
  assert entry.pricing == None
}

pub fn the_gateway_prices_only_the_annotated_entries_test() {
  // The catalogue is the only place a rate card enters the gateway, so
  // "priced" has to mean the settlement carries a cost and "unpriced" has
  // to mean it does not — proven here against the costing function itself
  // rather than against a copy of its arithmetic.
  let gateway =
    catalog.gateway(
      example(),
      transport: provider_test.silent(),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    )
  let usage =
    message.Usage(
      input: 1_000_000,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      cache_write_1h: None,
      reasoning: None,
      total_tokens: 1_000_000,
      cost: message.UsageCost(
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 0.0,
      ),
      evidence: usage_evidence.priced_api(),
    )
  let assert Ok(entry) = catalog.find(example(), "baseten-kimi")
  let assert Some(card) = entry.pricing
  assert pricing.price(usage, card).cost.total == 3.0
  assert provider_gateway.card_for(gateway, "baseten-kimi") == Ok(card)
  assert provider_gateway.card_for(gateway, "anthropic-opus") == Error(Nil)
}

pub fn a_pricing_table_needs_both_required_rates_test() {
  let text = minimal <> "
[models.one.pricing]
output = 15.0
"
  assert catalog.parse(text) == Error("models.one.pricing.input is required")
}

pub fn a_negative_rate_names_the_model_and_the_key_test() {
  let text = minimal <> "
[models.one.pricing]
input = 3.0
output = -15.0
"
  let assert Error(message) = catalog.parse(text)
  assert string.contains(message, "models.one.pricing.output")
  assert string.contains(message, "must not be negative")
}

pub fn a_non_numeric_rate_names_the_model_and_the_key_test() {
  let text = minimal <> "
[models.one.pricing]
input = \"three dollars\"
output = 15.0
"
  let assert Error(message) = catalog.parse(text)
  assert string.contains(message, "models.one.pricing.input")
  assert string.contains(message, "US dollars per million tokens")
}

pub fn a_whole_dollar_rate_may_be_written_as_an_integer_test() {
  // TOML tells `3` and `3.0` apart and an operator writes the former.
  let text = minimal <> "
[models.one.pricing]
input = 3
output = 15
"
  let assert Ok(parsed) = catalog.parse(text)
  let assert Ok(entry) = catalog.find(parsed, "one")
  assert entry.pricing
    == Some(pricing.Pricing(
      input: 3.0,
      output: 15.0,
      cache_read: 3.0,
      cache_write: 3.0,
    ))
}

pub fn an_unknown_pricing_key_is_refused_test() {
  let text = minimal <> "
[models.one.pricing]
input = 3.0
output = 15.0
cache_hit = 0.3
"
  let assert Error(message) = catalog.parse(text)
  assert string.contains(message, "unknown key `cache_hit`")
  assert string.contains(message, "models.one.pricing")
}

// --- strictness ------------------------------------------------------------

const minimal =
  "
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

// Vary only the authentication fields around one otherwise valid entry, so
// each refusal proves the intended configuration boundary.
fn responses_catalogue(fields: String) -> String {
  minimal
  |> string.replace("dialect = \"anthropic\"", "dialect = \"openai-responses\"")
  |> string.replace("api_key_env = \"KEY\"", fields)
}

// Subscription configuration starts without an API-key field, so a test
// can add one deliberately and prove the parser refuses it.
fn subscription_catalogue(fields: String) -> String {
  minimal
  |> string.replace(
    "dialect = \"anthropic\"",
    "dialect = \"codex-subscription\"",
  )
  |> string.replace("api_key_env = \"KEY\"", fields)
}

pub fn responses_defaults_and_trailing_slashes_test() {
  let text = responses_catalogue("auth = \"api-key\"\napi_key_env = \"KEY\"")
  let assert Ok(parsed) = catalog.parse(text)
    as "explicit API-key Responses configuration must parse"
  let assert Ok(entry) = catalog.find(parsed, "one")
    as "the Responses entry must retain its catalogue identity"
  assert entry.dialect == catalog.OpenAiResponses
  assert entry.base_url == "https://api.openai.com/v1"
  assert catalog.dialect_to_string(entry.dialect) == "openai-responses"
  assert catalog.resolved(entry).provider == "one"
  assert entry.api_key_env == "KEY"
  assert entry.thinking == model.ThinkingOff

  let assert Ok(custom) =
    catalog.parse(responses_catalogue(
      "auth = \"api-key\"\napi_key_env = \"KEY\"\nbase_url = \"https://responses.test/v1///\"",
    ))
    as "Responses roots use the existing normalization"
  let assert Ok(custom_entry) = catalog.find(custom, "one")
    as "the custom Responses entry must exist"
  assert custom_entry.base_url == "https://responses.test/v1"
}

pub fn responses_auth_configuration_is_closed_test() {
  list.each(
    [
      #("api_key_env = \"KEY\"", "models.one.auth is required"),
      #(
        "auth = \"\"\napi_key_env = \"KEY\"",
        "models.one.auth must be non-empty",
      ),
      #("auth = 1\napi_key_env = \"KEY\"", "models.one.auth must be a string"),
      #(
        "auth = \"codex\"\napi_key_env = \"KEY\"",
        "models.one.auth must be \"api-key\" for openai-responses",
      ),
      #(
        "auth = \"unknown\"\napi_key_env = \"KEY\"",
        "models.one.auth must be \"api-key\" for openai-responses",
      ),
      #("auth = \"api-key\"", "models.one.api_key_env is required"),
      #(
        "auth = \"api-key\"\napi_key_env = \"\"",
        "models.one.api_key_env must be non-empty",
      ),
      #(
        "auth = \"api-key\"\napi_key_env = 1",
        "models.one.api_key_env must be a string",
      ),
      #(
        "auth = \"api-key\"\napi_key_env = \"KEY\"\nprofile = \"default\"",
        "models.one.profile is not supported for API-key providers",
      ),
      #(
        "auth = \"api-key\"\napi_key_env = \"KEY\"\nprofile = 1",
        "models.one.profile is not supported for API-key providers",
      ),
    ],
    fn(example) {
      assert catalog.parse(responses_catalogue(example.0)) == Error(example.1)
    },
  )
}

pub fn responses_headers_are_explicitly_refused_test() {
  let assert Error("models.one: per-model headers are not supported" <> _) =
    catalog.parse(responses_catalogue(
      "auth = \"api-key\"\napi_key_env = \"KEY\"\nheaders = { Authorization = \"not-a-credential\" }",
    ))
    as "Responses must not acquire an arbitrary credential header path"
}

pub fn subscription_profile_is_distinct_from_api_keys_test() {
  let assert Ok(parsed) =
    catalog.parse(subscription_catalogue(
      "auth = \"codex\"\nprofile = \"default\"",
    ))
    as "a complete subscription profile must parse"
  let assert Ok(entry) = catalog.find(parsed, "one")
    as "the subscription entry keeps its own catalogue identity"
  assert entry.dialect == catalog.CodexSubscription(profile: "default")
  assert catalog.dialect_to_string(entry.dialect) == "codex-subscription"
  assert entry.base_url == ""
  assert entry.api_key_env == ""
  assert catalog.resolved(entry).provider == "one"
}

pub fn subscription_auth_configuration_is_closed_test() {
  list.each(
    [
      #("auth = \"codex\"", "models.one.profile is required"),
      #(
        "auth = \"codex\"\nprofile = \"\"",
        "models.one.profile must be non-empty",
      ),
      #("auth = \"codex\"\nprofile = 1", "models.one.profile must be a string"),
      #("profile = \"default\"", "models.one.auth is required"),
      #(
        "auth = \"\"\nprofile = \"default\"",
        "models.one.auth must be non-empty",
      ),
      #("auth = 1\nprofile = \"default\"", "models.one.auth must be a string"),
      #(
        "auth = \"api-key\"\nprofile = \"default\"",
        "models.one.auth must be \"codex\" for codex-subscription",
      ),
      #(
        "auth = \"unknown\"\nprofile = \"default\"",
        "models.one.auth must be \"codex\" for codex-subscription",
      ),
      #(
        "auth = \"codex\"\nprofile = \"default\"\napi_key_env = \"KEY\"",
        "models.one.api_key_env is not supported for codex-subscription",
      ),
      #(
        "auth = \"codex\"\nprofile = \"default\"\napi_key_env = \"\"",
        "models.one.api_key_env is not supported for codex-subscription",
      ),
      #(
        "auth = \"codex\"\nprofile = \"default\"\napi_key_env = 1",
        "models.one.api_key_env is not supported for codex-subscription",
      ),
      #(
        "auth = \"codex\"\nprofile = \"default\"\nbase_url = \"https://evil.example\"",
        "models.one.base_url is not supported for codex-subscription",
      ),
      #(
        "auth = \"codex\"\nprofile = \"default\"\nbase_url = \"\"",
        "models.one.base_url is not supported for codex-subscription",
      ),
      #(
        "auth = \"codex\"\nprofile = \"default\"\nbase_url = 1",
        "models.one.base_url is not supported for codex-subscription",
      ),
    ],
    fn(example) {
      assert catalog.parse(subscription_catalogue(example.0))
        == Error(example.1)
    },
  )
  let assert Error("models.one: per-model headers are not supported" <> _) =
    catalog.parse(subscription_catalogue(
      "auth = \"codex\"\nprofile = \"default\"\nheaders = { Authorization = \"Bearer pasted-token\" }",
    ))
    as "a subscription token must not enter the model catalogue"
}

pub fn subscription_profile_uses_the_helpers_portable_name_grammar_test() {
  list.each(
    ["a", "9", "Work_2-prod", string.repeat("a", times: 64)],
    fn(profile) {
      let assert Ok(_) =
        catalog.parse(subscription_catalogue(
          "auth = \"codex\"\nprofile = \"" <> profile <> "\"",
        ))
        as "every helper-valid profile must pass catalogue loading"
    },
  )
  list.each(
    [
      ".",
      "../default",
      "a/b",
      "a\\\\b",
      "a.b",
      "a b",
      " a",
      "é",
      "aé",
      "_start",
      "-start",
      string.repeat("a", times: 65),
    ],
    fn(profile) {
      assert catalog.parse(subscription_catalogue(
          "auth = \"codex\"\nprofile = \"" <> profile <> "\"",
        ))
        == Error(
          "models.one.profile must be 1-64 ASCII letters, digits, underscores or hyphens, starting with a letter or digit",
        )
    },
  )
}

pub fn parsed_subscription_catalogue_dispatches_its_profile_test() {
  let assert Ok(parsed) =
    catalog.parse(subscription_catalogue("auth = \"codex\"\nprofile = \"work\""))
    as "a subscription profile must load before dispatch"
  let profiles = process.new_subject()
  let gateway =
    catalog.gateway(
      parsed,
      transport: provider_test.silent(),
      secrets: secret.from_list([]),
      clock: clock.fixed(0),
    )
    |> provider_gateway.with_codex_transport(
      provider_gateway.CodexTransport(
        prepare_streaming: fn(profile, _request, _events) {
          process.send(profiles, profile)
          Error("intentional test refusal")
        },
      ),
    )
  let handle =
    provider_gateway.request(
      gateway,
      model.ProviderRequest(
        target: model.ForRole(model.Main, None),
        system: None,
        messages: [],
        tools: [],
        max_output_tokens: None,
      ),
    )
  let assert Ok(#(_, stream.Failed(_, _))) =
    stream.await_terminal(handle, within: 2000)
    as "the deliberate helper refusal must settle the subscription request"
  assert process.receive(profiles, within: 1000) == Ok("work")
}

// A session role profile changes routing while both native entries retain the
// independently named credential profile. The default catalogue stays Baseten.
pub fn role_profile_routes_native_workers_and_summaries_test() {
  let text =
    "
[models.baseten]
dialect = \"openai\"
api_key_env = \"BASETEN_API_KEY\"
model_id = \"default-model\"
context_window = 128000
max_output_tokens = 8192
[models.codex-worker]
dialect = \"codex-subscription\"
auth = \"codex\"
profile = \"personal\"
model_id = \"worker-model\"
context_window = 128000
max_output_tokens = 8192
[models.codex-summary]
dialect = \"codex-subscription\"
auth = \"codex\"
profile = \"personal\"
model_id = \"summary-model\"
context_window = 128000
max_output_tokens = 8192
[roles]
main = [\"baseten\"]
subagent = [\"baseten\"]
summarize = [\"baseten\"]
[profiles.codex.roles]
subagent = [\"codex-worker\"]
summarize = [\"codex-summary\"]
"
  let assert Ok(defaults) = catalog.parse(text)
    as "The split profile must parse beside the default routes."
  let assert Ok(selected) = catalog.select_profile(defaults, "codex")
    as "The named Codex role profile must be selectable."
  assert catalog.routed_roles(defaults, "baseten")
    == ["main", "subagent", "summarize"]
  let admitted = process.new_subject()
  let gateway =
    catalog.gateway(
      selected,
      transport: provider_test.silent(),
      secrets: secret.from_list([]),
      clock: clock.fixed(0),
    )
    |> provider_gateway.with_codex_transport(
      provider_gateway.CodexTransport(
        prepare_streaming: fn(profile, _request, _events) {
          process.send(admitted, profile)
          Error("intentional test refusal")
        },
      ),
    )

  // The inherited main stays on Baseten. Each native role resolves its own
  // model entry and reaches the same protected login profile at admission.
  let assert Ok(main) = provider_gateway.resolve(gateway, model.Main)
    as "The split profile must inherit the default main route."
  assert main.provider == "baseten"
  list.each(
    [#(model.Subagent, "codex-worker"), #(model.Summarize, "codex-summary")],
    fn(pair) {
      let #(role, provider) = pair
      let assert Ok(target) = provider_gateway.resolve(gateway, role)
        as "Each native role must resolve its configured entry."
      assert target.provider == provider
      let handle =
        provider_gateway.request(
          gateway,
          model.ProviderRequest(
            target: model.ForRole(role, None),
            system: None,
            messages: [],
            tools: [],
            max_output_tokens: None,
          ),
        )
      let assert Ok(#(_, stream.Failed(_, _))) =
        stream.await_terminal(handle, within: 2000)
        as "The scripted refusal must settle after native admission."
      assert process.receive(admitted, within: 1000) == Ok("personal")
    },
  )
}

pub fn existing_dialects_keep_their_auth_contract_test() {
  list.each(["anthropic", "openai", "gemini"], fn(dialect) {
    let text =
      string.replace(
        minimal,
        "dialect = \"anthropic\"",
        "dialect = \"" <> dialect <> "\"",
      )
    let assert Ok(_) = catalog.parse(text)
      as "existing dialects must continue to accept their original configuration"
    list.each(["\"api-key\"", "\"codex\"", "1"], fn(auth) {
      assert catalog.parse(string.replace(
          text,
          "model_id =",
          "auth = " <> auth <> "\nmodel_id =",
        ))
        == Error("models.one.auth is only supported for openai-responses")
    })
    assert catalog.parse(string.replace(
        text,
        "model_id =",
        "profile = \"default\"\nmodel_id =",
      ))
      == Error("models.one.profile is not supported for API-key providers")
  })
}

pub fn responses_and_chat_completions_keep_distinct_identities_test() {
  let text =
    "[models.chat]\ndialect = \"openai\"\napi_key_env = \"CHAT_KEY\"\nmodel_id = \"shared-model\"\ncontext_window = 1000\nmax_output_tokens = 100\n"
    <> "[models.responses]\ndialect = \"openai-responses\"\nauth = \"api-key\"\napi_key_env = \"RESPONSES_KEY\"\nmodel_id = \"shared-model\"\ncontext_window = 1000\nmax_output_tokens = 100\n"
    <> "[roles]\nmain = [\"chat\", \"responses\"]\nplan = [\"responses\"]\n"
  let assert Ok(parsed) = catalog.parse(text)
    as "one catalogue must carry both OpenAI dialects"
  let gateway =
    catalog.gateway(
      parsed,
      transport: provider_test.silent(),
      secrets: secret.from_list([]),
      clock: clock.fixed(0),
    )
  let assert Ok(chat) = provider_gateway.resolve(gateway, model.Main)
    as "the Chat Completions route must resolve"
  let assert Ok(responses) = provider_gateway.resolve(gateway, model.Plan)
    as "the Responses route must resolve"
  assert chat.model_id == responses.model_id
  assert chat.provider == "chat"
  assert responses.provider == "responses"
}

pub fn parsed_responses_catalogue_dispatches_through_its_adapter_test() {
  let assert Ok(parsed) =
    catalog.parse(responses_catalogue(
      "auth = \"api-key\"\napi_key_env = \"KEY\"",
    ))
    as "the Responses configuration must load before dispatch"
  let requests = process.new_subject()
  let transport =
    provider_test.transport(fn(request, events) {
      process.send(requests, request)
      process.send(events, http.ResponseStatus(400, []))
      process.send(events, http.ResponseEnd)
    })
  let gateway =
    catalog.gateway(
      parsed,
      transport:,
      secrets: secret.from_list([#("KEY", "catalogue-test-key")]),
      clock: clock.fixed(0),
    )
  let handle =
    provider_gateway.request(
      gateway,
      model.ProviderRequest(
        target: model.ForRole(model.Main, None),
        system: None,
        messages: [],
        tools: [],
        max_output_tokens: None,
      ),
    )
  let assert Ok(#(_, stream.Failed(_, _))) =
    stream.await_terminal(handle, within: 2000)
    as "the deliberate HTTP refusal must settle the configured request"
  let assert Ok(sent) = process.receive(requests, within: 1000)
    as "the catalogue must register a usable Responses provider"
  assert sent.url == "https://api.openai.com/v1/responses"
  assert list.key_find(sent.headers, "authorization")
    == Ok("Bearer catalogue-test-key")
}

pub fn empty_document_refused_test() {
  assert catalog.parse("")
    == Error("the catalogue needs a [models.<name>] table")
}

// The top-level allow-list is the whole config file's gate, not just this
// module's: `serve.load_config` hands the same text to three parsers, but
// only this one decides which tables may appear at all. A table whose own
// parser understands it perfectly is still refused outright if it is
// missing here — which is exactly how `[[schedule]]` shipped unreachable
// once, every schedule parsing correctly behind a boot that never got
// that far. These two pin both tables the other parsers own.
pub fn a_rule_table_is_allowed_at_the_top_level_test() {
  let assert Ok(_parsed) = catalog.parse(minimal <> "
[[rule]]
name = \"r\"
triggers = [\"t\"]
body = \"b\"
") as "a [[rule]] table must not be refused by the top-level key check"
}

pub fn a_schedule_table_is_allowed_at_the_top_level_test() {
  let assert Ok(_parsed) = catalog.parse(minimal <> "
[[schedule]]
name = \"s\"
every = \"60s\"
body = \"b\"
") as "a [[schedule]] table must not be refused by the top-level key check"
}

pub fn a_daemon_profile_table_is_validated_at_the_top_level_test() {
  let assert Ok(_parsed) = catalog.parse(minimal <> "
[daemon]
profile = true
") as "the launcher-owned daemon table must be reachable through config"

  assert catalog.parse(minimal <> "
[daemon]
profile = \"yes\"
") == Error("daemon.profile must be true or false")

  let assert Error("unknown key `enabled` in [daemon]" <> _detail) =
    catalog.parse(minimal <> "
[daemon]
enabled = true
")
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

// The four shapes that pass the identifier grammar and still do not
// survive mangling: the generator digests any name it has to change, so
// each of these would become cap/mcp/<name>_<8hex> rather than the
// cap/mcp/<name> a code-mode program imports by this key.

pub fn keyword_mcp_name_refused_test() {
  let text = with_mcp_server("test", "command = [\"x\"]")
  let assert Error("mcp.test is a Gleam keyword" <> _rest) = catalog.parse(text)
}

pub fn doubled_underscore_mcp_name_refused_test() {
  let text = with_mcp_server("a__b", "command = [\"x\"]")
  let assert Error("mcp.a__b contains a doubled underscore" <> _rest) =
    catalog.parse(text)
}

pub fn trailing_underscore_mcp_name_refused_test() {
  let text = with_mcp_server("foo_", "command = [\"x\"]")
  let assert Error("mcp.foo_ ends with an underscore" <> _rest) =
    catalog.parse(text)
}

pub fn overlong_mcp_name_refused_test() {
  // 33 characters: one past the mangler's truncation bound.
  let text = with_mcp_server(string.repeat("a", 33), "command = [\"x\"]")
  let assert Error("mcp." <> rest) = catalog.parse(text)
  assert string.contains(rest, "is longer than 32 characters")
  // And the bound itself still parses.
  let at_bound = with_mcp_server(string.repeat("a", 32), "command = [\"x\"]")
  let assert Ok(parsed) = catalog.parse(at_bound)
  assert list.map(parsed.mcp_servers, fn(server) { server.name })
    == [string.repeat("a", 32)]
}

// An ordinary name is untouched: mangling is the identity on it, so the
// key names its module unchanged.
pub fn ordinary_mcp_name_parses_test() {
  let text = with_mcp_server("github", "command = [\"x\"]")
  let assert Ok(parsed) = catalog.parse(text)
  assert parsed.mcp_servers
    == [catalog.McpServer(name: "github", command: ["x"], api_key_env: None)]
}

// --- the drift gate: catalog's restated rules against the mangler ------------
//
// `client/catalog` may not import `mcp/name` — this package's parser is
// reached before any server exists and the mangler's rules are restated
// there instead: a keyword list, a doubled-underscore rule, a trailing-
// underscore rule, and a 32-character bound. The promise those four make
// is a *joint* one with `mcp/name`: on every name the catalogue accepts,
// mangling is the identity, so the `[mcp.<key>]` key really does name the
// `cap/mcp/<key>` module a code-mode program imports.
//
// A test can see both sides, so this is where they are held together. For
// every shape the catalogue refuses on mangling grounds, the mangler must
// really rewrite it; for names it accepts, the mangler must really leave
// them alone. Drop a keyword from `catalog.gleam`'s list and the first
// test fails on the parse; add one to `mcp/name`'s (or move either
// bound) and it fails on the mangle.
//
// The keyword list below is deliberately a *third* copy rather than an
// import of either. It is the referee, and a referee reading one of the
// two lists it is comparing could not tell them apart.
const mangling_keywords = [
  "as", "assert", "auto", "case", "const", "delegate", "derive", "echo", "else",
  "fn", "if", "implement", "import", "let", "macro", "opaque", "panic", "pub",
  "test", "todo", "type", "use",
]

// The production digest, not a stub: the suffix's eight characters are
// what make a rewritten name distinct, and a constant stub would let a
// mangle that changed nothing else still look like a change.
fn digest(text: String) -> String {
  mcp.sha256_hex(text)
}

pub fn every_refused_server_name_is_one_mangling_would_rewrite_test() {
  list.each(mangling_keywords, refused_and_rewritten)
  refused_and_rewritten("a__b")
  refused_and_rewritten("foo_")
  // One past the bound both sides restate.
  refused_and_rewritten(string.repeat("a", 33))
}

fn refused_and_rewritten(shape: String) -> Nil {
  let assert Error(_reason) =
    catalog.parse(with_mcp_server(shape, "command = [\"x\"]"))
    as "the catalogue must refuse a server name mangling would rewrite"
  assert name.mangle(shape, digest) != shape
}

pub fn every_accepted_server_name_survives_mangling_test() {
  // A plain name, a digit inside one, an underscore inside one, and the
  // bound itself — the shapes nearest the four rules above.
  list.each(["github", "a2", "x_y", string.repeat("a", 32)], accepted_intact)
}

fn accepted_intact(shape: String) -> Nil {
  let assert Ok(parsed) =
    catalog.parse(with_mcp_server(shape, "command = [\"x\"]"))
    as "the catalogue must accept a server name mangling leaves alone"
  assert list.map(parsed.mcp_servers, fn(server) { server.name }) == [shape]
  assert name.mangle(shape, digest) == shape
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

// --- the [tools] table -------------------------------------------------------

// The operator's egress opt-in, appended after the minimal catalogue so
// each test exercises exactly the table body it names.
fn with_tools(body: String) -> String {
  minimal <> "\n[tools]\n" <> body <> "\n"
}

pub fn a_tools_table_is_allowed_at_the_top_level_test() {
  let assert Ok(_parsed) = catalog.parse(with_tools("network = \"off\""))
    as "a [tools] table must not be refused by the top-level key check"
}

pub fn absent_tools_table_permits_network_without_inheriting_secrets_test() {
  assert catalog.parse_tools(minimal) == Ok(catalog.default_tools())
  assert catalog.parse_tools(minimal)
    == Ok(
      catalog.ToolsConfig(
        network: catalog.ToolNetworkFull,
        env: [],
        set: [],
        path: [],
      ),
    )
}

pub fn the_example_catalogue_uses_the_development_default_test() {
  let assert Ok(text) = simplifile.read(example_path)
    as "the committed example catalogue must be readable"
  assert catalog.parse_tools(text) == Ok(catalog.default_tools())
}

pub fn a_full_tools_table_parses_test() {
  let text =
    with_tools(
      "network = \"full\"\nenv = [\"GH_TOKEN\"]
path = [\"/opt/homebrew/bin\", \"/usr/local/go/bin\"]\n\n[tools.set]\nGH_CONFIG_DIR = \"/home/me/.config/gh\"",
    )
  assert catalog.parse_tools(text)
    == Ok(
      catalog.ToolsConfig(
        network: catalog.ToolNetworkFull,
        env: ["GH_TOKEN"],
        set: [#("GH_CONFIG_DIR", "/home/me/.config/gh")],
        path: ["/opt/homebrew/bin", "/usr/local/go/bin"],
      ),
    )
}

pub fn tools_set_pairs_come_back_sorted_test() {
  // The TOML dict loses file order; the constructed environment must not
  // depend on which order it hands its keys back.
  let text =
    with_tools("[tools.set]\nZ_LAST = \"z\"\nA_FIRST = \"a\"\nM_MID = \"m\"")
  let assert Ok(parsed) = catalog.parse_tools(text)
  assert list.map(parsed.set, fn(pair) { pair.0 })
    == ["A_FIRST", "M_MID", "Z_LAST"]
}

pub fn a_relative_path_entry_is_refused_test() {
  // A relative directory would resolve against the shell's working
  // directory, which is the workspace the model writes to.
  let text = "[tools]\npath = [\"bin\"]\n"
  let assert Error("tools.path entries must be absolute directories" <> _) =
    catalog.parse_tools(text)
  let twice = "[tools]\npath = [\"/opt/x\", \"/opt/x\"]\n"
  let assert Error("tools.path lists a directory twice") =
    catalog.parse_tools(twice)
}

pub fn unknown_tools_key_refused_test() {
  let assert Error("unknown key `netwrok` in [tools]" <> _rest) =
    catalog.parse_tools(with_tools("netwrok = \"full\""))
}

pub fn unknown_tools_network_word_refused_test() {
  let assert Error("tools.network must be \"off\" or \"full\"" <> _rest) =
    catalog.parse_tools(with_tools("network = \"proxy\""))
}

pub fn a_non_string_network_is_refused_test() {
  let assert Error("tools.network must be a string" <> _rest) =
    catalog.parse_tools(with_tools("network = true"))
}

pub fn empty_env_name_refused_test() {
  let assert Error("tools.env names must be non-empty" <> _rest) =
    catalog.parse_tools(with_tools("env = [\"\"]"))
}

pub fn non_string_env_entry_refused_test() {
  let assert Error(
    "tools.env must be an array of environment variable names" <> _rest,
  ) = catalog.parse_tools(with_tools("env = [1]"))
}

pub fn duplicate_env_name_refused_test() {
  let assert Error("tools.env names a variable twice" <> _rest) =
    catalog.parse_tools(with_tools("env = [\"GH_TOKEN\", \"GH_TOKEN\"]"))
}

pub fn non_string_set_value_refused_test() {
  let assert Error("tools.set.GH_HOST must be a string" <> _rest) =
    catalog.parse_tools(with_tools("[tools.set]\nGH_HOST = 1"))
}

pub fn a_name_in_both_env_and_set_refused_test() {
  let text =
    with_tools("env = [\"GH_TOKEN\"]\n\n[tools.set]\nGH_TOKEN = \"literal\"")
  let assert Error(
    "tools.GH_TOKEN is named by both `env` and [tools.set]" <> _rest,
  ) = catalog.parse_tools(text)
}

pub fn a_server_owned_name_is_refused_from_env_test() {
  let assert Error("tools.env may not name GIT_CONFIG_GLOBAL" <> _rest) =
    catalog.parse_tools(with_tools("env = [\"GIT_CONFIG_GLOBAL\"]"))

  let assert Error("tools.env may not name PATH" <> _rest) =
    catalog.parse_tools(with_tools("env = [\"PATH\"]"))
  let assert Error("tools.env may not name LOOM_SCRATCH_DIR" <> _rest) =
    catalog.parse_tools(with_tools("env = [\"LOOM_SCRATCH_DIR\"]"))
}

pub fn a_server_owned_name_is_refused_from_set_test() {
  let assert Error("tools.set may not name GIT_CONFIG_GLOBAL" <> _rest) =
    catalog.parse_tools(with_tools(
      "[tools.set]\nGIT_CONFIG_GLOBAL = \"/elsewhere\"",
    ))

  // All five names, because each is owned for its own reason and a
  // check that only covered `PATH` would look exactly like this one.
  let assert Error("tools.set may not name HOME" <> _rest) =
    catalog.parse_tools(with_tools("[tools.set]\nHOME = \"/elsewhere\""))
  let assert Error("tools.set may not name TMPDIR" <> _rest) =
    catalog.parse_tools(with_tools("[tools.set]\nTMPDIR = \"/tmp\""))
  let assert Error("tools.set may not name PATH" <> _rest) =
    catalog.parse_tools(with_tools("[tools.set]\nPATH = \"/usr/bin\""))
  let assert Error("tools.set may not name LOOM_SCRATCH_DIR" <> _rest) =
    catalog.parse_tools(with_tools("[tools.set]\nLOOM_SCRATCH_DIR = \"/tmp\""))
}

pub fn a_scalar_tools_key_is_refused_test() {
  // Prefixed rather than appended: `minimal` ends inside its [roles]
  // table, so a key written after it would be `roles.tools`.
  let assert Error("tools must be a [tools] table" <> _rest) =
    catalog.parse_tools("tools = \"full\"" <> minimal)
}

// --- the advisor role --------------------------------------------------------

pub fn the_advisor_role_parses_to_a_custom_role_test() {
  let text = minimal <> "advisor = [\"one\"]\n"
  let assert Ok(parsed) = catalog.parse(text) as "advisor is a routable role"
  assert list.key_find(parsed.roles, catalog.advisor_role) == Ok(["one"])
  assert catalog.advisor_role == model.Custom("advisor")
}

pub fn the_advisor_role_is_last_in_the_canonical_order_test() {
  // Role order is independent of the order the TOML dict hands its keys
  // back, so the advisor's place is a property of the catalogue rather
  // than of this file's layout.
  let text = minimal <> "advisor = [\"one\"]\nsummarize = [\"one\"]\n"
  let assert Ok(parsed) = catalog.parse(text)
  assert list.map(parsed.roles, fn(route) { route.0 })
    == [model.Main, model.Summarize, catalog.advisor_role]
}

pub fn an_unknown_role_names_the_advisor_among_the_routable_ones_test() {
  let assert Error(reason) = catalog.parse(minimal <> "critic = [\"one\"]\n")
    as "a role nobody routes must be refused by name"
  assert string.contains(reason, "roles.critic is not a routable role")
  assert string.contains(reason, "advisor")
}

pub fn a_routed_advisor_is_listed_by_the_key_it_was_written_under_test() {
  // Not `custom:advisor`: an operator reading a listing back should meet
  // the word they typed in `[roles]`.
  let text = minimal <> "advisor = [\"one\"]\n"
  let assert Ok(parsed) = catalog.parse(text)
  assert catalog.routed_roles(parsed, "one") == ["main", "advisor"]
  assert catalog.active_roles(parsed, "one") == ["main", "advisor"]
}

pub fn a_catalogue_without_an_advisor_routes_none_test() {
  let assert Ok(parsed) = catalog.parse(minimal)
  assert list.key_find(parsed.roles, catalog.advisor_role) == Error(Nil)
}

// --- the [advisor] table -----------------------------------------------------

// One table body appended after the minimal catalogue, so each test
// exercises exactly the body it names.
fn with_advisor(body: String) -> String {
  minimal <> "\n[advisor]\n" <> body <> "\n"
}

pub fn an_advisor_table_is_allowed_at_the_top_level_test() {
  let assert Ok(_parsed) =
    catalog.parse(with_advisor("block_cooldown_reviews = 1"))
    as "an [advisor] table must not be refused by the top-level key check"
}

pub fn an_absent_advisor_table_takes_the_read_only_default_test() {
  assert catalog.parse_advisor(minimal) == Ok(catalog.default_advisor())
  assert catalog.parse_advisor(minimal)
    == Ok(catalog.AdvisorConfig(
      tools: ["fs_read", "grep"],
      feed_every_steps: 20,
      block_cooldown_reviews: 2,
    ))
}

pub fn a_full_advisor_table_parses_test() {
  let text =
    with_advisor(
      "tools = [\"fs_read\", \"grep\", \"history_search\"]
feed_every_steps = 8
block_cooldown_reviews = 5",
    )
  assert catalog.parse_advisor(text)
    == Ok(catalog.AdvisorConfig(
      tools: ["fs_read", "grep", "history_search"],
      feed_every_steps: 8,
      block_cooldown_reviews: 5,
    ))
}

pub fn each_absent_advisor_key_falls_back_on_its_own_test() {
  assert catalog.parse_advisor(with_advisor("block_cooldown_reviews = 0"))
    == Ok(catalog.AdvisorConfig(
      tools: ["fs_read", "grep"],
      feed_every_steps: 20,
      block_cooldown_reviews: 0,
    ))
  assert catalog.parse_advisor(with_advisor("tools = [\"grep\"]"))
    == Ok(catalog.AdvisorConfig(
      tools: ["grep"],
      feed_every_steps: 20,
      block_cooldown_reviews: 2,
    ))
  assert catalog.parse_advisor(with_advisor("feed_every_steps = 3"))
    == Ok(catalog.AdvisorConfig(
      tools: ["fs_read", "grep"],
      feed_every_steps: 3,
      block_cooldown_reviews: 2,
    ))
}

// Zero is the operator asking for the run-end-only cadence the advisor
// shipped with, which is a posture rather than a threshold every step
// trivially clears.
pub fn a_zero_feed_interval_is_honoured_test() {
  assert catalog.parse_advisor(with_advisor("feed_every_steps = 0"))
    == Ok(catalog.AdvisorConfig(
      tools: ["fs_read", "grep"],
      feed_every_steps: 0,
      block_cooldown_reviews: 2,
    ))
}

pub fn a_negative_feed_interval_is_refused_test() {
  let assert Error(reason) =
    catalog.parse_advisor(with_advisor("feed_every_steps = -1"))
    as "a negative interval has no reading, so it must not be clamped"
  assert string.contains(reason, "advisor.feed_every_steps")
  assert string.contains(reason, "must not be negative")

  let assert Error("advisor.feed_every_steps must be an integer") =
    catalog.parse_advisor(with_advisor("feed_every_steps = \"twenty\""))
}

pub fn an_empty_advisor_tool_list_is_honoured_test() {
  // An advisor that only reasons over the feed it was handed is a
  // posture, not a mistake, so the empty list is not read as absence.
  assert catalog.parse_advisor(with_advisor("tools = []"))
    == Ok(catalog.AdvisorConfig(
      tools: [],
      feed_every_steps: 20,
      block_cooldown_reviews: 2,
    ))
}

pub fn an_unknown_advisor_key_is_refused_test() {
  let assert Error("unknown key `cooldown` in [advisor]" <> _rest) =
    catalog.parse_advisor(with_advisor("cooldown = 2"))
}

pub fn a_negative_cooldown_is_refused_rather_than_clamped_test() {
  let assert Error(reason) =
    catalog.parse_advisor(with_advisor("block_cooldown_reviews = -1"))
    as "a negative window has no reading, so it must not be clamped"
  assert string.contains(reason, "must not be negative")
  assert string.contains(reason, "-1")
}

pub fn a_mistyped_cooldown_is_refused_test() {
  let assert Error("advisor.block_cooldown_reviews must be an integer") =
    catalog.parse_advisor(with_advisor("block_cooldown_reviews = \"two\""))
}

pub fn a_mistyped_advisor_tool_list_is_refused_test() {
  let assert Error("advisor.tools must be an array of tool names") =
    catalog.parse_advisor(with_advisor("tools = \"grep\""))
  let assert Error("advisor.tools must be an array of tool names") =
    catalog.parse_advisor(with_advisor("tools = [1]"))
  let assert Error("advisor.tools names must be non-empty") =
    catalog.parse_advisor(with_advisor("tools = [\"\"]"))
}

pub fn a_scalar_advisor_key_is_refused_test() {
  // Prefixed rather than appended, for the reason the tools twin is:
  // `minimal` ends inside its [roles] table.
  let assert Error("advisor must be an [advisor] table") =
    catalog.parse_advisor("advisor = 2\n" <> minimal)
}

// --- the committed advisor examples ------------------------------------------

// Both shipped catalogues that route an advisor are fixtures as well as
// documentation: an `[advisor]` table that did not parse would be a
// worked example of a boot that refuses.
const advisor_example_path = "../../docs/examples/loom-advisor.toml"

const baseten_example_path = "../../docs/examples/loom-baseten.toml"

fn committed(path: String) -> String {
  let assert Ok(text) = simplifile.read(path)
    as "a committed example catalogue must be readable"
  text
}

pub fn the_advisor_example_pairs_a_fast_main_with_a_slower_advisor_test() {
  let text = committed(advisor_example_path)
  let assert Ok(parsed) = catalog.parse(text)
    as "the committed advisor example must parse"
  assert parsed.roles
    == [
      #(model.Main, ["baseten-glm-5-3-flash"]),
      #(model.Summarize, ["baseten-glm-5-3-flash"]),
      #(catalog.advisor_role, ["baseten-glm-5-3"]),
    ]
  assert catalog.parse_advisor(text) == Ok(catalog.default_advisor())
}

pub fn the_baseten_example_routes_an_advisor_test() {
  let text = committed(baseten_example_path)
  let assert Ok(parsed) = catalog.parse(text)
    as "the committed baseten example must parse"
  assert list.key_find(parsed.roles, catalog.advisor_role)
    == Ok(["baseten-glm-5-3"])
  assert catalog.parse_advisor(text) == Ok(catalog.default_advisor())
}

pub fn image_limit_defaults_and_invalid_configuration_test() {
  let assert Ok(defaults) = catalog.parse(minimal)
    as "the minimal catalogue must parse"
  let assert [entry] = defaults.models as "the fixture has one model"
  assert entry.max_images == 8
  list.each(["0", "-1", "1.5", "true", "\"8\""], fn(value) {
    let configured =
      string.replace(
        minimal,
        "[roles]",
        "max_images = " <> value <> "\n[roles]",
      )
    let assert Error(reason) = catalog.parse(configured)
      as "only positive integer image limits are accepted"
    assert string.contains(reason, "max_images")
  })
}

pub fn configured_image_limit_reaches_gateway_before_secret_lookup_test() {
  let configured = string.replace(minimal, "[roles]", "max_images = 1\n[roles]")
  let assert Ok(parsed) = catalog.parse(configured)
    as "an explicit image count must parse"
  let gw =
    catalog.gateway(
      parsed,
      provider_test.silent(),
      secret.from_list([]),
      clock.fixed(0),
    )
  let request =
    model.ProviderRequest(
      target: model.ForRole(model.Main, None),
      system: None,
      messages: [
        message.UserMessage(
          [
            message.UserImage("YQ==", "image/png"),
            message.UserImage("Yg==", "image/png"),
          ],
          0,
          Some(message.Origin("owner", "Owner")),
        ),
      ],
      tools: [],
      max_output_tokens: None,
    )
  let handle = provider_gateway.request(gw, request)
  let assert Ok(#([], stream.Failed(error:, accounting: _))) =
    stream.await_terminal(handle, within: 2000)
    as "the configured image limit must fail before missing credentials"
  let assert stream.StreamError(api_error_type: "image_limit", message:) =
    stream.underlying_error(error)
    as "this must be an image-budget error, not a missing-key error"
  assert string.contains(message, "at most 1")
}

// --- profiles ----------------------------------------------------------------

// Three models and a default role set, with one profile that replaces `main`
// and `summarize` and leaves `plan` and `vision` alone.
const with_profiles =
  "
[models.slow]
dialect = \"anthropic\"
api_key_env = \"KEY\"
model_id = \"m-slow\"
context_window = 1000
max_output_tokens = 100

[models.fast]
dialect = \"openai\"
api_key_env = \"KEY\"
model_id = \"m-fast\"
context_window = 2000
max_output_tokens = 200

[models.eyes]
dialect = \"gemini\"
api_key_env = \"KEY\"
model_id = \"m-eyes\"
context_window = 3000
max_output_tokens = 300
vision = true

[roles]
main = [\"slow\", \"fast\"]
plan = [\"slow\"]
summarize = [\"slow\"]
vision = [\"eyes\"]

[profiles.quick.roles]
main = [\"fast\"]
summarize = [\"fast\", \"slow\"]
"

pub fn profiles_default_to_none_test() {
  let assert Ok(parsed) = catalog.parse(minimal)
  assert parsed.profiles == []
  assert catalog.profile_names(parsed) == []
}

pub fn a_profile_replaces_whole_roles_and_keeps_the_rest_test() {
  let assert Ok(parsed) = catalog.parse(with_profiles)
  assert catalog.profile_names(parsed) == ["quick"]

  // The default table is untouched by the profile's existence.
  assert parsed.roles
    == [
      #(model.Main, ["slow", "fast"]),
      #(model.Plan, ["slow"]),
      #(model.Summarize, ["slow"]),
      #(model.Vision, ["eyes"]),
    ]

  // `main` and `summarize` are replaced as whole chains, not merged into the
  // default ones, `plan` and `vision` are inherited, and the order is the
  // canonical one.
  let assert Ok(quick) = catalog.select_profile(parsed, "quick")
  assert quick.roles
    == [
      #(model.Main, ["fast"]),
      #(model.Plan, ["slow"]),
      #(model.Summarize, ["fast", "slow"]),
      #(model.Vision, ["eyes"]),
    ]
  assert quick.models == parsed.models
}

pub fn selecting_a_profile_changes_the_main_model_and_the_gateway_test() {
  let assert Ok(parsed) = catalog.parse(with_profiles)
  let assert Ok(quick) = catalog.select_profile(parsed, "quick")
  let assert Ok(default_main) = catalog.main_model(parsed)
  let assert Ok(quick_main) = catalog.main_model(quick)
  assert default_main.name == "slow"
  assert quick_main.name == "fast"

  // Two gateways built from one parsed file route independently, so two
  // sessions on different profiles do not see each other's roles.
  let build = fn(catalogue) {
    catalog.gateway(
      catalogue,
      transport: provider_test.silent(),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    )
  }
  let assert Ok(default_route) =
    provider_gateway.resolve(build(parsed), model.Main)
  let assert Ok(quick_route) =
    provider_gateway.resolve(build(quick), model.Main)
  assert default_route.provider == "slow"
  assert quick_route.provider == "fast"
  let assert Ok(quick_summary) =
    provider_gateway.resolve(build(quick), model.Summarize)
  assert quick_summary.provider == "fast"
  let assert Ok(inherited) =
    provider_gateway.resolve(build(quick), model.Vision)
  assert inherited.provider == "eyes"
}

pub fn the_models_listing_roles_follow_the_profile_test() {
  let assert Ok(parsed) = catalog.parse(with_profiles)
  let assert Ok(quick) = catalog.select_profile(parsed, "quick")
  assert catalog.routed_roles(parsed, "fast") == ["main"]
  assert catalog.routed_roles(quick, "fast") == ["main", "summarize"]
  assert catalog.active_roles(quick, "fast") == ["main", "summarize"]
  assert catalog.active_roles(quick, "slow") == ["plan"]
}

pub fn an_unknown_profile_names_the_known_ones_test() {
  let assert Ok(parsed) = catalog.parse(with_profiles)
  assert catalog.select_profile(parsed, "quik")
    == Error("unknown profile \"quik\"; the configuration defines: quick")
  let assert Ok(plain) = catalog.parse(minimal)
  assert catalog.select_profile(plain, "quick")
    == Error("unknown profile \"quick\"; the configuration defines no profiles")
}

const retargeting =
  "
[models.sol]
dialect = \"openai\"
api_key_env = \"KEY\"
model_id = \"m-sol\"
context_window = 1000
max_output_tokens = 100

[models.luna]
dialect = \"openai\"
api_key_env = \"KEY\"
model_id = \"m-luna\"
context_window = 1000
max_output_tokens = 100

[models.astra]
dialect = \"openai\"
api_key_env = \"KEY\"
model_id = \"m-astra\"
context_window = 1000
max_output_tokens = 100

[models.blue]
dialect = \"openai\"
api_key_env = \"KEY\"
model_id = \"m-blue\"
context_window = 1000
max_output_tokens = 100

[roles]
main = [\"blue\"]
subagent = [\"luna\"]
summarize = [\"luna\"]

[profiles.codex.roles]
main = [\"sol\"]
advisor = [\"astra\"]

[profiles.codex-blue.roles]
main = [\"blue\"]
advisor = [\"astra\"]
"

fn retarget_pairs(
  parsed: catalog.Catalog,
  leaving: String,
  entering: String,
) -> List(#(model.Role, String, String)) {
  let select = fn(name) {
    case name == catalog.default_profile {
      True -> parsed
      False -> {
        let assert Ok(selected) = catalog.select_profile(parsed, name)
        selected
      }
    }
  }
  catalog.retargets(select(leaving), select(entering))
  |> list.map(fn(retarget) {
    #(retarget.role, retarget.from.name, retarget.to.name)
  })
}

pub fn retargets_list_the_strand_roles_whose_head_moves_test() {
  let assert Ok(parsed) = catalog.parse(retargeting)

  // Main and advisor move; subagent is inherited by both and stays.
  assert retarget_pairs(parsed, "default", "codex")
    == [
      #(model.Main, "blue", "sol"),
    ]
  assert retarget_pairs(parsed, "codex", "codex-blue")
    == [
      #(model.Main, "sol", "blue"),
    ]
}

pub fn retargets_include_the_advisor_once_both_tables_route_one_test() {
  let assert Ok(parsed) = catalog.parse(retargeting)

  // The default table routes no advisor, so there is no head to move from.
  assert retarget_pairs(parsed, "default", "codex-blue") == []
  assert retarget_pairs(parsed, "codex", "default")
    == [#(model.Main, "sol", "blue")]
}

pub fn retargets_of_a_table_with_itself_are_empty_test() {
  let assert Ok(parsed) = catalog.parse(retargeting)
  assert retarget_pairs(parsed, "codex", "codex") == []
  assert retarget_pairs(parsed, "default", "default") == []
}

pub fn retargets_follow_the_advisor_head_between_profiles_test() {
  let text =
    string.replace(
      retargeting,
      "[profiles.codex-blue.roles]\nmain = [\"blue\"]\nadvisor = [\"astra\"]",
      "[profiles.codex-blue.roles]\nmain = [\"blue\"]\nadvisor = [\"luna\"]",
    )
  let assert Ok(parsed) = catalog.parse(text)
  assert retarget_pairs(parsed, "codex", "codex-blue")
    == [
      #(model.Main, "sol", "blue"),
      #(model.Custom("advisor"), "astra", "luna"),
    ]
}

pub fn default_is_reserved_so_a_profile_cannot_shadow_it_test() {
  let text = with_profiles <> "\n[profiles.default.roles]\nmain = [\"fast\"]\n"
  let assert Error("profiles.default is reserved" <> _rest) =
    catalog.parse(text)
}

pub fn a_profile_naming_an_undefined_model_refuses_the_file_test() {
  let text = with_profiles <> "\n[profiles.broken.roles]\nmain = [\"ghost\"]\n"
  let assert Error("profiles.broken.roles.main names \"ghost\"" <> _rest) =
    catalog.parse(text)
}

pub fn a_profile_naming_an_unknown_role_refuses_the_file_test() {
  let text = with_profiles <> "\n[profiles.broken.roles]\ncritic = [\"fast\"]\n"
  let assert Error(
    "profiles.broken.roles.critic is not a routable role" <> _rest,
  ) = catalog.parse(text)
}

pub fn an_unknown_key_in_a_profile_table_is_refused_test() {
  let text = with_profiles <> "\n[profiles.broken]\nmodels = [\"fast\"]\n"
  let assert Error("unknown key `models` in profiles.broken" <> _rest) =
    catalog.parse(text)
}

pub fn a_profile_needs_a_roles_table_with_a_role_in_it_test() {
  let bare = with_profiles <> "\n[profiles.bare]\n"
  let assert Error("profiles.bare needs a [profiles.bare.roles] table") =
    catalog.parse(bare)
  let empty = with_profiles <> "\n[profiles.empty.roles]\n"
  assert catalog.parse(empty)
    == Error("profiles.empty.roles must name at least one role")
}

pub fn profile_names_follow_the_identifier_grammar_test() {
  let named = fn(name) {
    with_profiles <> "\n[profiles." <> name <> ".roles]\nmain = [\"fast\"]\n"
  }
  let assert Error("profiles.Quick is not a profile name" <> _rest) =
    catalog.parse(named("\"Quick\""))
  let assert Error("profiles.a b is not a profile name" <> _rest) =
    catalog.parse(named("\"a b\""))
  let assert Ok(parsed) = catalog.parse(named("glm-5_3"))
  assert catalog.profile_names(parsed) == ["glm-5_3", "quick"]
}

pub fn a_profile_vision_chain_must_still_read_images_test() {
  let blind =
    "
[models.blind]
dialect = \"openai\"
api_key_env = \"KEY\"
model_id = \"m-blind\"
context_window = 1000
max_output_tokens = 100
vision = false
"
  let text =
    with_profiles <> blind <> "\n[profiles.blind.roles]\nvision = [\"blind\"]\n"
  let assert Error("profiles.blind.roles.vision names \"blind\"" <> _rest) =
    catalog.parse(text)
}

pub fn a_non_table_profiles_entry_is_refused_test() {
  let text = "profiles = \"quick\"\n" <> minimal
  assert catalog.parse(text)
    == Error("profiles must be a table of [profiles.<name>.roles] entries")
}

pub fn cyber_access_values_are_typed_and_dialect_scoped_test() {
  let public = responses_catalogue("auth = \"api-key\"\napi_key_env = \"KEY\"")
  list.each(
    [
      #("standard", model.StandardCyberAccess),
      #("daybreak_blue", model.DaybreakBlue),
      #("daybreak_red", model.DaybreakRed),
    ],
    fn(pair) {
      let #(value, expected) = pair
      let assert Ok(parsed) =
        catalog.parse(string.replace(
          public,
          "model_id =",
          "cyber_access = \"" <> value <> "\"\nmodel_id =",
        ))
        as "Every documented access value must parse as a typed selection."
      let assert Ok(entry) = catalog.main_model(parsed)
        as "The configured main entry must exist."
      assert entry.cyber_access == Some(expected)
    },
  )

  // Absence leaves entitlement defaults to the server. Invalid values and
  // other dialects refuse the configuration instead of dropping the option.
  let assert Ok(defaults) = catalog.parse(public)
    as "Existing Responses catalogues must still load."
  let assert Ok(entry) = catalog.main_model(defaults)
    as "The default entry must exist."
  assert entry.cyber_access == None
  list.each(["1", "\"unknown\""], fn(value) {
    let assert Error(_) =
      catalog.parse(string.replace(
        public,
        "model_id =",
        "cyber_access = " <> value <> "\nmodel_id =",
      ))
      as "Invalid access values must be refused."
  })
  list.each(["anthropic", "openai", "gemini"], fn(dialect) {
    let text =
      minimal
      |> string.replace(
        "dialect = \"anthropic\"",
        "dialect = \"" <> dialect <> "\"",
      )
      |> string.replace(
        "model_id =",
        "cyber_access = \"daybreak_blue\"\nmodel_id =",
      )
    assert catalog.parse(text)
      == Error(
        "models.one.cyber_access is only supported for Responses dialects",
      )
  })
}

pub fn cyber_access_dispatches_each_entry_for_role_and_resolved_test() {
  let text =
    "
[models.plain]
dialect = \"openai-responses\"
auth = \"api-key\"
api_key_env = \"KEY\"
model_id = \"gpt-6-sol\"
context_window = 272000
max_output_tokens = 8192
cyber_access = \"standard\"
[models.blue]
dialect = \"codex-subscription\"
auth = \"codex\"
profile = \"personal\"
model_id = \"gpt-6-sol\"
context_window = 272000
max_output_tokens = 8192
cyber_access = \"daybreak_blue\"
[roles]
main = [\"blue\"]
plan = [\"plain\"]
"
  let assert Ok(parsed) = catalog.parse(text)
    as "Same model IDs can have distinct named access selections."
  let requests = process.new_subject()
  let transport =
    provider_test.transport(fn(sent, events) {
      process.send(requests, sent)
      process.send(events, http.ResponseStatus(403, []))
      process.send(events, http.ResponseEnd)
    })
  let gateway =
    catalog.gateway(
      parsed,
      transport:,
      secrets: secret.from_list([#("KEY", "fixture-key")]),
      clock: clock.fixed(0),
    )
    |> provider_gateway.with_codex_transport(
      provider_gateway.CodexTransport(
        prepare_streaming: fn(profile, sent, _events) {
          assert profile == "personal"
          process.send(requests, sent)
          Error("intentional native admission refusal")
        },
      ),
    )

  // The program belongs to the named endpoint, so the same underlying model
  // selects correctly through both role resolution and pinned identity dispatch.
  list.each(
    [#(model.Main, "daybreak_blue"), #(model.Plan, "standard")],
    fn(pair) {
      let #(role, program) = pair
      let assert Ok(resolved) = provider_gateway.resolve(gateway, role)
        as "Both routes must resolve."
      list.each(
        [model.ForRole(role, None), model.ForResolved(resolved)],
        fn(target) {
          let handle =
            provider_gateway.request(
              gateway,
              model.ProviderRequest(
                target:,
                system: None,
                messages: [],
                tools: [],
                max_output_tokens: None,
              ),
            )
          let assert Ok(#(_, stream.Failed(_, _))) =
            stream.await_terminal(handle, within: 2000)
            as "Each intentional refusal must settle."
          let assert Ok(sent) = process.receive(requests, within: 1000)
            as "Each dispatch must reach the intended transport."
          let assert Ok(body) = json.parse(sent.body)
            as "Requests must be valid JSON."
          assert wire.field(body, "model") == Ok(json.String("gpt-6-sol"))
          assert wire.field(body, "access_programs")
            == Ok(json.Object([#("cyber", json.String(program))]))
        },
      )
    },
  )
}

// --- model choice (protocol-change/080) --------------------------------------

pub fn model_keys_list_every_entry_sorted_test() {
  let assert Ok(parsed) = catalog.parse(with_profiles)
  assert catalog.model_keys(parsed) == ["eyes", "fast", "slow"]
}

pub fn a_model_key_beyond_the_stored_bound_is_not_offered_test() {
  let long = string.repeat("k", 65)
  let text =
    minimal
    <> "\n[models."
    <> long
    <> "]\ndialect = \"openai\"\napi_key_env = \"KEY\"\nmodel_id = \"m\"\ncontext_window = 1000\nmax_output_tokens = 100\n"
  let assert Ok(parsed) = catalog.parse(text)

  // The file still loads and the entry still exists, but a key the catalogue
  // column cannot remember with a session is not offered.
  assert list.contains(list.map(parsed.models, fn(entry) { entry.name }), long)
  assert !list.contains(catalog.model_keys(parsed), long)
}

pub fn selecting_a_model_replaces_only_main_with_that_entry_alone_test() {
  let assert Ok(parsed) = catalog.parse(with_profiles)
  let assert Ok(pinned) = catalog.select_model(parsed, "eyes")

  // `main` was a two-entry chain; it is now the chosen entry with no fallback,
  // and every other role keeps the default chain.
  assert pinned.roles
    == [
      #(model.Main, ["eyes"]),
      #(model.Plan, ["slow"]),
      #(model.Summarize, ["slow"]),
      #(model.Vision, ["eyes"]),
    ]
  assert pinned.models == parsed.models
  assert pinned.profiles == parsed.profiles
  let assert Ok(main) = catalog.main_model(pinned)
  assert main.name == "eyes"
}

pub fn a_model_is_laid_over_a_profiles_roles_test() {
  let assert Ok(parsed) = catalog.parse(with_profiles)
  let assert Ok(quick) = catalog.select_profile(parsed, "quick")
  let assert Ok(pinned) = catalog.select_model(quick, "slow")

  // The profile's `summarize` stays and only its `main` is moved.
  assert pinned.roles
    == [
      #(model.Main, ["slow"]),
      #(model.Plan, ["slow"]),
      #(model.Summarize, ["fast", "slow"]),
      #(model.Vision, ["eyes"]),
    ]
}

pub fn selecting_a_model_moves_the_gateway_without_touching_the_original_test() {
  let assert Ok(parsed) = catalog.parse(with_profiles)
  let assert Ok(pinned) = catalog.select_model(parsed, "fast")
  let build = fn(catalogue) {
    catalog.gateway(
      catalogue,
      transport: provider_test.silent(),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    )
  }
  let assert Ok(default_route) =
    provider_gateway.resolve(build(parsed), model.Main)
  let assert Ok(pinned_route) =
    provider_gateway.resolve(build(pinned), model.Main)
  assert default_route.provider == "slow"
  assert pinned_route.provider == "fast"
}

pub fn an_unknown_model_names_the_known_keys_test() {
  let assert Ok(parsed) = catalog.parse(with_profiles)
  assert catalog.select_model(parsed, "fats")
    == Error(
      "unknown model \"fats\"; the configuration defines: eyes, fast, slow",
    )
  assert catalog.unknown_model([], "x")
    == "unknown model \"x\"; the configuration defines no models"
}

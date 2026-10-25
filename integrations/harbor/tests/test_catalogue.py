"""Config generation per provider."""

import tomllib

import pytest

from loom_harbor import catalogue
from loom_harbor.catalogue import CatalogueError, Pricing, render_loom_toml, resolve_model


def rendered(spec, **kwargs):
    spec = catalogue.with_api_key_env(spec, spec.api_key_envs[0])
    return render_loom_toml(spec, **kwargs)


def test_anthropic_maps_to_the_anthropic_dialect():
    document = tomllib.loads(rendered(resolve_model("anthropic/claude-opus-4-5")))
    entry = document["models"]["harbor"]
    assert entry["dialect"] == "anthropic"
    assert entry["api_key_env"] == "ANTHROPIC_API_KEY"
    assert entry["model_id"] == "claude-opus-4-5"
    assert "base_url" not in entry
    assert "auth" not in entry
    assert document["roles"] == {"main": ["harbor"]}


def test_openai_defaults_to_responses_with_explicit_api_key_auth():
    entry = tomllib.loads(rendered(resolve_model("openai/gpt-5.2")))["models"]["harbor"]
    assert entry["dialect"] == "openai-responses"
    assert entry["auth"] == "api-key"
    assert entry["api_key_env"] == "OPENAI_API_KEY"


def test_openai_chat_completions_needs_no_auth_key():
    entry = tomllib.loads(rendered(resolve_model("openai/gpt-4o", openai_api="chat")))["models"]["harbor"]
    assert entry["dialect"] == "openai"
    assert "auth" not in entry


def test_gemini_and_google_are_the_same_provider():
    for name in ("gemini/gemini-3.8-flash", "google/gemini-3.8-flash"):
        spec = resolve_model(name)
        assert spec.dialect == "gemini"
        assert spec.api_key_envs == ("GEMINI_API_KEY", "GOOGLE_API_KEY")


def test_unknown_provider_without_base_url_is_refused_not_guessed():
    with pytest.raises(CatalogueError, match="base_url"):
        resolve_model("moonshot/kimi-k3")


def test_openai_compatible_provider_uses_the_named_endpoint_and_derived_key_name():
    spec = resolve_model("together-ai/meta/llama", base_url="https://api.together.example/v1/")
    entry = tomllib.loads(rendered(spec))["models"]["harbor"]
    assert entry["dialect"] == "openai"
    assert entry["base_url"] == "https://api.together.example/v1"
    assert entry["api_key_env"] == "TOGETHER_AI_API_KEY"
    # Only the first slash separates provider from model.
    assert entry["model_id"] == "meta/llama"


def test_explicit_key_variable_and_limits_override_the_defaults():
    spec = resolve_model(
        "anthropic/claude-x", api_key_env="MY_KEY", context_window=1_000_000, max_output_tokens=64_000
    )
    entry = tomllib.loads(rendered(spec))["models"]["harbor"]
    assert (entry["api_key_env"], entry["context_window"], entry["max_output_tokens"]) == (
        "MY_KEY", 1_000_000, 64_000,
    )


def test_defaults_are_conservative_and_documented():
    spec = resolve_model("anthropic/claude-x")
    assert spec.context_window == catalogue.DEFAULT_CONTEXT_WINDOW == 200_000
    assert spec.thinking == "off"


@pytest.mark.parametrize(
    ("effort", "thinking"),
    [(None, "off"), ("none", "off"), ("minimal", "low"), ("low", "low"), ("medium", "medium"),
     ("high", "high"), ("xhigh", "high")],
)
def test_reasoning_effort_maps_onto_thinking(effort, thinking):
    assert resolve_model("anthropic/c", reasoning_effort=effort).thinking == thinking


def test_unknown_reasoning_effort_is_refused():
    with pytest.raises(CatalogueError, match="reasoning_effort"):
        resolve_model("anthropic/c", reasoning_effort="ludicrous")


def test_pricing_table_is_rendered_only_when_given():
    plain = tomllib.loads(rendered(resolve_model("anthropic/c")))
    assert "pricing" not in plain["models"]["harbor"]
    priced = tomllib.loads(
        rendered(resolve_model("anthropic/c", pricing=Pricing(input=5.0, output=25.0, cache_read=0.5)))
    )
    assert priced["models"]["harbor"]["pricing"] == {"input": 5.0, "output": 25.0, "cache_read": 0.5}


def test_network_and_writable_mounts_are_rendered():
    document = tomllib.loads(
        rendered(resolve_model("anthropic/c"), network="off", rw_mounts=("/etc/app", "/srv/data"))
    )
    assert document["tools"]["network"] == "off"
    assert document["workspace"]["mounts"] == [
        {"path": "/etc/app", "access": "rw"},
        {"path": "/srv/data", "access": "rw"},
    ]


@pytest.mark.parametrize("path", ["relative/dir", "/", "/a/../b", "/has space", "/a\"b"])
def test_unsafe_writable_mounts_are_refused(path):
    with pytest.raises(CatalogueError, match="writable mount"):
        rendered(resolve_model("anthropic/c"), rw_mounts=(path,))


@pytest.mark.parametrize("name", ["claude", "/claude", "anthropic/", ""])
def test_malformed_model_names_are_refused(name):
    with pytest.raises(CatalogueError, match="provider/model"):
        resolve_model(name)


def test_the_file_never_contains_a_key_value(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-should-never-appear-0000")
    text = rendered(resolve_model("anthropic/claude-opus-4-5"))
    assert "sk-ant" not in text
    assert "ANTHROPIC_API_KEY" in text


def test_a_string_with_quotes_is_escaped_into_valid_toml():
    spec = resolve_model('openai/odd"model\\id')
    assert tomllib.loads(rendered(spec))["models"]["harbor"]["model_id"] == 'odd"model\\id'


def test_rendering_without_a_chosen_key_variable_is_refused():
    with pytest.raises(CatalogueError, match="no API key variable"):
        render_loom_toml(resolve_model("anthropic/c"))


@pytest.mark.parametrize("model_id", ["model-\U0001F600", "café-中文", "del\x7fchar", "tab\there"])
def test_non_ascii_and_control_characters_render_as_valid_toml(model_id):
    spec = resolve_model("openai/" + model_id)
    assert tomllib.loads(rendered(spec))["models"]["harbor"]["model_id"] == model_id


def test_a_non_bmp_character_is_not_written_as_a_surrogate_pair():
    # json.dumps' default would write 😀, which TOML rejects.
    assert "\\ud83d" not in rendered(resolve_model("openai/m-\U0001F600"))

//// Real resolution preserves catalogue paths without starting native effects.

import client/memory
import client/owned_assembly_test
import client/serve
import core/clock
import core/ids
import filepath
import gleam/option.{Some}
import gleam/string
import provider/gateway as provider_gateway
import provider/model
import simplifile
import storage/catalogue
import storage/domain

pub fn isolated_resolution_keeps_runtime_config_independent_of_domain_test() {
  assert_runtime_configuration("anthropic", "", "anthropic-messages")
}

pub fn responses_resolution_captures_the_distinct_adapter_api_test() {
  assert_runtime_configuration(
    "openai-responses",
    "auth = \"api-key\"\n",
    "openai-responses",
  )
}

// Both dialects pass through the actual saved-session resolver. Neither the
// daemon default nor the shared domain may replace that session's model facts.
fn assert_runtime_configuration(dialect: String, auth: String, api: String) {
  let fixture = owned_assembly_test.settings()
  let state = filepath.directory_name(fixture.session_path)
  let assert Ok(Nil) = simplifile.create_directory_all(state)
    as "isolated resolution directory exists"
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), 712))
  let id = ids.session_id_to_string(id)
  let runtime_config = state <> "/runtime.toml"
  let assert Ok(Nil) = simplifile.write(runtime_config, "
[models.session_b]
dialect = \"" <> dialect <> "\"
" <> auth <> "
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"session-b-model\"
context_window = 1000
max_output_tokens = 100
[roles]
main = [\"session_b\"]
") as "session B owns its runtime provider configuration"
  let record =
    catalogue.Registration(
      id,
      fixture.session_path,
      fixture.workspace,
      "Resolution",
      runtime_config,
      1,
      "resolution",
      catalogue.Saved,
      profile: option.None,
      model: option.None,
      executor: "",
      pool: "",
      subtitle: option.None,
    )
  let selected =
    domain.Domain(
      domain.key(domain.SessionOnly, record.workspace, id),
      domain.SessionOnly,
      record.workspace,
      "/missing/domain-maintenance-config-a",
      state <> "/isolated/custom-memory.sqlite",
      state <> "/separate/custom-index.sqlite",
    )
  let assert Ok(settings) =
    serve.resolve_managed(
      ["--helper", "/bin/sh", "--config", "/missing/new-daemon-config"],
      record,
      selected,
      state,
    )
    as "session B runtime ignores domain A maintenance configuration"
  assert settings.model.provider == "session_b"
  assert settings.model.model_id == "session-b-model"
  assert settings.api == api
  assert domain.digest_beside(selected.memory_path)
    == memory.digest_beside(selected.memory_path)
  assert settings.domain_paths
    == Some(serve.DomainPaths(selected.memory_path, selected.index_path))
  assert selected.memory_path
    != serve.workspace_data_root(state, record.workspace) <> "/loom-memory.db"
  assert simplifile.is_file(selected.memory_path) == Ok(False)
  assert simplifile.is_file(selected.index_path) == Ok(False)
  assert simplifile.is_file(record.path) == Ok(False)
}

// --- profiles (protocol-change/076) -----------------------------------------

const profiled_config =
  "
[models.base]
dialect = \"anthropic\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"base-model\"
context_window = 1000
max_output_tokens = 100
[models.alt]
dialect = \"openai\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"alt-model\"
context_window = 2000
max_output_tokens = 200
[roles]
main = [\"base\"]
summarize = [\"base\"]
"

const alt_profile =
  "
[profiles.alt.roles]
main = [\"alt\"]
"

// A registration over a configuration file, resolved the way the daemon's
// builder resolves one on create and on every later open.
fn resolve_profiled(
  seed: Int,
  config_text: String,
  profile: option.Option(String),
  model: option.Option(String),
) -> Result(serve.Settings, String) {
  let fixture = owned_assembly_test.settings()
  let state = filepath.directory_name(fixture.session_path)
  let assert Ok(Nil) = simplifile.create_directory_all(state)
    as "profile resolution directory exists"
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), seed))
  let id = ids.session_id_to_string(id)
  let config = state <> "/profiled-" <> id <> ".toml"
  let assert Ok(Nil) = simplifile.write(config, config_text)
    as "the profiled configuration is written"
  let record =
    catalogue.Registration(
      id,
      fixture.session_path,
      fixture.workspace,
      "Profiled",
      config,
      1,
      "profiled-" <> id,
      catalogue.Saved,
      profile:,
      model:,
      executor: "",
      pool: "",
      subtitle: option.None,
    )
  let selected =
    domain.Domain(
      domain.key(domain.SessionOnly, record.workspace, id),
      domain.SessionOnly,
      record.workspace,
      config,
      state <> "/profiled/" <> id <> "-memory.sqlite",
      state <> "/profiled/" <> id <> "-index.sqlite",
    )
  serve.resolve_managed(["--helper", "/bin/sh"], record, selected, state)
}

pub fn two_sessions_on_different_profiles_route_different_main_models_test() {
  let text = profiled_config <> alt_profile
  let assert Ok(plain) = resolve_profiled(801, text, option.None, option.None)
  let assert Ok(alt) =
    resolve_profiled(802, text, option.Some("alt"), option.None)

  // Each session starts its strand on its own main model, and neither
  // resolution leaks into the other: they are built from one file by two
  // calls and share nothing.
  assert plain.model.provider == "base"
  assert alt.model.provider == "alt"
  assert alt.model.model_id == "alt-model"
  assert alt.context_window == 2000

  // The gateway every role consumer dispatches through follows the profile
  // too, for a role the profile replaces and for one it inherits.
  let assert Ok(plain_main) =
    provider_gateway.resolve(plain.gateway, model.Main)
  let assert Ok(alt_main) = provider_gateway.resolve(alt.gateway, model.Main)
  assert plain_main.provider == "base"
  assert alt_main.provider == "alt"
  let assert Ok(alt_summary) =
    provider_gateway.resolve(alt.gateway, model.Summarize)
  assert alt_summary.provider == "base"
}

pub fn a_session_whose_profile_was_removed_is_refused_not_defaulted_test() {
  let assert Error(reason) =
    resolve_profiled(803, profiled_config, option.Some("alt"), option.None)
  assert string.contains(
    reason,
    "unknown profile \"alt\"; the configuration defines no profiles",
  )
}

pub fn a_session_with_a_profile_needs_a_config_file_test() {
  let fixture = owned_assembly_test.settings()
  let state = filepath.directory_name(fixture.session_path)
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), 804))
  let id = ids.session_id_to_string(id)
  let record =
    catalogue.Registration(
      id,
      fixture.session_path,
      fixture.workspace,
      "Profiled",
      "",
      1,
      "profiled-" <> id,
      catalogue.Saved,
      profile: option.Some("alt"),
      model: option.None,
      executor: "",
      pool: "",
      subtitle: option.None,
    )
  let selected =
    domain.Domain(
      domain.key(domain.SessionOnly, record.workspace, id),
      domain.SessionOnly,
      record.workspace,
      "",
      state <> "/profiled/" <> id <> "-memory.sqlite",
      state <> "/profiled/" <> id <> "-index.sqlite",
    )
  let assert Error(reason) =
    serve.resolve_managed(["--helper", "/bin/sh"], record, selected, state)
  assert string.contains(reason, "profile \"alt\" needs a config file")
}

// --- model choice (protocol-change/080) -------------------------------------

pub fn a_pinned_model_replaces_only_the_main_chain_test() {
  let assert Ok(plain) =
    resolve_profiled(805, profiled_config, option.None, option.None)
  let assert Ok(pinned) =
    resolve_profiled(806, profiled_config, option.None, option.Some("alt"))

  // The strand starts on the pinned entry, and the neighbouring session built
  // from the same file is unaffected.
  assert plain.model.provider == "base"
  assert pinned.model.provider == "alt"
  assert pinned.model.model_id == "alt-model"
  assert pinned.context_window == 2000

  // Only `main` moved: the role the choice did not name keeps the file's chain.
  let assert Ok(pinned_main) =
    provider_gateway.resolve(pinned.gateway, model.Main)
  let assert Ok(pinned_summary) =
    provider_gateway.resolve(pinned.gateway, model.Summarize)
  assert pinned_main.provider == "alt"
  assert pinned_summary.provider == "base"
}

pub fn a_pinned_model_is_laid_over_the_profiles_roles_test() {
  // The profile routes `main` and `summarize` to `alt`. Pinning `base` then
  // moves `main` back and leaves the profile's `summarize` in place, so the
  // model is applied after the profile and touches nothing else.
  let text = profiled_config <> "
[profiles.alt.roles]
main = [\"alt\"]
summarize = [\"alt\"]
"
  let assert Ok(settings) =
    resolve_profiled(807, text, option.Some("alt"), option.Some("base"))
  let assert Ok(main) = provider_gateway.resolve(settings.gateway, model.Main)
  let assert Ok(summary) =
    provider_gateway.resolve(settings.gateway, model.Summarize)
  assert settings.model.provider == "base"
  assert main.provider == "base"
  assert summary.provider == "alt"
}

pub fn a_session_whose_model_was_removed_is_refused_not_defaulted_test() {
  let assert Error(reason) =
    resolve_profiled(808, profiled_config, option.None, option.Some("gone"))
  assert string.contains(
    reason,
    "unknown model \"gone\"; the configuration defines: alt, base",
  )
}

pub fn a_session_with_a_model_needs_a_config_file_test() {
  let fixture = owned_assembly_test.settings()
  let state = filepath.directory_name(fixture.session_path)
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), 809))
  let id = ids.session_id_to_string(id)
  let record =
    catalogue.Registration(
      id,
      fixture.session_path,
      fixture.workspace,
      "Pinned",
      "",
      1,
      "pinned-" <> id,
      catalogue.Saved,
      profile: option.None,
      model: option.Some("alt"),
      executor: "",
      pool: "",
      subtitle: option.None,
    )
  let selected =
    domain.Domain(
      domain.key(domain.SessionOnly, record.workspace, id),
      domain.SessionOnly,
      record.workspace,
      "",
      state <> "/pinned/" <> id <> "-memory.sqlite",
      state <> "/pinned/" <> id <> "-index.sqlite",
    )
  let assert Error(reason) =
    serve.resolve_managed(["--helper", "/bin/sh"], record, selected, state)
  assert string.contains(reason, "model \"alt\" needs a config file")
}

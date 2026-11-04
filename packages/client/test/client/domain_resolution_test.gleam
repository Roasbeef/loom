//// Real resolution preserves catalogue paths without starting native effects.

import client/catalog
import client/owned_assembly_test
import client/serve
import core/clock
import core/ids
import filepath
import gleam/list
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
      pins: [],
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
  resolve_pinned(seed, config_text, profile, case model {
    option.None -> []
    option.Some(key) -> [#(catalogue.PinMain, key)]
  })
}

// The same, for a registration with any role pins (protocol-change/107).
fn resolve_pinned(
  seed: Int,
  config_text: String,
  profile: option.Option(String),
  pins: List(#(catalogue.PinnedRole, String)),
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
      pins:,
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
      pins: [],
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

// --- a profile switch (protocol-change/082) ---------------------------------

// A registration stored in a real catalogue, so the switch is the catalogue's
// own write and each resolve reads the row as the next open does.
fn stored_registration(
  seed: Int,
  profile: option.Option(String),
) -> #(catalogue.Catalogue, catalogue.Registration, domain.Domain, String) {
  let fixture = owned_assembly_test.settings()
  let state = filepath.directory_name(fixture.session_path)
  let assert Ok(Nil) = simplifile.create_directory_all(state)
    as "profile switch directory exists"
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), seed))
  let id = ids.session_id_to_string(id)
  let config = state <> "/switched-" <> id <> ".toml"
  let assert Ok(Nil) = simplifile.write(config, profiled_config <> alt_profile)
    as "the profiled configuration is written"
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record =
    catalogue.Registration(
      id:,
      path: fixture.session_path,
      workspace: fixture.workspace,
      name: "Switched",
      configuration: config,
      profile:,
      pins: [],
      executor: "",
      pool: "",
      created_at: 1,
      request_key: "switched-" <> id,
      state: catalogue.Reserved,
      subtitle: option.None,
    )
  let assert Ok(_) = catalogue.reserve(store, record) as "reserved"
  let assert Ok(saved) = catalogue.confirm(store, id) as "confirmed"
  let selected =
    domain.Domain(
      domain.key(domain.SessionOnly, saved.workspace, id),
      domain.SessionOnly,
      saved.workspace,
      config,
      state <> "/switched/" <> id <> "-memory.sqlite",
      state <> "/switched/" <> id <> "-index.sqlite",
    )
  #(store, saved, selected, state)
}

fn resolved_now(
  store: catalogue.Catalogue,
  id: String,
  selected: domain.Domain,
  state: String,
) -> serve.Settings {
  let assert Ok(record) = catalogue.get(store, id) as "the row is read"
  let assert Ok(settings) =
    serve.resolve_managed(["--helper", "/bin/sh"], record, selected, state)
    as "the stored profile resolves"
  settings
}

// The switch writes only a name, and the next open reads it: a request after
// the switch routes through the new profile's chain, a role the profile omits
// keeps the `[roles]` chain, and clearing the profile returns the session to
// the default roles. Nothing else about the registration moves.
pub fn a_stored_switch_changes_what_the_next_open_routes_test() {
  let #(store, saved, selected, state) = stored_registration(811, option.None)
  let before = resolved_now(store, saved.id, selected, state)
  assert before.model.provider == "base"

  let assert Ok(switched) =
    catalogue.set_profile(store, saved.id, option.Some("alt"))
  assert switched
    == catalogue.Registration(..saved, profile: option.Some("alt"))
  let after = resolved_now(store, saved.id, selected, state)
  assert after.model.provider == "alt"
  let assert Ok(main) = provider_gateway.resolve(after.gateway, model.Main)
  assert main.provider == "alt"
  let assert Ok(summary) =
    provider_gateway.resolve(after.gateway, model.Summarize)
  assert summary.provider == "base"
    as "a role the profile omits keeps the default chain"

  let assert Ok(_) = catalogue.set_profile(store, saved.id, option.None)
  let cleared = resolved_now(store, saved.id, selected, state)
  assert cleared.model.provider == "base"
  let assert Ok(default_main) =
    provider_gateway.resolve(cleared.gateway, model.Main)
  assert default_main.provider == "base"
  assert catalogue.close(store) == Ok(Nil)
}

// A switch to a name the file no longer defines is refused at the next open, as
// a removed profile is: the saved name is never read as the default roles.
pub fn a_switch_to_a_profile_the_file_lost_is_refused_at_open_test() {
  let #(store, saved, selected, state) = stored_registration(812, option.None)
  let assert Ok(_) = catalogue.set_profile(store, saved.id, option.Some("alt"))
  let assert Ok(Nil) = simplifile.write(selected.configuration, profiled_config)
    as "the profile is removed from the file"
  let assert Ok(record) = catalogue.get(store, saved.id)
  let assert Error(reason) =
    serve.resolve_managed(["--helper", "/bin/sh"], record, selected, state)
  assert string.contains(
    reason,
    "unknown profile \"alt\"; the configuration defines no profiles",
  )
  assert catalogue.close(store) == Ok(Nil)
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

// --- role pins (protocol-change/107) ----------------------------------------

const pinning_config =
  "
[models.base]
dialect = \"anthropic\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"base-model\"
context_window = 1000
max_output_tokens = 100
vision = false
[models.alt]
dialect = \"openai\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"alt-model\"
context_window = 2000
max_output_tokens = 200
[models.eyes]
dialect = \"gemini\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"eyes-model\"
context_window = 3000
max_output_tokens = 300
vision = true
[roles]
main = [\"base\"]
subagent = [\"base\"]
summarize = [\"base\"]
[profiles.alt.roles]
main = [\"alt\"]
subagent = [\"alt\"]
"

pub fn a_pinned_vision_role_routes_beside_a_text_only_main_test() {
  let assert Ok(settings) =
    resolve_pinned(810, pinning_config, option.None, [
      #(catalogue.PinVision, "eyes"),
    ])

  // The text-only main stays, and an image has a route that reads it.
  let assert Ok(main) = provider_gateway.resolve(settings.gateway, model.Main)
  let assert Ok(vision) =
    provider_gateway.resolve(settings.gateway, model.Vision)
  assert main.provider == "base"
  assert vision.provider == "eyes"
}

pub fn pins_resolve_again_at_every_open_test() {
  let pins = [#(catalogue.PinMain, "alt"), #(catalogue.PinVision, "eyes")]
  let assert Ok(first) = resolve_pinned(811, pinning_config, option.None, pins)
  let assert Ok(second) = resolve_pinned(811, pinning_config, option.None, pins)
  assert first.catalog.roles == second.catalog.roles
  assert list.key_find(first.catalog.roles, model.Main) == Ok(["alt"])
  assert list.key_find(first.catalog.roles, model.Vision) == Ok(["eyes"])
}

pub fn a_session_whose_pinned_entry_was_removed_is_refused_naming_the_role_test() {
  let without_eyes =
    string.replace(pinning_config, "[models.eyes]", "[models.glasses]")
  let assert Error(reason) =
    resolve_pinned(812, without_eyes, option.None, [
      #(catalogue.PinVision, "eyes"),
    ])
  assert string.contains(
    reason,
    "unknown model \"eyes\" for role \"vision\"; the configuration defines:",
  )
}

pub fn a_session_whose_pinned_vision_entry_became_text_only_is_refused_test() {
  let blinded =
    string.replace(pinning_config, "vision = true", "vision = false")
  let assert Error(reason) =
    resolve_pinned(813, blinded, option.None, [#(catalogue.PinVision, "eyes")])
  assert string.contains(
    reason,
    "model \"eyes\" cannot serve role \"vision\": it declares vision = false",
  )
}

pub fn a_profile_switch_leaves_a_pinned_role_where_it_is_test() {
  let pins = [#(catalogue.PinMain, "base"), #(catalogue.PinVision, "eyes")]
  let assert Ok(leaving) =
    resolve_pinned(814, pinning_config, option.None, pins)
  let assert Ok(entering) =
    resolve_pinned(814, pinning_config, option.Some("alt"), pins)

  // `main` is pinned to `base` on both sides, so its strands stay. `subagent`
  // follows the profile and its strands move.
  let moved = catalog.retargets(leaving.catalog, entering.catalog)
  assert list.map(moved, fn(retarget) { retarget.role }) == [model.Subagent]
  assert list.key_find(entering.catalog.roles, model.Vision) == Ok(["eyes"])
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
      pins: [#(catalogue.PinMain, "alt")],
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

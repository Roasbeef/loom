//// Real resolution preserves catalogue paths without starting native effects.

import client/memory
import client/owned_assembly_test
import client/serve
import core/clock
import core/ids
import filepath
import gleam/option.{Some}
import simplifile
import storage/catalogue
import storage/domain

pub fn isolated_resolution_keeps_runtime_config_independent_of_domain_test() {
  let fixture = owned_assembly_test.settings()
  let state = filepath.directory_name(fixture.session_path)
  let assert Ok(Nil) = simplifile.create_directory_all(state)
    as "isolated resolution directory exists"
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), 712))
  let id = ids.session_id_to_string(id)
  let runtime_config = state <> "/runtime.toml"
  let assert Ok(Nil) =
    simplifile.write(
      runtime_config,
      "
[models.session_b]
dialect = \"anthropic\"
api_key_env = \"UNUSED_TEST_KEY\"
model_id = \"session-b-model\"
context_window = 1000
max_output_tokens = 100
[roles]
main = [\"session_b\"]
",
    )
    as "session B owns its runtime provider configuration"
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

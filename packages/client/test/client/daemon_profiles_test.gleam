//// The daemon's reads of the model profiles a configuration defines, as a
//// profile switch uses them (protocol-change/082): the names to offer and the
//// catalogue a chosen profile would route by.

import broker/token
import client/catalog
import client/daemon/profiles
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/model
import simplifile

const configuration =
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

[profiles.alt.roles]
main = [\"alt\"]

[profiles.other.roles]
summarize = [\"alt\"]
"

fn written() -> String {
  let directory =
    "build/test_db/profiles-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the configuration directory exists"
  let path = directory <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(path, configuration)
    as "the configuration is written"
  path
}

pub fn the_names_a_session_may_switch_to_are_the_files_sorted_test() {
  assert profiles.names(written()) == Ok(["alt", "other"])
  assert profiles.names("") == Ok([])
}

pub fn a_chosen_profile_loads_with_its_roles_and_the_rest_inherited_test() {
  let path = written()
  let assert Ok(alt) = profiles.load(path, Some("alt"))
  assert list.key_find(alt.roles, model.Main) == Ok(["alt"])
  assert list.key_find(alt.roles, model.Summarize) == Ok(["base"])
    as "a role the profile omits keeps the default chain"

  let assert Ok(other) = profiles.load(path, Some("other"))
  assert list.key_find(other.roles, model.Main) == Ok(["base"])
  assert list.key_find(other.roles, model.Summarize) == Ok(["alt"])
}

pub fn no_profile_loads_the_default_roles_test() {
  let assert Ok(default) = profiles.load(written(), None)
  assert list.key_find(default.roles, model.Main) == Ok(["base"])
  assert catalog.profile_names(default) == ["alt", "other"]
    as "the catalogue still knows every profile it could switch to"
}

pub fn an_unknown_profile_is_refused_with_the_names_that_exist_test() {
  assert profiles.load(written(), Some("nope"))
    == Error(profiles.UnknownProfile(
      "unknown profile \"nope\"; the configuration defines: alt, other",
    ))
}

pub fn a_session_without_a_file_has_no_profiles_to_load_test() {
  assert profiles.load("", Some("alt"))
    == Error(profiles.UnknownProfile(
      "unknown profile \"alt\"; the configuration defines no profiles",
    ))
  let assert Error(profiles.UnusableConfiguration(reason)) =
    profiles.load("", None)
  assert string.contains(reason, "no configuration file")
}

pub fn a_file_that_cannot_be_read_is_the_configurations_fault_test() {
  let assert Error(profiles.UnusableConfiguration(reason)) =
    profiles.load("/absent/loom.toml", Some("alt"))
  assert string.contains(reason, "is unreadable")
}

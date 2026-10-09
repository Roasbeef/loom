//// The profile names and model keys a configuration offers a session's
//// creation (`client/daemon/profiles`, protocol-change/076 and 080), and the
//// check a creation makes against them.

import client/daemon/profiles
import client/internal/ffi_os
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import simplifile

// Two models whose secrets-bearing fields carry markers the tests look for, and
// one profile.
const config_text =
  "
[models.zeta]
dialect = \"openai\"
base_url = \"https://secret-host.example/v1\"
api_key_env = \"SECRET_KEY_VARIABLE\"
model_id = \"secret-upstream-id\"
context_window = 1000
max_output_tokens = 100

[models.alpha]
dialect = \"anthropic\"
api_key_env = \"OTHER_SECRET_VARIABLE\"
model_id = \"other-upstream-id\"
context_window = 2000
max_output_tokens = 200

[roles]
main = [\"alpha\"]

[profiles.quick.roles]
main = [\"zeta\"]
"

fn written(label: String, text: String) -> String {
  let assert Ok(here) = simplifile.current_directory() as "fixture root exists"
  let directory =
    here
    <> "/build/choices-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "choices fixture directory"
  let path = directory <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(path, text) as "choices fixture file"
  path
}

// The page is given the keys and nothing else of an entry: not its endpoint, the
// name of its key variable or its upstream identifier. The list is the whole of
// what leaves the daemon for the form.
pub fn the_keys_offered_carry_nothing_of_the_entries_test() {
  let path = written("keys", config_text)
  let assert Ok(keys) = profiles.model_keys(path)
  assert keys == ["alpha", "zeta"]
  let rendered = string.inspect(keys)
  assert !string.contains(rendered, "secret-host")
  assert !string.contains(rendered, "SECRET_KEY_VARIABLE")
  assert !string.contains(rendered, "upstream-id")
  let assert Ok(names) = profiles.names(path)
  assert names == ["quick"]
}

pub fn no_file_offers_no_keys_test() {
  assert profiles.model_keys("") == Ok([])
}

pub fn an_unreadable_or_unparseable_file_is_an_error_not_an_empty_list_test() {
  let assert Error(unreadable) =
    profiles.model_keys("/definitely/not/a/loom.toml")
  assert string.contains(unreadable, "is unreadable")
  let bad = written("bad", "[retry2]\nbogus = 1\n")
  let assert Error(unparsed) = profiles.model_keys(bad)
  assert string.contains(unparsed, "unknown key `retry2` in the top level")
}

pub fn a_model_check_names_the_keys_that_exist_test() {
  let path = written("check", config_text)
  assert profiles.check_model(path, "zeta") == Ok(Nil)
  assert profiles.check_model(path, "zetaa")
    == Error(profiles.UnknownModel(
      "unknown model \"zetaa\"; the configuration defines: alpha, zeta",
    ))
  assert profiles.check_model("", "zeta")
    == Error(profiles.UnknownModel(
      "unknown model \"zeta\"; the configuration defines no models",
    ))
}

pub fn a_creation_is_judged_for_its_profile_before_its_model_test() {
  let path = written("choice", config_text)
  assert profiles.check_choice(path, None, None) == Ok(Nil)
  assert profiles.check_choice(path, Some("quick"), Some("alpha")) == Ok(Nil)
  assert profiles.check_choice(path, None, Some("alpha")) == Ok(Nil)
  let assert Error(profiles.UnknownProfile(_)) =
    profiles.check_choice(path, Some("slow"), Some("nope"))
  let assert Error(profiles.UnknownModel(_)) =
    profiles.check_choice(path, Some("quick"), Some("nope"))

  // A creation that chose nothing reads no file, so an unusable path is not an
  // error for it.
  assert profiles.check_choice("/definitely/not/a/loom.toml", None, None)
    == Ok(Nil)
  let assert Error(profiles.UnusableConfiguration(_)) =
    profiles.check_choice("/definitely/not/a/loom.toml", None, Some("alpha"))
}

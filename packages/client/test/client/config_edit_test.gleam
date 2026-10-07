//// Real files establish the dedicated configuration edit boundary.
//// Validation and consent do not mutate files; the host rechecks the same
//// selected path and observation after approval, then publishes the save.

import client/config_edit
import client/internal/ffi_os
import gleam/int
import gleam/option.{None, Some}
import host/bootstrap
import simplifile
import tom
import tools/configuration

fn file() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the fixture has a working directory"
  here
  <> "/build/config-edit-"
  <> int.to_string(ffi_os.unique_positive_integer())
  <> ".toml"
}

fn validate(text: String) -> Result(Nil, String) {
  case tom.parse(text) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("invalid TOML")
  }
}

fn fixture() {
  let path = file()
  let assert Ok(Nil) = simplifile.write(path, "model = \"old\"\n")
    as "the selected source exists"
  let assert Ok(path) = bootstrap.canonical_path(path)
    as "the source is canonical"
  let door = config_edit.door(Some(path), validate, fn() { Ok([]) })
  let assert Ok(document) = door.read()
    as "the host exposes the selected observation"
  #(path, door, configuration.Edit(path, document.digest, "\"old\"", "\"new\""))
}

pub fn validation_does_not_write_and_approved_save_is_atomic_test() {
  let #(path, door, edit) = fixture()
  assert door.validate(edit) == Ok(Nil)
    as "the proposed complete document validates"
  assert simplifile.read(path) == Ok("model = \"old\"\n")
    as "validation leaves the original bytes"
  let assert Ok(_) = door.apply(edit)
    as "approved consent saves through the host boundary"
  assert simplifile.read(path) == Ok("model = \"new\"\n")
    as "the complete replacement is committed"
  let assert Error(_) = door.apply(edit)
    as "the same observation cannot apply twice"
}

pub fn pending_external_edit_is_never_overwritten_test() {
  let #(path, door, edit) = fixture()
  assert door.validate(edit) == Ok(Nil)
    as "the proposal validates before consent"
  let assert Ok(Nil) = simplifile.write(path, "model = \"operator\"\n")
    as "the operator changes the pending base"
  let assert Error(_) = door.apply(edit) as "approval cannot revive stale bytes"
  assert simplifile.read(path) == Ok("model = \"operator\"\n")
    as "the operator's edit is retained"
}

pub fn invalid_and_unselected_edits_never_write_test() {
  let #(path, door, edit) = fixture()
  let invalid = configuration.Edit(..edit, new: "[")
  let assert Error(_) = door.validate(invalid)
    as "invalid TOML is refused before asking"
  let assert Error(_) = door.apply(invalid)
    as "the host independently refuses invalid TOML"
  let assert Error(_) =
    door.apply(configuration.Edit(..edit, path: path <> ".other"))
    as "agent paths cannot select another file"
  assert simplifile.read(path) == Ok("model = \"old\"\n")
    as "all refusals preserve the selected bytes"
  let absent = config_edit.door(None, validate, fn() { Ok([]) })
  let assert Error(_) = absent.read()
    as "workspace files do not silently become trusted configuration"
}

pub fn editor_change_during_validation_is_detected_test() {
  let #(path, initial, edit) = fixture()
  let door =
    config_edit.door(
      Some(path),
      fn(text) {
        let assert Ok(Nil) = simplifile.write(path, "model = \"operator\"\n")
          as "the editor saves while validation runs"
        validate(text)
      },
      fn() { Ok([]) },
    )
  let assert Error(_) = door.apply(edit)
    as "the final base check follows validation"
  assert simplifile.read(path) == Ok("model = \"operator\"\n")
    as "the unrelated save survives"
  let assert Ok(_) = initial.read() as "the selected file remains available"
}

pub fn symlink_lock_cannot_redirect_host_writes_test() {
  let #(path, door, edit) = fixture()
  let target = path <> ".target"
  assert simplifile.write(target, "operator-owned") == Ok(Nil)
    as "the unrelated target exists"
  assert simplifile.create_symlink(target, config_edit.lock_path(path))
    == Ok(Nil)
    as "the test redirects the sibling lock"
  let assert Error(_) = door.apply(edit)
    as "the host refuses a redirected lock before acquisition"
  assert simplifile.read(target) == Ok("operator-owned")
    as "the unrelated target is untouched"
  assert simplifile.read(path) == Ok("model = \"old\"\n")
    as "the selected config is also untouched"
}

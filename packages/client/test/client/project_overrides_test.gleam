//// The precedence rule over a project's own settings (`client/project_overrides`):
//// the project's value, else the file's, else the default.

import client/project_overrides as overrides
import client/project_records
import client/project_settings
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tom

fn file_from(text: String) -> overrides.Values {
  let assert Ok(document) = tom.parse(text)
  let assert Ok(settings) = project_settings.from_document(document)
  overrides.file_values(settings)
}

pub fn nothing_held_gives_the_file_test() {
  let file = file_from("[project]\ncheck = \"make check\"\nmax_workers = 6\n")
  let in_force = overrides.effective(file, overrides.none)
  assert in_force == file
  assert in_force.check == Some("make check")
  assert in_force.max_workers == 6
}

pub fn a_held_value_outranks_the_file_for_that_key_only_test() {
  let file = file_from("[project]\ncheck = \"file\"\nsetup = \"file setup\"\n")
  let held = overrides.with(overrides.none, overrides.CheckIs("own"))
  let in_force = overrides.effective(file, held)
  assert in_force.check == Some("own")
  assert in_force.setup == Some("file setup")
}

pub fn a_file_that_changes_moves_every_key_the_project_does_not_hold_test() {
  let held = overrides.with(overrides.none, overrides.CheckIs("own"))
  let before =
    overrides.effective(file_from("[project]\nsetup = \"a\"\n"), held)
  let after = overrides.effective(file_from("[project]\nsetup = \"b\"\n"), held)
  assert before.check == after.check
  assert before.setup == Some("a")
  assert after.setup == Some("b")
}

pub fn the_source_says_where_each_value_came_from_test() {
  let file = file_from("[project]\ncheck = \"file\"\n")
  let held = overrides.with(overrides.none, overrides.SetupIs("own"))
  assert overrides.source_of(file, held, overrides.SetupKey)
    == overrides.FromProject
  assert overrides.source_of(file, held, overrides.CheckKey)
    == overrides.FromFile
  assert overrides.source_of(file, held, overrides.PublishKey)
    == overrides.FromDefault
}

pub fn a_file_value_equal_to_the_default_reads_as_the_default_test() {
  let file = file_from("[project]\nmax_workers = 4\n")
  assert overrides.source_of(file, overrides.none, overrides.MaxWorkersKey)
    == overrides.FromDefault
}

pub fn releasing_a_key_gives_it_back_test() {
  let held = overrides.with(overrides.none, overrides.MaxWorkersIs(9))
  assert overrides.without(held, overrides.MaxWorkersKey) == overrides.none
}

pub fn every_key_round_trips_its_words_test() {
  let words = [
    #(overrides.CheckKey, ["make check"]),
    #(overrides.SetupKey, ["make deps"]),
    #(overrides.PublishKey, ["pull_request"]),
    #(overrides.MaxWorkersKey, ["8"]),
    #(overrides.ProtectedPathsKey, ["Makefile", ".github/**"]),
  ]
  assert list.map(words, fn(each) { each.0 }) == overrides.keys
  assert result.all(
      list.map(words, fn(each) {
        overrides.parse(each.0, each.1) |> result.map(overrides.words)
      }),
    )
    == Ok(words)
}

pub fn protected_paths_may_be_held_empty_test() {
  assert overrides.parse(overrides.ProtectedPathsKey, [])
    == Ok(overrides.ProtectedPathsAre([]))
}

pub fn a_setting_record_round_trips_through_the_ledger_line_test() {
  let record =
    project_records.SettingChanged(
      key: "protected_paths",
      values: Some(["a", "b"]),
      by: "owner",
      at_ms: 12,
    )
  let line = project_records.encode_record(record)
  assert project_records.decode_line(line) == Ok(project_records.Host(record))
  let released =
    project_records.SettingChanged(
      key: "check",
      values: None,
      by: "owner",
      at_ms: 13,
    )
  assert project_records.decode_line(project_records.encode_record(released))
    == Ok(project_records.Host(released))
}

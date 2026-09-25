//// The `[[check]]` runner over a door made of closures: what a pass is,
//// both directions of a mismatch, and an answer that never came.
////
//// The runner holds no I/O beyond the door, so every property here is
//// decided without a server, and the live half — the same runner through
//// the jailed manager — is `conformance/lsp_profiles_test`.

import client/extension/manifest
import client/lsp/profile_check
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import lsp/query

// A door that answers `definition` and `references` from fixed lists,
// and refuses everything else, since a check asks nothing else.
fn door(
  definitions: Result(List(query.Site), query.QueryError),
  references: Result(List(query.Site), query.QueryError),
) -> query.Door {
  let unused = query.Unavailable("a check never asks this")
  query.Door(
    definition: fn(_asked) {
      result.map(definitions, query.Served(_, query.Warm))
    },
    references: fn(_asked) {
      use sites <- result.map(references)
      query.Served(
        list.map(sites, query.Reference(site: _, container: None)),
        query.Started("fixture"),
      )
    },
    hover: fn(_asked) { Error(unused) },
    outline: fn(_path) { Error(unused) },
    calls: fn(_asked, _direction) { Error(unused) },
    diagnostics: fn(_path) { Error(unused) },
    prepare_rename: fn(_asked, _name) { Error(unused) },
    after_write: fn(_path) { None },
  )
}

fn site(path: String, line: Int) -> query.Site {
  query.Site(path:, line:, column: 1, text: "")
}

fn check(
  query: manifest.CheckQuery,
  expect: List(#(String, Int)),
) -> manifest.Check {
  manifest.Check(
    server: "fixture",
    fixture: "fixture",
    query:,
    symbol: "util.greet",
    path: None,
    line: None,
    expect: list.map(expect, fn(pair) { manifest.Site(pair.0, pair.1) }),
  )
}

pub fn a_definition_at_the_expected_site_passes_test() {
  let answered = door(Ok([site("src/util.gleam", 1)]), Ok([]))
  assert profile_check.run(
      answered,
      check(manifest.Definition, [#("src/util.gleam", 1)]),
    )
    == profile_check.Passed
}

/// The mutation this pins is the runner comparing lists: two references
/// on one line are two sites with one `path:line`, and a server answers
/// in no order the author controls. Both must still pass.
pub fn references_compare_as_a_set_test() {
  let answered =
    door(
      Ok([]),
      Ok([
        site("src/fixture.gleam", 4),
        site("src/util.gleam", 1),
        site("src/fixture.gleam", 4),
      ]),
    )
  assert profile_check.run(
      answered,
      check(manifest.References, [
        #("src/util.gleam", 1),
        #("src/fixture.gleam", 4),
      ]),
    )
    == profile_check.Passed
}

/// A site the author expected and the server did not answer.
pub fn a_missing_site_is_a_mismatch_test() {
  let answered = door(Ok([]), Ok([site("src/util.gleam", 1)]))
  let outcome =
    profile_check.run(
      answered,
      check(manifest.References, [
        #("src/util.gleam", 1),
        #("src/main.rs", 4),
      ]),
    )
  assert outcome
    == profile_check.Mismatch(
      expected: ["src/main.rs:4", "src/util.gleam:1"],
      got: ["src/util.gleam:1"],
    )
  assert !profile_check.passed(outcome)
}

/// The other direction: the server answered a site the author did not
/// expect, which is as wrong as a missing one. An empty answer against a
/// non-empty `expect` is the case a server that is not really loaded
/// produces.
pub fn an_unexpected_site_is_a_mismatch_test() {
  let answered =
    door(Ok([site("src/util.gleam", 1), site("src/other.gleam", 9)]), Ok([]))
  assert profile_check.run(
      answered,
      check(manifest.Definition, [#("src/util.gleam", 1)]),
    )
    == profile_check.Mismatch(expected: ["src/util.gleam:1"], got: [
      "src/other.gleam:9",
      "src/util.gleam:1",
    ])
  let empty = door(Ok([]), Ok([]))
  assert profile_check.run(
      empty,
      check(manifest.Definition, [#("src/util.gleam", 1)]),
    )
    == profile_check.Mismatch(expected: ["src/util.gleam:1"], got: [])
}

pub fn a_query_error_is_errored_test() {
  let refused = door(Error(query.NoServer("gleam is not on PATH")), Ok([]))
  let outcome =
    profile_check.run(
      refused,
      check(manifest.Definition, [#("src/util.gleam", 1)]),
    )
  assert outcome == profile_check.Errored("no server: gleam is not on PATH")
  assert !profile_check.passed(outcome)
}

/// The check's own path and line reach the door: a runner that dropped
/// them would ask a bare name the fixture may hold twice.
pub fn the_check_is_asked_as_written_test() {
  let asked = fn(expected: query.SymbolQuery) {
    query.Door(..door(Ok([]), Ok([])), definition: fn(symbol_query) {
      case symbol_query == expected {
        True -> Ok(query.Served([site("src/util.rs", 1)], query.Warm))
        False -> Ok(query.Served([], query.Warm))
      }
    })
  }
  let placed =
    manifest.Check(
      ..check(manifest.Definition, [#("src/util.rs", 1)]),
      symbol: "util::greet",
      path: Some("src/main.rs"),
      line: Some(5),
    )
  assert profile_check.run(
      asked(query.SymbolQuery("util::greet", Some("src/main.rs"), Some(5))),
      placed,
    )
    == profile_check.Passed
}

pub fn every_check_runs_after_a_failure_test() {
  let answered = door(Ok([]), Ok([site("src/util.gleam", 1)]))
  let failing = check(manifest.Definition, [#("src/util.gleam", 1)])
  let passing = check(manifest.References, [#("src/util.gleam", 1)])
  let outcomes = profile_check.run_all(answered, [failing, passing])
  assert outcomes
    == [
      #(
        failing,
        profile_check.Mismatch(expected: ["src/util.gleam:1"], got: []),
      ),
      #(passing, profile_check.Passed),
    ]
}

pub fn a_check_line_names_the_question_and_both_sets_test() {
  let placed =
    manifest.Check(
      ..check(manifest.References, [#("src/util.rs", 1)]),
      symbol: "greet",
      path: Some("src/util.rs"),
      line: Some(1),
    )
  assert profile_check.describe(placed, profile_check.Passed)
    == "ok    references greet at src/util.rs:1"
  assert profile_check.describe(
      check(manifest.Definition, [#("a.go", 3)]),
      profile_check.Mismatch(expected: ["a.go:3"], got: []),
    )
    == "FAIL  definition util.greet: expected {a.go:3}, got {}"
  assert profile_check.describe(
      check(manifest.Definition, [#("a.go", 3)]),
      profile_check.Errored("the symbol was not found"),
    )
    == "FAIL  definition util.greet: the symbol was not found"
}

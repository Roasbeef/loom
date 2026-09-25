//// A profile's `[[check]]`s, asked of a running server through the door
//// the tools use (ADR-014 §5).
////
//// A language profile is a claim about how a server behaves in a jail:
//// that with exactly these roots and this environment it loads a project
//// and answers. ADR-013 was built by measuring servers rather than by
//// reading their documentation, so a profile carries its own measurement:
//// a fixture project and the answers the server must give about it. This
//// module asks those questions and judges the answers. It is the part of
//// `loom ext check` that knows nothing about processes, jails or disks.
////
//// # Why the door, and nothing below it
////
//// A check passes only if the path a model's question takes works:
//// symbol resolution, the qualified-name rule the profile configures, the
//// readiness wait after a start, the gate on what a server names. Asking
//// the server over a private client would prove a server answers, not that
//// Loom can use it. So a check is exactly one `query.Door` call, and the
//// door is the only effect here, which is also what lets a test drive the
//// runner with a door made of closures.
////
//// # Why a set
////
//// A server's answer has no order ADR-013 fixes, and two references on
//// one line (`util.greet(a) <> util.greet(b)`) are two sites with one
//// `path:line`. An author writes what a reader of the fixture sees: which
//// lines mention the symbol. So both sides are compared as sets of
//// `path:line`, and a mismatch shows both sets sorted, so the difference
//// can be read off a terminal.
////
//// # Paths are the fixture's
////
//// `expect` names fixture-relative paths, and the door answers
//// workspace-relative ones. The two agree because the caller makes the
//// fixture's copy the whole workspace: its root is the scratch
//// workspace's root. A site outside it comes back absolute, matches
//// nothing an author could have written, and fails the check, which is
//// the right answer for a server that wandered out of its project.

import client/extension/manifest.{type Check}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import lsp/query.{type Door, type QueryError}

/// What one check's question came back as.
pub type CheckOutcome {
  /// The answer's sites equal `expect` as a set of `path:line`.
  Passed

  /// The server answered, and its sites differ from `expect`. Both are
  /// `path:line` sets, sorted and each listed once.
  Mismatch(expected: List(String), got: List(String))

  /// The question produced no answer. The reason is the query error in
  /// one line, worded for the operator running the check.
  Errored(reason: String)
}

/// Asks one check's question through `door` and judges the answer.
///
/// `definition` compares the definition sites; `references` compares
/// every reference's site, the declaration included, which is what the
/// door answers and what an author sees in the fixture.
///
/// ## Examples
///
/// ```gleam
/// // profile_check.run(door, manifest.Check(server: "go", fixture: "fixture",
/// //   query: manifest.Definition, symbol: "util.Greet", path: None,
/// //   line: None, expect: [manifest.Site("util/util.go", 3)]))
/// // -> Passed
/// ```
///
pub fn run(door: Door, check: Check) -> CheckOutcome {
  let asked = query.SymbolQuery(check.symbol, check.path, check.line)
  let answered = case check.query {
    manifest.Definition ->
      door.definition(asked) |> result.map(fn(served) { served.value })
    manifest.References ->
      door.references(asked)
      |> result.map(fn(served) {
        list.map(served.value, fn(reference) { reference.site })
      })
  }
  case answered {
    Error(error) -> Errored(reason: describe_error(error))
    Ok(sites) ->
      judged(
        expected: list.map(check.expect, fn(site) {
          site_text(site.path, site.line)
        }),
        got: list.map(sites, fn(site) { site_text(site.path, site.line) }),
      )
  }
}

/// Runs every check in order, each paired with its outcome.
///
/// A failed check does not stop the rest: an author fixing a profile
/// wants every wrong answer at once, not one per run.
///
/// ## Examples
///
/// ```gleam
/// // profile_check.run_all(door, manifest.checks)
/// // -> [#(check, Passed), #(other, Mismatch(["a.go:3"], []))]
/// ```
///
pub fn run_all(
  door: Door,
  checks: List(Check),
) -> List(#(Check, CheckOutcome)) {
  list.map(checks, fn(check) { #(check, run(door, check)) })
}

/// Whether an outcome is a pass. The one question the verb's exit code
/// asks of it.
///
/// ## Examples
///
/// ```gleam
/// assert profile_check.passed(profile_check.Passed)
/// assert !profile_check.passed(profile_check.Errored("no server"))
/// ```
///
pub fn passed(outcome: CheckOutcome) -> Bool {
  case outcome {
    Passed -> True
    Mismatch(..) | Errored(..) -> False
  }
}

/// The line `loom ext check` prints for one check: `ok` or `FAIL`, the
/// query and its symbol (with the path and line it was asked from, when
/// the check names them), and for a failure what went wrong. A mismatch
/// prints both sets, so the difference is on the line itself.
///
/// ## Examples
///
/// ```gleam
/// profile_check.describe(check, profile_check.Mismatch(["a.go:3"], []))
/// // -> "FAIL  definition util.Greet: expected {a.go:3}, got {}"
/// ```
///
pub fn describe(check: Check, outcome: CheckOutcome) -> String {
  let asked = query_text(check)
  case outcome {
    Passed -> "ok    " <> asked
    Mismatch(expected:, got:) ->
      "FAIL  "
      <> asked
      <> ": expected "
      <> set_text(expected)
      <> ", got "
      <> set_text(got)
    Errored(reason:) -> "FAIL  " <> asked <> ": " <> reason
  }
}

// The comparison itself. Both sides become sets before they meet, so
// order and repetition, which neither the server nor the author controls
// the same way, cannot fail a check whose lines are right.
fn judged(
  expected expected: List(String),
  got got: List(String),
) -> CheckOutcome {
  let wanted = set.from_list(expected)
  let found = set.from_list(got)
  case wanted == found {
    True -> Passed
    False -> Mismatch(expected: sorted(wanted), got: sorted(found))
  }
}

fn sorted(sites: set.Set(String)) -> List(String) {
  set.to_list(sites) |> list.sort(string.compare)
}

fn site_text(path: String, line: Int) -> String {
  path <> ":" <> int.to_string(line)
}

fn set_text(sites: List(String)) -> String {
  "{" <> string.join(sites, ", ") <> "}"
}

fn query_text(check: Check) -> String {
  let verb = case check.query {
    manifest.Definition -> "definition"
    manifest.References -> "references"
  }
  let from = case check.path, check.line {
    option.Some(path), option.Some(line) -> " at " <> site_text(path, line)
    option.Some(path), option.None -> " in " <> path
    option.None, _ -> ""
  }
  verb <> " " <> check.symbol <> from
}

// One line per error, for an operator rather than a model: the tools'
// rendering (`tools/lsp.render_error`) carries advice about which tool to
// use next, which is the wrong reader here, and an ambiguous answer's
// candidates go on the same line so the check's output stays one line
// per check.
fn describe_error(error: QueryError) -> String {
  case error {
    query.NoServer(reason:) -> "no server: " <> reason
    query.Unsupported(server:, request:) ->
      "the " <> server <> " server does not support " <> request
    query.NotFound(query: _) -> "the symbol was not found"
    query.Ambiguous(candidates:) ->
      "ambiguous between "
      <> set_text(
        list.map(candidates, fn(site) { site_text(site.path, site.line) }),
      )
    query.ServerRefused(message:) -> "the server refused: " <> message
    query.Unavailable(reason:) -> "unavailable: " <> reason
  }
}

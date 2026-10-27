//// Reads a test run's output as data: which tests ran, and how each ended.
////
//// A mined task is graded by test identity. "These tests failed before the
//// fix and pass after it" is the whole claim a regression task makes, so the
//// miner and, later, the verifier both need to turn the text a test command
//// printed into a set of ids without trusting anything about how the text
//// was produced. This module is that reading, and it is pure: the same bytes
//// always give the same report, and no input can make it fail.
////
//// Two output shapes are understood, because the repository has two ways to
//// run a package's tests and they disagree about what they print.
////
//// - `scripts/test.sh` runs EUnit verbosely. Every test gets a line,
////   `  lint_test: r1_flags_test...[0.001 s] ok` or `...*failed*`, and a run
////   ends with `All N tests passed.` or `Failed: F.  Skipped: S.  Passed: P.`
////   This is the shape a verifier needs, because a pass-to-pass test is one
////   the output *names* as passing.
//// - Raw `gleam test` (gleeunit) prints a dot per pass and names only the
////   failures, ` test: machine@failure_test.some_fn`, followed by
////   `77 passed, 2 failures`. It cannot say which tests passed, so a report
////   read from it has failures and a summary and nothing else.
////
//// Both are read after ANSI escapes are stripped, because gleeunit colours
//// its lines and a pattern anchored on a colour code would miss them the
//// day the terminal changed. A test id is `<module>.<function>` with the
//// Erlang module name as printed (`machine@failure_test.fn`), the same text
//// in either shape, so an id lifted from one run can be looked up in
//// another.
////
//// The reader is deliberately forgiving about lines it does not recognise
//// and deliberately strict about the ones it does: an unrecognised line is
//// skipped, but a recognised result line is never guessed at.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// How one test ended.
pub type Outcome {
  /// The test body returned normally.
  Passed

  /// The test raised, timed out, or was aborted.
  Failed

  /// EUnit did not run the test (skipped, or cancelled by a failed fixture).
  Skipped
}

/// The counts a run printed about itself.
pub type Summary {
  Summary(
    /// How many tests the run says passed.
    passed: Int,
    /// How many tests the run says failed.
    failed: Int,
    /// How many tests the run says it skipped.
    skipped: Int,
  )
}

/// Everything readable from one run's output.
pub type TestReport {
  TestReport(
    /// One entry per recognised result line, in print order. Raw gleeunit
    /// output contributes failures only.
    results: List(#(String, Outcome)),
    /// The totals the run printed, summed when several runs were
    /// concatenated into one text, or `None` when no totals line was found
    /// (a compile failure prints none).
    summary: Option(Summary),
  )
}

/// Reads a test run's output. Total: any text at all yields a report, and a
/// text with nothing recognisable yields an empty one.
///
/// ## Examples
///
/// ```gleam
/// let report = eunit_ids.parse("  lint_test: a_test...ok\n  All 1 tests passed.")
/// assert report.results == [#("lint_test.a_test", eunit_ids.Passed)]
/// ```
///
pub fn parse(output: String) -> TestReport {
  let lines =
    output
    |> strip_ansi
    |> string.split("\n")
    |> list.map(string.trim)

  let script = list.filter_map(lines, script_result)
  let raw = list.filter_map(lines, raw_failure)
  let summaries = list.filter_map(lines, summary_line)

  TestReport(
    results: list.append(script, raw),
    summary: sum_summaries(summaries),
  )
}

/// The ids in a report that ended a given way, in print order.
///
/// ## Examples
///
/// ```gleam
/// // eunit_ids.ids(report, eunit_ids.Failed) == ["lint_test.a_test"]
/// ```
///
pub fn ids(report: TestReport, outcome: Outcome) -> List(String) {
  report.results
  |> list.filter(fn(entry) { entry.1 == outcome })
  |> list.map(fn(entry) { entry.0 })
}

/// How one id ended, or `Error(Nil)` when the report never names it. When a
/// text names an id twice the last line wins, which is the retry a runner
/// printed after the first attempt.
///
/// ## Examples
///
/// ```gleam
/// // eunit_ids.outcome(report, "lint_test.a_test") == Ok(eunit_ids.Passed)
/// ```
///
pub fn outcome(report: TestReport, id: String) -> Result(Outcome, Nil) {
  report.results
  |> list.reverse
  |> list.key_find(id)
}

/// Removes ANSI escape sequences. A sequence is ESC, `[`, parameter bytes,
/// and one final byte in `@` through `~`; a bare ESC with nothing after it
/// is dropped alone.
///
/// ## Examples
///
/// ```gleam
/// assert eunit_ids.strip_ansi("\u{1b}[31mred\u{1b}[0m") == "red"
/// ```
///
pub fn strip_ansi(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> drop_escapes([])
  |> string.from_utf_codepoints
}

/// Walks the codepoints keeping everything outside an escape sequence. ESC
/// opens a sequence and `skip_sequence` decides how much of the following text
/// it owns, so the scan is one pass and cannot loop.
fn drop_escapes(
  remaining: List(UtfCodepoint),
  kept: List(UtfCodepoint),
) -> List(UtfCodepoint) {
  case remaining {
    [] -> list.reverse(kept)

    [first, ..rest] ->
      case string.utf_codepoint_to_int(first) {
        27 -> drop_escapes(skip_sequence(rest), kept)
        _ -> drop_escapes(rest, [first, ..kept])
      }
  }
}

/// Decides what follows an ESC. `[` opens a control sequence that runs to its
/// final byte; any other follower means a bare ESC, which is dropped alone so
/// the next codepoint survives.
fn skip_sequence(after_escape: List(UtfCodepoint)) -> List(UtfCodepoint) {
  case after_escape {
    [opener, ..rest] ->
      case string.utf_codepoint_to_int(opener) {
        91 -> skip_to_final(rest)
        _ -> after_escape
      }

    [] -> []
  }
}

/// Drops a control sequence's parameter bytes up to and including its final
/// byte (`@` through `~`). Input that ends first leaves nothing, because a
/// truncated sequence is not text.
fn skip_to_final(remaining: List(UtfCodepoint)) -> List(UtfCodepoint) {
  // The scan ends at the first final byte; running out of input first means the sequence was cut off, and the rest is dropped with it.
  case remaining {
    [] -> []

    [first, ..rest] -> {
      let code = string.utf_codepoint_to_int(first)

      // A final byte ends the sequence and is itself part of it.
      case code >= 64 && code <= 126 {
        True -> rest
        False -> skip_to_final(rest)
      }
    }
  }
}

/// Reads one EUnit verbose line, `module: name...[0.001 s] ok`. The verdict
/// must sit at the end of the line so a source excerpt inside a failure report
/// that happens to contain `...` is not mistaken for a result. `Error(Nil)` for
/// any line that is not a result.
fn script_result(line: String) -> Result(#(String, Outcome), Nil) {
  use #(head, tail) <- result.try(string.split_once(line, "..."))
  use outcome <- result.try(outcome_word(drop_timing(tail)))
  use #(module, name) <- result.try(string.split_once(head, ": "))
  use module <- result.try(module_name(module))

  // A generator test prints its description after the function name, and the description is not part of the identity.
  let name = case string.split_once(name, " (") {
    Ok(#(before, _description)) -> before
    Error(Nil) -> name
  }

  // A name with a space is a description, not a function, so the line is prose and not a result.
  case name == "" || string.contains(name, " ") {
    True -> Error(Nil)
    False -> Ok(#(module <> "." <> name, outcome))
  }
}

/// Removes the `[0.001 s] ` EUnit prints before the verdict of a test that took
/// long enough to time.
fn drop_timing(tail: String) -> String {
  case string.starts_with(tail, "[") {
    True ->
      case string.split_once(tail, "] ") {
        Ok(#(_timing, verdict)) -> verdict
        Error(Nil) -> tail
      }

    False -> tail
  }
}

/// Maps EUnit's verdict word to an outcome. Every `*...*` marker other than
/// skipped or did-not-run is a failure, so a timeout or abort can never read as
/// a pass.
fn outcome_word(word: String) -> Result(Outcome, Nil) {
  case string.trim(word) {
    "ok" -> Ok(Passed)
    "*skipped*" | "*did not run*" -> Ok(Skipped)
    "*failed*" | "*timed out*" | "*aborted*" -> Ok(Failed)
    _ -> Error(Nil)
  }
}

/// The module part of a result line. EUnit may print `module:LINE` for a fun-
/// style test, and the line number is not part of the identity.
fn module_name(raw: String) -> Result(String, Nil) {
  // EUnit may print `module:LINE` for a fun-style test; only the module is identity.
  let module = case string.split_once(raw, ":") {
    Ok(#(before, _line)) -> before
    Error(Nil) -> raw
  }

  // A module name never contains a space; one that does means this was not a test line.
  case module == "" || string.contains(module, " ") {
    True -> Error(Nil)
    False -> Ok(module)
  }
}

/// Reads one gleeunit failure line, ` test: machine@failure_test.some_fn`. Only
/// a line that begins with the marker counts, and the id must look like
/// `module.function`.
fn raw_failure(line: String) -> Result(#(String, Outcome), Nil) {
  use id <- result.try(string.split_once(line, "test: "))

  // Only a line that begins with the marker names a failure; the same words inside a source excerpt must not count.
  case id.0 == "" {
    False -> Error(Nil)
    True ->
      case string.contains(id.1, ".") && !string.contains(id.1, " ") {
        True -> Ok(#(id.1, Failed))
        False -> Error(Nil)
      }
  }
}

/// Recognises the totals line of either shape.
fn summary_line(line: String) -> Result(Summary, Nil) {
  case line {
    "Test passed." -> Ok(Summary(passed: 1, failed: 0, skipped: 0))
    "All " <> rest -> all_passed(rest)
    "Failed: " <> _ -> eunit_counts(line)
    _ -> gleeunit_counts(line)
  }
}

/// Reads the tail of `All N tests passed.`.
fn all_passed(rest: String) -> Result(Summary, Nil) {
  use #(count, tail) <- result.try(string.split_once(rest, " "))
  use passed <- result.try(int.parse(count))

  // `All N tests passed.` is the whole sentence; anything after the count is not this summary.
  case tail {
    "tests passed." -> Ok(Summary(passed:, failed: 0, skipped: 0))
    _ -> Error(Nil)
  }
}

/// Reads `Failed: 1.  Skipped: 0.  Passed: 41.`. The labels may come in any
/// order and unknown labels are ignored; a line missing `Failed` or `Passed` is
/// not a summary.
fn eunit_counts(line: String) -> Result(Summary, Nil) {
  let clauses =
    line
    |> string.split(".")
    |> list.filter_map(fn(clause) {
      use #(label, count) <- result.try(string.split_once(clause, ": "))
      use count <- result.map(int.parse(string.trim(count)))
      #(string.trim(label), count)
    })

  use failed <- result.try(list.key_find(clauses, "Failed"))
  use passed <- result.map(list.key_find(clauses, "Passed"))
  let skipped = result.unwrap(list.key_find(clauses, "Skipped"), 0)
  Summary(passed:, failed:, skipped:)
}

/// Reads gleeunit's totals: `77 passed, 2 failures`, `79 passed, no failures`
/// or `1 passed, 1 failure`. gleeunit never reports skips.
fn gleeunit_counts(line: String) -> Result(Summary, Nil) {
  use #(passed, tail) <- result.try(string.split_once(line, " passed, "))
  use passed <- result.try(int.parse(passed))

  // gleeunit prints `no failures` or `N failures`; any other tail is not its summary.
  use failed <- result.map(case tail {
    "no failures" -> Ok(0)
    _ -> {
      use #(count, word) <- result.try(string.split_once(tail, " "))

      // The count is only a count when its unit is the word failure or failures.
      case word {
        "failure" | "failures" -> int.parse(count)
        _ -> Error(Nil)
      }
    }
  })

  Summary(passed:, failed:, skipped: 0)
}

/// Adds the totals of several runs. A text with none has no summary, which is
/// how a compile failure reads.
fn sum_summaries(summaries: List(Summary)) -> Option(Summary) {
  case summaries {
    [] -> None

    _ ->
      Some(
        list.fold(summaries, Summary(0, 0, 0), fn(total, one) {
          Summary(
            passed: total.passed + one.passed,
            failed: total.failed + one.failed,
            skipped: total.skipped + one.skipped,
          )
        }),
      )
  }
}

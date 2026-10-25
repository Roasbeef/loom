//// Tests for the reader of test-run output: the verbose EUnit shape that
//// `scripts/test.sh` prints, the raw gleeunit shape, and the guarantee that
//// no text at all can make the reader fail.

import eval/eunit_ids.{Failed, Passed, Skipped, Summary}
import gleam/option.{None, Some}
import gleam/string
import qcheck
import simplifile

const fuzz_seed = 91

fn fixture(name: String) -> String {
  let assert Ok(text) = simplifile.read("test/fixtures/" <> name)
    as "fixture text is committed beside the tests"
  text
}

pub fn eunit_parses_script_output_test() {
  let report = eunit_ids.parse(fixture("test_script_failure.txt"))

  assert eunit_ids.ids(report, Failed)
    == ["lint_test.r1_does_not_nest_code_spans_in_the_require_advice_test"]
  assert eunit_ids.outcome(report, "lint_test.r10_gates_a_welded_comment_test")
    == Ok(Passed)
  assert report.summary == Some(Summary(passed: 41, failed: 1, skipped: 0))
  assert eunit_ids.outcome(report, "lint_test.no_such_test") == Error(Nil)
}

pub fn eunit_parses_raw_gleam_output_test() {
  let report = eunit_ids.parse(fixture("gleeunit_raw_failure.txt"))

  assert report.results
    == [
      #(
        "machine@failure_test.threshold_summarizer_unresolved_keeps_the_run_alive_test",
        Failed,
      ),
      #(
        "machine@failure_test.threshold_summary_failure_past_the_ladder_keeps_the_run_alive_test",
        Failed,
      ),
    ]
  assert report.summary == Some(Summary(passed: 77, failed: 2, skipped: 0))
}

pub fn eunit_reads_skips_and_all_passed_test() {
  let report =
    eunit_ids.parse(
      "  m_test: a_test...ok\n  m_test: b_test...*skipped*\n  m_test: c_test...[0.5 s] ok\n  Failed: 0.  Skipped: 1.  Passed: 2.\n",
    )

  assert eunit_ids.ids(report, Skipped) == ["m_test.b_test"]
  assert eunit_ids.ids(report, Passed) == ["m_test.a_test", "m_test.c_test"]
  assert report.summary == Some(Summary(passed: 2, failed: 0, skipped: 1))
  assert eunit_ids.parse("  All 7 tests passed.\n").summary
    == Some(Summary(passed: 7, failed: 0, skipped: 0))
  assert eunit_ids.parse("79 passed, no failures").summary
    == Some(Summary(passed: 79, failed: 0, skipped: 0))
}

pub fn eunit_sums_concatenated_runs_test() {
  let report =
    eunit_ids.parse(
      "  All 2 tests passed.\nFailed: 1.  Skipped: 0.  Passed: 3.",
    )

  assert report.summary == Some(Summary(passed: 5, failed: 1, skipped: 0))
}

pub fn eunit_strips_ansi_test() {
  assert eunit_ids.strip_ansi("\u{1b}[31mred\u{1b}[0m and \u{1b}plain")
    == "red and plain"
  assert eunit_ids.parse("compile error\n").summary == None
}

pub fn eunit_parse_is_total_test() {
  qcheck.run(
    qcheck.default_config()
      |> qcheck.with_test_count(300)
      |> qcheck.with_seed(qcheck.seed(fuzz_seed)),
    qcheck.string(),
    fn(text) {
      let report = eunit_ids.parse(text <> "\n  m: t_test...ok")

      assert eunit_ids.outcome(report, "m.t_test") == Ok(Passed)
        || string.contains(text, "\u{1b}")
    },
  )
}

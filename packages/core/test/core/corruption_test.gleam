import core/corruption
import gleam/string

pub fn report_builds_the_record_test() {
  let report =
    corruption.report(
      at: "core/json.parse",
      on: "offset 3",
      expected: "a digit",
      context: "\"x\"",
    )
  assert report.boundary == "core/json.parse"
  assert report.subject == "offset 3"
  assert report.expected == "a digit"
  assert report.context == "\"x\""
}

pub fn describe_renders_one_line_test() {
  let report = corruption.report(at: "b", on: "s", expected: "e", context: "c")
  assert corruption.describe(report)
    == "corruption at b (s): expected e, got: c"
}

pub fn report_bounds_oversized_context_test() {
  // A context slice of adversarial input is truncated to the documented
  // bound, so a hostile payload cannot bloat logs or persisted reports.
  let huge = string.repeat("x", corruption.max_context_length * 100)
  let report = corruption.report(at: "b", on: "s", expected: "e", context: huge)
  assert string.length(report.context) == corruption.max_context_length + 1
  assert string.ends_with(report.context, "…")
}

pub fn report_keeps_context_at_the_bound_test() {
  let exact = string.repeat("y", corruption.max_context_length)
  let report =
    corruption.report(at: "b", on: "s", expected: "e", context: exact)
  assert report.context == exact
}

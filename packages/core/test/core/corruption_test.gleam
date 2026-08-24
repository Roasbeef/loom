import core/corruption

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

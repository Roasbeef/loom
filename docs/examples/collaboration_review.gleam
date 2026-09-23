//// A resident review coordinator. Submit this file as a background code-mode
//// program, then send a `review` input after readiness reports that endpoint.
////
//// The two named child operations hold durable review results. This satellite
//// only holds the input service and its latest progress value. If it is lost,
//// launch the same source again and send the same run, version and commit: each
//// `workflow.step` reconciles the existing child operation. The program does
//// not replay any workspace effect or restore an actor heap.

import cap/execution
import cap/report
import cap/strand
import cap/workflow
import gleam/result

type Review {
  Review(run: String, commit: String)
}

pub fn main() -> report.Outcome {
  case execution.endpoint("review", decode_review, review) {
    Error(_) -> report.failure("Could not register the review endpoint.")
    Ok(endpoint) ->
      case execution.serve([endpoint], idle_within_ms: 120_000) {
        Ok(_) -> report.text("Review input service ended.")
        Error(_) -> report.failure("Review input service failed.")
      }
  }
}

fn decode_review(value: report.Value) -> Result(Review, String) {
  use run <- result.try(required_text(value, "run"))
  use commit <- result.try(required_text(value, "commit"))
  Ok(Review(run:, commit:))
}

fn required_text(value: report.Value, name: String) -> Result(String, String) {
  use field <- result.try(
    report.field(value, name) |> result.replace_error("Missing " <> name <> "."),
  )
  report.as_string(field)
  |> result.replace_error("Expected text for " <> name <> ".")
}

fn review(input: Review) -> Result(Nil, String) {
  use security <- result.try(child(input, "security"))
  use performance <- result.try(child(input, "performance"))
  use Nil <- result.try(
    execution.progress(
      report.object([
        #("phase", report.string("reviewing")),
        #("run", report.string(input.run)),
      ]),
    )
    |> result.map(fn(_) { Nil }),
  )
  use joined <- result.try(
    strand.wait([security, performance], within_ms: 30_000)
    |> result.map_error(strand.error_text),
  )
  execution.progress(
    report.object([
      #("phase", report.string("joined")),
      #("run", report.string(input.run)),
      #("results", report.int(count_ready(joined))),
      #("reports", report.list(completed_reports(joined))),
    ]),
  )
  |> result.map(fn(_) { Nil })
}

fn child(input: Review, name: String) -> Result(strand.Handle, String) {
  let assignment =
    strand.assignment(
      purpose: name,
      brief: "Review commit "
        <> input.commit
        <> " for "
        <> name
        <> " findings. "
        <> "Record a concise result before completing.",
    )
  workflow.step(input.run, "v1", input.commit, name, assignment)
}

fn count_ready(joined: List(strand.Waited)) -> Int {
  case joined {
    [] -> 0
    [strand.Ready(outcome: strand.Completed, ..), ..rest] ->
      1 + count_ready(rest)
    [_, ..rest] -> count_ready(rest)
  }
}

fn completed_reports(joined: List(strand.Waited)) -> List(report.Value) {
  case joined {
    [] -> []
    [strand.Ready(outcome: strand.Completed, report: text, ..), ..rest] -> [
      report.string(text),
      ..completed_reports(rest)
    ]
    [_, ..rest] -> completed_reports(rest)
  }
}

//// A resident specialist that sends findings to one explicitly linked peer.
//// Run this source in each specialist session. An owner grants both directions
//// before asking the two agents to exchange findings.

import cap/execution
import cap/peer
import cap/report
import gleam/result

type Finding {
  Finding(session: String, message_id: String, text: String)
}

pub fn main() -> report.Outcome {
  case execution.endpoint("finding", decode_finding, deliver_finding) {
    Error(_) -> report.failure("Could not register the finding endpoint.")
    Ok(endpoint) ->
      case execution.serve([endpoint], idle_within_ms: 120_000) {
        Ok(_) -> report.text("Finding input service ended.")
        Error(_) -> report.failure("Finding input service failed.")
      }
  }
}

fn decode_finding(value: report.Value) -> Result(Finding, String) {
  use session <- result.try(required_text(value, "session"))
  use message_id <- result.try(required_text(value, "message_id"))
  use text <- result.try(required_text(value, "text"))
  Ok(Finding(session:, message_id:, text:))
}

fn required_text(value: report.Value, name: String) -> Result(String, String) {
  use field <- result.try(
    report.field(value, name) |> result.replace_error("Missing " <> name <> "."),
  )
  report.as_string(field)
  |> result.replace_error("Expected text for " <> name <> ".")
}

fn deliver_finding(finding: Finding) -> Result(Nil, String) {
  use _receipt <- result.try(peer.send(
    finding.session,
    "main",
    finding.message_id,
    finding.text,
  ))
  execution.progress(
    report.object([
      #("message_id", report.string(finding.message_id)),
      #("delivered_to", report.string(finding.session)),
    ]),
  )
  |> result.map(fn(_) { Nil })
}

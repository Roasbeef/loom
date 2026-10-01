//// Workflow errors retain host denial and malformed-handle distinctions.

import cap/internal/channel
import cap/internal/dispatch
import cap/report
import cap/strand
import cap/workflow

pub fn workflow_errors_preserve_boundary_categories_test() {
  let assignment = strand.assignment("review", "inspect")
  dispatch.install(
    channel.Channel(call: fn(_, _, _) {
      Error(channel.Denied("version_conflict", "immutable"))
    }),
  )
  assert workflow.step("run", "v1", "input", "step", assignment)
    == Error(workflow.WorkflowDenied("version_conflict", "immutable"))
  dispatch.install(
    channel.Channel(call: fn(_, _, _) { Error(channel.Unreachable("offline")) }),
  )
  assert workflow.step("run", "v1", "input", "step", assignment)
    == Error(workflow.WorkflowUnavailable("offline"))
  dispatch.install(
    channel.Channel(call: fn(_, _, _) {
      Ok(
        report.object([
          #("strand", report.string("reviewer")),
          #("operation", report.string("not-an-id")),
        ]),
      )
    }),
  )
  let assert Error(workflow.WorkflowResultMalformed(_)) =
    workflow.step("run", "v1", "input", "step", assignment)
    as "invalid durable identities fail at the successful-response boundary"
  dispatch.reset()
}

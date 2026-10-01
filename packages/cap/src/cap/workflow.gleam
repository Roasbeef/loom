//// Named, durable child steps for background orchestration programs.
////
//// A workflow name identifies one run within the launching strand. Its version
//// and input are immutable. Repeating a step returns the same child handle,
//// including failed outcomes; use a new step name for an intentional retry.
//// Ordinary code and workspace effects are never replayed by this API.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/strand
import gleam/result

/// Why a durable workflow admission could not be recovered.
pub type WorkflowError {
  /// The host refused the operation under its stable denial code.
  WorkflowDenied(
    /// The stable denial code supplied by the host.
    code: String,
    /// The host denial explanation.
    message: String,
  )

  /// The capability transport could not carry the request.
  WorkflowUnavailable(
    /// The complete diagnostic or closure reason.
    reason: String,
  )

  /// A successful response did not contain a valid typed handle.
  WorkflowResultMalformed(
    /// The complete diagnostic or closure reason.
    reason: String,
  )
}

/// Starts or recovers a named child step in the current background execution.
/// Join the returned handle with strand.wait, whose result is durable. Other
/// completed steps retain their handles when a failed step is retried by name.
///
/// ## Examples
///
/// ```gleam
/// // workflow.step("review-42", "v1", commit, "security", assignment)
/// ```
pub fn step(
  run: String,
  version: String,
  input: String,
  name: String,
  assignment: strand.Assignment,
) -> Result(strand.Handle, WorkflowError) {
  use value <- result.try(
    dispatch.call(
      "workflow.step",
      wire.args([
        #("run", wire.string(run)),
        #("version", wire.string(version)),
        #("input", wire.string(input)),
        #("name", wire.string(name)),
        #("assignment", strand.assignment_value(assignment)),
      ]),
    )
    |> result.map_error(map_error),
  )
  strand.read_handle(value) |> result.map_error(WorkflowResultMalformed)
}

fn map_error(error: channel.CallError) -> WorkflowError {
  case error {
    channel.Denied(code:, message:) -> WorkflowDenied(code:, message:)
    channel.Unreachable(reason:) -> WorkflowUnavailable(reason:)
  }
}

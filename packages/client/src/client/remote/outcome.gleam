//// Exact final report validation at the owner-to-session handoff.
////
//// Equality includes every AgentMessage field and terminal disposition.
//// Runtime synthesizes ToolFailed messages, so those records remain retained.

import core/message
import gleam/result
import runtime/effects
import storage/owner_custody

/// Validates every finalized message field and the durable termination flag.
/// Failed outcomes remain retained because runtime synthesizes their message.
///
/// ## Examples
///
/// ```gleam
/// // outcome.validate_commit(exact_payload, actual_reserved_entry)
/// ```
pub fn validate_commit(
  payload: owner_custody.Payload,
  readback: owner_custody.ResultReadback,
) -> Result(Nil, String) {
  use outcome <- result.try(
    effects.decode_tool_outcome(owner_custody.bytes(payload)),
  )
  case outcome {
    effects.ToolCompleted(result: message, terminate: terminate) -> {
      let termination = case terminate {
        True -> owner_custody.Terminates
        False -> owner_custody.Continues
      }
      case message == readback.message && termination == readback.termination {
        True -> Ok(Nil)
        False -> Error("reserved entry differs from exact final tool outcome")
      }
    }
    effects.ToolFailed(_) ->
      Error("synthetic failed result has no exact owner proof; retain custody")
  }
}

/// Refuses final results addressed to a different original provider call.
///
/// ## Examples
///
/// ```gleam
/// // outcome.validate_outcome(original_run, outcome)
/// ```
pub fn validate_outcome(
  run: effects.ToolRun,
  outcome: effects.ToolOutcome,
) -> Result(Nil, String) {
  case outcome {
    effects.ToolFailed(_) -> Ok(Nil)
    effects.ToolCompleted(
      message.ToolResultMessage(tool_call_id: id, tool_name: name, ..),
      _,
    ) ->
      case id == run.call.id && name == run.call.name {
        True -> Ok(Nil)
        False -> Error("final tool result changed original call ID or name")
      }
    effects.ToolCompleted(_, _) -> Error("final outcome is not a tool result")
  }
}

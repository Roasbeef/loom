//// Exact final report validation at the owner-to-session handoff.
////
//// Equality includes every AgentMessage field and terminal disposition.
//// Runtime synthesizes ToolFailed messages, so those records remain retained.
//// `valid_preview` bounds display bytes and the persisted timestamp independently
//// of terminal value custody.

import core/json
import core/message
import core/msgpack
import core/report_value
import gleam/bit_array
import gleam/bool
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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

/// Refuses oversized original provider identity before a report-profile effect.
/// The trusted profile, never the model's tool name, selects this contract.
///
/// ## Examples
///
/// `validate_admission(owner_custody.CodeModeReportV1, run)` precedes Fresh.
pub fn validate_admission(
  profile: owner_custody.FinalProfile,
  run: effects.ToolRun,
) -> Result(Nil, String) {
  case profile {
    owner_custody.OrdinaryFinal -> Ok(Nil)
    owner_custody.CodeModeReportV1 -> {
      let identity =
        json.to_string(
          json.Array([json.String(run.call.id), json.String(run.call.name)]),
        )
      case string.byte_size(identity) <= 8192 {
        True -> Ok(Nil)
        False -> Error("report final provider identity exceeds allowance")
      }
    }
  }
}

/// Validates the fixed complete-report final against prior original report custody.
/// A generic failure cannot turn retained report history into final authority.
///
/// ## Examples
///
/// `validate_final(profile, reference, terminal, outcome)` runs before final COMMIT and on reopen.
pub fn validate_final(
  profile: owner_custody.FinalProfile,
  reference: Option(report_value.ReportRef),
  terminal: Option(report_value.Outcome),
  outcome: effects.ToolOutcome,
) -> Result(Nil, String) {
  case profile, reference, terminal, outcome {
    owner_custody.OrdinaryFinal, None, None, _ -> Ok(Nil)
    owner_custody.CodeModeReportV1, None, None, effects.ToolFailed(_) -> Ok(Nil)
    owner_custody.CodeModeReportV1,
      None,
      None,
      effects.ToolCompleted(
        message.ToolResultMessage(
          content: [message.ToolResultText(preview, None)],
          details: Some(json.Object([
            #("kind", json.String("code_mode_not_run_v1")),
            #("stage", json.String(stage)),
          ])),
          usage: None,
          added_tool_names: None,
          is_error: True,
          timestamp: timestamp,
          ..,
        ),
        _,
      )
    -> {
      case
        { stage == "vet" || stage == "compile" }
        && valid_preview(preview, timestamp)
      {
        True -> Ok(Nil)
        False -> Error("invalid nonexecution refusal stage or preview")
      }
    }
    owner_custody.CodeModeReportV1,
      Some(reference),
      Some(terminal),
      effects.ToolCompleted(
        message.ToolResultMessage(
          content: [message.ToolResultText(preview, None)],
          details: details,
          usage: None,
          added_tool_names: None,
          is_error: is_error,
          timestamp: timestamp,
          ..,
        ),
        _,
      )
    -> {
      let expected =
        Some(
          json.Object([
            #("kind", json.String("code_mode_report_v1")),
            #("reference", json.String(report_value.ref_to_string(reference))),
          ]),
        )
      let failed = case terminal {
        report_value.Completed(_) -> False
        report_value.Errored(..) -> True
      }
      case
        details == expected
        && valid_preview(preview, timestamp)
        && is_error == failed
      {
        True -> Ok(Nil)
        False ->
          Error("final report reference, preview or error disposition differs")
      }
    }
    _, _, _, _ ->
      Error("complete report final lacks exact prior report custody")
  }
}

fn valid_preview(preview: String, timestamp: Int) -> Bool {
  string.byte_size(preview) <= 4096
  && timestamp >= 0
  && timestamp <= 18_446_744_073_709_551_615
}

/// Checks final call identity against the bounded immutable original request.
/// This startup check uses the saved request, never a recovered model argument.
///
/// ## Examples
///
/// `validate_original_request(request, final)` refuses a changed provider call.
pub fn validate_original_request(
  request: owner_custody.Payload,
  final: effects.ToolOutcome,
) -> Result(Nil, String) {
  case final {
    effects.ToolFailed(_) -> Ok(Nil)
    effects.ToolCompleted(
      message.ToolResultMessage(tool_call_id: id, tool_name: name, ..),
      _,
    ) -> validate_request_identity(owner_custody.bytes(request), id, name)
    effects.ToolCompleted(_, _) -> Error("final outcome is not a tool result")
  }
}

/// Checks the fixed bounded request and original provider identity before Fresh.
///
/// ## Examples
///
/// `validate_request_identity(request, original_id, original_name)` never selects a profile.
pub fn validate_request_identity(
  request: BitArray,
  id: String,
  name: String,
) -> Result(Nil, String) {
  use <- bool.guard(
    when: bit_array.byte_size(request) > 262_144
      || bit_array.bit_size(request) % 8 != 0,
    return: Error("original owner request exceeds bound"),
  )
  use value <- result.try(
    msgpack.decode(request)
    |> result.replace_error("invalid original owner request"),
  )
  case value {
    msgpack.ArrayValue([
      msgpack.BinaryValue(_scope),
      msgpack.StringValue(_strand),
      msgpack.StringValue(original_id),
      msgpack.StringValue(original_name),
      msgpack.StringValue(_arguments),
      _signature,
      _namespace,
    ])
      if original_id == id && original_name == name
    -> Ok(Nil)
    _ -> Error("final call differs from immutable original request")
  }
}

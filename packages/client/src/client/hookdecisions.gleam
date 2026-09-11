//// `client/hookdecisions` — reads one finished hook process back as
//// the decision the Claude contract says it made.
////
//// # Why this is its own module
////
//// The pinned contract gives a command hook two channels — exit codes
//// and stdout JSON — and rules for how they combine that vary per
//// event: exit 2 blocks on `PreToolUse` but is advisory on
//// `PostToolUse`; stdout is context on `SessionStart` and discarded on
//// `PreToolUse` when it is not JSON; a parsed object's fields act
//// alongside the exit code except where exit 2's block cannot be
//// overridden. Those rules are the parity target of #350, and writing
//// them once here is what keeps the event mapping from re-deciding
//// them per event, where they would drift.
////
//// The input type is `client/hookrunner.Outcome` and nothing else, so
//// the decision layer cannot know how a process ran and the runner
//// cannot know what a decision means. The output types are named for
//// the question each event asks, because a caller reading
//// `ToolPermission{Deny, reason}` should not have to remember a
//// number.
////
//// # What "plain text" means, exactly
////
//// The contract classifies stdout by how it starts and ends, ignoring
//// surrounding whitespace: `{...}` is parsed as JSON, and anything
//// else is plain text — including a JSON array or a quoted string.
//// A multi-line output whose lines each parse as JSON on their own is
//// plain text unless one of them sets a field. This module implements
//// that classification exactly; the per-event readers below decide
//// whether the text class matters, because four events make plain
//// stdout into model context and the rest ignore it.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// How one hook's stdout classifies, by the contract's rule.
pub type Stdout {
  /// No stdout at all: the quiet, successful hook.
  Silent

  /// A single JSON object: `{\u{2026}}`, whitespace-trimmed. The fields
  /// the event honors are read from it.
  Json(fields: List(#(String, JsonValue)))

  /// Anything else, including JSON that is not an object and
  /// multi-line outputs. Whether this is context, an error, or noise
  /// is the event's call.
  Plain(text: String)
}

/// The blocking exit code. The contract fixes it at 2, and 2 is the
/// one code whose effect JSON cannot override.
pub const blocking_code = 2

/// The cap the contract puts on any hook output string before it is
/// used as context or a message.
pub const output_cap = 10_000

/// Classifies one outcome's stdout by the contract's rule.
///
/// ## Examples
///
/// ```gleam
/// assert classify("") == Silent
/// assert classify("  {\"continue\": false} ") |> is_json
/// assert classify("[1, 2]") |> is_plain
/// ```
///
pub fn classify(stdout: String) -> Stdout {
  let trimmed = string.trim(stdout)
  case trimmed {
    "" -> Silent
    "{" <> _ ->
      case json.parse(stdout) {
        Ok(json.Object(fields)) -> Json(fields)
        _ -> Plain(trimmed)
      }
    _ -> Plain(trimmed)
  }
}



/// What a `PreToolUse` hook decided about one planned call.
///
/// The four outcomes are the contract's four `permissionDecision`
/// values, plus the exit-2 block, which routes the same way as deny
/// with the stderr text as the reason.
pub type ToolPermission {
  /// Nothing to say; the call proceeds through the harness's own
  /// clearance. `allow` is here too — a hook's allow never skips the
  /// harness's authority checks, so both map to the same "proceed".
  Proceed

  /// Refuse the call. The reason is text the model reads.
  Deny(reason: String)

  /// Escalate to the operator. Loom's escalation plane is the honest
  /// answer for the contract's `"ask"`.
  Ask(reason: String)

  /// Rewrite the arguments before the call runs, then proceed. The
  /// replacement is the whole input object, exactly as the contract
  /// words `updatedInput`.
  Rewrite(updated_input: JsonValue)
}

/// Reads a `PreToolUse` hook's outcome as its decision.
///
/// Precedence, per the contract: exit 2 blocks whether or not JSON was
/// printed, and the JSON's blocking decision names the reason when it
/// made one, with stderr otherwise. A timed-out hook renders no
/// decision — the contract's own words — so the call proceeds through
/// the normal clearance.
///
/// ## Examples
///
/// ```gleam
/// // exit 2, stderr "no rm" -> Deny("no rm")
/// // exit 0, stdout {} -> Proceed
/// ```
///
pub fn tool_permission(
  code: Int,
  stderr: String,
  stdout: String,
  timed_out: Bool,
) -> ToolPermission {
  case timed_out {
    True -> Proceed
    False ->
      case code {
        _ if code == blocking_code -> Deny(reason_for_block(stderr, stdout))
        _ ->
          case classify(stdout) {
            Silent -> Proceed
            Plain(_) -> Proceed
            Json(fields) -> permission_of(fields, stderr)
          }
      }
  }
}

// The JSON arm of a `PreToolUse` decision. `deny` wins, `ask`
// escalates, `allow` with an `updatedInput` rewrites, and a bare
// `allow` is the same as silence.
fn permission_of(
  fields: List(#(String, JsonValue)),
  stderr: String,
) -> ToolPermission {
  let specific = specific_fields("PreToolUse", fields)
  case string_field(specific, "permissionDecision") {
    Some("deny") -> Deny(string_field(specific, "permissionDecisionReason")
      |> option.unwrap(reason_for_block(stderr, "")))
    Some("ask") -> Ask(string_field(specific, "permissionDecisionReason")
      |> option.unwrap(""))
    Some("allow") ->
      case updated_input(specific) {
        Some(updated) -> Rewrite(updated)
        None -> Proceed
      }
    _ -> Proceed
  }
}

/// What a `PostToolUse` hook decided about one finished call.
pub type ToolFeedback {
  /// Nothing the model needs to see beyond the tool's own result.
  Nothing

  /// Feedback beside the result: the contract's `decision: "block"`
  /// adds the reason next to the tool result. The tool already ran;
  /// the block names what the model should look at, not an undo.
  Feedback(reason: String)

  /// The tool's result replaced before the model reads it, the
  /// contract's `updatedToolOutput`.
  Rewritten(replacement: JsonValue)

  /// Plain-text context the model reads alongside the result, the
  /// contract's `additionalContext`.
  Context(text: String)
}

/// Reads a `PostToolUse` hook's outcome as its feedback.
///
/// The tool already ran, so exit 2 is not a block but a signal: the
/// contract routes the stderr to the model. A rewrite only replaces
/// the *content* of the result — whether the call failed, what it
/// cost, and which call it settles stay the harness's, which is the
/// existing `tool_result` fold's own narrowing rule.
pub fn tool_feedback(
  code: Int,
  stderr: String,
  stdout: String,
  timed_out: Bool,
) -> ToolFeedback {
  case timed_out {
    True -> Nothing
    False ->
      case code {
        _ if code == blocking_code -> Feedback(stderr)
        _ ->
          case classify(stdout) {
            Silent -> Nothing
            Plain(_) -> Nothing
            Json(fields) -> feedback_of(fields)
          }
      }
  }
}

fn feedback_of(fields: List(#(String, JsonValue))) -> ToolFeedback {
  let specific = specific_fields("PostToolUse", fields)
  let context = string_field(specific, "additionalContext")
  case updated_input_named(specific, "updatedToolOutput") {
    Some(replacement) -> Rewritten(replacement)
    None ->
      case string_field(fields, "decision") {
        Some("block") ->
          Feedback(string_field(fields, "reason") |> option.unwrap(""))
        _ ->
          case context {
            Some(text) -> Context(text)
            None -> Nothing
          }
      }
  }
}

/// What a `Stop` or `SubagentStop` hook decided about ending the run.
pub type Continuation {
  /// The run may finish.
  Finish

  /// The run continues, with the reason as the continuation's text.
  /// The harness places the follow-up the same way its own `run_end`
  /// slot does, which is what makes the gate durable under replay.
  Continue(reason: String)
}

/// Reads a `Stop` hook's outcome as its continuation decision.
///
/// Exit 2 blocks the stop with the stderr as the reason — the contract
/// routes it exactly like `decision: "block"` — and a JSON
/// `additionalContext` also continues, as non-error feedback.
pub fn continuation(
  code: Int,
  stderr: String,
  stdout: String,
  timed_out: Bool,
) -> Continuation {
  case timed_out {
    True -> Finish
    False ->
      case code {
        _ if code == blocking_code ->
          Continue(case string.trim(stderr) {
            "" -> "the stop hook blocked the stop"
            reason -> reason
          })
        _ ->
          case classify(stdout) {
            Silent -> Finish
            Plain(_) -> Finish
            Json(fields) -> continuation_of(fields)
          }
      }
  }
}

fn continuation_of(fields: List(#(String, JsonValue))) -> Continuation {
  let specific = specific_fields("Stop", fields)
  let reason = string_field(fields, "reason")
  case string_field(fields, "decision") {
    Some("block") ->
      Continue(reason |> option.unwrap("the stop hook blocked the stop"))
    _ ->
      case string_field(specific, "additionalContext") {
        Some(text) -> Continue(text)
        None -> Finish
      }
  }
}

/// What a `SessionStart` or `UserPromptSubmit` hook contributed.
pub type ContextInjection {
  /// Nothing to add.
  NoContext

  /// Text for the model, alongside the session's start or the prompt.
  /// The plain-stdout arm is the contract's "stdout as context" rule
  /// for the four context-carrying events.
  Injected(text: String)

  /// The prompt is rejected: `UserPromptSubmit`'s `decision: "block"`.
  /// Not producible by `SessionStart`, which cannot block.
  Blocked(reason: String)
}

/// Reads a context-carrying event's outcome.
///
/// `blocking: True` selects the `UserPromptSubmit` reading, where exit
/// 2 rejects the prompt and a `decision: "block"` does the same;
/// `blocking: False` is the `SessionStart`/`SubagentStart` reading,
/// where neither exit 2 nor any decision field blocks and plain
/// stdout is context.
pub fn context_injection(
  event: String,
  blocking: Bool,
  code: Int,
  stderr: String,
  stdout: String,
  timed_out: Bool,
) -> ContextInjection {
  case timed_out {
    True -> NoContext
    False -> {
      case blocking_decision(blocking, code, stderr, stdout) {
        Blocked(reason) -> Blocked(reason)
        _ ->
          case classify(stdout) {
            Silent -> NoContext
            Plain(text) -> Injected(text)
            Json(fields) -> injected_of(event, fields, stdout)
          }
      }
    }
  }
}

fn blocking_decision(
  blocking: Bool,
  code: Int,
  stderr: String,
  stdout: String,
) -> ContextInjection {
  case blocking, code {
    True, c if c == blocking_code -> Blocked(string.trim(stderr))
    True, _ ->
      case classify(stdout) {
        Json(fields) ->
          case string_field(fields, "decision") {
            Some("block") ->
              Blocked(string_field(fields, "reason") |> option.unwrap(""))
            _ -> NoContext
          }
        _ -> NoContext
      }
    False, _ -> NoContext
  }
}

// The fields a decision reads from: the hook's `hookSpecificOutput`
// when it named this event, the top-level fields otherwise. The
// contract treats the nested object as the richer override, so the
// reader looks there first and falls back to the top level.
fn specific_fields(
  event: String,
  fields: List(#(String, JsonValue)),
) -> List(#(String, JsonValue)) {
  case hook_specific(event, fields) {
    Some(specific) -> specific
    None -> fields
  }
}

fn injected_of(
  event: String,
  fields: List(#(String, JsonValue)),
  stdout: String,
) -> ContextInjection {
  let specific = specific_fields(event, fields)
  case string_field(specific, "additionalContext") {
    Some(text) -> Injected(text)
    None ->
      // Plain stdout still counts as context on these events even
      // when a JSON object carried no context field, per the
      // contract's both-channels rule.
      case classify(stdout) {
        Plain(text) -> Injected(text)
        _ -> NoContext
      }
  }
}

/// The `hookSpecificOutput` object of one parsed hook output, with the
/// contract's `hookEventName` check: an object naming a different
/// event is not this event's output and is ignored, which is the
/// contract's guard against a copied-pasted answer firing at the wrong
/// moment.
pub fn hook_specific(
  event: String,
  fields: List(#(String, JsonValue)),
) -> Option(List(#(String, JsonValue))) {
  case list.key_find(fields, "hookSpecificOutput") {
    Ok(json.Object(specific)) ->
      case list.key_find(specific, "hookEventName") {
        Ok(json.String(name)) if name == event -> Some(specific)
        _ -> None
      }
    _ -> None
  }
}

/// Reads one string field out of a parsed field list.
pub fn string_field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Option(String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Some(text)
    _ -> None
  }
}

/// Reads the `updatedInput` replacement object.
pub fn updated_input(
  fields: List(#(String, JsonValue)),
) -> Option(JsonValue) {
  updated_input_named(fields, "updatedInput")
}

fn updated_input_named(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Option(JsonValue) {
  case list.key_find(fields, key) {
    Ok(json.Object(_) as value) -> Some(value)
    _ -> None
  }
}

// The reason a blocking decision carries, by the contract's order: the
// JSON's reason when the object made one, the stderr text otherwise.
fn reason_for_block(stderr: String, stdout: String) -> String {
  case classify(stdout) {
    Json(fields) ->
      string_field(fields, "reason")
      |> option.or(string_field(
        list.key_find(fields, "hookSpecificOutput")
        |> result.unwrap(json.Null)
        |> object_fields,
        "permissionDecisionReason",
      ))
      |> option.unwrap(string.trim(stderr))
    _ -> string.trim(stderr)
  }
}

fn object_fields(value: JsonValue) -> List(#(String, JsonValue)) {
  case value {
    json.Object(fields) -> fields
    _ -> []
  }
}

/// Clamps one hook output string to the contract's cap, with the same
/// preview shape a large tool result gets: the head, a marker naming
/// what was dropped, and nothing else.
pub fn capped(text: String) -> String {
  case string.length(text) <= output_cap {
    True -> text
    False ->
      string.slice(text, 0, output_cap)
      <> "\n[hook output capped at "
      <> int.to_string(output_cap)
      <> " characters]"
  }
}

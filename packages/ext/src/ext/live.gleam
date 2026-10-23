//// Stateful extension callbacks carry their state as a bounded JSON document.
//// The definition is data: only the generated trusted satellite entry starts
//// the actor or receives native upgrade commands. Authored code gets no loader,
//// process identifier, suspension API, or constructor for native authority.

import cap/report
import cap/runtime
import ext
import ext/runtime as extension_runtime
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/result

/// The stable invocation envelope shared by compatible implementations.
pub type Asked =
  runtime.Asked

/// The ordinary satellite reply; migration never manufactures this authority.
pub type Answer =
  runtime.Answer

/// A newly compiled implementation's initial state and message callback.
pub type Definition {
  Definition(
    /// Valid JSON seed used only when the component is first started.
    initial_state: String,
    /// Computes a new state and reply from the current state and invocation.
    on_message: fn(String, Asked) -> Result(#(String, Answer), String),
  )
}

/// Renders an ordinary extension outcome through the existing reply codec.
///
/// ## Examples
///
/// ```gleam
/// // live.reply(ext.Outcome(content: [ext.Text("ok")], terminate: ext.ContinueRun))
/// ```
///
pub fn reply(outcome: ext.Outcome) -> Answer {
  extension_runtime.outcome_answer(outcome)
}

/// Reads the manifest tool name from the stable invocation envelope.
///
/// ## Examples
///
/// ```gleam
/// // live.tool_name(asked)
/// ```
///
pub fn tool_name(asked: Asked) -> Result(String, String) {
  case asked.invocation {
    runtime.Tool(name) -> Ok(name)
    runtime.Event(_) -> Error("stateful callback received an event")
  }
}

/// Totally decodes the ordinary tool argument envelope's JSON document.
///
/// ## Examples
///
/// ```gleam
/// // live.arguments(asked)
/// ```
///
pub fn arguments(asked: Asked) -> Result(Dynamic, String) {
  use value <- result.try(
    report.field(asked.args, "args")
    |> result.replace_error("tool args are absent"),
  )
  use text <- result.try(
    report.as_string(value)
    |> result.replace_error("tool args are not JSON text"),
  )
  json.parse(text, decode.dynamic)
  |> result.replace_error("tool args are invalid JSON")
}

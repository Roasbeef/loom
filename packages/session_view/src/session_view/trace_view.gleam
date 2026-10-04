//// The Trace tab's data: the `code_mode` programs a session ran, in order,
//// each with its state and a bounded excerpt of its result, and the budget
//// the newest one named.
////
//// Issue #656 planned this as a list of a program's capability calls drawn
//// from what a page already receives. A page does not receive them:
//// capability calls are serviced inside the satellite host and nothing
//// records one (`protocol-change/060` says so and proposes the record). What
//// a page does hold is each `code_mode` call's arguments and its result, so
//// this fold lists the programs, which is the finest grain the data has. The
//// per-call rows, and the timing bars after them, arrive with that record.
//// `capability_calls_recorded` says so in words, so a host can state the
//// limit and not leave the reader to infer that a program made no calls.
////
//// `fold` works over the records a host holds, the same window the
//// transcript has, so a program older than the window is not listed. It
//// reads the call's `program_path` or the first line of its `program` as a
//// label, its `within_ms` as the wall budget, and the result's `status` and
//// `value`. A call whose result has not arrived is `Running`. Everything it
//// returns is session text or a number: the label and the excerpt are cut,
//// single-line and free of control characters, and a host draws them as text
//// nodes. `State` and `Vetting` are closed types computed here from the
//// result's `status` word, so a host chooses a style from the type and never
//// from the text.
////
//// The board is bounded for the same reason `changes_view`'s is: it is
//// drawn into every viewer's document. It keeps the newest `max_programs`
//// programs and counts the older ones. The module is portable: it imports
//// `core`, other `session_view` modules and the standard library, holds no
//// `@external`, and performs no I/O.

import core/json
import core/message
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/protocol
import session_view/text_hygiene
import session_view/tool_activity
import session_view/transcript_lines

/// The most programs a trace holds. An older program is counted and not
/// held.
pub const max_programs = 12

/// The most characters a label or an excerpt keeps. A longer one ends in `…`.
pub const max_characters = 160

/// Where a program is, decided from its result's `status` word.
pub type State {
  /// The call has no result yet.
  Running

  /// The program ran to its final value.
  Completed

  /// The program ran and reported a failure of its own.
  Errored

  /// Vetting refused the program, so it never compiled.
  Rejected

  /// The program passed vetting and did not compile.
  CompileFailed

  /// The program compiled and the run failed: a deadline, or the satellite
  /// died.
  RunFailed

  /// The result is an error with a `status` this fold does not know.
  Failed
}

/// What the result says about vetting, which the Budget line carries.
pub type Vetting {
  /// There is no result, so nothing is known yet.
  Pending

  /// The program was vetted and went on to compile.
  Passed

  /// Vetting refused it.
  Refused
}

/// One `code_mode` call.
pub type Program {
  Program(
    /// Where the program is.
    state: State,
    /// The program's file when the call named one, otherwise its first
    /// non-blank line, or nothing when it had neither. Session text.
    label: String,
    /// The final value, or the failure's text, cut to `max_characters`.
    /// Nothing while the call runs. Session text.
    excerpt: Option(String),
    /// The wall budget in milliseconds the call named, when it named one.
    within_ms: Option(Int),
    /// What the result said about vetting.
    vetting: Vetting,
    /// The sandbox line the result reported (`sandbox · build enforced 4
    /// layers; skipped 0 · satellite …`), when it reported one.
    sandbox: Option(String),
  )
}

/// The session's programs.
pub type Trace {
  Trace(
    /// The newest `max_programs` programs, oldest first, so the last is the
    /// one the tab leads with.
    programs: List(Program),
    /// How many older programs the bound left out.
    omitted: Int,
  )
}

/// A trace with no program in it.
///
/// ## Examples
///
/// ```gleam
/// assert trace_view.empty().programs == []
/// ```
pub fn empty() -> Trace {
  Trace(programs: [], omitted: 0)
}

/// What a host says under the list, so a reader does not take a program that
/// shows no capability calls to have made none.
///
/// ## Examples
///
/// ```gleam
/// assert trace_view.capability_calls_recorded() == "Capability calls are not recorded yet."
/// ```
pub fn capability_calls_recorded() -> String {
  "Capability calls are not recorded yet."
}

/// The one line the lane's step summary can use for a program: its label.
/// The first capability call (`read calc.py`) is not available, because no
/// capability call is recorded (`protocol-change/060`); when that record
/// lands this is where it is read from.
///
/// ## Examples
///
/// ```gleam
/// let program = trace_view.Program(
///   trace_view.Running, "count.gleam", None, None, trace_view.Pending, None,
/// )
/// assert trace_view.first_call(program) == "count.gleam"
/// ```
pub fn first_call(program: Program) -> String {
  program.label
}

/// The word for a state, as the tab prints it.
///
/// ## Examples
///
/// ```gleam
/// assert trace_view.state_word(trace_view.CompileFailed) == "compile failed"
/// ```
pub fn state_word(state: State) -> String {
  case state {
    Running -> "running"
    Completed -> "completed"
    Errored -> "errored"
    Rejected -> "rejected by vetting"
    CompileFailed -> "compile failed"
    RunFailed -> "run failed"
    Failed -> "failed"
  }
}

/// The word for a vetting state, as the Budget line prints it.
///
/// ## Examples
///
/// ```gleam
/// assert trace_view.vetting_word(trace_view.Passed) == "vetted"
/// ```
pub fn vetting_word(vetting: Vetting) -> String {
  case vetting {
    Pending -> "not vetted yet"
    Passed -> "vetted"
    Refused -> "refused by vetting"
  }
}

/// The budget the newest program named, as one line: `30000 ms wall · vetted`.
/// A call that named no budget says the host's default applied.
///
/// ## Examples
///
/// ```gleam
/// let program = trace_view.Program(
///   trace_view.Completed, "", None, Some(30_000), trace_view.Passed,
/// )
/// assert trace_view.budget_line(program) == "30000 ms wall · vetted"
/// ```
pub fn budget_line(program: Program) -> String {
  let wall = case program.within_ms {
    Some(ms) -> int.to_string(ms) <> " ms wall"
    None -> "default wall budget"
  }
  wall <> " · " <> vetting_word(program.vetting)
}

/// Folds a window of records into the session's trace. Records arrive
/// newest first, as a host holds them.
///
/// ## Examples
///
/// ```gleam
/// assert trace_view.fold([]) == trace_view.empty()
/// ```
pub fn fold(records: List(protocol.EntryRecord)) -> Trace {
  let programs =
    records
    |> list.reverse
    |> list.map(fn(record) { record.entry })
    |> tool_activity.project
    |> list.flat_map(calls)
    |> list.filter(fn(call) { call.invocation.name == "code_mode" })
    |> list.map(program)

  let total = list.length(programs)
  Trace(
    programs: list.drop(programs, int.max(0, total - max_programs)),
    omitted: int.max(0, total - max_programs),
  )
}

// The calls of a tool group. Prose, and a result whose call is outside the
// window, hold none.
fn calls(item: tool_activity.Item) -> List(tool_activity.Call) {
  case item {
    tool_activity.Tools(calls:) -> calls
    tool_activity.Narrative(_) -> []
  }
}

// One call as a program: the arguments give the label and the budget, the
// result gives the state and the excerpt.
fn program(call: tool_activity.Call) -> Program {
  let arguments = case call.invocation.arguments {
    json.Object(fields) -> fields
    _ -> []
  }
  let within_ms = case list.key_find(arguments, "within_ms") {
    Ok(json.Int(value)) -> Some(value)
    _ -> None
  }
  let label = label(arguments)

  case call.outcome {
    Some(message.ToolResultMessage(content:, details:, is_error:, ..)) -> {
      let fields = case details {
        Some(json.Object(fields)) -> fields
        _ -> []
      }
      let state = state(fields, is_error)
      Program(
        sandbox: transcript_lines.sandbox_summary(fields),
        state:,
        label:,
        excerpt: Some(excerpt(fields, content, state)),
        within_ms:,
        vetting: vetting(state),
      )
    }
    Some(_) | None ->
      Program(
        state: Running,
        label:,
        excerpt: None,
        within_ms:,
        vetting: Pending,
        sandbox: None,
      )
  }
}

// The file the call named, else the program's first non-blank line.
fn label(arguments: List(#(String, json.JsonValue))) -> String {
  case
    list.key_find(arguments, "program_path"),
    list.key_find(arguments, "program")
  {
    Ok(json.String(path)), _ -> clipped(path)
    _, Ok(json.String(source)) ->
      source
      |> string.split("\n")
      |> list.find(fn(line) { string.trim(line) != "" })
      |> result.unwrap("")
      |> clipped
    _, _ -> ""
  }
}

// The result's `status` word as a closed state. A result without a known
// word is `Completed` when it is not an error, and `Failed` when it is.
fn state(fields: List(#(String, json.JsonValue)), is_error: Bool) -> State {
  case list.key_find(fields, "status"), is_error {
    Ok(json.String("completed")), _ -> Completed
    Ok(json.String("errored")), _ | Ok(json.String("program_failed")), _ ->
      Errored
    Ok(json.String("vetting_rejected")), _ -> Rejected
    Ok(json.String("compile_failed")), _ -> CompileFailed
    Ok(json.String("run_failed")), _ -> RunFailed
    _, False -> Completed
    _, True -> Failed
  }
}

// A program that reached compilation was vetted. A refusal says so, and a
// failure with no known word says nothing, so it is not claimed as vetted.
fn vetting(state: State) -> Vetting {
  case state {
    Completed | Errored | CompileFailed | RunFailed -> Passed
    Rejected -> Refused
    Running | Failed -> Pending
  }
}

// What the result says: the final value of a program that completed, the
// failure's message otherwise, falling back to the result's text.
fn excerpt(
  fields: List(#(String, json.JsonValue)),
  content: List(message.ToolResultBlock),
  state: State,
) -> String {
  let from_fields = case state, list.key_find(fields, "value") {
    Completed, Ok(value) -> Some(json.to_string(value))
    _, _ ->
      case list.key_find(fields, "message") {
        Ok(json.String(text)) -> Some(text)
        _ -> None
      }
  }
  case from_fields {
    Some(text) -> clipped(text)
    None ->
      content
      |> list.map(fn(block) {
        case block {
          message.ToolResultText(text:, ..) -> text
          message.ToolResultImage(mime_type:, ..) ->
            "[image " <> mime_type <> "]"
        }
      })
      |> string.join(" ")
      |> clipped
  }
}

// A single line of at most `max_characters` code points, cut with `…`.
fn clipped(text: String) -> String {
  let line = text_hygiene.single_line(text)
  let points = string.to_utf_codepoints(line)
  case list.drop(points, max_characters) {
    [] -> line
    [_, ..] ->
      string.from_utf_codepoints(list.take(points, max_characters - 1)) <> "…"
  }
}

//// The Trace tab's data: the `code_mode` programs a session ran, in order,
//// each with its state and a bounded excerpt of its result, and the budget
//// the newest one named.
////
//// Issue #656 planned this as a list of a program's capability calls drawn
//// from what a page already receives. Capability calls are serviced inside
//// the satellite host, and `protocol-change/060` adds the record: a result's
//// `details` carry the calls the program made. This fold lists the programs,
//// and each one carries the rows of its call record (`calls`, worded as the
//// transcript's own call section words them) when its result has one. A
//// program whose result has none, because it is still running or predates the
//// record, lists no calls. The timing bars are a separate piece of work.
//// `capability_calls_recorded` says so in words, so a host can state the
//// limit and not leave the reader to infer that a program made no calls.
////
//// The terminal's Trace tab and the web view's share this module. The web
//// view folds the branch it holds (`fold`), and the terminal asks for one
//// strand's newest program with its source (`newest`).
////
//// `fold` works over the records a host holds, the same window the
//// transcript has, so a program older than the window is not listed. It
//// reads the call's `program_path` or the leading comment of its `program` as a
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
////
//// ## Flow
////
//// `fold` → `code_mode_calls` → `program` → `call_rows`
////
//// `newest` → `code_mode_calls` → `program` → `source_rows`
////
//// 1. `fold` lists a branch's programs, oldest first, bounded.
//// 2. `newest` picks one strand's records out of a mixed window, in entry
////    order, and returns the last program with its numbered source.
//// 3. `code_mode_calls` finds the code-mode calls among entries, with the
////    results that answer them.
//// 4. `program` words one call: label, budget, state and excerpt.
//// 5. `call_rows` reads the call record a result carries, as rows.
//// 6. `source_rows` numbers the opening lines of a program.

import core/entry
import core/json
import core/message
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/call_tree
import session_view/protocol
import session_view/text_hygiene
import session_view/tool_activity
import session_view/transcript_lines

/// The most programs a trace holds. An older program is counted and not
/// held.
pub const max_programs = 12

/// The most characters a label or an excerpt keeps. A longer one ends in `…`.
pub const max_characters = 160

/// How many rows of source `newest` is given.
pub const source_lines = 12

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
    /// The program's file when the call named one, otherwise its leading
    /// comment's text, otherwise `Program N` for its place in the session.
    /// Session text.
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
    /// What went wrong in the result's own words, when the result keeps them
    /// apart from the text it wrote for the model: the compiler's
    /// diagnostics of a program that did not compile, the reason a run
    /// failed. It is the one thing a reader wants from a failed program, and
    /// `excerpt` is not it, since that is the text beside it that tells the
    /// model what to do next. At most `max_detail` characters, lines kept.
    /// Session text.
    detail: Option(String),
    /// The rows of the call record the result carried (`CALLS · 2 calls · 1
    /// failed`, then one row per call), as the transcript's call section
    /// words them. Nothing while the call runs, and nothing for a result with
    /// no readable record. Session text.
    calls: List(String),
  )
}

/// One strand's newest program with what a host beside the transcript draws
/// that the list does not: the opening lines of its source.
pub type Newest {
  Newest(
    /// The program, as `fold` words it.
    program: Program,
    /// The opening lines of the source, numbered, ending in a count of what
    /// was cut. Empty for a call that carried no program text.
    source: List(String),
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
/// shows no capability calls to have made none: a call is listed when its
/// result carries the record `protocol-change/060` adds.
///
/// ## Examples
///
/// ```gleam
/// assert trace_view.capability_calls_recorded()
///   == "Capability calls are listed from each result's call record; a program with no record lists none."
/// ```
pub fn capability_calls_recorded() -> String {
  "Capability calls are listed from each result's call record; "
  <> "a program with no record lists none."
}

/// The one line the lane's step summary can use for a program: its first
/// capability call (`✓ fs.read   calc.py`) when the result carried a call
/// record, and its label otherwise.
///
/// ## Examples
///
/// ```gleam
/// let program = trace_view.Program(
///   trace_view.Running, "count.gleam", None, None, trace_view.Pending, None,
///   None, [],
/// )
/// assert trace_view.first_call(program) == "count.gleam"
/// ```
pub fn first_call(program: Program) -> String {
  case program.calls {
    [_heading, first, ..] -> first
    [_] | [] -> program.label
  }
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

/// The words the transcript's own failure block uses for a state, so the
/// terminal's Trace tab names a program's end the way the transcript does:
/// `compile error`, `refused by vetting`, `did not finish`, `program failed`.
///
/// ## Examples
///
/// ```gleam
/// assert trace_view.state_title(trace_view.Rejected) == "refused by vetting"
/// ```
pub fn state_title(state: State) -> String {
  case state {
    Running -> "running"
    Completed -> "completed"
    Errored -> transcript_lines.status_title("program_failed")
    Rejected -> transcript_lines.status_title("vetting_rejected")
    CompileFailed -> transcript_lines.status_title("compile_failed")
    RunFailed -> transcript_lines.status_title("run_failed")
    Failed -> transcript_lines.status_title("failed")
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
///   trace_view.Completed, "", None, Some(30_000), trace_view.Passed, None,
///   None, [],
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

/// The budget a program named, as a reader says it: `30 s`, or `default` when
/// the call named none. `budget_line` is the terminal's, which also says
/// whether vetting passed; a program the page lists has a state chip that
/// already says so.
///
/// ## Examples
///
/// ```gleam
/// let program = trace_view.Program(
///   trace_view.Completed, "", None, Some(30_000), trace_view.Passed, None,
///   None, [],
/// )
/// assert trace_view.budget_words(program) == "30 s"
/// ```
pub fn budget_words(program: Program) -> String {
  case program.within_ms {
    Some(ms) if ms >= 1000 && ms % 1000 == 0 -> int.to_string(ms / 1000) <> " s"
    Some(ms) -> int.to_string(ms) <> " ms"
    None -> "default"
  }
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
    |> code_mode_calls
    |> list.index_map(fn(call, index) { program(call, index + 1) })

  let total = list.length(programs)
  Trace(
    programs: list.drop(programs, int.max(0, total - max_programs)),
    omitted: int.max(0, total - max_programs),
  )
}

/// Joins the trace of an earlier stretch of a session to the trace of a later
/// one, within the same bound. A host that keeps a summary of each settled turn
/// folds each turn's programs once and joins them when it draws the page.
///
/// ## Examples
///
/// ```gleam
/// assert trace_view.append(trace_view.empty(), trace_view.empty())
///   == trace_view.empty()
/// ```
pub fn append(earlier: Trace, later: Trace) -> Trace {
  let programs = list.append(earlier.programs, later.programs)
  let left_out = int.max(0, list.length(programs) - max_programs)
  Trace(
    programs: list.drop(programs, left_out),
    omitted: earlier.omitted + later.omitted + left_out,
  )
}

/// One strand's newest program, whatever order the records arrive in, or
/// nothing when the strand has run none. The records may belong to several
/// strands, as a terminal holds them, and only `strand`'s are read.
///
/// ## Examples
///
/// ```gleam
/// assert trace_view.newest([], "main") == None
/// ```
pub fn newest(
  records: List(protocol.EntryRecord),
  strand: String,
) -> Option(Newest) {
  let calls =
    records
    |> list.filter(fn(record) { record.strand == strand })
    |> list.sort(fn(left, right) {
      int.compare(entry_seq(left.entry), entry_seq(right.entry))
    })
    |> list.map(fn(record) { record.entry })
    |> code_mode_calls
  case list.last(calls) {
    Ok(call) ->
      Some(Newest(
        program: program(call, list.length(calls)),
        source: source_rows(program_text(call)),
      ))
    Error(Nil) -> None
  }
}

// A message entry's place in the session; the others carry none a program
// can have, so they sort first.
fn entry_seq(value: entry.Entry) -> Int {
  case value {
    entry.MessageEntry(seq:, ..) -> seq
    entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> 0
  }
}

// The `code_mode` calls among entries given oldest first, each with the
// result that answers it when one has arrived. `tool_activity.calls` keeps a
// call made beside visible reasoning or text, which the transcript's
// projection folds into a prose row.
fn code_mode_calls(entries: List(entry.Entry)) -> List(tool_activity.Call) {
  entries
  |> tool_activity.calls
  |> list.filter(fn(call) { call.invocation.name == "code_mode" })
}

// The program text a call sent, or nothing when it named a file instead.
fn program_text(call: tool_activity.Call) -> String {
  case call.invocation.arguments {
    json.Object(fields) ->
      case list.key_find(fields, "program") {
        Ok(json.String(source)) -> source
        Ok(_) | Error(Nil) -> ""
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> ""
  }
}

/// The opening lines of a program, each with its number, and a closing row
/// counting the lines left out.
///
/// ## Examples
///
/// ```gleam
/// assert trace_view.source_rows("a\nb") == ["  1 │ a", "  2 │ b"]
/// ```
pub fn source_rows(program: String) -> List(String) {
  let lines = string.split(program, "\n")
  let shown =
    lines
    |> list.take(source_lines)
    |> list.index_map(fn(line, index) {
      string.pad_start(int.to_string(index + 1), 3, " ")
      <> " │ "
      <> text_hygiene.single_line(line)
    })
  case list.length(lines) - source_lines {
    left if left > 0 ->
      list.append(shown, [
        "    … "
        <> int.to_string(left)
        <> " more lines · the transcript has the rest",
      ])
    _ -> shown
  }
}

// One call as a program: the arguments give the label and the budget, the
// result gives the state and the excerpt.
fn program(call: tool_activity.Call, position: Int) -> Program {
  let arguments = case call.invocation.arguments {
    json.Object(fields) -> fields
    _ -> []
  }
  let within_ms = case list.key_find(arguments, "within_ms") {
    Ok(json.Int(value)) -> Some(value)
    _ -> None
  }
  let label = label(arguments, position)

  case call.outcome {
    Some(message.ToolResultMessage(content:, details:, is_error:, ..)) -> {
      let fields = case details {
        Some(json.Object(fields)) -> fields
        _ -> []
      }
      let state = state(fields, is_error)
      let shown = excerpt(fields, content, state)
      Program(
        sandbox: transcript_lines.sandbox_summary(fields),
        detail: detail(fields, state, shown),
        state:,
        label:,
        excerpt: Some(shown),
        within_ms:,
        vetting: vetting(state),
        calls: call_rows(details),
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
        detail: None,
        calls: [],
      )
  }
}

/// The most characters of a failure's detail a program keeps.
pub const max_detail = 800

// What went wrong, for a state that is a failure to compile, vet or run. The
// result's own `detail` is the reason (the compiler's diagnostics, a run's
// reason), and a vetting refusal keeps its reasons in `rejections[].detail`.
// A result with neither, or with empty ones, falls back to the first sentence
// of its text, which states what happened before it tells the model what to
// do next. So a failed program always has a reason to show, and never the
// instruction.
fn detail(
  fields: List(#(String, json.JsonValue)),
  state: State,
  excerpt: String,
) -> Option(String) {
  case state {
    CompileFailed | RunFailed | Rejected ->
      case reason(fields) {
        "" ->
          case first_sentence(excerpt) {
            "" -> None
            sentence -> Some(sentence)
          }
        text -> Some(bounded(text))
      }
    Running | Completed | Errored | Failed -> None
  }
}

fn reason(fields: List(#(String, json.JsonValue))) -> String {
  let from_detail = case list.key_find(fields, "detail") {
    Ok(json.String(text)) -> text
    _ -> ""
  }
  let text = case
    string.trim(from_detail),
    list.key_find(fields, "rejections")
  {
    "", Ok(json.Array(rejections)) ->
      rejections
      |> list.filter_map(fn(rejection) {
        case rejection {
          json.Object(entry) ->
            case list.key_find(entry, "detail") {
              Ok(json.String(text)) -> Ok(text)
              _ -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
      |> string.join("\n")
    _, _ -> from_detail
  }
  string.trim(from_first_error(text_hygiene.multiline(text)))
}

fn bounded(text: String) -> String {
  case string.length(text) > max_detail {
    True -> string.slice(text, 0, max_detail - 1) <> "…"
    False -> text
  }
}

// The text up to its first full stop followed by a space, with the stop.
fn first_sentence(text: String) -> String {
  case string.split_once(text, ". ") {
    Ok(#(first, _)) -> first <> "."
    Error(Nil) -> string.trim(text)
  }
}

// The rows of the call record a result's details carry, as the transcript's
// call section words them without its leading blank row, or nothing when the
// details carry none.
fn call_rows(details: Option(json.JsonValue)) -> List(String) {
  case details {
    Some(record) ->
      case call_tree.read(record) {
        Some(log) ->
          list.filter(transcript_lines.call_section(log), fn(row) { row != "" })
        None -> []
      }
    None -> []
  }
}

// The file the call named. Otherwise the text of the program's leading
// comment, which is usually the model's description of it, found after any
// blank lines and imports; a program that opens with code says nothing about
// itself, so it is `Program N` for its place in the session.
fn label(arguments: List(#(String, json.JsonValue)), position: Int) -> String {
  let fallback = "Program " <> int.to_string(position)
  case
    list.key_find(arguments, "program_path"),
    list.key_find(arguments, "program")
  {
    Ok(json.String(path)), _ -> clipped(path)
    _, Ok(json.String(source)) ->
      case leading_comment(string.split(source, "\n")) {
        "" -> fallback
        text -> clipped(text)
      }
    _, _ -> fallback
  }
}

// The text of the first line that is not blank or an import, when that line
// is a `//` comment, and nothing otherwise.
fn leading_comment(lines: List(String)) -> String {
  case lines {
    [] -> ""
    [line, ..rest] -> {
      let line = string.trim(line)
      case line, string.starts_with(line, "import ") {
        "", _ | _, True -> leading_comment(rest)
        _, False ->
          case string.starts_with(line, "//") {
            True -> line |> drop_slashes |> string.trim
            False -> ""
          }
      }
    }
  }
}

fn drop_slashes(line: String) -> String {
  case string.starts_with(line, "/") {
    True -> drop_slashes(string.drop_start(line, 1))
    False -> line
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

// The text from its first `error` line on, or the whole text when it has no
// such line.
fn from_first_error(text: String) -> String {
  let lines = string.split(text, "\n")
  case list.drop_while(lines, fn(line) { !string.starts_with(line, "error") }) {
    [] -> text
    [_, ..] as from -> string.join(from, "\n")
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

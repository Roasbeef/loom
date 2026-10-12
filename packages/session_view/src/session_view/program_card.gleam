//// A `code_mode` program as one card: what it did in a sentence, the calls it
//// made on a time axis, the program, and its result or its error.
////
//// The terminal draws a program as a titled block of text
//// (`transcript_lines.program_lines`). A host that can draw more than text
//// wants the same facts as typed fields: a status to colour, a call to put a
//// bar on, a compiler's line number to mark, not words already laid out and
//// cut to eighty columns. This module reads those fields from the call and the
//// result joined to it, once, so the web view and any later host draw one
//// projection and cannot word it differently. The terminal does not use it
//// and keeps drawing the text it always drew.
////
//// ## What the card holds, and what it does not
////
//// Everything here is derived from a program's arguments (`program`,
//// `within_ms`, `mode`) and from the result's `details` (`status`, `value`,
//// `detail`, `message`, and the call record of protocol change 060). The
//// record itemises each call with its capability, a redacted argument
//// summary, its status, an error code and its timing, and nothing else: there
//// is no per-call result, no file path beyond the summary, no host and no
//// reason for a refusal. So the card names no path it was not given, and the
//// outcome sentence counts calls by what their capability is and says
//// nothing about what they touched. While a program runs the host has written
//// no record, so a running card holds the program and the budget alone.
////
//// ## The outcome sentence
////
//// A reader scanning a long transcript wants one line per program. `family`
//// is the closed table that sorts a capability into what it does to the
//// world (read a file, search, look up code, run git, write a file, run a
//// command, reach the network), and `phrases` turns the counts of each into
//// words (`Read 2 files, ran 4 git commands`). A capability the table does
//// not list is counted as an other call, never guessed at. The table is
//// closed on purpose: a wrong entry reads as a false claim about what ran.
//// The chips mark the three families that change something outside the
//// program (a write, a command, a request) and the calls that failed, so a
//// side effect stands out from a read.
////
//// ## The time axis
////
//// Each call row carries a `Bar`: where the call started and how long it
//// ran, as whole percentages of the program's own span, so a view draws it
//// with two numbers and no arithmetic. `bar` keeps `offset` in 0 to 99 and
//// `width` in 1 to `100 - offset` for any input, including a record whose
//// elapsed time is zero, so a bar is always visible and never leaves its
//// track.
////
//// ## Flow
////
//// `read` → `running`, `completed`, `failed`
////
//// 1. `read` accepts a foreground program call and the result joined to
////    it, and sends it to the state it is in.
//// 2. `completed` reads the call record and the value, and `failed` reads
////    the error and, for a compiler's diagnostic, `parse_diagnostic`.
//// 3. `call_table` groups consecutive calls and gives each group a `bar`.
//// 4. `opening` says which sections a view draws open by default.

import core/json
import core/message
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/call_tree.{type Call, type CallLog, type Status}
import session_view/text_hygiene
import session_view/transcript_lines

/// How the program stands.
pub type State {
  /// The call has no result yet.
  Running

  /// The program ran to the end and returned a value.
  Completed

  /// The compiler refused the program, so nothing ran.
  CompileFailed

  /// Vetting refused the program before it compiled, so nothing ran.
  Rejected

  /// The program was stopped before it finished, such as by its deadline.
  RunFailed

  /// The program ran and reported a failure of its own.
  ProgramFailed
}

/// How much of the program's and the result's text the card keeps.
///
/// A card is part of every viewer's document whether or not anyone opens it,
/// so the host decides how much of a large text it carries, as it does for an
/// expanded row (`turns.Expansion`).
pub type Source {
  /// Only the program's opening lines and its line count. The card holds no
  /// whole program and no whole value.
  OpeningOnly

  /// The whole program and the whole value, each passed through `cut`, which
  /// bounds a text and says where it did.
  Whole(cut: fn(String) -> String)
}

/// One program as a card.
pub type ProgramCard {
  ProgramCard(
    /// How the program stands.
    state: State,
    /// The status as a word, for a reader that cannot see the glyph:
    /// `completed`, `compile error`, `refused by vetting`.
    status_word: String,
    /// The one sentence a transcript scan reads.
    outcome: String,
    /// The side effects and failures the calls had, in a fixed order.
    chips: List(Chip),
    /// How many calls it made, as words (`7 calls`, `7 calls · 1 failed`),
    /// or `None` when the result carries no call record.
    count_words: Option(String),
    /// How long the program ran, from the call record.
    elapsed_ms: Option(Int),
    /// The budget the call asked for, when it named one.
    budget_ms: Option(Int),
    /// The program's source.
    program: Program,
    /// The calls the program made, when the result carries a record.
    calls: Option(CallTable),
    /// Why the program did not complete, when it did not.
    failure: Option(Failure),
    /// What a completed program returned.
    value: Option(Value),
  )
}

/// A program's source, as much as the card keeps.
pub type Program {
  Program(
    /// How many lines the program has.
    lines: Int,
    /// Its first few lines that say something, each under its own number.
    /// Blank lines are skipped, so the numbers need not be consecutive.
    opening: List(SourceLine),
    /// The whole program, when the host asked for it (`Whole`).
    whole: Option(String),
    /// The line a compiler named, when the program did not compile and the
    /// diagnostic could be read.
    failing_line: Option(Int),
  )
}

/// One numbered line of source.
pub type SourceLine {
  SourceLine(number: Int, text: String)
}

/// A count the header marks with a chip.
pub type Chip {
  Chip(kind: ChipKind, count: Int)
}

/// What a chip counts.
pub type ChipKind {
  /// Files the program wrote or edited.
  Wrote

  /// Commands the program ran, git commands that change the repository
  /// included.
  Ran

  /// Network requests the program made.
  Network

  /// Calls that failed or that the host refused.
  FailedCalls
}

/// The calls a program made, grouped and placed on its time axis.
pub type CallTable {
  CallTable(
    /// The record's account of itself (`7 calls · 1 failed`).
    summary: String,
    /// One row per run of consecutive calls that share a capability and an
    /// ending, in the order the program made them.
    rows: List(CallRow),
    /// Calls the host counted and did not itemise.
    unlisted: Int,
    /// The span the bars are drawn against, in milliseconds. It is never
    /// zero.
    axis_ms: Int,
  )
}

/// One run of consecutive calls to one capability that ended the same way.
pub type CallRow {
  CallRow(
    /// The capability, such as `fs.read`.
    cap: String,
    /// How many calls the run holds.
    count: Int,
    /// How the calls ended.
    status: Status,
    /// The error code of a failed run, in words (`exit status`).
    error: Option(String),
    /// The redacted argument summaries of the run, joined and cut to a row.
    args: String,
    /// The calls' durations added up, in milliseconds.
    duration_ms: Int,
    /// Where the run sits on the time axis.
    bar: Bar,
    /// Every call of the run, for the row's expanded form.
    members: List(Member),
  )
}

/// One call of a run: all the record holds about it.
pub type Member {
  Member(
    /// The redacted argument summary, when the host made one.
    args: Option(String),
    /// Milliseconds from the program's start to the call's start.
    start_ms: Int,
    /// Milliseconds from the call's start to its end.
    duration_ms: Int,
  )
}

/// A call's place on the time axis, in whole percentages of the axis.
pub type Bar {
  Bar(
    /// Where the bar starts, from 0 to 99.
    offset: Int,
    /// How wide it is, from 1 to `100 - offset`.
    width: Int,
  )
}

/// Why a program did not complete.
pub type Failure {
  Failure(
    /// What the foot of the card says (`the program did not run`).
    foot: String,
    /// The error text as the result carried it, trimmed.
    text: String,
    /// How many lines `text` has.
    lines: Int,
    /// The compiler's diagnostic read into its parts, when `text` is one.
    diagnostic: Option(Diagnostic),
  )
}

/// A compiler diagnostic read into its parts.
pub type Diagnostic {
  Diagnostic(
    /// The first line, `error: Unknown variable`.
    heading: String,
    /// The program's name in the compiler's report.
    path: String,
    /// The line and column the compiler named, counted from 1.
    line: Int,
    column: Int,
    /// The report below its place: the quoted source, the pointer under it
    /// and any note, in order.
    rows: List(DiagRow),
  )
}

/// One row of a compiler's report.
pub type DiagRow {
  /// A line of the program the report quotes, under its number.
  Quoted(number: Int, text: String)

  /// The row of carets under a quoted line, and what the compiler says there.
  Pointer(text: String)

  /// Any other line of the report, such as a hint.
  Note(text: String)
}

/// What a completed program returned.
pub type Value {
  Value(
    /// What kind of value it is (`object · 3 keys`, `list · 2 items`, or the
    /// value itself for a scalar).
    kind: String,
    /// A hint per top-level key of an object or for the first element of a
    /// list, at most a few.
    hints: List(String),
    /// The whole value as text, when the host asked for it (`Whole`).
    whole: Option(String),
  )
}

/// Whether a section of the card is drawn open.
pub type Disclosure {
  Collapsed
  Expanded
}

/// Which parts of a card a view draws open before the reader touches it.
pub type Opening {
  Opening(
    /// The card itself. A settled program with nothing wrong is one line.
    card: Disclosure,
    /// The program section.
    program: Disclosure,
    /// The calls section.
    calls: Disclosure,
    /// The result section.
    result: Disclosure,
  )
}

// How many of a program's lines the card shows before the reader asks for
// the rest. The terminal shows the same number.
const opening_lines = 4

// The most characters of a row's argument summaries.
const args_limit = 120

/// The card of a foreground `code_mode` call, with the result joined to it
/// when there is one.
///
/// A call that is not a program, a launch (whose result is a handle, since
/// the program was admitted and not run), a call without a program, and a
/// result with no readable details have no card, and the host draws them as
/// any other call.
///
/// ## Examples
///
/// ```gleam
/// let call = message.ToolCall("c1", "code_mode", json.Object([#("program", json.String("1"))]), None, None)
/// let assert Some(card) = program_card.read(call, None, program_card.OpeningOnly)
/// assert card.state == program_card.Running
/// ```
pub fn read(
  invocation: message.ToolCall,
  outcome: Option(message.AgentMessage),
  source: Source,
) -> Option(ProgramCard) {
  case invocation.name, invocation.arguments {
    "code_mode", json.Object(arguments) ->
      case string_field(arguments, "program") {
        None -> None
        Some(program) ->
          case string_field(arguments, "mode") |> option.unwrap("run") {
            "run" -> settle(program, arguments, outcome, source)
            _ -> None
          }
      }
    _, _ -> None
  }
}

// The card the result decides: none yet is a running program, a result that
// is not an error is a completed one, and an error with details is a failed
// one. A result without details has nothing to read, so it has no card.
fn settle(
  program: String,
  arguments: List(#(String, json.JsonValue)),
  outcome: Option(message.AgentMessage),
  source: Source,
) -> Option(ProgramCard) {
  let budget = int_field(arguments, "within_ms")
  case outcome {
    None -> Some(running(program, budget, source))
    Some(message.ToolResultMessage(
      is_error: False,
      details: Some(json.Object(details)),
      content:,
      ..,
    )) -> Some(completed(program, budget, details, content, source))
    Some(message.ToolResultMessage(
      is_error: True,
      details: Some(json.Object(details)),
      content:,
      ..,
    )) -> Some(failed(program, budget, details, content, source))
    Some(_) -> None
  }
}

// A program with no result: its opening and its budget are all there is.
fn running(
  program: String,
  budget: Option(Int),
  source: Source,
) -> ProgramCard {
  ProgramCard(
    state: Running,
    status_word: "running",
    outcome: "Running a program",
    chips: [],
    count_words: None,
    elapsed_ms: None,
    budget_ms: budget,
    program: program_of(program, source, None),
    calls: None,
    failure: None,
    value: None,
  )
}

// A program that returned: its record gives the sentence, the chips and the
// calls, and its value gives the result.
fn completed(
  program: String,
  budget: Option(Int),
  details: List(#(String, json.JsonValue)),
  content: List(message.ToolResultBlock),
  source: Source,
) -> ProgramCard {
  let log = call_tree.read(json.Object(details))
  ProgramCard(
    state: Completed,
    status_word: string_field(details, "status")
      |> option.unwrap("completed")
      |> text_hygiene.single_line,
    outcome: completed_sentence(log),
    chips: chips(log),
    count_words: option.map(log, count_words),
    elapsed_ms: option.map(log, fn(log) { log.elapsed_ms }),
    budget_ms: budget,
    program: program_of(program, source, None),
    calls: option.map(log, call_table),
    failure: None,
    value: Some(value_of(details, content, source)),
  )
}

// A program that did not complete: which way it failed decides the state and
// where the error text is, and the call record, when the host wrote one,
// still says what ran before it stopped.
fn failed(
  program: String,
  budget: Option(Int),
  details: List(#(String, json.JsonValue)),
  content: List(message.ToolResultBlock),
  source: Source,
) -> ProgramCard {
  let said = content |> list.map(result_text) |> string.join("\n")
  let status = string_field(details, "status") |> option.unwrap("")
  let #(state, error) = case status {
    "compile_failed" -> #(
      CompileFailed,
      string_field(details, "detail") |> option.unwrap(said),
    )
    "vetting_rejected" -> #(Rejected, said)
    "program_failed" -> #(
      ProgramFailed,
      string_field(details, "message") |> option.unwrap(said),
    )
    _ -> #(RunFailed, said)
  }
  let text = error |> text_hygiene.multiline |> string.trim
  let diagnostic = case state {
    CompileFailed -> parse_diagnostic(text)
    Running | Completed | Rejected | RunFailed | ProgramFailed -> None
  }
  let log = call_tree.read(json.Object(details))
  ProgramCard(
    state:,
    status_word: transcript_lines.status_title(status),
    outcome: failed_sentence(state, log, diagnostic),
    chips: chips(log),
    count_words: option.map(log, count_words),
    elapsed_ms: option.map(log, fn(log) { log.elapsed_ms }),
    budget_ms: budget,
    program: program_of(
      program,
      source,
      option.map(diagnostic, fn(found) { found.line }),
    ),
    calls: option.map(log, call_table),
    failure: Some(Failure(
      foot: failure_foot(state, budget),
      text:,
      lines: list.length(string.split(text, "\n")),
      diagnostic:,
    )),
    value: None,
  )
}

// --- the program --------------------------------------------------------

// The program's line count and opening, and the whole text when the host
// keeps it. The opening skips blank lines, so the lines shown are ones that
// say something; each keeps the number it has in the program.
fn program_of(
  program: String,
  source: Source,
  failing_line: Option(Int),
) -> Program {
  let lines = string.split(string.trim_end(program), "\n")
  Program(
    lines: list.length(lines),
    opening: lines
      |> list.index_map(fn(line, index) {
        SourceLine(index + 1, text_hygiene.single_line(line))
      })
      |> list.filter(fn(line) { string.trim(line.text) != "" })
      |> list.take(opening_lines),
    whole: case source {
      OpeningOnly -> None
      Whole(cut:) -> Some(program |> cut |> text_hygiene.multiline)
    },
    failing_line:,
  )
}

// --- the outcome sentence -----------------------------------------------

// What a capability does to the world, which is all the sentence says about
// it. `Git` is split because a status and a commit are both git commands to a
// reader, and only the commit is a side effect.
type Family {
  FileRead
  Search
  CodeLookup
  GitRead
  GitWrite
  FileWrite
  Command
  Request
  Other
}

// The closed table. A capability is `module.function`, and a function the
// table does not name is `Other` rather than a guess.
fn family(cap: String) -> Family {
  case string.split_once(cap, ".") {
    Ok(#(module, function)) -> family_of(module, function)
    Error(Nil) -> Other
  }
}

fn family_of(module: String, function: String) -> Family {
  case module, function {
    "fs", "read" -> FileRead
    "fs", "list" -> Search
    "fs", "write" | "fs", "edit" -> FileWrite
    "search", _ -> Search
    "lsp", "rename" -> FileWrite
    "lsp", _ | "lsp_sql", _ -> CodeLookup
    "git", "add" | "git", "commit" -> GitWrite
    "git", _ -> GitRead
    "proc", "run" -> Command
    "job", "start"
    | "job", "start_within"
    | "job", "start_for_session"
    | "job", "send"
    | "job", "send_last"
    | "job", "kill"
    -> Command
    "net", _ -> Request
    _, _ -> Other
  }
}

// The calls that took effect or may have: everything the program did not see
// fail and did not cancel. An unsettled call is in, since it may have run.
fn live(log: CallLog) -> List(Call) {
  list.filter(log.items, fn(call) {
    case call.status {
      call_tree.Settled | call_tree.Unsettled -> True
      call_tree.Failed | call_tree.Cancelled -> False
    }
  })
}

fn tally(calls: List(Call), families: List(Family)) -> Int {
  list.count(calls, fn(call) { list.contains(families, family(call.cap)) })
}

// The sentence of a program that returned. The phrases come first in a fixed
// order, so two programs that did the same read the same.
fn completed_sentence(log: Option(CallLog)) -> String {
  case log {
    None -> "Completed"
    Some(log) -> {
      let calls = live(log)
      let unlisted = log.total - list.length(log.items)
      let said =
        list.flatten([
          phrase(tally(calls, [FileRead]), "read", "file", "files"),
          phrase(tally(calls, [Search]), "searched", "time", "times"),
          phrase(tally(calls, [CodeLookup]), "looked up code", "time", "times"),
          phrase(
            tally(calls, [GitRead, GitWrite]),
            "ran",
            "git command",
            "git commands",
          ),
          phrase(tally(calls, [FileWrite]), "wrote", "file", "files"),
          phrase(tally(calls, [Command]), "ran", "command", "commands"),
          phrase(
            tally(calls, [Request]),
            "made",
            "network request",
            "network requests",
          ),
          other_phrase(tally(calls, [Other]), unlisted),
          failed_phrase(log.failed),
        ])
      case said, log.total {
        [], 0 -> "Ran with no calls"
        [], total -> "Made " <> counted(total, "call", "calls")
        _, _ -> said |> string.join(", ") |> string.capitalise
      }
    }
  }
}

// `read 2 files`, or nothing for a count of zero.
fn phrase(count: Int, verb: String, one: String, many: String) -> List(String) {
  case count {
    0 -> []
    n -> [verb <> " " <> counted(n, one, many)]
  }
}

// The calls the table does not sort, together with those the host counted
// and did not itemise: neither is guessed at.
fn other_phrase(other: Int, unlisted: Int) -> List(String) {
  case other + unlisted {
    0 -> []
    n -> [counted(n, "other call", "other calls")]
  }
}

fn failed_phrase(failed: Int) -> List(String) {
  case failed {
    0 -> []
    n -> [int.to_string(n) <> " failed"]
  }
}

// The sentence of a program that did not complete.
fn failed_sentence(
  state: State,
  log: Option(CallLog),
  diagnostic: Option(Diagnostic),
) -> String {
  case state, log {
    CompileFailed, _ ->
      case diagnostic {
        Some(found) -> "Compile error, line " <> int.to_string(found.line)
        None -> "Compile error"
      }
    Rejected, _ -> "Refused by vetting"
    RunFailed, Some(log) ->
      case log.unsettled {
        0 -> "Stopped before it finished"
        n ->
          "Stopped before it finished, "
          <> counted(n, "call", "calls")
          <> " not settled"
      }
    RunFailed, None -> "Stopped before it finished"
    ProgramFailed, Some(log) ->
      case log.failed {
        0 -> "The program reported a failure"
        n ->
          "Failed: "
          <> int.to_string(n)
          <> " of "
          <> counted(log.total, "call", "calls")
      }
    ProgramFailed, None -> "The program reported a failure"
    Running, _ | Completed, _ -> "The program did not finish"
  }
}

// What the foot of a failed card says, in the words the terminal's block
// uses for the same failure.
fn failure_foot(state: State, budget: Option(Int)) -> String {
  case state {
    CompileFailed | Rejected -> "the program did not run"
    RunFailed ->
      "the program was stopped"
      <> case budget {
        Some(ms) -> " · budget " <> budget_words(ms)
        None -> ""
      }
    ProgramFailed -> "the program reported a failure"
    Running | Completed -> "the program did not finish"
  }
}

/// A budget in the words a reader says it: whole minutes, whole seconds, or
/// milliseconds.
///
/// ## Examples
///
/// ```gleam
/// assert program_card.budget_words(300_000) == "5m"
/// assert program_card.budget_words(30_000) == "30s"
/// assert program_card.budget_words(1500) == "1500ms"
/// ```
pub fn budget_words(ms: Int) -> String {
  case ms >= 60_000 && ms % 60_000 == 0, ms % 1000 == 0 {
    True, _ -> int.to_string(ms / 60_000) <> "m"
    False, True -> int.to_string(ms / 1000) <> "s"
    False, False -> int.to_string(ms) <> "ms"
  }
}

// The header's account of the calls: the plain count when every call
// settled, and the record's whole summary when any did not.
fn count_words(log: CallLog) -> String {
  case log.failed + log.cancelled + log.unsettled {
    0 -> counted(log.total, "call", "calls")
    _ -> call_tree.summary(log)
  }
}

// --- the chips ----------------------------------------------------------

// The side effects and the failures, only those there were. A write, a
// command and a request are the calls that change something outside the
// program, so they are marked; a read is not.
fn chips(log: Option(CallLog)) -> List(Chip) {
  case log {
    None -> []
    Some(log) -> {
      let calls = live(log)
      [
        Chip(Wrote, tally(calls, [FileWrite])),
        Chip(Ran, tally(calls, [Command, GitWrite])),
        Chip(Network, tally(calls, [Request])),
        Chip(FailedCalls, log.failed),
      ]
      |> list.filter(fn(chip) { chip.count > 0 })
    }
  }
}

/// A chip's words (`wrote 2`, `ran 4 commands`, `network 1`, `failed 1`).
///
/// ## Examples
///
/// ```gleam
/// assert program_card.chip_words(program_card.Chip(program_card.Ran, 1))
///   == "ran 1 command"
/// ```
pub fn chip_words(chip: Chip) -> String {
  case chip.kind {
    Wrote -> "wrote " <> int.to_string(chip.count)
    Ran -> "ran " <> counted(chip.count, "command", "commands")
    Network -> "network " <> int.to_string(chip.count)
    FailedCalls -> "failed " <> int.to_string(chip.count)
  }
}

// --- the calls ----------------------------------------------------------

// The record's calls as rows. Consecutive calls to one capability that
// ended the same way are one row, as the terminal groups them, and each row
// is placed on the span of the whole execution.
fn call_table(log: CallLog) -> CallTable {
  let axis_ms = axis(log)
  CallTable(
    summary: call_tree.summary(log),
    rows: log.items
      |> grouped
      |> list.map(fn(group) { row(group.0, group.1, axis_ms) }),
    unlisted: log.total - list.length(log.items),
    axis_ms:,
  )
}

/// The span the bars of a record are drawn against: the execution's elapsed
/// time, or the end of its last call when a call ends after the elapsed time
/// says the execution did, and never less than one millisecond.
///
/// ## Examples
///
/// ```gleam
/// // program_card.axis(log) >= 1
/// ```
pub fn axis(log: CallLog) -> Int {
  list.fold(log.items, int.max(1, log.elapsed_ms), fn(span, call) {
    int.max(span, call.start_ms + call.duration_ms)
  })
}

// Consecutive calls that share a capability, an ending and an error code,
// each run as its first call and every call it holds, in order.
fn grouped(calls: List(Call)) -> List(#(Call, List(Call))) {
  calls
  |> list.fold([], fn(groups: List(#(Call, List(Call))), call) {
    case groups {
      [#(first, members), ..rest]
        if first.cap == call.cap
        && first.status == call.status
        && first.error == call.error
      -> [#(first, [call, ..members]), ..rest]
      [_, ..] | [] -> [#(call, [call]), ..groups]
    }
  })
  |> list.map(fn(group) { #(group.0, list.reverse(group.1)) })
  |> list.reverse
}

fn row(first: Call, members: List(Call), axis_ms: Int) -> CallRow {
  let start =
    list.fold(members, first.start_ms, fn(earliest, call) {
      int.min(earliest, call.start_ms)
    })
  let end =
    list.fold(members, 0, fn(latest, call) {
      int.max(latest, call.start_ms + call.duration_ms)
    })
  CallRow(
    cap: text_hygiene.single_line(first.cap),
    count: list.length(members),
    status: first.status,
    error: option.map(first.error, transcript_lines.error_words),
    args: args_row(members),
    duration_ms: list.fold(members, 0, fn(total, call) {
      total + call.duration_ms
    }),
    bar: bar(axis_ms, start, end, first.status),
    members: list.map(members, fn(call) {
      Member(
        args: option.map(call.args, text_hygiene.single_line),
        start_ms: call.start_ms,
        duration_ms: call.duration_ms,
      )
    }),
  )
}

// A run's argument summaries on one line, cut to a row.
fn args_row(members: List(Call)) -> String {
  let joined =
    members
    |> list.filter_map(fn(call) {
      option.to_result(call.args, Nil) |> result.map(text_hygiene.single_line)
    })
    |> string.join(" · ")
  case string.drop_start(joined, args_limit) {
    "" -> joined
    _ -> string.slice(joined, 0, args_limit - 1) <> "…"
  }
}

/// A call's place on a time axis of `axis_ms` milliseconds, from its start to
/// its end, as whole percentages.
///
/// The offset is kept below 100 and the width at least 1, so a call too short
/// to see is still a mark and one at the very end still fits inside the
/// track. A call that was still running when the program ended
/// (`Unsettled`) has no end of its own, so its bar runs to the end of the
/// axis. An axis of zero or less is read as one millisecond.
///
/// ## Examples
///
/// ```gleam
/// assert program_card.bar(1000, 100, 600, call_tree.Settled)
///   == program_card.Bar(offset: 10, width: 50)
/// assert program_card.bar(0, 0, 0, call_tree.Settled)
///   == program_card.Bar(offset: 0, width: 1)
/// ```
pub fn bar(axis_ms: Int, start_ms: Int, end_ms: Int, status: Status) -> Bar {
  let axis = int.max(1, axis_ms)
  let offset = int.clamp(start_ms * 100 / axis, min: 0, max: 99)
  let end = case status {
    call_tree.Unsettled -> axis
    call_tree.Settled | call_tree.Failed | call_tree.Cancelled ->
      int.max(end_ms, start_ms)
  }
  let span = int.max(0, end - start_ms) * 100 / axis
  Bar(offset:, width: int.clamp(span, min: 1, max: 100 - offset))
}

// --- the value ----------------------------------------------------------

// The program's value as the card shows it: the kind of value and a hint
// per key from the terminal's preview, and the whole value when the host
// keeps it. A result with no `value` has its text as the value.
fn value_of(
  details: List(#(String, json.JsonValue)),
  content: List(message.ToolResultBlock),
  source: Source,
) -> Value {
  let value = case list.key_find(details, "value") {
    Ok(value) -> value
    Error(Nil) ->
      json.String(content |> list.map(result_text) |> string.join("\n"))
  }
  let #(kind, hints) = case transcript_lines.value_preview(value) {
    [first, ..hints] -> #(
      string.split_once(first, "RESULT · ")
        |> result.map(fn(parts) { parts.1 })
        |> result.unwrap(first),
      list.map(hints, string.trim),
    )
    [] -> #("", [])
  }
  Value(kind:, hints:, whole: case source {
    OpeningOnly -> None
    Whole(cut:) ->
      Some(
        case value {
          json.String(text) -> text
          other -> json.to_string(other)
        }
        |> cut
        |> text_hygiene.multiline,
      )
  })
}

// --- the compiler's diagnostic --------------------------------------------

// A Gleam diagnostic opens with `error: …`, names its place on a
// `┌─ path:line:column` line, and quotes the source under numbered `│`
// gutters with a row of carets under the line it means. A text that has no
// place or quotes no source is not a diagnostic the card can lay out, and
// the card shows it as it came.
fn parse_diagnostic(text: String) -> Option(Diagnostic) {
  case string.split(text, "\n") {
    [heading, ..rest] ->
      case list.find_map(rest, place_of) {
        Ok(#(path, line, column)) -> {
          let rows = list.filter_map(rest, row_of)
          case list.any(rows, is_quoted) {
            True -> Some(Diagnostic(heading:, path:, line:, column:, rows:))
            False -> None
          }
        }
        Error(Nil) -> None
      }
    [] -> None
  }
}

// The path, line and column of a `┌─ path:line:column` row.
fn place_of(row: String) -> Result(#(String, Int, Int), Nil) {
  use #(_, place) <- result.try(string.split_once(row, "┌─ "))
  case list.reverse(string.split(string.trim(place), ":")) {
    [column, line, ..path] -> {
      use column <- result.try(int.parse(column))
      use line <- result.try(int.parse(line))
      Ok(#(string.join(list.reverse(path), ":"), line, column))
    }
    _ -> Error(Nil)
  }
}

// A row of the report below its place: quoted source, the carets under it,
// or a note. The place row and the empty gutters between rows are none of
// these.
fn row_of(row: String) -> Result(DiagRow, Nil) {
  let trimmed = string.trim_start(row)
  case string.contains(row, "┌─ "), string.split_once(trimmed, " │") {
    True, _ -> Error(Nil)
    False, Ok(#(number, text)) ->
      case int.parse(number) {
        Ok(number) -> Ok(Quoted(number, drop_space(text)))
        Error(Nil) -> gutter_row(trimmed)
      }
    False, Error(Nil) -> gutter_row(trimmed)
  }
}

fn gutter_row(trimmed: String) -> Result(DiagRow, Nil) {
  case string.split_once(trimmed, "│"), string.trim(trimmed) {
    _, "" -> Error(Nil)
    Ok(#("", text)), _ ->
      case string.trim(text) {
        "" -> Error(Nil)
        _ ->
          case string.contains(text, "^") {
            True -> Ok(Pointer(drop_space(text)))
            False -> Ok(Note(string.trim(text)))
          }
      }
    _, _ -> Ok(Note(string.trim(trimmed)))
  }
}

fn drop_space(text: String) -> String {
  case string.starts_with(text, " ") {
    True -> string.drop_start(text, 1)
    False -> text
  }
}

fn is_quoted(row: DiagRow) -> Bool {
  case row {
    Quoted(..) -> True
    Pointer(..) | Note(..) -> False
  }
}

// --- which sections are open ---------------------------------------------

/// Which parts of `card` a view draws open before the reader touches it.
///
/// A program that failed, or whose calls failed, opens on what went wrong and
/// keeps its program shut; a program that is running opens on its program,
/// since nothing else is known; a program that completed with nothing wrong
/// is one line, and shows its program, its calls and its value once opened.
///
/// ## Examples
///
/// ```gleam
/// // program_card.opening(card).card == program_card.Collapsed
/// ```
pub fn opening(card: ProgramCard) -> Opening {
  let trouble = list.any(card.chips, fn(chip) { chip.kind == FailedCalls })
  case card.state, trouble {
    Running, _ ->
      Opening(
        card: Expanded,
        program: Expanded,
        calls: Collapsed,
        result: Collapsed,
      )
    Completed, False ->
      Opening(
        card: Collapsed,
        program: Expanded,
        calls: Expanded,
        result: Expanded,
      )
    Completed, True ->
      Opening(
        card: Expanded,
        program: Collapsed,
        calls: Expanded,
        result: Collapsed,
      )
    CompileFailed, _ | Rejected, _ | RunFailed, _ | ProgramFailed, _ ->
      Opening(
        card: Expanded,
        program: Collapsed,
        calls: Expanded,
        result: Collapsed,
      )
  }
}

// --- reading the call and its result --------------------------------------

fn counted(count: Int, one: String, many: String) -> String {
  int.to_string(count)
  <> " "
  <> case count {
    1 -> one
    _ -> many
  }
}

fn result_text(block: message.ToolResultBlock) -> String {
  case block {
    message.ToolResultText(text:, ..) -> text
    message.ToolResultImage(mime_type:, ..) -> "[image " <> mime_type <> "]"
  }
}

fn string_field(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Option(String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Some(value)
    _ -> None
  }
}

fn int_field(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Option(Int) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) -> Some(value)
    _ -> None
  }
}

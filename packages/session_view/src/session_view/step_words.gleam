//// How one step of a turn reads: a short verb, what it acted on, and for an
//// edit how many lines it changed. `Read calc.py`, `Edit calc.py +3 −1`,
//// `Ran python3 -m unittest`, `Memory · 4 lines`, `Reasoning · 4s`.
////
//// A tool call's own summary (`transcript_lines.call_summary`) names the tool
//// the way the model spelled it: `fs_edit · calc.py`. That is the right word
//// for a reader who is debugging the harness and the wrong one for a reader
//// following the work, who wants to know what happened to which file. This
//// module is the one place that turns a tool's name and arguments into the
//// words a reader scans, so a host that draws a step (the web view's fold)
//// and a host that wants the same line as text (`text`) agree on the words
//// and neither writes a second table.
////
//// The table decides three things and nothing else. The **verb** is fixed
//// here for every tool the harness ships and falls back to the tool's own
//// name for one it does not know, so an MCP tool still says what ran. The
//// **subject** is what the call acted on, tagged with how a host draws it:
//// a path or command is code and keeps a monospace face (`Mono`), a name or
//// purpose is prose (`Prose`), a count or a time is a quiet figure
//// (`Figure`). The **change** is the lines an edit added and removed, read
//// from the diff the edit's own result reported, so a call with no result
//// yet has none and a failed edit never claims one.
////
//// Everything a subject holds is session text: a path or a command the
//// model wrote, a purpose it gave a sub-agent. A host draws it as a text
//// node and never as an attribute, class or key; the tag says only which
//// face to use. The module is portable: it imports `core`, other
//// `session_view` modules and the standard library, holds no `@external`,
//// and performs no I/O.
////
//// ## Flow
////
//// `of_call` → `first_call`
////
//// 1. `of_call` reads a call's name and arguments, and its result when one is
////    in the window, and returns the call's `Words`.
//// 2. `first_call` names the first capability a code-mode program calls, so
////    the step says what the program did and not only that one ran. It reads
////    the program's own text and runs nothing.
//// 3. `memory`, `reasoning`, `worked` and `returned` are the words of the
////    rows that are not tool calls, and `text` is any of them as one line.

import core/json.{type JsonValue}
import core/message
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene
import session_view/tool_activity

/// The most characters of a command, a purpose or a pattern a step keeps. A
/// longer one ends in `…`; the step's expansion holds the whole call.
pub const subject_limit = 96

/// The most characters of a shell command a step's summary keeps. A longer
/// command is cut back to the end of its last whole word and ends in `…`;
/// the step's open body holds the whole command as its first line.
pub const command_limit = 80

/// The most characters of a path a step keeps. A longer path keeps its end,
/// which is the part that tells two files apart.
pub const path_limit = 80

// How many lines of a program `first_call` reads before it gives up. A
// program that calls nothing in its first lines is not worth a longer scan
// for a one-line summary.
const scan_lines = 200

/// What a step's words say about the thing the step acted on, and how a host
/// draws it.
pub type Subject {
  /// A path, a command or a program call: code, drawn in the monospace face.
  Mono(text: String)

  /// A name or a purpose: prose, drawn in the page's own face.
  Prose(text: String)

  /// A count or a time after the verb, drawn quiet: `4 lines`, `4s`.
  Figure(text: String)

  /// The verb says everything.
  Unnamed
}

/// The lines an edit changed.
pub type Change {
  Change(
    /// Lines the edit added.
    added: Int,
    /// Lines the edit removed.
    removed: Int,
  )
}

/// One step as a reader scans it.
pub type Words {
  Words(
    /// The action, fixed here for a known tool and the tool's own name for
    /// one this table does not list.
    verb: String,
    /// What the action was done to.
    subject: Subject,
    /// The lines an edit changed, once its result says.
    change: Option(Change),
  )
}

/// The words of one tool call, from its arguments and its result when the
/// window holds one.
///
/// ## Examples
///
/// ```gleam
/// // of_call(call to fs_edit of "calc.py" whose diff added 3 lines, removed 1)
/// //   == Words("Edit", Mono("calc.py"), Some(Change(3, 1)))
/// ```
pub fn of_call(call: tool_activity.Call) -> Words {
  let name = call.invocation.name
  let arguments = call.invocation.arguments
  case name {
    "bash" ->
      named("Ran", Mono, text_field(arguments, "command"), command)
      |> or_name(name, arguments)
    "fs_read" | "read" ->
      named("Read", Mono, text_field(arguments, "path"), path)
      |> or_name(name, arguments)
    "fs_edit" ->
      case text_field(arguments, "path") {
        Some(target) -> Words("Edit", Mono(path(target)), changed(call.outcome))
        None -> generic(name, arguments)
      }
    "fs_write" ->
      named("Wrote", Mono, text_field(arguments, "path"), path)
      |> or_name(name, arguments)
    "grep" -> searched(arguments)
    "agent_spawn" ->
      named("Spawned", Prose, text_field(arguments, "purpose"), clip)
      |> or_name(name, arguments)
    "agent_wait" -> waited(arguments)
    "agent_send" ->
      named("Messaged", Prose, text_field(arguments, "to"), clip)
      |> or_name(name, arguments)
    "agent_note" -> Words("Noted", keyed(text_field(arguments, "key")), None)
    "agent_notes" -> Words("Listed notes", Unnamed, None)
    "remember" -> Words("Remembered", Prose("a durable note"), None)
    "context_remaining" -> Words("Checked context", Unnamed, None)
    "todo" -> todo_words(arguments)
    "code_mode" -> program(arguments)
    _ -> generic(name, arguments)
  }
}

/// The words of the memory context the daemon attached to a run, counted in
/// the digest's lines: `Memory · 4 lines`.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.text(step_words.memory(4)) == "Memory · 4 lines"
/// ```
pub fn memory(lines: Int) -> Words {
  Words("Memory", Figure(counted(lines, "line", "lines")), None)
}

/// The words of a reasoning block: `Reasoning · 4s`, or `Reasoning` when the
/// records give no time. The time is the response's, from the record before
/// it to the response's own, since a response's reasoning is not stamped
/// apart from its text and calls.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.text(step_words.reasoning(Some(4000))) == "Reasoning · 4s"
/// ```
pub fn reasoning(took_ms: Option(Int)) -> Words {
  reasoning_of(Raw, None, took_ms)
}

/// Whose words a reasoning block holds.
pub type Provenance {
  /// The model's own reasoning text.
  Raw

  /// A summary the provider wrote of reasoning it did not send. The terminal
  /// names it so a reader never takes it for the model's own words.
  Summarized
}

/// The words of a reasoning block as the terminal says them: the verb names a
/// summary (`Reasoning (summarized)`), and the figure is the line count, when
/// there is more to open than the row shows, then the time, each left out when
/// it is not known: `Reasoning (summarized) · 162 lines · 54s`.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.text(step_words.reasoning_of(
///     step_words.Summarized,
///     Some(162),
///     Some(54_000),
///   ))
///   == "Reasoning (summarized) · 162 lines · 54s"
/// ```
pub fn reasoning_of(
  provenance: Provenance,
  lines: Option(Int),
  took_ms: Option(Int),
) -> Words {
  let verb = case provenance {
    Raw -> "Reasoning"
    Summarized -> "Reasoning (summarized)"
  }
  let figures =
    list.append(
      case lines {
        Some(count) -> [counted(count, "line", "lines")]
        None -> []
      },
      case took_ms {
        Some(ms) -> [duration(ms)]
        None -> []
      },
    )
  case figures {
    [] -> Words(verb, Unnamed, None)
    [_, ..] -> Words(verb, Figure(string.join(figures, " · ")), None)
  }
}

/// A turn's fold summary: `Worked 22s · 10 steps · 2 files`, leaving out a
/// figure the records did not give.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.worked(Some(22_000), 10, 2)
///   == "Worked 22s · 10 steps · 2 files"
/// ```
pub fn worked(duration_ms: Option(Int), steps: Int, files: Int) -> String {
  worked_with_failures(duration_ms, steps, files, 0)
}

/// The same summary with the number of calls that failed, when it is not
/// zero: `Worked 22s · 10 steps · 2 files · 1 failed`.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.worked_with_failures(Some(22_000), 10, 2, 1)
///   == "Worked 22s · 10 steps · 2 files · 1 failed"
/// ```
pub fn worked_with_failures(
  duration_ms: Option(Int),
  steps: Int,
  files: Int,
  failed: Int,
) -> String {
  let time = case duration_ms {
    Some(ms) -> "Worked " <> duration(ms)
    None -> "Worked"
  }
  [
    time,
    counted_or_none(steps, "step", "steps"),
    counted_or_none(files, "file", "files"),
    counted_or_none(failed, "failed", "failed"),
  ]
  |> list.filter(fn(part) { part != "" })
  |> string.join(" · ")
}

/// How a sub-agent's result reads after its tag: `finished` for a child that
/// completed, and the child's own outcome word for any other.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.returned("completed") == "finished"
/// assert step_words.returned("failed") == "failed"
/// ```
pub fn returned(outcome: String) -> String {
  case outcome {
    "completed" -> "finished"
    other -> other
  }
}

/// A report whose line breaks arrived as the two characters `\n` read with
/// real ones.
///
/// A model that double-escapes its report writes `# calc \n Tiny calculator.`
/// on one line, and a host that draws it as it came shows the backslash. The
/// repair applies only to text that has no line break of its own, so a report
/// that is already laid out in lines, and may legitimately quote `\n` in a
/// program, is left as it is.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.spoken_breaks("# calc \\n Tiny") == "# calc \n Tiny"
/// assert step_words.spoken_breaks("a\nb \\n c") == "a\nb \\n c"
/// ```
pub fn spoken_breaks(text: String) -> String {
  case string.contains(text, "\n") {
    True -> text
    False -> string.replace(text, "\\n", "\n")
  }
}

/// The plain sentence a failed step opens on, before the engine's own text.
///
/// The engine words its refusals for the model: `invalid arguments: `from` is
/// required for this hunk op`. A reader following the work wants to know which
/// step was refused and why, in words that name no tool. A refusal of the
/// arguments is `The edit was rejected: "from" is required for this hunk op.`,
/// with the backticks turned into quotation marks, and any other failure is
/// only that the step failed, since the engine's text beneath it says the rest.
///
/// ## Examples
///
/// ```gleam
/// let words = Words("Edit", Mono("calc.py"), None)
/// assert step_words.failure_sentence(words, "invalid arguments: `from` is required")
///   == "The edit was rejected: \"from\" is required."
/// assert step_words.failure_sentence(words, "no such file") == "The edit failed."
/// ```
pub fn failure_sentence(words: Words, engine: String) -> String {
  let step = step_noun(words.verb)
  case string.trim(engine) {
    "invalid arguments: " <> reason ->
      step
      <> " was rejected: "
      <> string.replace(text_hygiene.single_line(reason), "`", "\"")
      <> "."
    _ -> step <> " failed."
  }
}

// The step as a sentence's subject: the verb's own noun for a tool the table
// knows, and a neutral phrase for any other.
fn step_noun(verb: String) -> String {
  case verb {
    "Edit" -> "The edit"
    "Read" -> "The read"
    "Ran" -> "The command"
    "Wrote" -> "The write"
    "Searched" -> "The search"
    "Spawned" -> "The sub-agent spawn"
    "Messaged" -> "The message"
    "Todo" -> "The todo update"
    "code_mode" -> "The program"
    _ -> "This step"
  }
}

/// The most characters a collapsed result line keeps before its ellipsis.
pub const result_limit = 140

/// The first line of a report that says something, as the line a reader scans:
/// without the Markdown marker it opens with or the backticks of a code span,
/// and cut at a word boundary to `result_limit` characters. A cut ends in an
/// ellipsis inside the line, so a host that keeps the line on one row shows it
/// at the end of that row and not on a row of its own. A report with no text
/// is the empty string.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.result_line("# Summary\n\nFound two files.") == "Summary"
/// assert step_words.result_line("") == ""
/// ```
pub fn result_line(report: String) -> String {
  let line =
    report
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.find(fn(line) { line != "" })
    |> result.unwrap("")
    |> string.replace("`", "")
  let bare = case line {
    "# " <> rest
    | "## " <> rest
    | "### " <> rest
    | "> " <> rest
    | "- " <> rest
    | "* " <> rest -> string.trim(rest)
    _ -> line
  }
  case string.length(bare) > result_limit {
    True ->
      at_word(
        string.slice(bare, 0, result_limit),
        string.slice(bare, result_limit, 1),
      )
      <> "…"
    False -> bare
  }
}

// A cut line backed up to the end of its last whole word, so the ellipsis
// follows a word and not half of one. A cut that ends at a word's end (the
// next character is a space) and a cut with no space in it keep every
// character.
fn at_word(cut: String, next: String) -> String {
  case next, list.reverse(string.split(cut, " ")) {
    " ", _ -> cut
    _, [_partial, first, ..rest] ->
      string.join(list.reverse([first, ..rest]), " ")
    _, _ -> cut
  }
}

/// A duration as a step reads it: `<1s`, seconds under a minute, minutes and
/// seconds under an hour, then hours and minutes.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.duration(48_000) == "48s"
/// assert step_words.duration(64_000) == "1m 4s"
/// assert step_words.duration(7_260_000) == "2h 1m"
/// ```
pub fn duration(ms: Int) -> String {
  let seconds = int.max(0, ms) / 1000
  case seconds >= 3600, seconds >= 60, seconds >= 1 {
    True, _, _ ->
      int.to_string(seconds / 3600)
      <> "h "
      <> int.to_string(seconds % 3600 / 60)
      <> "m"
    False, True, _ ->
      int.to_string(seconds / 60) <> "m " <> int.to_string(seconds % 60) <> "s"
    False, False, True -> int.to_string(seconds) <> "s"
    False, False, False -> "<1s"
  }
}

/// A step's words as one line of text, for a host that draws no typography:
/// `Edit calc.py +3 −1`.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.text(Words("Read", Mono("calc.py"), None)) == "Read calc.py"
/// ```
pub fn text(words: Words) -> String {
  let subject = case words.subject {
    Mono(text) | Prose(text) -> " " <> text
    Figure(text) -> " · " <> text
    Unnamed -> ""
  }
  words.verb <> subject <> change_text(words.change)
}

/// The change as it is written after the subject: ` +3 −1`, or nothing when
/// there is none. The minus is U+2212, which lines up with the plus.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.change_text(Some(Change(3, 1))) == " +3 −1"
/// ```
pub fn change_text(change: Option(Change)) -> String {
  case change {
    Some(Change(added:, removed:)) ->
      " +" <> int.to_string(added) <> " −" <> int.to_string(removed)
    None -> ""
  }
}

/// The first capability a `code_mode` program calls, with its first argument
/// when that is a string literal: `fs.read calc.py`. `None` when the program
/// imports no capability module or calls none in its first lines.
///
/// A capability is a module the program imports from the prelude
/// (`import cap/fs`), called as `fs.read("calc.py")`. The reader looks at the
/// program's text and nothing more, so a call made through a helper
/// function, a variable or a generated name is not found and the step says
/// only `code_mode`. This stands in for the trace view's own fold of a
/// program's calls; the step should read that once the trace view exists.
///
/// ## Examples
///
/// ```gleam
/// assert step_words.first_call("import cap/fs\n\npub fn main() {\n  fs.read(\"calc.py\")\n}")
///   == Some("fs.read calc.py")
/// ```
pub fn first_call(program: String) -> Option(String) {
  let lines = string.split(program, "\n") |> list.take(scan_lines)
  let modules = list.filter_map(lines, imported)
  lines
  |> list.filter(fn(line) { !string.starts_with(string.trim(line), "import ") })
  |> list.find_map(called(_, modules))
  |> option.from_result
}

// A call's verb, subject and the way the subject is clipped, or nothing when
// the arguments do not carry the field. `or_name` turns nothing into the
// generic words, so a malformed call still says which tool it was.
fn named(
  verb: String,
  tag: fn(String) -> Subject,
  field: Option(String),
  shape: fn(String) -> String,
) -> Option(Words) {
  option.map(field, fn(value) { Words(verb, tag(shape(value)), None) })
}

fn or_name(words: Option(Words), name: String, arguments: JsonValue) -> Words {
  case words {
    Some(found) -> found
    None -> generic(name, arguments)
  }
}

// A tool this table does not list, or a listed one whose arguments lack the
// field the words need: the tool's own name and what it was given.
fn generic(name: String, arguments: JsonValue) -> Words {
  let given = case arguments {
    json.Object([]) -> Unnamed
    _ -> Mono(clip(json.to_string(arguments)))
  }
  Words(clip(name), given, None)
}

fn searched(arguments: JsonValue) -> Words {
  case text_field(arguments, "pattern"), text_field(arguments, "path") {
    Some(pattern), Some(where) ->
      Words("Searched", Mono(clip(pattern) <> " in " <> path(where)), None)
    Some(pattern), None -> Words("Searched", Mono(clip(pattern)), None)
    None, _ -> generic("grep", arguments)
  }
}

fn waited(arguments: JsonValue) -> Words {
  case arguments {
    json.Object(fields) ->
      case list.key_find(fields, "handles") {
        Ok(json.Array(handles)) ->
          Words(
            "Waited for",
            Prose(counted(list.length(handles), "sub-agent", "sub-agents")),
            None,
          )
        _ -> generic("agent_wait", arguments)
      }
    _ -> generic("agent_wait", arguments)
  }
}

fn keyed(key: Option(String)) -> Subject {
  case key {
    Some(key) -> Mono(clip(key))
    None -> Unnamed
  }
}

// The `todo` call as a reader says it: `Todo · 4 tasks` for a new list,
// `Todo · done: Add modulo` for a task finished. The call's `op` is the
// tool's own vocabulary (`init`, `drop`), which is for the model, so each op
// is a word a person would use, and the task is the model's text cut to
// `task_limit` characters. A call whose `op` is missing or not one the tool
// knows keeps the op's own word, since the words are only the reader's gloss.
fn todo_words(arguments: JsonValue) -> Words {
  let op = option.unwrap(text_field(arguments, "op"), "")
  let target = todo_target(arguments)
  let said = fn(verb) { Words("Todo", Figure(verb <> target), None) }
  case op {
    "init" -> Words("Todo", Figure(planned(arguments)), None)
    "append" -> Words("Todo", Figure("added " <> planned(arguments)), None)
    "start" -> said("started")
    "done" -> said("done")
    "drop" -> said("dropped")
    "remove" -> said("removed")
    "block" -> said("blocked")
    "unblock" -> said("unblocked")
    "view" -> Words("Todo", Figure("viewed"), None)
    "" -> Words("Todo", Unnamed, None)
    other -> Words("Todo", Figure(clip_to(other, todo_task_limit)), None)
  }
}

// What a `todo` op acted on, after its verb: `: Add modulo` for a task,
// `: phase Setup` for a phase, and nothing for an op on the whole board.
fn todo_target(arguments: JsonValue) -> String {
  case text_field(arguments, "task"), text_field(arguments, "phase") {
    Some(task), _ -> ": " <> clip_to(task, todo_task_limit)
    None, Some(phase) -> ": phase " <> clip_to(phase, todo_task_limit)
    None, None -> ""
  }
}

// The most characters of a task a todo step keeps.
const todo_task_limit = 60

// How many tasks a new or extended list holds: the items of every phase of
// `phases`, or the call's own `items`.
fn planned(arguments: JsonValue) -> String {
  let items = fn(value: JsonValue) {
    case value {
      json.Object(fields) ->
        case list.key_find(fields, "items") {
          Ok(json.Array(entries)) -> list.length(entries)
          _ -> 0
        }
      _ -> 0
    }
  }
  let total = case arguments {
    json.Object(fields) ->
      case list.key_find(fields, "phases") {
        Ok(json.Array(phases)) ->
          list.fold(phases, 0, fn(n, p) { n + items(p) })
        _ -> items(arguments)
      }
    _ -> 0
  }
  case total {
    0 -> "list"
    _ -> counted(total, "task", "tasks")
  }
}

fn program(arguments: JsonValue) -> Words {
  case text_field(arguments, "program") |> option.then(first_call) {
    Some(call) -> Words("code_mode", Mono(clip(call)), None)
    None -> Words("code_mode", Unnamed, None)
  }
}

// The lines a successful edit's own result says it added and removed, counted
// from the headerless unified hunks it reported.
fn changed(outcome: Option(message.AgentMessage)) -> Option(Change) {
  case outcome {
    Some(message.ToolResultMessage(
      is_error: False,
      details: Some(json.Object(fields)),
      ..,
    )) ->
      case list.key_find(fields, "diff") {
        Ok(json.String(diff)) -> counted_change(diff)
        _ -> None
      }
    _ -> None
  }
}

fn counted_change(diff: String) -> Option(Change) {
  let #(added, removed) =
    string.split(diff, "\n")
    |> list.fold(#(0, 0), fn(total, line) {
      case string.starts_with(line, "@@"), string.first(line) {
        True, _ -> total
        False, Ok("+") -> #(total.0 + 1, total.1)
        False, Ok("-") -> #(total.0, total.1 + 1)
        False, _ -> total
      }
    })
  case added + removed {
    0 -> None
    _ -> Some(Change(added:, removed:))
  }
}

// A module the program imports from the capability prelude, as the name the
// program calls it by and the name the prelude gives it: `import cap/fs` is
// `#("fs", "fs")`, and `import cap/fs as files` is `#("files", "fs")`.
fn imported(line: String) -> Result(#(String, String), Nil) {
  case string.trim(line) {
    "import cap/" <> rest -> {
      let #(module, after) = take_name(rest)
      case module, string.split_once(after, " as ") {
        "", _ -> Error(Nil)
        _, Ok(#(_, alias)) ->
          case take_name(string.trim(alias)) {
            #("", _) -> Ok(#(module, module))
            #(local, _) -> Ok(#(local, module))
          }
        _, Error(Nil) -> Ok(#(module, module))
      }
    }
    _ -> Error(Nil)
  }
}

// The earliest call of an imported module on one line, as `module.name` and
// the first string literal after it.
fn called(
  line: String,
  modules: List(#(String, String)),
) -> Result(String, Nil) {
  modules
  |> list.filter_map(fn(pair) { call_in(line, pair.0, pair.1) })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.first
  |> result.map(fn(pair) { pair.1 })
}

// One module's first call on a line, with where on the line it stood.
fn call_in(
  line: String,
  local: String,
  module: String,
) -> Result(#(Int, String), Nil) {
  case string.split_once(line, local <> ".") {
    Error(Nil) -> Error(Nil)
    Ok(#(before, after)) ->
      case name_ends(before), take_name(after) {
        True, _ ->
          call_in(after, local, module)
          |> shifted(string.length(before) + string.length(local) + 1)
        False, #("", _) -> Error(Nil)
        False, #(function, rest) ->
          case string.starts_with(rest, "(") {
            False -> Error(Nil)
            True ->
              Ok(#(
                string.length(before),
                module <> "." <> function <> argument(rest),
              ))
          }
      }
  }
}

// A match inside a longer name (`profs.` for `fs.`) is not a call of the
// module; the search goes on after it, and its position is moved past the
// `skipped` characters it left behind.
fn shifted(
  found: Result(#(Int, String), Nil),
  skipped: Int,
) -> Result(#(Int, String), Nil) {
  result.map(found, fn(pair) { #(pair.0 + skipped, pair.1) })
}

// Whether text ends in a character a name can contain.
fn name_ends(before: String) -> Bool {
  case string.last(before) {
    Ok(grapheme) -> is_name(grapheme)
    Error(Nil) -> False
  }
}

// The call's first argument, when it is a string literal: ` literal`. Only
// the first argument is read, so a call whose first argument is a name or an
// expression says no argument, and a later call on the same line is not
// mistaken for this one's.
fn argument(rest: String) -> String {
  case string.trim_start(string.drop_start(rest, 1)) {
    "\"" <> after ->
      case string.split_once(after, "\"") {
        Ok(#("", _)) | Error(Nil) -> ""
        Ok(#(literal, _)) -> " " <> path(text_hygiene.single_line(literal))
      }
    _ -> ""
  }
}

// The leading name in text and what follows it.
fn take_name(text: String) -> #(String, String) {
  let graphemes = string.to_graphemes(text)
  let name = list.take_while(graphemes, is_name)
  #(string.concat(name), string.concat(list.drop(graphemes, list.length(name))))
}

fn is_name(grapheme: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    grapheme,
  )
}

fn text_field(value: JsonValue, name: String) -> Option(String) {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, name) {
        Ok(json.String(text)) -> Some(text)
        _ -> None
      }
    _ -> None
  }
}

// A shell command as a summary keeps it: its first line, cut at a word
// boundary so the result, ellipsis included, is at most `command_limit`
// characters, with a following line marked by a
// trailing ellipsis. The cut keeps the leading words, which name the program,
// so a leading `cd <dir> &&` is dropped first (`without_cd`): an agent that
// runs in a long worktree path starts nearly every command that way, and the
// cut would otherwise end the summary right after `cd`.
fn command(text: String) -> String {
  let shown = without_cd(string.trim(text))
  let #(line, more) = case string.split_once(shown, "\n") {
    Ok(#(first, _)) -> #(text_hygiene.single_line(first), True)
    Error(Nil) -> #(text_hygiene.single_line(shown), False)
  }
  case string.length(line) > command_limit {
    True ->
      at_word(
        string.slice(line, 0, command_limit - 1),
        string.slice(line, command_limit - 1, 1),
      )
      <> "…"
    False ->
      case more {
        True -> line <> " …"
        False -> line
      }
  }
}

// A command with its leading `cd <dir> &&` or `cd <dir> ;` removed, when a
// command follows it. The directory is one word or one quoted string. A
// command that is only a `cd`, or whose `cd` is joined by anything else (`||`,
// a pipe), is returned whole: the summary then says what the text says.
fn without_cd(text: String) -> String {
  case string.starts_with(text, "cd ") {
    False -> text
    True -> {
      let after = string.trim_start(string.drop_start(text, 3))
      let rest = string.trim_start(directory_end(after))
      let remainder = case
        string.starts_with(rest, "&&"),
        string.starts_with(rest, ";")
      {
        True, _ -> string.trim_start(string.drop_start(rest, 2))
        False, True -> string.trim_start(string.drop_start(rest, 1))
        False, False -> ""
      }
      case remainder {
        "" -> text
        _ -> remainder
      }
    }
  }
}

// What follows the directory word of a `cd`: past a quoted string when the
// word opens with a quote, and past the next space otherwise. A word holding
// a shell operator, or an unclosed quote, leaves nothing, so the command stays
// whole.
fn directory_end(after: String) -> String {
  case string.first(after) {
    Ok("'") -> past_quote(after, "'")
    Ok("\"") -> past_quote(after, "\"")
    Ok(_) ->
      case string.split_once(after, " ") {
        Ok(#(word, rest)) ->
          case string.contains(word, ";") || string.contains(word, "&") {
            True -> ""
            False -> rest
          }
        Error(Nil) -> ""
      }
    Error(Nil) -> ""
  }
}

fn past_quote(after: String, quote: String) -> String {
  case string.split_once(string.drop_start(after, 1), quote) {
    Ok(#(_, rest)) -> rest
    Error(Nil) -> ""
  }
}

fn clip(text: String) -> String {
  clip_to(text, subject_limit)
}

fn clip_to(text: String, limit: Int) -> String {
  let one_line = text_hygiene.single_line(text)
  case string.drop_start(one_line, limit) {
    "" -> one_line
    _ -> string.slice(one_line, 0, limit - 1) <> "…"
  }
}

fn path(text: String) -> String {
  text_hygiene.fit_tail(text_hygiene.single_line(text), path_limit)
}

fn counted(count: Int, one: String, many: String) -> String {
  int.to_string(count)
  <> case count {
    1 -> " " <> one
    _ -> " " <> many
  }
}

fn counted_or_none(count: Int, one: String, many: String) -> String {
  case count {
    0 -> ""
    _ -> counted(count, one, many)
  }
}

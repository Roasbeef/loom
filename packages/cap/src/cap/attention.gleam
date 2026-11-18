//// Questions for the owner and notes about what a program saw, as the
//// `ask` and `notice` tools record them. A program calls them as a model's
//// own call does, and the host holds both to the same bounds.
////
//// ## Flow
////
//// `ask` → `notice` → the id of the record
////
//// 1. Build the questions with `confirm`, `choose`, `choose_many`,
////    `checklist` or `fill`, and give a `choose`-style question its options
////    through `alternative`.
//// 2. `ask(questions, to: None, why: None)` records them and returns the
////    ask's id. It does not wait for the answer and it does not end your
////    turn: after the program returns, end the turn yourself. The answer
////    arrives later as a message from the person holding one fenced JSON
////    object.
//// 3. `notice(kind, text, path: None, line: None)` records a note about
////    something outside the task and returns its id. It never stops
////    anything.
////
//// An ask must never request a secret. Credentials, tokens and keys go
//// through grants and approvals, not through a question.
////
//// ## Examples
////
//// ```gleam
//// let question =
////   attention.choose("Which branch?", [
////     attention.alternative("main"),
////     attention.alternative("topic"),
////   ])
//// let assert Ok(id) = attention.ask([question], to: None, why: None)
//// ```

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import cap/report.{type Value}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A refusal, a validation failure, or a transport failure.
pub type AttentionError {
  /// The host refused this call, retaining its error code and explanation.
  /// An out-of-bound argument and a full inbox arrive here.
  AttentionDenied(code: String, message: String)

  /// The host could not be reached or answered with an invalid value.
  AttentionUnavailable(reason: String)
}

/// Whether the model suggests an option.
pub type Emphasis {
  /// The option you suggest. At most one per question.
  Recommended

  /// An option with no suggestion attached.
  Plain
}

/// One option of a `choose`, `choose_many` or `checklist` question.
pub type Alternative {
  Alternative(
    /// What the person sees and the answer carries, at most 60 characters,
    /// unique within the question.
    label: String,
    /// What choosing it does, at most 140 characters.
    note: Option(String),
    /// Whether you suggest it.
    emphasis: Emphasis,
  )
}

/// What a `fill` question expects the text to be. None names a secret.
pub type Format {
  /// A short line of text.
  ShortText

  /// A paragraph.
  LongText

  /// A file path.
  FilePath

  /// A number, carried as the text the person typed.
  Number

  /// A URL.
  Url
}

/// What a question asks of the person.
pub type Kind {
  /// Yes or no. The answer is `true` or `false`.
  Confirm

  /// One of two to eight options. The answer is its label.
  Choose(options: List(Alternative))

  /// Between `min` and `max` of the options, where
  /// `0 <= min <= max <= the number of options`. The answer is a list of
  /// labels.
  ChooseMany(options: List(Alternative), min: Int, max: Int)

  /// Any subset of two to eight items, possibly none. The answer is a list of
  /// labels.
  Checklist(options: List(Alternative))

  /// Text of the stated format. The answer is a string.
  Fill(format: Format)
}

/// One question: what is asked, at most 300 characters, and what the person
/// gives. Every question also accepts a free-text Other, answered as `null`
/// with its text beside it, so do not add an option for it.
pub type Question {
  Question(prompt: String, kind: Kind)
}

/// What a note is.
pub type Find {
  /// A hazard.
  Risk

  /// An improvement.
  Idea

  /// A defect that is not yours to fix now.
  Bug

  /// Something you wonder about and will not stop to ask. A question that
  /// needs an answer before work continues is an `ask`.
  Wondering
}

/// A yes-or-no question.
///
/// ## Examples
///
/// ```gleam
/// attention.confirm("Retry the build?")
/// ```
pub fn confirm(prompt: String) -> Question {
  Question(prompt:, kind: Confirm)
}

/// A question answered with one of the options.
///
/// ## Examples
///
/// ```gleam
/// attention.choose("Which branch?", [
///   attention.alternative("main"),
///   attention.alternative("topic"),
/// ])
/// ```
pub fn choose(prompt: String, options: List(Alternative)) -> Question {
  Question(prompt:, kind: Choose(options:))
}

/// A question answered with between `min` and `max` of the options.
///
/// ## Examples
///
/// ```gleam
/// attention.choose_many(
///   "Which files?",
///   [attention.alternative("a.gleam"), attention.alternative("b.gleam")],
///   min: 1,
///   max: 2,
/// )
/// ```
pub fn choose_many(
  prompt: String,
  options: List(Alternative),
  min min: Int,
  max max: Int,
) -> Question {
  Question(prompt:, kind: ChooseMany(options:, min:, max:))
}

/// A question answered with any subset of the items, possibly none.
///
/// ## Examples
///
/// ```gleam
/// attention.checklist("Which of these may I delete?", [
///   attention.alternative("build/"),
///   attention.alternative("node_modules/"),
/// ])
/// ```
pub fn checklist(prompt: String, options: List(Alternative)) -> Question {
  Question(prompt:, kind: Checklist(options:))
}

/// A question answered with text.
///
/// ## Examples
///
/// ```gleam
/// attention.fill("Where should it go?", attention.FilePath)
/// ```
pub fn fill(prompt: String, format: Format) -> Question {
  Question(prompt:, kind: Fill(format:))
}

/// An option with a label and nothing else.
///
/// ## Examples
///
/// ```gleam
/// attention.alternative("main")
/// ```
pub fn alternative(label: String) -> Alternative {
  Alternative(label:, note: None, emphasis: Plain)
}

/// Puts one to four questions to the owner, or to a strand of this session
/// when `to` names one, and returns the ask's id. It records the ask and
/// returns at once, and it does not end your turn: end it yourself after the
/// program returns. The answer arrives later as a message from the person
/// holding one fenced JSON object. At most 32 asks may be open at once.
/// Capability: attention.ask. The execution allows at most 8 calls.
///
/// ## Examples
///
/// ```gleam
/// attention.ask([attention.confirm("Retry?")], to: None, why: None)
/// ```
pub fn ask(
  questions: List(Question),
  to to: Option(String),
  why why: Option(String),
) -> Result(String, AttentionError) {
  dispatch.call(
    "attention.ask",
    wire.args(
      list.flatten([
        [#("questions", report.list(list.map(questions, question_value)))],
        optional("to", to),
        optional("why", why),
      ]),
    ),
  )
  |> result.map_error(map_error)
  |> result.try(id_of)
}

/// Records a note about something you saw outside the task and returns its
/// id. It never stops anything, and you cannot edit or close it. `path` is
/// relative to the workspace, and `line` needs a `path`. At most 128 notices
/// may be open at once. Capability: attention.notice. The execution allows at
/// most 32 calls.
///
/// ## Examples
///
/// ```gleam
/// attention.notice(attention.Bug, "No backoff.", path: Some("src/retry.gleam"), line: Some(41))
/// ```
pub fn notice(
  kind: Find,
  text: String,
  path path: Option(String),
  line line: Option(Int),
) -> Result(String, AttentionError) {
  dispatch.call(
    "attention.notice",
    wire.args(
      list.flatten([
        [
          #("kind", wire.string(find_name(kind))),
          #("text", wire.string(text)),
        ],
        optional("path", path),
        case line {
          Some(number) -> [#("line", wire.int(number))]
          None -> []
        },
      ]),
    ),
  )
  |> result.map_error(map_error)
  |> result.try(id_of)
}

/// The id out of the host's `{id}` reply.
fn id_of(value: Value) -> Result(String, AttentionError) {
  wire.string_field(value, "id")
  |> result.map_error(AttentionUnavailable)
}

/// An argument present only when given.
fn optional(
  key: String,
  value: Option(String),
) -> List(#(String, report.Value)) {
  case value {
    Some(text) -> [#(key, wire.string(text))]
    None -> []
  }
}

/// One question as the tool's argument takes it.
fn question_value(question: Question) -> Value {
  // Each kind names itself and adds only the fields that kind takes, so a
  // `confirm` carries no options and a `fill` carries a format.
  let kind_fields = case question.kind {
    Confirm -> [#("kind", report.string("confirm"))]
    Choose(options:) -> [
      #("kind", report.string("choice")),
      #("options", options_value(options)),
    ]
    ChooseMany(options:, min:, max:) -> [
      #("kind", report.string("multiple")),
      #("options", options_value(options)),
      #("min", report.int(min)),
      #("max", report.int(max)),
    ]
    Checklist(options:) -> [
      #("kind", report.string("checklist")),
      #("options", options_value(options)),
    ]
    Fill(format:) -> [
      #("kind", report.string("fill")),
      #("format", report.string(format_name(format))),
    ]
  }

  report.object([#("prompt", report.string(question.prompt)), ..kind_fields])
}

/// A question's options as the tool's argument takes them.
fn options_value(options: List(Alternative)) -> Value {
  report.list(
    list.map(options, fn(option) {
      report.object(
        list.flatten([
          [#("label", report.string(option.label))],
          case option.note {
            Some(note) -> [#("note", report.string(note))]
            None -> []
          },
          case option.emphasis {
            Recommended -> [#("recommended", report.bool(True))]
            Plain -> []
          },
        ]),
      )
    }),
  )
}

/// A fill format's wire name.
fn format_name(format: Format) -> String {
  case format {
    ShortText -> "text"
    LongText -> "long_text"
    FilePath -> "path"
    Number -> "number"
    Url -> "url"
  }
}

/// A note kind's wire name.
fn find_name(kind: Find) -> String {
  case kind {
    Risk -> "risk"
    Idea -> "idea"
    Bug -> "bug"
    Wondering -> "question"
  }
}

fn map_error(error: CallError) -> AttentionError {
  case error {
    Denied(code:, message:) -> AttentionDenied(code:, message:)
    Unreachable(reason:) -> AttentionUnavailable(reason:)
  }
}

/// A one-line rendering of an `AttentionError`.
///
/// ## Examples
///
/// ```gleam
/// assert attention.error_text(attention.AttentionUnavailable("no channel"))
///   == "attention unavailable: no channel"
/// ```
///
pub fn error_text(error: AttentionError) -> String {
  case error {
    AttentionDenied(code:, message:) -> code <> ": " <> message
    AttentionUnavailable(reason:) -> "attention unavailable: " <> reason
  }
}

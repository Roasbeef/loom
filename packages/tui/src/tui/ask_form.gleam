//// One open ask as the owner fills it in at the keyboard.
////
//// An agent's `ask` tool records questions for the owner (protocol-change/119)
//// and ends its run. The terminal draws each open ask above the composer and
//// lets the owner answer it without a mouse. This module is the form behind
//// that card: the ask as the daemon stored it, the owner's draft for each
//// question, the cursor, and the keys that edit the draft. It draws nothing
//// and performs no I/O, so a test drives it with keys and reads what it would
//// send.
////
//// ## Flow
////
//// `new` → `update` → `answer` → `Send`
////
//// 1. `new` holds an ask with the revision `attention.read` returned and an
////    empty draft for every question. `refreshed` keeps the draft when the
////    same ask is read again.
//// 2. `update` takes one key. A key moves the cursor, picks an option, edits
////    the text of an Other or a fill question, leaves the form, or sends.
//// 3. `answer` turns the draft into the typed values of `core/attention` and
////    asks `core/attention_answer.check` whether the stored ask would accept
////    them. This is the daemon's own rule, so the form never offers an answer
////    the daemon would refuse for its content.
//// 4. A checked answer leaves `update` as `Send`, carrying the object that
////    `attention.answer` takes. A refused one stays in the form as words.
////
//// ## Rows
////
//// The cursor is one index over every row of every question, followed by a
//// Send row. A `confirm` question has the rows Yes and No, a `choice`,
//// `multiple` or `checklist` question has one row for each option, and each of
//// those kinds has a last row for Other. A `fill` question has one text row
//// and no Other, because its text is its answer. Choosing Other replaces the
//// options, as the daemon requires, so picking an option clears the Other text
//// and choosing Other clears the picks.
////
//// ## Typing
////
//// Enter on an Other or fill row starts typing into it. While typing, every
//// printable key is text and nothing else is a command except Enter and
//// Escape, which stop typing, and Ctrl+S, which sends. Browsing never types,
//// so a stray letter cannot enter an answer. Text is a single line.

import core/attention.{type Ask, type Question}
import core/attention_answer
import core/json.{type JsonValue}
import etui/keys
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The longest text the form accepts into one field, in bytes: the longest
/// text any question kind may carry. The daemon's rule measures the rest.
const typing_limit = 4000

/// Whether the owner may answer this ask. The daemon says so in the record it
/// reads (`may_answer`), and an observer is told no.
pub type Standing {
  /// The owner, or a member who may act, can send an answer.
  MayAnswer

  /// The ask is shown and nothing about it can be sent from here.
  ObserverOnly
}

/// Whether keys edit text or move the cursor.
pub type Entry {
  /// Keys move, pick and send.
  Browsing

  /// Keys are text for the row under the cursor, which is an Other or a fill.
  Typing
}

/// What the owner has put in for one question.
pub type Draft {
  Draft(
    /// The option rows chosen, by position in the question's options. A
    /// `confirm` has one option row for Yes and one for No.
    picked: List(Int),
    /// The text of Other when Other is the answer, and none when it is not.
    other: Option(String),
    /// The typed text of a `fill` question.
    text: String,
  )
}

/// One row the cursor can stand on.
pub type Row {
  /// An option of the question at `question`, by position.
  Pick(question: Int, option: Int)

  /// The Other row of the question at `question`.
  OtherRow(question: Int)

  /// The text row of a `fill` question.
  FillRow(question: Int)

  /// The row that sends the answer.
  SendRow
}

/// An open ask and the owner's draft of its answer.
pub type Form {
  Form(
    /// The ask as `attention.read` returned it.
    ask: Ask,
    /// The revision that read returned, which an answer must name.
    revision: Int,
    /// Whether the owner can send an answer.
    standing: Standing,
    /// One draft for each question, in question order.
    drafts: List(Draft),
    /// The row the cursor stands on, as an index into `rows`.
    cursor: Int,
    /// Whether keys are text or commands.
    entry: Entry,
    /// Why the last send did not go, in words, or none.
    refusal: Option(String),
  )
}

/// What a key asks of the form.
pub type Action {
  /// Keep the form as it now is.
  Continue(form: Form)

  /// Hand the keyboard back to the composer. The draft is kept.
  Leave(form: Form)

  /// Move the keyboard to the next ask (`by` is 1) or the previous one (-1).
  Page(form: Form, by: Int)

  /// Send the checked answer. `answer` is the object `attention.answer` takes.
  Send(form: Form, answer: JsonValue)
}

/// Why a draft is not an answer the stored ask accepts, as the owner reads it.
pub type Problem {
  Problem(
    /// The question key, `q1` to `q4`, or the field the rule named.
    key: String,
    /// Fixed words saying what is wrong. Never text the owner typed.
    words: String,
  )
}

/// Holds an ask with an empty draft for each question.
///
/// ## Examples
///
/// ```gleam
/// let form = ask_form.new(ask, 41, ask_form.MayAnswer)
/// assert form.cursor == 0
/// ```
pub fn new(ask: Ask, revision: Int, standing: Standing) -> Form {
  Form(
    ask:,
    revision:,
    standing:,
    drafts: list.map(ask.questions, fn(_) { empty_draft() }),
    cursor: 0,
    entry: Browsing,
    refusal: None,
  )
}

/// The form after the ask was read again. The same ask keeps its draft, its
/// cursor and its refusal and takes the new revision and standing; a different
/// ask under the same identifier cannot exist, but a changed one starts over.
///
/// ## Examples
///
/// ```gleam
/// let again = ask_form.refreshed(form, form.ask, 42, ask_form.MayAnswer)
/// assert again.drafts == form.drafts
/// ```
pub fn refreshed(
  form: Form,
  ask: Ask,
  revision: Int,
  standing: Standing,
) -> Form {
  // The draft is only meaningful against the questions it was made for.
  case form.ask == ask {
    True -> Form(..form, revision:, standing:)
    False -> new(ask, revision, standing)
  }
}

/// The rows of the form in drawing order: every question's rows, then Send.
///
/// ## Examples
///
/// ```gleam
/// // A confirm question and a fill question.
/// assert ask_form.rows(form)
///   == [ask_form.Pick(0, 0), ask_form.Pick(0, 1), ask_form.OtherRow(0),
///       ask_form.FillRow(1), ask_form.SendRow]
/// ```
pub fn rows(form: Form) -> List(Row) {
  let questions =
    list.index_map(form.ask.questions, fn(question, index) {
      question_rows(question, index)
    })
  list.append(list.flatten(questions), [SendRow])
}

/// The row under the cursor.
///
/// ## Examples
///
/// ```gleam
/// assert ask_form.row_at(ask_form.new(ask, 1, ask_form.MayAnswer))
///   == ask_form.Pick(0, 0)
/// ```
pub fn row_at(form: Form) -> Row {
  rows(form)
  |> list.drop(form.cursor)
  |> list.first
  |> result.unwrap(SendRow)
}

/// The rows of one question.
fn question_rows(question: Question, index: Int) -> List(Row) {
  // Each kind draws the rows its answer needs; `fill` has no options and no
  // Other, because its text is the answer.
  case question.kind {
    attention.Fill(..) -> [FillRow(index)]
    attention.Confirm -> [Pick(index, 0), Pick(index, 1), OtherRow(index)]
    attention.Choice | attention.Multiple(..) | attention.Checklist ->
      list.flatten([
        list.index_map(question.options, fn(_, option) { Pick(index, option) }),
        [OtherRow(index)],
      ])
  }
}

/// The options a question offers as choices to pick: Yes and No for a
/// `confirm`, the model's own options for the other kinds.
///
/// ## Examples
///
/// ```gleam
/// assert list.map(ask_form.options(confirm_question), fn(o) { o.label })
///   == ["Yes", "No"]
/// ```
pub fn options(question: Question) -> List(attention.Alternative) {
  case question.kind {
    attention.Confirm -> [
      attention.Alternative("Yes", None, attention.Plain),
      attention.Alternative("No", None, attention.Plain),
    ]
    attention.Choice
    | attention.Multiple(..)
    | attention.Checklist
    | attention.Fill(..) -> question.options
  }
}

/// The draft of the question at `index`, empty when the index names none.
///
/// ## Examples
///
/// ```gleam
/// assert ask_form.draft_of(form, 0).picked == []
/// ```
pub fn draft_of(form: Form, index: Int) -> Draft {
  form.drafts
  |> list.drop(index)
  |> list.first
  |> result.lazy_unwrap(empty_draft)
}

/// A draft with nothing in it.
fn empty_draft() -> Draft {
  Draft(picked: [], other: None, text: "")
}

/// Takes one key.
///
/// ## Examples
///
/// ```gleam
/// let assert ask_form.Continue(next) = ask_form.update(keys.Down, form)
/// assert next.cursor == 1
/// ```
pub fn update(key: keys.Key, form: Form) -> Action {
  case form.entry {
    Typing -> typed(key, form)
    Browsing -> browsed(key, form)
  }
}

/// A key while the cursor browses.
fn browsed(key: keys.Key, form: Form) -> Action {
  // Escape gives the keyboard back; every other key edits the form.
  case key {
    keys.Escape -> Leave(Form(..form, refusal: None))
    keys.Up -> Continue(moved(form, -1))
    keys.Down -> Continue(moved(form, 1))
    keys.Tab -> Continue(to_question(form, 1))
    keys.BackTab -> Continue(to_question(form, -1))
    keys.PageDown -> Page(form, 1)
    keys.PageUp -> Page(form, -1)
    keys.Home -> Continue(Form(..form, cursor: 0))
    keys.End -> Continue(Form(..form, cursor: last_row(form)))
    keys.Ctrl("s") -> sent(form)
    keys.Enter | keys.Char(" ") -> activated(form)

    // A letter while browsing is not text and changes nothing.
    keys.Char(_)
    | keys.Left
    | keys.Right
    | keys.Backspace
    | keys.Delete
    | keys.Insert
    | keys.F(_)
    | keys.Ctrl(_)
    | keys.Alt(_)
    | keys.Unknown(_) -> Continue(form)
  }
}

/// A key while the cursor types into an Other or a fill row.
fn typed(key: keys.Key, form: Form) -> Action {
  // Only Enter, Escape and Ctrl+S are commands while typing; the rest is text.
  case key {
    keys.Enter | keys.Escape -> Continue(Form(..form, entry: Browsing))
    keys.Ctrl("s") -> sent(form)
    keys.Backspace -> Continue(edited(form, drop_last))
    keys.Ctrl("u") -> Continue(edited(form, fn(_) { "" }))
    keys.Char(text) -> Continue(typed_text(form, text))
    keys.Up -> Continue(moved(Form(..form, entry: Browsing), -1))
    keys.Down -> Continue(moved(Form(..form, entry: Browsing), 1))
    keys.Tab -> Continue(to_question(Form(..form, entry: Browsing), 1))
    keys.BackTab -> Continue(to_question(Form(..form, entry: Browsing), -1))
    keys.Left
    | keys.Right
    | keys.Delete
    | keys.Home
    | keys.End
    | keys.PageUp
    | keys.PageDown
    | keys.Insert
    | keys.F(_)
    | keys.Ctrl(_)
    | keys.Alt(_)
    | keys.Unknown(_) -> Continue(form)
  }
}

/// Appends pasted text, kept to one line, to the field being typed into.
///
/// ## Examples
///
/// ```gleam
/// let typing = ask_form.Form(..form, entry: ask_form.Typing)
/// assert ask_form.pasted(typing, "a\nb") != typing
/// ```
pub fn pasted(form: Form, text: String) -> Form {
  // Text pasted while browsing has no field to go to and is dropped.
  case form.entry {
    Browsing -> form
    Typing -> typed_text(form, string.replace(text, "\n", " "))
  }
}

/// Text typed or pasted into the field under the cursor, up to the bound.
fn typed_text(form: Form, text: String) -> Form {
  edited(form, fn(current) {
    case string.byte_size(current) + string.byte_size(text) <= typing_limit {
      True -> current <> text
      False -> current
    }
  })
}

/// The string without its last grapheme.
fn drop_last(text: String) -> String {
  string.drop_end(text, 1)
}

/// Applies `change` to the text of the Other or fill row under the cursor.
fn edited(form: Form, change: fn(String) -> String) -> Form {
  case row_at(form) {
    OtherRow(question:) ->
      with_draft(form, question, fn(draft) {
        Draft(
          ..draft,
          picked: [],
          other: Some(change(option.unwrap(draft.other, ""))),
        )
      })
    FillRow(question:) ->
      with_draft(form, question, fn(draft) {
        Draft(..draft, text: change(draft.text))
      })
    Pick(..) | SendRow -> form
  }
}

/// Replaces the draft of one question with the result of `change`.
fn with_draft(form: Form, question: Int, change: fn(Draft) -> Draft) -> Form {
  let drafts =
    list.index_map(form.drafts, fn(draft, index) {
      case index == question {
        True -> change(draft)
        False -> draft
      }
    })
  Form(..form, drafts:, refusal: None)
}

/// The index of the Send row.
fn last_row(form: Form) -> Int {
  list.length(rows(form)) - 1
}

/// The form with the cursor moved by `by` rows, held inside the rows.
fn moved(form: Form, by: Int) -> Form {
  Form(..form, cursor: int.clamp(form.cursor + by, 0, last_row(form)))
}

/// The form with the cursor on the first row of the question `by` places away,
/// or on the Send row after the last question.
fn to_question(form: Form, by: Int) -> Form {
  // The question the cursor is in; the Send row is one past the last.
  let current = case row_at(form) {
    Pick(question:, ..) | OtherRow(question:) | FillRow(question:) -> question
    SendRow -> list.length(form.ask.questions)
  }

  let target = int.clamp(current + by, 0, list.length(form.ask.questions))
  let index =
    rows(form)
    |> list.index_map(fn(row, index) { #(index, row) })
    |> list.find(fn(entry) { first_of(entry.1, target) })
    |> result.map(fn(entry) { entry.0 })
    |> result.lazy_unwrap(fn() { last_row(form) })

  Form(..form, cursor: index)
}

/// Whether a row is the first row of the question at `target`, or the Send row
/// when `target` is past the last question.
fn first_of(row: Row, target: Int) -> Bool {
  case row {
    Pick(question:, option: 0) -> question == target
    FillRow(question:) -> question == target
    SendRow -> target >= 0
    Pick(..) | OtherRow(..) -> False
  }
}

/// Enter or Space on the row under the cursor.
fn activated(form: Form) -> Action {
  // The Send row sends; an option is picked or toggled; Other and fill rows
  // start typing.
  case row_at(form) {
    SendRow -> sent(form)
    Pick(question:, option:) -> Continue(picked(form, question, option))
    OtherRow(question:) ->
      Continue(
        Form(
          ..with_draft(form, question, fn(draft) {
            Draft(
              ..draft,
              picked: [],
              other: Some(option.unwrap(draft.other, "")),
            )
          }),
          entry: Typing,
        ),
      )
    FillRow(..) -> Continue(Form(..form, entry: Typing))
  }
}

/// Picks or toggles one option, clearing any Other text.
fn picked(form: Form, question: Int, option: Int) -> Form {
  // The question's kind says whether a pick toggles or replaces.
  let kind = case list.drop(form.ask.questions, question) {
    [asked, ..] -> Some(asked.kind)
    [] -> None
  }

  with_draft(form, question, fn(draft) {
    // A `multiple` or `checklist` toggles; the other kinds hold one pick.
    case kind {
      Some(attention.Multiple(..)) | Some(attention.Checklist) ->
        Draft(..draft, picked: toggled(draft.picked, option), other: None)
      Some(attention.Confirm)
      | Some(attention.Choice)
      | Some(attention.Fill(..))
      | None -> Draft(..draft, picked: [option], other: None)
    }
  })
}

/// The picks with `option` added when absent and removed when present, in
/// option order.
fn toggled(picks: List(Int), option: Int) -> List(Int) {
  case list.contains(picks, option) {
    True -> list.filter(picks, fn(pick) { pick != option })
    False -> list.sort([option, ..picks], int.compare)
  }
}

/// The form after the owner asked to send: an answer to send, or the words
/// that say why it cannot go.
fn sent(form: Form) -> Action {
  // An observer's keys never reach the daemon.
  case form.standing {
    ObserverOnly ->
      Continue(
        Form(..form, refusal: Some("You can read this ask but not answer it.")),
      )
    MayAnswer ->
      case answer(form) {
        Ok(wire) -> Send(Form(..form, refusal: None, entry: Browsing), wire)
        Error(problem) -> Continue(refused(form, problem_words(problem)))
      }
  }
}

/// The form with `words` shown as why the last send did not go.
///
/// ## Examples
///
/// ```gleam
/// assert ask_form.refused(form, "The ask is gone.").refusal
///   == option.Some("The ask is gone.")
/// ```
pub fn refused(form: Form, words: String) -> Form {
  Form(..form, refusal: Some(words), entry: Browsing)
}

/// The words a problem is shown in: the question's number and the rule's own
/// fixed words.
///
/// ## Examples
///
/// ```gleam
/// assert ask_form.problem_words(ask_form.Problem("q2", "needs an answer"))
///   == "Question 2: needs an answer"
/// ```
pub fn problem_words(problem: Problem) -> String {
  // A question key reads as its number; a field of the object has no number.
  case string.starts_with(problem.key, "q") {
    True ->
      "Question " <> string.drop_start(problem.key, 1) <> ": " <> problem.words
    False -> problem.words
  }
}

/// The typed values the draft stands for, one for each question the owner has
/// answered, in question order.
///
/// ## Examples
///
/// ```gleam
/// assert ask_form.values(ask_form.new(ask, 1, ask_form.MayAnswer)) == []
/// ```
pub fn values(form: Form) -> List(#(String, attention.Value)) {
  list.index_map(form.ask.questions, fn(question, index) {
    value_of(question, draft_of(form, index))
    |> result.map(fn(value) { #(question.key, value) })
  })
  |> result.values
}

/// The value one question's draft stands for, or nothing when unanswered.
fn value_of(question: Question, draft: Draft) -> Result(attention.Value, Nil) {
  // Other replaces every option, so it is read first.
  case draft.other {
    Some(text) -> Ok(attention.Other(text))
    None -> option_value(question, draft)
  }
}

/// The value of a question answered by its own controls.
fn option_value(
  question: Question,
  draft: Draft,
) -> Result(attention.Value, Nil) {
  // Each kind reads the controls it draws.
  case question.kind, draft.picked {
    attention.Confirm, [0] -> Ok(attention.Yes)
    attention.Confirm, [1] -> Ok(attention.No)
    attention.Confirm, _ -> Error(Nil)
    attention.Choice, [pick] ->
      label_at(question, pick) |> result.map(attention.Picked)
    attention.Choice, _ -> Error(Nil)
    attention.Multiple(..), picks | attention.Checklist, picks ->
      list.try_map(picks, label_at(question, _))
      |> result.map(attention.PickedMany)
    attention.Fill(..), _ ->
      case draft.text {
        "" -> Error(Nil)
        text -> Ok(attention.Typed(text))
      }
  }
}

/// The label of the option at a position.
fn label_at(question: Question, position: Int) -> Result(String, Nil) {
  question.options
  |> list.drop(position)
  |> list.first
  |> result.map(fn(option) { option.label })
}

/// The answer object `attention.answer` takes, when the stored ask accepts
/// the draft, and the first problem when it does not.
///
/// The check is `core/attention_answer.check`, the rule the daemon applies, so
/// a draft that passes here is refused by the daemon only if the ask moved.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(problem) = ask_form.answer(ask_form.new(ask, 1, ask_form.MayAnswer))
/// assert ask_form.problem_words(problem) == "Question 1: needs an answer"
/// ```
pub fn answer(form: Form) -> Result(JsonValue, Problem) {
  let wire = attention.answer_object(values(form))

  // The rule's refusal names a key and fixed words; a missing key reads as an
  // unanswered question.
  use checked <- result.map(
    attention_answer.check(form.ask, wire)
    |> result.map_error(fn(rejection) {
      Problem(rejection.key, case rejection.reason {
        "missing" -> "needs an answer"
        words -> words
      })
    }),
  )
  attention.answer_object(checked)
}

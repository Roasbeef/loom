//// How the inbox turns an ask's form into the answer that is staged for
//// sending (protocol-change/119 and 120).
////
//// An ask's pane draws one fixed component for each question's kind, and a
//// submit of that form is a list of name and value pairs. This module reads
//// the pairs back into the wire object the daemon takes, `{"answers": ...,
//// "other": ...}`, and checks it against the ask with the daemon's own rule
//// (`core/attention_answer.check`), so a page's check and the daemon's cannot
//// disagree about what is valid. A form that does not pass is a `Problem`
//// worded from constants, and the page draws it beside the ask.
////
//// No model text travels in a form. A question is named by its key (`q1` to
//// `q4`, assigned by position and never written by a model), an option by its
//// position in the question's list, and the page's own words (`yes`, `no`,
//// `other`) stand for the rest. The labels are looked up here, from the
//// record the page read, so a forged form can only name an option the ask has.
////
//// The module is pure. It holds no Lustre and performs no I/O.
////
//// ## Flow
////
//// `stage` → `wire` → `core/attention_answer.check` → `lines`
////
//// 1. `stage` reads the form's pairs into the wire object question by
////    question, refusing a name the form does not have.
//// 2. The daemon's rule checks the object against the ask.
//// 3. `lines` words each checked value for the outbox, so the person sees
////    what Send will deliver.

import core/attention.{type Ask, type Question}
import core/attention_answer
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The value a confirm's yes control carries.
pub const yes = "yes"

/// The value a confirm's no control carries.
pub const no = "no"

/// The value of the Other control of a question, which says the question is
/// answered by its Other text instead of an option.
pub const other = "other"

/// An answer that is ready to send: the record it answers, the revision the
/// page read it at, the wire object the daemon checks again, and the words the
/// outbox lists.
pub type Staged {
  Staged(
    /// The session the ask belongs to.
    session: String,
    /// The ask's identifier.
    ask: String,
    /// The revision the page read the ask at. Send names it, so an answer to an
    /// ask that has since moved is refused and never delivered.
    revision: Int,
    /// The object `attention.answer` takes, without the ask's identifier.
    wire: JsonValue,
    /// One line for each question: its prompt and what was chosen. They hold
    /// model text and are drawn as text nodes.
    lines: List(String),
  )
}

/// Why a form was not staged. The words are fixed, and the key names the
/// question, so the page can point at it.
pub type Problem {
  Problem(
    /// `q1` to `q4`, or a field of the form.
    key: String,
    /// Fixed words that never include what the person typed.
    words: String,
  )
}

/// The name of a question's own control.
///
/// ## Examples
///
/// ```gleam
/// assert answer_rule.field_name(question) == "q1"
/// ```
pub fn field_name(question: Question) -> String {
  question.key
}

/// The name of a question's Other text field.
///
/// ## Examples
///
/// ```gleam
/// assert answer_rule.other_name(question) == "q1-other"
/// ```
pub fn other_name(question: Question) -> String {
  question.key <> "-other"
}

/// The value an option's control carries: its position in the question's
/// options, from zero.
///
/// ## Examples
///
/// ```gleam
/// assert answer_rule.position(2) == "2"
/// ```
pub fn position(index: Int) -> String {
  int.to_string(index)
}

/// The number a question has in the words the page says, from its key.
///
/// ## Examples
///
/// ```gleam
/// assert answer_rule.number("q2") == "Question 2"
/// ```
pub fn number(key: String) -> String {
  case string.starts_with(key, "q") {
    True -> "Question " <> string.drop_start(key, 1)
    False -> "The form"
  }
}

/// Stages the form for `ask`, read at `revision` in `session`, or says why it
/// cannot be sent.
///
/// ## Examples
///
/// ```gleam
/// assert answer_rule.stage("s", ask, 4, [#("q1", "yes")]) |> result.is_ok
/// ```
pub fn stage(
  session: String,
  ask: Ask,
  revision: Int,
  fields: List(#(String, String)),
) -> Result(Staged, Problem) {
  use Nil <- result.try(known_names(ask, fields))
  use wire <- result.try(wire(ask, fields))

  // The daemon's own rule is the last word on whether the object is valid.
  use values <- result.map(
    attention_answer.check(ask, wire)
    |> result.map_error(fn(rejection) {
      Problem(rejection.key, rejection.reason)
    }),
  )

  Staged(
    session:,
    ask: ask.header.id,
    revision:,
    wire:,
    lines: list.map(ask.questions, fn(question) {
      line(question, list.key_find(values, question.key))
    }),
  )
}

/// The wire object of a form: each question's value, and the Other text of
/// each question answered by Other.
///
/// ## Examples
///
/// ```gleam
/// assert answer_rule.wire(ask, [#("q1", "yes")]) |> result.is_ok
/// ```
pub fn wire(
  ask: Ask,
  fields: List(#(String, String)),
) -> Result(JsonValue, Problem) {
  use answers <- result.map(
    list.try_fold(ask.questions, #([], []), fn(acc, question) {
      use read <- result.map(given(question, fields))
      let #(answers, others) = acc

      // A question left unanswered is left out, which the daemon's rule names.
      case read {
        Unanswered -> #(answers, others)
        Answered(value) -> #([#(question.key, value), ..answers], others)
        OtherText(text) -> #([#(question.key, json.Null), ..answers], [
          #(question.key, json.String(text)),
          ..others
        ])
      }
    }),
  )
  let #(answers, others) = answers

  json.Object([
    #("answers", json.Object(list.reverse(answers))),
    #("other", json.Object(list.reverse(others))),
  ])
}

/// What a form says about one question.
type Given {
  /// Nothing was chosen or typed.
  Unanswered

  /// A value of the question's kind.
  Answered(JsonValue)

  /// The Other control, with the text beside it.
  OtherText(String)
}

/// Reads one question's controls. Text in the Other field beside an option
/// that is not Other is refused by name, because the form submits an empty
/// field for every question and a person who typed there meant something.
fn given(
  question: Question,
  fields: List(#(String, String)),
) -> Result(Given, Problem) {
  use read <- result.try(controls(question, fields))
  let typed = values_of(fields, other_name(question))

  // Only an answered question has a stray: an Other has its text by design.
  case read, list.any(typed, fn(text) { string.trim(text) != "" }) {
    Answered(_), True ->
      Error(Problem(question.key, "Other text for an answer that is not Other"))
    Answered(_), False | Unanswered, _ | OtherText(_), _ -> Ok(read)
  }
}

/// Reads one question's controls, without judging the Other text beside an
/// option.
fn controls(
  question: Question,
  fields: List(#(String, String)),
) -> Result(Given, Problem) {
  let key = question.key
  let chosen = values_of(fields, field_name(question))
  let typed = case values_of(fields, other_name(question)) {
    [text] -> text
    [] | [_, ..] -> ""
  }

  case question.kind, chosen {
    _, [] ->
      case question.kind {
        attention.Checklist | attention.Multiple(..) ->
          Ok(Answered(json.Array([])))
        attention.Confirm | attention.Choice | attention.Fill(..) ->
          Ok(Unanswered)
      }
    attention.Confirm, [pick] ->
      case pick {
        "yes" -> Ok(Answered(json.Bool(True)))
        "no" -> Ok(Answered(json.Bool(False)))
        "other" -> Ok(OtherText(typed))
        _ -> Error(Problem(key, "not a value this question takes"))
      }
    attention.Choice, [pick] ->
      case pick == other {
        True -> Ok(OtherText(typed))
        False ->
          label_at(question, pick)
          |> result.map(fn(label) { Answered(json.String(label)) })
      }
    attention.Multiple(..), picks | attention.Checklist, picks ->
      case list.contains(picks, other) {
        True ->
          case picks {
            [_] -> Ok(OtherText(typed))
            [_, _, ..] ->
              Error(Problem(key, "Other replaces the options, not adds to them"))
            [] -> Ok(Unanswered)
          }
        False ->
          list.try_map(picks, label_at(question, _))
          |> result.map(fn(labels) {
            Answered(json.Array(list.map(labels, json.String)))
          })
      }
    attention.Fill(..), [text] -> Ok(Answered(json.String(text)))
    _, [_, _, ..] -> Error(Problem(key, "not a value this question takes"))
  }
}

/// The label of the option a position names, or a refusal for a position the
/// question does not have, so a forged form can name only what is drawn.
fn label_at(question: Question, pick: String) -> Result(String, Problem) {
  let refusal = Problem(question.key, "not one of the options")

  use index <- result.try(int.parse(pick) |> result.replace_error(refusal))
  question.options
  |> list.drop(index)
  |> list.first
  |> result.map(fn(option) { option.label })
  |> result.replace_error(refusal)
}

/// Every value of a name in the form, in the order the form held them.
fn values_of(fields: List(#(String, String)), name: String) -> List(String) {
  list.filter_map(fields, fn(field) {
    case field.0 == name {
      True -> Ok(field.1)
      False -> Error(Nil)
    }
  })
}

/// Refuses a name the ask's form does not have, so a forged submit cannot
/// carry anything no control offers. A control's own name and its Other field
/// are the only names, one of each for every question.
fn known_names(
  ask: Ask,
  fields: List(#(String, String)),
) -> Result(Nil, Problem) {
  let names =
    list.flat_map(ask.questions, fn(question) {
      [field_name(question), other_name(question)]
    })

  case list.find(fields, fn(field) { !list.contains(names, field.0) }) {
    Ok(_) -> Error(Problem("form", "no such field"))
    Error(Nil) -> Ok(Nil)
  }
}

/// One outbox line for a question: its prompt, then what the checked value
/// says. Both are drawn as text nodes.
fn line(question: Question, value: Result(attention.Value, Nil)) -> String {
  let said = case value {
    Ok(attention.Yes) -> "Yes"
    Ok(attention.No) -> "No"
    Ok(attention.Picked(label:)) -> label
    Ok(attention.PickedMany(labels:)) ->
      case labels {
        [] -> "none"
        [_, ..] -> string.join(labels, ", ")
      }
    Ok(attention.Typed(text:)) -> text
    Ok(attention.Other(text:)) -> "Other: " <> text
    Error(Nil) -> ""
  }

  question.prompt <> " — " <> said
}

//// A person's answer to an ask, checked against the stored record and worded
//// as the prompt the daemon delivers (protocol-change/120).
////
//// A page submits an answer as JSON, and the daemon turns it into one prompt to
//// the asking strand. Between the two sits a rule: the answer must be one the
//// stored record could have been given. This module is that rule, and it is the
//// same rule whoever submits, so a page's own check and the daemon's cannot
//// disagree about what is valid.
////
//// ## Flow
////
//// `check` → `value_of` → `prompt_text`
////
//// 1. `check` reads the submitted object and requires the keys to be exactly
////    the ask's question keys.
//// 2. `value_of` checks each value against its question's kind. The first
////    failure is a `Rejection` naming the key.
//// 3. `prompt_text` words the checked values as fixed sentence plus one fenced
////    JSON object, the form protocol-change/119 specifies.
////
//// ## Why the prompt is checked here too
////
//// The longest prompt the gateway accepts is a bound on the whole text, not on
//// any one value, so `check` builds the prompt and measures it. A value that is
//// fine alone can still push the prompt past the bound when four of them sit
//// together.
////
//// ## What this module does not check
////
//// Nothing here knows who is answering, whether the ask is still open or
//// whether the record has moved since the page read it. The daemon decides
//// those from the registry and the store, and then calls this.

import core/attention.{
  type Ask, type Question, type Value, Checklist, Choice, Confirm, Fill,
  Multiple, No, Other, Picked, PickedMany, Typed, Yes,
}
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// The longest prompt the gateway accepts, in bytes. It is the home composer's
/// bound, `web_view/composer.prompt_limit`, restated because `core` may not
/// depend on the page's package. A test pins the two together.
pub const max_prompt_bytes = 16_384

/// The longest Other text, in bytes.
pub const max_other_bytes = 1000

/// The longest `fill` value of the `long_text` format, in bytes.
pub const max_long_text_bytes = 4000

/// The longest `fill` value of any other format, in bytes.
pub const max_fill_bytes = 1000

/// Why an answer was refused: the first key that failed and what was wrong.
///
/// The key is a question key (`q1` to `q4`) or the name of a top-level field of
/// the submitted object (`answers`, `other`), so a page can point at the
/// control that caused it.
pub type Rejection {
  Rejection(
    /// The question key or field the refusal is about.
    key: String,
    /// Fixed words saying what was wrong. Never text the person typed.
    reason: String,
  )
}

/// Checks a submitted answer against an ask and answers the typed values, one
/// for each question and in the order of the questions.
///
/// `wire` is the object of protocol-change/119, "The answer", without the
/// `ask` key: `{"answers": {...}, "other": {...}}`, with `other` optional when
/// no question was answered by Other.
///
/// ## Examples
///
/// ```gleam
/// let wire = json.Object([#("answers", json.Object([#("q1", json.Bool(True))]))])
/// assert attention_answer.check(ask, wire) == Ok([#("q1", attention.Yes)])
/// ```
pub fn check(
  ask: Ask,
  wire: JsonValue,
) -> Result(List(#(String, Value)), Rejection) {
  use fields <- result.try(object_of(wire, "answer"))
  use Nil <- result.try(only_fields(fields, ["answers", "other"]))
  use answers <- result.try(member(fields, "answers", required: True))
  use others <- result.try(member(fields, "other", required: False))
  use Nil <- result.try(exactly(answers, ask.questions))
  use values <- result.try(
    list.try_map(ask.questions, fn(question) {
      value_of(question, answers, others)
    }),
  )
  use Nil <- result.try(others_belong_to_other(others, values))

  // The prompt is built and measured because the bound is on the whole text.
  case
    bit_array.byte_size(<<prompt_text(ask.header.id, values):utf8>>)
    <= max_prompt_bytes
  {
    True -> Ok(values)
    False -> Error(Rejection("answer", "the answer is too long to send"))
  }
}

/// The prompt that carries checked values to the asking strand: a sentence that
/// names the ask, then the fenced JSON object `{"ask", "answers", "other"}`.
///
/// The words never include the ask's own text. The object is encoded by the
/// JSON encoder, so a person's text is a string inside it and cannot close the
/// fence: a JSON string has no raw newline, and the fence closes only at the
/// start of a line.
///
/// ## Examples
///
/// ```gleam
/// assert attention_answer.prompt_text("ask-0123456789", [#("q1", attention.Yes)])
///   == "Answer to ask-0123456789:\n\n```json\n{\"ask\":\"ask-0123456789\",\"answers\":{\"q1\":true},\"other\":{}}\n```"
/// ```
pub fn prompt_text(ask_id: String, values: List(#(String, Value))) -> String {
  // The answer object is led by the ask it answers.
  let object = case attention.answer_object(values) {
    json.Object(fields) ->
      json.Object([#("ask", json.String(ask_id)), ..fields])
    other -> other
  }

  "Answer to "
  <> ask_id
  <> ":\n\n```json\n"
  <> json.to_string(object)
  <> "\n```"
}

// --- the submitted object ----------------------------------------------------

/// The fields of an object, or the refusal for a value that is not one.
fn object_of(
  value: JsonValue,
  key: String,
) -> Result(List(#(String, JsonValue)), Rejection) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Rejection(key, "expected an object"))
  }
}

/// Refuses the first field of `fields` that is not in `allowed`, so the object
/// carries nothing the daemon did not ask for (`by` least of all: the answerer
/// is the daemon's to name).
fn only_fields(
  fields: List(#(String, JsonValue)),
  allowed: List(String),
) -> Result(Nil, Rejection) {
  case list.find(fields, fn(entry) { !list.contains(allowed, entry.0) }) {
    Ok(#(key, _)) -> Error(Rejection(key, "no such field"))
    Error(Nil) -> Ok(Nil)
  }
}

/// One member that must be an object. An absent member is the empty object when
/// it is not `required`.
fn member(
  fields: List(#(String, JsonValue)),
  key: String,
  required required: Bool,
) -> Result(List(#(String, JsonValue)), Rejection) {
  case list.key_find(fields, key), required {
    Ok(value), _ -> object_of(value, key)
    Error(Nil), True -> Error(Rejection(key, "missing"))
    Error(Nil), False -> Ok([])
  }
}

/// Requires `answers` to hold exactly one key for each question, so a missing
/// answer and an answer to no question are both refused by name.
fn exactly(
  answers: List(#(String, JsonValue)),
  questions: List(Question),
) -> Result(Nil, Rejection) {
  let keys = list.map(questions, fn(question) { question.key })
  let missing =
    list.find(keys, fn(key) { list.key_find(answers, key) == Error(Nil) })
  let extra = list.find(answers, fn(entry) { !list.contains(keys, entry.0) })

  // A missing key is reported before an extra one, in question order.
  case missing, extra {
    Ok(key), _ -> Error(Rejection(key, "missing"))
    Error(Nil), Ok(#(key, _)) -> Error(Rejection(key, "no such question"))
    Error(Nil), Error(Nil) -> Ok(Nil)
  }
}

/// Requires every key of `other` to belong to a question answered by Other, so
/// the text of an Other cannot ride beside an option the person picked.
fn others_belong_to_other(
  others: List(#(String, JsonValue)),
  values: List(#(String, Value)),
) -> Result(Nil, Rejection) {
  let stray =
    list.find(others, fn(entry) {
      case list.key_find(values, entry.0) {
        Ok(Other(..)) -> False
        Ok(Yes)
        | Ok(No)
        | Ok(Picked(..))
        | Ok(PickedMany(..))
        | Ok(Typed(..)) -> True
        Error(Nil) -> True
      }
    })

  // A stray Other key names an answer that is not Other.
  case stray {
    Ok(#(key, _)) ->
      Error(Rejection(key, "Other text for an answer that is not Other"))
    Error(Nil) -> Ok(Nil)
  }
}

// --- one question ------------------------------------------------------------

/// The value a question's answer stands for. A `null` is Other, whose text
/// sits in `other` under the same key; anything else is a value of the
/// question's kind.
fn value_of(
  question: Question,
  answers: List(#(String, JsonValue)),
  others: List(#(String, JsonValue)),
) -> Result(#(String, Value), Rejection) {
  let key = question.key

  // A null is Other; any other value must be of the question's kind.
  use value <- result.map(case list.key_find(answers, key) {
    Ok(json.Null) -> other_text(key, others) |> result.map(Other)
    Ok(given) -> typed(question, given)
    Error(Nil) -> Error(Rejection(key, "missing"))
  })

  #(key, value)
}

/// The text of an Other answer: present, not empty after trimming, and within
/// `max_other_bytes`.
fn other_text(
  key: String,
  others: List(#(String, JsonValue)),
) -> Result(String, Rejection) {
  case list.key_find(others, key) {
    Ok(json.String(text)) ->
      case string.trim(text) != "", string.byte_size(text) <= max_other_bytes {
        True, True -> Ok(text)
        False, _ -> Error(Rejection(key, "Other needs some text"))
        True, False -> Error(Rejection(key, "Other text is too long"))
      }
    Ok(_) | Error(Nil) -> Error(Rejection(key, "Other needs some text"))
  }
}

/// A value of the question's kind, or the refusal that says it is not one.
fn typed(question: Question, given: JsonValue) -> Result(Value, Rejection) {
  let key = question.key
  let wrong = Rejection(key, "not a value this question takes")

  // Each kind takes only the values its table row names.
  case question.kind, given {
    Confirm, json.Bool(True) -> Ok(Yes)
    Confirm, json.Bool(False) -> Ok(No)
    Choice, json.String(label) ->
      label_of(question, label) |> result.map(Picked)
    Multiple(min:, max:), json.Array(items) ->
      labels_of(question, items)
      |> result.try(within(key, _, min, max))
      |> result.map(PickedMany)
    Checklist, json.Array(items) ->
      labels_of(question, items) |> result.map(PickedMany)
    Fill(format:), json.String(text) ->
      fill_text(key, format, text)
      |> result.map(Typed)
    Confirm, _ | Choice, _ | Multiple(..), _ | Checklist, _ | Fill(..), _ ->
      Error(wrong)
  }
}

/// A label that is one of the question's options.
fn label_of(question: Question, label: String) -> Result(String, Rejection) {
  case list.any(question.options, fn(option) { option.label == label }) {
    True -> Ok(label)
    False -> Error(Rejection(question.key, "not one of the options"))
  }
}

/// Distinct option labels from an array of strings.
fn labels_of(
  question: Question,
  items: List(JsonValue),
) -> Result(List(String), Rejection) {
  use labels <- result.try(
    list.try_map(items, fn(item) {
      case item {
        json.String(label) -> label_of(question, label)
        json.Object(_)
        | json.Array(_)
        | json.Int(_)
        | json.Float(_)
        | json.Bool(_)
        | json.Null ->
          Error(Rejection(question.key, "a choice is a label of an option"))
      }
    }),
  )

  // Every label must name an option and none may repeat.
  case list.length(list.unique(labels)) == list.length(labels) {
    True -> Ok(labels)
    False -> Error(Rejection(question.key, "a label is chosen twice"))
  }
}

/// The labels, when their number is between `min` and `max`.
fn within(
  key: String,
  labels: List(String),
  min: Int,
  max: Int,
) -> Result(List(String), Rejection) {
  let count = list.length(labels)

  // The count of choices is held between min and max.
  case count < min, count > max {
    True, _ -> Error(Rejection(key, "too few choices"))
    False, True -> Error(Rejection(key, "too many choices"))
    False, False -> Ok(labels)
  }
}

// --- fill ---------------------------------------------------------------------

/// A `fill` value: not empty after trimming, free of NUL, within the format's
/// size, and of the format's shape.
fn fill_text(
  key: String,
  format: attention.Format,
  text: String,
) -> Result(String, Rejection) {
  // A value of the right shape is accepted whole and never cleaned.
  let limit = case format {
    attention.LongText -> max_long_text_bytes
    attention.ShortText
    | attention.FilePath
    | attention.Number
    | attention.Url -> max_fill_bytes
  }

  use <- bool.guard(
    when: string.trim(text) == "",
    return: Error(Rejection(key, "needs some text")),
  )
  use <- bool.guard(
    when: string.contains(text, "\u{0000}"),
    return: Error(Rejection(key, "text holds a NUL")),
  )
  use <- bool.guard(
    when: string.byte_size(text) > limit,
    return: Error(Rejection(key, "text is too long")),
  )

  // Only a format whose shape the text has is accepted.
  case shaped(format, text) {
    True -> Ok(text)
    False -> Error(Rejection(key, "not of the format the question asks"))
  }
}

/// Whether `text` has the shape of `format`. `text` and `long_text` take any
/// text; `path` takes one line and nothing is looked up on disk; `number` takes
/// the decimal form `-?[0-9]+(\.[0-9]+)?`; `url` takes an absolute `http` or
/// `https` address with no whitespace.
fn shaped(format: attention.Format, text: String) -> Bool {
  case format {
    attention.ShortText | attention.LongText -> True
    attention.FilePath ->
      !string.contains(text, "\n") && !string.contains(text, "\r")
    attention.Number -> decimal(text)
    attention.Url -> address(text)
  }
}

/// Whether `text` is `-?[0-9]+(\.[0-9]+)?`.
fn decimal(text: String) -> Bool {
  // A sign is allowed once, in front.
  let unsigned = case string.starts_with(text, "-") {
    True -> string.drop_start(text, 1)
    False -> text
  }

  // At most one point, with digits on both sides of it.
  case string.split(unsigned, ".") {
    [whole] -> digits(whole)
    [whole, fraction] -> digits(whole) && digits(fraction)
    [] | [_, _, _, ..] -> False
  }
}

/// Whether `text` is one or more ASCII digits.
fn digits(text: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), fn(grapheme) {
    string.contains("0123456789", grapheme)
  })
}

/// Whether `text` is an absolute `http` or `https` address with something after
/// the scheme and no whitespace.
fn address(text: String) -> Bool {
  // The scheme must be http or https, and something must follow it.
  let rest = case
    string.starts_with(text, "https://"),
    string.starts_with(text, "http://")
  {
    True, _ -> Some(string.drop_start(text, 8))
    False, True -> Some(string.drop_start(text, 7))
    False, False -> None
  }

  // No whitespace may appear anywhere in the address.
  case rest {
    Some(host) ->
      host != ""
      && list.all(string.to_graphemes(text), fn(grapheme) {
        !list.contains([" ", "\t", "\n", "\r"], grapheme)
      })
    None -> False
  }
}

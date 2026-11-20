//// The answer's rule and its prompt (protocol-change/120): every kind accepted
//// and refused, Other, the whole-prompt bound, and the prompt text, which must
//// read back as the answer it was made from.

import core/attention.{
  Alternative, Anchor, Ask, AskOpen, Checklist, Choice, Confirm, Fill, Header,
  Multiple, Plain, Question,
}
import core/attention_answer.{Rejection}
import core/clock
import core/ids
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{None}
import gleam/string

fn operation() -> ids.OpId {
  let #(id, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  id
}

fn options(labels: List(String)) -> List(attention.Alternative) {
  list.map(labels, fn(label) {
    Alternative(label:, note: None, emphasis: Plain)
  })
}

/// An ask with one question of each kind and one of each fill format.
fn ask() -> attention.Ask {
  Ask(
    header: Header(
      id: "ask-3f9c01a2b4",
      created_at: 1_790_000_000_000,
      routing: attention.ToOwner,
      anchor: Anchor(operation: operation(), step_id: "s", source_index: 0),
      strand: "main",
      parents: [],
    ),
    why: None,
    questions: [
      Question("q1", "Retry?", Confirm, []),
      Question("q2", "Branch?", Choice, options(["main", "topic"])),
      Question(
        "q3",
        "Files?",
        Multiple(min: 1, max: 2),
        options(["a", "b", "c"]),
      ),
      Question("q4", "Which?", Checklist, options(["x", "y"])),
      Question("q5", "Where?", Fill(attention.FilePath), []),
      Question("q6", "How many?", Fill(attention.Number), []),
      Question("q7", "Link?", Fill(attention.Url), []),
      Question("q8", "Say more", Fill(attention.LongText), []),
    ],
    state: AskOpen,
  )
}

fn good() -> List(#(String, JsonValue)) {
  [
    #("q1", json.Bool(True)),
    #("q2", json.String("topic")),
    #("q3", json.Array([json.String("a"), json.String("c")])),
    #("q4", json.Array([])),
    #("q5", json.String("src/retry.gleam")),
    #("q6", json.String("-12.5")),
    #("q7", json.String("https://example.com/x")),
    #("q8", json.String("A paragraph.\nWith two lines.")),
  ]
}

fn wire(
  answers: List(#(String, JsonValue)),
  other: List(#(String, JsonValue)),
) -> JsonValue {
  json.Object([
    #("answers", json.Object(answers)),
    #("other", json.Object(other)),
  ])
}

/// `good()` with one key's value replaced.
fn with(key: String, value: JsonValue) -> JsonValue {
  wire(
    list.map(good(), fn(entry) {
      case entry.0 == key {
        True -> #(key, value)
        False -> entry
      }
    }),
    [],
  )
}

fn refused_at(key: String, answer: JsonValue) -> Nil {
  let assert Error(Rejection(key: failed, ..)) =
    attention_answer.check(ask(), answer)
    as "the answer is refused"
  assert failed == key
}

pub fn an_answer_of_every_kind_is_accepted_in_question_order_test() {
  let assert Ok(values) = attention_answer.check(ask(), wire(good(), []))
    as "a valid answer"
  assert values
    == [
      #("q1", attention.Yes),
      #("q2", attention.Picked("topic")),
      #("q3", attention.PickedMany(["a", "c"])),
      #("q4", attention.PickedMany([])),
      #("q5", attention.Typed("src/retry.gleam")),
      #("q6", attention.Typed("-12.5")),
      #("q7", attention.Typed("https://example.com/x")),
      #("q8", attention.Typed("A paragraph.\nWith two lines.")),
    ]
}

pub fn other_replaces_any_kind_with_its_text_test() {
  let answers = list.key_set(good(), "q2", json.Null)
  let assert Ok(values) =
    attention_answer.check(
      ask(),
      wire(answers, [#("q2", json.String("Do it in a branch."))]),
    )
    as "an Other answer is accepted"
  assert list.key_find(values, "q2")
    == Ok(attention.Other("Do it in a branch."))
}

pub fn other_needs_text_within_its_bound_test() {
  let answers = list.key_set(good(), "q2", json.Null)
  refused_at("q2", wire(answers, []))
  refused_at("q2", wire(answers, [#("q2", json.String("   "))]))
  refused_at("q2", wire(answers, [#("q2", json.String("a\u{0000}b"))]))
  refused_at(
    "q2",
    wire(answers, [#("q2", json.String(string.repeat("x", 1001)))]),
  )
  let assert Ok(_) =
    attention_answer.check(
      ask(),
      wire(answers, [#("q2", json.String(string.repeat("x", 1000)))]),
    )
    as "the bound itself is accepted"
}

pub fn other_text_beside_a_picked_option_is_refused_test() {
  refused_at("q2", wire(good(), [#("q2", json.String("also"))]))
  refused_at("q9", wire(good(), [#("q9", json.String("stray"))]))
}

pub fn the_keys_are_exactly_the_questions_test() {
  refused_at("q8", wire(list.take(good(), 7), []))
  refused_at("q9", wire(list.append(good(), [#("q9", json.Bool(True))]), []))
  refused_at("answers", json.Object([]))
  refused_at(
    "by",
    json.Object([
      #("answers", json.Object(good())),
      #("by", json.String("owner")),
    ]),
  )
  refused_at("answer", json.Array([]))
}

pub fn a_confirm_takes_a_boolean_only_test() {
  refused_at("q1", with("q1", json.String("yes")))
  let assert Ok(values) =
    attention_answer.check(ask(), with("q1", json.Bool(False)))
    as "no is accepted"
  assert list.key_find(values, "q1") == Ok(attention.No)
}

pub fn a_choice_is_one_label_of_its_options_test() {
  refused_at("q2", with("q2", json.String("elsewhere")))
  refused_at("q2", with("q2", json.Array([json.String("main")])))
  refused_at("q2", with("q2", json.Int(1)))
}

pub fn a_multiple_respects_min_and_max_and_distinctness_test() {
  refused_at("q3", with("q3", json.Array([])))
  refused_at(
    "q3",
    with(
      "q3",
      json.Array([json.String("a"), json.String("b"), json.String("c")]),
    ),
  )
  refused_at("q3", with("q3", json.Array([json.String("a"), json.String("a")])))
  refused_at("q3", with("q3", json.Array([json.String("zzz")])))
  refused_at("q3", with("q3", json.Array([json.Int(1)])))
  refused_at("q3", with("q3", json.String("a")))
}

pub fn a_checklist_may_be_empty_but_not_repeat_or_stray_test() {
  refused_at("q4", with("q4", json.Array([json.String("x"), json.String("x")])))
  refused_at("q4", with("q4", json.Array([json.String("q")])))
}

pub fn a_fill_is_held_to_its_format_test() {
  refused_at("q5", with("q5", json.String("a\nb")))
  refused_at("q5", with("q5", json.String("  ")))
  refused_at("q6", with("q6", json.String("12.")))
  refused_at("q6", with("q6", json.String("1e3")))
  refused_at("q6", with("q6", json.String("--1")))
  refused_at("q6", with("q6", json.String("")))
  refused_at("q7", with("q7", json.String("ftp://example.com")))
  refused_at("q7", with("q7", json.String("https://exa mple.com")))
  refused_at("q7", with("q7", json.String("https://")))
  refused_at("q8", with("q8", json.String("a\u{0000}b")))
  refused_at("q1", with("q1", json.Null))
}

pub fn a_fill_is_held_to_its_size_test() {
  let thousand = string.repeat("a", 1000)
  let assert Ok(_) =
    attention_answer.check(ask(), with("q5", json.String(thousand)))
    as "a thousand bytes of path is the bound"
  refused_at("q5", with("q5", json.String(thousand <> "a")))
  let assert Ok(_) =
    attention_answer.check(
      ask(),
      with("q8", json.String(string.repeat("a", 4000))),
    )
    as "long text takes four thousand"
  refused_at("q8", with("q8", json.String(string.repeat("a", 4001))))
}

pub fn the_whole_prompt_is_bounded_test() {
  // Four long texts fit alone and not together once the object is built.
  let long = json.String(string.repeat("a", 4000))
  let many =
    Ask(
      ..ask(),
      questions: list.map(["q1", "q2", "q3", "q4", "q5"], fn(key) {
        Question(key, "Say", Fill(attention.LongText), [])
      }),
    )
  let answers =
    list.map(["q1", "q2", "q3", "q4", "q5"], fn(key) { #(key, long) })
  let assert Error(Rejection(key: "answer", ..)) =
    attention_answer.check(many, wire(answers, []))
    as "five long texts overrun the prompt"
}

pub fn the_prompt_names_the_ask_and_carries_one_fenced_object_test() {
  let assert Ok(values) =
    attention_answer.check(
      ask(),
      wire(list.key_set(good(), "q2", json.Null), [
        #("q2", json.String("Use ``` and \"quotes\"\nand a newline.")),
      ]),
    )
    as "a valid answer"
  let text = attention_answer.prompt_text("ask-3f9c01a2b4", values)
  assert string.starts_with(text, "Answer to ask-3f9c01a2b4:\n\n```json\n")
  assert string.ends_with(text, "\n```")

  // The object between the fences is the answer, so the person's text cannot
  // close the fence, and it parses back to what was checked.
  let assert [_, rest] = string.split(text, "```json\n")
    as "the opening fence appears once"
  let assert Ok(body) = string.split_once(rest, "\n```")
    as "the closing fence ends the text"
  let assert Ok(json.Object(fields)) = json.parse(body.0)
    as "the fenced text is one JSON object"
  assert list.key_find(fields, "ask") == Ok(json.String("ask-3f9c01a2b4"))
  let object = attention.answer_object(values)
  let assert json.Object(expected) = object as "the answer is an object"
  assert list.key_find(fields, "answers") == list.key_find(expected, "answers")
  assert list.key_find(fields, "other") == list.key_find(expected, "other")
  assert body.1 == ""
}

pub fn the_prompt_bound_is_the_composers_test() {
  assert attention_answer.max_prompt_bytes == 16_384
}

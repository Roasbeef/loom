//// Catalogue-backed selection must not turn classifier output into authority.

import client/extension/skill_selection as selection
import core/json
import core/message
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import host/skill

fn candidate(name: String, flags: String, body: String) -> skill.Skill {
  let assert Ok(candidate) =
    skill.parse(
      "/skills/" <> name <> "/SKILL.md",
      "---\nname: "
        <> name
        <> "\ndescription: Test skill\n"
        <> flags
        <> "---\n"
        <> body,
    )
    as "valid skill fixture"
  candidate
}

fn answer(names: List(String)) -> json.JsonValue {
  json.Object([#("skills", json.Array(list.map(names, json.String)))])
}

pub fn explicit_only_is_neither_disclosed_nor_accepted_test() {
  let manual = candidate("manual", "disable-model-invocation: true\n", "secret")
  let hidden = candidate("hidden", "user-invocable: false\n", "instructions")
  assert selection.eligible([manual, hidden]) == [hidden]
  assert result.is_error(selection.accept(
    [manual],
    [],
    "jev",
    answer(["manual"]),
  ))
  assert result.is_error(selection.accept(
    [hidden],
    [],
    "jev",
    answer(["invented"]),
  ))
}

pub fn known_document_is_loaded_once_with_source_and_no_arguments_test() {
  let review = candidate("review", "", "Check $ARGUMENTS, never run !`shell`.")
  let assert Ok(selected) =
    selection.accept([review], [], "jev", answer(["review", "review"]))
    as "known selection"
  let assert [
    #(
      "review",
      message.UserMessage(content: [message.UserText(text, None)], ..),
    ),
  ] = selected
    as "one attributed instruction"
  assert string.contains(text, "extension \"jev\"")
  assert string.contains(text, "/skills/review/SKILL.md")
  assert string.contains(text, "Check , never run !`shell`.")
  assert selection.accept([review], selected, "other", answer(["review"]))
    == Ok(selected)
}

pub fn oversized_and_malformed_proposals_are_atomic_test() {
  let small = candidate("small", "", "useful")
  let huge = candidate("huge", "", string.repeat("word ", 10_000))
  let assert Ok(prior) =
    selection.accept([small], [], "first", answer(["small"]))
    as "first selection"
  assert result.is_error(selection.accept(
    [small, huge],
    prior,
    "second",
    answer(["huge"]),
  ))
  assert result.is_error(selection.accept(
    [small],
    prior,
    "second",
    answer(["small", "unknown"]),
  ))
  assert result.is_error(selection.accept([small], [], "bad", json.Object([])))
  assert result.is_error(selection.accept(
    [small],
    [],
    "bad",
    answer(["small", "small", "small", "small"]),
  ))
  assert selection.accept([small], prior, "none", answer([])) == Ok(prior)
}

pub fn individually_valid_proposals_share_one_total_budget_test() {
  let a = candidate("a", "", "first")
  let b = candidate("b", "", "second")
  let c = candidate("c", "", "third")
  let d = candidate("d", "", "fourth")
  let catalogue = [a, b, c, d]
  let assert Ok(prior) =
    selection.accept(catalogue, [], "one", answer(["a", "b"]))
    as "two skills fit"
  assert result.is_error(selection.accept(
    catalogue,
    prior,
    "two",
    answer(["c", "d"]),
  ))
  let assert Ok(three) =
    selection.accept(catalogue, prior, "two", answer(["b", "c"]))
    as "duplicate names consume no new slot"
  assert list.length(three) == 3

  let a = candidate("a", "", string.repeat("word ", 4000))
  let b = candidate("b", "", string.repeat("word ", 4000))
  let assert Ok(prior) = selection.accept([a, b], [], "one", answer(["a"]))
    as "one large document fits"
  assert result.is_ok(selection.accept([a, b], [], "two", answer(["b"])))
  assert result.is_error(selection.accept([a, b], prior, "two", answer(["b"])))
}

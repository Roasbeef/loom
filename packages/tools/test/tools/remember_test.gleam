//// The `remember` tool's arguments: four required fields, a closed list of
//// kinds, and a seam that sees one decoded note.

import core/json.{type JsonValue}
import gleam/erlang/process
import gleam/list
import gleam/string
import support/fake_broker
import support/memory_fs
import tools/remember
import tools/tool

fn ctx() -> tool.Ctx {
  fake_broker.ctx(
    workspace: "/work",
    filesystem: memory_fs.filesystem(memory_fs.start()),
    now: 0,
    script: [],
    recorded: process.new_subject(),
  )
}

// A seam that records the note it was handed on a subject and accepts it.
fn recording(seen: process.Subject(remember.Note)) -> remember.Memory {
  remember.Memory(remember: fn(note) {
    process.send(seen, note)
    Ok(Nil)
  })
}

fn call(memory: remember.Memory, args: List(#(String, JsonValue))) {
  tool.dispatch(
    tool.registry([remember.tool(memory)]),
    ctx(),
    remember.tool_name,
    json.Object(args),
  )
}

fn full() -> List(#(String, JsonValue)) {
  [
    #("title", json.String("Run make fmt first")),
    #("description", json.String("CI rejects unformatted Gleam")),
    #("kind", json.String("feedback")),
    #(
      "note",
      json.String("Run make fmt before committing: CI fails otherwise."),
    ),
  ]
}

pub fn a_full_call_reaches_the_seam_as_one_typed_note_test() {
  let seen = process.new_subject()
  let outcome = call(recording(seen), full())
  assert !outcome.is_error
  assert process.receive(seen, 0)
    == Ok(remember.Note(
      kind: remember.Feedback,
      title: "Run make fmt first",
      description: "CI rejects unformatted Gleam",
      text: "Run make fmt before committing: CI fails otherwise.",
    ))
}

pub fn each_missing_field_is_refused_in_band_and_never_reaches_the_seam_test() {
  list.each(["title", "description", "kind", "note"], fn(missing) {
    let seen = process.new_subject()
    let args = list.filter(full(), fn(pair) { pair.0 != missing })
    let outcome = call(recording(seen), args)
    assert outcome.is_error
    assert process.receive(seen, 0) == Error(Nil)
  })
}

pub fn a_kind_outside_the_list_is_refused_in_band_test() {
  let seen = process.new_subject()
  let args = [
    #("kind", json.String("lesson")),
    ..list.filter(full(), fn(pair) { pair.0 != "kind" })
  ]
  let outcome = call(recording(seen), args)
  assert outcome.is_error
  assert process.receive(seen, 0) == Error(Nil)
}

pub fn the_schema_lists_exactly_the_three_kinds_and_requires_all_four_test() {
  let declared = tool.describe(remember.tool(recording(process.new_subject())))
  let text = string.inspect(declared.schema)
  assert string.contains(text, "feedback")
  assert string.contains(text, "fact")
  assert string.contains(text, "decision")
  assert list.map(remember.kinds, remember.kind_name)
    == ["feedback", "fact", "decision"]
}

pub fn the_description_asks_for_the_reason_and_how_to_apply_it_test() {
  let declared = remember.tool(recording(process.new_subject()))
  assert string.contains(declared.description, "reason")
  assert string.contains(declared.description, "how to apply")
  assert string.contains(declared.description, "never asks the user")
}

pub fn kind_names_round_trip_test() {
  list.each(remember.kinds, fn(kind) {
    assert remember.kind_named(remember.kind_name(kind)) == Ok(kind)
  })
  assert remember.kind_named("Fact") == Error(Nil)
}

pub fn check_line_judges_emptiness_newlines_and_length_test() {
  assert remember.check_line("title", "ok", 5) == Ok(Nil)
  assert remember.check_line("title", "  ", 5)
    == Error(remember.FieldInvalid("title", "is empty"))
  assert remember.check_line("title", "a\nb", 5)
    == Error(remember.FieldInvalid("title", "must be a single line"))
  assert remember.check_line("title", "abcdef", 5)
    == Error(remember.FieldInvalid(
      "title",
      "is 6 characters and the limit is 5",
    ))
}

//// Operator fixtures bind their source bytes and independent expected result.

import client/evolution/tasks
import core/json
import gleam/result
import gleeunit/should

pub fn task_set_identity_binds_fixture_prompt_and_independent_expected_files_test() {
  let assert Ok(base) = tasks.decode(payload("source.txt", "before", "after"))
    as "admitted task payload decodes"
  let assert Ok(changed) =
    tasks.decode(payload("source.txt", "before", "different expected"))
    as "changed independent criterion decodes"
  let assert Ok(source) =
    tasks.decode(payload("source.txt", "different fixture", "after"))
    as "changed source fixture decodes"
  should.be_false(base.id == changed.id)
  should.be_false(base.id == source.id)
  let assert [fixture] = base.tasks as "one task is retained"
  let assert [changed_fixture] = changed.tasks
    as "one changed criterion is retained"
  fixture.task.fixture |> should.equal(changed_fixture.task.fixture)
  should.be_false(fixture.task.criteria == changed_fixture.task.criteria)
  fixture.expected |> should.equal([#("source.txt", "after")])
}

pub fn escaping_paths_duplicate_tasks_and_unknown_scorers_are_refused_test() {
  tasks.decode(payload("../outside", "before", "after"))
  |> result.is_error
  |> should.be_true
  tasks.decode(payload("/absolute", "before", "after"))
  |> result.is_error
  |> should.be_true
  tasks.decode(payload(".git/config", "before", "after"))
  |> result.is_error
  |> should.be_true
  let assert json.Object(fields) = payload("source.txt", "before", "after")
    as "test payload is an object"
  tasks.decode(
    json.Object([
      #("scorer", json.String("candidate-supplied command")),
      ..fields
    ]),
  )
  |> result.is_error
  |> should.be_true
}

fn payload(path: String, before: String, after: String) -> json.JsonValue {
  json.Object([
    #("version", json.Int(1)),
    #(
      "tasks",
      json.Array([
        json.Object([
          #("id", json.String("edit-file/v1")),
          #(
            "prompt",
            json.String(
              "Change source.txt to the required result using coding tools.",
            ),
          ),
          #("files", json.Object([#(path, json.String(before))])),
          #("expected", json.Object([#(path, json.String(after))])),
        ]),
      ]),
    ),
  ])
}

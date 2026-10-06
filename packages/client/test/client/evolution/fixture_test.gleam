//// Independent scoring uses admitted bytes and refuses links and oversized files.

import client/evolution/fixture
import client/evolution/rollout
import client/evolution/tasks
import client/evolution/trace
import client/internal/ffi_os
import core/json
import gleam/int
import simplifile

pub fn scoring_compares_native_expected_bytes_and_refuses_oversized_output_test() {
  let #(admitted, captured, workspace) = prepared("score")
  assert fixture.score(admitted, captured.task, workspace) == Ok(trace.Failed)
  let assert Ok(Nil) =
    simplifile.write(workspace <> "/out/result.txt", "expected")
    as "the completed coding operation writes the criterion"
  assert fixture.score(admitted, captured.task, workspace)
    == Ok(trace.Succeeded)
  let assert Ok(Nil) =
    simplifile.write(workspace <> "/out/result.txt", "expected extra")
    as "an oversized file cannot pass by a matching prefix"
  assert fixture.score(admitted, captured.task, workspace) == Ok(trace.Failed)
  let assert Ok(Nil) = simplifile.delete(workspace)
    as "the native fixture owner retires its scratch directory"
}

pub fn scoring_refuses_a_linked_file_and_a_linked_parent_test() {
  let #(admitted, captured, workspace) = prepared("links")
  let outside = workspace <> "/native.txt"
  let assert Ok(Nil) = simplifile.write(outside, "expected")
    as "a linked target would otherwise satisfy the criterion"
  let assert Ok(Nil) = simplifile.delete(workspace <> "/out/result.txt")
    as "the trial removes the initial regular file"
  let assert Ok(Nil) =
    simplifile.create_symlink(to: outside, from: workspace <> "/out/result.txt")
    as "the trial replaces the scored file with a link"
  assert fixture.score(admitted, captured.task, workspace) == Ok(trace.Failed)
  let assert Ok(Nil) = simplifile.delete(workspace <> "/out")
    as "the native fixture removes its linked leaf"
  let assert Ok(Nil) =
    simplifile.create_directory_all(workspace <> "/elsewhere")
    as "the linked parent has a directory target"
  let assert Ok(Nil) =
    simplifile.write(workspace <> "/elsewhere/result.txt", "expected")
    as "the nested link would otherwise satisfy the criterion"
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: workspace <> "/elsewhere",
      from: workspace <> "/out",
    )
    as "the trial replaces an intermediate parent with a link"
  assert fixture.score(admitted, captured.task, workspace) == Ok(trace.Failed)
  let assert Ok(Nil) = simplifile.delete(workspace)
    as "native cleanup does not follow the trial's links"
}

pub fn scoring_refuses_a_task_that_differs_from_its_admitted_fixture_test() {
  let #(admitted, captured, workspace) = prepared("identity")
  let changed = rollout.Task(..captured.task, prompt: "candidate-picked task")
  assert fixture.find(admitted, changed)
    == Error("the rollout task differs from its admitted fixture")
  let assert Ok(Nil) = simplifile.delete(workspace)
    as "the unused fixture is cleaned by its native owner"
}

fn prepared(name: String) {
  let assert Ok(admitted) =
    tasks.decode(
      json.Object([
        #("version", json.Int(1)),
        #(
          "tasks",
          json.Array([
            json.Object([
              #("id", json.String("criterion/v1")),
              #(
                "prompt",
                json.String("Write the requested output using tools."),
              ),
              #(
                "files",
                json.Object([#("out/result.txt", json.String("initial"))]),
              ),
              #(
                "expected",
                json.Object([#("out/result.txt", json.String("expected"))]),
              ),
            ]),
          ]),
        ),
      ]),
    )
    as "the operator admits source and criterion independently"
  let assert [captured] = admitted.tasks as "one exact fixture is admitted"
  let workspace =
    "build/test_db/evolution-fixture-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = fixture.install(captured, workspace)
    as "installation precedes authored execution"
  #(admitted, captured, workspace)
}

//// Operator fixtures bind their source bytes and independent expected result.

import client/evolution/tasks
import core/json
import gleam/list
import gleam/result
import gleam/string
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

/// The digest of the canonical version-one bytes for `payload`, computed once
/// outside the code under test (`sha256` of the compact JSON text). If the
/// version-two work ever changed what a version-one payload means, this would
/// move.
const v1_identity =
  "1466970ec33cf14ac5b26e04d9eb92184fe3714e568856e26706bdd72f283ac6"

pub fn v1_task_sets_still_decode_test() {
  let assert Ok(base) = tasks.decode(payload("source.txt", "before", "after"))
    as "a version-one payload still decodes"
  assert base.id == v1_identity
  assert base.version == 1
  let assert [fixture] = base.tasks as "one task is retained"
  assert fixture.files == [#("source.txt", "before")]
  assert fixture.expected == [#("source.txt", "after")]
}

pub fn v2_inline_task_set_round_trips_test() {
  let assert Ok(admitted) =
    tasks.decode(payload_v2("source.txt", "before", "after"))
    as "an inline expected-files version-two payload decodes"
  assert admitted.version == 2
  let assert [fixture] = admitted.tasks as "one task is retained"
  assert fixture.files == [#("source.txt", "before")]
  assert fixture.expected == [#("source.txt", "after")]

  // The stored form is what `admit` writes and `load` reads back; decoding
  // the canonical bytes must give the same set and the same identity.
  let assert Ok(again) =
    tasks.decode(
      json.Object([
        #("version", json.Int(2)),
        #("tasks", json.Array(list.map(admitted.tasks, v2_task))),
      ]),
    )
    as "the canonical re-encoding decodes"
  assert again == admitted

  // The set is not the version-one set of the same bytes.
  let assert Ok(v1) = tasks.decode(payload("source.txt", "before", "after"))
    as "the version-one twin decodes"
  assert v1.id != admitted.id
  let assert [old] = v1.tasks as "the version-one twin keeps its task"
  assert old.task.fixture == fixture.task.fixture
  assert old.task.criteria == fixture.task.criteria
}

pub fn v2_program_task_is_refused_for_governed_runs_test() {
  let program =
    json.Object([
      #("kind", json.String("program")),
      #("files", json.Object([])),
      #("argv", json.Array([json.String("true")])),
      #("fail_to_pass", json.Array([])),
      #("pass_to_pass", json.Array([])),
      #("timeout_ms", json.Int(1000)),
      #("scoring", json.String("all_rewards_one")),
    ])
  let assert Error(reason) =
    tasks.decode(payload_v2_with(inline("a", "b"), program))
    as "a program verifier is not admitted"
  assert string.contains(
    reason,
    "program verifiers are not admitted to governed comparisons yet",
  )

  // A tree from a repository is the other member of the sum the governed
  // plane cannot open, and it is refused by its own name.
  let tree =
    json.Object([
      #("kind", json.String("git_tree")),
      #("repository", json.String("loom")),
      #("commit", json.String("c")),
      #("tree", json.String("t")),
      #("prepare", json.Array([])),
    ])
  let assert Error(reason) =
    tasks.decode(payload_v2_with(tree, expected("a", "c")))
    as "a git tree workspace is not admitted"
  assert string.contains(reason, "not admitted to governed comparisons yet")

  // A kind the sum does not have is malformed rather than unsupported.
  let assert Error(_) =
    tasks.decode(payload_v2_with(
      json.Object([#("kind", json.String("mystery"))]),
      expected("a", "c"),
    ))
    as "an unknown workspace kind is refused"
}

pub fn v2_identity_covers_workspace_and_verifier_test() {
  let assert Ok(base) =
    tasks.decode(payload_v2("source.txt", "before", "after"))
    as "base decodes"
  let assert Ok(workspace) =
    tasks.decode(payload_v2("source.txt", "other", "after"))
    as "changed workspace decodes"
  let assert Ok(verifier) =
    tasks.decode(payload_v2("source.txt", "before", "other"))
    as "changed verifier decodes"
  assert base.id != workspace.id
  assert base.id != verifier.id
  assert workspace.id != verifier.id

  // A member the version-two task does not define cannot ride along unhashed.
  let assert json.Object(fields) = payload_v2("source.txt", "before", "after")
    as "payload is an object"
  assert result.is_error(
    tasks.decode(json.Object([#("scorer", json.String("x")), ..fields])),
  )
  assert result.is_error(
    tasks.decode(payload_v2_with(
      json.Object([
        #("kind", json.String("inline")),
        #("files", json.Object([])),
        #("extra", json.String("x")),
      ]),
      expected("a", "c"),
    )),
  )
}

pub fn v2_refuses_a_repeated_fixture_and_expected_pair_test() {
  let twin = fn(id) { v2_task_of(id, inline("a", "b"), expected("a", "c")) }
  let set = fn(items) {
    json.Object([#("version", json.Int(2)), #("tasks", json.Array(items))])
  }
  assert result.is_error(tasks.decode(set([twin("one"), twin("two")])))

  // The same pair under version one stays valid: independence is a version-two rule.
  let assert Ok(_) = tasks.decode(payload_v1_twins())
    as "version one keeps admitting repeated pairs"
}

fn payload_v1_twins() -> json.JsonValue {
  let task = fn(id) {
    json.Object([
      #("id", json.String(id)),
      #("prompt", json.String("p")),
      #("files", json.Object([#("a", json.String("b"))])),
      #("expected", json.Object([#("a", json.String("c"))])),
    ])
  }
  json.Object([
    #("version", json.Int(1)),
    #("tasks", json.Array([task("one"), task("two")])),
  ])
}

fn inline(path: String, contents: String) -> json.JsonValue {
  json.Object([
    #("kind", json.String("inline")),
    #("files", json.Object([#(path, json.String(contents))])),
  ])
}

fn expected(path: String, contents: String) -> json.JsonValue {
  json.Object([
    #("kind", json.String("expected_files")),
    #("expected", json.Object([#(path, json.String(contents))])),
  ])
}

fn v2_task_of(
  id: String,
  workspace: json.JsonValue,
  verifier: json.JsonValue,
) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("prompt", json.String("Change source.txt to the required result.")),
    #("workspace", workspace),
    #("verifier", verifier),
  ])
}

fn payload_v2_with(
  workspace: json.JsonValue,
  verifier: json.JsonValue,
) -> json.JsonValue {
  json.Object([
    #("version", json.Int(2)),
    #("tasks", json.Array([v2_task_of("edit-file/v2", workspace, verifier)])),
  ])
}

fn payload_v2(path: String, before: String, after: String) -> json.JsonValue {
  payload_v2_with(inline(path, before), expected(path, after))
}

fn v2_task(fixture: tasks.Fixture) -> json.JsonValue {
  v2_task_of(
    fixture.task.id,
    inline_of(fixture.files),
    json.Object([
      #("kind", json.String("expected_files")),
      #("expected", files_object(fixture.expected)),
    ]),
  )
  |> with_prompt(fixture.task.prompt)
}

fn inline_of(files: List(#(String, String))) -> json.JsonValue {
  json.Object([
    #("kind", json.String("inline")),
    #("files", files_object(files)),
  ])
}

fn files_object(files: List(#(String, String))) -> json.JsonValue {
  json.Object(list.map(files, fn(pair) { #(pair.0, json.String(pair.1)) }))
}

fn with_prompt(task: json.JsonValue, prompt: String) -> json.JsonValue {
  case task {
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(pair) {
          case pair.0 {
            "prompt" -> #("prompt", json.String(prompt))
            _ -> pair
          }
        }),
      )
    other -> other
  }
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

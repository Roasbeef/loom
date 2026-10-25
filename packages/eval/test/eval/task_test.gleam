import core/json
import eval/task.{type Task}
import gleam/int
import gleam/list
import gleam/string
import qcheck
import simplifile

const seed = 17

const commit = "0123456789abcdef0123456789abcdef01234567"

const tree = "fedcba9876543210fedcba9876543210fedcba98"

fn config() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(300)
  |> qcheck.with_seed(qcheck.seed(seed))
}

fn mined() -> Task {
  task.mint(task.Task(
    id: "",
    name: "fix queue ordering",
    prompt: "Queue pops in the wrong order.",
    workspace: task.GitTree(
      repository: "https://example.invalid/loom.git",
      commit:,
      tree:,
      prepare: [["gleam", "deps", "download"]],
    ),
    verifier: task.Program(
      files: [#("packages/machine/test/machine/queue_test.gleam", "test body")],
      argv: ["bash", "scripts/test.sh", "machine", "--match", "queue_test"],
      fail_to_pass: ["queue_test.pops_in_order"],
      pass_to_pass: ["queue_test.pushes"],
      timeout_ms: 60_000,
      scoring: task.AllRewardsOne,
    ),
    tags: ["family:packages/machine/queue", "taxonomy:ordering"],
    provenance: task.MinedCommit(fix: commit, parent: tree, subject: "fix"),
  ))
}

fn inline() -> Task {
  task.mint(task.Task(
    id: "",
    name: "hello",
    prompt: "Write hello.",
    workspace: task.Inline(files: [#("a.txt", "a"), #("dir/b.txt", "b")]),
    verifier: task.ExpectedFiles(expected: [#("out.txt", "hello")]),
    tags: [],
    provenance: task.HandWritten(author: "someone"),
  ))
}

pub fn task_round_trips_test() {
  assert task.decode(task.to_json(mined())) == Ok(mined())
  assert task.decode(task.to_json(inline())) == Ok(inline())

  let text = json.to_string(task.to_json(mined()))
  let assert Ok(parsed) = json.parse(text)
  assert task.decode(parsed) == Ok(mined())
  assert task.verify_id(mined()) == Ok(mined())
  assert task.mint(mined()) == mined()
}

// Each selector edits a different field of the mined task. The suffix is
// never empty, so every edit really changes the field it names.
fn edit(base: Task, selector: Int, suffix: String) -> Task {
  let text = "x" <> suffix
  case base.workspace, base.verifier, base.provenance {
    task.GitTree(..) as workspace,
      task.Program(..) as verifier,
      task.MinedCommit(..) as provenance
    ->
      case selector {
        0 -> task.Task(..base, name: base.name <> text)
        1 -> task.Task(..base, prompt: base.prompt <> text)
        2 -> task.Task(..base, tags: [text, ..base.tags])
        3 ->
          task.Task(
            ..base,
            workspace: task.GitTree(
              ..workspace,
              repository: workspace.repository <> text,
            ),
          )
        4 ->
          task.Task(
            ..base,
            workspace: task.GitTree(..workspace, prepare: [
              [text],
              ..workspace.prepare
            ]),
          )
        5 ->
          task.Task(
            ..base,
            workspace: task.GitTree(..workspace, tree: workspace.tree <> text),
          )
        6 ->
          task.Task(
            ..base,
            verifier: task.Program(..verifier, files: [
              #("p/" <> text, "t"),
              ..verifier.files
            ]),
          )
        7 ->
          task.Task(
            ..base,
            verifier: task.Program(..verifier, argv: [text, ..verifier.argv]),
          )
        8 ->
          task.Task(
            ..base,
            verifier: task.Program(..verifier, fail_to_pass: [
              text,
              ..verifier.fail_to_pass
            ]),
          )
        9 ->
          task.Task(
            ..base,
            verifier: task.Program(..verifier, pass_to_pass: [
              text,
              ..verifier.pass_to_pass
            ]),
          )
        10 ->
          task.Task(
            ..base,
            verifier: task.Program(
              ..verifier,
              timeout_ms: verifier.timeout_ms + 1 + string.length(suffix),
            ),
          )
        11 ->
          task.Task(
            ..base,
            verifier: task.Program(..verifier, scoring: task.AllRewardsPositive),
          )
        12 ->
          task.Task(
            ..base,
            provenance: task.MinedCommit(
              ..provenance,
              subject: provenance.subject <> text,
            ),
          )
        _ -> task.Task(..base, provenance: task.HandWritten(author: text))
      }
    _, _, _ -> base
  }
}

pub fn task_id_changes_on_any_edit_test() {
  let base = mined()
  let edits = qcheck.tuple2(qcheck.bounded_int(0, 13), qcheck.string())

  qcheck.run(config(), edits, fn(pair) {
    let edited = task.mint(edit(base, pair.0, pair.1))

    assert edited != base
    assert edited.id != base.id
    assert edited.id == task.mint(edited).id
  })
}

pub fn inline_edits_change_the_id_test() {
  let base = inline()
  let files = task.Inline(files: [#("a.txt", "a2"), #("dir/b.txt", "b")])
  let expected = task.ExpectedFiles(expected: [#("out.txt", "hello!")])

  assert task.mint(task.Task(..base, workspace: files)).id != base.id
  assert task.mint(task.Task(..base, verifier: expected)).id != base.id
}

pub fn stale_id_is_refused_test() {
  let stale = task.Task(..mined(), prompt: "edited after minting")
  let assert Error(reason) = task.verify_id(stale)

  assert string.starts_with(reason, "task content changed")
}

// A replacement is spliced over the n-th node of the document, counting
// depth-first. The decoder must answer every such document with a value or a
// reason, and anything it accepts must survive its own round trip.
fn walk(
  value: json.JsonValue,
  remaining: Int,
  replacement: json.JsonValue,
) -> #(json.JsonValue, Int) {
  case remaining {
    0 -> #(replacement, -1)
    _ if remaining < 0 -> #(value, remaining)
    _ ->
      case value {
        json.Object(fields:) -> {
          let #(kept, left) =
            list.fold(fields, #([], remaining - 1), fn(state, field) {
              let #(done, left) = walk(field.1, state.1, replacement)
              #([#(field.0, done), ..state.0], left)
            })
          #(json.Object(list.reverse(kept)), left)
        }
        json.Array(items:) -> {
          let #(kept, left) =
            list.fold(items, #([], remaining - 1), fn(state, item) {
              let #(done, left) = walk(item, state.1, replacement)
              #([done, ..state.0], left)
            })
          #(json.Array(list.reverse(kept)), left)
        }
        json.String(..)
        | json.Int(..)
        | json.Float(..)
        | json.Bool(..)
        | json.Null -> #(value, remaining - 1)
      }
  }
}

fn replacements() -> List(json.JsonValue) {
  [
    json.Null,
    json.Int(-1),
    json.Int(0),
    json.Int(99_999_999),
    json.Float(1.5),
    json.Bool(True),
    json.String(""),
    json.String("../escape"),
    json.String("/abs"),
    json.Array([]),
    json.Array([json.Null]),
    json.Object([]),
    json.Object([#("zzz", json.Null)]),
  ]
}

pub fn task_decode_is_total_test() {
  let assert Ok(base) = json.parse(json.to_string(task.to_json(mined())))
  let generator =
    qcheck.tuple2(
      qcheck.bounded_int(0, 80),
      qcheck.bounded_int(0, list.length(replacements()) - 1),
    )

  qcheck.run(config(), generator, fn(pair) {
    let assert Ok(replacement) = list.drop(replacements(), pair.1) |> list.first
    let #(mutated, _) = walk(base, pair.0, replacement)

    case task.decode(mutated) {
      Ok(accepted) -> {
        assert task.decode(task.to_json(accepted)) == Ok(accepted)
      }
      Error(_) -> Nil
    }
  })
}

fn reason_for(value: json.JsonValue) -> String {
  case task.decode(value) {
    Ok(_) -> "accepted"
    Error(reason) -> reason
  }
}

fn with_field(
  value: json.JsonValue,
  key: String,
  replacement: json.JsonValue,
) -> json.JsonValue {
  case value {
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(field) {
          case field.0 == key {
            True -> #(key, replacement)
            False -> field
          }
        }),
      )
    other -> other
  }
}

fn with_extra(value: json.JsonValue) -> json.JsonValue {
  case value {
    json.Object(fields) -> json.Object([#("extra", json.Null), ..fields])
    other -> other
  }
}

fn with_nested(
  value: json.JsonValue,
  outer: String,
  inner: String,
  replacement: json.JsonValue,
) -> json.JsonValue {
  case value {
    json.Object(fields) ->
      json.Object(
        list.map(fields, fn(field) {
          case field.0 == outer {
            True -> #(outer, with_field(field.1, inner, replacement))
            False -> field
          }
        }),
      )
    other -> other
  }
}

pub fn bounds_are_enforced_test() {
  let base = task.to_json(mined())
  let long = string.repeat("a", 8193)

  assert reason_for(with_field(base, "prompt", json.String(long)))
    == "prompt must be 1 byte to 8 KiB"
  assert reason_for(with_field(base, "v", json.Int(1)))
    == "unsupported task version"
  assert reason_for(with_extra(base)) == "unknown key \"extra\""
  assert reason_for(with_nested(base, "verifier", "timeout_ms", json.Int(0)))
    == "\"timeout_ms\" must be between 1 and 3600000"
  assert reason_for(with_nested(
      base,
      "verifier",
      "timeout_ms",
      json.Int(3_600_001),
    ))
    == "\"timeout_ms\" must be between 1 and 3600000"
  assert reason_for(with_nested(base, "verifier", "argv", json.Array([])))
    == "verifier argv must hold 1 to 64 words"
  assert reason_for(with_nested(
      base,
      "verifier",
      "fail_to_pass",
      json.Array([]),
    ))
    == "a program verifier needs at least one fail_to_pass test"
  assert reason_for(with_nested(base, "workspace", "commit", json.String("abc")))
    == "commit and tree must be 40-digit lowercase hex"
}

fn many_files(count: Int) -> json.JsonValue {
  json.Object(
    list.repeat(Nil, count)
    |> list.index_map(fn(_, index) {
      #("f" <> int.to_string(index), json.String("x"))
    }),
  )
}

pub fn file_set_bounds_test() {
  let base = task.to_json(inline())
  let sixty_four = with_nested(base, "workspace", "files", many_files(64))
  let sixty_five = with_nested(base, "workspace", "files", many_files(65))
  let big =
    with_nested(
      base,
      "workspace",
      "files",
      json.Object([#("a", json.String(string.repeat("a", 262_145)))]),
    )

  assert reason_for(sixty_four) != "a file set may hold at most 64 files"
  assert reason_for(sixty_five) == "a file set may hold at most 64 files"
  assert reason_for(big) == "a file set may hold at most 256 KiB"
}

pub fn unsafe_paths_refused_test() {
  let base = task.to_json(inline())
  let bad = [
    "../x", "/abs", "a/../b", "a/./b", "a\u{0}b", ".git/config", "", "a//b",
    "a\\b", "dir/.loom/x", "..",
  ]

  list.each(bad, fn(path) {
    let files = json.Object([#(path, json.String("x"))])
    let value = with_nested(base, "workspace", "files", files)

    assert reason_for(value) == "unsafe path \"" <> path <> "\""
  })

  let fine = json.Object([#("src/ok.gleam", json.String("x"))])

  assert reason_for(with_nested(base, "workspace", "files", fine)) == "accepted"
}

fn scratch(name: String) -> String {
  let directory = "build/eval_task_test/" <> name
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  directory
}

pub fn task_load_refuses_renamed_file_test() {
  let directory = scratch("load")
  let body = json.to_string(task.to_json(mined()))
  let good = directory <> "/" <> mined().id <> ".json"
  let renamed = directory <> "/renamed.json"
  let assert Ok(Nil) = simplifile.write(good, body)
  let assert Ok(Nil) = simplifile.write(renamed, body)

  assert task.load(good) == Ok(mined())
  let assert Error(reason) = task.load(renamed)
  assert string.contains(reason, "must be named")
}

pub fn task_load_refuses_edited_file_test() {
  let directory = scratch("edited")
  let edited = task.Task(..mined(), prompt: "changed on disk")
  let path = directory <> "/" <> mined().id <> ".json"
  let assert Ok(Nil) =
    simplifile.write(path, json.to_string(task.to_json(edited)))
  let assert Error(reason) = task.load(path)

  assert string.starts_with(reason, "task content changed")
  let assert Error(missing) = task.load(directory <> "/absent.json")
  assert string.contains(missing, "cannot read")
}

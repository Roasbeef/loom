//// Tests for the governed door's payload and the holdout seal: the refusal by
//// name, the version-two shape, and the property that matters, that no
//// holdout id ever reaches a task-set fact.

import client/evolution/tasks
import core/clock
import core/json
import core/register
import core/tx.{SetRegister, Tx}
import eval/admit
import eval/admit_cli
import eval/split
import eval/task.{
  type Task, ExpectedFiles, GitTree, HandWritten, Inline, Program,
}
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile
import storage/sqlite
import storage/storage

const salt = "admit-test-salt"

/// An inline, expected-files task whose bytes are unique to its family.
fn fixture(family: String) -> Task {
  task.mint(task.Task(
    id: "",
    name: family,
    prompt: "Make out.txt say " <> family,
    workspace: Inline([#("in.txt", "start " <> family)]),
    verifier: ExpectedFiles([#("out.txt", "done " <> family)]),
    tags: ["family:" <> family],
    provenance: HandWritten("test"),
  ))
}

/// A pool with at least `each` tasks on every side of the wall.
fn pool() -> List(Task) {
  let families =
    list.map(
      int.range(from: 0, to: 60, with: [], run: fn(acc, n) { [n, ..acc] })
        |> list.reverse,
      fn(n) { "fam" <> string.inspect(n) },
    )
  let of = fn(side) {
    families
    |> list.filter(fn(family) { split.assign(salt, family) == side })
    |> list.take(3)
    |> list.map(fixture)
  }

  list.flatten([of(split.Tune), of(split.Validate), of(split.Holdout)])
}

fn ids_of(side: split.Split, pool: List(Task)) -> List(String) {
  pool
  |> list.filter(fn(each) { split.assign(salt, split.family(each)) == side })
  |> list.map(fn(each) { each.id })
}

pub fn holdout_admit_is_refused_by_name_test() {
  let assert Error(reason) = admit.prepare(pool(), split.Holdout, salt)
    as "the holdout is never prepared"
  assert string.contains(reason, "holdout")

  // The command line refuses before it reads a plan or a task directory, so
  // a request for the holdout touches nothing.
  let asked =
    admit_cli.Request(
      split: "holdout",
      tasks: "/nonexistent/tasks",
      plan: "/nonexistent/plan.json",
      session: "s",
      state: "/nonexistent",
      loomd: "loomd",
    )
  let assert Error(reason) =
    admit_cli.run(asked, fn(_argv, _timeout) { panic as "the door was reached" })
    as "the command refuses the holdout"
  assert string.contains(reason, "holdout")
}

pub fn admit_payload_is_v2_and_split_filtered_test() {
  let everything = pool()
  let assert Ok(admission) = admit.prepare(everything, split.Tune, salt)
    as "the tune split prepares"

  assert list.sort(admission.admitted, string.compare)
    == list.sort(ids_of(split.Tune, everything), string.compare)
  assert admission.skipped == []

  // The payload is what the governed decoder admits, as version two.
  let assert Ok(set) = tasks.decode(admission.payload)
    as "the governed decoder accepts the payload"
  assert set.version == 2
  assert list.length(set.tasks) == list.length(admission.admitted)

  // The same pool and salt always mint the same set.
  let assert Ok(again) =
    admit.prepare(list.reverse(everything), split.Tune, salt)
  assert again.payload == admission.payload
}

/// A family name that hashes onto `side`, found by search.
fn family_on(side: split.Split, prefix: String) -> String {
  let assert Ok(found) =
    int.range(from: 0, to: 200, with: [], run: fn(acc, n) { [n, ..acc] })
    |> list.reverse
    |> list.map(fn(n) { prefix <> string.inspect(n) })
    |> list.find(fn(family) { split.assign(salt, family) == side })
    as "some family lands on every side"
  found
}

pub fn tasks_without_a_governed_form_are_skipped_with_a_reason_test() {
  let program_family = family_on(split.Tune, "program")
  let tree_family = family_on(split.Tune, "tree")
  let program =
    task.mint(
      task.Task(
        ..fixture(program_family),
        id: "",
        verifier: Program(
          files: [],
          argv: ["true"],
          fail_to_pass: [],
          pass_to_pass: [],
          timeout_ms: 1000,
          scoring: task.AllRewardsOne,
        ),
      ),
    )
  let tree =
    task.mint(
      task.Task(
        ..fixture(tree_family),
        id: "",
        workspace: GitTree("loom", "c", "t", []),
      ),
    )
  let assert Ok(admission) =
    admit.prepare([program, tree, ..pool()], split.Tune, salt)
    as "the pool still prepares"
  let reasons = list.map(admission.skipped, fn(each) { each.reason })

  assert list.length(admission.skipped) == 2
  assert list.any(reasons, fn(reason) {
    string.contains(reason, "program verifiers are not admitted")
  })
  assert !list.contains(admission.admitted, program.id)
  assert !list.contains(admission.admitted, tree.id)
}

pub fn door_argv_names_the_existing_operator_door_test() {
  assert admit.door_argv("loomd", "/s", "ses", "/s/a.json")
    == [
      "loomd", "evolution", "--state-dir", "/s", "admit_tasks", "ses", "--args",
      "/s/a.json",
    ]
}

pub fn holdout_ids_never_reach_a_taskset_fact_test() {
  let state = "build/admit-test/seal"
  let _ = simplifile.delete(state)
  let assert Ok(Nil) = simplifile.create_directory_all(state <> "/sessions")
  let everything = pool()
  let holdout = ids_of(split.Holdout, everything)
  let admitted =
    list.append(
      ids_of(split.Tune, everything),
      ids_of(split.Validate, everything),
    )

  // Both admissible splits go through a door that stores what the daemon's
  // door stores: one reserved fact per set, keyed by the set's identity.
  list.each([split.Tune, split.Validate], fn(side) {
    let assert Ok(admission) = admit.prepare(everything, side, salt)
    let assert Ok(_) = admit.submit(admission, store_door(state))
      as "the fixture door accepts the set"
    Nil
  })

  let facts = taskset_facts(state)
  assert list.length(facts) == 2
  let text = string.join(list.map(facts, json.to_string), "\n")
  assert holdout != []
  assert list.all(holdout, fn(id) { !string.contains(text, id) })
  assert list.all(admitted, fn(id) { string.contains(text, id) })
}

/// A door that records the set the way `tasks.admit` does, in a session file
/// under the fixture state directory.
fn store_door(state: String) -> admit.Door {
  fn(payload) {
    use set <- result_try(tasks.decode(payload))
    let assert Ok(store) =
      sqlite.open(
        sqlite.config(path: state <> "/sessions/s.db", owner: "door"),
        clock.fixed(at: 10_000),
      )
    let committed =
      storage.commit(
        store,
        Tx(
          writes: [
            SetRegister(
              register.FactCustom,
              "prompt/evolution-taskset/" <> set.id,
              register.RegisterValue(
                json.Object([
                  #("principal", json.String("operator")),
                  #("payload", payload),
                ]),
              ),
            ),
          ],
          expected: [],
        ),
      )
    let _closed = storage.close(store)
    case committed {
      Ok(_) -> Ok("admitted " <> set.id)
      Error(_) -> Error("commit failed")
    }
  }
}

fn result_try(value, next) {
  case value {
    Ok(inner) -> next(inner)
    Error(reason) -> Error(reason)
  }
}

/// Every `prompt/evolution-taskset/*` payload in every session of the state.
fn taskset_facts(state: String) -> List(json.JsonValue) {
  let assert Ok(names) = simplifile.read_directory(state <> "/sessions")
  list.flat_map(names, fn(name) {
    let assert Ok(store) =
      sqlite.open(
        sqlite.config(path: state <> "/sessions/" <> name, owner: "scan"),
        clock.fixed(at: 20_000),
      )
    let listed =
      storage.list_registers(
        store,
        register.FactCustom,
        Some("prompt/evolution-taskset/"),
      )
    let _closed = storage.close(store)
    let assert Ok(cells) = listed
    list.map(cells, fn(cell) { { cell.1 }.value.payload })
  })
}

pub fn an_oversized_set_is_refused_with_its_size_test() {
  let assert Ok(admission) = admit.prepare(pool(), split.Tune, salt)
  let big =
    admit.Admission(
      ..admission,
      payload: json.Object([#("pad", json.String(string.repeat("x", 50_000)))]),
    )
  let assert Error(reason) = admit.submit(big, fn(_) { Ok("reached") })
  assert string.contains(reason, "bytes")
}

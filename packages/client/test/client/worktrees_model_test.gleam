//// The worktree lifecycle against a model (protocol-change/095).
////
//// `worktrees_test` walks the cases the design names. This module asks a
//// different question: whatever order a session's tree is opened, edited,
//// committed to, closed, deleted from under the executor and restarted over,
//// do the promises hold? `statem` draws sequences of those commands for two
//// sessions, runs each against the real executor worktrees, a real repository
//// and the shipped sandbox helper, and compares what it finds with a small
//// pure model after every command.
////
//// The promises it checks are the ones a user would be angry to see broken.
//// Work that was committed is back at every later open. Work that was not
//// committed survives every close and reopen, unless the tree itself was
//// deleted by hand. A clean close removes the tree and a dirty one never does.
//// A branch, once made, is never deleted. And the ledger's record, the
//// directory on disk and the model agree about which of those states a session
//// is in.
////
//// The seed and the sizes are constants, so the gate is deterministic: a
//// failure names the run and the shrunk command list, and replays.

import client/worktrees
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import qcheck
import simplifile
import statem
import storage/exec_ledger
import support/worktree_rig.{type Rig, exists, git, session, write}

const sequence_seed = 9501

const sequence_count = 24

const sequence_length = 12

// --- the model ------------------------------------------------------------------

// Where a session's tree is in its life, as the ledger's record says it.
type Life {
  Unmade
  Live
  Left
  Gone
}

// Whether the directory of a live or left tree is still there. A tree deleted
// by hand keeps its record until the next open or the next start finds out.
type Disk {
  Intact
  Vanished
}

// Whether the tree holds work that is not committed.
type Work {
  Clean
  Uncommitted
}

type Slot {
  Slot(life: Life, disk: Disk, work: Work, committed: Bool)
}

type Model =
  Dict(Int, Slot)

type Command {
  Open(session: Int)
  Close(session: Int)
  Edit(session: Int)
  Commit(session: Int)
  Vanish(session: Int)
  Restart
}

fn unmade() -> Slot {
  Slot(life: Unmade, disk: Intact, work: Clean, committed: False)
}

fn slot(model: Model, n: Int) -> Slot {
  result.unwrap(dict.get(model, n), unmade())
}

fn here(life: Life) -> Bool {
  life == Live || life == Left
}

// The model's whole transition function. Reading it beside `perform` is the
// review: each arm is what the design says the command does.
fn step(model: Model, command: Command) -> Model {
  case command {
    Open(n) -> {
      let held = slot(model, n)
      let opened = case held.life, held.disk {
        // The tree is adopted as it is.
        Live, Intact | Left, Intact -> Slot(..held, life: Live)

        // The directory was deleted by hand: the branch brings back what was
        // committed, and what was not is gone with the directory.
        Live, Vanished | Left, Vanished | Gone, _ ->
          Slot(life: Live, disk: Intact, work: Clean, committed: held.committed)

        Unmade, _ ->
          Slot(life: Live, disk: Intact, work: Clean, committed: False)
      }
      dict.insert(model, n, opened)
    }

    Close(n) -> {
      let held = slot(model, n)
      let closed = case held.life, held.disk, held.work {
        Unmade, _, _ | Gone, _, _ -> held
        Live, Intact, Uncommitted | Left, Intact, Uncommitted ->
          Slot(..held, life: Left)
        Live, Intact, Clean | Left, Intact, Clean -> Slot(..held, life: Gone)

        // A status of a directory that is not there cannot be read, and Loom
        // leaves what it cannot check.
        Live, Vanished, _ | Left, Vanished, _ -> Slot(..held, life: Left)
      }
      dict.insert(model, n, closed)
    }

    Edit(n) -> dict.insert(model, n, Slot(..slot(model, n), work: Uncommitted))

    Commit(n) ->
      dict.insert(
        model,
        n,
        Slot(..slot(model, n), work: Clean, committed: True),
      )

    Vanish(n) -> dict.insert(model, n, Slot(..slot(model, n), disk: Vanished))

    // The restart's reconciliation turns a record whose directory is gone into
    // a removed one.
    Restart ->
      dict.map_values(model, fn(_n, held) {
        case here(held.life), held.disk {
          True, Vanished ->
            Slot(
              life: Gone,
              disk: Intact,
              work: Clean,
              committed: held.committed,
            )
          True, Intact | False, _ -> held
        }
      })
  }
}

fn admitted(model: Model, command: Command) -> statem.Admission {
  case command {
    Edit(n) | Vanish(n) ->
      case here(slot(model, n).life), slot(model, n).disk {
        True, Intact -> statem.Admit
        True, Vanished | False, _ -> statem.Reject
      }
    Commit(n) ->
      case here(slot(model, n).life), slot(model, n).disk, slot(model, n).work {
        True, Intact, Uncommitted -> statem.Admit
        _, _, _ -> statem.Reject
      }
    Open(_) | Close(_) | Restart -> statem.Admit
  }
}

// --- the system under test ------------------------------------------------------

fn tree_path(rig: Rig, n: Int) -> String {
  worktrees.tree_path(rig.state, "repo", session(n))
}

fn perform(rig: Rig, command: Command) -> Result(Rig, String) {
  case command {
    Open(n) ->
      worktrees.open(rig.trees, rig.workspace, session(n))
      |> result.map(fn(_tree) { rig })
    Close(n) -> {
      let _closed = worktrees.close(rig.trees, rig.workspace, session(n))
      Ok(rig)
    }
    Edit(n) -> {
      write(tree_path(rig, n) <> "/d.txt", "work\n")
      Ok(rig)
    }
    Commit(n) -> {
      git(tree_path(rig, n), ["add", "-A"])
      git(tree_path(rig, n), ["commit", "--quiet", "-m", "work"])
      Ok(rig)
    }
    Vanish(n) -> {
      let _removed = simplifile.delete(tree_path(rig, n))
      Ok(rig)
    }
    Restart -> {
      let restarted = worktree_rig.restart(rig)

      // The first job of a gate reconciles, so a job that touches no tree
      // is how the test makes the start's reconciliation happen now.
      let _closed =
        worktrees.close(restarted.trees, restarted.workspace, "no-such-session")
      Ok(restarted)
    }
  }
}

fn record_of(rig: Rig, n: Int) -> Result(exec_ledger.TreeState, Nil) {
  let assert Ok(ledger) = exec_ledger.connect(rig.ledger_path)
    as "the ledger connects"
  let found = exec_ledger.tree(ledger, session(n))
  let _closed = exec_ledger.close(ledger)
  case found {
    Ok(Some(each)) -> Ok(each.state)
    Ok(None) | Error(_) -> Error(Nil)
  }
}

fn expected_record(held: Slot) -> Result(exec_ledger.TreeState, Nil) {
  case held.life {
    Unmade -> Error(Nil)
    Live -> Ok(exec_ledger.Present)
    Left -> Ok(exec_ledger.Kept)
    Gone -> Ok(exec_ledger.Removed)
  }
}

fn violation(tag: String, detail: String) -> Result(a, statem.Violation) {
  Error(statem.Violation(tag:, detail:))
}

// Every session, after every command: the record, the directory, the branch
// and the work all agree with the model.
fn check(rig: Rig, model: Model) -> Result(Nil, statem.Violation) {
  list.try_each([0, 1], fn(n) {
    let held = slot(model, n)
    let path = tree_path(rig, n)
    use Nil <- result.try(case record_of(rig, n) == expected_record(held) {
      True -> Ok(Nil)
      False ->
        violation(
          "record",
          "session "
            <> string.inspect(n)
            <> " is "
            <> string.inspect(held)
            <> " in the model but its record is "
            <> string.inspect(record_of(rig, n)),
        )
    })
    let want_directory = here(held.life) && held.disk == Intact
    use Nil <- result.try(case exists(path) == want_directory {
      True -> Ok(Nil)
      False ->
        violation(
          "directory",
          "session "
            <> string.inspect(n)
            <> " expected the directory "
            <> string.inspect(want_directory)
            <> " for "
            <> string.inspect(held),
        )
    })
    use Nil <- result.try(
      case
        list.contains(branches(rig), "loom/" <> session(n)),
        held.life == Unmade
      {
        True, False | False, True -> Ok(Nil)
        True, True | False, False ->
          violation(
            "branch",
            "session "
              <> string.inspect(n)
              <> " has the wrong branch state for "
              <> string.inspect(held),
          )
      },
    )
    case want_directory && { held.committed || held.work == Uncommitted } {
      True ->
        case exists(path <> "/d.txt") {
          True -> Ok(Nil)
          False ->
            violation(
              "lost-work",
              "session "
                <> string.inspect(n)
                <> " lost its work: "
                <> string.inspect(held),
            )
        }
      False -> Ok(Nil)
    }
  })
}

fn branches(rig: Rig) -> List(String) {
  git(rig.root, ["branch", "--list", "loom/*", "--format=%(refname:short)"])
  |> string.split("\n")
}

fn execute(
  rig: Rig,
  model: Model,
  command: Command,
) -> Result(Rig, statem.Violation) {
  case perform(rig, command) {
    Error(reason) ->
      violation(
        "refused",
        string.inspect(command) <> " was refused: " <> reason,
      )
    Ok(next) -> {
      use Nil <- result.map(check(next, step(model, command)))
      next
    }
  }
}

fn commands() -> qcheck.Generator(Command) {
  let which = qcheck.bounded_int(from: 0, to: 1)
  qcheck.from_weighted_generators(#(5, qcheck.map(which, fn(n) { Open(n) })), [
    #(5, qcheck.map(which, fn(n) { Close(n) })),
    #(3, qcheck.map(which, fn(n) { Edit(n) })),
    #(4, qcheck.map(which, fn(n) { Commit(n) })),
    #(1, qcheck.map(which, fn(n) { Vanish(n) })),
    #(1, qcheck.return(Restart)),
  ])
}

fn lifecycle() -> statem.Spec(Model, Command, Rig) {
  statem.Spec(
    initial: dict.new(),
    command: fn(_model) { commands() },
    precondition: admitted,
    next_model: step,
    new_sut: fn() { worktree_rig.rig("model") },
    execute:,
    finish: fn(_rig, _model) { Ok(Nil) },
    teardown: fn(rig) {
      worktrees.stop(rig.trees)
      Nil
    },
  )
}

pub fn any_order_of_opens_edits_closes_and_restarts_keeps_every_promise_test() {
  let config =
    statem.default_config(seed: sequence_seed)
    |> statem.with_test_count(sequence_count)
    |> statem.with_max_commands(sequence_length)
  case statem.check(lifecycle(), config) {
    Ok(Nil) -> Nil
    Error(failure) ->
      panic as statem.report(failure, fn(command) { string.inspect(command) })
  }
}

// A property that never reaches a state proves nothing about it, so the model
// is replayed over the generated lists and must visit the states the promises
// are about: a tree kept, one removed, and a restart that reconciles.
pub fn the_generated_sequences_reach_the_states_the_promises_are_about_test() {
  let config =
    statem.default_config(seed: sequence_seed)
    |> statem.with_test_count(sequence_count)
    |> statem.with_max_commands(sequence_length)
  let spec = lifecycle()
  let visited =
    runs()
    |> list.flat_map(fn(run) {
      let #(_, models) =
        list.map_fold(
          statem.commands(spec, config, run),
          spec.initial,
          fn(model, command) {
            let next = step(model, command)
            #(next, #(command, next))
          },
        )
      models
    })
  assert list.any(visited, fn(each) {
    list.any(dict.values(each.1), fn(held) { held.life == Left })
  })
    as "some sequence leaves a tree kept"
  assert list.any(visited, fn(each) {
    list.any(dict.values(each.1), fn(held) { held.life == Gone })
  })
    as "some sequence removes a tree"
  assert list.any(visited, fn(each) { each.0 == Restart })
    as "some sequence restarts the executor"
  assert list.any(visited, fn(each) {
    list.any(dict.values(each.1), fn(held) {
      held.committed && held.life == Gone
    })
  })
    as "some sequence removes a tree whose work was committed"
}

fn runs() -> List(Int) {
  int.range(0, sequence_count, [], fn(found, n) { [n, ..found] })
  |> list.reverse
}

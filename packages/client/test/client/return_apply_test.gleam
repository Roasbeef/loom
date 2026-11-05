//// The parent's end of a return: the gate an apply takes, the workspace it must
//// be for, and the store it reads (protocol-change/107, "Return").
////
//// The gate tests use closures for the apply, because what they check is when it
//// runs and who is kept out while it does. The store tests use a real repository,
//// the real sandbox helper and a real child.

import client/internal/ffi_os
import client/remote_child
import client/return_apply
import client/state_apply.{Clone}
import client/state_capture
import client/state_object.{type State, Full}
import client/state_service
import client/state_store
import client/workspace_gate.{type Gate}
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/state_rig.{type Rig}
import support/worktree_rig
import telemetry/field
import telemetry/level
import telemetry/log
import weft/registry

fn started() -> Gate {
  let assert Ok(names) = registry.start() as "the registry starts"
  let assert Ok(gate) = workspace_gate.start_at(registry.new_address(names))
    as "the gate starts"
  gate
}

fn here() -> String {
  let assert Ok(directory) = simplifile.current_directory()
  directory
}

// A path no one has written yet, which a worker in another process polls for.
fn marker() -> String {
  let path =
    here()
    <> "/build/return-apply-release-"
    <> int.to_string(ffi_os.unique_positive_integer())

  // The counter starts again in every VM, so a marker an earlier run wrote under
  // the same number would release the apply before the test looks at the gate.
  let _removed = simplifile.delete(path)
  path
}

// Waits, in the caller's own process, for the marker to appear.
fn wait_for(path: String, tries: Int) -> Nil {
  case simplifile.is_file(path), tries > 0 {
    Ok(True), _ -> Nil
    _, True -> {
      process.sleep(20)
      wait_for(path, tries - 1)
    }
    _, False -> Nil
  }
}

fn some_state() -> State {
  state_object.State(
    hash: string.repeat("ab", 32),
    size: 100,
    tip: string.repeat("1", 40),
    base: None,
    dirty: state_object.Clean,
  )
}

fn ref() -> String {
  "refs/loom/children/fix-cache-0123456789abcdef/11111111"
}

pub fn the_apply_runs_with_every_tool_call_kept_out_test() {
  let gate = started()
  let running = process.new_subject()
  let release = marker()
  let finished = process.new_subject()

  // The apply announces itself and then waits to be let go.
  let apply = fn(_workspace, _sent, _returned, _child) {
    process.send(running, Nil)
    wait_for(release, 250)
    Ok(#(ref(), 2))
  }
  let _applying =
    process.spawn(fn() {
      process.send(
        finished,
        return_apply.behind_gate(
          gate,
          1000,
          10_000,
          here(),
          here(),
          apply,
          some_state(),
          some_state(),
          "sub:^main/fix-cache-0123456789abcdef",
        ),
      )
    })
  let assert Ok(Nil) = process.receive(running, 5000)

  // While it runs, a workspace tool call cannot enter. The shared side would have
  // let it in beside another shared call, which is why the apply does not use it.
  assert workspace_gate.shared(gate, 150, fn() { Nil })
    == Error(workspace_gate.Busy)

  // When it ends, the gate is open again and the answer is the ref.
  let assert Ok(Nil) = simplifile.write(release, "go")
  let assert Ok(answer) = process.receive(finished, 5000)
  assert answer == Ok(remote_child.Applied(ref: ref(), commits: 2))
  assert workspace_gate.shared(gate, 1000, fn() { Nil }) == Ok(Nil)
}

pub fn a_workspace_that_does_not_go_quiet_is_a_retry_and_applies_nothing_test() {
  let gate = started()
  let in_flight = process.new_subject()
  let release = marker()
  let called = process.new_subject()

  // A tool call is running in the workspace and does not end.
  let _tool =
    process.spawn(fn() {
      let _ =
        workspace_gate.shared(gate, 1000, fn() {
          process.send(in_flight, Nil)
          wait_for(release, 250)
        })
      Nil
    })
  let assert Ok(Nil) = process.receive(in_flight, 5000)

  let answer =
    return_apply.behind_gate(
      gate,
      150,
      10_000,
      here(),
      here(),
      fn(_workspace, _sent, _returned, _child) {
        process.send(called, Nil)
        Ok(#(ref(), 1))
      },
      some_state(),
      some_state(),
      "sub:^main/fix-cache-0123456789abcdef",
    )
  let assert Error(reason) = answer
  assert string.contains(reason, "did not go quiet")
  assert process.receive(called, 100) == Error(Nil)
  let assert Ok(Nil) = simplifile.write(release, "go")
}

pub fn the_commits_go_only_where_the_child_was_started_from_test() {
  let gate = started()
  let called = process.new_subject()

  // The session's workspace resolves to another directory than the one the
  // state was captured from, as after a move or a changed configuration.
  let answer =
    return_apply.behind_gate(
      gate,
      1000,
      10_000,
      here(),
      here() <> "/src",
      fn(_workspace, _sent, _returned, _child) {
        process.send(called, Nil)
        Ok(#(ref(), 1))
      },
      some_state(),
      some_state(),
      "sub:^main/fix-cache-0123456789abcdef",
    )
  let assert Ok(remote_child.NotApplied(reason)) = answer
  assert string.contains(reason, "not the one the child was started from")
  assert process.receive(called, 100) == Error(Nil)

  // A workspace that cannot be read is refused too, and not applied into.
  let assert Ok(remote_child.NotApplied(_)) =
    return_apply.behind_gate(
      gate,
      1000,
      10_000,
      here() <> "/no-such-directory",
      here(),
      fn(_workspace, _sent, _returned, _child) { Ok(#(ref(), 1)) },
      some_state(),
      some_state(),
      "sub:^main/fix-cache-0123456789abcdef",
    )
}

// A parent that sent its dirty workspace, and a child that made two commits on
// top of the copy, with both bundles in the parent's store.
type Return {
  Return(
    rig: Rig,
    store: state_store.Store,
    sent: State,
    returned: State,
    child: String,
  )
}

fn returned(name: String) -> Return {
  let rig = state_rig.rig(name)
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let capturer =
    state_capture.new(
      rig.git,
      rig.state,
      [],
      state_service.endpoint(service),
      store,
    )
  worktree_rig.write(rig.root <> "/README", "parent edit\n")
  let assert Ok(sent) =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  let assert Ok(Some(held)) = state_store.get(store, sent.hash)
  let copy = rig.scratch <> "/copy"
  let assert Ok(_applied) =
    state_apply.apply(
      rig.git,
      held.path,
      held.state,
      Clone(destination: copy, session: "seed-0123456789abcdef"),
    )
  let _ = state_rig.commit_file(copy, "one.txt", "one\n", "child one")
  let _ = state_rig.commit_file(copy, "two.txt", "two\n", "child two")
  let assert Ok(Some(back)) =
    state_capture.capture_commits(capturer, copy, sent.tip)
  Return(
    rig:,
    store:,
    sent:,
    returned: back,
    child: "sub:^main/fix-cache-0123456789abcdef",
  )
}

fn behind(world: Return, gate: Gate) {
  behind_logging(world, gate, log.discard())
}

fn behind_logging(world: Return, gate: Gate, logger: log.Logger) {
  return_apply.behind_gate(
    gate,
    1000,
    60_000,
    world.rig.root,
    world.rig.root,
    return_apply.from_store(world.store, world.rig.git, logger),
    world.sent,
    world.returned,
    world.child,
  )
}

// The line an operator reads to know a child's commits arrived: which child, how
// many commits, which ref, and the returned state by its short hash and size.
pub fn applied_commits_are_told_with_the_child_and_the_ref_test() {
  let world = returned("return-apply-log")
  let gate = started()
  let logs = process.new_subject()
  let logger = log.new(sink: log.to_subject(logs), threshold: level.Info)

  let assert Ok(remote_child.Applied(ref:, commits: 2)) =
    behind_logging(world, gate, logger)
  let assert Ok(told) = process.receive(logs, 1000)
  assert told.event == "remote_spawn.commits_applied"
  assert told.fields
    == [
      field.ident("child", world.child),
      field.ident("state", state_object.short(world.returned.hash)),
      field.count("bytes", world.returned.size),
      field.count("commits", 2),
      field.text("ref", ref),
    ]
}

pub fn the_store_supplies_both_bundles_and_a_replay_changes_nothing_test() {
  let world = returned("return-apply-store")
  let gate = started()
  let before = state_rig.refs(world.rig.root)

  let assert Ok(remote_child.Applied(ref:, commits: 2)) = behind(world, gate)
  assert ref
    == "refs/loom/children/fix-cache-0123456789abcdef/"
    <> string.slice(world.returned.tip, 0, 8)
  let after = state_rig.refs(world.rig.root)
  assert string.contains(after, ref <> " " <> world.returned.tip)
  assert string.length(after) > string.length(before)

  // The same return again is the same answer and no second ref.
  assert behind(world, gate) == Ok(remote_child.Applied(ref:, commits: 2))
  assert state_rig.refs(world.rig.root) == after
  state_rig.stop(world.rig)
}

pub fn a_state_the_store_no_longer_holds_is_a_refusal_not_a_retry_test() {
  let world = returned("return-apply-lost")
  let gate = started()
  let before = state_rig.refs(world.rig.root)

  // The bundle expired from the store, as retention can leave it.
  let assert Ok(Some(held)) = state_store.get(world.store, world.returned.hash)
  let assert Ok(Nil) = simplifile.delete(held.path)
  let assert Ok(remote_child.NotApplied(reason)) = behind(world, gate)
  assert string.length(reason) > 0
  assert state_rig.refs(world.rig.root) == before
  state_rig.stop(world.rig)
}

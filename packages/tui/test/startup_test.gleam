//// Barriers prove overlap without asserting elapsed time. Model construction
//// remains in the terminal, and joining leaves no weft messages behind.

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import tui
import tui/connection
import tui/runtime
import tui/startup
import tui/workspace
import weft

pub fn resolver_overlaps_original_terminal_model_preparation_test() {
  isolated_terminal(fn() {
    let terminal = process.self()
    let started = process.new_subject()
    let pending =
      startup.begin_with(fn(owner, within) {
        let prepared = process.new_subject()
        process.send(started, #(owner, process.self(), within, prepared))
        let assert Ok(Nil) = process.receive(prepared, 2000)
          as "terminal preparation releases the resolver"
        Error("fixture refusal")
      })
    let assert Ok(#(owner, worker, within, prepared)) =
      process.receive(started, 2000)
      as "resolver starts before terminal preparation completes"
    assert owner == terminal
    assert worker != terminal
    assert within > 0 && within <= 90_000
    let model =
      tui.new_model(connection.new_inbox(), workspace.Context("/fixture", None))
    assert model.view.terminal == runtime.terminal_identity()
    process.send(prepared, Nil)
    assert startup.join(pending) == Error("fixture refusal")
    assert_mailbox_empty()
  })
}

pub fn immediate_refusal_before_join_leaves_no_outcomes_test() {
  // EUnit can reuse its caller across tests. This unrelated parent message
  // must survive; the isolated terminal's oracle still checks its whole inbox.
  let unrelated = process.new_subject()
  process.send(unrelated, Nil)
  isolated_terminal(fn() {
    list.each(list.repeat(Nil, 25), fn(_) {
      let completed = process.new_subject()
      let pending =
        startup.begin_with(fn(_, _) {
          process.send(completed, Nil)
          Error("immediate refusal")
        })
      assert process.receive(completed, 1000) == Ok(Nil)
      process.sleep(1)
      assert startup.join(pending) == Error("immediate refusal")
      assert_mailbox_empty()
    })
  })
  assert process.receive(unrelated, 0) == Ok(Nil)
}

pub fn normal_terminal_exit_cancels_inflight_resolver_test() {
  let ready = process.new_subject()
  let terminal =
    process.spawn(fn() {
      let stop = process.new_subject()
      let _pending =
        startup.begin_with(fn(owner, _) {
          process.send(ready, #(owner, process.self(), stop))
          let blocked = process.new_subject()
          let _ = process.receive(blocked, 5000)
          Error("terminal should have cancelled this task")
        })
      let _ = process.receive(stop, 5000)
      Nil
    })
  let assert Ok(#(owner, worker, stop)) = process.receive(ready, 2000)
    as "inflight resolver is known before terminal exit"
  assert owner == terminal
  let watch = process.monitor(worker)
  process.send(stop, Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(2000)
    as "normal terminal exit cancels and retires the resolver"
}

fn assert_mailbox_empty() {
  assert process.new_selector()
    |> process.select_other(fn(_) { Nil })
    |> process.selector_receive(0)
    == Error(Nil)
}

// Weft's scope owns its protocol messages; its fresh leaf receives none while
// running this body. The initial assertion proves the mailbox premise instead
// of flushing or filtering away evidence. A failure or deadline retires the
// terminal; terminal death cancels its linked startup run.
fn isolated_terminal(exercise: fn() -> Nil) {
  let outcomes =
    weft.new([
      fn() {
        assert_mailbox_empty()
        exercise()
        Ok(Nil)
      },
    ])
    |> weft.deadline(5000)
    |> weft.start
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the isolated terminal completed its whole-mailbox accounting checks"
  Nil
}

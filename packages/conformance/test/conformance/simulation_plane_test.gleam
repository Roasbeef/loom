//// The simulation's effect plane on its own: an execution a tool starts is
//// ended and settles once, one whose tool dies is cancelled by its relay, and
//// the check that would notice one that is neither reports it.
////
//// The sweep (`simulation_test`) shows the plane holding under generated
//// schedules. These tests show the other half: that its two checks can fail,
//// because a check that has never been seen to fail proves nothing.

import conformance/simulation/control
import conformance/simulation/plane
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string

/// A tool that starts an execution and finishes it leaves nothing behind,
/// and the service's books show it started and settled once.
pub fn a_finished_execution_leaves_nothing_behind_test() {
  let ctl = control.start()
  let effect_plane = plane.start()
  let assert Some(execution) = plane.begin(effect_plane, ctl)
    as "the plane clears an execution"
  plane.finish(effect_plane, execution)

  let observed = plane.verify(effect_plane)
  assert observed.violations == []
  assert observed.executions == 1
  plane.stop(effect_plane)
  control.stop(ctl)
}

/// A tool whose process dies with its execution in flight is the case the
/// plane exists for: the relay sees its caller go, cancels, settles, and the
/// broker returns the helper, so nothing is left to find.
pub fn an_execution_whose_tool_died_is_cancelled_by_its_relay_test() {
  let ctl = control.start()
  let effect_plane = plane.start()
  let started = process.new_subject()
  let tool =
    process.spawn_unlinked(fn() {
      let assert Some(_execution) = plane.begin(effect_plane, ctl)
        as "the plane clears an execution"
      process.send(started, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(started, 3000)
    as "the tool started its execution"
  process.kill(tool)

  let observed = plane.verify(effect_plane)
  assert observed.violations == []
  assert observed.executions == 1
  plane.stop(effect_plane)
  control.stop(ctl)
}

/// The control for the check itself: a tool that is still alive and never
/// ends its execution leaves a row, a borrowed helper and a live relay, and
/// `effects/no-orphan` names them. Without this the two tests above would pass
/// against a `verify` that always answered nothing.
pub fn an_execution_nobody_ends_is_reported_as_an_orphan_test() {
  let ctl = control.start()
  let effect_plane = plane.start()
  let started = process.new_subject()
  let tool =
    process.spawn_unlinked(fn() {
      let assert Some(_execution) = plane.begin(effect_plane, ctl)
        as "the plane clears an execution"
      process.send(started, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(started, 3000)
    as "the tool started its execution"

  let observed = plane.verify(effect_plane)
  let assert [violation] = observed.violations
    as "exactly one violation is reported"
  assert string.starts_with(violation, "effects/no-orphan: ")
  assert list.length(observed.violations) == 1
  process.kill(tool)
  plane.stop(effect_plane)
  control.stop(ctl)
}

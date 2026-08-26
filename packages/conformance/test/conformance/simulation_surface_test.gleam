//// The simulation surface's own seams, tested directly rather than
//// through a seed.
////
//// A generated seed exercises `surface.apply` only from inside a live
//// effect, where a steer is expected to land. What is worth testing
//// here is the other branch: what the surface does when an admission
//// does *not* land. A simulation that swallowed that failure would go
//// on to assert convergence over a transcript it had silently lost a
//// turn from, which is the one failure mode the whole runner exists to
//// rule out.

import conformance/simulation/control
import conformance/simulation/fault
import conformance/simulation/runner
import conformance/simulation/script
import conformance/simulation/surface
import conformance/simulation/vclock
import gleam/list
import gleam/option.{None}
import gleam/string
import machine/operation.{ReplaySafe}
import runtime/api
import session/session

// A script with no operations at all: the tree boots, the strand is
// idle, and no run is ever open. Every queue admission against it is
// refused in band, which is the undeliverable steer this module is
// about.
fn idle_script() -> script.Script {
  script.Script(
    registry: [#("read", ReplaySafe)],
    tools: [#("read", script.ToolOk(text: "out:read"))],
    ops: [],
    threshold_after: None,
    structural: script.Supplied,
    interventions: [],
    poll_answer: script.Answer(text: "unused", tokens: 1),
    subagent: None,
    parallel: False,
    escalate: False,
  )
}

// Boots a real simulated session tree on an idle strand and hands back
// its control actor, with the runtime published the way `runner.execute`
// publishes it.
fn idle_session() -> #(control.Control, vclock.Clockwork, api.Runtime) {
  let vc = vclock.start(from: 1_700_000_000_000)
  let ctl = control.start()
  let script = idle_script()
  let assert Ok(raw) = session.open_memory(vclock.clock(vc))
    as "the memory session must open"
  let surfaces =
    surface.build(ctl, vc, script, fault.none(), raw, strand: "main")
  let assert Ok(Nil) =
    session.ensure_strand(raw, "main", runner.configuration())
    as "the strand must seed"
  let assert Ok(runtime) =
    api.open(raw, surfaces, api.default_options(runner.configuration()))
    as "the session tree must boot"
  control.set_runtime(ctl, runtime)
  #(ctl, vc, runtime)
}

fn teardown(ctl: control.Control, vc: vclock.Clockwork, runtime: api.Runtime) {
  let _closed = api.close(runtime)
  vclock.stop(vc)
  control.stop(ctl)
}

/// A steer the runtime refuses is a turn the transcript has lost, so the
/// surface must record it where the runner's soundness check reads it.
pub fn refused_steer_is_recorded_test() {
  let #(ctl, vc, runtime) = idle_session()
  surface.apply(
    ctl,
    script.Steer(trigger: script.DuringTurn(turn: 0), text: "dropped"),
    awaited: True,
  )
  let notes = control.notes(ctl)
  teardown(ctl, vc, runtime)
  assert list.any(notes, fn(note) { string.contains(note, "steer") })
    as { "the refused steer was not recorded: " <> string.inspect(notes) }
}

/// The same for a follow-up: it is the same admission path and the same
/// lost turn.
pub fn refused_follow_up_is_recorded_test() {
  let #(ctl, vc, runtime) = idle_session()
  surface.apply(
    ctl,
    script.FollowUp(trigger: script.DuringTurn(turn: 0), text: "dropped"),
    awaited: True,
  )
  let notes = control.notes(ctl)
  teardown(ctl, vc, runtime)
  assert list.any(notes, fn(note) { string.contains(note, "follow-up") })
    as { "the refused follow-up was not recorded: " <> string.inspect(notes) }
}

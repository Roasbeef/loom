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
import core/json
import core/message.{UserMessage, UserText}
import core/register
import core/tx
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation.{ReplaySafe}
import runtime/api
import runtime/supervisor
import session/session
import storage/storage

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
fn idle_session() -> #(
  control.Control,
  vclock.Clockwork,
  session.Session,
  api.Runtime,
) {
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
  #(ctl, vc, raw, runtime)
}

fn teardown(ctl: control.Control, vc: vclock.Clockwork, runtime: api.Runtime) {
  let _closed = api.close(runtime)
  vclock.stop(vc)
  control.stop(ctl)
}

/// A steer the runtime refuses is a turn the transcript has lost, so the
/// surface must record it where the runner's soundness check reads it.
pub fn refused_steer_is_recorded_test() {
  let #(ctl, vc, raw, runtime) = idle_session()
  surface.apply(
    ctl,
    raw,
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
  let #(ctl, vc, raw, runtime) = idle_session()
  surface.apply(
    ctl,
    raw,
    script.FollowUp(trigger: script.DuringTurn(turn: 0), text: "dropped"),
    awaited: True,
  )
  let notes = control.notes(ctl)
  teardown(ctl, vc, runtime)
  assert list.any(notes, fn(note) { string.contains(note, "follow-up") })
    as { "the refused follow-up was not recorded: " <> string.inspect(notes) }
}

pub fn unavailable_admission_defers_the_untouched_suffix_test() {
  let #(ctl, vc, raw, runtime) = idle_session()
  let trigger = script.DuringTurn(turn: 0)
  let scripted =
    script.Script(..idle_script(), interventions: [
      script.Steer(trigger:, text: "first"),
      script.FollowUp(trigger:, text: "second"),
      script.Abort(trigger:),
    ])

  // Stop routing but retain the raw store for admission reconciliation. This
  // fixes the unavailable boundary independently of scheduler timing. A dead
  // root ends retries, so all three obligations must remain unobserved; in
  // particular, the abort must not run ahead of the unavailable admissions.
  assert supervisor.shutdown(runtime.tree, grace_ms: 1000) == Ok(Nil)
  surface.fire_due(ctl, scripted, raw, trigger)
  assert control.notes(ctl) == []
  assert control.waits(ctl)
    == [
      "intervening@steer-during-effect",
      "intervening@follow-up-during-effect",
      "intervening@abort-during-effect",
    ]
  assert list.contains(control.marks(ctl), "admission-unobserved")

  assert session.close(raw) == Ok(Nil)
  vclock.stop(vc)
  control.stop(ctl)
}

/// The signature passed to the runtime is the deterministic identity the
/// instrumented store recognizes and fences into the admission transaction.
pub fn intervention_user_carries_its_durable_identity_test() {
  let intervention =
    script.Steer(trigger: script.DuringTurn(turn: 2), text: "redirect")
  let assert UserMessage(
    content: [UserText(text: "redirect", text_signature: Some(identity))],
    ..,
  ) = surface.intervention_user(intervention, "redirect")
    as "a simulated intervention must carry its durable identity"
  assert identity == script.intervention_key(intervention)
    as "the queue signature and retry identity must be identical"
}

/// Recovery settles from the durable marker itself, not from post-commit
/// in-memory bookkeeping that a crash can overtake.
pub fn durable_admission_marker_settles_a_lost_reply_test() {
  let #(ctl, vc, raw, runtime) = idle_session()
  let intervention =
    script.FollowUp(trigger: script.DuringTurn(turn: 0), text: "landed")
  let fact_key =
    intervention
    |> script.intervention_key
    |> script.intervention_fact_key
  let assert Ok(_) =
    storage.commit(
      raw.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            ns: register.FactCustom,
            key: fact_key,
            value: register.value(json.Null),
          ),
        ],
        expected: [
          tx.Expect(ns: register.FactCustom, key: fact_key, seq: None),
        ],
      ),
    )
    as "the lost-reply marker must be durable"

  surface.apply(ctl, raw, intervention, awaited: True)
  let notes = control.notes(ctl)
  let waits = control.waits(ctl)
  teardown(ctl, vc, runtime)
  assert notes == []
    as {
      "a durable admission must not be reported as dropped: "
      <> string.inspect(notes)
    }
  assert waits
    == [
      "intervening@follow-up-during-effect",
      "intervened@follow-up-during-effect",
    ]
    as "the durable marker must close the claimed intervention debt"
}

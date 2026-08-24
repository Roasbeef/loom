//// Durable escalations (design §5.3): raise/approve/deny recorded in
//// `fact.custom` registers, grants fed into tool clearance exactly once,
//// and lifecycle transitions guarded so a decision is never overwritten.

import core/clock
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import machine/operation.{ReplaySafe}
import runtime/api
import runtime/effects
import runtime/escalation
import runtime/supervisor
import session/session
import support/fake
import support/harness
import support/recorder

fn denial() -> json.JsonValue {
  json.Object([
    #("reason", json.String("network off")),
    #("wanted", json.Array([grant()])),
  ])
}

fn grant() -> json.JsonValue {
  json.Object([
    #("grant", json.String("network")),
    #("network", json.String("proxy")),
  ])
}

pub fn escalation_lifecycle_and_single_consumption_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base_effects =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("read", ReplaySafe)],
      fn(spec) {
        case fake.turn(spec) {
          0 -> fake.Reply(fake.tool_use("retrying", [#("c1", "read")], 4))
          _ -> fake.Reply(fake.answer("done", 5))
        }
      },
      fn(tool_run) {
        fake.ToolReply(
          text: "out:" <> tool_run.call.name,
          is_error: False,
          terminate: False,
        )
      },
    )
  // Instrument clearance to record how many grants each call saw.
  let eff =
    effects.Effects(
      ..base_effects,
      tools: effects.ToolSurface(
        ..base_effects.tools,
        clear: fn(query: effects.ClearanceQuery) {
          let _count =
            recorder.bump(
              rec,
              "grants:" <> int.to_string(list.length(query.grants)),
            )
          effects.Cleared(
            effective_arguments: query.call.arguments,
            replay: ReplaySafe,
          )
        },
      ),
    )
  let base = api.default_options(harness.configuration())
  let options =
    api.Options(
      ..base,
      poll_interval_ms: 50,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  // Raise durably; a duplicate raise is refused.
  let assert Ok(Nil) = api.raise_escalation(rt, "esc-1", denial())
  let assert Error(api.EscalationExists(id: "esc-1")) =
    api.raise_escalation(rt, "esc-1", denial())
  let assert Ok([record]) = api.escalations(rt)
  assert record.status == escalation.Pending
  // Only pending escalations decide; a decided one refuses re-decision.
  let assert Ok(Nil) = api.approve_escalation(rt, "esc-1", [grant()])
  let assert Error(api.EscalationWrongStatus(
    id: "esc-1",
    status: escalation.Approved,
  )) = api.approve_escalation(rt, "esc-1", [grant()])
  let assert Error(api.EscalationWrongStatus(id: "esc-1", status: _)) =
    api.deny_escalation(rt, "esc-1")
  // The next tool clearance carries the approved grant and consumes the
  // approval; later clearances see no grants.
  let assert Ok(op) = api.prompt(rt, [fake.user("try again")])
    as "the prompt must be accepted"
  let assert Ok(last) = api.await_result(rt, op, within_ms: 10_000)
    as "the run must finish"
  harness.assert_completed(last)
  assert recorder.read(rec, "grants:1") == 1
  let assert Ok([consumed]) = api.escalations(rt)
  assert consumed.status == escalation.Consumed
  // The single re-execution is spent: explicit consumption refuses too.
  let assert Error(api.EscalationWrongStatus(
    id: "esc-1",
    status: escalation.Consumed,
  )) = api.consume_escalation(rt, "esc-1")
  // Escalation records never masquerade as blackboard facts, and the
  // reserved prefix refuses fact writes.
  let assert Ok([]) = api.facts(rt, prefix: option.None)
  let assert Error(api.ReservedFactKey(key: "escalation/esc-9")) =
    api.put_fact(rt, "escalation/esc-9", json.String("nope"))
  process.kill(rt.tree.supervisor)
}

pub fn denied_escalation_grants_nothing_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Reply(fake.answer("ok", 1)) },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) =
    api.open(
      sess,
      eff,
      api.Options(
        ..api.default_options(harness.configuration()),
        poll_interval_ms: 50,
        tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
      ),
    )
    as "the session tree must boot"
  let assert Ok(Nil) = api.raise_escalation(rt, "esc-2", denial())
  let assert Ok(Nil) = api.deny_escalation(rt, "esc-2")
  let assert Error(api.EscalationWrongStatus(
    id: "esc-2",
    status: escalation.Rejected,
  )) = api.consume_escalation(rt, "esc-2")
  let assert Ok([record]) = api.escalations(rt)
  assert record.status == escalation.Rejected
  assert record.grants == []
  process.kill(rt.tree.supervisor)
}

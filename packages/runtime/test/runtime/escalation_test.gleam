//// Durable escalations (design §5.3): raise/approve/deny recorded in
//// `fact.custom` registers, an approval attributed to the exact call its
//// denial was raised for, grants consumed by CAS *before* they are used,
//// and lifecycle transitions guarded so a decision is never overwritten.

import core/clock
import core/ids.{type OpId}
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
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

fn options() -> api.Options {
  api.Options(
    ..api.default_options(harness.configuration()),
    poll_interval_ms: 50,
    tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
  )
}

// An approval that carries no call attribution — or one attributed to a
// *different* call — must widen nothing: no clearance on any strand may
// load its grants, and no clearance may burn it. Before attribution
// landed, the driver handed the union of every approved escalation's
// grants to whichever call cleared next, so this test fails on that
// code: the clearance sees one grant and the approval comes back
// consumed.
pub fn unattributed_approvals_never_widen_a_clearance_test() {
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
  let assert Ok(rt) = api.open(sess, eff, options())
    as "the session tree must boot"
  // Raise durably; a duplicate raise is refused.
  let assert Ok(Nil) = api.raise_escalation(rt, "esc-1", denial())
  let assert Error(api.EscalationExists(id: "esc-1")) =
    api.raise_escalation(rt, "esc-1", denial())
  let assert Ok([record]) = api.escalations(rt)
  assert record.status == escalation.Pending
  assert record.scope == None
  // Only pending escalations decide; a decided one refuses re-decision.
  let assert Ok(Nil) = api.approve_escalation(rt, "esc-1", [grant()])
  let assert Error(api.EscalationWrongStatus(
    id: "esc-1",
    status: escalation.Approved,
  )) = api.approve_escalation(rt, "esc-1", [grant()])
  let assert Error(api.EscalationWrongStatus(id: "esc-1", status: _)) =
    api.deny_escalation(rt, "esc-1")
  // A second approval, attributed to a call this run will never make (a
  // sibling strand's coordinates): its grant must stay put too.
  let elsewhere =
    escalation.CallScope(
      operation: alien_op_id(),
      strand: "sub:1",
      step_id: "s1",
      source_index: 0,
      call_id: "c9",
    )
  let assert Ok(Nil) =
    api.raise_escalation_for(rt, "esc-2", denial(), scope: elsewhere)
  let assert Ok(Nil) = api.approve_escalation(rt, "esc-2", [grant()])
  // The run's clearance sees no grants at all, and neither approval is
  // burned by it.
  let assert Ok(op) = api.prompt(rt, [fake.user("try again")])
    as "the prompt must be accepted"
  let assert Ok(last) = api.await_result(rt, op, within_ms: 10_000)
    as "the run must finish"
  harness.assert_completed(last)
  assert recorder.read(rec, "grants:0") >= 1
  assert recorder.read(rec, "grants:1") == 0
  let assert Ok(records) = api.escalations(rt)
  assert list.map(records, fn(record) { record.status })
    == [escalation.Approved, escalation.Approved]
  // The unscoped approval is still spendable the explicit way — once.
  let assert Ok([_grant]) = api.consume_escalation(rt, "esc-1")
  let assert Error(api.EscalationWrongStatus(
    id: "esc-1",
    status: escalation.Consumed,
  )) = api.consume_escalation(rt, "esc-1")
  // Escalation records never masquerade as blackboard facts, and the
  // reserved prefixes refuse fact writes.
  let assert Ok([]) = api.facts(rt, prefix: None)
  let assert Error(api.ReservedFactKey(key: "escalation/esc-9")) =
    api.put_fact(rt, "escalation/esc-9", json.String("nope"))
  let assert Error(api.ReservedFactKey(key: "operation-result/op-9")) =
    api.put_fact(rt, "operation-result/op-9", json.String("nope"))
  process.kill(rt.tree.supervisor)
}

// An operation id that is valid but names no operation in this session:
// coordinates for a call the session will never clear.
fn alien_op_id() -> OpId {
  let generator = ids.generator(clock.fixed(at: 42), seed: 424_242)
  let #(op, _generator) = ids.mint_op(generator)
  op
}

// The scoped path end to end: a denial's escalation is raised for the
// exact call being cleared, approved, and — after the driver restarts —
// the *same durable call coordinates* re-clear with the grant. The test
// pins both security orderings at their sharpest observable points:
//
// - the grant reaches only the clearance whose coordinates match, and
// - by the time `tools.clear` sees the grant, the approval is already
//   durably consumed (consume-before-clear), so an explicit concurrent
//   consumer — standing in for a second driver racing the same approval
//   — is refused rather than handed a second spend.
//
// Before the fix the consumption ran *after* the clearance had already
// used the grants and a lost CAS was swallowed, so the concurrent
// consume here would succeed: one approval, two spends.
pub fn scoped_approval_is_consumed_before_its_clearance_test() {
  let rec = recorder.start()
  let cell = holder()
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
          0 -> fake.Reply(fake.tool_use("working", [#("c1", "read")], 4))
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
  let eff =
    effects.Effects(
      ..base_effects,
      tools: effects.ToolSurface(..base_effects.tools, clear: fn(query) {
        clear_with_escalation_dance(rec, cell, "esc-c1", query)
      }),
    )
  let assert Ok(rt) = api.open(sess, eff, options())
    as "the session tree must boot"
  put(cell, rt)
  let assert Ok(op) = api.prompt(rt, [fake.user("dig in")])
    as "the prompt must be accepted"
  let assert Ok(last) = api.await_result(rt, op, within_ms: 15_000)
    as "the run must finish across the scripted driver restart"
  harness.assert_completed(last)
  // The re-clearance carried exactly the approved grant...
  assert recorder.read(rec, "grants-at-reclear:1") == 1
  // ...the approval was already consumed when the clearance saw it...
  assert recorder.read(rec, "consumed-before-clear") == 1
  // ...the racing explicit consume was refused, so one approval bought
  // exactly one spend...
  assert recorder.read(rec, "double-spend-refused") == 1
  // ...and the tool executed exactly once under it.
  assert recorder.read(rec, "tool:read:c1") == 1
  let assert Ok([record]) = api.escalations(rt)
  assert record.status == escalation.Consumed
  process.kill(rt.tree.supervisor)
}

// The clearance hook for the scoped test. First clearance of `c1`: raise
// an escalation attributed to exactly this call, approve it, then kill
// the driver (from inside its own actor process) so the durable state
// replans and the *same* coordinates clear again — the only way to reach
// a grant-bearing clearance without predicting minted ids. Second
// clearance: verify the security orderings and clear.
fn clear_with_escalation_dance(
  rec: Subject(recorder.Message),
  cell: Holder,
  id: String,
  query: effects.ClearanceQuery,
) -> effects.Clearance {
  let assert Some(rt) = get(cell) as "the runtime must be published"
  case recorder.bump(rec, "clearance:" <> query.call.id) {
    1 -> {
      let scope =
        escalation.CallScope(
          operation: query.operation,
          strand: "main",
          step_id: query.step_id,
          source_index: query.source_index,
          call_id: query.call.id,
        )
      let assert Ok(Nil) =
        api.raise_escalation_for(rt, id, denial(), scope: scope)
        as "raising the scoped escalation must commit"
      let assert Ok(Nil) = api.approve_escalation(rt, id, [grant()])
        as "approving the scoped escalation must commit"
      // Die before returning: the restart's re-plan re-resolves this
      // clearance from durable state, now with the approval in place.
      process.kill(process.self())
      effects.ClearanceRefused(reason: "unreachable: the driver was killed")
    }
    _ -> {
      let _seen =
        recorder.bump(
          rec,
          "grants-at-reclear:" <> int.to_string(list.length(query.grants)),
        )
      // Consume-before-clear: the record must already be durably
      // consumed at the moment the grants are first usable.
      let assert Ok([record]) = api.escalations(rt)
        as "the escalation record must list"
      case record.status == escalation.Consumed {
        True -> recorder.bump(rec, "consumed-before-clear")
        False -> recorder.bump(rec, "still-unconsumed-at-clear")
      }
      // A concurrent consumer racing this clearance must lose: the CAS
      // was spent by the consumption that preceded this clearance.
      case api.consume_escalation(rt, id) {
        Error(api.EscalationWrongStatus(..)) ->
          recorder.bump(rec, "double-spend-refused")
        _ -> recorder.bump(rec, "double-spend-allowed")
      }
      effects.Cleared(
        effective_arguments: query.call.arguments,
        replay: ReplaySafe,
      )
    }
  }
}

// Step 1 of the grants channel, at its far end: an approval consumed at
// clearance must reach the *execution*. `ClearanceQuery` carried the
// grants and `ToolRun` dropped them on the floor, so a grant a human
// approved could be consumed, attributed, and still never reach a policy
// decision — the whole approval path was theatre below the clearance.
// The dance here is the same one the scoped test drives; what this test
// watches is the tool run, not the query.
pub fn approved_grants_reach_the_tool_run_test() {
  let rec = recorder.start()
  let cell = holder()
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
          0 -> fake.Reply(fake.tool_use("working", [#("c1", "read")], 4))
          _ -> fake.Reply(fake.answer("done", 5))
        }
      },
      fn(tool_run: effects.ToolRun) {
        let _seen =
          recorder.bump(
            rec,
            "run-grants:" <> int.to_string(list.length(tool_run.grants)),
          )
        case tool_run.grants == [grant()] {
          True -> recorder.bump(rec, "run-grant-is-the-approved-one")
          False -> recorder.bump(rec, "run-grant-is-something-else")
        }
        fake.ToolReply(text: "out", is_error: False, terminate: False)
      },
    )
  let eff =
    effects.Effects(
      ..base_effects,
      tools: effects.ToolSurface(..base_effects.tools, clear: fn(query) {
        clear_with_escalation_dance(rec, cell, "esc-run", query)
      }),
    )
  let assert Ok(rt) = api.open(sess, eff, options())
    as "the session tree must boot"
  put(cell, rt)
  let assert Ok(op) = api.prompt(rt, [fake.user("dig in")])
    as "the prompt must be accepted"
  let assert Ok(last) = api.await_result(rt, op, within_ms: 15_000)
    as "the run must finish across the scripted driver restart"
  harness.assert_completed(last)
  // The execution carried exactly the approved grant, and carried it
  // exactly once: no run saw an empty grant list after the re-clearance.
  assert recorder.read(rec, "run-grants:1") == 1
  assert recorder.read(rec, "run-grants:0") == 0
  assert recorder.read(rec, "run-grant-is-the-approved-one") == 1
  assert recorder.read(rec, "run-grant-is-something-else") == 0
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
  let assert Ok(rt) = api.open(sess, eff, options())
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

// --- a tiny published-value cell -------------------------------------------
//
// The clearance hooks need the runtime handle, which exists only after
// `api.open` — and `api.open` needs the effects record that closes over
// the hooks. A one-slot actor breaks the cycle: the test publishes the
// handle after opening, the hooks read it at clearance time.

type HolderMessage {
  Put(runtime: api.Runtime)
  Get(reply_with: Subject(Option(api.Runtime)))
}

type Holder =
  Subject(HolderMessage)

fn holder() -> Holder {
  let assert Ok(started) =
    actor.new(None)
    |> actor.on_message(fn(state, message) {
      case message {
        Put(runtime:) -> actor.continue(Some(runtime))
        Get(reply_with:) -> {
          process.send(reply_with, state)
          actor.continue(state)
        }
      }
    })
    |> actor.start
    as "the runtime holder must start"
  started.data
}

fn put(cell: Holder, runtime: api.Runtime) -> Nil {
  process.send(cell, Put(runtime:))
}

fn get(cell: Holder) -> Option(api.Runtime) {
  process.call_forever(cell, Get)
}

// --- claiming a record ------------------------------------------------------

// The record id is a digest of the *want*, not of the call, so under a
// retry loop the row is nearly always already there when a refusal
// arrives. `claim_escalation` is what a raiser does about that: the row
// stays one row and the scope follows whichever call is standing at the
// door, because a scope frozen to the first attempt names a call that
// has already settled and an approval scoped to it can never be spent.
//
// This walks the whole transition table, since which state a claim may
// take over is the security-relevant part of it.
pub fn a_claim_moves_a_record_to_the_call_standing_at_the_door_test() {
  let rt = quiet_runtime()
  let a = scope_for("call-a")
  let b = scope_for("call-b")

  // Absent: the claim writes the record, exactly as a raise would.
  let assert Ok(raised) = api.claim_escalation(rt, "esc-1", denial(), scope: a)
    as "the first claim must file the record"
  assert raised.status == escalation.Pending
  assert raised.scope == Some(a)

  // Pending: the claim moves, and the stored denial is refreshed to the
  // live call's, so a human reads what the call in hand actually wants.
  let assert Ok(moved) =
    api.claim_escalation(rt, "esc-1", other_denial(), scope: b)
    as "a pending record must move to the new claimant"
  assert moved.status == escalation.Pending
  assert moved.scope == Some(b)
  assert moved.denial == other_denial()

  // Approved: the claim moves and the grants do not. What a human
  // authorized is unchanged; only who may spend it moves.
  let assert Ok(Nil) = api.approve_escalation(rt, "esc-1", [grant()])
    as "the approval must commit"
  let assert Ok(approved) =
    api.claim_escalation(rt, "esc-1", denial(), scope: a)
    as "an approved record must move to the new claimant"
  assert approved.status == escalation.Approved
  assert approved.scope == Some(a)
  assert approved.grants == [grant()]

  // Consumed: a new question, with no grants carried over — which is
  // what keeps one approval worth exactly one widened execution.
  let assert Ok([_spent]) = api.consume_escalation(rt, "esc-1")
    as "the approval must be spendable once"
  let assert Ok(reopened) =
    api.claim_escalation(rt, "esc-1", denial(), scope: b)
    as "a consumed record must re-open"
  assert reopened.status == escalation.Pending
  assert reopened.scope == Some(b)
  assert reopened.grants == []

  // Rejected: likewise a new question, so one "no" is a decision about
  // one call rather than a verdict the session cannot revisit.
  let assert Ok(Nil) = api.deny_escalation(rt, "esc-1") as "the denial commits"
  let assert Ok(asked_again) =
    api.claim_escalation(rt, "esc-1", denial(), scope: a)
    as "a rejected record must re-open"
  assert asked_again.status == escalation.Pending
  assert asked_again.grants == []

  // Throughout: one row.
  let assert Ok([_one]) = api.escalations(rt) as "one record, all along"

  // And the write-once door is still write-once: a caller that means
  // "record this, once" still gets `EscalationExists`.
  let assert Error(api.EscalationExists(id: "esc-1")) =
    api.raise_escalation_for(rt, "esc-1", denial(), scope: a)
    as "raise_escalation_for stays write-once"

  // The cheap, bounded question a raiser asks before opening a new row.
  let assert Ok(True) = api.escalations_below(rt, 2) as "one record fits"
  let assert Ok(False) = api.escalations_below(rt, 1) as "one record fills one"
  process.kill(rt.tree.supervisor)
}

fn other_denial() -> json.JsonValue {
  json.Object([
    #("reason", json.String("wall clock too short")),
    #("wanted", json.Array([grant()])),
  ])
}

fn scope_for(call_id: String) -> escalation.CallScope {
  escalation.CallScope(
    operation: alien_op_id(),
    strand: "main",
    step_id: "turn-1:tools",
    source_index: 0,
    call_id:,
  )
}

// A runtime with nothing driving it: this suite's claim coverage is
// about the durable record, not about a run.
fn quiet_runtime() -> api.Runtime {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Reply(fake.answer("unused", 1)) },
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let assert Ok(rt) = api.open(sess, eff, options())
    as "the session tree must boot"
  rt
}

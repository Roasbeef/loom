//// The M3 runtime slice of the milestone acceptance: a parent strand
//// and two subagent strands collaborating over the shared tree via
//// durable messaging to a combined result — and surviving a
//// kill-and-reboot mid-collaboration, with recovery restoring all three
//// strands from the store.
////
//// The subagent doctrine exercised here (design §4.2/§4.6): subagents
//// are strands forked in place at a parent entry (shared history, own
//// leaf register, own durable model identity); the request/reply
//// pattern is a task-brief run plus the child's durable terminal
//// result; cross-strand payloads travel as durable queue admissions
//// (`send_to_strand`), and the blackboard is `fact.custom`.

import core/clock
import core/json
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import machine/operation
import machine/strand.{
  type StrandConfiguration, ModelIdentity, StrandConfiguration, ThinkingOff,
}
import runtime/api
import runtime/effects
import runtime/supervisor
import session/session
import support/fake
import support/harness
import support/recorder

fn sub_configuration(model_id: String) -> StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id:),
    thinking_level: ThinkingOff,
    active_tool_names: [],
  )
}

fn model_of(spec: effects.RequestSpec) -> String {
  case spec {
    effects.GenerationRequest(configuration:, ..) ->
      configuration.model.model_id
    effects.PollRequest(configuration:, ..) -> configuration.model.model_id
    effects.SummaryRequest(configuration:, ..) -> configuration.model.model_id
  }
}

// The collaboration script, keyed by each strand's own durable model
// identity and the phase of its projected context — never by counters,
// so it answers the same way before and after the reboot. Each
// subagent's *first* attempt hangs (and is orphaned by the kill); the
// retry after recovery answers.
fn collaboration_provider(spec: effects.RequestSpec) -> fake.ProviderResult {
  case model_of(spec) {
    "sub-a" ->
      case fake.attempt(spec) {
        1 -> fake.Hang
        _ -> fake.Reply(fake.answer("part-a", 5))
      }
    "sub-b" ->
      case fake.attempt(spec) {
        1 -> fake.Hang
        _ -> fake.Reply(fake.answer("part-b", 6))
      }
    _ ->
      case fake.turn(spec) {
        0 -> fake.Reply(fake.answer("delegating", 3))
        _ -> fake.Reply(fake.answer("combined: part-a part-b", 7))
      }
  }
}

pub fn parent_and_two_subagents_collaborate_across_reboot_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      collaboration_provider,
      fn(_run) {
        fake.ToolReply(text: "unused", is_error: False, terminate: False)
      },
    )
  let base = api.default_options(harness.configuration())
  let options =
    api.Options(
      ..base,
      retry_policy: operation.NormalizedRetryPolicy(
        max_attempts: 3,
        base_delay_ms: 30,
      ),
      poll_interval_ms: 50,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  // 1. The parent plans.
  let assert Ok(plan_op) = api.prompt(rt, [fake.user("plan")])
    as "the parent prompt must be accepted"
  let assert Ok(_last) = api.await_result(rt, plan_op, within_ms: 10_000)
    as "the parent's planning run must finish"
  // 2. Two subagents fork in place at the parent's leaf, each with its
  // own model identity and a task-brief first run.
  let assert Ok(Some(session.Cell(value: fork, ..))) =
    session.strand_leaf(sess, "main")
    as "the parent must have a leaf to fork at"
  let assert Ok(op_a) =
    api.create_strand(
      rt,
      named: "sub:1",
      configuration: sub_configuration("sub-a"),
      at: fork,
      brief: [fake.user("do part a")],
    )
    as "sub:1 must be created"
  let assert Ok(op_b) =
    api.create_strand(
      rt,
      named: "sub:2",
      configuration: sub_configuration("sub-b"),
      at: fork,
      brief: [fake.user("do part b")],
    )
    as "sub:2 must be created"
  // A second creation under the same name is refused durably.
  let assert Error(api.StrandExists(name: "sub:1")) =
    api.create_strand(
      rt,
      named: "sub:1",
      configuration: sub_configuration("sub-a"),
      at: fork,
      brief: [fake.user("again")],
    )
  // 3. Kill the whole tree mid-collaboration: both subagents have a
  // provider request in flight (their first attempts hang by script).
  wait_for(fn() { recorder.read(rec, "provider") >= 3 }, 5000)
  process.kill(rt.tree.supervisor)
  wait_for(fn() { !process.is_alive(rt.tree.supervisor) }, 1000)
  // 4. Reopen from the same store: recovery boots ALL strands from the
  // strand.* registers, not just "main".
  let assert Ok(rt) = api.open(sess, eff, options) as "the session must reopen"
  let assert Ok(["main", "sub:1", "sub:2"]) = api.strands(rt)
  // 5. Both subagents recover their orphaned attempts and complete.
  let assert Ok(last_a) =
    api.await_strand_result(
      rt,
      strand: "sub:1",
      operation: op_a,
      within_ms: 15_000,
    )
    as "sub:1 must complete after recovery"
  harness.assert_completed(last_a)
  let assert Ok(last_b) =
    api.await_strand_result(
      rt,
      strand: "sub:2",
      operation: op_b,
      within_ms: 15_000,
    )
    as "sub:2 must complete after recovery"
  harness.assert_completed(last_b)
  // Each subagent worked over the shared history: its projection opens
  // with the parent's turn it forked from.
  assert strand_projection(sess, "sub:1")
    == [
      "user:plan", "assistant:stop:delegating", "user:do part a",
      "assistant:stop:part-a",
    ]
  assert strand_projection(sess, "sub:2")
    == [
      "user:plan", "assistant:stop:delegating", "user:do part b",
      "assistant:stop:part-b",
    ]
  // 6. Findings go to the durable blackboard...
  let assert Ok(Nil) = api.put_fact(rt, "notes/sub:1", json.String("part-a"))
  let assert Ok(Nil) = api.put_fact(rt, "notes/sub:2", json.String("part-b"))
  let assert Ok(Some(json.String("part-a"))) = api.fact(rt, "notes/sub:1")
  let assert Ok(facts) = api.facts(rt, prefix: Some("notes/"))
  assert list.length(facts) == 2
  // 7. ...and the combined result reaches the parent as a durable
  // message: the parent is idle, so the send accepts a fresh run.
  let assert Ok(api.Started(operation: combine_op)) =
    api.send_to_strand(
      rt,
      to: "main",
      message: fake.user("combine: part-a part-b"),
    )
  let assert Ok(combined) = api.await_result(rt, combine_op, within_ms: 15_000)
    as "the combining run must finish"
  harness.assert_completed(combined)
  assert strand_projection(sess, "main")
    == [
      "user:plan", "assistant:stop:delegating", "user:combine: part-a part-b",
      "assistant:stop:combined: part-a part-b",
    ]
  process.kill(rt.tree.supervisor)
}

pub fn send_to_strand_steers_an_open_run_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("slow", operation.ReplayNever)],
      fn(spec) {
        case fake.turn(spec) {
          0 -> fake.Reply(fake.tool_use("working", [#("c1", "slow")], 4))
          _ -> fake.Hang
        }
      },
      fn(_run) { fake.ToolHang },
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
  let assert Ok(op) = api.prompt(rt, [fake.user("dig in")])
    as "the prompt must be accepted"
  // Once the tool is in flight the run is durably open: a cross-strand
  // send lands as a steer item on its queue.
  wait_for(fn() { recorder.read(rec, "tool:slow:c1") >= 1 }, 5000)
  let assert Ok(api.Steered(entry: _)) =
    api.send_to_strand(rt, to: "main", message: fake.user("also this"))
  api.abort(rt)
  let assert Ok(last) = api.await_result(rt, op, within_ms: 10_000)
    as "the aborted run must reach its terminal result"
  harness.assert_aborted(last)
  process.kill(rt.tree.supervisor)
}

fn strand_projection(sess: session.Session, strand: String) -> List(String) {
  let leaf = case session.strand_leaf(sess, strand) {
    Ok(Some(session.Cell(value: leaf, ..))) -> leaf
    _ -> None
  }
  let assert Ok(messages) = session.project_context(sess, leaf)
    as "the strand projection must read cleanly"
  list.map(messages, harness.fingerprint)
}

fn wait_for(condition: fn() -> Bool, remaining: Int) -> Nil {
  case condition() {
    True -> Nil
    False ->
      case remaining <= 0 {
        True -> panic as "timed out waiting for a test condition"
        False -> {
          process.sleep(10)
          wait_for(condition, remaining - 10)
        }
      }
  }
}

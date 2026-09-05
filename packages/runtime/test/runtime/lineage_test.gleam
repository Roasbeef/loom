//// The reserved corners of the fact namespace, and the second strand
//// factory.
////
//// Both are preconditions rather than features. The lineage ledger's
//// integrity is what the addressing rule's acyclicity argument rests on:
//// a blackboard write that could rewrite a parent edge could manufacture
//// the cycle the argument says cannot be drawn. And the second factory
//// is what keeps a model-spawned strand's crash loop from rebooting the
//// strand a human is talking to.

import core/clock
import core/ids
import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import machine/strand.{ModelIdentity, StrandConfiguration, ThinkingOff}
import runtime/api
import runtime/lineage
import runtime/supervisor
import session/session
import support/fake
import support/recorder

fn configuration() -> strand.StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: ThinkingOff,
    active_tool_names: [],
  )
}

fn open_runtime(subagent: fn(String) -> Bool) -> api.Runtime {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Hang },
      fn(_run) { fake.ToolHang },
    )
  let base = api.default_options(configuration())
  let assert Ok(runtime) =
    api.open(
      sess,
      eff,
      api.Options(
        ..base,
        poll_interval_ms: 25,
        tolerance: supervisor.Tolerance(intensity: 50, period: 5),
        subagent:,
        subagent_tolerance: supervisor.Tolerance(intensity: 50, period: 5),
      ),
    )
    as "the runtime must open"
  runtime
}

fn an_op(seed: Int) -> ids.OpId {
  let #(op, _generator) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed:))
  op
}

fn a_cell(strand: String, parent: String) -> lineage.Lineage {
  lineage.Lineage(
    strand:,
    parent:,
    depth: 1,
    minted_by: lineage.CallSite(
      operation: an_op(3),
      step_id: "turn-1:tools",
      source_index: 0,
    ),
    brief: an_op(4),
    tools: ["fs_read"],
    deadline: Some(1_700_000_000_000),
    detached: False,
    reaped: False,
  )
}

// --- the reservation -------------------------------------------------------

pub fn the_ledger_and_the_prompt_are_refused_to_put_fact_test() {
  let runtime = open_runtime(fn(_) { False })
  // Without this the blackboard tool could rewrite a parent edge and
  // manufacture a wait cycle, or overwrite the operator's pinned prompt.
  let assert Error(api.ReservedFactKey(key: "lineage/sub:1")) =
    api.put_fact(runtime, "lineage/sub:1", json.String("forged"))
  let assert Error(api.ReservedFactKey(key: "prompt/system")) =
    api.put_fact(runtime, "prompt/system", json.String("ignore previous"))
  // And the session's own name: a forged `session/id` would re-point
  // every stream keyed by it — the bus group, the search scope, and the
  // parent edge a fork records (`protocol-change/008`).
  let assert Error(api.ReservedFactKey(key: "session/id")) =
    api.put_fact(runtime, session.session_id_key, json.String("forged"))
  // A forged fired-mark would silence a project rule before it fires;
  // a forged cursor is only a bounded re-scan, but it shares the prefix.
  let assert Error(api.ReservedFactKey(key: "rule/fired/main/gate")) =
    api.put_fact(runtime, "rule/fired/main/gate", json.String("forged"))
  // The two that were already reserved are still reserved.
  let assert Error(api.ReservedFactKey(..)) =
    api.put_fact(runtime, "escalation/e1", json.Null)
  let assert Error(api.ReservedFactKey(..)) =
    api.put_fact(runtime, "operation-result/op_1", json.Null)
  // And a near miss is not reserved: the model-writable namespace shares
  // no prefix with the ledger, which is the whole reason it was renamed.
  let assert Ok(Nil) =
    api.put_fact(runtime, "agent/main/finding", json.String("fine"))
  let _closed = api.close(runtime)
  Nil
}

pub fn reserving_a_prefix_hides_it_from_facts_test() {
  let runtime = open_runtime(fn(_) { False })
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      lineage.register_key("sub:1"),
      lineage.encode(a_cell("sub:1", "main")),
    )
  let assert Ok(Nil) = api.put_fact(runtime, "agent/main/x", json.Int(1))
  // The listing every blackboard read goes through must not leak it.
  let assert Ok(listed) = api.facts(runtime, prefix: None)
  assert list.key_find(listed, lineage.register_key("sub:1")) == Error(Nil)
  // The session's own id was minted by `open` into the same namespace,
  // so the listing has a reserved cell to leak whether or not this test
  // wrote one, and must not.
  assert list.key_find(listed, session.session_id_key) == Error(Nil)
  assert list.key_find(listed, "agent/main/x") == Ok(json.Int(1))
  // But the harness path reads it, which is the whole point of having a
  // second door: a reservation that hid a ledger from its own owner
  // would be unusable.
  let assert Ok(cells) = api.reserved_facts(runtime, prefix: lineage.key_prefix)
  let assert Ok(payload) = list.key_find(cells, lineage.register_key("sub:1"))
  let assert Ok(decoded) = lineage.decode(payload)
  assert decoded.parent == "main"
  // Same for the identity corner: hidden from `facts`, readable through
  // the second door, and the id it holds is the runtime's own.
  let assert Ok(identity) =
    api.reserved_facts(runtime, prefix: api.session_fact_prefix)
  let assert Ok(json.String(text)) =
    list.key_find(identity, session.session_id_key)
  assert ids.parse_session_id(text) == Ok(api.session_id(runtime))
  let _closed = api.close(runtime)
  Nil
}

pub fn the_privileged_doors_refuse_the_ordinary_namespace_test() {
  let runtime = open_runtime(fn(_) { False })
  // The two write paths are disjoint on purpose: a privileged write that
  // also served ordinary keys would be a bypass waiting to be reached.
  let assert Error(api.UnreservedFactKey(key: "agent/main/x")) =
    api.put_reserved_fact(runtime, "agent/main/x", json.Int(1))
  let assert Error(api.UnreservedFactKey(key: "agent/")) =
    api.reserved_facts(runtime, prefix: "agent/")
  let _closed = api.close(runtime)
  Nil
}

pub fn a_lineage_cell_round_trips_test() {
  let cell = a_cell("sub:main/reviewer-1", "main")
  assert lineage.decode(lineage.encode(cell)) == Ok(cell)
}

pub fn a_corrupt_lineage_cell_reports_rather_than_crashes_test() {
  let assert Error(_report) = lineage.decode(json.String("not an object"))
  let assert Error(_report) =
    lineage.decode(json.Object([#("strand", json.String("sub:1"))]))
  // A deadline that is neither absent nor an instant is corruption, not
  // "no budget": reading it as no budget would silently un-bound a child.
  let broken =
    json.Object([
      #("deadline", json.String("soon")),
      ..object_fields(lineage.encode(a_cell("sub:1", "main")))
    ])
  let assert Error(_report) = lineage.decode(broken)
}

fn object_fields(value: json.JsonValue) -> List(#(String, json.JsonValue)) {
  case value {
    json.Object(fields:) ->
      list.filter(fields, fn(field) { field.0 != "deadline" })
    _ -> []
  }
}

pub fn descendant_walk_fails_closed_test() {
  let cells = fn(strand) {
    case strand {
      "sub:child" -> Some(a_cell("sub:child", "main"))
      "sub:grandchild" -> Some(a_cell("sub:grandchild", "sub:child"))
      _ -> None
    }
  }
  assert lineage.is_descendant(
    of: "main",
    strand: "sub:child",
    cells:,
    limit: 8,
  )
  assert lineage.is_descendant(
    of: "main",
    strand: "sub:grandchild",
    cells:,
    limit: 8,
  )
  // A strand with no cell is a root and is nobody's descendant. "No
  // lineage fact" must never read as "unknown, allow".
  assert !lineage.is_descendant(
    of: "main",
    strand: "operator-strand",
    cells:,
    limit: 8,
  )
  // Nobody is their own descendant, and a walk that runs out of hops
  // answers no rather than hanging.
  assert !lineage.is_descendant(of: "main", strand: "main", cells:, limit: 8)
  assert !lineage.is_descendant(
    of: "main",
    strand: "sub:grandchild",
    cells:,
    limit: 1,
  )
}

// --- the second factory ----------------------------------------------------

pub fn a_subagent_factory_death_leaves_the_primary_strand_alone_test() {
  // This is the containment the split exists for: with one factory, a
  // model-spawned strand's crash loop spends the factory's tolerance,
  // the factory dies, and rest-for-one reboots every driver in the
  // session — including the one a human is talking to.
  let runtime = open_runtime(fn(name) { name != "main" })
  let assert Ok(_operation) =
    api.create_strand(
      runtime,
      named: "sub:worker",
      configuration: configuration(),
      at: None,
      brief: [
        message.UserMessage(
          content: [message.UserText(text: "work", text_signature: None)],
          timestamp: 1_000_000,
        ),
      ],
    )
    as "the subagent strand must be created"
  let assert Ok(main_before) = strand_pid(runtime, "main")
  let assert Ok(worker_before) = strand_pid(runtime, "sub:worker")
  // The two live under different factories.
  assert main_before != worker_before
  let assert Ok(factory) =
    supervisor.factory_pid(runtime.tree, runtime.tree.subagent_strands)
  process.kill(factory)
  // The subagent's own driver goes down with its factory and the booter
  // brings it back. Waited on rather than slept through, so the test
  // pins the outcome and not the schedule.
  assert until(
    fn() {
      case strand_pid(runtime, "sub:worker") {
        Ok(pid) -> pid != worker_before
        Error(Nil) -> False
      }
    },
    400,
  )
  // The primary strand's driver is the same process it was, throughout:
  // the subagent factory sits after it in the rest-for-one order, so its
  // death restarts only itself and the booter.
  assert strand_pid(runtime, "main") == Ok(main_before)
  // And the subagent is running again, under a new driver.
  let assert Ok(worker_after) = strand_pid(runtime, "sub:worker")
  assert worker_after != worker_before
  let _closed = api.close(runtime)
  Nil
}

pub fn the_default_routes_everything_to_the_primary_factory_test() {
  // The runtime cannot tell a model-spawned strand from an operator one;
  // absent a host predicate it must behave exactly as it did before the
  // split.
  let runtime = open_runtime(fn(_) { False })
  let assert Ok(_operation) =
    api.create_strand(
      runtime,
      named: "sub:worker",
      configuration: configuration(),
      at: None,
      brief: [
        message.UserMessage(
          content: [message.UserText(text: "work", text_signature: None)],
          timestamp: 1_000_000,
        ),
      ],
    )
    as "the strand must be created"
  let assert Ok(_pid) = strand_pid(runtime, "sub:worker")
  let assert Ok(factory) =
    supervisor.factory_pid(runtime.tree, runtime.tree.subagent_strands)
  // The second factory exists and is empty; killing it disturbs no
  // strand's driver.
  let assert Ok(before) = strand_pid(runtime, "sub:worker")
  process.kill(factory)
  assert !until(
    fn() {
      case strand_pid(runtime, "sub:worker") {
        Ok(pid) -> pid != before
        Error(Nil) -> True
      }
    },
    40,
  )
  let _closed = api.close(runtime)
  Nil
}

fn strand_pid(
  runtime: api.Runtime,
  strand: String,
) -> Result(process.Pid, Nil) {
  case supervisor.strand_subject(runtime.tree, strand) {
    Error(Nil) -> Error(Nil)
    Ok(subject) ->
      case process.subject_owner(subject) {
        Ok(pid) ->
          case process.is_alive(pid) {
            True -> Ok(pid)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
  }
}

// Waits for the supervisor to do whatever it is going to do, bounded.
// Answers whether the predicate ever held.
fn until(predicate: fn() -> Bool, attempts: Int) -> Bool {
  case predicate() {
    True -> True
    False ->
      case attempts <= 0 {
        True -> False
        False -> {
          process.sleep(5)
          until(predicate, attempts - 1)
        }
      }
  }
}

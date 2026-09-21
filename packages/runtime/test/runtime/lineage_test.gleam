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
import runtime/async_execution
import runtime/child_run
import runtime/effects
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
        idle_poll_interval_ms: 25,
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
    default_within_ms: Some(600_000),
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
  // Models cannot reset a child's deadline or forge its cancellation cause.
  let assert Error(api.ReservedFactKey(..)) =
    api.put_fact(runtime, child_run.key(an_op(99)), json.Null)

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
          origin: None,
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
          origin: None,
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

pub fn legacy_lineage_defaults_to_ten_minutes_but_preserves_unbounded_test() {
  let cell = a_cell("sub:1", "main")
  let assert json.Object(fields) = lineage.encode(cell)
    as "the lineage encoding is an object"
  let legacy =
    json.Object(list.filter(fields, fn(field) { field.0 != "defaultWithinMs" }))
  assert lineage.decode(legacy) == Ok(cell)
  let unbounded = lineage.Lineage(..cell, default_within_ms: None)
  assert lineage.decode(lineage.encode(unbounded)) == Ok(unbounded)
  let json.Object(old_fields) = legacy
  list.each([json.Int(0), json.Int(-1), json.String("later")], fn(budget) {
    let assert Error(_) =
      lineage.decode(json.Object([#("defaultWithinMs", budget), ..old_fields]))
      as "invalid budgets must never become unbounded"
  })
}

pub fn child_run_records_round_trip_and_reject_missing_custody_test() {
  let original =
    child_run.Run(
      strand: "sub:1",
      owner: Some(child_run.ParentRun(an_op(30))),
      deadline: Some(50_000),
      stop: child_run.Unstopped,
    )
  list.each(
    [
      child_run.Unstopped, child_run.BudgetExpired, child_run.ParentFinished,
      child_run.LegacyReaped,
    ],
    fn(stop) {
      let run = child_run.Run(..original, stop:)
      assert child_run.decode(child_run.encode(run)) == Ok(run)
    },
  )
  let detached = child_run.Run(..original, owner: None, deadline: None)
  assert child_run.decode(child_run.encode(detached)) == Ok(detached)
  let assert json.Object(fields) = child_run.encode(original)
    as "the run encoding is an object"
  list.each(fields, fn(field) {
    let missing =
      json.Object(list.filter(fields, fn(pair) { pair.0 != field.0 }))
    let assert Error(_) = child_run.decode(missing)
      as "missing metadata is corruption, not an unbounded or detached run"
    let malformed =
      json.Object([
        #(field.0, json.Bool(False)),
        ..list.filter(fields, fn(pair) { pair.0 != field.0 })
      ])
    let assert Error(_) = child_run.decode(malformed)
      as "malformed lifecycle metadata must be rejected"
  })
}

pub fn child_admission_cannot_acquire_a_parent_after_run_end_begins_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let entered = process.new_subject()
  let base =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_) { fake.Reply(fake.answer("done", 1)) },
      fn(_) { fake.ToolHang },
    )
  let eff =
    effects.Effects(
      ..base,
      hooks: effects.Hooks(..base.hooks, run_end: fn(operation) {
        let release = process.new_subject()
        process.send(entered, #(operation, release))
        let assert Ok(Nil) = process.receive(release, within: 5000)
          as "the test must release the parked completion hook"
        None
      }),
    )
  let assert Ok(runtime) =
    api.open(sess, eff, api.default_options(configuration()))
    as "the runtime must open"
  let assert Ok(Nil) =
    api.create_idle_strand(
      runtime,
      named: "sub:1",
      configuration: configuration(),
      at: None,
    )
    as "the child must be idle before the parent finishes"
  let assert Ok(parent) = api.prompt(runtime, [fake.user("finish")])
    as "the parent must start"
  let assert Ok(#(ending, release)) = process.receive(entered, within: 5000)
    as "the parent must reach its completion hook"
  assert ending == parent
  let cell = a_cell("sub:1", "main")
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      lineage.register_key("sub:1"),
      lineage.encode(cell),
    )
    as "the child lineage must be published"

  // StrandState still names the parent here, but its cleanup boundary has
  // begun. Refusing a stale sender must not publish any child lifecycle.
  let assert Error(api.ReadFailed(_)) =
    api.send_to_child(
      runtime,
      "sub:1",
      fake.user("late parent work"),
      parent,
      None,
    )
    as "a finishing parent must not admit another owned run"
  assert api.reserved_facts(runtime, child_run.key_prefix) == Ok([])
  let assert Ok(operation) =
    api.accept_quietly(api.on_strand(runtime, "sub:1"), [
      fake.user("operator continuation"),
    ])
    as "the operator may admit work without inheriting finished custody"
  let assert Ok(Some(value)) = api.fact(runtime, child_run.key(operation))
    as "admission must publish the run metadata atomically"
  let assert Ok(run) = child_run.decode(value) as "the run metadata must decode"
  assert run.owner == None
  assert run.deadline != None
  process.send(release, Nil)
  process.kill(runtime.tree.supervisor)
}

pub fn corrupt_lineage_refuses_agent_admission_but_keeps_host_recovery_test() {
  let runtime = open_runtime(fn(_) { False })
  let assert Ok(Nil) =
    api.create_idle_strand(
      runtime,
      named: "sub:1",
      configuration: configuration(),
      at: None,
    )
    as "the child strand must exist"
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      lineage.register_key("sub:1"),
      json.String("corrupt"),
    )
    as "the test must corrupt the lineage ledger"
  let assert Error(api.ReadFailed(_)) =
    api.send_to_child(
      runtime,
      "sub:1",
      fake.user("agent continuation"),
      an_op(70),
      Some(600_000),
    )
    as "an agent must not admit work through corrupt lineage"
  assert api.reserved_facts(runtime, child_run.key_prefix) == Ok([])

  // The host can still operate the conversation for recovery. That does not
  // make the broken lineage trustworthy enough to mint lifecycle metadata.
  let assert Ok(operation) =
    api.prompt(api.on_strand(runtime, "sub:1"), [fake.user("operator recovery")])
    as "direct host prompting must remain usable"
  assert api.fact(runtime, child_run.key(operation)) == Ok(None)
  assert api.fact(runtime, lineage.register_key("sub:1"))
    == Ok(Some(json.String("corrupt")))
  let _closed = api.close(runtime)
  Nil
}

// A satellite outlives its initiating turn. Its first child has no lineage
// yet, so ownership must be part of acceptance itself, not a later repair.
pub fn async_child_custody_precedes_lineage_and_fences_steering_test() {
  let runtime = open_runtime(fn(_) { False })
  let execution =
    async_execution.Execution(
      id: "abc",
      strand: "main",
      operation: an_op(91),
      step: "async/abc",
      deadline_ms: 9_000_000,
      source: "program",
      seam: "orchestration",
      phase: async_execution.Running,
    )
  let assert Ok(_) =
    api.put_reserved_fact_expecting(
      runtime,
      async_execution.key(execution.id),
      async_execution.encode(execution),
      None,
    )
    as "the live execution must be durable"
  let assert Ok(_) =
    api.create_idle_strand(runtime, "sub:async", configuration(), None)
    as "the child must be seeded idle"
  let custody =
    api.AsyncCustody("main", execution.operation, execution.id, api.Owned)
  let prompt =
    message.UserMessage(
      content: [message.UserText("work", None)],
      timestamp: 1_000_000,
      origin: None,
    )
  let assert Ok(api.Started(operation)) =
    api.send_to_async_child(
      runtime,
      "sub:async",
      prompt,
      custody,
      Some(999_999_999),
    )
    as "async custody must admit without a live parent operation or lineage"
  let assert Ok(Some(payload)) = api.fact(runtime, child_run.key(operation))
    as "admission must persist custody"
  let assert Ok(run) = child_run.decode(payload)
    as "the child record must decode"
  assert run.owner == Some(child_run.AsyncExecution(execution.operation, "abc"))
  assert run.deadline == Some(execution.deadline_ms)
  let assert Ok(api.Steered(_)) =
    api.send_to_async_child(runtime, "sub:async", prompt, custody, None)
    as "a live execution may steer"

  let assert Ok(Some(cell)) = api.fact_cell(runtime, async_execution.key("abc"))
    as "the fence sequence must exist"
  let closed =
    async_execution.Execution(..execution, phase: async_execution.Draining)
  let assert Ok(_) =
    api.put_reserved_fact_expecting(
      runtime,
      async_execution.key("abc"),
      async_execution.encode(closed),
      Some(cell.seq),
    )
    as "closing custody must commit"
  let assert Error(api.ReadFailed(_)) =
    api.send_to_async_child(runtime, "sub:async", prompt, custody, None)
    as "closed custody must refuse busy steering"
  let assert Ok(_) =
    api.create_idle_strand(runtime, "sub:late", configuration(), None)
    as "another child must be seeded idle"
  let assert Error(api.ReadFailed(_)) =
    api.send_to_async_child(runtime, "sub:late", prompt, custody, Some(1000))
    as "closed custody must refuse new runs"
  let _closed = api.close(runtime)
}

pub fn async_execution_codec_rejects_cross_execution_steps_test() {
  let record =
    async_execution.Execution(
      "abc",
      "main",
      an_op(92),
      "async/abc",
      1_000_000,
      "program",
      "workspace",
      async_execution.Running,
    )
  assert async_execution.decode(async_execution.encode(record)) == Ok(record)
  let forged = async_execution.Execution(..record, step: "async/def")
  let assert Error(_) = async_execution.decode(async_execution.encode(forged))
    as "a stored handle must never address another broker step"
  assert !async_execution.admits(record, record.deadline_ms)
  assert !async_execution.valid_id("../abc")
}

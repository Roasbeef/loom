//// ORCH-M2, runtime half: under `settings.tool_execution: Parallel`
//// the driver genuinely overlaps tool effects. Each scripted tool blocks
//// until the *other* tool's execution has started — a batch that
//// deadlocks under sequential dispatch by construction — and the run
//// completes only because both effects run concurrently. One test runs
//// the same batch under `api.default_options` with nothing overridden,
//// which is what pins `Parallel` as the *shipped* default rather than
//// merely a reachable one.

import core/clock
import gleam/erlang/process
import machine/operation.{
  CompactionSettings, ConsumeAll, Parallel, ReplaySafe, RunSettings,
}
import runtime/api
import runtime/effects
import runtime/supervisor
import session/session
import support/fake
import support/harness
import support/recorder

pub fn parallel_batch_overlaps_tool_effects_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("read", ReplaySafe), #("probe", ReplaySafe)],
      fn(spec) {
        case fake.turn(spec) {
          0 ->
            fake.Reply(fake.tool_use(
              "fanning out",
              [#("c1", "read"), #("c2", "probe")],
              4,
            ))
          _ -> fake.Reply(fake.answer("both done", 5))
        }
      },
      fn(tool_run) {
        // Block until the sibling call has started: only concurrent
        // dispatch can satisfy both.
        let sibling = case tool_run.call.name {
          "read" -> "tool:probe:c2"
          _ -> "tool:read:c1"
        }
        wait_for(fn() { recorder.read(rec, sibling) >= 1 }, 5000)
        fake.ToolReply(
          text: "out:" <> tool_run.call.name,
          is_error: False,
          terminate: False,
        )
      },
    )
  let base = api.default_options(harness.configuration())
  let options =
    api.Options(
      ..base,
      settings: RunSettings(
        compaction: CompactionSettings(
          enabled: False,
          reserve_tokens: 0,
          keep_recent_tokens: 0,
        ),
        steering_mode: ConsumeAll,
        follow_up_mode: ConsumeAll,
        tool_execution: Parallel,
      ),
      poll_interval_ms: 50,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(op) = api.prompt(rt, [fake.user("fan out")])
    as "the prompt must be accepted"
  let assert Ok(last) = api.await_result(rt, op, within_ms: 15_000)
    as "the parallel batch must complete"
  harness.assert_completed(last)
  // Tree materialization stayed source-ordered regardless of settle
  // order.
  assert harness.final_projection(sess)
    == [
      "user:fan out",
      "assistant:tool_use:fanning out|call(c1)read|call(c2)probe",
      "tool:read:c1:ok:out:read", "tool:probe:c2:ok:out:probe",
      "assistant:stop:both done",
    ]
  harness.assert_placement_invariants(sess)
  process.kill(rt.tree.supervisor)
}

pub fn exclusive_tool_serializes_a_parallel_batch_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base_effects =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("read", ReplaySafe), #("bash", ReplaySafe), #("probe", ReplaySafe)],
      fn(spec) {
        case fake.turn(spec) {
          0 ->
            fake.Reply(fake.tool_use(
              "mixed batch",
              [#("c1", "read"), #("c2", "bash"), #("c3", "probe")],
              4,
            ))
          _ -> fake.Reply(fake.answer("all done", 5))
        }
      },
      fn(tool_run) {
        // An overlap detector: more calls entered than left means two
        // executions ran at once.
        let entered = recorder.bump(rec, "entered")
        let left = recorder.read(rec, "left")
        case entered - left > 1 {
          True -> {
            let _overlaps = recorder.bump(rec, "overlap")
            Nil
          }
          False -> Nil
        }
        process.sleep(20)
        let _left = recorder.bump(rec, "left")
        fake.ToolReply(
          text: "out:" <> tool_run.call.name,
          is_error: False,
          terminate: False,
        )
      },
    )
  // `bash` is exclusive; the others may overlap.
  let eff =
    effects.Effects(
      ..base_effects,
      tools: effects.ToolSurface(..base_effects.tools, execution_mode: fn(name) {
        case name {
          "bash" -> effects.ExclusiveExecution
          _ -> effects.ConcurrentExecution
        }
      }),
    )
  let base = api.default_options(harness.configuration())
  let options =
    api.Options(
      ..base,
      settings: RunSettings(
        compaction: CompactionSettings(
          enabled: False,
          reserve_tokens: 0,
          keep_recent_tokens: 0,
        ),
        steering_mode: ConsumeAll,
        follow_up_mode: ConsumeAll,
        tool_execution: Parallel,
      ),
      poll_interval_ms: 50,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(op) = api.prompt(rt, [fake.user("mixed")])
    as "the prompt must be accepted"
  let assert Ok(last) = api.await_result(rt, op, within_ms: 15_000)
    as "the mixed batch must complete"
  harness.assert_completed(last)
  // The exclusive call fenced the batch: nothing ever overlapped, and
  // every call still ran exactly once, materialized in source order.
  assert recorder.read(rec, "overlap") == 0
  assert recorder.read(rec, "entered") == 3
  assert harness.final_projection(sess)
    == [
      "user:mixed",
      "assistant:tool_use:mixed batch|call(c1)read|call(c2)bash|call(c3)probe",
      "tool:read:c1:ok:out:read", "tool:bash:c2:ok:out:bash",
      "tool:probe:c3:ok:out:probe", "assistant:stop:all done",
    ]
  harness.assert_placement_invariants(sess)
  process.kill(rt.tree.supervisor)
}

/// The same deadlocks-under-sequential-dispatch batch, run under
/// `api.default_options` with nothing overridden. It completes, which is
/// the only way the shipped default can be `Parallel` — an assertion
/// about the setting's *value* would pass just as well if nothing read
/// it, and this batch cannot finish unless something does.
pub fn the_shipped_default_overlaps_tool_effects_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("read", ReplaySafe), #("probe", ReplaySafe)],
      fn(spec) {
        case fake.turn(spec) {
          0 ->
            fake.Reply(fake.tool_use(
              "fanning out",
              [#("c1", "read"), #("c2", "probe")],
              4,
            ))
          _ -> fake.Reply(fake.answer("both done", 5))
        }
      },
      fn(tool_run) {
        let sibling = case tool_run.call.name {
          "read" -> "tool:probe:c2"
          _ -> "tool:read:c1"
        }
        wait_for(fn() { recorder.read(rec, sibling) >= 1 }, 5000)
        fake.ToolReply(
          text: "out:" <> tool_run.call.name,
          is_error: False,
          terminate: False,
        )
      },
    )
  let base = api.default_options(harness.configuration())
  // Everything but `settings`: the defaults are what is under test.
  let options =
    api.Options(
      ..base,
      poll_interval_ms: 50,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(op) = api.prompt(rt, [fake.user("fan out")])
    as "the prompt must be accepted"
  let assert Ok(last) = api.await_result(rt, op, within_ms: 15_000)
    as "the default batch must complete, which only parallel dispatch allows"
  harness.assert_completed(last)
  assert harness.final_projection(sess)
    == [
      "user:fan out",
      "assistant:tool_use:fanning out|call(c1)read|call(c2)probe",
      "tool:read:c1:ok:out:read", "tool:probe:c2:ok:out:probe",
      "assistant:stop:both done",
    ]
  harness.assert_placement_invariants(sess)
  process.kill(rt.tree.supervisor)
}

fn wait_for(condition: fn() -> Bool, remaining: Int) -> Nil {
  case condition() {
    True -> Nil
    False ->
      case remaining <= 0 {
        True -> panic as "timed out waiting for the sibling tool to start"
        False -> {
          process.sleep(10)
          wait_for(condition, remaining - 10)
        }
      }
  }
}

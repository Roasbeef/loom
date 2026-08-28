//// The interleave harness's scenario library: each scenario runs once
//// uninterrupted to fix its commit-boundary count `C`, then once per
//// `k in 1..C` with the tree killed right after commit `k`, rebooted by
//// its supervisor, and driven to completion against the same scripted
//// effect outcomes.
////
//// Convergence assertions, per scenario:
////
//// - terminal outcome kind matches;
//// - the final *projected* context matches the uninterrupted run's
////   (synthetic errored/aborted settlements never enter the projection,
////   which is exactly why they may exist without diverging it);
//// - the ledger's token total matches where crash semantics require it
////   (synthetic settlements are zero-usage and a settled commit is never
////   re-billed) — the abort scenario is exempt, since an early abort
////   legitimately skips whole turns;
//// - no `replay: Never` tool ran twice (the fake runner counts
////   invocations in a recorder that outlives the tree);
//// - the placement invariant holds at the terminal boundary (asserted
////   inside every run).
////
//// Documented legitimate divergences: a `Never` tool call whose intent
//// was the kill boundary yields the synthetic interrupted result instead
//// of the scripted one (`converged_with_tool_allowance`), and the abort
//// scenario's transcript depends on how far the run got before the
//// durable marker landed — only its outcome and invariants are asserted.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation.{ReplayNever, ReplaySafe}
import runtime/effects
import support/fake
import support/harness.{type Scenario, Scenario}
import support/recorder

fn no_tools(
  _rec: Subject(recorder.Message),
  _run: effects.ToolRun,
) -> fake.ToolResult {
  fake.ToolReply(text: "unused", is_error: False, terminate: False)
}

// --- scenario 1: prompt → assistant → finish ------------------------------

fn simple_scenario() -> Scenario {
  Scenario(
    name: "simple",
    registry: [],
    provider: fn(_rec, spec) {
      case fake.turn(spec) {
        0 -> fake.Reply(fake.answer("The answer", 10))
        _ -> fake.Reply(fake.answer("unexpected turn", 1))
      }
    },
    tool: no_tools,
    prompt: [fake.user("Hello")],
    steer: None,
    abort_when: None,
  )
}

pub fn simple_interleave_test() {
  let base =
    harness.interleave(simple_scenario(), fn(base, crashed, k) {
      harness.assert_completed(crashed.outcome)
      expect_same_projection(base, crashed, k)
      expect_same_ledger(base, crashed, k)
    })
  assert base.projection == ["user:Hello", "assistant:stop:The answer"]
  assert base.usage_total == 10
  // The scenario's crash-boundary count is deterministic: acceptance is
  // pre-armed, then run-start checkpoint, generation ready, request
  // intent, settlement, and the terminal transaction.
  assert base.commits == 5
}

// --- scenario 2: prompt → assistant → two tools → assistant → finish ------

fn tools_scenario() -> Scenario {
  Scenario(
    name: "tools",
    registry: [#("read", ReplaySafe), #("write", ReplayNever)],
    provider: fn(_rec, spec) {
      case fake.turn(spec) {
        0 ->
          fake.Reply(fake.tool_use(
            "running tools",
            [#("c1", "read"), #("c2", "write")],
            7,
          ))
        _ -> fake.Reply(fake.answer("Done", 5))
      }
    },
    tool: fn(_rec, tool_run) {
      fake.ToolReply(
        text: "out:" <> tool_run.call.name,
        is_error: False,
        terminate: False,
      )
    },
    prompt: [fake.user("Run the tools")],
    steer: None,
    abort_when: None,
  )
}

pub fn tools_interleave_test() {
  let base =
    harness.interleave(tools_scenario(), fn(base, crashed, k) {
      harness.assert_completed(crashed.outcome)
      case
        harness.converged_with_tool_allowance(
          base.projection,
          crashed.projection,
        )
      {
        True -> Nil
        False ->
          panic as { "projection diverged in " <> harness.context("tools", k) }
      }
      expect_same_ledger(base, crashed, k)
      // The Never tool must not run twice; the Safe tool may replay.
      assert recorder.read(crashed.rec, "tool:write:c2") <= 1
    })
  assert base.usage_total == 12
  assert base.projection
    == [
      "user:Run the tools",
      "assistant:tool_use:running tools|call(c1)read|call(c2)write",
      "tool:read:c1:ok:out:read",
      "tool:write:c2:ok:out:write",
      "assistant:stop:Done",
    ]
  // Uninterrupted, each tool ran exactly once.
  assert recorder.read(base.rec, "tool:read:c1") == 1
  assert recorder.read(base.rec, "tool:write:c2") == 1
  // Deterministic boundary count: checkpoint, ready, intent, settle,
  // then per call (intent, stage, materialize) twice, then the final
  // turn's ready/intent/settle and the terminal transaction.
  assert base.commits == 14
}

// --- scenario 3: steer admitted onto the open run -------------------------

fn steer_scenario() -> Scenario {
  Scenario(
    name: "steer",
    registry: [],
    provider: fn(_rec, spec) {
      case fake.turn(spec) {
        0 -> fake.Reply(fake.answer("Steered answer", 9))
        _ -> fake.Reply(fake.answer("unexpected turn", 1))
      }
    },
    tool: no_tools,
    prompt: [fake.user("Hello")],
    steer: Some(fake.user("Also do this")),
    abort_when: None,
  )
}

pub fn steer_interleave_test() {
  let base =
    harness.interleave(steer_scenario(), fn(base, crashed, k) {
      harness.assert_completed(crashed.outcome)
      expect_same_projection(base, crashed, k)
      expect_same_ledger(base, crashed, k)
    })
  // The checkpoint drained the steer before generating: it is in context.
  assert base.projection
    == ["user:Hello", "user:Also do this", "assistant:stop:Steered answer"]
  // Deterministic boundary count: the steer drain adds one commit to
  // the simple scenario's five.
  assert base.commits == 6
}

// --- scenario 4: abort while a Never tool is mid-flight -------------------

fn abort_scenario() -> Scenario {
  Scenario(
    name: "abort",
    registry: [#("slow", ReplayNever)],
    provider: fn(_rec, spec) {
      case fake.turn(spec) {
        0 -> fake.Reply(fake.tool_use("working", [#("c1", "slow")], 4))
        // Any later turn blocks: the run can only end by abort.
        _ -> fake.Hang
      }
    },
    tool: fn(_rec, _run) { fake.ToolHang },
    prompt: [fake.user("Delete everything")],
    steer: None,
    abort_when: Some(fn(rec) {
      // Abort once the tool is in flight — or, in reboots where the
      // interrupted tool was already reconciled, once the run is parked
      // on the (blocking) next generation.
      recorder.read(rec, "tool:slow:c1") >= 1
      || recorder.read(rec, "provider") >= 2
    }),
  )
}

pub fn abort_interleave_test() {
  let base =
    harness.interleave(abort_scenario(), fn(_base, crashed, _k) {
      harness.assert_aborted(crashed.outcome)
      // pi §0.5: nothing ran twice.
      assert recorder.read(crashed.rec, "tool:slow:c1") <= 1
    })
  harness.assert_aborted(base.outcome)
  assert recorder.read(base.rec, "tool:slow:c1") == 1
  // The uninterrupted abort interrupts the mid-flight Never call: its
  // synthetic result is in the tree and carries the explicit warning.
  assert list.any(base.projection, fn(line) {
    string.starts_with(line, "tool:slow:c1:err:")
  })
  // Deterministic boundary count: through the tool intent, then the
  // abort marker, interrupted staging, materialization, and the aborted
  // terminal transaction.
  assert base.commits == 9
}

// --- scenario 5: retryable provider failure → retry wait → success --------

fn retry_scenario() -> Scenario {
  Scenario(
    name: "retry",
    registry: [],
    provider: fn(_rec, spec) {
      case fake.turn(spec), fake.attempt(spec) {
        0, 1 -> fake.Refuse(fake.retryable_error())
        0, _ -> fake.Reply(fake.answer("Recovered", 8))
        _, _ -> fake.Reply(fake.answer("unexpected turn", 1))
      }
    },
    tool: no_tools,
    prompt: [fake.user("Try hard")],
    steer: None,
    abort_when: None,
  )
}

pub fn retry_interleave_test() {
  let base =
    harness.interleave(retry_scenario(), fn(base, crashed, k) {
      harness.assert_completed(crashed.outcome)
      // The failed attempt settles as an errored response, which the
      // projection drops — crashed and uninterrupted projections match
      // exactly even though their attempt counts may differ.
      expect_same_projection(base, crashed, k)
      expect_same_ledger(base, crashed, k)
    })
  assert base.projection == ["user:Try hard", "assistant:stop:Recovered"]
  // The failed attempt billed zero; only the success is in the ledger.
  assert base.usage_total == 8
  // Deterministic boundary count: the failed attempt settles into
  // retry_wait, the wait elapses into ready, and the second attempt
  // completes the run.
  assert base.commits == 8
}

// --- shared assertions ----------------------------------------------------

fn expect_same_projection(
  base: harness.Report,
  crashed: harness.Report,
  k: Int,
) -> Nil {
  case crashed.projection == base.projection {
    True -> Nil
    False ->
      panic as { "projection diverged in " <> harness.context("scenario", k) }
  }
}

fn expect_same_ledger(
  base: harness.Report,
  crashed: harness.Report,
  k: Int,
) -> Nil {
  case crashed.usage_total == base.usage_total {
    True -> Nil
    False ->
      panic as { "ledger diverged in " <> harness.context("scenario", k) }
  }
}

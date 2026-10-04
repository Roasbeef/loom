//// Dependency preparation before a language-server lease becomes usable.
////
//// An approved recipe grants networking to one finite broker call. The
//// recipe reuses the server's filesystem view and private cache, but never
//// changes the offline lease's policy. A failed download cannot produce a
//// server that reports empty answers against an incomplete project.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import codemode/lsp_host/jail
import core/ids.{type OpId}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/result
import gleam/string
import tools/tool.{type RunningCall}

/// The wall and CPU bound on the explicitly approved setup recipe.
pub const timeout_ms = 60_000

/// Runs the fixed Gleam dependency recipe through the broker.
///
/// The caller has proven the offline jail's enforcement. Only this call
/// receives network authority; filesystem and environment stay the approved
/// profile's. Broker settlement owns release. A receive timeout cancels it.
///
/// ## Examples
///
/// ```gleam
/// // preparation.run(built, run, op, exec.BestEffort, now_ms: 0)
/// // -> Ok(Nil), before the offline server starts.
/// ```
pub fn run(
  built: jail.Jail,
  run: fn(broker.CallSpec, Subject(broker.CallEvent)) ->
    Result(RunningCall, broker.Refusal),
  op: OpId,
  demand: exec.EnforcementDemand,
  now_ms now: Int,
) -> Result(Nil, String) {
  use spec <- result.try(call_spec(built, op, demand, now_ms: now))
  let events = process.new_subject()
  use running <- result.try(
    run(spec, events) |> result.map_error(jail.refusal_text),
  )
  running.stdin(<<>>, True)

  // The native wall deadline is independent of output activity. The
  // collector's grace lets the broker deliver its terminal report.
  use collected <- result.try(
    tool.collect_events(events, waiting: timeout_ms + 2000)
    |> result.map_error(fn(_nil) {
      running.cancel()
      "dependency preparation did not settle within 62 seconds; it was cancelled"
    }),
  )
  settled(collected)
}

/// Constructs setup authority without mutating the offline server policy.
///
/// The profile decoder admits only a fixed recipe for a Gleam `lsp`
/// command with a writable project and private cache. Its executable is
/// the already resolved and vetted server executable.
///
/// ## Examples
///
/// ```gleam
/// // preparation.call_spec(built, op, exec.BestEffort, now_ms: 0)
/// // -> Ok(spec), with full network and a 60-second deadline.
/// ```
pub fn call_spec(
  built: jail.Jail,
  op: OpId,
  demand: exec.EnforcementDemand,
  now_ms now: Int,
) -> Result(broker.CallSpec, String) {
  use executable <- result.try(case built.argv {
    [executable, "lsp"] -> Ok(executable)
    _ -> Error("dependency preparation requires the approved Gleam lsp command")
  })
  let base = policy.SandboxPolicy(..built.base, network: policy.NetworkFull)
  let requirements =
    policy.SandboxPolicy(
      ..built.requirements,
      network: policy.NetworkFull,
      limits: policy.Limits(
        ..built.requirements.limits,
        wall_s: timeout_ms / 1000,
        cpu_s: timeout_ms / 1000,
        output_bytes: 1_048_576,
      ),
    )

  // The extra authority comes from approval of the named recipe, never
  // from a session-wide grant or from the server's later requests.
  Ok(
    broker.CallSpec(
      ..jail.call_spec(built, op, now_ms: now, demand:),
      step_id: built.step_id <> "/prepare",
      base_policy: base,
      requirements:,
      argv: [executable, "deps", "download"],
      budget: budget.Budget(max_outstanding: 1, deadline_ms: now + timeout_ms),
    ),
  )
}

// A nonzero exit preserves the command's explanation. The receive buffers
// and rendered tail are bounded separately, so a registry error stays
// useful without turning a failed query into a build log.
fn settled(collected: tool.Collected) -> Result(Nil, String) {
  case collected.outcome {
    broker.CallExited(result:) if result.code == 0 -> Ok(Nil)
    broker.CallExited(result:) ->
      Error(
        "gleam deps download exited with code "
        <> int.to_string(result.code)
        <> ": "
        <> output(collected),
      )
    broker.CallFailed(failure:) ->
      Error("gleam deps download failed: " <> tool.exec_failure_text(failure))
  }
}

fn output(collected: tool.Collected) -> String {
  let stderr = result.unwrap(bit_array.to_string(collected.stderr), "")
  let stdout = result.unwrap(bit_array.to_string(collected.stdout), "")
  let combined = string.trim(stderr <> "\n" <> stdout)
  string.slice(
    combined,
    at_index: int.max(0, string.length(combined) - 4000),
    length: 4000,
  )
}

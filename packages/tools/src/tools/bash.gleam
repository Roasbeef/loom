//// The `bash` tool: a shell command through the broker's jailed
//// executor.
////
//// Each call builds a `CallSpec` — `["bash", "-lc", command]` in the
//// workspace, the caller's allowlist-constructed environment, and
//// policy-shaped requirements of workspace write, system paths
//// readable, and whatever network the session base allows (**off**
//// unless an operator's `[tools]` table opened it) — and clears it
//// through the broker seam
//// with `RefuseNarrowed`: if the session base does not cover the
//// requirements, the call settles in-band as a structured policy
//// refusal carrying the exact wanted grants, ready for the escalation
//// flow. Streamed output is collected (respecting the helper's
//// truncation flags), and the settlement becomes a tool result with
//// exit code, stdout, and stderr; output beyond the spec §3.2
//// threshold overflows to the blob store.
////
//// `replay: Never` — a shell command is an arbitrary external effect;
//// a crash mid-execution must yield a synthetic interrupted result
//// (the pi §0.5 scenario), never a re-execution. `execution_mode` is
//// `Exclusive`: the command may mutate the workspace.

import broker/broker
import broker/budget
import broker/exec.{type ExecResult}
import broker/policy
import core/clock
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import tools/blob
import tools/tool.{type Ctx, type ToolOutcome}

/// Wall-clock timeout applied when the arguments give none.
pub const default_timeout_ms = 120_000

/// The policy ceiling on the per-call timeout argument; larger requests
/// are clamped down to it.
pub const max_timeout_ms = 600_000

/// Slack added to the receive window beyond the execution deadline: the
/// broker's own relay grace plus the helper's cancel ladder, so the
/// tool always outwaits a broker that is still settling honestly.
const settle_grace_ms = 10_000

/// The `bash` tool.
pub fn tool() -> tool.Tool {
  tool.Tool(
    name: "bash",
    description: "Run a shell command in the sandboxed workspace. The "
      <> "command runs as `bash -lc` with the workspace as the working "
      <> "directory and no network access.",
    prompt_snippet: option.Some(
      "`bash` runs a shell command in the workspace, jailed and offline.",
    ),
    schema: tool.object_schema(
      [
        #("command", tool.string_property("the shell command to run")),
        #(
          "timeout_ms",
          tool.integer_property(
            "wall-clock timeout in milliseconds (default "
            <> int.to_string(default_timeout_ms)
            <> ", ceiling "
            <> int.to_string(max_timeout_ms)
            <> ")",
          ),
        ),
      ],
      ["command"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements:,
    run:,
  )
}

/// The bash tool's policy-shaped needs: workspace writable, the whole
/// filesystem readable (interpreters and system libraries live outside
/// the workspace), network off, tmpfs scratch. The environment
/// allowlist is added per call from the context's env, and so is the
/// network — `call_spec` takes the session base's through
/// `tool.asking_base_network`, so the `NetworkOff` stated here is the
/// posture of a host that configured none rather than a ceiling this
/// tool imposes.
pub fn requirements(workspace: String) -> policy.SandboxPolicy {
  let base = policy.workspace_default(workspace)
  policy.SandboxPolicy(..base, readable_roots: ["/"], env_allow: [])
}

fn run(ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use command <- tool.with_arg(tool.required_string(args, "command"))
  use timeout <- tool.with_arg(tool.optional_int(args, "timeout_ms"))
  let timeout = option.unwrap(timeout, default_timeout_ms)
  use <- bool.guard(
    when: timeout < 1,
    return: tool.failure("invalid arguments: `timeout_ms` must be >= 1"),
  )
  let timeout = int.min(timeout, max_timeout_ms)
  let #(now, _clock) = clock.read(ctx.clock)
  let spec = call_spec(ctx, command, now, timeout)
  let events = process.new_subject()
  use call <- tool.or_outcome(
    ctx.clear_call(spec, events),
    tool.refusal_outcome,
  )

  // The child gets no interactive stdin; close it so pipelines reading
  // stdin terminate instead of hanging.
  call.stdin(<<>>, True)
  use collected <- tool.or_outcome(
    tool.collect_events(events, waiting: timeout + settle_grace_ms),
    fn(_nil) {
      call.cancel()
      tool.failure("the sandbox did not settle the command within its window")
    },
  )
  settle(ctx, collected)
}

// The CallSpec for one bash invocation. Requirements add the env names
// actually passed, so composition checks them against the session's
// allowlist; the wall limit mirrors the timeout.
fn call_spec(
  ctx: Ctx,
  command: String,
  now: Int,
  timeout: Int,
) -> broker.CallSpec {
  // Egress is the session's decision, not this tool's. `requirements`
  // states the offline default a host with no `[tools]` table serves;
  // asking for the base's own network is what lets an operator who
  // opened it reach a shell, and the meet keeps it closed otherwise.
  let base_requirements =
    tool.asking_base_network(requirements(ctx.workspace), ctx.base_policy)

  let wall_s = { timeout + 999 } / 1000

  // The shell asks for every root the session base already grants, not
  // the workspace alone. The meet intersects roots, so asking for the
  // workspace would hand the shell the workspace whatever the base
  // said — and the base says more for a linked git worktree, whose
  // metadata lives under the main repository's `.git`
  // (`client/serve.widening_linked_worktree`); without those roots a
  // `git commit` here dies on the index lock. Asking for the base's own
  // roots can never widen past the base: the intersection of a set with
  // itself is itself.
  let tool_requirements =
    policy.SandboxPolicy(
      ..base_requirements,
      writable_roots: list.unique(list.append(
        base_requirements.writable_roots,
        ctx.base_policy.writable_roots,
      )),
      env_allow: list.map(ctx.env, fn(pair) { pair.0 }),
      limits: policy.Limits(..base_requirements.limits, wall_s:),
    )
  broker.CallSpec(
    op_id: ctx.op_id,
    step_id: ctx.step_id,
    base_policy: ctx.base_policy,
    requirements: tool_requirements,
    grants: ctx.grants,
    response: broker.RefuseNarrowed,
    demand: ctx.demand,
    argv: ["bash", "-lc", command],
    env: ctx.env,
    cwd: ctx.workspace,
    budget: budget.Budget(max_outstanding: 1, deadline_ms: now + timeout),
  )
}

fn settle(ctx: Ctx, collected: tool.Collected) -> ToolOutcome {
  case collected.outcome {
    broker.CallFailed(failure:) -> tool.exec_failure_outcome(failure)
    broker.CallExited(result:) -> exited(ctx, collected, result)
  }
}

fn exited(
  ctx: Ctx,
  collected: tool.Collected,
  result: ExecResult,
) -> ToolOutcome {
  let stdout = output_text(collected.stdout)
  let stderr = output_text(collected.stderr)
  let body =
    [
      case stdout {
        "" -> []
        _ -> [stdout]
      },
      case collected.stdout_truncated {
        True -> ["[stdout truncated at the output cap]"]
        False -> []
      },
      case stderr {
        "" -> []
        _ -> ["--- stderr ---", stderr]
      },
      case collected.stderr_truncated {
        True -> ["[stderr truncated at the output cap]"]
        False -> []
      },
      case result.timed_out {
        True -> ["[command timed out]"]
        False -> []
      },
      case result.code, result.signal {
        0, 0 -> []
        code, 0 -> ["exit code " <> int.to_string(code)]
        _, signal -> ["killed by signal " <> int.to_string(signal)]
      },
    ]
    |> list.flatten
    |> string.join(with: "\n")
  let body = case body {
    "" -> "(no output)"
    _ -> body
  }
  let is_error = result.code != 0 || result.signal != 0 || result.timed_out
  let details =
    json.Object([
      #("exit_code", json.Int(result.code)),
      #("signal", json.Int(result.signal)),
      #("wall_ms", json.Int(result.wall_ms)),
      #("timed_out", json.Bool(result.timed_out)),
      #("stdout_bytes", json.Int(result.stdout_bytes)),
      #("stderr_bytes", json.Int(result.stderr_bytes)),
      #("stdout_truncated", json.Bool(collected.stdout_truncated)),
      #("stderr_truncated", json.Bool(collected.stderr_truncated)),
      #("degraded", json.Bool(result.degraded)),
      #("enforcement", json.Array(list.map(result.enforcement, json.String))),
    ])

  // Large bodies overflow to the blob store (spec §3.2); a blob-store
  // failure falls back to the inline body rather than losing the
  // result.
  case blob.bound(ctx, body) {
    Error(_error) ->
      tool.ToolOutcome(
        content: [tool.text_block(body)],
        details: option.Some(details),
        is_error:,
        terminate: tool.ContinueRun,
      )
    Ok(bounded) ->
      tool.ToolOutcome(
        content: [tool.text_block(blob.bounded_text(bounded))],
        details: option.Some(details),
        is_error:,
        terminate: tool.ContinueRun,
      )
      |> blob.with_blob_details(bounded)
  }
}

// Jailed output is expected to be UTF-8; anything else is summarized
// rather than corrupted into the transcript.
fn output_text(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) ->
      "["
      <> int.to_string(bit_array.byte_size(bytes))
      <> " bytes of non-UTF-8 output]"
  }
}

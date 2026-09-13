//// The `bash` tool: a shell command through the broker's jailed
//// executor.
////
//// Each call builds a `CallSpec` — `bash -o pipefail -c` in the
//// workspace, the caller's allowlist-constructed environment, and
//// policy-shaped requirements of workspace write, system paths
//// readable, and whatever network the session base allows — and clears it
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
////
//// ## The two modes
////
//// `mode` chooses between the foreground call above and a **background
//// job**: the same command, admitted under the same rules, but allowed
//// to outlive the tool call that started it. A background call clears
//// through `tools/job.Jobs` — the host's door — and returns a handle at
//// once rather than the command's output, and the model reads it
//// afterwards with `job_poll`, feeds it with `job_send` and stops it
//// with `job_kill`.
////
//// One flag on a tool the model already has, rather than a fourth tool
//// definition, because tool-surface cost is arithmetic: every permanent
//// definition renders into the provider's cached byte prefix and is paid
//// for on every request of every strand for the life of the session.
////
//// The two modes are otherwise deliberately not symmetric in one place.
//// The foreground clamp is this module's `max_timeout_ms`, ten minutes;
//// a job's default and clamp are the host's, an hour, raised by an
//// operator's `[jobs].max_wall`. So `timeout_ms` is passed to the door
//// **unclamped** and the door answers with the wall it granted — clamping
//// here as well would silently cap a job at the foreground ceiling and
//// no reader of either number could tell which had applied.

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
import gleam/option.{type Option, None, Some}
import gleam/string
import tools/blob
import tools/job.{type Jobs}
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

/// Whether a call blocks for its command or backgrounds it.
///
/// A two-variant type rather than the `detach: Bool` the shape would
/// otherwise take, for the no-naked-`Bool` reason: the polarity of a
/// flag named for one of two peers is exactly what a reader of a call
/// site should not have to carry.
pub type Mode {
  /// The call blocks until the command settles and answers with its
  /// output. What every `bash` call meant before this argument existed,
  /// and what an argument-less call still means.
  Foreground

  /// The call admits a background job and answers with its handle. The
  /// command keeps running after the tool call ends.
  Background
}

/// The `bash` tool over one jobs door.
///
/// The door is taken unconditionally rather than as an `Option` because
/// `bash` exists on every host and only one of its two modes needs one:
/// a host with no jobs plane passes `job.unavailable()`, and a model
/// asking for `mode: "background"` there is refused in band saying so.
/// An `Option` would put that same refusal one layer further from the
/// place that has to word it.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry([bash.tool(job.unavailable())])
/// ```
///
pub fn tool(jobs: Jobs) -> tool.Tool {
  tool.Tool(
    name: "bash",
    description: "Run a shell command in the sandboxed workspace. The "
      <> "command runs as `bash -o pipefail -c` in the workspace using "
      <> "the session's PATH and network policy. A failed command before "
      <> "a pipe remains a failed pipeline; inspect its output before "
      <> "claiming tests passed. With `mode: \"background\"` the "
      <> "command is started as a background job instead: the call returns "
      <> "a job id straight away and the command keeps running after it, so "
      <> "use it for a long build or something you want to watch. Read a "
      <> "job with `"
      <> job.poll_tool_name
      <> "`, write to its stdin with `"
      <> job.send_tool_name
      <> "`, and stop it with `"
      <> job.kill_tool_name
      <> "`.",
    // No double quotes in a snippet: the system prompt's index is
    // asserted line-by-line against the JSON request body it renders
    // into (`client/serve_test`), and a quote is escaped there.
    prompt_snippet: option.Some(
      "`bash` runs a shell command in the workspace, jailed and offline; "
      <> "`mode: background` starts it as a job instead. A pipeline that "
      <> "exists to find, filter, or count across files belongs in "
      <> "`code_mode` with `cap/search`, which answers structured.",
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
            <> "). A background job has its own, much longer default and "
            <> "ceiling; the result of starting one says which wall it "
            <> "was granted",
          ),
        ),
        #(
          "mode",
          tool.enum_property(
            ["foreground", "background"],
            "\"foreground\" (the default) waits for the command and "
              <> "returns its output. \"background\" starts it as a job and "
              <> "returns a job id at once, leaving it running after this "
              <> "call ends",
          ),
        ),
      ],
      ["command"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements:,
    run: fn(ctx, args) { run(jobs, ctx, args) },
  )
}

/// The bash tool's policy-shaped needs: workspace writable, network off,
/// tmpfs scratch. The environment allowlist is added per call from the
/// context's env, and so is the network — `call_spec` takes the session
/// base's through `tool.asking_base_network`, so the `NetworkOff` stated
/// here is the posture of a host that configured none rather than a
/// ceiling this tool imposes.
///
/// The readable reach is added per call for the same reason. It used to
/// be `["/"]` here, which was true of a base view that bound the whole
/// host; under `protocol-change/020` the base names the regions a jail
/// may read, so `call_spec` asks for the base's own readable roots and
/// mounts. A shell that restated `["/"]` would be asking for a root no
/// base covers, and the meet would refuse every call.
pub fn requirements(workspace: String) -> policy.SandboxPolicy {
  let base = policy.workspace_default(workspace)
  policy.SandboxPolicy(..base, readable_roots: [], env_allow: [])
}

fn run(jobs: Jobs, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use command <- tool.with_arg(tool.required_string(args, "command"))
  use requested <- tool.with_arg(tool.optional_int(args, "timeout_ms"))
  use mode <- tool.with_arg(requested_mode(args))

  // The floor is shared and the ceiling is not: a timeout under a
  // millisecond is nonsense in either mode, while the ceiling belongs to
  // whichever plane will run the command. See the module doc.
  use <- bool.guard(
    when: option.unwrap(requested, default_timeout_ms) < 1,
    return: tool.failure("invalid arguments: `timeout_ms` must be >= 1"),
  )

  case mode {
    Background -> background(jobs, ctx, command, requested)
    Foreground -> foreground(ctx, command, requested)
  }
}

// The model writes a closed vocabulary rather than a boolean, and an
// absent argument is the foreground call every `bash` was before this
// argument existed — so nothing a model wrote yesterday backgrounds
// itself today.
fn requested_mode(args: JsonValue) -> Result(Mode, String) {
  case tool.optional_string(args, "mode") {
    Error(reason) -> Error(reason)
    Ok(None) | Ok(Some("foreground")) -> Ok(Foreground)
    Ok(Some("background")) -> Ok(Background)

    Ok(Some(other)) ->
      Error(
        "`mode` must be \"foreground\" or \"background\", not \""
        <> other
        <> "\"",
      )
  }
}

// A background call is synchronous over the *admission* and nothing
// else: the door clears the command through the broker under the job's
// own identity, so a policy refusal, an escalation and the strand's job
// ceiling all reach this call in the door's own words rather than
// arriving at some later poll. What it does not wait for is the command.
fn background(
  jobs: Jobs,
  ctx: Ctx,
  command: String,
  requested: Option(Int),
) -> ToolOutcome {
  use started <- tool.or_outcome(
    jobs.start(ctx, command, requested),
    job.refusal_outcome,
  )
  tool.success(
    "started background job "
    <> started.id
    <> ", with a wall of "
    <> int.to_string({ started.wall_ms + 999 } / 1000)
    <> "s. It is running now; read it with `"
    <> job.poll_tool_name
    <> "`.",
  )
  |> tool.with_details(
    json.Object([
      #("job_id", json.String(started.id)),
      #("mode", json.String("background")),
      #("deadline_ms", json.Int(started.deadline_ms)),
      #("wall_ms", json.Int(started.wall_ms)),
    ]),
  )
}

fn foreground(
  ctx: Ctx,
  command: String,
  requested: Option(Int),
) -> ToolOutcome {
  let timeout = option.unwrap(requested, default_timeout_ms)
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
    tool.collect_observed(
      events,
      waiting: timeout + settle_grace_ms,
      observe: ctx.observe_output,
    ),
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
  //
  // The readable roots and the mounts are asked for the same way and on
  // the same argument. An interpreter, a system library and a toolchain
  // cache all sit outside the workspace, and under
  // `protocol-change/020` the session base is what says which of them a
  // jail may reach. Mounts compose by exact path, so a shell that named
  // none would run with none of them bound at all.
  let tool_requirements =
    policy.SandboxPolicy(
      ..base_requirements,
      writable_roots: list.unique(list.append(
        base_requirements.writable_roots,
        ctx.base_policy.writable_roots,
      )),
      readable_roots: list.unique(list.append(
        base_requirements.readable_roots,
        ctx.base_policy.readable_roots,
      )),
      mounts: ctx.base_policy.mounts,
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
    // Login startup rewrites PATH through the host's system profile. The
    // session already supplies the intended environment; pipefail also keeps
    // `go test | tail` from reporting the successful tail as a passing test.
    argv: ["bash", "-o", "pipefail", "-c", command],
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

// Render a settled execution twice over: as the prose a model reads and
// as the `details` object a program reads, from the same `ExecResult` so
// the two cannot disagree. Both halves report `cancelled` alongside
// `timed_out` because neither flag implies the other's answer:
// `timed_out` says the wall deadline fired, `cancelled` says the helper
// stopped the run rather than the run ending on its own, and a run
// killed by its deadline is both. Only `cancelled` can distinguish a
// truncated run from a clean one, since a cancelled payload that had
// backgrounded its work exits zero (`protocol-change/006`).
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
      // The two flags answer different questions, so the line reports
      // the pair. `cancelled` is the helper's own witness that it
      // climbed the cancel ladder, and nothing else in the record can
      // stand in for it: a cancelled run whose payload had backgrounded
      // its work reports `code=0 signal=0`, an ordinary clean success
      // (`protocol-change/006`). When it is set, the output above is
      // only what arrived before the stop.
      case result.timed_out, result.cancelled {
        True, True -> ["[command timed out and was stopped; output is partial]"]
        True, False -> ["[command timed out]"]
        False, True -> ["[command was cancelled; output is partial]"]
        False, False -> []
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
      // `cancelled` without `timed_out` is the broker having asked for
      // the stop; the two together are the policy's wall clock running
      // out, which climbs the same ladder (`protocol-change/006`).
      #("cancelled", json.Bool(result.cancelled)),
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

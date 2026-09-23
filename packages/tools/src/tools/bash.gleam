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
//// ## The three modes
////
//// `mode` chooses between the foreground call above, a **background
//// job**, and **auto**, which is the default. A background job is the
//// same command, admitted under the same rules, but allowed to outlive
//// the tool call that started it. A background call clears through
//// `tools/job.Jobs` — the host's door — and returns a handle at once
//// rather than the command's output, and the model reads it afterwards
//// with `job_poll`, feeds it with `job_send` and stops it with
//// `job_kill`. The owner is sent a notice when a job ends, so reading
//// one is optional rather than the only way to learn its outcome.
////
//// **Auto** starts the command as a job the call then waits on, for up
//// to `timeout_ms`, streaming its output to the client as a foreground
//// call does. A job that finishes in that window is rendered exactly as
//// a foreground result — the same body, `details` and blob overflow,
//// through the same `exited` — so a quick command reads the same in
//// either mode. One that outlives the window is *released*: the call
//// returns its handle, the command keeps running, and its end arrives
//// later as a notice. A model therefore never has to decide in advance
//// which commands are long. `docs/design-notes/async-completion-wake.md`
//// has the whole design, including why the job is silent while the call
//// waits and why the release cannot lose or duplicate the result.
////
//// Auto falls back to the foreground path when the jobs plane cannot
//// take the command: the strand is at its job ceiling, the host has no
//// jobs plane, or the clearance refused. The last case is about the shape
//// of the refusal rather than about running anyway: the foreground
//// clearance produces the structured refusal the escalation flow reads,
//// and the jobs door reports one as text.
////
//// One flag on a tool the model already has, rather than a fourth tool
//// definition, because tool-surface cost is arithmetic: every permanent
//// definition renders into the provider's cached byte prefix and is paid
//// for on every request of every strand for the life of the session.
////
//// Foreground and background are otherwise deliberately not symmetric in
//// one place.
//// The foreground clamp is this module's `max_timeout_ms`, ten minutes;
//// a job's default and clamp are the host's, an hour, raised by an
//// operator's `[jobs].max_wall`. So `timeout_ms` is passed to the door
//// **unclamped** and the door answers with the wall it granted — clamping
//// here as well would silently cap a job at the foreground ceiling and
//// no reader of either number could tell which had applied.

import broker/broker
import broker/budget
import broker/exec.{type ExecResult}
import broker/framing
import broker/policy
import core/clock
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/blob
import tools/job.{type Jobs}
import tools/permissions
import tools/tail
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

/// How often an auto call's wait looks at its job, in milliseconds: the
/// cadence the client's live output advances at, and the latency between
/// a job settling and the call noticing.
const watch_slice_ms = 500

/// Whether a call blocks for its command, backgrounds it, or waits for a
/// while and backgrounds it only if it has to.
///
/// A closed vocabulary rather than the `detach: Bool` the shape would
/// otherwise take, for the no-naked-`Bool` reason: the polarity of a
/// flag named for one of two peers is exactly what a reader of a call
/// site should not have to carry.
pub type Mode {
  /// The call starts the command as a job and waits up to `timeout_ms`
  /// for it. A command that finishes in time answers as a foreground call
  /// would; one that does not answers with its job handle and keeps
  /// running. What an argument-less call means.
  Auto

  /// The call blocks until the command settles and answers with its
  /// output, killing it at `timeout_ms`. What every `bash` call meant
  /// before jobs existed.
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
      <> "the session's PATH and network policy. Declare extra paths or full "
      <> "network access in permissions to request approval before execution. "
      <> "For a Git worktree outside the workspace, request writable_roots "
      <> "for the repository's .git directory and an existing destination "
      <> "directory or its parent if the new worktree path does not exist. "
      <> "A failed command before "
      <> "a pipe remains a failed pipeline; inspect its output before "
      <> "claiming tests passed. For scratch files use "
      <> "`${LOOM_SCRATCH_DIR:-$TMPDIR}`, not a literal `/tmp`: macOS "
      <> "exposes private scratch at a different path. Private scratch "
      <> "lasts for this command or background job; keep files needed "
      <> "by later calls in the workspace. A command still running when "
      <> "`timeout_ms` passes is not killed: it becomes a background job, "
      <> "the call returns its job id, and you are sent a notice with its "
      <> "result when it finishes, so keep working or end your turn to "
      <> "wait. With `mode: \"background\"` the command is started as a job "
      <> "at once, for a server or something you want to watch; with "
      <> "`mode: \"foreground\"` it is killed at `timeout_ms` instead. Read a "
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
      "`bash` runs a shell command under the session jail policy; one "
      <> "that outlives its timeout becomes a background job and you are "
      <> "notified when it ends. Declare "
      <> "`permissions.writable_roots` for outside writes before running; "
      <> "a denied command needs a fresh call with those roots. Use "
      <> "`${LOOM_SCRATCH_DIR:-$TMPDIR}` for scratch, not literal `/tmp`. "
      <> "A pipeline that "
      <> "exists to find, filter, or count across files belongs in "
      <> "`code_mode` with `cap/search`, which answers structured.",
    ),
    schema: tool.object_schema(
      [
        #("permissions", permissions.schema()),
        #("command", tool.string_property("the shell command to run")),
        #(
          "timeout_ms",
          tool.integer_property(
            "how long to wait for the command in milliseconds (default "
            <> int.to_string(default_timeout_ms)
            <> ", ceiling "
            <> int.to_string(max_timeout_ms)
            <> "). By default a command still running then becomes a "
            <> "background job rather than being killed. A background job "
            <> "has its own, much longer wall; the result of starting one "
            <> "says which wall it was granted",
          ),
        ),
        #(
          "mode",
          tool.enum_property(
            ["auto", "foreground", "background"],
            "\"auto\" (the default) waits up to timeout_ms and returns the "
              <> "output, or a job id if the command is still running. "
              <> "\"foreground\" kills the command at timeout_ms. "
              <> "\"background\" starts it as a job and returns a job id at "
              <> "once, leaving it running after this call ends",
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

  use ctx <- tool.or_outcome(permissions.authorize(ctx, args), fn(outcome) {
    outcome
  })
  case mode {
    Auto -> attended(jobs, ctx, command, requested)
    Background -> background(jobs, ctx, command, requested)
    Foreground -> foreground(ctx, command, requested)
  }
}

// The model writes a closed vocabulary rather than a boolean, and an
// absent argument is auto: a command that finishes in its window answers
// exactly as the foreground call it would have been, so the only thing a
// model writing yesterday's call sees change is a long command that is
// no longer killed.
fn requested_mode(args: JsonValue) -> Result(Mode, String) {
  case tool.optional_string(args, "mode") {
    Error(reason) -> Error(reason)
    Ok(None) | Ok(Some("auto")) -> Ok(Auto)
    Ok(Some("foreground")) -> Ok(Foreground)
    Ok(Some("background")) -> Ok(Background)

    Ok(Some(other)) ->
      Error(
        "`mode` must be \"auto\", \"foreground\" or \"background\", not \""
        <> other
        <> "\"",
      )
  }
}

// --- auto -------------------------------------------------------------------

// An auto call: the command starts as a job this call attends, and the
// call waits on it for its window.
//
// The door's refusals split two ways. The ones that prove no job exists
// and say the jobs plane cannot take this command — the strand's ceiling,
// a host with no plane, a clearance refusal — fall back to the foreground
// path, because none of them is a verdict about the command a foreground
// call would share except the last, and that one the foreground clearance
// words in the structure an escalation needs. `Unavailable` does not fall
// back: a plane that did not answer in time may already be clearing the
// job, and a foreground run beside it would run the command twice. The
// rest can only mean the door and this module disagree, and they are all
// reported as they are.
fn attended(
  jobs: Jobs,
  ctx: Ctx,
  command: String,
  requested: Option(Int),
) -> ToolOutcome {
  let window =
    int.min(option.unwrap(requested, default_timeout_ms), max_timeout_ms)
  case jobs.attend(ctx, command) {
    Ok(started) -> {
      let #(now, _clock) = clock.read(ctx.clock)
      look(jobs, ctx, started, Watch(..fresh_watch(), until: now + window))
    }

    Error(job.CeilingReached(..))
    | Error(job.NoJobsPlane)
    | Error(job.ClearanceRefused(..)) -> foreground(ctx, command, requested)

    Error(job.Unavailable(..) as refusal)
    | Error(job.NotFound(..) as refusal)
    | Error(job.Invalid(..) as refusal) -> job.refusal_outcome(refusal)
  }
}

// What an auto call carries between looks at its job: the cursors, the
// whole of each stream as far as the looks have seen it, whether any look
// missed bytes, the windows the client is shown, and when the wait ends.
type Watch {
  Watch(
    cursors: job.Cursors,
    stdout: List(BitArray),
    stderr: List(BitArray),
    gaps: Gaps,
    stdout_tail: tail.Tail,
    stderr_tail: tail.Tail,
    until: Int,
  )
}

// Whether the looks saw every byte. A job's rolling tail is bounded, so a
// command that prints faster than the looks come can push bytes past a
// cursor before it is read; the spill has them, and `collected` reads it.
type Gaps {
  SawEverything
  MissedSome
}

fn fresh_watch() -> Watch {
  Watch(
    cursors: job.Cursors(stdout: 0, stderr: 0),
    stdout: [],
    stderr: [],
    gaps: SawEverything,
    stdout_tail: tail.new(capacity: tool.tail_bytes),
    stderr_tail: tail.new(capacity: tool.tail_bytes),
    until: 0,
  )
}

// One look at the job, and then either its end, another look, or the
// release. Each look waits at most `watch_slice_ms`, which is what keeps
// the client's view of the output moving while the command runs.
fn look(
  jobs: Jobs,
  ctx: Ctx,
  started: job.Started,
  watch: Watch,
) -> ToolOutcome {
  let #(now, _clock) = clock.read(ctx.clock)
  let wait = int.clamp(watch.until - now, min: 0, max: watch_slice_ms)
  case jobs.poll(ctx, started.id, wait, watch.cursors) {
    // The job is ours and the door could not answer about it; nothing is
    // known about the command, so the call hands the job back to its
    // owner and says so rather than guessing at an outcome.
    Error(_refusal) -> release(jobs, ctx, started, watch)

    Ok(polled) -> {
      let watch = seen(watch, polled, ctx.observe_output)
      case job.is_pending(polled.state), now + wait >= watch.until {
        False, _deadline -> ended(ctx, polled, watch)
        True, True -> release(jobs, ctx, started, watch)
        True, False -> look(jobs, ctx, started, watch)
      }
    }
  }
}

// One poll's bytes folded into the watch, and shown to the client.
fn seen(
  watch: Watch,
  polled: job.Polled,
  observe: fn(tool.OutputTail) -> Nil,
) -> Watch {
  let gaps = case polled.stdout.dropped + polled.stderr.dropped {
    0 -> watch.gaps
    _missed -> MissedSome
  }
  let stdout_tail = tail.push(watch.stdout_tail, polled.stdout.bytes)
  let stderr_tail = tail.push(watch.stderr_tail, polled.stderr.bytes)
  show(observe, framing.Stdout, stdout_tail, polled.stdout.bytes)
  show(observe, framing.Stderr, stderr_tail, polled.stderr.bytes)
  Watch(
    ..watch,
    cursors: job.Cursors(
      stdout: polled.stdout.cursor,
      stderr: polled.stderr.cursor,
    ),
    stdout: [polled.stdout.bytes, ..watch.stdout],
    stderr: [polled.stderr.bytes, ..watch.stderr],
    gaps:,
    stdout_tail:,
    stderr_tail:,
  )
}

// A stream's window, shown only when this look brought it something: a
// foreground call's collector shows one window per chunk, and a look with
// no new bytes is not a chunk.
fn show(
  observe: fn(tool.OutputTail) -> Nil,
  stream: framing.OutputStream,
  window: tail.Tail,
  fresh: BitArray,
) -> Nil {
  case bit_array.byte_size(fresh) {
    0 -> Nil
    _size ->
      observe(tool.OutputTail(
        stream:,
        tail: tail.since(window, 0).bytes
          |> bit_array.to_string
          |> result.unwrap(""),
        total_bytes: tail.received(window),
      ))
  }
}

// The window ran out. The release is serialized against the job's own
// settlement by the actor, so exactly one of two things is true: the job
// is still running and its owner will be told when it ends, or it ended
// first and nobody will be, in which case this call renders it.
fn release(
  jobs: Jobs,
  ctx: Ctx,
  started: job.Started,
  watch: Watch,
) -> ToolOutcome {
  case jobs.release(ctx, started.id) {
    Ok(job.Released) -> handed_off(started, watch)

    Ok(job.AlreadyEnded) ->
      case jobs.poll(ctx, started.id, 0, watch.cursors) {
        Ok(polled) ->
          ended(ctx, polled, seen(watch, polled, ctx.observe_output))
        Error(refusal) -> job.refusal_outcome(refusal)
      }

    Error(refusal) -> job.refusal_outcome(refusal)
  }
}

// The answer for a command that outlived its window: the handle, what the
// command has printed so far, and what will happen next.
fn handed_off(started: job.Started, watch: Watch) -> ToolOutcome {
  let so_far =
    [
      #("stdout", watch.stdout_tail),
      #("stderr", watch.stderr_tail),
    ]
    |> list.filter_map(fn(pair) {
      let text =
        tail.since(pair.1, 0).bytes
        |> bit_array.to_string
        |> result.unwrap("")
      case text {
        "" -> Error(Nil)
        _ -> Ok("--- " <> pair.0 <> " so far ---\n" <> text)
      }
    })
  tool.success(string.join(
    [
      "the command is still running, now as background job "
        <> started.id
        <> " with a wall of "
        <> int.to_string({ started.wall_ms + 999 } / 1000)
        <> "s. You will be sent a notice with its result when it "
        <> "finishes: keep working on something else, or end your turn "
        <> "to wait. Read it early with `"
        <> job.poll_tool_name
        <> "` or stop it with `"
        <> job.kill_tool_name
        <> "`.",
      ..so_far
    ],
    "\n\n",
  ))
  |> tool.with_details(
    json.Object([
      #("job_id", json.String(started.id)),
      #("mode", json.String("auto")),
      #("backgrounded", json.Bool(True)),
      #("deadline_ms", json.Int(started.deadline_ms)),
      #("wall_ms", json.Int(started.wall_ms)),
    ]),
  )
}

// A job that ended inside the call, rendered as the foreground call it
// stood in for. An exit or a kill carries the helper's own report and goes
// through `exited`; a loss carries none, and says so.
fn ended(ctx: Ctx, polled: job.Polled, watch: Watch) -> ToolOutcome {
  case polled.state {
    job.Exited(result:) | job.Killed(result:, ..) ->
      exited(ctx, collected(ctx, polled, watch, result), result)

    job.Lost(..) ->
      tool.failure(
        "the command's sandbox was lost before it reported an exit, so "
        <> "what it did is unknown: "
        <> job.state_name(polled.state),
      )

    // Unreachable: `watch` only calls this once `is_pending` is false.
    // Answered with the job's handle rather than a guess, so a change to
    // that predicate shows up as a visible answer and not a wrong one.
    job.Starting | job.Running | job.Draining(..) ->
      tool.failure("job " <> polled.id <> " is still running")
  }
}

// The whole of each stream, from the looks when they saw every byte and
// from the spill when they did not. A stream whose spill cannot be read
// falls back to what the looks saw, which is the tail of it at worst.
fn collected(
  ctx: Ctx,
  polled: job.Polled,
  watch: Watch,
  result: ExecResult,
) -> tool.Collected {
  let stdout = whole(ctx, watch.gaps, polled.spill.stdout_ref, watch.stdout)
  let stderr = whole(ctx, watch.gaps, polled.spill.stderr_ref, watch.stderr)
  tool.Collected(
    stdout:,
    stderr:,
    stdout_truncated: result.stdout_truncated
      || bit_array.byte_size(stdout) < result.stdout_bytes,
    stderr_truncated: result.stderr_truncated
      || bit_array.byte_size(stderr) < result.stderr_bytes,
    outcome: broker.CallExited(result:),
  )
}

fn whole(
  ctx: Ctx,
  gaps: Gaps,
  spill: Option(String),
  looked: List(BitArray),
) -> BitArray {
  let seen = bit_array.concat(list.reverse(looked))
  case gaps, spill {
    SawEverything, _spill | MissedSome, None -> seen
    MissedSome, Some(ref) ->
      ctx.filesystem.read(blob.ref_path(ctx.blob_root, ref))
      |> result.unwrap(seen)
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
      permission_guidance(result, stderr),
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

// A kernel error is only a clue: stderr is program output, not an
// enforcement report, and a shell may already have changed state. The
// next invocation can declare authority before it starts, but this one
// must never be replayed automatically.
fn permission_guidance(result: ExecResult, stderr: String) -> List(String) {
  case
    result.code != 0
    && {
      string.contains(stderr, "Operation not permitted")
      || string.contains(stderr, "Permission denied")
      || string.contains(stderr, "Read-only file system")
    }
  {
    True -> {
      let git_hint = case denied_git_directory(stderr) {
        Some(path) ->
          " Git reported a blocked path under `"
          <> path
          <> "`; include that directory in permissions.writable_roots "
          <> "if the write is intended."
        None -> ""
      }
      [
        "If this failure came from the sandbox, do not repeat the same "
        <> "call. Start a new bash call with permissions.readable_roots "
        <> "and permissions.writable_roots naming the exact paths needed; "
        <> "Loom will request approval before "
        <> "that call runs. For git worktree add, include the "
        <> "repository's .git directory and an existing destination "
        <> "directory or its parent if the worktree path does not exist. "
        <> "Protected paths cannot be approved."
        <> git_hint,
      ]
    }
    False -> []
  }
}

// Git reports a full lock path, but its worktree operation needs more
// than one file under the common metadata directory. This is only a
// hint from untrusted stderr; `permissions` still canonicalizes the
// model's next request and the operator still sees the exact grant.
fn denied_git_directory(stderr: String) -> Option(String) {
  let quoted = string.split(stderr, on: "'")
  case
    list.find(quoted, fn(part) {
      string.starts_with(part, "/") && string.contains(part, "/.git/")
    })
  {
    Error(Nil) -> None
    Ok(path) ->
      case string.split(path, on: "/.git/") {
        [repository, ..] -> Some(repository <> "/.git")
        [] -> None
      }
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

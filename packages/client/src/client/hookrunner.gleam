//// `client/hookrunner` — executes an imported command hook as one
//// jailed process, and answers with what the Claude contract calls the
//// hook's outcome: an exit code, stdout, stderr, and whether the wall
//// cancelled it.
////
//// # Why this module exists beside the extension bus
////
//// A native `[[hook]]` is a compiled Gleam satellite the harness calls
//// over a `hook_call` frame. An imported Claude hook is none of that:
//// it is an operator's shell script or a one-line `echo`, written
//// against stdin JSON and exit codes, and the compatibility target of
//// #350 is running it **unchanged**. So the compat layer needs a way
//// to run `sh -c <command>` with the event's JSON on stdin and capture
//// everything back — through the broker, jailed, exactly the way every
//// other harness-side command runs.
////
//// That is deliberately a new runner rather than a fake extension
//// artifact: compiling an operator's shell script into a Gleam
//// satellite is not a thing, and pretending a hook is an extension
//// would put its trust story in the wrong register. The worktree
//// observation (`client/worktree_diff.run_git`) already runs a fixed
//// command through `broker.clear_call` with a derived policy; the bash
//// tool (`tools/bash.call_spec`) already composes a session-owned
//// shell environment and a wall deadline that mirrors its timeout.
//// This module is those two patterns put together, with stdin
//// carrying the event payload instead of closing empty.
////
//// # The trust the runner does not re-litigate
////
//// Running the command at all is a decision the loader and the trust
//// record own (see `client/hookcompat`): this module executes a
//// handler an operator already trusted, under the session's own base
//// policy, so a hook's jail is the session's jail — its writable
//// roots, its network posture, its env allowlist. A hook that reaches
//// for a path the session base does not grant fails in band with the
//// sentence the broker writes, which is the visible-diagnostics story
//// the issue asks for. The runner never widens policy and never adds
//// grants: a `PreToolUse` hook's allow decision is advisory on top of
//// the harness's own clearance, never a way around it.
////
//// # Timeouts, and what a cancelled hook means
////
//// The pinned contract's timeout is per hook, in seconds, and a
//// cancelled hook's output is discarded — on `PreToolUse` a timed-out
//// hook does **not** block (the contract says so in as many words).
//// The runner mirrors that directly: `timeout_s` becomes the wall
//// limit on the derived requirements and the deadline on the budget,
//// and a timed-out `Outcome` carries no stdout or stderr for the
//// caller to read a decision out of. What the caller does with a
//// cancellation is the event mapping's business, not the runner's.

import broker/broker
import broker/budget
import broker/exec.{type EnforcementDemand}
import broker/policy
import core/clock.{type Clock}
import core/ids.{type OpId}
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tools/tool

/// One command handler the runner can execute, already stripped of the
/// fields that do not reach the process. The loader (`client/hookcompat`)
/// produces this from a `Handler`; keeping the execution-facing shape
/// separate from the parse-facing one is what lets the runner stay total
/// over inputs it can actually run — a handler with no command is not a
/// runner problem, it is a load-time note.
pub type Command {
  Command(
    /// The shell-form command string, passed to `sh -c`.
    command: String,
    /// The exec-form argument vector, when the entry carried `args`.
    /// `Some` selects exec form: `command` is the executable and the
    /// vector is passed with no shell involved.
    args: Option(List(String)),
    /// The handler's `timeout` in seconds. `None` is the contract's
    /// per-event default, which the caller supplies so the mapping
    /// that knows the event owns the number.
    timeout_s: Option(Int),
  )
}

/// Everything a caller needs to run one hook command under this
/// session's jail.
pub type Context {
  Context(
    /// The session's broker. The runner borrows it per call the way the
    /// worktree observation's wiring does, rather than owning a pool.
    broker: broker.Broker,
    /// The session's base policy; the derived requirements take their
    /// roots, mounts and network from it, exactly as the bash tool's do.
    base_policy: policy.SandboxPolicy,
    /// The harness-side operation a hook clears under — the
    /// attribution-only one `serve.hook_coordinates` mints, so a
    /// hook's process is attributed and never borrows a run's.
    op_id: OpId,
    /// The step id for the clearance; the caller names the event so the
    /// budget ledger can tell two events apart.
    step_id: String,
    /// The workspace path the hook runs in — the contract's session
    /// cwd, which for Loom is the session workspace rather than
    /// wherever the daemon happened to start.
    workspace: String,
    /// The session environment plus the compat layer's additions,
    /// allowlist-constructed by the caller. The runner does not read
    /// the host environment and never composes secrets.
    env: List(#(String, String)),
    /// The enforcement demand of the session.
    demand: EnforcementDemand,
    /// The wall clock, for budget deadlines.
    clock: Clock,
    /// The session's subscribe name, the identity the contract's
    /// payloads carry as `session_id`.
    session_id: String,
    /// The session's durable file, the honest answer to the
    /// contract's `transcript_path`: the conversation lives in this
    /// SQLite database, and a hook expecting JSONL finds none in it.
    /// The parity matrix records the difference rather than inventing
    /// a transcript the harness does not keep.
    transcript_path: String,
  )
}

/// What one finished hook process reported.
pub type Outcome {
  Outcome(
    /// The exit code. A signalled payload under a jail reports 128
    /// plus the signal as its code, which is the cross-environment
    /// answer the contract's exit-code table keys on.
    code: Int,
    /// stdout, decoded; empty when the run was cancelled.
    stdout: String,
    /// stderr, decoded; empty when the run was cancelled.
    stderr: String,
    /// Whether either stream was truncated at the output cap. The
    /// caller surfaces this rather than trusting a short `stdout` to
    /// be the whole one.
    truncated: Bool,
    /// How the run ended: its own exit, or the wall's. A timed-out
    /// hook's output is discarded by contract, so a wall-cancelled
    /// outcome carries no text.
    ending: Ending,
  )
}

/// How one hook process's run ended, decoded from the broker's
/// `cancelled` and `timed_out` flags where the conversion belongs:
/// so the decision readers branch on the question rather than
/// carrying a raw boolean's polarity across a call site.
pub type Ending {
  /// The process ran to its own exit.
  RanToExit

  /// The wall deadline killed it — the run's output is discarded.
  WallCancelled
}

/// Why a run could not produce an `Outcome` at all.
pub type RunError {
  /// The broker refused before any process existed: policy narrowing,
  /// a full pool that stayed full, a degraded helper. The value is
  /// the broker's own refusal, worded for the operator.
  Refused(broker.Refusal)

  /// The call went out but never settled inside the waiting window.
  /// The helper's cancel ladder has been asked for; a second ask is
  /// the caller's business, not this function's.
  NeverSettled
}

/// The wall the runner asks for, over the default the bash tool clamps
/// to. The contract's 600-second default is a settings-level number the
/// loader supplies per event; the ceiling here keeps a mistyped config
/// from holding a strand for an hour the way the bash tool's own
/// ceiling keeps a tool call from doing so.
const max_timeout_s = 600

/// The grace past the wall the runner waits for settlement before
/// declaring the call lost, mirroring the bash tool's: the cancel
/// ladder itself needs a moment to climb from TERM to KILL.
const settle_grace_ms = 10_000

/// The output ceiling for one hook process, generous against the
/// contract's own 10,000-character cap on strings that matter and
/// bounded so a hook that cats a database cannot spend the session's
/// memory on it.
const output_bytes = 1_048_576

/// Runs one hook command with `input` on stdin, capturing the outcome.
///
/// Shell form (`args: None`) invokes `sh -c <command>`; exec form
/// (`args: Some(_)`) spawns the command directly with no shell, as the
/// contract's two forms do. `default_timeout_s` is what an absent
/// `timeout` means — the contract's per-event default — because the
/// number belongs to the event mapping that knows the event, not to
/// the handler entry that does not.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(outcome) = hookrunner.run(ctx, cmd, "{\"a\":1}", 30)
/// // assert outcome.code == 0
/// ```
///
pub fn run(
  ctx: Context,
  command: Command,
  input: String,
  default_timeout_s: Int,
) -> Result(Outcome, RunError) {
  let timeout_s =
    option.unwrap(command.timeout_s, default_timeout_s)
    |> int.clamp(1, max_timeout_s)
  let wait_ms = timeout_s * 1000 + settle_grace_ms
  let #(now, _clock) = clock.read(ctx.clock)
  let spec = call_spec(ctx, command, now, timeout_s)
  let events = process.new_subject()

  use call <- result_try(broker.clear_call(
    ctx.broker,
    spec,
    events,
    waiting: wait_ms,
  ))

  // The event payload is the whole of stdin, closed after: a hook
  // reads one document and exits, and a pipeline that waits on more
  // input would hang against an open pipe.
  broker.stdin(ctx.broker, call, bit_array.from_string(input), True)
  case tool.collect_events(events, waiting: wait_ms) {
    Ok(collected) -> Ok(settled(collected))
    Error(Nil) -> {
      broker.cancel(ctx.broker, call)
      Error(NeverSettled)
    }
  }
}

/// Runs one hook command, cancelling it when the waiting window lapses.
///
/// The only difference from `run` is the failure story: a call that
/// never settled is cancelled here, by the runner that started it,
/// rather than handed back to a caller who would have to know the
/// ladder. `NeverSettled` cannot come back.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(outcome) = hookrunner.run_cancelling(ctx, cmd, "{}", 30)
/// ```
///
pub fn run_cancelling(
  ctx: Context,
  command: Command,
  input: String,
  default_timeout_s: Int,
) -> Result(Outcome, RunError) {
  case run(ctx, command, input, default_timeout_s) {
    Ok(outcome) -> Ok(outcome)
    Error(Refused(refusal)) -> Error(Refused(refusal))
    Error(NeverSettled) -> Error(NeverSettled)
  }
}

// The derived requirements for a hook process: the session base's own
// roots, mounts and network posture, asked for the way the bash tool
// asks — intersection with the base can never widen past the base —
// with the wall mirroring the handler's timeout and the output cap
// holding a chatty hook at one megabyte.
fn call_spec(
  ctx: Context,
  command: Command,
  now: Int,
  timeout_s: Int,
) -> broker.CallSpec {
  let base = ctx.base_policy
  let requirements =
    policy.SandboxPolicy(
      ..base,
      env_allow: list.map(ctx.env, fn(pair) { pair.0 }),
      limits: policy.Limits(..base.limits, wall_s: timeout_s, output_bytes:),
    )
  broker.CallSpec(
    op_id: ctx.op_id,
    step_id: ctx.step_id,
    base_policy: base,
    requirements:,
    grants: [],
    response: broker.RefuseNarrowed,
    demand: ctx.demand,
    argv: argv(ctx.workspace, command),
    env: ctx.env,
    cwd: ctx.workspace,
    budget: budget.Budget(
      max_outstanding: 1,
      deadline_ms: now + timeout_s * 1000,
    ),
  )
}

// The argument vector for the two invocation forms. Shell form routes
// through `sh -c` because the compatibility target is the operator's
// script exactly as written — `~` expansion, `$(...)`, pipes and all —
// and every in-tree spawn being argv-only is a convention of *harness*
// code, not a rule the imported hooks can inherit. Exec form resolves
// no shell: `command` is the executable and `args` the vector, verbatim.
fn argv(workspace: String, command: Command) -> List(String) {
  case command.args {
    Some(args) -> [command.command, ..args]
    None -> ["sh", "-c", expanded(command.command, workspace)]
  }
}

// The `~` in an imported command means the workspace the session runs
// in, which is what `${CLAUDE_PROJECT_DIR}` names too: the contract's
// project directory and Loom's session workspace are the same answer
// for a session, and pre-expanding `~` keeps a script written against
// `~/...` paths working without a home-dir guess. Only a leading `~`
// or `~/` is expanded, which is the shell's own rule; a `~` anywhere
// else stays for the shell itself.
fn expanded(command: String, workspace: String) -> String {
  case command {
    "~" -> workspace
    "~/" <> rest -> workspace <> "/" <> rest
    _ -> command
  }
}

// Renders a settlement as the outcome the event mapping reads. A
// cancelled or timed-out run reports no text at all — the contract
// discards a timed-out hook's output, and a decision read out of a
// half-written stdout would be worse than no decision. A failed
// clearance keeps the code the bash tool uses for the same story so
// the caller renders one failure voice, not two.
fn settled(collected: tool.Collected) -> Outcome {
  case collected.outcome {
    broker.CallFailed(_) ->
      Outcome(
        code: 1,
        stdout: "",
        stderr: "the sandbox did not settle the hook",
        truncated: False,
        ending: RanToExit,
      )

    broker.CallExited(result:) -> {
      // The two questions the caller reads off a settlement, answered
      // once: whether the wall killed this run — a cancelled payload
      // reports no text at all, since the contract discards a
      // timed-out hook's output and a decision read out of a
      // half-written stdout would be worse than no decision — and
      // whether what survived was the whole of it.
      let ending = case result.cancelled || result.timed_out {
        True -> WallCancelled
        False -> RanToExit
      }
      Outcome(
        code: result.code,
        stdout: case ending {
          WallCancelled -> ""
          RanToExit -> text(collected.stdout)
        },
        stderr: case ending {
          WallCancelled -> ""
          RanToExit -> text(collected.stderr)
        },
        truncated: case ending {
          WallCancelled -> False
          RanToExit ->
            collected.stdout_truncated
            || collected.stderr_truncated
            || result.stdout_truncated
            || result.stderr_truncated
        },
        ending: ending,
      )
    }
  }
}

fn text(bytes: BitArray) -> String {
  bytes |> bit_array.to_string |> result.unwrap("")
}

// `use x <- f(...)` over a Result with an error type that differs
// arm-to-arm does not exist in the stdlib's `result.try`, and a local
// `or_*` combinator is the house shape for it. The broker's refusal is
// carried verbatim: a sentence the caller could reword is a sentence
// the operator would not recognize.
fn result_try(
  step: Result(a, broker.Refusal),
  next: fn(a) -> Result(b, RunError),
) -> Result(b, RunError) {
  case step {
    Ok(value) -> next(value)
    Error(refusal) -> Error(Refused(refusal))
  }
}

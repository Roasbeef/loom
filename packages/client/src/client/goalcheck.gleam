//// `client/goalcheck` — runs the operator's goal check as one jailed
//// process and answers with the evidence the reviewer is shown.
////
//// # Why the check is not run in the harness VM
////
//// The command is operator-authored, so it is not model-influenced text.
//// That is not the question Rule Zero asks. Rule Zero is about *where*
//// code runs, and a shell command executed inside the harness VM would be
//// a hole in the effect plane whatever its provenance — the same hole an
//// operator-authored hook would be, which is why `client/hookrunner`
//// exists rather than an `os:cmd`. So the check clears through
//// `tools/tool.broker_runner`, the very closure the `bash` tool clears
//// through: the same requirements, the same `RefuseNarrowed`, the same
//// enforcement demand, the same escalation path (protocol 044 §8).
////
//// The policy is the session's own base, which is the policy the `bash`
//// tool composes onto and effectively what it runs under. A check is
//// deliberately not narrowed to a read-only view of the workspace: the
//// commands an operator would pin — `make check`, `go build ./...`, a test
//// binary — write build output, and a check that could not write would
//// fail for a reason that has nothing to do with the objective.
////
//// # Why the seam is one closure
////
//// Everything above is a fact about this module, and nothing above is a
//// fact the advisor actor needs. The actor holds a `Wiring` carrying one
//// blocking closure and the wall it runs under, so a test substitutes a
//// check that passes, fails, hangs or dies without a broker, a helper pool
//// or a jail — the arrangement `client/jobs` takes for the same reason.
//// The closure blocks, which is why the actor never calls it directly: it
//// runs inside a deadline-bounded weft task, and `client/advisor` owns
//// that.
////
//// Purity: this module reads a clock and clears a call, so it is an effect
//// module. It holds no state between calls and nothing it returns depends
//// on anything but its arguments and the process it ran.

import broker/broker
import broker/budget
import broker/exec.{type EnforcementDemand}
import broker/policy
import client/goalstate
import core/clock.{type Clock}
import core/ids.{type OpId}
import core/message
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/result
import gleam/string
import tools/tool

/// How much of each captured stream one result carries, in characters.
///
/// The tail rather than the head, because the end of a build log is where
/// the failure is: a reviewer shown the first two thousand characters of
/// `make check` reads the compiler starting up. Two streams are bounded
/// separately, so a result carries at most twice this much text — the cell
/// it is written to and the frame it is rendered into are both bounded well
/// above that.
///
/// It is a character count rather than a byte count because every consumer
/// downstream counts characters: the cell's JSON, the frame's own slice
/// bounds and the panel's row. The bytes are within a factor of four of it,
/// which is the same slack `client/protocol`'s objective bound accepts.
pub const output_tail_chars = 2000

/// The ceiling the sandbox itself applies to each captured stream.
///
/// The tail above is what the reviewer reads; this is what the harness is
/// willing to hold in memory to compute it. One megabyte, the number
/// `client/hookrunner` uses for the same question, so a check that cats a
/// database cannot spend the session's memory before it is clipped.
pub const output_bytes = 1_048_576

/// The grace past the wall the runner waits for a settlement before
/// declaring the call lost, mirroring the bash tool's: the helper's cancel
/// ladder needs a moment to climb from TERM to KILL.
pub const settle_grace_ms = 10_000

/// The step every check clears under.
///
/// Its own name rather than the hooks' or a run's, because the pooled
/// execution budget follows the operation-and-step pair: a check sharing
/// the hooks' step would queue behind an unrelated event's outstanding
/// process and would be refused for a reason the operator could not see
/// (protocol 044 §8).
pub const step_id = "goal-check"

/// The seam the advisor actor holds: one blocking run, and the wall it
/// runs under.
///
/// The wall is carried rather than read from `client/goalloop` so a test
/// can pin a short one; production passes `goalloop.check_timeout_ms`, and
/// the same number becomes the durable `Checking` deadline, so the phase a
/// restart reads and the process's own wall cannot disagree.
pub type Wiring {
  Wiring(
    /// Runs one command to completion and answers what it did. Blocking,
    /// and never called on an actor's process.
    run: fn(String) -> goalstate.CheckResult,
    /// How long one run may take, in milliseconds.
    timeout_ms: Int,
  )
}

/// Everything the production runner needs, which is exactly what
/// `client/jobs.Wiring` needs for the same jailed path.
pub type Runner {
  Runner(
    /// The broker seam, exactly `tools/tool.broker_runner`. Called from
    /// the task's own process, which is what binds the broker relay's
    /// caller-watch to the check rather than to the advisor actor.
    clear_call: fn(broker.CallSpec, Subject(broker.CallEvent)) ->
      Result(tool.RunningCall, broker.Refusal),
    /// The session base policy the check's requirements are asked against.
    base_policy: policy.SandboxPolicy,
    /// Enforcement strictness for the session.
    demand: EnforcementDemand,
    /// The allowlist-constructed child environment. The runner reads no
    /// host environment of its own.
    env: List(#(String, String)),
    /// The workspace the check runs in, which is the directory an operator
    /// typing the same command would be standing in.
    workspace: String,
    /// The session's time base, for the budget deadline and the stamp on
    /// the result.
    clock: Clock,
    /// The attribution-only operation a check clears under. Minted once by
    /// the host, the way a hook's is: nobody sees it as a running step, so
    /// nothing can abort it out from under the loop.
    op_id: OpId,
    /// How long a clearance may spend waiting out a congested helper pool.
    clearance_ms: Int,
  )
}

/// The production wiring over a runner.
///
/// ## Examples
///
/// ```gleam
/// // goalcheck.wiring(runner, timeout_ms: goalloop.check_timeout_ms)
/// ```
///
pub fn wiring(runner: Runner, timeout_ms timeout_ms: Int) -> Wiring {
  Wiring(run: fn(command) { execute(runner, command, timeout_ms) }, timeout_ms:)
}

/// A wiring that runs nothing and says so, for a host with no broker to
/// clear through.
///
/// It exists so "no check can be run here" is a value rather than an
/// absence: a goal whose check cannot run is fed with the reason as its
/// evidence, which is the same shape a check that timed out takes, rather
/// than being fed as though the operator had pinned no check at all.
///
/// ## Examples
///
/// ```gleam
/// // goalcheck.unavailable("this session runs no sandbox helper")
/// ```
///
pub fn unavailable(reason: String, timeout_ms timeout_ms: Int) -> Wiring {
  Wiring(
    run: fn(command) {
      goalstate.CheckResult(
        command:,
        ending: goalstate.DidNotFinish(reason:),
        output: "",
        ran_at_ms: 0,
      )
    },
    timeout_ms:,
  )
}

// One check, start to settlement, on whatever process called this.
//
// The order matters in one place: stdin is closed before the collector
// starts, because a command that reads stdin — a `git` pager, an
// interactive prompt a script did not expect to be absent — would otherwise
// sit against an open pipe until the wall killed it, and report a timeout
// for a reason that has nothing to do with the work.
fn execute(
  runner: Runner,
  command: String,
  timeout_ms: Int,
) -> goalstate.CheckResult {
  let #(now, _clock) = clock.read(runner.clock)
  let events = process.new_subject()
  let wait_ms = timeout_ms + settle_grace_ms

  case runner.clear_call(call_spec(runner, command, now, timeout_ms), events) {
    Error(refusal) -> unfinished(command, refused(refusal), now)

    Ok(call) -> {
      call.stdin(<<>>, True)

      case tool.collect_events(events, waiting: wait_ms) {
        Ok(collected) -> settled(command, collected, now)

        // The broker broke its exactly-one-settlement contract inside the
        // window. The cancel asks the helper to stop whatever is still
        // running; the loop is told the check produced nothing, which is
        // the honest answer and the one the deadline would have reached
        // anyway.
        Error(Nil) -> {
          call.cancel()
          unfinished(command, "the sandbox did not settle the check", now)
        }
      }
    }
  }
}

// The requirements for a check process: the session base's own roots,
// mounts and network posture, asked for directly. Composition takes the
// meet of base and requirements, so asking for the base can never widen
// past it — the intersection of a set with itself is itself — and the two
// fields that do move are the wall and the output ceiling.
fn call_spec(
  runner: Runner,
  command: String,
  now: Int,
  timeout_ms: Int,
) -> broker.CallSpec {
  let base = runner.base_policy
  let wall_s = { timeout_ms + 999 } / 1000
  let requirements =
    policy.SandboxPolicy(
      ..base,
      env_allow: list.map(runner.env, fn(pair) { pair.0 }),
      limits: policy.Limits(..base.limits, wall_s:, output_bytes:),
    )

  broker.CallSpec(
    op_id: runner.op_id,
    step_id:,
    base_policy: base,
    requirements:,
    grants: [],
    response: broker.RefuseNarrowed,
    demand: runner.demand,
    // The same invocation the `bash` tool makes, because the check is the
    // command an operator would have typed there: `pipefail` so a failing
    // stage of `go test | tail` is not reported as a passing tail, and no
    // login shell so the host's profile cannot rewrite the PATH the
    // session composed.
    argv: ["bash", "-o", "pipefail", "-c", command],
    env: runner.env,
    cwd: runner.workspace,
    budget: budget.Budget(max_outstanding: 1, deadline_ms: now + timeout_ms),
  )
}

// A settled call as the result the loop records.
//
// A run the wall killed reports no status, because there is none: the
// process was stopped rather than finished, and an exit code invented for
// it would read to the reviewer as the command's own verdict on the work.
// Its output is still carried — unlike a timed-out hook's, which is
// discarded because a decision is parsed out of it, a check's tail is
// evidence a reviewer weighs, and the tail of a build that was killed at
// five minutes is exactly what says why.
fn settled(
  command: String,
  collected: tool.Collected,
  now: Int,
) -> goalstate.CheckResult {
  case collected.outcome {
    broker.CallFailed(failure: _) ->
      unfinished(command, "the sandbox could not run the check", now)

    broker.CallExited(result:) ->
      case result.cancelled || result.timed_out {
        True ->
          goalstate.CheckResult(
            command:,
            ending: goalstate.DidNotFinish(
              reason: "the check was stopped at its wall before it exited",
            ),
            output: captured(collected),
            ran_at_ms: now,
          )

        False ->
          goalstate.CheckResult(
            command:,
            ending: goalstate.Exited(status: result.code),
            output: captured(collected),
            ran_at_ms: now,
          )
      }
  }
}

fn unfinished(
  command: String,
  reason: String,
  now: Int,
) -> goalstate.CheckResult {
  goalstate.CheckResult(
    command:,
    ending: goalstate.DidNotFinish(reason:),
    output: "",
    ran_at_ms: now,
  )
}

// Both streams, each clipped to its own tail and labelled. Labelled
// because a reviewer weighing a failure needs to know which stream said so
// — a warning on stderr beside a zero exit is a different fact from the
// same words on stdout — and an empty stream draws nothing rather than a
// line saying it was empty.
fn captured(collected: tool.Collected) -> String {
  [
    #("stdout", tail(text(collected.stdout))),
    #("stderr", tail(text(collected.stderr))),
  ]
  |> list.filter(fn(stream) { stream.1 != "" })
  |> list.map(fn(stream) { stream.0 <> ":\n" <> stream.1 })
  |> string.join("\n")
}

// The last `output_tail_chars` characters, marked when anything was cut.
//
// Whether the text is longer than the bound is a bounded question, so it is
// answered by dropping the bound rather than by measuring a megabyte: a
// stream that has nothing left after dropping the tail is a stream that fits
// inside it.
fn tail(captured_text: String) -> String {
  case string.drop_end(captured_text, output_tail_chars) {
    "" -> captured_text

    _longer ->
      "(earlier output omitted)\n"
      <> string.slice(captured_text, -output_tail_chars, output_tail_chars)
  }
}

fn text(bytes: BitArray) -> String {
  bytes |> bit_array.to_string |> result.unwrap("")
}

// The broker's own words for a refusal, taken from the rendering the tool
// plane already owns rather than reworded here: an operator who has seen a
// `bash` call refused should read the same sentence when their check is
// refused for the same reason.
fn refused(refusal: broker.Refusal) -> String {
  let rendered = tool.refusal_outcome(refusal)

  case
    list.filter_map(rendered.content, fn(block) {
      case block {
        message.ToolResultText(text: said, ..) -> Ok(said)
        message.ToolResultImage(..) -> Error(Nil)
      }
    })
  {
    [] -> "the sandbox refused the check"
    blocks -> string.join(blocks, " ")
  }
}

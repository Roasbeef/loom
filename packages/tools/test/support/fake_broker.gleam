//// A fake broker seam for the bash/grep suites: a record of functions
//// that captures the `CallSpec` a tool built, replays a scripted event
//// sequence to the tool's events subject, and records stdin/cancel
//// calls — the whole broker contract without a broker.

import broker/broker.{type CallEvent, type CallSpec, type Refusal}
import broker/exec
import broker/framing
import broker/policy
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
import tools/tool.{type Ctx}

/// What a fake call records back to the test.
pub type Recorded {
  /// The spec the tool built.
  Spec(spec: CallSpec)
  /// A stdin chunk the tool sent.
  Stdin(data: BitArray, eof: Bool)
  /// The tool cancelled the call.
  Cancelled
}

/// A `Ctx` whose broker seam replays `script` after recording the spec.
/// The clock is fixed at `now`; the base policy reads the whole
/// filesystem, writes the workspace, and allows `PATH`.
pub fn ctx(
  workspace workspace: String,
  filesystem filesystem: tool.FileSystem,
  now now: Int,
  script script: List(CallEvent),
  recorded recorded: Subject(Recorded),
) -> Ctx {
  base_ctx(workspace, filesystem, now, fn(spec, events) {
    process.send(recorded, Spec(spec:))
    replay(script, events)
    Ok(
      tool.RunningCall(
        stdin: fn(data, eof) { process.send(recorded, Stdin(data:, eof:)) },
        cancel: fn() { process.send(recorded, Cancelled) },
      ),
    )
  })
}

/// A `Ctx` whose broker seam refuses every clearance with `refusal`.
pub fn refusing_ctx(
  workspace workspace: String,
  filesystem filesystem: tool.FileSystem,
  now now: Int,
  refusal refusal: Refusal,
) -> Ctx {
  base_ctx(workspace, filesystem, now, fn(_spec, _events) { Error(refusal) })
}

/// A `Ctx` whose broker seam clears the call but never settles it — for
/// exercising the tool-side settlement window.
pub fn silent_ctx(
  workspace workspace: String,
  filesystem filesystem: tool.FileSystem,
  now now: Int,
  recorded recorded: Subject(Recorded),
) -> Ctx {
  base_ctx(workspace, filesystem, now, fn(spec, _events) {
    process.send(recorded, Spec(spec:))
    Ok(
      tool.RunningCall(
        stdin: fn(data, eof) { process.send(recorded, Stdin(data:, eof:)) },
        cancel: fn() { process.send(recorded, Cancelled) },
      ),
    )
  })
}

fn base_ctx(
  workspace: String,
  filesystem: tool.FileSystem,
  now: Int,
  clear_call: fn(CallSpec, Subject(CallEvent)) ->
    Result(tool.RunningCall, Refusal),
) -> Ctx {
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: now), seed: 7))
  tool.Ctx(
    workspace:,
    op_id:,
    step_id: "step-1",
    source_index: 0,
    strand: "main",
    base_policy: base_policy(workspace),
    grants: [],
    demand: exec.FullEnforcement,
    env: [#("PATH", "/usr/bin:/bin")],
    clock: clock.fixed(at: now),
    filesystem:,
    blob_root: workspace <> "/.blobs",
    clear_call:,
    raise_refusal: tool.no_raise(),
  )
}

/// The fake sessions' base policy: whole filesystem readable, workspace
/// writable, `PATH` allowed — wide enough that the shipped tool
/// requirements compose without narrowing.
pub fn base_policy(workspace: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(workspace),
    readable_roots: ["/"],
    env_allow: ["PATH"],
  )
}

fn replay(script: List(CallEvent), events: Subject(CallEvent)) -> Nil {
  case script {
    [] -> Nil
    [event, ..rest] -> {
      process.send(events, event)
      replay(rest, events)
    }
  }
}

/// A settled successful exit with the given code and byte counts.
pub fn exited(code code: Int, stdout_bytes stdout_bytes: Int) -> CallEvent {
  broker.CallSettled(
    outcome: broker.CallExited(result: exec.ExecResult(
      code:,
      signal: 0,
      stdout_bytes:,
      stderr_bytes: 0,
      stdout_truncated: False,
      stderr_truncated: False,
      enforcement: ["rlimits", "pgroup"],
      degraded: False,
      wall_ms: 5,
      timed_out: False,
      cancelled: False,
    )),
  )
}

/// One stdout chunk.
pub fn stdout(data: String) -> CallEvent {
  broker.CallOutput(
    stream: framing.Stdout,
    data: <<data:utf8>>,
    total_bytes: 0,
    truncated: False,
  )
}

/// One stderr chunk.
pub fn stderr(data: String) -> CallEvent {
  broker.CallOutput(
    stream: framing.Stderr,
    data: <<data:utf8>>,
    total_bytes: 0,
    truncated: False,
  )
}

/// A truncated stdout chunk.
pub fn stdout_truncated(data: String) -> CallEvent {
  broker.CallOutput(
    stream: framing.Stdout,
    data: <<data:utf8>>,
    total_bytes: 0,
    truncated: True,
  )
}

/// A failure settlement.
pub fn failed(failure: exec.ExecFailure) -> CallEvent {
  broker.CallSettled(outcome: broker.CallFailed(failure:))
}

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

/// A `Ctx` that emits one stdout chunk immediately and holds settlement
/// until its returned release subject is signalled. Tests use this to
/// distinguish a live observation from output reported only after a call has
/// finished.
pub fn held_settlement_ctx(
  workspace workspace: String,
  filesystem filesystem: tool.FileSystem,
  now now: Int,
  recorded recorded: Subject(Recorded),
  gate gate: Subject(Subject(Nil)),
) -> Ctx {
  base_ctx(workspace, filesystem, now, fn(spec, events) {
    process.send(recorded, Spec(spec:))
    process.send(events, stdout("still running\n"))

    // Settlement stays unreachable until the test releases it, while the
    // tool's collector remains free to consume and publish the first chunk.
    process.spawn_unlinked(fn() {
      let release = process.new_subject()
      process.send(gate, release)
      let assert Ok(Nil) = process.receive(release, 1000)
        as "the test must release the held settlement"
      process.send(events, exited(code: 0, stdout_bytes: 14))
    })
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
    observe_output: tool.ignore_output(),
  )
}

/// The fake sessions' base policy: the workspace writable, one system
/// region readable and mounted, `PATH` allowed — wide enough that the
/// shipped tool requirements compose without narrowing.
///
/// The region is stated rather than answered with `["/"]`. Under
/// `protocol-change/020` a session base names what a jail may reach, so
/// a fixture that granted the whole host would be testing the tools
/// against a base view nothing ships any more.
pub fn base_policy(workspace: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..policy.workspace_default(workspace),
    readable_roots: [workspace, system_region],
    env_allow: ["PATH"],
    mounts: [
      policy.Mount(
        path: system_region,
        access: policy.MountReadOnly,
        requirement: policy.MountOptional,
      ),
    ],
  )
}

/// The one out-of-workspace region the fake base grants: where a shell's
/// interpreter and system libraries live.
pub const system_region = "/usr"

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

/// A settled exit the helper's cancel ladder stopped, with no wall
/// deadline involved — the shape `protocol-change/006` exists to make
/// sayable, where the code alone is indistinguishable from a clean run.
pub fn cancelled(code code: Int) -> CallEvent {
  broker.CallSettled(
    outcome: broker.CallExited(result: exec.ExecResult(
      code:,
      signal: 0,
      stdout_bytes: 0,
      stderr_bytes: 0,
      stdout_truncated: False,
      stderr_truncated: False,
      enforcement: ["rlimits", "pgroup"],
      degraded: False,
      wall_ms: 5,
      timed_out: False,
      cancelled: True,
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

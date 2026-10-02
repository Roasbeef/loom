//// The two dispatch lanes against the real `loom-exec` helper.
////
//// `lane_equivalence_test` compares the lanes over fakes, which prove the
//// plumbing and nothing about the kernel. This module runs the same four
//// payloads through a broker in each lane over a pool of real helpers, and
//// asserts that the caller sees the same bytes, the same exit and a
//// byte-identical enforcement report. The report is the one that matters:
//// it is ground truth about the jail, and a lane that altered it would be
//// a lane that altered what the caller was told it got.
////
//// Discovery and skip rules follow `integration_test`: the helper is the
//// one `make sandbox` built, a missing one skips with the remedy named, and
//// nothing here compiles a helper of its own. Wall time is the one field
//// not compared, because two real runs never take the same time.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import broker/support/lanes.{type Lane}
import core/clock
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import simplifile

// Locates the prebuilt helper and returns a ready SpawnConfig, or the
// reason to skip.
fn helper_config() -> Result(exec.SpawnConfig, String) {
  case exec.unjailed_skip_reason(exec.host_platform()) {
    Some(reason) -> Error(reason)
    None -> helper_config_here()
  }
}

fn helper_config_here() -> Result(exec.SpawnConfig, String) {
  let assert Ok(here) = simplifile.current_directory()
  let work_dir = here <> "/build/integration"
  let helper_path = here <> "/../sandbox/loom-exec"
  let assert Ok(Nil) = simplifile.create_directory_all(work_dir <> "/work")
  case simplifile.is_file(helper_path) {
    Ok(True) ->
      Ok(exec.SpawnConfig(
        helper_path:,
        shell_path: "/bin/sh",
        base_policy: base_policy(work_dir),
        helper_args: [],
        tmp_dir: work_dir <> "/tmp-lanes",
        handshake_timeout_ms: 5000,
        cancel_grace_ms: 3000,
        heartbeat_interval_ms: 0,
      ))

    _absent_or_unreadable ->
      Error("no loom-exec at " <> helper_path <> "; run `make sandbox`")
  }
}

fn base_policy(work_dir: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: [work_dir <> "/work"],
    readable_roots: ["/"],
    protected: [],
    network: policy.NetworkOff,
    limits: policy.Limits(
      cpu_s: 30,
      wall_s: 60,
      mem_bytes: 536_870_912,
      pids: 64,
      fsize_bytes: 8_388_608,
      output_bytes: 1_048_576,
    ),
    env_allow: ["PATH"],
    scratch: policy.ScratchTmpfs,
    mounts: [],
  )
}

// What a payload does after it starts.
type Drive {
  RunToCompletion
  CancelAfter(ms: Int)
  FeedStdin(text: String)
}

type Payload {
  Payload(name: String, argv: List(String), drive: Drive)
}

fn payloads() -> List(Payload) {
  [
    Payload("true", ["/bin/true"], RunToCompletion),
    Payload(
      "output on both streams and a nonzero exit",
      ["/bin/sh", "-c", "echo hi; echo err >&2; exit 3"],
      RunToCompletion,
    ),
    Payload("a cancelled sleep", ["/bin/sleep", "30"], CancelAfter(ms: 300)),
    Payload("stdin echoed by cat", ["/bin/cat"], FeedStdin(text: "round trip")),
  ]
}

// Everything about a run a caller could act on, except how long it took.
type Observed {
  Observed(
    stdout: BitArray,
    stderr: BitArray,
    code: Int,
    signal: Int,
    stdout_bytes: Int,
    stderr_bytes: Int,
    cancelled: Bool,
    degraded: Bool,
    timed_out: Bool,
    enforcement: List(String),
  )
}

fn run(lane: Lane, config: exec.SpawnConfig, payload: Payload) -> Observed {
  let plane =
    lanes.start(
      lane,
      size: 1,
      spawn: fn() { exec.prepare_helper(config) },
      clock: clock.fixed(at: 1_700_000_000_000),
    )
  let assert Ok(here) = simplifile.current_directory()
  let work_dir = here <> "/build/integration"
  let base = base_policy(work_dir)
  let spec =
    broker.CallSpec(
      op_id: lanes.op(),
      step_id: "lane-" <> payload.name,
      base_policy: base,
      requirements: base,
      grants: [],
      response: broker.RefuseNarrowed,
      demand: exec.BestEffort,
      argv: payload.argv,
      env: [#("PATH", "/usr/bin:/bin")],
      cwd: work_dir <> "/work",
      budget: budget.Budget(max_outstanding: 1, deadline_ms: 0),
    )
  let events = process.new_subject()
  let assert Ok(handle) =
    broker.clear_call(plane.broker, spec, events:, waiting: 10_000)
    as payload.name
  case payload.drive {
    RunToCompletion -> Nil
    CancelAfter(ms:) -> {
      process.sleep(ms)
      broker.cancel(plane.broker, handle)
    }
    FeedStdin(text:) -> {
      broker.stdin(plane.broker, handle, data: <<text:utf8>>, eof: True)
    }
  }
  let seen = lanes.collect(events, within: 15_000)
  lanes.stop(plane)
  observe(payload.name, seen)
}

// Folds a call's events into what the caller learned. A call that did not
// settle as an exit fails the test with its name.
fn observe(name: String, seen: List(broker.CallEvent)) -> Observed {
  let #(stdout, stderr) =
    list.fold(seen, #(<<>>, <<>>), fn(streams, event) {
      case event {
        broker.CallOutput(stream: framing.Stdout, data:, ..) -> #(
          bit_array.append(streams.0, data),
          streams.1,
        )
        broker.CallOutput(stream: framing.Stderr, data:, ..) -> #(
          streams.0,
          bit_array.append(streams.1, data),
        )
        broker.CallSettled(..) -> streams
      }
    })
  let assert Ok(broker.CallSettled(broker.CallExited(result))) = list.last(seen)
    as name
  Observed(
    stdout:,
    stderr:,
    code: result.code,
    signal: result.signal,
    stdout_bytes: result.stdout_bytes,
    stderr_bytes: result.stderr_bytes,
    cancelled: result.cancelled,
    degraded: result.degraded,
    timed_out: result.timed_out,
    enforcement: result.enforcement,
  )
}

/// The same four payloads, through each lane, over real helpers, give the
/// same bytes, the same exit and the same enforcement report. The
/// expectations on the first lane's own result make the comparison mean
/// something: two lanes agreeing on a wrong answer would still fail them.
pub fn real_helper_outcomes_are_identical_in_both_lanes_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP real_helper_outcomes_are_identical: " <> reason)
    Ok(config) ->
      list.each(payloads(), fn(payload) {
        let direct = run(lanes.Direct, config, payload)
        let service = run(lanes.Service, config, payload)
        assert direct == service as payload.name
        assert direct.enforcement != [] as payload.name
        assert expected(payload, direct) as payload.name
      })
  }
}

// What each payload must have done, whichever lane ran it.
fn expected(payload: Payload, observed: Observed) -> Bool {
  case payload.drive {
    CancelAfter(..) -> observed.cancelled && observed.code == 143
    FeedStdin(text:) -> observed.stdout == <<text:utf8>> && observed.code == 0
    RunToCompletion ->
      case payload.argv {
        ["/bin/true"] -> observed.code == 0 && observed.stdout == <<>>
        _ ->
          observed.code == 3
          && observed.stdout == <<"hi\n":utf8>>
          && observed.stderr == <<"err\n":utf8>>
      }
  }
}

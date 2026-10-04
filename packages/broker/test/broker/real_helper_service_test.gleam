//// The executor service against the real `loom-exec` helper.
////
//// `executor_test` and `call_story_test` drive the service over fakes, which
//// prove the plumbing and nothing about the kernel. This module runs four
//// payloads through a broker over a pool of real helpers and asserts that
//// the caller sees the right bytes, the right exit and a non-empty
//// enforcement report. The report is the one that matters: it is ground
//// truth about the jail, and a service that dropped it would be a service
//// that hid what the caller got. The helper's own tests, and `make e2e`,
//// own what the report says; here it only has to arrive.
////
//// Discovery and skip rules follow `integration_test`: the helper is the
//// one `make sandbox` built, a missing one skips with the remedy named, and
//// nothing here compiles a helper of its own. Wall time is not asserted,
//// because two real runs never take the same time.
////
//// Two further tests run the service against the real helper for
//// properties a fake cannot show: that a caller which stops reading cannot
//// slow a cancel, because the helper's own `output_bytes` cap is what
//// bounds the backlog, and that back-to-back runs on a pool of one never
//// meet a helper still busy with the last.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import broker/support/bench_host as host
import broker/support/planes
import core/clock
import gleam/bit_array
import gleam/erlang/process
import gleam/int
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
        tmp_dir: work_dir <> "/tmp-service",
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
    Payload("true", ["/usr/bin/true"], RunToCompletion),
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

fn run(config: exec.SpawnConfig, payload: Payload) -> Observed {
  let plane =
    planes.start(
      size: 1,
      spawn: fn() { exec.prepare_helper(config) },
      clock: clock.fixed(at: 1_700_000_000_000),
    )
  let assert Ok(here) = simplifile.current_directory()
  let work_dir = here <> "/build/integration"
  let base = base_policy(work_dir)
  let spec =
    broker.CallSpec(
      op_id: planes.op(),
      step_id: "real-" <> payload.name,
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
  let seen = planes.collect(events, within: 15_000)
  planes.stop(plane)
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

/// Four payloads, through the service, over real helpers, give the bytes and
/// the exit each of them must produce, and an enforcement report that
/// arrived.
pub fn real_helper_outcomes_are_what_each_payload_produces_test() {
  case helper_config() {
    Error(reason) -> io.println_error("SKIP real_helper_outcomes: " <> reason)
    Ok(config) ->
      list.each(payloads(), fn(payload) {
        let observed = run(config, payload)
        assert observed.enforcement != [] as payload.name
        assert expected(payload, observed) as payload.name
      })
  }
}

// What each payload must have done.
fn expected(payload: Payload, observed: Observed) -> Bool {
  case payload.drive {
    CancelAfter(..) -> observed.cancelled && observed.code == 143
    FeedStdin(text:) -> observed.stdout == <<text:utf8>> && observed.code == 0
    RunToCompletion ->
      case payload.argv {
        ["/usr/bin/true"] -> observed.code == 0 && observed.stdout == <<>>
        _ ->
          observed.code == 3
          && observed.stdout == <<"hi\n":utf8>>
          && observed.stderr == <<"err\n":utf8>>
      }
  }
}

// A real-helper call spec: `argv` under the suite's base policy.
fn real_spec(argv: List(String)) -> broker.CallSpec {
  let assert Ok(here) = simplifile.current_directory()
  let work_dir = here <> "/build/integration"
  let base = base_policy(work_dir)
  broker.CallSpec(
    op_id: planes.op(),
    step_id: "service-real",
    base_policy: base,
    requirements: base,
    grants: [],
    response: broker.RefuseNarrowed,
    demand: exec.BestEffort,
    argv:,
    env: [#("PATH", "/usr/bin:/bin")],
    cwd: work_dir <> "/work",
    budget: budget.Budget(max_outstanding: 1, deadline_ms: 0),
  )
}

// Counts the payload bytes among a call's events and whether the helper
// said it had truncated.
fn payload_of(seen: List(broker.CallEvent)) -> #(Int, Bool) {
  list.fold(seen, #(0, False), fn(total, event) {
    case event {
      broker.CallOutput(data:, truncated:, ..) -> #(
        total.0 + bit_array.byte_size(data),
        total.1 || truncated,
      )
      broker.CallSettled(..) -> total
    }
  })
}

/// A caller that stops reading cannot hold up a cancel. `yes` writes as
/// fast as it is read, the caller reads nothing for two seconds, and then
/// cancels. The relay's delivery is a send to the caller's mailbox and
/// never waits on it, so the cancel settles within a second of being asked
/// whatever the backlog; and the backlog itself is bounded by the helper,
/// whose `output_bytes` cap (one mebibyte here) stops forwarding after that
/// many bytes per stream and says so with a truncated chunk. The BEAM adds
/// no buffer of its own beyond the caller's mailbox, which is the point:
/// the cap is the bound, and it is the helper's.
pub fn a_caller_that_stops_reading_cannot_slow_a_cancel_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP a_caller_that_stops_reading: " <> reason)
    Ok(config) -> {
      let plane =
        planes.start(
          size: 1,
          spawn: fn() { exec.prepare_helper(config) },
          clock: clock.fixed(at: 1_700_000_000_000),
        )
      let events = process.new_subject()
      let assert Ok(handle) =
        broker.clear_call(
          plane.broker,
          real_spec(["/usr/bin/yes"]),
          events:,
          waiting: 10_000,
        )

      // Not one message is read while `yes` writes into the helper's cap.
      process.sleep(2000)
      let asked_at = host.now_us()
      broker.cancel(plane.broker, handle)
      let seen = planes.collect(events, within: 5000)
      let settled_ms = { host.now_us() - asked_at } / 1000

      let assert Ok(broker.CallSettled(broker.CallExited(result))) =
        list.last(seen)
      assert result.cancelled
      assert settled_ms < 1000
        as { "the cancel settled in " <> int.to_string(settled_ms) <> " ms" }

      // At most the cap, plus the framing slack of the chunk that crossed
      // it, ever reached the caller's mailbox; and the helper said so.
      let #(bytes, truncated) = payload_of(seen)
      assert bytes <= 1_048_576 + 65_536
        as { "the mailbox held " <> int.to_string(bytes) <> " bytes" }
      assert bytes >= 1_048_576 / 2
      assert truncated
      planes.stop(plane)
    }
  }
}

/// Twenty `true`s back to back on a pool of one, through the service. Each
/// call is cleared the moment the last one settled, so each finds the one
/// helper either already checked in or, for an instant, not yet; the
/// helper's own distinction between a finished execution and one still
/// being joined means neither is ever `HelperBusy`. A busy helper would be
/// retired and replaced, and would show as a refusal or a different exit.
pub fn twenty_sequential_runs_on_one_real_helper_see_no_busy_window_test() {
  case helper_config() {
    Error(reason) -> io.println_error("SKIP twenty_sequential_runs: " <> reason)
    Ok(config) -> {
      let plane =
        planes.start(
          size: 1,
          spawn: fn() { exec.prepare_helper(config) },
          clock: clock.fixed(at: 1_700_000_000_000),
        )
      list.each(list.repeat(Nil, 20), fn(_run) {
        let events = process.new_subject()
        let assert Ok(_handle) =
          broker.clear_call(
            plane.broker,
            real_spec(["/usr/bin/true"]),
            events:,
            waiting: 10_000,
          )
        let assert [broker.CallSettled(broker.CallExited(result))] =
          planes.collect(events, within: 10_000)
        assert result.code == 0
      })
      planes.stop(plane)
    }
  }
}

/// The production wire lease also bounds an unread consumer. This reaches the
/// real helper through broker clearance with the actual session lease policy,
/// then proves truncation and prompt cancellation without reading while it runs.
pub fn a_wire_lease_bounds_a_nonreading_consumer_test() {
  case helper_config() {
    Error(reason) -> io.println_error("SKIP wire_lease_nonreading: " <> reason)
    Ok(config) -> {
      let lease = policy.session_lease(config.base_policy, policy.OutputIsWire)
      let plane =
        planes.start(
          size: 1,
          spawn: fn() {
            exec.prepare_helper(exec.SpawnConfig(..config, base_policy: lease))
          },
          clock: clock.fixed(at: 1_700_000_000_000),
        )
      let events = process.new_subject()
      let original = real_spec(["/usr/bin/yes"])
      let spec =
        broker.CallSpec(..original, base_policy: lease, requirements: lease)
      let assert Ok(handle) =
        broker.clear_call(plane.broker, spec, events:, waiting: 10_000)
        as "the finite wire lease must clear"

      // The consumer is deliberately idle while the native producer reaches
      // its cumulative allowance. Cancellation uses its independent channel.
      process.sleep(2000)
      let asked_at = host.now_us()
      broker.cancel(plane.broker, handle)
      let seen = planes.collect(events, within: 5000)
      let settled_ms = { host.now_us() - asked_at } / 1000
      let assert Ok(broker.CallSettled(broker.CallExited(result))) =
        list.last(seen)
        as "the native call must settle after cancellation"
      assert result.cancelled
      assert settled_ms < 1000
        as { "wire cancel settled in " <> int.to_string(settled_ms) <> " ms" }

      let #(bytes, truncated) = payload_of(seen)
      assert bytes <= lease.limits.output_bytes
        as { "wire mailbox held " <> int.to_string(bytes) <> " bytes" }
      assert truncated as "the flood must cross the actual wire quota"
      planes.stop(plane)
    }
  }
}

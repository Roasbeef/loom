//// Feature-detected integration suite: drives the real `loom-exec`
//// helper, as `make sandbox` built it, through the exec pool —
//// handshake over the fd-3 shell trick, an echo run, a stdin
//// roundtrip, a cancel mid-sleep, and output truncation. Skipped (with
//// the reason printed) when the helper has not been built.
////
//// The development container usually lacks bwrap, so the helper runs
//// degraded; executions use `BestEffort` and assert on the honest
//// enforcement report rather than demanding a jail the kernel cannot
//// provide here.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/internal/ffi_os
import broker/policy
import broker/support/bench_host as host
import broker/token
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import weft/poll

// Locates the prebuilt helper and returns a ready SpawnConfig, or the
// reason to skip.
fn helper_config() -> Result(exec.SpawnConfig, String) {
  case exec.unjailed_skip_reason(exec.host_platform()) {
    Some(reason) -> Error(reason)
    None -> helper_config_here()
  }
}

// Every test in this suite runs the helper `make sandbox` built, at the
// path the Makefile names, and none compiles one itself. Each test used to
// run its own `go build`, so a parallel run started several at once, beside
// the other packages' real-helper suites doing the same. On the
// containerised signoff some of those builds read a Go build-cache object
// that was zero from some offset on and failed to link, and each failure
// became an undeclared skip. With the one build before any test starts, no
// test process writes the Go cache and no test replaces a binary a sibling
// is executing. `make check`, `make test` and `make e2e` build the helper
// first; a run without it skips with the remedy named, and the skip census
// counts that skip as a failure.
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
        tmp_dir: work_dir <> "/tmp",
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

fn with_real_helper(name: String, run: fn(exec.Helper) -> Nil) -> Nil {
  case helper_config() {
    Error(reason) -> io.println_error("SKIP " <> name <> ": " <> reason)
    Ok(config) ->
      case exec.spawn_helper(config) {
        Error(spawn_error) ->
          panic as {
            name <> ": helper failed to spawn: " <> string.inspect(spawn_error)
          }
        Ok(helper) -> {
          run(helper)
          exec.shutdown(helper)
        }
      }
  }
}

fn request(argv: List(String), output_bytes: Int) -> exec.ExecRequest {
  let assert Ok(here) = simplifile.current_directory()
  let work_dir = here <> "/build/integration"
  let base = base_policy(work_dir)
  let limits = policy.Limits(..base.limits, output_bytes:)
  exec.ExecRequest(
    argv:,
    env: [#("PATH", "/usr/bin:/bin")],
    cwd: work_dir <> "/work",
    policy: Some(policy.SandboxPolicy(..base, limits:)),
    token: <<0:size(31)-unit(8), 9>>,
    demand: exec.BestEffort,
  )
}

pub fn real_helper_handshake_test() {
  use helper <- with_real_helper("real_helper_handshake")
  let assert exec.StatusReady(features) = exec.status(helper, waiting: 1000)
  // The helper always reports rlimits + pgroup; the rest depends on
  // the kernel we run on. Whatever it says, it said something.
  assert features != []
  assert exec.heartbeat(helper, waiting: 2000) == Ok(Nil)
}

pub fn real_helper_orderly_idle_retirement_test() {
  use helper <- with_real_helper("real_helper_orderly_idle_retirement")
  assert exec.close(helper, waiting: 5000) == Ok(Nil)
  assert !process.is_alive(exec.pid(helper))
}

pub fn real_helper_orderly_running_retirement_test() {
  use helper <- with_real_helper("real_helper_orderly_running_retirement")
  let events = process.new_subject()
  let req =
    request(
      ["/bin/sh", "-c", "trap '' TERM; printf ready; while :; do sleep 1; done"],
      1024,
    )
  assert exec.run(helper, req, events:, waiting: 1000) == Ok(Nil)
  let assert Ok(exec.Output(data: <<"ready":utf8>>, ..)) =
    process.receive(events, 5000)
    as "jailed payload is running before shutdown"
  assert exec.close(helper, waiting: 5000) == Ok(Nil)
  assert !process.is_alive(exec.pid(helper))
}

pub fn real_pool_orderly_borrowed_retirement_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP real_pool_orderly_borrowed_retirement: " <> reason)
    Ok(config) -> {
      let assert Ok(pool) =
        exec.start_pool(size: 2, spawn: fn() { exec.prepare_helper(config) })
        as "native pool starts"
      let assert Ok(idle) = exec.checkout(pool, waiting: 5000)
        as "idle native helper"
      let assert Ok(borrowed) = exec.checkout(pool, waiting: 5000)
        as "borrowed native helper"
      exec.checkin(pool, idle)
      let events = process.new_subject()
      let req =
        request(
          [
            "/bin/sh", "-c",
            "trap '' TERM; printf ready; while :; do sleep 1; done",
          ],
          1024,
        )
      assert exec.run(borrowed, req, events:, waiting: 1000) == Ok(Nil)
      let assert Ok(exec.Output(data: <<"ready":utf8>>, ..)) =
        process.receive(events, 5000)
        as "borrowed jail is running before pool drain"
      assert exec.close_pool(pool, waiting: 5000) == Ok(Nil)
      assert !process.is_alive(exec.pid(idle))
      assert !process.is_alive(exec.pid(borrowed))
      assert !process.is_alive(exec.pool_pid(pool))
    }
  }
}

pub fn real_helper_echo_test() {
  use helper <- with_real_helper("real_helper_echo")
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(
      helper,
      request(["/bin/echo", "hello"], 1_048_576),
      events:,
      waiting: 3000,
    )
  let assert Ok(result) = collect_exit(events, <<>>, 15_000)
  let #(stdout, exit) = result
  assert stdout == <<"hello\n":utf8>>
  assert exit.code == 0
  assert exit.signal == 0
  // Ground truth about what was enforced came back with the exit.
  assert exit.enforcement != []
}

pub fn real_helper_stdin_roundtrip_test() {
  use helper <- with_real_helper("real_helper_stdin")
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(["/bin/cat"], 1_048_576), events:, waiting: 3000)
  exec.stdin(helper, data: <<"round ">>, eof: False)
  exec.stdin(helper, data: <<"trip">>, eof: True)
  let assert Ok(#(stdout, exit)) = collect_exit(events, <<>>, 15_000)
  assert stdout == <<"round trip":utf8>>
  assert exit.code == 0
}

pub fn real_helper_cancel_mid_sleep_test() {
  use helper <- with_real_helper("real_helper_cancel")
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(
      helper,
      request(["/bin/sleep", "30"], 1_048_576),
      events:,
      waiting: 3000,
    )
  // Give the child a moment to start, then cancel. `/bin/sleep` takes
  // TERM at its default disposition, so the first rung of the ladder is
  // what ends it and the exit must say so.
  process.sleep(200)
  exec.cancel(helper)
  let assert Ok(#(_stdout, exit)) = collect_exit(events, <<>>, 15_000)
  // The property, not the byte.
  //
  // `code == 143` was a real tightening over `signal != 0` — that claim
  // stands — but it is an assertion about a byte that at least three
  // distinct causes produce: a payload that took the TERM; a jailed
  // payload whose bwrap supervisor relays 128+15 by exiting it; and
  // `sh -c 'exit 143'`, with no cancel involved at all. It is also not
  // the byte a cancelled run always carries: with the payload's work
  // backgrounded, a forcibly truncated execution reported `code=0
  // signal=0` — a clean success — in 3 of 3 measured runs (#53).
  //
  // `cancelled` is the property. The helper is the only party that knows
  // it stopped the execution rather than watching it end, and since
  // protocol-change/006 the frame says so. The exit status is still
  // checked, but as a detail of *this* payload — `/bin/sleep` takes TERM
  // at its default disposition — rather than as the evidence.
  assert exit.cancelled == True
  assert exit.code == 143
  assert exit.signal == 0 || exit.signal == 15
}

// The other half of the same claim: an ordinary run must not report
// itself cancelled, and a payload that simply *exits* 143 must not be
// mistaken for one that was TERMed. Without this, asserting `cancelled`
// above would be satisfied by a helper that sets the flag on everything.
pub fn real_helper_uncancelled_exit_143_is_not_a_cancel_test() {
  use helper <- with_real_helper("real_helper_uncancelled_143")
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(
      helper,
      request(["/bin/sh", "-c", "exit 143"], 1_048_576),
      events:,
      waiting: 3000,
    )
  let assert Ok(#(_stdout, exit)) = collect_exit(events, <<>>, 15_000)
  assert exit.code == 143
  assert exit.cancelled == False
}

pub fn real_helper_output_truncation_test() {
  use helper <- with_real_helper("real_helper_truncation")
  let events = process.new_subject()
  // ~200KB of output against a 4096-byte per-stream cap.
  let flood =
    "i=0; while [ $i -lt 2000 ]; do echo 0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789; i=$((i+1)); done"
  let assert Ok(Nil) =
    exec.run(
      helper,
      request(["/bin/sh", "-c", flood], 4096),
      events:,
      waiting: 3000,
    )
  let assert Ok(#(stdout, exit)) = collect_exit(events, <<>>, 30_000)
  assert exit.stdout_truncated == True
  // The stream stopped at the cap even though the child kept writing.
  assert bit_array.byte_size(stdout) <= 4096
  assert exit.stdout_bytes <= 4096
}

// Accumulates stdout until the terminal event arrives.
fn collect_exit(
  events: process.Subject(exec.ExecEvent),
  stdout: BitArray,
  timeout: Int,
) -> Result(#(BitArray, exec.ExecResult), Nil) {
  case process.receive(events, timeout) {
    Ok(exec.Output(stream: framing.Stdout, data:, ..)) ->
      collect_exit(events, bit_array.append(stdout, data), timeout)
    Ok(exec.Output(stream: framing.Stderr, ..)) ->
      collect_exit(events, stdout, timeout)
    Ok(exec.Exited(result:)) -> Ok(#(stdout, result))
    Ok(exec.Failed(_)) -> Error(Nil)
    Error(Nil) -> Error(Nil)
  }
}

// The temp policy file must be unlinked once the helper says hello.
//
// The proof is that the spawn's tmp directory holds nothing afterwards,
// which is only a statement about this spawn's own file if no other
// helper writes there. Every other test in the suite spawns through the
// shared `tmp_dir`, so this one is given a directory of its own and
// starts by emptying it: the listing then names this spawn's policy file
// or nothing at all, whatever else the suite is doing at the same time.
pub fn real_helper_policy_file_unlinked_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP real_helper_policy_file_unlinked: " <> reason)
    Ok(shared) -> {
      let tmp_dir = shared.tmp_dir <> "-policy-unlink"
      let _ = simplifile.delete(tmp_dir)
      let assert Ok(Nil) = simplifile.create_directory_all(tmp_dir)
      let config = exec.SpawnConfig(..shared, tmp_dir:)
      let assert Ok(helper) = exec.spawn_helper(config)
        as "the helper must spawn from its own tmp directory"
      let assert Ok(entries) = simplifile.read_directory(tmp_dir)
      exec.shutdown(helper)
      assert entries == []
    }
  }
}

// `helper_args` must actually reach the helper's command line, through
// the shell that opens fd 3 for it. A flag the helper does not know
// makes it exit before the handshake, which nothing else in this suite
// can cause — so a successful spawn here would mean the arguments were
// dropped on the way.
pub fn helper_args_reach_the_helper_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP helper_args_reach_the_helper: " <> reason)
    Ok(config) -> {
      let bogus = exec.SpawnConfig(..config, helper_args: ["--not-a-real-flag"])
      let assert Error(_spawn_error) = exec.spawn_helper(bogus)
        as "an argument the helper rejects must fail the spawn; a success
means the extra arguments never reached its command line"
      Nil
    }
  }
}

// The flag a host on an unjailed platform would pass is accepted by a
// helper that does have a jail, and changes nothing about what it
// enforces. Linux is the only place this can be checked at all.
pub fn allow_unenforced_arg_is_harmless_where_a_jail_exists_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP allow_unenforced_arg_is_harmless: " <> reason)
    Ok(config) -> {
      let args = exec.unenforced_helper_args(exec.host_platform())
      // On a jailed host there is nothing to pass, so pass it anyway:
      // the flag must be accepted and inert, not a way to opt out of
      // enforcement on a platform that has some.
      assert args == []
      let opted =
        exec.SpawnConfig(..config, helper_args: ["--allow-unenforced"])
      let assert Ok(helper) = exec.spawn_helper(opted)
      let assert exec.StatusReady(features) = exec.status(helper, waiting: 1000)
      assert !list.contains(features, "platform-unsupported")
      exec.shutdown(helper)
    }
  }
}

// The honesty contract for resource ceilings: a policy that asks for
// `mem_bytes` or `pids` gets back either the platform's applied mechanism
// or a `skip:` naming it. Silence would let exactly this policy satisfy a
// `FullEnforcement` demand with neither ceiling in place.
pub fn cgroup_ceiling_is_never_silently_dropped_test() {
  use helper <- with_real_helper("cgroup_ceiling_is_never_silently_dropped")
  let events = process.new_subject()
  let assert Ok(here) = simplifile.current_directory()
  let work_dir = here <> "/build/integration"
  let base = base_policy(work_dir)
  // Both ceilings demanded, explicitly.
  let limits = policy.Limits(..base.limits, mem_bytes: 268_435_456, pids: 16)
  let req =
    exec.ExecRequest(
      argv: ["/bin/echo", "ok"],
      env: [#("PATH", "/usr/bin:/bin")],
      cwd: work_dir <> "/work",
      policy: Some(policy.SandboxPolicy(..base, limits:)),
      token: <<0:size(31)-unit(8), 9>>,
      demand: exec.BestEffort,
    )
  let assert Ok(Nil) = exec.run(helper, req, events:, waiting: 3000)
  let assert Ok(#(_stdout, exit)) = collect_exit(events, <<>>, 15_000)
  case ffi_os.os_name() {
    "darwin" -> {
      assert layer_applied_or_skipped(exit, "rlimit-address-space")
      assert layer_applied_or_skipped(exit, "rlimit-processes")
    }
    _ -> {
      assert layer_applied_or_skipped(exit, "cgroup-v2")
    }
  }
}

fn layer_applied_or_skipped(result: exec.ExecResult, layer: String) -> Bool {
  let applied = list.contains(result.enforcement, layer)
  let skipped =
    list.any(result.enforcement, fn(entry) {
      string.starts_with(entry, "skip:" <> layer)
    })
  applied != skipped
}

// The honesty patch's headline claim, end to end through the real
// helper: a `FullEnforcement` demand for ceilings this host cannot hold
// must refuse, never quietly succeed.
//
// Both refusals are correct and which one arrives depends on the
// machine — a helper with no bwrap is refused at dispatch from its hello
// features, and a helper that looked healthy is refused on the
// `skip:cgroup-v2` entry in its exec_exit. What must never happen is an
// `Exited`: that is the result silently accepting two unenforced
// ceilings, which is exactly what happened before the helper learned to
// report the gap.
pub fn full_enforcement_never_accepts_unenforced_ceilings_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error(
        "SKIP full_enforcement_never_accepts_unenforced_ceilings: " <> reason,
      )
    Ok(config) -> {
      let assert Ok(helper) = exec.spawn_helper(config)
      let events = process.new_subject()
      let assert Ok(here) = simplifile.current_directory()
      let work_dir = here <> "/build/integration"
      let base = base_policy(work_dir)
      let limits =
        policy.Limits(..base.limits, mem_bytes: 268_435_456, pids: 16)
      let req =
        exec.ExecRequest(
          argv: ["/bin/echo", "ok"],
          env: [#("PATH", "/usr/bin:/bin")],
          cwd: work_dir <> "/work",
          policy: Some(policy.SandboxPolicy(..base, limits:)),
          token: <<0:size(31)-unit(8), 9>>,
          demand: exec.FullEnforcement,
        )
      case exec.run(helper, req, events:, waiting: 3000) {
        // Refused before dispatch: the helper advertised degradation.
        Error(exec.DegradedHelper(_features)) -> Nil
        Error(other) ->
          panic as { "unexpected dispatch failure: " <> string.inspect(other) }
        Ok(Nil) ->
          case collect_settled(events, 15_000) {
            Error(Nil) -> panic as "no terminal event arrived"
            // Refused on ground truth. The refusal alone is not the claim:
            // on a host missing some other layer this result would be
            // refused anyway, and the resource gap would still be invisible.
            // Insist the report names the platform mechanism.
            Ok(exec.Failed(exec.DegradedExecution(result))) -> {
              case ffi_os.os_name() {
                "darwin" -> {
                  assert layer_applied_or_skipped(
                    result,
                    "rlimit-address-space",
                  )
                  assert layer_applied_or_skipped(result, "rlimit-processes")
                }
                _ -> {
                  assert layer_applied_or_skipped(result, "cgroup-v2")
                }
              }
              Nil
            }
            Ok(exec.Failed(other)) ->
              panic as { "unexpected failure: " <> string.inspect(other) }
            Ok(exec.Exited(result)) -> {
              // Darwin always reports its lifecycle gap, so strict execution
              // can never legitimately exit without a degradation refusal.
              case ffi_os.os_name() {
                "darwin" ->
                  panic as {
                    "Darwin strict execution ignored its mandatory lifecycle skip: "
                    <> string.inspect(result)
                  }
                _ -> {
                  assert list.contains(result.enforcement, "cgroup-v2")
                }
              }
              Nil
            }
            Ok(exec.Output(..)) -> panic as "unreachable"
          }
      }
      exec.shutdown(helper)
    }
  }
}

// Drains output and returns the terminal event.
fn collect_settled(
  events: process.Subject(exec.ExecEvent),
  timeout: Int,
) -> Result(exec.ExecEvent, Nil) {
  case process.receive(events, timeout) {
    Ok(exec.Output(..)) -> collect_settled(events, timeout)
    Ok(event) -> Ok(event)
    Error(Nil) -> Error(Nil)
  }
}

// One second is the finite control wall. The explicitly granted zero wall
// must still be live after that interval, then settle through cancellation.
pub fn real_broker_session_lifetime_remains_jailed_and_cancellable_test() {
  use helper <- with_real_helper("real_broker_session_lifetime")
  let assert Ok(here) = simplifile.current_directory()
    as "the fixture workspace exists"
  let workspace = here <> "/build/integration"
  let base = base_policy(workspace)
  let base =
    policy.SandboxPolicy(
      ..base,
      limits: policy.Limits(..base.limits, wall_s: 1),
    )
  let wanted =
    policy.SandboxPolicy(
      ..base,
      limits: policy.Limits(..base.limits, wall_s: 0),
    )
  let time = clock.fixed(at: 1_700_000_000_000)
  let #(operation, _) = ids.mint_op(ids.generator(time, seed: 11))
  let returned = process.new_subject()
  let assert Ok(owner) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: time,
        checkout: fn() { Ok(helper) },
        checkin: fn(helper) { process.send(returned, helper) },
      ),
    )
    as "the real-helper broker starts"
  let events = process.new_subject()
  let spec =
    broker.CallSpec(
      op_id: operation,
      step_id: "session-watch",
      base_policy: base,
      requirements: wanted,
      grants: [],
      response: broker.RefuseNarrowed,
      demand: exec.BestEffort,
      argv: ["/bin/sleep", "30"],
      env: [#("PATH", "/usr/bin:/bin")],
      cwd: workspace <> "/work",
      budget: budget.Budget(max_outstanding: 1, deadline_ms: 0),
    )
  let assert Error(broker.PolicyRefused(..)) =
    broker.clear_call(owner, spec, events:, waiting: 2000)
    as "finite base authority refuses session lifetime before dispatch"
  let assert Ok(handle) =
    broker.clear_call(
      owner,
      broker.CallSpec(..spec, grants: [policy.GrantLimit(policy.WallSeconds, 0)]),
      events:,
      waiting: 3000,
    )
    as "explicit wall authority launches the jailed watcher"
  assert process.receive(events, 1200) == Error(Nil)
  broker.cancel(owner, handle)
  let assert Ok(broker.CallSettled(broker.CallExited(exit))) =
    process.receive(events, 5000)
    as "the real helper acknowledges cancellation"
  assert exit.cancelled
  assert exit.enforcement != []
  let assert Ok(_helper) = process.receive(returned, 2000)
    as "settlement returns the helper"
  broker.stop(owner)
}

// Accumulates stdout until the terminal event, keeping the event itself so
// a test can tell an exit from an in-band failure.
fn collect_terminal(
  events: process.Subject(exec.ExecEvent),
  stdout: BitArray,
  timeout: Int,
) -> #(BitArray, Result(exec.ExecEvent, Nil)) {
  case process.receive(events, timeout) {
    Ok(exec.Output(stream: framing.Stdout, data:, ..)) ->
      collect_terminal(events, bit_array.append(stdout, data), timeout)
    Ok(exec.Output(stream: framing.Stderr, ..)) ->
      collect_terminal(events, stdout, timeout)
    Ok(terminal) -> #(stdout, Ok(terminal))
    Error(Nil) -> #(stdout, Error(Nil))
  }
}

// A refused stdin write is answered by the helper with `error{no_exec}`
// carrying the stdin frame's id. That error is about the *write*, not about
// the execution, so it must not settle the execution: the payload is still
// running and its real `exec_exit` is still owed. Before stdin frames had
// ids of their own the error carried the execution's id, `settle` took it
// for the execution's own refusal, and the machine went `Idle` with the
// payload alive in the helper, so the next `Run` got a Go `busy`.
//
// The refusal is provoked by writing after end of file. The payload also
// closes its own stdin, which is the shape the report described, but under
// bwrap the jail's supervisor keeps the pipe's read end open, so that alone
// does not fail the helper's write; the second send after `eof` does, on
// every platform.
pub fn real_helper_stdin_error_does_not_settle_execution_test() {
  use helper <- with_real_helper("real_helper_stdin_error")
  let events = process.new_subject()
  let req =
    request(
      ["/bin/sh", "-c", "exec 0<&-; echo closed; sleep 2; echo done"],
      1024,
    )
  assert exec.run(helper, req, events:, waiting: 3000) == Ok(Nil)
  let assert Ok(exec.Output(data: <<"closed\n":utf8>>, ..)) =
    process.receive(events, 5000)
    as "the payload has closed its stdin before any is sent"

  // The first send closes the helper's side of the pipe; the second is
  // refused. Spaced, so the refusal is read while the payload still runs.
  exec.stdin(helper, data: <<"first">>, eof: True)
  process.sleep(100)
  exec.stdin(helper, data: <<"second">>, eof: False)
  let #(stdout, terminal) = collect_terminal(events, <<>>, 10_000)
  let assert Ok(exec.Exited(exit)) = terminal
    as "the execution settles by its own exit, not by the stdin refusal"
  assert exit.code == 0
  assert stdout == <<"done\n":utf8>>
}

// The marker in the payload's argv, which is how a leftover is recognised in
// native process metadata. Nothing else on this host sleeps for this long.
const kill_marker = "300.75"

// A helper that cannot act on a cancel is killed by the broker, and that kill
// must keep its proof. The helper is stopped with SIGSTOP, so the cancel goes
// unanswered, the grace expires, and the machine settles `CancelEscalated`.
// Before the kill was witnessed, the port was closed ahead of the SIGKILL, no
// exit status could be selected, and the slot became `Unconfirmed` for good,
// although the jail had died with its helper all the same.
//
// This is the disproof of the ruling as much as its test. The claim is that a
// SIGKILLed helper under bwrap takes its jail with it, so the retained port's
// `exit_status` is enough evidence. If the marked payload survived the kill,
// the ruling would be wrong and the slot would have to stay unconfirmed.
// Darwin has no such kernel guarantee: its existing non-bwrap arm instead
// proves the conservative refusal and retained custody, never jail teardown.
pub fn real_helper_witnessed_kill_retires_a_stopped_helper_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP real_helper_witnessed_kill: " <> reason)
    Ok(shared) -> {
      // The helper is stopped, so the grace only has to pass, not to be a
      // useful interval for it.
      let config = exec.SpawnConfig(..shared, cancel_grace_ms: 500)
      let baseline = host.helper_os_pids()
      let original_ports = host.port_os_pids()
      let assert Ok(pool) =
        exec.start_pool(size: 1, spawn: fn() { exec.prepare_helper(config) })
        as "native pool starts"
      let assert Ok(helper) = exec.checkout(pool, waiting: 5000)
        as "native helper lent"
      let assert exec.StatusReady(features) = exec.status(helper, waiting: 1000)
      let jailed = list.contains(features, "bwrap")
      let assert [victim] =
        list.filter(host.port_os_pids(), fn(pid) {
          !list.contains(original_ports, pid)
        })
        as "the original helper owns exactly one new native port"

      let events = process.new_subject()
      let req =
        request(
          [
            "/bin/sh",
            "-c",
            "trap \"\" TERM; echo ready; sleep " <> kill_marker,
          ],
          1024,
        )
      assert exec.run(helper, req, events:, waiting: 3000) == Ok(Nil)
      let assert Ok(exec.Output(data: <<"ready\n":utf8>>, ..)) =
        process.receive(events, 5000)
        as "the payload ignores TERM and is running"

      // The port's OS pid must be the helper and not the shell that opened
      // fd 3 for it, or the SIGKILL below would not be addressed to it.
      assert host.busy_helper_os_pid(exclude: baseline) == Ok(victim)
      let assert [#(_, "loom-exec", _), ..] = host.proc_tree(victim)
        as "the port's pid is the exec'd helper itself"
      host.signal(victim, "STOP")
      exec.cancel(helper)
      assert process.receive(events, 5000)
        == Ok(exec.Failed(exec.CancelEscalated))

      // Under bwrap the jail dies with its helper. Without it nothing
      // promises that, so the leftover is ours to reap and not to assert on.
      case jailed {
        True -> {
          let assert poll.Answered(Nil) =
            poll.until(within: 1000, every: 20, attempt: fn() {
              case host.census([kill_marker]) {
                [] -> poll.Done(Nil)
                _survivors -> poll.Retry
              }
            })
            as "no process carrying the payload's marker survives the kill"
          Nil
        }
        False ->
          list.each(host.census([kill_marker]), fn(entry) {
            host.signal(entry.0, "KILL")
          })
      }

      // The pool takes the dead helper back, retires it on the exit status
      // the kill produced, and lends a replacement before it is closed.
      exec.checkin(pool, helper)
      case jailed {
        True -> {
          let assert poll.Answered(replacement) =
            poll.until(within: 5000, every: 20, attempt: fn() {
              case exec.checkout(pool, waiting: 5000) {
                Ok(next) -> poll.Done(next)
                Error(exec.AllBusy(..)) -> poll.Retry
                Error(other) -> poll.Fail(other)
              }
            })
            as "the killed helper's slot is lent again"
          assert exec.pid(replacement) != exec.pid(helper)
          exec.checkin(pool, replacement)
          assert exec.close_pool(pool, waiting: 5000) == Ok(Nil)
        }

        // Nothing promises the jail died with the helper, so the slot stays
        // unconfirmed, and the exit status is what says so.
        False -> {
          assert exec.close_pool(pool, waiting: 5000)
            == Error(exec.RetirementExit(137))
          let assert Ok(custody) = exec.pool_custody(pool, waiting: 1000)
            as "the original owner's unconfirmed custody remains inspectable"
          let assert [view] = custody.helpers as "the original slot is retained"
          assert view.pid == exec.pid(helper)
          assert view.custody
            == exec.CleanupUnconfirmed(exec.RetirementExit(137))
          assert exec.checkout(pool, waiting: 1000)
            == Error(exec.PoolUnavailable)
        }
      }
    }
  }
}

// How long after the broker knows a killed helper is retired its payload may
// still be writing. The claim the witnessed kill makes is that the kernel has
// already begun killing the jail when the exit status is selected, so the
// payload gets a couple of scheduler wakeups and a namespace teardown at most.
// A tenth of a second is far above both and far below anything a replacement
// session could do with the freed slot.
const ordering_slack_ns = 100_000_000

// The ordering half of the disproof. The payload appends the wall clock to a
// file in a writable root as fast as `date` forks; the helper is stopped, the
// cancel goes unanswered, and the broker kills it. The instant `close` answers
// `Ok` is the instant the broker would release custody, so no timestamp the
// payload wrote after that instant, plus the slack, may exist. A line later
// than that would mean the jail outlived the verdict and the slot must stay
// unconfirmed. The measured lag is printed so a reader can see the margin.
// Darwin runs the existing non-bwrap refusal arm. Its writer records activity
// because BSD date has no nanosecond format; those bytes make no timing or
// descendant-death claim, and RetirementExit(137) must retain custody.
pub fn real_helper_kill_verdict_precedes_no_late_payload_write_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP real_helper_kill_ordering: " <> reason)
    Ok(shared) -> {
      let config = exec.SpawnConfig(..shared, cancel_grace_ms: 500)
      let baseline = host.helper_os_pids()
      let original_ports = host.port_os_pids()
      let assert Ok(helper) = exec.spawn_helper(config)
        as "native helper spawns"
      let assert exec.StatusReady(features) = exec.status(helper, waiting: 1000)
      let assert [victim] =
        list.filter(host.port_os_pids(), fn(pid) {
          !list.contains(original_ports, pid)
        })
        as "the original helper owns exactly one new native port"
      let assert Ok(here) = simplifile.current_directory()
      let log = here <> "/build/integration/work/ordering-" <> unique_name()
      let _ = simplifile.delete(log)
      let writing = case ffi_os.os_name() {
        "darwin" ->
          "trap '' TERM; while :; do echo active >> "
          <> log
          <> "; sleep 0.02; done"
        _linux_or_unsupported ->
          "trap '' TERM; while :; do date +%s%N >> " <> log <> "; done"
      }

      let events = process.new_subject()
      let req = request(["/bin/sh", "-c", writing], 1024)
      assert exec.run(helper, req, events:, waiting: 3000) == Ok(Nil)
      let assert poll.Answered(Nil) =
        poll.until(within: 3000, every: 20, attempt: fn() {
          case simplifile.read(log) {
            Ok(text) ->
              case list.length(string.split(text, "\n")) > 5 {
                True -> poll.Done(Nil)
                False -> poll.Retry
              }
            Error(_) -> poll.Retry
          }
        })
        as "the payload is writing inside the jail"

      assert host.busy_helper_os_pid(exclude: baseline) == Ok(victim)
      host.signal(victim, "STOP")
      exec.cancel(helper)
      assert process.receive(events, 5000)
        == Ok(exec.Failed(exec.CancelEscalated))

      let verdict = exec.close(helper, waiting: 5000)
      let witnessed = host.system_time_ns()
      process.sleep(500)
      let assert Ok(text) = simplifile.read(log) as "the payload's write log"
      let latest =
        string.split(text, "\n")
        |> list.filter_map(int.parse)
        |> list.fold(0, int.max)
      let lag = latest - witnessed
      case list.contains(features, "bwrap") {
        True -> {
          io.println_error(
            "kill_ordering: latest payload write "
            <> int.to_string(lag / 1000)
            <> " us after the verdict (negative is before)",
          )
          assert verdict == Ok(Nil)
          assert latest > 0
          assert lag <= ordering_slack_ns
        }
        False -> {
          assert verdict == Error(exec.RetirementExit(137))
          list.each(host.census([log]), fn(entry) {
            host.signal(entry.0, "KILL")
          })
        }
      }
    }
  }
}

fn unique_name() -> String {
  int.to_string(host.unique()) <> ".log"
}

// A write that fails after the helper died on its own finds the exit status
// already queued behind it. A port delivers `{exit_status, S}` and only then
// closes, so the order inside the actor's mailbox is the helper's death, the
// caller's heartbeat request, and the status; but the actor reads the
// request first because the test queued it first. To fix that order on a real
// port, the actor is suspended, the request is queued, the helper is killed
// from outside, and the port is given time to close with its status
// delivered. Resuming then makes the actor write to a closed port with the
// status next in line.
//
// The status must not be thrown away with the failed write. The helper was
// idle, so its death left no jail and the status retires it. A `mark_gone`
// that records `LostExit` at once leaves the pool slot unconfirmed for the
// life of the session and blocks the session's writer lease.
pub fn real_helper_failed_write_keeps_a_queued_status_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP real_helper_failed_write_keeps: " <> reason)
    Ok(config) -> {
      let before = host.port_os_pids()
      let assert Ok(helper) = exec.spawn_helper(config)
        as "native helper spawns"
      let assert [victim] =
        list.filter(host.port_os_pids(), fn(pid) { !list.contains(before, pid) })
        as "one new helper port"
      let assert Ok(actor) = process.subject_owner(exec.wire(helper))
        as "the wire subject belongs to the helper actor"

      host.suspend(actor)
      let answers = process.new_subject()
      process.spawn_unlinked(fn() {
        process.send(answers, exec.heartbeat(helper, waiting: 5000))
      })

      // The request must be in the suspended actor's mailbox before the
      // helper dies, so that the exit status queues behind it and the write
      // fails with the status already waiting. Polling the mailbox and then
      // the port list states both orderings instead of guessing at them.
      let assert poll.Answered(Nil) =
        poll.until(within: 5000, every: 10, attempt: fn() {
          case host.queued(actor) >= 1 {
            True -> poll.Done(Nil)
            False -> poll.Retry
          }
        })
        as "the request is queued behind the suspension"
      host.signal(victim, "KILL")

      // A port whose child exited leaves `erlang:ports()` only after it has
      // delivered `{exit_status, _}`, so once the victim's port is gone the
      // status is queued behind the request.
      let assert poll.Answered(Nil) =
        poll.until(within: 5000, every: 10, attempt: fn() {
          case list.contains(host.port_os_pids(), victim) {
            True -> poll.Retry
            False -> poll.Done(Nil)
          }
        })
        as "the killed helper's port has delivered its status and closed"
      host.resume(actor)

      assert process.receive(answers, 5000) == Ok(Error(exec.SendFailed))
      assert exec.status(helper, waiting: 1000)
        == exec.StatusDead(exec.SendFailed)
      assert exec.close(helper, waiting: 2000) == Ok(Nil)
    }
  }
}

// The same ordering with `close` as the write that fails. A helper that died
// on its own and is then asked to shut down finds the status queued behind
// the shutdown frame, and the verdict is the unasked exit's, judged by the
// idle phase it died in.
pub fn real_helper_failed_shutdown_write_keeps_a_queued_status_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP real_helper_failed_shutdown: " <> reason)
    Ok(config) -> {
      let before = host.port_os_pids()
      let assert Ok(helper) = exec.spawn_helper(config)
        as "native helper spawns"
      let assert [victim] =
        list.filter(host.port_os_pids(), fn(pid) { !list.contains(before, pid) })
        as "one new helper port"
      let assert Ok(actor) = process.subject_owner(exec.wire(helper))
        as "the wire subject belongs to the helper actor"

      host.suspend(actor)
      let verdicts = process.new_subject()
      process.spawn_unlinked(fn() {
        process.send(verdicts, exec.close(helper, waiting: 5000))
      })

      // The request must be in the suspended actor's mailbox before the
      // helper dies, so that the exit status queues behind it and the write
      // fails with the status already waiting. Polling the mailbox and then
      // the port list states both orderings instead of guessing at them.
      let assert poll.Answered(Nil) =
        poll.until(within: 5000, every: 10, attempt: fn() {
          case host.queued(actor) >= 1 {
            True -> poll.Done(Nil)
            False -> poll.Retry
          }
        })
        as "the request is queued behind the suspension"
      host.signal(victim, "KILL")

      // A port whose child exited leaves `erlang:ports()` only after it has
      // delivered `{exit_status, _}`, so once the victim's port is gone the
      // status is queued behind the request.
      let assert poll.Answered(Nil) =
        poll.until(within: 5000, every: 10, attempt: fn() {
          case list.contains(host.port_os_pids(), victim) {
            True -> poll.Retry
            False -> poll.Done(Nil)
          }
        })
        as "the killed helper's port has delivered its status and closed"
      host.resume(actor)

      assert process.receive(verdicts, 5000) == Ok(Ok(Nil))
    }
  }
}

// The other half of the rule: a failed write whose status never comes. The
// port of an idle helper is closed from outside, which is what a port that
// failed under its owner looks like: the next write is refused and no exit
// status is ever delivered. The helper is declared dead without being killed,
// and the retirement stays pending for the witness window, after which the
// proof is lost for good. A late status after that cannot repair it.
pub fn real_helper_failed_write_loses_the_proof_test() {
  case helper_config() {
    Error(reason) ->
      io.println_error("SKIP real_helper_failed_write: " <> reason)
    Ok(config) -> {
      let before = host.port_os_pids()
      let assert Ok(helper) = exec.spawn_helper(config)
        as "native helper spawns"
      let assert [victim] =
        list.filter(host.port_os_pids(), fn(pid) { !list.contains(before, pid) })
        as "one new helper port"
      let assert Ok(Nil) = host.close_port_of(victim)
        as "the helper's port is closed under its owner"
      assert exec.heartbeat(helper, waiting: 2000) == Error(exec.SendFailed)
      assert exec.status(helper, waiting: 1000)
        == exec.StatusDead(exec.SendFailed)

      // The status is awaited, not given up on at the failed write.
      assert exec.close(helper, waiting: 200) == Error(exec.RetirementPending)

      // Five seconds is the witness window, and nothing arrives in it.
      assert exec.close(helper, waiting: 8000)
        == Error(exec.RetirementProofLost)
      process.send(exec.wire(helper), exec.WireClosed(0))
      assert exec.close(helper, waiting: 1000)
        == Error(exec.RetirementProofLost)
    }
  }
}

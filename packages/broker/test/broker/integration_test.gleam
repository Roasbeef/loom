//// Feature-detected integration suite: builds the real `loom-exec`
//// helper with the Go toolchain and drives it through the exec pool —
//// handshake over the fd-3 shell trick, an echo run, a stdin
//// roundtrip, a cancel mid-sleep, and output truncation. Skipped (with
//// the reason printed) when `go` is missing or the build fails.
////
//// The development container usually lacks bwrap, so the helper runs
//// degraded; executions use `BestEffort` and assert on the honest
//// enforcement report rather than demanding a jail the kernel cannot
//// provide here.

import broker/exec
import broker/framing
import broker/policy
import broker/support/shell
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/option.{Some}
import gleam/string
import simplifile

// Builds the helper (cached by Go, so cheap per test) and returns a
// ready SpawnConfig, or the reason to skip.
fn helper_config() -> Result(exec.SpawnConfig, String) {
  case shell.find_executable("go") {
    Error(Nil) -> Error("go toolchain not on PATH")
    Ok(_go) -> {
      let assert Ok(here) = simplifile.current_directory()
      let work_dir = here <> "/build/integration"
      let helper_path = work_dir <> "/loom-exec"
      let assert Ok(Nil) = simplifile.create_directory_all(work_dir <> "/work")
      let output =
        shell.os_cmd(
          "cd ../sandbox && go build -o '"
          <> helper_path
          <> "' ./cmd/loom-exec && echo LOOM_BUILD_OK",
        )
      case string.contains(output, "LOOM_BUILD_OK") {
        False -> Error("go build failed: " <> output)
        True ->
          Ok(exec.SpawnConfig(
            helper_path:,
            shell_path: "/bin/sh",
            base_policy: base_policy(work_dir),
            tmp_dir: work_dir <> "/tmp",
            handshake_timeout_ms: 5000,
            cancel_grace_ms: 3000,
            heartbeat_interval_ms: 0,
          ))
      }
    }
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
  )
}

fn with_real_helper(name: String, run: fn(exec.Helper) -> Nil) -> Nil {
  case helper_config() {
    Error(reason) -> io.println("SKIP " <> name <> ": " <> reason)
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
  // Give the child a moment to start, then cancel; the pgroup dies via
  // TERM (or KILL at the helper's 2s escalation).
  process.sleep(200)
  exec.cancel(helper)
  let assert Ok(#(_stdout, exit)) = collect_exit(events, <<>>, 15_000)
  assert exit.signal != 0
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

// The temp policy file must be unlinked once the helper says hello —
// prove the tmp dir is empty after a successful spawn.
pub fn real_helper_policy_file_unlinked_test() {
  use _helper <- with_real_helper("real_helper_policy_file_unlinked")
  let assert Ok(here) = simplifile.current_directory()
  let assert Ok(entries) =
    simplifile.read_directory(here <> "/build/integration/tmp")
  assert entries == []
}

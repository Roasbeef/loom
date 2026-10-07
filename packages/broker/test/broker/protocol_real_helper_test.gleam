//// Credited ServerProtocol crosses the production port, codec and retirement pool.
//// The helper is built from this checkout before this focused integration gate.

import broker/exec
import broker/executor
import broker/framing
import broker/policy
import core/clock
import gleam/erlang/process
import gleam/option.{Some}
import simplifile
import telemetry/log

pub fn real_protocol_server_retirement_follows_original_native_join_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "integration checkout directory exists"
  let work = here <> "/build/protocol-real"
  let helper_path = here <> "/../sandbox/loom-exec"
  assert simplifile.is_file(helper_path) == Ok(True)
    as "this checkout's native helper must be built before this gate"
  assert simplifile.create_directory_all(work) == Ok(Nil)
  let defaults = policy.workspace_default(work)
  let base =
    policy.SandboxPolicy(
      ..defaults,
      network: policy.NetworkOff,
      limits: policy.Limits(..defaults.limits, wall_s: 1, output_bytes: 4096),
    )
  let spawn =
    exec.SpawnConfig(
      helper_path:,
      shell_path: "/bin/sh",
      base_policy: base,
      helper_args: [],
      tmp_dir: work <> "/native",
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    )
  let borrowed = process.new_subject()
  let assert Ok(pool) = exec.start_pool(1, fn() { exec.prepare_helper(spawn) })
    as "real native helper pool starts"
  let checked = process.new_subject()
  let retired = process.new_subject()
  let assert Ok(service) =
    executor.start_with_retirement(
      executor.ExecutorConfig(
        checkout: fn() {
          let answer = exec.checkout(pool, waiting: 5000)
          case answer {
            Ok(helper) -> process.send(borrowed, helper)
            Error(_) -> Nil
          }
          answer
        },
        checkin: fn(helper) { process.send(checked, helper) },
        custody: fn() { exec.pool_custody(pool, waiting: 1000) },
        close_helpers: fn(ms) { exec.close_pool(pool, waiting: ms) },
        incarnation: 17,
        log: log.discard(),
      ),
      fn(helper, done) { exec.prepare_borrowed_retirement(pool, helper, done) },
    )
    as "service installs the exact native retirement seam"
  let assert Ok(dispatcher) =
    executor.dispatcher_protocol_retiring_with_native_deadline(
      service,
      fn(id, result) { process.send(retired, #(id, result)) },
    )
    as "server mode requires the trusted retirement constructor"
  let events = process.new_subject()
  let request =
    exec.ExecRequest(
      argv: ["/bin/sh", "-c", "printf ready"],
      env: [#("PATH", "/usr/bin:/bin")],
      cwd: work,
      policy: Some(base),
      token: <<1>>,
      demand: exec.BestEffort,
    )
  let assert Ok(original) =
    executor.start_protocol(
      dispatcher,
      executor.ProtocolDispatch(
        41,
        request,
        clock.fixed(0),
        10_000,
        events,
        process.self(),
      ),
    )
    as "real protocol execution starts"
  let assert Ok(helper) = process.receive(borrowed, 1000)
    as "test retains the exact originally borrowed helper"
  let assert Ok(exec.ProtocolOutput(
    1,
    framing.Stdout,
    <<"ready">>,
    5,
    framing.OutputComplete,
  )) = process.receive(events, 5000)
    as "native output crosses the credited production codec"
  executor.protocol_output_consumed(original, 1)
  let assert Ok(exec.ProtocolTerminal(Ok(result), framing.ProtocolComplete)) =
    process.receive(events, 5000)
    as "consumed output permits the exact native terminal"
  assert result.code == 0
  assert result.stdout_bytes == 5
  assert result.enforcement != []
  assert process.receive(retired, 0) == Error(Nil)
  assert process.receive(checked, 0) == Error(Nil)
  executor.release_protocol_execution(original)
  let assert Ok(#(_, Ok(Nil))) = process.receive(retired, 5000)
    as "exact native shutdown and normal helper owner Down are both joined"
  assert !process.is_alive(exec.pid(helper))
  assert process.receive(checked, 0) == Error(Nil)
  assert process.receive(retired, 0) == Error(Nil)
  assert executor.close(service, draining: 1000, helpers: 5000) == Ok(Nil)
}

//// Original collected returns cross the real helper port and the actual pool.
//// These controls require this checkout's normally built native helper.

import broker/exec
import broker/executor
import broker/framing
import broker/policy
import core/clock
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import simplifile
import telemetry/log

type ReleaseOrder {
  ReleaseFirst
  ConsumeFirst
}

fn round(
  native: executor.Executor,
  request: exec.ExecRequest,
  seq: Int,
  order: ReleaseOrder,
) {
  let events = process.new_subject()
  let returned = process.new_subject()
  let assert Ok(original) =
    executor.start_protocol(
      executor.dispatcher_collected_with_native_deadline(native),
      executor.ProtocolDispatch(
        seq,
        request,
        clock.fixed(0),
        10_000,
        events,
        process.self(),
      ),
    )
    as "real finite collected command starts with original pool registration"
  case order {
    ReleaseFirst -> executor.release_collected(original, returned)
    ConsumeFirst -> Nil
  }
  let assert Ok(Nil) =
    executor.protocol_input(
      original,
      1,
      33,
      <<>>,
      framing.InputEOF,
      waiting: 1000,
    )
    as "finite input admits its one empty EOF"

  // The helper may interleave acceptance and output. Exactly three bounded
  // events precede Reusable: the accepted EOF, one output, and the terminal.
  let counted =
    list.fold([1, 2, 3], #(0, 0, 0), fn(counted, _) {
      let assert Ok(event) = process.receive(events, 5000)
        as "real original helper delivers its bounded protocol event"
      case event {
        exec.ProtocolInputAccepted(1, 33) -> #(
          counted.0 + 1,
          counted.1,
          counted.2,
        )
        exec.ProtocolOutput(
          1,
          framing.Stdout,
          <<"ready">>,
          5,
          framing.OutputComplete,
        ) -> {
          executor.protocol_output_consumed(original, 1)
          #(counted.0, counted.1 + 1, counted.2)
        }
        exec.ProtocolTerminal(Ok(result), framing.ProtocolComplete) -> {
          assert result.code == 0
          assert result.stdout_bytes == 5
          assert result.enforcement != []
          #(counted.0, counted.1, counted.2 + 1)
        }
        _ -> panic as "unexpected real original protocol event"
      }
    })
  assert counted == #(1, 1, 1)
  let assert Ok(exec.ProtocolReusable) = process.receive(events, 5000)
    as "actual waitDone produces the original reusable witness"
  assert process.receive(returned, 0) == Error(Nil)
  executor.protocol_reusable_consumed(original)
  case order {
    ReleaseFirst -> Nil
    ConsumeFirst -> executor.release_collected(original, returned)
  }
  let assert Ok(Ok(proof)) = process.receive(returned, 5000)
    as "original observer receives actual Borrowed-to-Available proof"
  assert executor.verify_collected_return(original, proof) == Ok(Nil)
  assert process.receive(returned, 0) == Error(Nil)
  #(original, proof)
}

pub fn real_collected_return_both_orders_and_same_helper_successor_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "integration package directory exists"
  let work = here <> "/build/collected-return-real"
  let helper_path = here <> "/../sandbox/loom-exec"
  assert simplifile.is_file(helper_path) == Ok(True)
    as "this checkout's normal native helper build is required"
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
      helper_path,
      "/bin/sh",
      base,
      [],
      work <> "/native",
      5000,
      3000,
      0,
    )
  let assert Ok(pool) = exec.start_pool(1, fn() { exec.prepare_helper(spawn) })
    as "one actual original helper pool starts"
  let assert Ok(native) =
    executor.start_registered_protocol_pool(pool, 29, log.discard())
    as "native executor retains this same original pool"
  let request =
    exec.ExecRequest(
      ["/bin/sh", "-c", "cat >/dev/null; printf ready"],
      [#("PATH", "/usr/bin:/bin")],
      work,
      Some(base),
      <<1>>,
      exec.BestEffort,
    )
  let #(first, proof) = round(native, request, 1, ReleaseFirst)
  let #(second, _) = round(native, request, 2, ConsumeFirst)
  assert executor.protocol_execution_id(first)
    != executor.protocol_execution_id(second)
  assert executor.verify_collected_return(first, proof) == Ok(Nil)
  assert executor.verify_collected_return(second, proof)
    == Error(exec.ReturnRefused)
  let assert Ok(census) = exec.pool_census(pool, waiting: 1000)
    as "one spawn confirms the successor used the same actual helper"
  assert census.spawned == 1
  assert census.retired == 0
  assert executor.close(native, draining: 1000, helpers: 5000) == Ok(Nil)
  assert !process.is_alive(exec.pool_pid(pool))
}

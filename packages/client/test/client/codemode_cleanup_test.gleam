//// The client owns its execution roots and needs an original Launch drain
//// before deleting them. Program completion is deliberately independent:
//// these controls observe real files through the production deletion helper,
//// rather than treating an outcome string as evidence that work has joined.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import broker/token
import client/codemode
import codemode/codemode as pipeline
import codemode/compile
import codemode/enforcement
import codemode/identity
import codemode/run_channel
import codemode/satellite
import core/clock
import core/ids
import core/msgpack
import gleam/bit_array
import gleam/erlang/process
import gleam/result
import gleam/string
import simplifile
import tools/codemode as codemode_tool
import weft

pub fn released_launch_removes_both_original_client_roots_test() {
  let #(root, sockets) = roots("released")
  codemode.cleanup_local_execution(
    satellite.LaunchResourcesReleased,
    root,
    sockets,
  )
  assert simplifile.link_info(root) |> is_error
  assert simplifile.link_info(sockets) |> is_error
  sibling_retained(root)
}

pub fn no_launch_effects_removes_only_the_client_preparation_test() {
  let #(root, sockets) = roots("not-launched")
  codemode.cleanup_local_execution(satellite.NoLaunchResources, root, sockets)
  assert simplifile.link_info(root) |> is_error
  assert simplifile.link_info(sockets) |> is_error
  sibling_retained(root)
}

pub fn known_program_outcome_retains_unresolved_original_roots_test() {
  let #(root, sockets) = roots("known-unresolved")
  let outcome = satellite.Completed(msgpack.StringValue("done"))
  let custody = satellite.LaunchResourcesUnresolved("original close was lost")
  codemode.cleanup_local_execution(custody, root, sockets)
  assert outcome == satellite.Completed(msgpack.StringValue("done"))
  retained(root, sockets)
}

pub fn post_ready_refusal_retains_unresolved_preparation_test() {
  let #(root, sockets) = roots("refused-unresolved")
  let refusal = satellite.LaunchRejected("original admission refused")
  codemode.cleanup_local_execution(
    satellite.LaunchResourcesUnresolved("preparation drain was not observed"),
    root,
    sockets,
  )
  assert codemode.translate(pipeline.RunFailed(refusal))
    == codemode_tool.RunFailed(codemode_tool.StartFailed(
      "original admission refused",
    ))
  retained(root, sockets)
}

pub fn unknown_launch_keeps_the_typed_reconciliation_result_test() {
  assert codemode.translate(
      pipeline.RunFailed(satellite.LaunchOutcomeUnknown(
        "original reply was lost",
      )),
    )
    == codemode_tool.RunFailed(codemode_tool.LaunchOutcomeUnknown(
      "original reply was lost",
    ))
}

// Every test creates its own actual client roots and a sibling marker. The
// marker catches a deletion widened beyond the execution's two owned paths.
fn roots(name: String) -> #(String, String) {
  let assert Ok(here) = simplifile.current_directory()
    as "the cleanup test requires its private package directory"
  let base = here <> "/build/cleanup-" <> name
  let root = base <> "/build"
  let sockets = base <> "/sockets"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the original build root exists"
  let assert Ok(Nil) = simplifile.create_directory_all(sockets)
    as "the original socket root exists"
  let assert Ok(Nil) = simplifile.write(base <> "/sibling", "retained")
    as "the unrelated sibling exists"
  #(root, sockets)
}

fn retained(root: String, sockets: String) -> Nil {
  let assert Ok(_) = simplifile.link_info(root)
    as "unresolved build custody retains its original root"
  let assert Ok(_) = simplifile.link_info(sockets)
    as "unresolved transport custody retains its original socket root"
  sibling_retained(root)
}

fn sibling_retained(root: String) -> Nil {
  assert simplifile.read(string.drop_end(root, 6) <> "/sibling")
    == Ok("retained")
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Error(_) -> True
    Ok(_) -> False
  }
}

// The filesystem owner receives custody produced by the actual foreground host.
pub fn admitted_host_work_retains_actual_client_roots_test() {
  let #(root, sockets) = roots("host-admitted")
  let entered = process.new_subject()
  let consumed = process.new_subject()
  let terminal_ready = process.new_subject()
  let time = 1_700_000_000_000
  let fixed = clock.fixed(at: time)
  let #(op, _) = ids.mint_op(ids.generator(fixed, seed: 9))
  let assert Ok(owner) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: fixed,
        checkout: fn() { Error(exec.AllBusy(0)) },
        checkin: fn(_) { Nil },
      ),
    )
    as "the real broker prepares without needing a native helper"
  let cfg =
    satellite.RunConfig(
      base_policy: policy.workspace_default(root),
      demand: exec.BestEffort,
      env: [],
      cwd: root,
      entropy: token.production_entropy(),
      clock: fixed,
      precheck: satellite.no_precheck,
      ceilings: [],
      call_timeout_ms: 5000,
      router: fn(_) {
        Ok(
          satellite.ScopedService(fn() {
            process.send(entered, Nil)
            let held = process.new_subject()
            let _ = process.receive(held, 5000)
            framing.CapOk(msgpack.NilValue)
          }),
        )
      },
    )
  let phase =
    identity.for_execution(op, "owned", budget.Budget(2, time + 20_000))
    |> identity.run_phase
  let artifact = compile.Artifact(root, root, compile.entry_module, "fixture")
  let task =
    weft.new([
      fn() {
        Ok(
          satellite.run(artifact, phase, owner, cfg, fn(request) {
            let incarnation = run_channel.new_incarnation()
            let #(_, events) = run_channel.endpoint(run_channel.host(request))
            let assert Ok(active) =
              run_channel.prepare_direction(incarnation, run_channel.ToHost)
              |> run_channel.activate_direction
              as "the fixture activates its original inbound window"
            let assert Ok(wire) =
              framing.encode(framing.Frame(
                1,
                framing.CapCall(
                  run_channel.token(request),
                  "held",
                  msgpack.NilValue,
                  time + 20_000,
                ),
              ))
              as "the admitted call uses the real cap frame encoder"
            let bytes = bit_array.slice(wire, 4, bit_array.byte_size(wire) - 4)
            let assert Ok(call_bytes) = bytes
              as "the cap frame has its four byte prefix"
            let #(pending, delivery) =
              fixture_delivery(active, call_bytes, fn(disposition) {
                process.send(consumed, disposition)
              })
            let #(frame, _) = run_channel.delivered(delivery)
            process.send(terminal_ready, fn() {
              let #(next, _) =
                run_channel.consume_frame(pending, frame, run_channel.Continue)
              let envelope =
                msgpack.MapValue([
                  #(msgpack.StringValue("v"), msgpack.IntValue(1)),
                  #(msgpack.StringValue("id"), msgpack.IntValue(0)),
                  #(
                    msgpack.StringValue("kind"),
                    msgpack.StringValue(satellite.outcome_kind),
                  ),
                  #(
                    msgpack.StringValue("body"),
                    msgpack.MapValue([
                      #(msgpack.StringValue("ok"), msgpack.BoolValue(True)),
                      #(
                        msgpack.StringValue("value"),
                        msgpack.StringValue("done"),
                      ),
                    ]),
                  ),
                ])
              let assert Ok(terminal) = msgpack.encode(envelope)
                as "the known terminal encodes"
              let #(_, terminal_delivery) =
                fixture_delivery(next, terminal, fn(_) { Nil })
              process.send(events, run_channel.Frame(terminal_delivery))
            })
            let assert Ok(grant) =
              run_channel.prepare_direction(incarnation, run_channel.ToNode)
              |> run_channel.activate_direction
              |> result.try(run_channel.write_grant)
              as "the bounded fixture prepares its original writer"
            Ok(
              run_channel.Connection(
                incarnation:,
                initial_write_grant: grant,
                activate: fn() {
                  process.send(events, run_channel.Frame(delivery))
                  Ok(Nil)
                },
                offer: fn(_, _) { Error(run_channel.ChannelRetired) },
                close: fn() {
                  run_channel.CloseResult(
                    enforcement.Unreported("no native node in this fixture"),
                    run_channel.TransportJoined,
                    run_channel.ResourcesReleased,
                  )
                },
              ),
            )
          }),
        )
      },
    ])
    |> weft.deadline(10_000)
    |> weft.start_detached
  let assert Ok(terminal) = process.receive(terminal_ready, 3000)
    as "the original terminal publisher is available"
  let assert Ok(run_channel.Continue) = process.receive(consumed, 3000)
    as "the host consumed the original admitted frame"
  let assert Ok(Nil) = process.receive(entered, 3000)
    as "admitted capability work started before termination"
  terminal()
  let assert weft.PulledOutcome(weft.Completed(value: ran, ..)) =
    weft.pull(task, within: 5000)
    as "the foreground host returns its actual custody"
  assert ran.outcome == Ok(satellite.Completed(msgpack.StringValue("done")))
  codemode.cleanup_local_execution(ran.custody, root, sockets)
  retained(root, sockets)
  broker.stop(owner)
}

fn fixture_delivery(
  window: run_channel.Window,
  bytes: BitArray,
  consumed: fn(run_channel.Consumption) -> Nil,
) -> #(run_channel.Window, run_channel.Delivery) {
  let assert Ok(length) = run_channel.payload_length(bit_array.byte_size(bytes))
    as "fixture bytes are bounded before reservation"
  let assert Ok(#(reserved, reservation)) =
    run_channel.reserve_frame(window, length)
    as "the original frame reserves its credit"
  let assert Ok(payload) = run_channel.finish_payload(reservation, bytes)
    as "the original payload matches its reservation"
  let assert Ok(delivery) = run_channel.delivery(reservation, payload, consumed)
    as "the original delivery owns its consumption"
  let assert Ok(pending) = run_channel.publish_frame(reserved, reservation)
    as "the published frame waits for exact consumption"
  #(pending, delivery)
}

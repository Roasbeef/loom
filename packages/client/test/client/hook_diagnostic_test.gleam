//// A scripted executor speaks the real helper protocol through the real
//// broker and hook runner. Host kernel delegation cannot affect this proof.

import broker/broker
import broker/exec
import broker/framing
import broker/policy
import broker/token
import client/hookrunner
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string

const skip = "skip:cgroup-v2: root holds 9 processes; memory.max and pids.max NOT applied"

pub fn degraded_hook_preserves_exact_refusal_and_discards_decision_test() {
  let outcome = run(SkippedLayer)
  assert outcome.code == 1
  assert outcome.stdout == ""
  assert outcome.stderr
    == "the execution ran without the demanded enforcement: " <> skip
  assert outcome.ending == hookrunner.RanToExit
}

pub fn timed_out_degraded_hook_discards_all_output_test() {
  let outcome = run(TimedOutSkippedLayer)
  assert outcome.code == 1
  assert outcome.stdout == ""
  assert outcome.stderr == ""
  assert outcome.ending == hookrunner.WallCancelled
}

pub fn helper_refusal_preserves_exact_code_and_reason_test() {
  let outcome = run(HelperRefusal)
  assert outcome.code == 1
  assert outcome.stdout == ""
  assert outcome.stderr
    == "the sandbox helper refused (bad_policy): invalid fixture mount"
}

type Script {
  SkippedLayer
  TimedOutSkippedLayer
  HelperRefusal
}

fn run(script: Script) -> hookrunner.Outcome {
  let handoff = process.new_subject()
  let script =
    process.spawn_unlinked(fn() {
      let outgoing = process.new_subject()
      let attachment = process.new_subject()
      process.send(handoff, #(outgoing, attachment))
      let wire = process.receive_forever(attachment)
      send(
        wire,
        framing.Frame(
          1,
          framing.Hello(framing.exec_protocol_version, "exec-helper", [
            "bwrap",
            "rlimits",
            "pgroup",
            "landlock",
            "seccomp",
          ]),
        ),
      )
      respond(outgoing, wire, framing.deframer(), script)
    })
  let assert Ok(#(outgoing, attachment)) = process.receive(handoff, 1000)
    as "script publishes its own inbox"
  let assert Ok(helper) =
    exec.start(exec.HelperConfig(
      transport: exec.ChannelTransport(
        send: fn(bytes) { process.send(outgoing, bytes) },
        close: fn() { Nil },
      ),
      handshake_timeout_ms: 2000,
      cancel_grace_ms: 100,
      heartbeat_interval_ms: 0,
    ))
    as "scripted helper starts"
  let wire = exec.wire(helper)
  process.send(attachment, wire)
  let assert Ok(_) = exec.await_ready(helper, waiting: 1000)
    as "healthy hello admits platform demand"
  let wall = clock.fixed(1000)
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: wall,
        checkout: fn() { Ok(helper) },
        checkin: fn(_) { Nil },
      ),
    )
    as "real broker starts"
  let #(op_id, _) = ids.mint_op(ids.generator(wall, 363))
  let ctx =
    hookrunner.Context(
      broker: broker_actor,
      base_policy: policy.workspace_default("/fixture"),
      op_id:,
      step_id: "diagnostic",
      workspace: "/fixture",
      env: [],
      demand: exec.PlatformEnforcement,
      clock: wall,
      session_id: "diagnostic",
      transcript_path: "/fixture/session.db",
    )
  let observed =
    hookrunner.run(ctx, hookrunner.Command("fixture", None, Some(1)), "{}", 30)
  process.kill(script)
  broker.stop(broker_actor)
  process.unlink(exec.pid(helper))
  process.kill(exec.pid(helper))
  let assert Ok(outcome) = observed
    as "the broker settles the hook failure in band"
  outcome
}

fn respond(outgoing, wire, deframer, script: Script) {
  let bytes = process.receive_forever(outgoing)
  let framing.Pushed(deframer:, inbound:, ..) = framing.push(deframer, bytes)
  case inbound {
    [framing.Known(framing.Frame(id, framing.ExecStart(..)))] -> {
      case script {
        HelperRefusal ->
          send(
            wire,
            framing.Frame(
              id,
              framing.ErrorBody("bad_policy", "invalid fixture mount"),
            ),
          )
        SkippedLayer | TimedOutSkippedLayer -> {
          let timed_out = script == TimedOutSkippedLayer

          // The printed permission decision is deliberately dangerous if the
          // runner ever treats a degraded or timed-out run as successful.
          let output = "{\"permissionDecision\":\"allow\"}"
          send(
            wire,
            framing.Frame(
              id,
              framing.ExecOut(
                framing.Stdout,
                bit_array.from_string(output),
                string.byte_size(output),
                False,
              ),
            ),
          )
          send(
            wire,
            framing.Frame(
              id,
              framing.ExecExit(
                code: 0,
                signal: 0,
                stdout_bytes: string.byte_size(output),
                stderr_bytes: 0,
                stdout_truncated: False,
                stderr_truncated: False,
                enforcement: [skip],
                degraded: False,
                wall_ms: 1,
                timed_out:,
                cancelled: timed_out,
              ),
            ),
          )
        }
      }
    }
    _ -> respond(outgoing, wire, deframer, script)
  }
}

fn send(wire, frame) {
  let assert Ok(data) = framing.encode(frame) as "fixture frame encodes"
  process.send(wire, exec.WireBytes(data))
}

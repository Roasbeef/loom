//// Credited helper controls use an in-process wire with explicitly held witnesses.
//// These tests exercise the production helper state machine without a native jail.

import broker/exec
import broker/framing
import broker/policy
import core/clock
import gleam/erlang/process
import gleam/option.{Some}

pub fn peer(
  features: List(String),
) -> #(exec.Helper, process.Subject(BitArray)) {
  let outbound = process.new_subject()
  let transport =
    exec.ChannelTransport(fn(bytes) { process.send(outbound, bytes) }, fn() {
      Nil
    })
  let config = exec.default_config(transport)
  let assert Ok(helper) =
    exec.start(exec.HelperConfig(..config, heartbeat_interval_ms: 0))
    as "test helper starts"
  inbound(
    helper,
    framing.Frame(
      1,
      framing.Hello(framing.exec_protocol_version, "exec-helper", features),
    ),
  )
  let assert Ok(_) = exec.await_ready(helper, waiting: 1000)
    as "hello completes"
  let _hello = next(outbound)
  #(helper, outbound)
}

pub fn inbound(helper: exec.Helper, frame: framing.Frame) -> Nil {
  let assert Ok(bytes) = framing.encode(frame) as "frame encodes"
  process.send(exec.wire(helper), exec.WireBytes(bytes))
}

pub fn next(outbound: process.Subject(BitArray)) -> framing.Frame {
  let assert Ok(bytes) = process.receive(outbound, 1000)
    as "original outbound frame arrives"
  let pushed = framing.push(framing.deframer(), bytes)
  let assert [framing.Known(frame)] = pushed.inbound as "one frame is deframed"
  frame
}

pub fn request() -> exec.ExecRequest {
  let base = policy.workspace_default("/work")
  exec.ExecRequest(
    argv: ["true"],
    env: [],
    cwd: "/work",
    policy: Some(
      policy.SandboxPolicy(
        ..base,
        limits: policy.Limits(..base.limits, wall_s: 1),
      ),
    ),
    token: <<1>>,
    demand: exec.BestEffort,
  )
}

pub fn terminal(helper: exec.Helper, id: Int, stdout: Int, stderr: Int) -> Nil {
  let assert Ok(report) =
    framing.protocol_terminal(framing.ExecExit(
      0,
      0,
      stdout,
      stderr,
      False,
      False,
      ["pgroup"],
      False,
      1,
      False,
      False,
    ))
    as "only native exit is wrapped"
  inbound(
    helper,
    framing.Frame(id, framing.ProtocolExit(report, framing.ProtocolComplete)),
  )
}

pub fn finite_terminal_and_delivered_reusable_hold_borrow_until_consumed_test() {
  let #(helper, outbound) = peer([framing.protocol_credit_feature])
  let events = process.new_subject()
  let checked = process.new_subject()
  let assert Ok(original) =
    exec.run_protocol(
      helper,
      request(),
      framing.FiniteCollected,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    as "credited command starts"
  let start = next(outbound)
  let id = exec.protocol_execution_id(original)
  assert start.id == id
  let assert framing.ProtocolStart(mode: framing.FiniteCollected, ..) =
    start.body
    as "finite mode is explicit"
  let assert Ok(Nil) =
    exec.defer_protocol_checkin(
      original,
      fn() { process.send(checked, "first") },
      waiting: 1000,
    )
    as "original checkin registers"
  let assert Error(_) =
    exec.defer_protocol_checkin(
      original,
      fn() { process.send(checked, "replacement") },
      waiting: 1000,
    )
    as "second checkin refuses"
  let assert Ok(Nil) =
    exec.protocol_input(original, 1, 33, <<>>, framing.InputEOF, waiting: 1000)
    as "finite EOF is submitted"
  let input = next(outbound)
  let assert framing.ProtocolInput(
    execution_id: received,
    ordinal: 1,
    frame_id: 33,
    data: <<>>,
    end: framing.InputEOF,
  ) = input.body
    as "all original input coordinates survive"
  assert received == id
  inbound(helper, framing.Frame(id, framing.ProtocolInputAccepted(id, 1, 33)))
  let assert Ok(exec.ProtocolInputAccepted(1, 33)) =
    process.receive(events, 1000)
    as "queue admission arrives separately"
  terminal(helper, id, 0, 0)
  let assert Ok(exec.ProtocolTerminal(Ok(_), framing.ProtocolComplete)) =
    process.receive(events, 1000)
    as "native terminal retained"
  let assert exec.StatusBusy(_) = exec.status(helper, waiting: 1000)
    as "terminal cannot free helper"
  assert process.receive(checked, 0) == Error(Nil)
  inbound(helper, framing.Frame(id, framing.ProtocolReusable(id)))
  let assert Ok(exec.ProtocolReusable) = process.receive(events, 1000)
    as "post-join witness is delivered"
  let assert exec.StatusBusy(_) = exec.status(helper, waiting: 1000)
    as "delivery cannot free helper"
  assert process.receive(checked, 0) == Error(Nil)
  exec.protocol_reusable_consumed(original)
  let assert Ok("first") = process.receive(checked, 1000)
    as "only original deferred checkin runs"
  let assert exec.StatusReady(_) = exec.status(helper, waiting: 1000)
    as "consumed witness frees helper"
  let assert Ok(successor) =
    exec.run_protocol(
      helper,
      request(),
      framing.FiniteCollected,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    as "sequential collector starts"
  let second = next(outbound)
  assert second.id != id
  exec.cancel_protocol(original)
  let assert exec.StatusBusy(_) = exec.status(helper, waiting: 1000)
    as "old cancel cannot settle successor"
  assert process.receive(outbound, 0) == Error(Nil)
  exec.cancel_protocol(successor)
  let assert framing.Cancel = next(outbound).body
    as "original successor cancel is emitted"
  exec.shutdown(helper)
}

pub fn direct_finite_consumption_allows_ordinary_successor_and_refuses_late_checkin_test() {
  let #(helper, outbound) = peer([framing.protocol_credit_feature])
  let events = process.new_subject()
  let checked = process.new_subject()
  let assert Ok(original) =
    exec.run_protocol(
      helper,
      request(),
      framing.FiniteCollected,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    as "direct finite command starts without a pool checkin"
  let id = next(outbound).id
  terminal(helper, id, 0, 0)
  let assert Ok(exec.ProtocolTerminal(Ok(_), framing.ProtocolComplete)) =
    process.receive(events, 1000)
    as "original finite terminal arrives"
  inbound(helper, framing.Frame(id, framing.ProtocolReusable(id)))
  let assert Ok(exec.ProtocolReusable) = process.receive(events, 1000)
    as "original finite cleanup has joined"
  exec.protocol_reusable_consumed(original)
  let assert exec.StatusReady(_) = exec.status(helper, waiting: 1000)
    as "direct consumption makes the helper ready"

  // The accepted ordinary successor closes the original callback association.
  // Waiting for its start frame proves that admission already happened.
  let ordinary = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(), events: ordinary, waiting: 1000)
    as "ordinary successor starts after direct finite consumption"
  let successor = next(outbound)
  let assert framing.ExecStart(..) = successor.body
    as "successor uses ordinary execution framing"
  assert successor.id != id
  let assert Error(exec.ProtocolViolation("deferred_checkin_identity")) =
    exec.defer_protocol_checkin(
      original,
      fn() { process.send(checked, Nil) },
      waiting: 1000,
    )
    as "late original checkin cannot attach to ordinary successor"
  assert process.receive(checked, 0) == Error(Nil)
  inbound(
    helper,
    framing.Frame(
      successor.id,
      framing.ExecOut(framing.Stdout, <<"ordinary">>, 8, False),
    ),
  )
  let assert Ok(exec.Output(framing.Stdout, <<"ordinary">>, 8, False)) =
    process.receive(ordinary, 1000)
    as "ordinary output is classified on its own lane"
  inbound(
    helper,
    framing.Frame(
      successor.id,
      framing.ExecExit(
        0,
        0,
        8,
        0,
        False,
        False,
        ["pgroup"],
        False,
        1,
        False,
        False,
      ),
    ),
  )
  let assert Ok(exec.Exited(result)) = process.receive(ordinary, 1000)
    as "ordinary successor retains its exact terminal"
  assert result.code == 0
  assert result.stdout_bytes == 8
  let assert exec.StatusReady(_) = exec.status(helper, waiting: 1000)
    as "ordinary successor completes without killing the helper"
  assert process.receive(checked, 0) == Error(Nil)
  exec.shutdown(helper)
}

pub fn shared_output_credit_checks_cumulative_per_stream_counts_test() {
  let #(helper, outbound) = peer([framing.protocol_credit_feature])
  let events = process.new_subject()
  let assert Ok(original) =
    exec.run_protocol(
      helper,
      request(),
      framing.ServerProtocol,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    as "server starts"
  let id = next(outbound).id
  inbound(
    helper,
    framing.Frame(
      id,
      framing.ProtocolOutput(
        id,
        1,
        framing.Stdout,
        <<"abc">>,
        3,
        framing.OutputComplete,
      ),
    ),
  )
  let assert Ok(exec.ProtocolOutput(
    1,
    framing.Stdout,
    <<"abc">>,
    3,
    framing.OutputComplete,
  )) = process.receive(events, 1000)
    as "cumulative stdout survives"
  assert process.receive(outbound, 0) == Error(Nil)
  exec.protocol_output_consumed(original, 1)
  let assert framing.ProtocolOutputConsumed(received, 1) = next(outbound).body
    as "only consumed offer returns credit"
  assert received == id
  inbound(
    helper,
    framing.Frame(
      id,
      framing.ProtocolOutput(
        id,
        2,
        framing.Stderr,
        <<"xy">>,
        2,
        framing.OutputComplete,
      ),
    ),
  )
  let assert Ok(exec.ProtocolOutput(
    2,
    framing.Stderr,
    <<"xy">>,
    2,
    framing.OutputComplete,
  )) = process.receive(events, 1000)
    as "stderr has its own cumulative count"
  exec.protocol_output_consumed(original, 2)
  let _ack = next(outbound)
  inbound(
    helper,
    framing.Frame(
      id,
      framing.ProtocolOutput(
        id,
        3,
        framing.Stdout,
        <<"d">>,
        99,
        framing.OutputComplete,
      ),
    ),
  )
  let assert Ok(exec.ProtocolFailure(exec.ProtocolViolation(
    "output_credit_or_count",
  ))) = process.receive(events, 1000)
    as "false cumulative count fails, not truncates"
  let assert exec.StatusDead(_) = exec.status(helper, waiting: 1000)
    as "failed gate is absorbing"
}

pub fn wrong_and_late_reusable_cannot_release_original_borrow_test() {
  let #(helper, outbound) = peer([framing.protocol_credit_feature])
  let events = process.new_subject()
  let checked = process.new_subject()
  let assert Ok(original) =
    exec.run_protocol(
      helper,
      request(),
      framing.FiniteCollected,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    as "finite starts"
  let id = next(outbound).id
  let assert Ok(Nil) =
    exec.defer_protocol_checkin(
      original,
      fn() { process.send(checked, Nil) },
      waiting: 1000,
    )
    as "checkin registered"
  terminal(helper, id, 0, 0)
  let _terminal = process.receive(events, 1000)
  inbound(helper, framing.Frame(id + 2, framing.ProtocolReusable(id + 2)))
  let assert exec.StatusDead(_) = exec.status(helper, waiting: 1000)
    as "wrong witness fences helper"
  let assert Ok(exec.ProtocolFailure(_)) = process.receive(events, 1000)
    as "original consumer learns reuse uncertainty"
  inbound(helper, framing.Frame(id, framing.ProtocolReusable(id)))
  exec.protocol_reusable_consumed(original)
  let assert exec.StatusDead(_) = exec.status(helper, waiting: 1000)
    as "late witness stays fenced"
  assert process.receive(checked, 0) == Error(Nil)
}

pub fn server_reusable_and_unnegotiated_start_refuse_test() {
  let #(old, outbound) = peer([])
  let events = process.new_subject()
  let assert Error(exec.ProtocolRunRefused(exec.NotReady)) =
    exec.run_protocol(
      old,
      request(),
      framing.FiniteCollected,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    as "missing feature refuses before start"
  assert process.receive(outbound, 0) == Error(Nil)
  exec.shutdown(old)
  let #(helper, outbound) = peer([framing.protocol_credit_feature])
  let assert Ok(_) =
    exec.run_protocol(
      helper,
      request(),
      framing.ServerProtocol,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    as "server starts"
  let id = next(outbound).id
  terminal(helper, id, 0, 0)
  let _terminal = process.receive(events, 1000)
  inbound(helper, framing.Frame(id, framing.ProtocolReusable(id)))
  let assert exec.StatusDead(_) = exec.status(helper, waiting: 1000)
    as "server never substitutes reuse for retirement"
}

pub fn lost_start_reply_retains_original_execution_and_cancellation_test() {
  let #(helper, outbound) = peer([framing.protocol_credit_feature])
  let events = process.new_subject()
  let reached = process.new_subject()
  let held =
    clock.from_function(fn() {
      let release = process.new_subject()
      process.send(reached, release)
      let assert Ok(Nil) = process.receive(release, 1000)
        as "test releases original start clock"
      0
    })
  let assert Error(exec.ProtocolRunUnknown(original, exec.HelperUnresponsive)) =
    exec.run_protocol(
      helper,
      request(),
      framing.ServerProtocol,
      held,
      10_000,
      events,
      waiting: 20,
    )
    as "held Run response is unknown with original handle"
  let assert Ok(release) = process.receive(reached, 1000)
    as "original start reached held admission"
  exec.cancel_protocol(original)
  process.send(release, Nil)
  let start = next(outbound)
  assert start.id == exec.protocol_execution_id(original)
  let cancel = next(outbound)
  assert cancel.id == start.id
  let assert framing.Cancel = cancel.body
    as "cleanup binds the possibly-started original"
  assert process.receive(outbound, 0) == Error(Nil)
  exec.shutdown(helper)
}

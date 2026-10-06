//// Real Unix-frame controls for the foreground local adapter. The node side
//// uses the existing protocol helper fixture, so these prove original socket
//// admission/consumption/drain ordering, not actual jail enforcement.
//// A separately named existing real-toolchain E2E gate proves the jail path.

import broker/broker
import broker/budget
import broker/exec
import broker/policy
import broker/token
import codemode/compile
import codemode/identity
import codemode/launch
import codemode/physical
import codemode/run_channel
import codemode/satellite
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import simplifile
import support/fake_helper
import support/internal/ffi_peer
import support/rig
import support/scratch

const t = 1_700_000_000_000

fn phase() -> identity.PhaseIdentity {
  let generator = ids.generator(clock.fixed(t), seed: 441)
  let #(operation, _) = ids.mint_op(generator)
  identity.for_execution(operation, "foreground", budget.Budget(4, t + 30_000))
  |> identity.run_phase
}

fn setup(name: String) {
  let dir = scratch.fresh("foreground-" <> name)
  let assert Ok(owner) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(t),
        checkout: fn() {
          Ok(fake_helper.start_helper(fake_helper.HoldForCancel))
        },
        checkin: fn(_) { Nil },
      ),
    )
    as "the original broker starts"
  let config =
    launch.ForegroundLaunchConfig(
      local: launch.LaunchConfig(
        runner: physical.local(owner),
        clock: clock.fixed(t),
        erl_path: "/usr/bin/erl",
        host_mounts: [],
        demand: exec.BestEffort,
        accept_timeout_ms: 3000,
      ),
      token_path: dir <> "/token/cap-token",
      cap_socket_path: dir <> "/sock/cap.sock",
      write_token_file: satellite.private_token_writer(dir <> "/token"),
      unlink_token_file: satellite.unlink_token_file,
    )
  let events = process.new_subject()
  let base =
    policy.SandboxPolicy(
      ..policy.workspace_default(dir),
      readable_roots: ["/"],
      env_allow: ["PATH", launch.sock_env, launch.token_env],
    )
  let artifact =
    compile.Artifact(dir, dir <> "/ebin", compile.entry_module, "sha256-none")
  let assert Ok(request) =
    run_channel.request(
      artifact,
      phase(),
      base,
      exec.BestEffort,
      [#("PATH", "/usr/bin")],
      dir,
      bit_array.concat(list.repeat(<<7>>, 32)),
      run_channel.host_endpoint(process.self(), events),
    )
    as "the original request is valid"
  #(owner, config, request, events)
}

fn prepared(name: String) {
  let #(owner, config, request, events) = setup(name)
  let assert Ok(connection) = launch.foreground_launcher(config)(request)
    as "the original paused connection prepares"
  let assert Ok(peer) = ffi_peer.connect(config.cap_socket_path)
    as "the peer reaches the original listener"
  #(owner, config, connection, peer, events)
}

fn consume_prefix(
  connection: run_channel.Connection,
  peer: ffi_peer.PeerSocket,
  events: process.Subject(run_channel.Event),
) {
  let assert Ok(Nil) = connection.activate()
    as "original custody activates once"
  let assert Ok(Nil) = ffi_peer.send(peer, <<1:32, 0xc0>>)
    as "the first exact frame is written"
  let assert Ok(run_channel.Frame(delivery)) = process.receive(events, 3000)
    as "the reader publishes one admitted frame"
  run_channel.consume(delivery, run_channel.Continue)
}

pub fn preparation_does_not_deliver_a_body_before_activation_test() {
  let #(owner, config, connection, peer, events) = prepared("paused")
  let assert Ok(Nil) = ffi_peer.send(peer, <<1:32, 0xc0>>)
    as "bytes may be pending only in the original passive socket"
  assert process.receive(events, 20) == Error(Nil)
  let assert Ok(Nil) = connection.activate() as "the host has installed custody"
  assert connection.activate() == Error(run_channel.WindowUnavailable)
  let assert Ok(run_channel.Frame(delivery)) = process.receive(events, 3000)
    as "activation releases exactly one admitted frame"
  let #(_frame, payload) = run_channel.delivered(delivery)
  assert run_channel.payload(payload) == <<0xc0>>
  run_channel.consume(delivery, run_channel.Final)
  let closed = connection.close()
  assert closed.transport == run_channel.TransportJoined
  assert closed.resources == run_channel.ResourcesReleased
  assert !rig.exists(config.cap_socket_path)
  assert !rig.exists(config.token_path)
  ffi_peer.close(peer)
  broker.stop(owner)
}

pub fn inbound_window_is_held_until_original_consumption_test() {
  let #(owner, _config, connection, peer, events) = prepared("held")
  let assert Ok(Nil) = connection.activate() as "original activation"
  let assert Ok(Nil) = ffi_peer.send(peer, <<1:32, 1, 1:32, 2, 1:32, 3>>)
    as "three wire frames are queued on the passive socket"
  let assert Ok(run_channel.Frame(first)) = process.receive(events, 3000)
    as "the first reservation is published"
  assert process.receive(events, 20) == Error(Nil)
  run_channel.consume(first, run_channel.Continue)
  let assert Ok(run_channel.Frame(second)) = process.receive(events, 3000)
    as "exact consumption permits the second reservation"
  run_channel.consume(first, run_channel.Continue)
  assert process.receive(events, 20) == Error(Nil)
  run_channel.consume(second, run_channel.Final)
  let closed = connection.close()
  assert closed.transport == run_channel.TransportJoined
  assert closed.resources == run_channel.ResourcesReleased
  assert process.receive(events, 0) == Error(Nil)
  ffi_peer.close(peer)
  broker.stop(owner)
}

pub fn duplicate_outbound_reservation_cannot_publish_twice_test() {
  let #(owner, _config, connection, peer, events) = prepared("duplicate")
  consume_prefix(connection, peer, events)
  let assert Ok(payload) = run_channel.from_wire(<<1:32, 0xc0>>)
    as "one exact outbound frame"
  let assert Ok(#(_held, reservation)) =
    run_channel.reserve_write(connection.initial_write_grant, payload)
    as "the host charges before offer"
  assert connection.offer(reservation, payload) == Ok(Nil)
  let assert Error(_) = connection.offer(reservation, payload)
    as "copied reservation cannot admit twice"
  let assert Ok(run_channel.WriteConsumed(frame)) =
    process.receive(events, 3000)
    as "the socket writer consumed the original frame"
  let #(original, _length) = run_channel.reservation(reservation)
  assert frame == original
  let assert Ok(bytes) = ffi_peer.recv(peer, 3000)
    as "the peer sees the original frame"
  assert bytes == <<1:32, 0xc0>>
  assert ffi_peer.recv(peer, 20) == Error(Nil)
  let closed = connection.close()
  assert closed.transport == run_channel.TransportJoined
  assert closed.resources == run_channel.ResourcesReleased
  ffi_peer.close(peer)
  broker.stop(owner)
}

pub fn close_bypasses_a_writer_blocked_on_real_socket_test() {
  let #(owner, _config, connection, peer, events) = prepared("blocked-writer")
  consume_prefix(connection, peer, events)
  let chunk = bit_array.concat(list.repeat(<<0>>, run_channel.max_chunk_bytes))
  let body = bit_array.concat(list.repeat(chunk, 256))
  let assert Ok(payload) =
    run_channel.from_wire(<<run_channel.max_payload_bytes:32, body:bits>>)
    as "the maximum bounded body is valid transport data"
  let assert Ok(#(_held, reservation)) =
    run_channel.reserve_write(connection.initial_write_grant, payload)
    as "the maximum frame is charged before publication"
  assert connection.offer(reservation, payload) == Ok(Nil)

  // Actual received prefix/body bytes prove the writer entered the real socket
  // path. The unread remainder exceeds its buffers and retains the writer ACK.
  let assert Ok(prefix) = ffi_peer.recv(peer, 3000)
    as "the writer has physically started"
  assert bit_array.byte_size(prefix) > 0
  assert process.receive(events, 50) == Error(Nil)
  let before = ffi_peer.now_ms()
  let closed = connection.close()
  let elapsed = ffi_peer.now_ms() - before
  assert closed.transport == run_channel.TransportJoined
  assert closed.resources == run_channel.ResourcesReleased
  assert elapsed < 3000
  ffi_peer.close(peer)
  broker.stop(owner)
}

pub fn wrong_token_placement_refuses_before_native_dispatch_test() {
  let #(owner, config, request, _events) = setup("token-placement")
  let wrong =
    launch.ForegroundLaunchConfig(
      ..config,
      token_path: config.token_path <> "-different",
    )
  assert launch.foreground_launcher(wrong)(request)
    == Error(run_channel.LaunchRefused(
      "the token writer changed original placement",
      run_channel.ResourcesReleased,
    ))
  assert !rig.exists(config.token_path)
  assert !rig.exists(config.cap_socket_path)
  broker.stop(owner)
}

// A declared excess is refused from its fixed header, without waiting for body.
pub fn oversized_declaration_retires_before_body_receipt_test() {
  let #(owner, _config, connection, peer, events) = prepared("oversized-header")
  let assert Ok(Nil) = connection.activate() as "original activation"
  let too_large = run_channel.max_payload_bytes + 1
  let assert Ok(Nil) = ffi_peer.send(peer, <<too_large:32>>)
    as "only the fixed header was sent"
  let assert Ok(run_channel.Fault(original, reason)) =
    process.receive(events, 3000)
    as "no body is needed to refuse the declared excess"
  assert original == connection.incarnation
  assert reason == "frame declaration exceeds original bound"
  let closed = connection.close()
  assert closed.transport == run_channel.TransportJoined
  assert closed.resources == run_channel.ResourcesReleased
  ffi_peer.close(peer)
  broker.stop(owner)
}

// A synchronous private-file writer can fail after creating its original file.
// Known non-dispatch is cleanup-safe only after that exact preparation is removed.
pub fn partial_token_write_failure_cleans_original_preparation_test() {
  let #(owner, config, request, _events) = setup("partial-token")
  let directory =
    config.token_path |> string.drop_end(string.length("/cap-token"))
  let failing =
    launch.ForegroundLaunchConfig(..config, write_token_file: fn(bytes) {
      let assert Ok(Nil) = simplifile.create_directory_all(directory)
        as "fixture creates original private placement"
      let assert Ok(Nil) = simplifile.write_bits(config.token_path, bytes)
        as "fixture produces a partial original preparation"
      Error("the original private permission step failed")
    })
  assert launch.foreground_launcher(failing)(request)
    == Error(run_channel.LaunchRefused(
      "the original private permission step failed",
      run_channel.ResourcesReleased,
    ))
  assert !rig.exists(config.token_path)
  assert !rig.exists(config.cap_socket_path)
  broker.stop(owner)
}

// Duplicate close observes original retained evidence; it never launches again.
pub fn duplicate_close_returns_original_join_and_native_disposition_test() {
  let #(owner, _config, connection, peer, events) = prepared("duplicate-close")
  consume_prefix(connection, peer, events)
  let first = connection.close()
  assert first.transport == run_channel.TransportJoined
  assert first.resources == run_channel.ResourcesReleased
  assert connection.close() == first
  ffi_peer.close(peer)
  broker.stop(owner)
}

// The whole request supplies enforcement demand, even if a stale adapter default
// differs. Original identity and token placement remain those of this request.
pub fn original_request_demand_reaches_physical_clearance_test() {
  let #(owner, config, request, events) = setup("request-demand")
  let seen = process.new_subject()
  let checking =
    physical.Runner(
      clear: fn(origin, call, _events) {
        process.send(seen, #(origin, call))
        Error(broker.OperationAborted)
      },
      abort_step: fn(_operation, _step) { Nil },
    )
  let configured =
    launch.ForegroundLaunchConfig(
      ..config,
      local: launch.LaunchConfig(..config.local, runner: checking),
    )
  let #(artifact, phase, policy, _demand, env, cwd) =
    run_channel.execution(request)
  let assert Ok(request) =
    run_channel.request(
      artifact,
      phase,
      policy,
      exec.FullEnforcement,
      env,
      cwd,
      run_channel.token(request),
      run_channel.host_endpoint(process.self(), events),
    )
    as "the original trusted request pins full enforcement"
  let assert Ok(connection) = launch.foreground_launcher(configured)(request)
    as "original preparation reaches the physical adapter"
  let assert Ok(#(origin, call)) = process.receive(seen, 3000)
    as "the original physical clearance was observed"
  assert call.demand == exec.FullEnforcement
  assert call.op_id == identity.op_id(phase)
  assert call.step_id == identity.step_id(phase)
  assert origin == identity.command_origin(phase) |> result.unwrap(None)
  let closed = connection.close()
  assert closed.transport == run_channel.TransportJoined
  assert closed.resources == run_channel.ResourcesReleased
  broker.stop(owner)
}

// A real queued ClearCall can outlive the caller's observation deadline. This
// control holds the real broker's checkout handler, then proves that transport
// joins cannot release original files before any original native settlement.
pub fn lost_clearance_reply_keeps_original_resources_unresolved_test() {
  let #(unused_owner, config, request, _events) = setup("lost-clearance")
  let checkout_started = process.new_subject()
  let native_started = process.new_subject()
  let helper = fake_helper.start_helper(fake_helper.Gated(native_started))
  let assert Ok(owner) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(t),
        checkout: fn() {
          let release = process.new_subject()
          process.send(checkout_started, release)
          let assert Ok(Nil) = process.receive(release, 15_000)
            as "the test driver releases the original queued clearance"
          Ok(helper)
        },
        checkin: fn(_) { Nil },
      ),
    )
    as "the original serial broker starts"
  let configured =
    launch.ForegroundLaunchConfig(
      ..config,
      local: launch.LaunchConfig(..config.local, runner: physical.local(owner)),
    )
  let assert Ok(connection) = launch.foreground_launcher(configured)(request)
    as "original whole Launch returns paused custody"
  let assert Ok(release) = process.receive(checkout_started, 3000)
    as "the real original ClearCall entered broker checkout"
  let closed = connection.close()
  assert closed.transport == run_channel.TransportJoined
  assert closed.resources
    == run_channel.ResourcesUnresolved(
      "original native clearance was not observed",
    )
  assert rig.exists(config.token_path)
  assert rig.exists(config.cap_socket_path)

  // Releasing the broker demonstrates actual late dispatch, not an invented
  // possibility. Its queued abort cancels that dispatch, but cannot retroactively
  // create the lost collector's original native settlement observation.
  process.send(release, Nil)
  let assert Ok(_started) = process.receive(native_started, 3000)
    as "the original timed-out clearance really dispatched afterward"
  assert connection.close() == closed
  broker.stop(owner)
  broker.stop(unused_owner)
}

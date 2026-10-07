//// Real passive Unix sockets prove original close-before-join ordering.
//// The peer fixture reuses codemode's existing test-only client functions.

import codemode/enforcement
import codemode/run_channel as run
import executor/remote/launch_channel as channel
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/string
import gleam/time/timestamp
import simplifile
import weft/actor
import weft/poll

type Peer

type AdoptionGate

type AdoptionFault {
  CloseBeforeAdoption
  LoseLeafBeforeAdoption
}

@external(erlang, "executor_launch_socket_fixture", "adoption_gate")
fn adoption_gate(
  fault: AdoptionFault,
  ready: process.Subject(Nil),
) -> AdoptionGate

@external(erlang, "executor_launch_socket_fixture", "cancel_adoption_gate")
fn cancel_adoption_gate(gate: AdoptionGate) -> Nil

@external(erlang, "executor_launch_socket_fixture", "continue_adoption_gate")
fn continue_adoption_gate(gate: AdoptionGate) -> Nil

@external(erlang, "executor_launch_socket_fixture", "adoption_clock")
fn adoption_clock(gate: AdoptionGate, now: Int) -> Int

@external(erlang, "executor_launch_socket_fixture", "release_adoption_gate")
fn release_adoption_gate(gate: AdoptionGate) -> Nil

@external(erlang, "executor_launch_socket_fixture", "adoption_witness")
fn adoption_witness(gate: AdoptionGate) -> Result(Nil, Nil)

@external(erlang, "executor_launch_socket_fixture", "peer_closed")
fn peer_closed(peer: Peer) -> Result(Nil, Nil)

@external(erlang, "executor_launch_socket_fixture", "kill_channel_owner_and_join_leaves")
fn kill_channel_owner_and_join_leaves(owner: channel.Owner) -> Result(Nil, Nil)

@external(erlang, "executor_launch_socket_fixture", "connect_unix")
fn connect(path: String) -> Result(Peer, Nil)

@external(erlang, "executor_launch_socket_fixture", "peer_send")
fn send(peer: Peer, bytes: BitArray) -> Result(Nil, Nil)

@external(erlang, "executor_launch_socket_fixture", "closer_waiting")
fn closer_waiting(pid: process.Pid) -> Bool

@external(erlang, "executor_launch_socket_fixture", "peer_close")
fn close_peer(peer: Peer) -> Nil

fn fixture(
  run: fn(
    channel.Owner,
    run.Connection,
    process.Subject(run.Event),
    Peer,
    String,
  ) -> Nil,
) {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    temporary_root()
    <> "/lwc-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let parent = process.new_subject()
  let cancelled = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(owner) =
    channel.start(
      #(path, path <> "/s", path <> "/t"),
      poll.monotonic().now() + 10_000,
      poll.monotonic().now,
      parent,
      fn() { process.send(cancelled, Nil) },
      fn() { Ok(Nil) },
      fn(result) { process.send(closed, result) },
    )
    as "Original path custody before effects."
  assert channel.prepare(owner, <<0:size(256)>>) == Ok(Nil)
  channel.preparation_joined(owner)
  let events = process.new_subject()
  let handoff = process.new_subject()
  channel.install(owner, run.host_endpoint(process.self(), events), handoff)
  let assert Ok(peer) = connect(path <> "/s") as "Real Unix client."
  let assert Ok(connection) = process.receive(handoff, 1000)
    as "Original paused handoff follows accept."
  run(owner, connection, events, peer, path)
  channel.stop(owner)
  close_peer(peer)
  let assert Ok(_) = process.receive(closed, 3000)
    as "Independent close result delivered."
  assert simplifile.delete(path) == Ok(Nil)
}

pub fn paused_terminal_final_and_native_observation_never_emits_end_test() {
  fixture(fn(owner, connection, events, peer, _path) {
    assert send(peer, <<3:32, 1, 2, 3>>) == Ok(Nil)
    assert process.receive(events, 0) == Error(Nil)
    assert connection.activate() == Ok(Nil)
    let assert Ok(run.Frame(delivery)) = process.receive(events, 1000)
      as "Frame waits for actual activation."
    let #(_, payload) = run.delivered(delivery)
    assert run.payload(payload) == <<1, 2, 3>>
    channel.settled(
      owner,
      enforcement.Unreported("actual native terminal fixture"),
    )
    assert process.receive(events, 0) == Error(Nil)
    run.consume(delivery, run.Final)
    let closed = connection.close()
    assert closed.transport == run.TransportJoined
    assert closed.node
      == enforcement.Unreported("actual native terminal fixture")
    assert closed.resources
      == run.ResourcesUnresolved(
        "original native resource retirement not observed",
      )
    assert process.receive(events, 0) == Error(Nil)
  })
}

pub fn independent_close_wakes_real_blocked_socket_reader_test() {
  fixture(fn(_owner, connection, _events, peer, _path) {
    assert connection.activate() == Ok(Nil)
    let closed = connection.close()
    assert closed.transport == run.TransportJoined
    assert peer_closed(peer) == Ok(Nil)
  })
}

pub fn independent_close_wakes_real_blocked_socket_writer_test() {
  fixture(fn(_owner, connection, _events, _peer, _path) {
    assert connection.activate() == Ok(Nil)
    let bytes = bit_array.from_string(string.repeat("x", run.max_payload_bytes))
    let assert Ok(length) = run.payload_length(run.max_payload_bytes)
      as "Bounded declaration."
    let assert Ok(window) =
      run.activate_direction(run.prepare_direction(
        connection.incarnation,
        run.ToNode,
      ))
      as "Initial pure mirror."
    let assert Ok(#(_, declared)) = run.reserve_frame(window, length)
      as "Exact reservation."
    let assert Ok(payload) = run.finish_payload(declared, bytes)
      as "Complete bounded payload."
    let assert Ok(#(_grant, reservation)) =
      run.reserve_write(connection.initial_write_grant, payload)
      as "Original one-window grant."
    assert connection.offer(reservation, payload) == Ok(Nil)
    assert connection.offer(reservation, payload)
      == Error(run.WindowUnavailable)
    let closed = connection.close()
    assert closed.transport == run.TransportJoined
  })
}

pub fn exclusive_collision_and_partial_directory_custody_test() {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    temporary_root()
    <> "/lwc-collision-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory(path) == Ok(Nil)
  assert simplifile.write(path <> "/kept", "original") == Ok(Nil)
  let parent = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(owner) =
    channel.start(
      #(path, path <> "/s", path <> "/t"),
      poll.monotonic().now() + 10_000,
      poll.monotonic().now,
      parent,
      fn() { Nil },
      fn() { Ok(Nil) },
      fn(result) { process.send(closed, result) },
    )
    as "Owner initialized without effects."
  let assert Error(channel.Definite(_)) =
    channel.prepare(owner, <<0:size(256)>>)
    as "Existing allocation refuses once."
  let assert Error(channel.Definite(_)) =
    channel.prepare(owner, <<0:size(256)>>)
    as "Refusal cannot remint allocation."
  channel.preparation_joined(owner)
  channel.excluded(owner, enforcement.Unreported("committed no-dispatch fence"))
  let assert Ok(result) = process.receive(closed, 1000)
    as "No newly owned directory."
  assert result.resources == run.ResourcesReleased
  assert simplifile.read(path <> "/kept") == Ok("original")
  assert simplifile.delete(path) == Ok(Nil)
}

pub fn copied_foreign_incarnation_cannot_enter_original_socket_writer_test() {
  fixture(fn(_owner, connection, _events, _peer, _path) {
    assert connection.activate() == Ok(Nil)
    let assert Ok(length) = run.payload_length(3) as "Bounded declaration."
    let foreign = run.new_incarnation()
    let assert Ok(window) =
      run.activate_direction(run.prepare_direction(foreign, run.ToNode))
      as "Different incarnation."
    let assert Ok(#(_, reservation)) = run.reserve_frame(window, length)
      as "Copied foreign reservation."
    let assert Ok(payload) = run.finish_payload(reservation, <<1, 2, 3>>)
      as "Exact foreign frame body."
    assert connection.offer(reservation, payload) == Error(run.StaleReservation)
    assert connection.close().transport == run.TransportJoined
  })
}

pub fn no_directory_removal_before_original_preparation_join_test() {
  let #(seconds, nanos) =
    timestamp.system_time()
    |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    temporary_root()
    <> "/lwc-preparer-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let parent = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(owner) =
    channel.start(
      #(path, path <> "/s", path <> "/t"),
      poll.monotonic().now() + 10_000,
      poll.monotonic().now,
      parent,
      fn() { Nil },
      fn() { Ok(Nil) },
      fn(result) { process.send(closed, result) },
    )
    as "Original cleanup witnesses are independent."
  assert channel.prepare(owner, <<0:size(256)>>) == Ok(Nil)
  channel.excluded(owner, enforcement.Unreported("committed original fence"))

  // The same producer ask witnesses processing of the earlier exclusion.
  let assert Error(channel.Definite(_)) =
    channel.prepare(owner, <<0:size(256)>>)
    as "Original exclusion has reached the actor before checking cleanup."
  assert process.receive(closed, 0) == Error(Nil)
  assert simplifile.read_bits(path <> "/t") == Ok(<<0:size(256)>>)
  channel.preparation_joined(owner)
  let assert Ok(result) = process.receive(closed, 1000)
    as "Actual preparer join completes cleanup."
  assert result.resources == run.ResourcesReleased
  assert simplifile.is_directory(path) == Ok(False)
}

pub fn original_host_death_closes_blocked_accept_without_native_cleanup_proof_test() {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    temporary_root()
    <> "/lwc-host-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let parent = process.new_subject()
  let cancelled = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(host) =
    actor.new(Nil)
    |> actor.on_message(fn(_, _) { actor.stop() })
    |> actor.start
    as "Original independent host."
  let assert Ok(owner) =
    channel.start(
      #(path, path <> "/s", path <> "/t"),
      poll.monotonic().now() + 10_000,
      poll.monotonic().now,
      parent,
      fn() { process.send(cancelled, Nil) },
      fn() { Ok(Nil) },
      fn(result) { process.send(closed, result) },
    )
    as "Original listener custody."
  assert channel.prepare(owner, <<0:size(256)>>) == Ok(Nil)
  channel.preparation_joined(owner)
  channel.install(
    owner,
    run.host_endpoint(host.pid, process.new_subject()),
    process.new_subject(),
  )

  // The same producer barrier follows installation before terminating its host.
  let assert Error(channel.Definite(_)) =
    channel.prepare(owner, <<0:size(256)>>)
    as "Installation reached original socket owner."
  process.send(host.data, Nil)
  assert process.receive(cancelled, 1000) == Ok(Nil)
  let assert Ok(result) = process.receive(closed, 3000)
    as "Host death closes and joins blocked accept."
  assert result.transport == run.TransportJoined
  assert result.resources
    == run.ResourcesUnresolved(
      "original native resource retirement not observed",
    )
  assert simplifile.read_bits(path <> "/t") == Ok(<<0:size(256)>>)
  assert simplifile.delete(path) == Ok(Nil)
}

pub fn immutable_deadline_closes_original_listener_without_fabricating_cleanup_test() {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    temporary_root()
    <> "/lwc-deadline-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let parent = process.new_subject()
  let cancelled = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(owner) =
    channel.start(
      #(path, path <> "/s", path <> "/t"),
      poll.monotonic().now() + 300,
      poll.monotonic().now,
      parent,
      fn() { process.send(cancelled, Nil) },
      fn() { Ok(Nil) },
      fn(result) { process.send(closed, result) },
    )
    as "Original finite deadline."
  assert channel.prepare(owner, <<0:size(256)>>) == Ok(Nil)
  channel.preparation_joined(owner)
  assert process.receive(cancelled, 1000) == Ok(Nil)
  let assert Ok(result) = process.receive(closed, 1000)
    as "Original deadline independently closes listener."
  assert result.transport == run.TransportJoined
  assert result.resources
    == run.ResourcesUnresolved(
      "original native resource retirement not observed",
    )
  assert simplifile.read_bits(path <> "/t") == Ok(<<0:size(256)>>)
  assert simplifile.delete(path) == Ok(Nil)
}

fn refused_partial(
  deadline_ms: Int,
  run: fn(
    channel.Owner,
    process.Subject(Nil),
    process.Subject(Nil),
    process.Subject(run.CloseResult),
    String,
  ) -> Nil,
) {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    temporary_root()
    <> "/lwc-refused-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(parent) =
    actor.new(Nil)
    |> actor.on_message(fn(_, _) { actor.stop() })
    |> actor.start
    as "Original parent lives through partial preparation."
  let cancelled = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(owner) =
    channel.start(
      #(path, path <> "/" <> string.repeat("s", 140), path <> "/t"),
      poll.monotonic().now() + deadline_ms,
      poll.monotonic().now,
      parent.data,
      fn() { process.send(cancelled, Nil) },
      fn() { Ok(Nil) },
      fn(result) { process.send(closed, result) },
    )
    as "Exact original channel custody."
  let assert Error(channel.Definite(_)) =
    channel.prepare(owner, <<0:size(256)>>)
    as "Real Unix path limit refuses after directory and token acquisition."
  assert simplifile.read_bits(path <> "/t") == Ok(<<0:size(256)>>)
  channel.preparation_joined(owner)
  run(owner, parent.data, cancelled, closed, path)
  process.send(parent.data, Nil)
  assert simplifile.delete(path) == Ok(Nil)
}

pub fn refused_partial_deadline_closes_without_resource_witness_test() {
  refused_partial(300, fn(_owner, _parent, cancelled, closed, path) {
    assert process.receive(cancelled, 1000) == Ok(Nil)
    let assert Ok(result) = process.receive(closed, 1000)
      as "Refused original deadline reaches close."
    assert result.transport == run.TransportJoined
    assert result.resources
      == run.ResourcesUnresolved(
        "original native resource retirement not observed",
      )
    assert simplifile.read_bits(path <> "/t") == Ok(<<0:size(256)>>)
  })
}

pub fn refused_partial_parent_death_closes_without_resource_witness_test() {
  refused_partial(10_000, fn(_owner, parent, cancelled, closed, path) {
    process.send(parent, Nil)
    assert process.receive(cancelled, 1000) == Ok(Nil)
    let assert Ok(result) = process.receive(closed, 1000)
      as "Refused parent death reaches close."
    assert result.transport == run.TransportJoined
    assert result.resources
      == run.ResourcesUnresolved(
        "original native resource retirement not observed",
      )
    assert simplifile.read_bits(path <> "/t") == Ok(<<0:size(256)>>)
  })
}

pub fn service_stop_without_waiter_preserves_original_close_reply_test() {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    temporary_root()
    <> "/lwc-waiter-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let parent = process.new_subject()
  let published = process.new_subject()
  let assert Ok(owner) =
    channel.start(
      #(path, path <> "/s", path <> "/t"),
      poll.monotonic().now() + 10_000,
      poll.monotonic().now,
      parent,
      fn() { Nil },
      fn() { Ok(Nil) },
      fn(result) { process.send(published, result) },
    )
    as "Original real socket custody."
  assert channel.prepare(owner, <<0:size(256)>>) == Ok(Nil)
  let handoff = process.new_subject()
  channel.install(
    owner,
    run.host_endpoint(process.self(), process.new_subject()),
    handoff,
  )
  let assert Ok(peer) = connect(path <> "/s") as "Original passive peer."
  let assert Ok(connection) = process.receive(handoff, 1000)
    as "Actual adopted socket children."
  assert connection.activate() == Ok(Nil)

  // Missing preparation join deliberately holds Closing after actual socket joins.
  channel.fenced_before_native(owner)
  let assert Error(channel.Definite(_)) =
    channel.prepare(owner, <<0:size(256)>>)
    as "No-dispatch fence has reached the original owner."
  let answer = process.new_subject()
  let close = connection.close
  let assert Ok(closer) =
    actor.new(Nil)
    |> actor.on_message(fn(_, _) {
      process.send(answer, close())
      actor.stop()
    })
    |> actor.start
    as "Original synchronous close caller."
  process.send(closer.data, Nil)

  // Waiting inside the close function witnesses Stop(Some) before its receive.
  let waiting =
    poll.until(within: 1000, every: 1, attempt: fn() {
      case closer_waiting(closer.pid) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  let assert poll.Answered(Nil) = waiting
    as "Original close waiter has been sent."
  let assert Error(channel.Definite(_)) =
    channel.prepare(owner, <<0:size(256)>>)
    as "Original close request has reached the held Closing actor."
  channel.stop(owner)

  // This same producer roundtrip witnesses processing of service-style Stop(None).
  let assert Error(channel.Definite(_)) =
    channel.prepare(owner, <<0:size(256)>>)
    as "No-waiter cancellation processed before cleanup disposition."
  let assert Ok(actual) = process.receive(published, 3000)
    as "Bounded cleanup publishes actual joined transport with uncertain resources."
  let assert Ok(received) = process.receive(answer, 4000)
    as "Original close caller receives its result."
  assert received == actual
  assert received.transport == run.TransportJoined
  assert received.resources
    == run.ResourcesUnresolved(
      "original native resource retirement not observed",
    )
  assert simplifile.read_bits(path <> "/t") == Ok(<<0:size(256)>>)
  close_peer(peer)
  assert simplifile.delete(path) == Ok(Nil)
}

pub fn channel_owner_death_joins_leaves_and_closes_accepted_socket_test() {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    temporary_root()
    <> "/lwc-owner-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let closed = process.new_subject()
  let assert Ok(owner) =
    channel.start(
      #(path, path <> "/s", path <> "/t"),
      poll.monotonic().now() + 10_000,
      poll.monotonic().now,
      process.new_subject(),
      fn() { Nil },
      fn() { Ok(Nil) },
      fn(result) { process.send(closed, result) },
    )
    as "Original owner retains native resource uncertainty."
  assert channel.prepare(owner, <<0:size(256)>>) == Ok(Nil)
  channel.preparation_joined(owner)
  let handoff = process.new_subject()
  channel.install(
    owner,
    run.host_endpoint(process.self(), process.new_subject()),
    handoff,
  )
  let assert Ok(peer) = connect(path <> "/s") as "Original accepted socket."
  let assert Ok(connection) = process.receive(handoff, 1000)
    as "Both original leaves are under scope custody."
  assert connection.activate() == Ok(Nil)
  assert kill_channel_owner_and_join_leaves(owner) == Ok(Nil)
  assert peer_closed(peer) == Ok(Nil)
  assert process.receive(closed, 0) == Error(Nil)
  assert simplifile.read_bits(path <> "/t") == Ok(<<0:size(256)>>)
  close_peer(peer)
  assert simplifile.delete(path) == Ok(Nil)
}

// The fixture queues original Stop while both leaves are alive and the relay
// cannot yet run. Its normal scope DOWN must prove exits after adoption.
fn close_before_adoption(fault: AdoptionFault) -> run.CloseResult {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    temporary_root()
    <> "/lwc-adoption-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let ready = process.new_subject()
  let gate = adoption_gate(fault, ready)
  let closed = process.new_subject()
  let clock = poll.monotonic().now
  let assert Ok(owner) =
    channel.start(
      #(path, path <> "/s", path <> "/t"),
      clock() + 10_000,
      fn() { adoption_clock(gate, clock()) },
      process.new_subject(),
      fn() { cancel_adoption_gate(gate) },
      fn() { Ok(Nil) },
      fn(result) {
        release_adoption_gate(gate)
        process.send(closed, result)
      },
    )
    as "Original socket owner with bounded pre-adoption schedule."
  assert channel.prepare(owner, <<0:size(256)>>) == Ok(Nil)
  channel.preparation_joined(owner)
  channel.install(
    owner,
    run.host_endpoint(process.self(), process.new_subject()),
    process.new_subject(),
  )
  let assert Ok(Nil) = process.receive(ready, 1000)
    as "Original cancellation reached the held managed run."
  continue_adoption_gate(gate)
  let assert Ok(result) = process.receive(closed, 3000)
    as "Pre-activation shutdown retains its actual transport account."
  assert adoption_witness(gate) == Ok(Nil)
  assert result.resources
    == run.ResourcesUnresolved(
      "original native resource retirement not observed",
    )
  assert simplifile.read_bits(path <> "/t") == Ok(<<0:size(256)>>)
  assert simplifile.delete(path) == Ok(Nil)
  result
}

pub fn queued_stop_before_scope_adoption_joins_original_leaves_test() {
  assert close_before_adoption(CloseBeforeAdoption).transport
    == run.TransportJoined
}

pub fn absent_leaf_before_adoption_retains_unresolved_transport_test() {
  assert close_before_adoption(LoseLeafBeforeAdoption).transport
    == run.TransportUnresolved("original child drain unresolved")
}

// macOS resolves /tmp through /private; Linux has no /private directory.
fn temporary_root() -> String {
  case simplifile.is_directory("/private/tmp") {
    Ok(True) -> "/private/tmp"
    _ -> "/tmp"
  }
}

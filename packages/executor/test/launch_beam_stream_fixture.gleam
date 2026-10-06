//// Fixed TLS-BEAM role runners compose real Launch preparation and Unix I/O.
//// The test rendezvous carries only checked keys, transient doors and closed
//// bytes. Every production stream callback remains local to its original node.

import codemode/run_channel as run
import core/command
import core/ids
import distribution_fixture as fixtures
import envoy
import executor/remote/distribution
import executor/remote/identity
import executor/remote/internal/beam_protocol as protocol
import executor/remote/internal/launch_stream_wire as wire
import executor/remote/launch_beam as bridge
import gleam/bit_array
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/string
import launch_stream_preparation_fixture as preparation
import simplifile
import weft/poll

type Socket

@external(erlang, "executor_launch_socket_fixture", "connect_unix")
fn connect(path: String) -> Result(Socket, Nil)

@external(erlang, "executor_launch_socket_fixture", "peer_send")
fn send(socket: Socket, bytes: BitArray) -> Result(Nil, Nil)

@external(erlang, "executor_launch_socket_fixture", "peer_recv")
fn receive(socket: Socket, within_ms: Int) -> Result(BitArray, Nil)

@external(erlang, "executor_launch_socket_fixture", "peer_close")
fn close_socket(socket: Socket) -> Nil

// Exact bounded reads avoid interpreting raw TCP chunk boundaries as frames.
@external(erlang, "executor_launch_beam_probe", "recv_exact")
fn recv_exact(
  socket: Socket,
  length: Int,
  within_ms: Int,
) -> Result(BitArray, Nil)

type ReaderWatch

@external(erlang, "executor_launch_beam_probe", "original_reader_monitor")
fn original_reader_monitor(door: bridge.Door) -> Result(ReaderWatch, Nil)

@external(erlang, "executor_launch_beam_probe", "reader_down")
fn reader_down(watch: ReaderWatch, within_ms: Int) -> Result(Nil, Nil)

// These bounded probes preserve production Door opacity and introduce no peer API.
@external(erlang, "executor_launch_beam_probe", "inject")
fn inject(
  destination: bridge.Door,
  sender: bridge.Door,
  bytes: BitArray,
) -> Result(Nil, Nil)

@external(erlang, "executor_launch_beam_probe", "foreign_sender")
fn foreign_sender(destination: bridge.Door, bytes: BitArray) -> Result(Nil, Nil)

@external(erlang, "executor_launch_beam_probe", "closed")
fn closed(pid: process.Pid) -> Bool

type Prepared {
  Prepared(command.ServiceKey, process.Subject(Bind))
}

type Bind {
  Bind(bridge.Offer, process.Subject(bridge.Acceptance))
}

fn inputs() -> #(String, fixtures.Provisioned) {
  let assert Ok(root) = envoy.get("LOOM_LAUNCH_STREAM_FIXTURE")
    as "Fixed parent fixture."
  let assert Ok(fixture) = fixtures.read_provisioned(root <> "/fixture.term")
    as "Pinned TLS members."
  #(root, fixture)
}

fn pin() -> protocol.Binding {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Full session."
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "Full workspace."
  let assert Ok(executor) = identity.executor_id("linux")
    as "Original executor label."
  let assert Ok(first) = identity.epoch(2) as "Session epoch."
  let assert Ok(second) = identity.epoch(7) as "Workspace epoch."
  protocol.Binding(
    "owner",
    "linux",
    1,
    identity.scope(session, workspace, executor, first, second),
  )
}

fn rendezvous(pid: process.Pid) -> process.Subject(Prepared) {
  process.unsafely_create_subject(
    pid,
    dynamic.string("loom.executor.endpoint/1"),
  )
}

fn await(root: String, name: String) {
  let assert poll.Answered(Nil) =
    poll.until(10_000, 10, fn() {
      case simplifile.is_file(root <> "/" <> name) {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "Finite role barrier."
}

pub fn executor_main() {
  let #(root, fixture) = inputs()
  let assert Ok(membership) = distribution.start(fixture.executor_config)
    as "Real executor TLS node."
  let assert Ok(owner) = distribution.peer(membership, fixture.owner_name)
    as "Authenticated original owner."
  await(root, "owner-started")
  assert distribution.connect(owner, 3000) == Ok(Nil)
  preparation.with_prepared(fn(service, key, paths) {
    let assert Ok(pid) = distribution.endpoint(owner, 10_000)
      as "Original owner test rendezvous."
    let bind = process.new_subject()
    assert distribution.send(rendezvous(pid), Prepared(key, bind))
      == distribution.Sent
    let assert Ok(Bind(offered, reply)) = process.receive(bind, 3000)
      as "Finite original bind offer."
    assert bridge.serve(
        service,
        owner,
        protocol.Binding(..pin(), generation: 2),
        offered,
      )
      == Error(bridge.Invalid)
    let assert Ok(executor) = bridge.serve(service, owner, pin(), offered)
      as "Exact active Launch entry installed."
    assert distribution.send(reply, bridge.acceptance(executor))
      == distribution.Sent
    await(root, "installed")
    let assert Ok(socket) = connect(paths.1) as "Real original Unix socket."
    let many = bit_array.from_string(string.repeat("x", 70_000))
    assert send(socket, <<
        70_000:32,
        many:bits,
        3:32,
        4,
        5,
        6,
        3:32,
        10,
        11,
        12,
      >>)
      == Ok(Nil)
    let assert Ok(bytes) = receive(socket, 5000)
      as "Original complete socket write."
    assert bytes == <<3:32, 7, 8, 9>>
    let #(_, executor_door) =
      bridge.acceptance_fields(bridge.acceptance(executor))
    let assert Ok(reader) = original_reader_monitor(executor_door)
      as "Original local reader monitored before Final."
    case envoy.get("LOOM_LAUNCH_STREAM_BUDGET") {
      Ok("lifetime") ->
        list.each(
          [
            run.max_wire_bytes,
            run.max_wire_bytes,
            run.max_wire_bytes,
            16_777_197,
          ],
          fn(size) {
            let assert Ok(bytes) = recv_exact(socket, size, 5000)
              as "Original complete maximum Unix frame."
            let assert <<declared:32, body:bytes>> = bytes
              as "Exact original prefix."
            assert declared == size - 4
            assert bit_array.byte_size(body) == declared
            assert body == bit_array.from_string(string.repeat("z", declared))
          },
        )
      _ -> {
        let assert Ok(partial) = receive(socket, 5000)
          as "Original writer reached the actual Unix socket."
        let assert <<16_777_216:32, _body:bits>> = partial
          as "Exact maximum frame prefix."
        assert bit_array.byte_size(partial) < run.max_wire_bytes
        let #(original, owner_door) = bridge.offer_fields(offered)
        let assert Ok(binding) = wire.decode_binding(pin(), original)
          as "Original closed stream authority."
        let assert Ok(bytes) =
          wire.encode(binding, wire.Consumed(run.ToNode, 2, run.Continue))
          as "Same peer, different original process."
        assert foreign_sender(owner_door, bytes) == Ok(Nil)
        assert simplifile.write(root <> "/writer-started", "ready") == Ok(Nil)
      }
    }
    await(root, "owner-final")
    assert reader_down(reader, 2000) == Ok(Nil)
      as "Actual original reader terminated before cancellation or close."
    assert simplifile.write(root <> "/reader-final", "normal") == Ok(Nil)
    await(root, "owner-success")
    close_socket(socket)
  })
  assert simplifile.write(
      root <> "/executor-success",
      "real_original_unix_custody",
    )
    == Ok(Nil)
}

pub fn owner_main() {
  let #(root, fixture) = inputs()
  let assert Ok(membership) = distribution.start(fixture.owner_config)
    as "Real owner TLS node."
  let assert Ok(executor) = distribution.peer(membership, fixture.executor_name)
    as "Authenticated original executor."
  assert distribution.register_endpoint(process.self()) == Ok(Nil)
  assert simplifile.write(root <> "/owner-started", "ready") == Ok(Nil)
  let assert Ok(Prepared(key, bind)) =
    process.receive(rendezvous(process.self()), 50_000)
    as "Actual prepared original key."
  let events = process.new_subject()
  let assert Ok(owner) =
    bridge.start_owner(
      executor,
      pin(),
      key,
      run.host_endpoint(process.self(), events),
      poll.monotonic().now() + 15_000,
      poll.monotonic().now,
    )
    as "Original host projection."
  let answer = process.new_subject()
  assert distribution.send(bind, Bind(bridge.offer(owner), answer))
    == distribution.Sent
  let assert Ok(accepted) = process.receive(answer, 1000)
    as "Finite bind returns before socket accept."
  let #(bytes, door) = bridge.acceptance_fields(accepted)
  let assert Ok(changed) =
    bridge.acceptance_from_wire(executor, <<bytes:bits, 0>>, door)
    as "Bounded but changed original binding."
  assert bridge.install(owner, changed) == Error(bridge.Invalid)
  assert bridge.install(owner, accepted) == Ok(Nil)
  assert bridge.install(owner, accepted) == Error(bridge.Invalid)
  assert bridge.await_connection(owner, 1) == Error(bridge.Uncertain)
  assert simplifile.write(root <> "/installed", "ready") == Ok(Nil)
  let assert Ok(connection) = bridge.await_connection(owner, 3000)
    as "Original paused asynchronous handoff."
  assert process.receive(events, 0) == Error(Nil)
  assert connection.activate() == Ok(Nil)
  let assert Ok(run.Frame(first)) = process.receive(events, 3000)
    as "First actual delivery."
  assert run.payload(run.delivered(first).1)
    == bit_array.from_string(string.repeat("x", 70_000))
  assert process.receive(events, 100) == Error(Nil)
  run.consume(first, run.Continue)
  let assert Ok(run.Frame(last)) = process.receive(events, 3000)
    as "Consumption returns one frame credit."
  assert run.payload(run.delivered(last).1) == <<4, 5, 6>>
  run.consume(first, run.Continue)
  assert process.receive(events, 100) == Error(Nil)
  let assert Ok(payload) = run.from_wire(<<3:32, 7, 8, 9>>)
    as "Nested raw payload remains bytes."
  let assert Ok(#(held, reservation)) =
    run.reserve_write(connection.initial_write_grant, payload)
    as "Original ToNode reservation."
  assert connection.offer(reservation, payload) == Ok(Nil)
  let assert Ok(run.WriteConsumed(frame)) = process.receive(events, 3000)
    as "Actual Unix writer completed."
  let #(grant, consumed) = run.consume_write(held, frame)
  assert consumed == run.Consumed
  let large = bit_array.from_string(string.repeat("z", run.max_payload_bytes))
  let assert Ok(large) = run.from_wire(<<16_777_216:32, large:bits>>)
    as "Maximum exact raw payload."
  case envoy.get("LOOM_LAUNCH_STREAM_BUDGET") {
    Ok("lifetime") -> {
      let grant =
        list.fold([1, 2, 3], grant, fn(grant, _) {
          let assert Ok(#(held, reservation)) = run.reserve_write(grant, large)
            as "One original maximum frame reservation."
          assert connection.offer(reservation, large) == Ok(Nil)
          let assert Ok(run.WriteConsumed(frame)) =
            process.receive(events, 5000)
            as "Only original complete Unix write returns frame credit."
          let #(grant, consumed) = run.consume_write(held, frame)
          assert consumed == run.Consumed
          grant
        })
      assert run.reserve_write(grant, large) == Error(run.AllowanceExhausted)
      let tail = bit_array.from_string(string.repeat("z", 16_777_193))
      let assert Ok(tail) = run.from_wire(<<16_777_193:32, tail:bits>>)
        as "Exact remaining payload accounts for every earlier four-byte prefix."
      let assert Ok(#(held, reservation)) = run.reserve_write(grant, tail)
        as "Last original byte of lifetime allowance."
      assert connection.offer(reservation, tail) == Ok(Nil)
      let assert Ok(run.WriteConsumed(frame)) = process.receive(events, 5000)
        as "Complete original tail write consumed without lifetime refund."
      let #(grant, consumed) = run.consume_write(held, frame)
      assert consumed == run.Consumed
      let assert Ok(empty) = run.from_wire(<<0:32>>)
        as "Even empty payload owns a four-byte wire prefix."
      assert run.reserve_write(grant, empty) == Error(run.AllowanceExhausted)
    }
    _ -> {
      let assert Ok(#(held, reservation)) = run.reserve_write(grant, large)
        as "Second original write reservation."
      assert connection.offer(reservation, large) == Ok(Nil)
      await(root, "writer-started")
      let #(original, owner_door) = bridge.offer_fields(bridge.offer(owner))
      let assert Ok(binding) = wire.decode_binding(pin(), original)
        as "Original packet authority."
      let packets = [
        wire.ChunkAck(run.ToNode, 1, 0),
        wire.ChunkAck(run.ToNode, 2, 0),
        wire.ChunkAck(run.ToHost, 2, 0),
        wire.Consumed(run.ToNode, 1, run.Continue),
        wire.Consumed(run.ToNode, 3, run.Continue),
      ]
      list.each(packets, fn(packet) {
        let assert Ok(bytes) = wire.encode(binding, packet)
          as "Bounded stale or wrong packet."
        assert inject(owner_door, door, bytes) == Ok(Nil)
      })
      let assert Ok(wrong) = wire.binding(pin(), key, <<99:size(256)>>)
        as "Different original nonce."
      let assert Ok(bytes) =
        wire.encode(wrong, wire.Consumed(run.ToNode, 2, run.Continue))
        as "Wrong nonce bytes."
      assert inject(owner_door, door, bytes) == Ok(Nil)
      let assert Ok(bytes) =
        wire.encode(binding, wire.Consumed(run.ToNode, 2, run.Continue))
        as "Exact packet with foreign sender."
      assert foreign_sender(owner_door, bytes) == Ok(Nil)
      assert process.receive(events, 100) == Error(Nil)
      assert connection.offer(reservation, large)
        == Error(run.WindowUnavailable)
      assert run.consume_write(held, frame).1 == run.Ignored
    }
  }
  run.consume(last, run.Final)
  assert simplifile.write(root <> "/owner-final", "sent") == Ok(Nil)
  await(root, "reader-final")
  assert process.receive(events, 100) == Error(Nil)
  bridge.cancel(owner)
  let assert poll.Answered(Nil) =
    poll.until(5000, 10, fn() {
      case closed(bridge.pid(owner)) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "Actual original close result retained before collector attaches."
  let closed = connection.close()
  assert closed.transport == run.TransportJoined
  assert closed.resources != run.ResourcesReleased
  assert process.receive(events, 100) == Error(Nil)
  assert simplifile.write(
      root <> "/owner-success",
      "real_duplex_final_credit_and_join",
    )
    == Ok(Nil)
}

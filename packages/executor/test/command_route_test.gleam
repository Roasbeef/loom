//// Transport-only peers exercise real TLS BEAM and the production dispatcher.
//// The first four controls retain the original pure codec/coordinate assertions.
//// Three fixed two-node scripts use the actual public owner endpoint exchange
//// with unchanged canonical bytes and intentionally hostile counterpart replies.
//// They neither admit a Compile service nor grant native launch authority.
//// Production Compile admission is covered separately by its joined consumer.
////
//// `run_owner` and `run_executor` are fixed test administration entrypoints.
//// `beam_control` checks both OS process exits and explicit final witnesses;
//// the test counterpart mirrors only the existing bounded transfer vocabulary.

import broker/dispatch
import broker/exec
import broker/framing
import broker/policy
import command_route_beam_peer as peer
import core/clock
import core/command
import core/ids
import core/json
import core/msgpack as mp
import core/remote_tool
import core/workspace
import distribution_fixture as fixture
import executor/remote/beam_endpoint as endpoint
import executor/remote/dispatcher
import executor/remote/distribution
import executor/remote/identity
import executor/remote/internal/beam_protocol as protocol
import executor/remote/native
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import weft
import weft/poll

fn scope() -> identity.Scope {
  native_scope(2)
}

fn native_scope(number: Int) -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Session."
  let assert Ok(workspace) = identity.workspace_id("checkout") as "Workspace."
  let assert Ok(executor) = identity.executor_id("linux") as "Executor."
  let assert Ok(epoch) = identity.epoch(number) as "Session epoch."
  let assert Ok(workspace_epoch) = identity.epoch(7) as "Workspace epoch."
  identity.scope(session, workspace, executor, epoch, workspace_epoch)
}

fn key() -> identity.RequestKey {
  native_key(scope(), "00000000-0000-7000-8000-000000000002")
}

fn native_key(scope: identity.Scope, op: String) -> identity.RequestKey {
  let assert Ok(operation) = ids.parse_op_id(op) as "Operation."
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000008")
    as "Native UUID."
  identity.request_key(scope, operation, request)
}

fn ref(input: String, role: command.ServiceRole) -> command.CommandRef {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Session."
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Operation."
  let assert Ok(entry) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000004")
    as "Parent result."
  let assert Ok(parent) =
    remote_tool.key(session, op, "parent", 3, string.repeat("a", 64), entry)
    as "Full parent."
  let assert Ok(scope) =
    workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      2,
      7,
    )
    as "Core scope."
  let assert Ok(step) = workspace.step("physical:build") as "Physical step."
  let assert Ok(id) = ids.parse_entry_id("00000000-0000-7000-8000-000000000003")
    as "Original service UUID."
  let assert Ok(service) =
    command.service_key(
      parent,
      role,
      scope,
      op,
      step,
      id,
      input,
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Complete service."
  let assert Ok(ref) =
    command.command_ref(service, case role {
      command.CompileService -> command.CompileCommand
      command.LaunchService -> command.SatelliteCommand
    })
    as "Closed native role."
  ref
}

fn original() -> command.CommandRef {
  ref(string.repeat("d", 64), command.CompileService)
}

fn prepared() -> wire.Prepared {
  let assert Ok(registration) = wire.digest(<<1>>)
    as "Registration fixture digest."
  wire.Prepared(
    "physical:build",
    registration,
    wire.Finite(30_000),
    exec.ExecRequest(
      ["/bin/true"],
      [],
      "/work",
      Some(policy.workspace_default("/work")),
      <<7:size(256)>>,
      exec.PlatformEnforcement,
    ),
    wire.Logs,
  )
}

fn digest() -> identity.Digest {
  let assert Ok(value) = wire.prepared_digest(prepared())
    as "Exact Prepared digest."
  value
}

fn envelope(role: wire.Role, body: wire.Body) -> wire.Envelope {
  wire.Envelope(role, "owner", "linux", 1, scope(), body)
}

pub fn command_route_preserves_native_value_and_full_reference_test() {
  let p = prepared()
  let d = digest()
  let owner = [
    wire.ChallengeRequest(key(), d),
    wire.Submit(key(), d, p, <<0:size(256)>>, 5000),
    wire.Query(key(), d, 0),
    wire.Stdin(key(), d, 0, <<1>>, dispatch.EndOfInput),
    wire.Cancel(key(), d),
    wire.DurableReceipt(key(), d, d),
  ]
  let executor = [
    wire.Challenge(key(), d, <<0:size(256)>>, 1000),
    wire.Evidence(key(), d, 1, 123),
    wire.Output(key(), d, 0, <<1>>),
    wire.Terminal(key(), d, <<1>>),
    wire.Rejected(4),
  ]
  list.each([#(wire.Owner, owner), #(wire.Executor, executor)], fn(pair) {
    list.each(pair.1, fn(body) {
      let native = envelope(pair.0, body)
      let assert Ok(wrapped) = wire.command_envelope(original(), native)
        as "Correspondence validates."
      assert wire.command_ref(wrapped) == original()
      assert wire.native_envelope(wrapped) == native
      let assert Ok(bytes) = wire.encode_command(wrapped)
        as "One bounded frame."
      assert wire.decode_command(bytes, pair.0, "owner", "linux", scope())
        == Ok(wrapped)
      let assert Ok(mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue("loom.remote.command/1"),
        mp.StringValue(ref_json),
        native_value,
      ])) = wire.decode_value(bytes)
        as "Native value is nested directly."
      assert ref_json == json.to_string(command.encode_ref(original()))
      let assert Ok(native_bytes) = wire.encode(native)
        as "Original native encoding."
      assert wire.decode_value(native_bytes) == Ok(native_value)
      assert wire.decode(bytes, pair.0, "owner", "linux", scope())
        == Error(wire.Invalid)
    })
  })

  // A changed full input digest is preserved as distinct data, not ownership proof.
  let changed = ref(string.repeat("e", 64), command.CompileService)
  let assert Ok(value) =
    wire.command_envelope(
      changed,
      envelope(wire.Owner, wire.Query(key(), d, 0)),
    )
    as "Same coordinates may carry a different retained claim."
  assert wire.command_ref(value) != original()
  let launch = ref(string.repeat("e", 64), command.LaunchService)
  let assert Ok(_) =
    wire.command_envelope(launch, envelope(wire.Owner, wire.Query(key(), d, 0)))
    as "Satellite role uses the same closed transport."
}

pub fn command_route_refuses_cross_coordinates_and_administrative_bodies_test() {
  let d = digest()
  list.each([wire.Hello, wire.CloseScope], fn(body) {
    assert wire.command_envelope(original(), envelope(wire.Owner, body))
      == Error(wire.Invalid)
  })
  assert wire.command_envelope(
      original(),
      envelope(wire.Executor, wire.ScopeRetirement),
    )
    == Error(wire.Invalid)
  assert wire.command_envelope(
      original(),
      envelope(wire.Executor, wire.Query(key(), d, 0)),
    )
    == Error(wire.Invalid)
  let foreign_scope = native_scope(3)
  let foreign_key =
    native_key(foreign_scope, "00000000-0000-7000-8000-000000000002")
  assert wire.command_envelope(
      original(),
      wire.Envelope(
        ..envelope(wire.Owner, wire.Query(foreign_key, d, 0)),
        scope: foreign_scope,
      ),
    )
    == Error(wire.Invalid)
  // Native key encoding omits scope; construction must check the original key.
  assert wire.command_envelope(
      original(),
      envelope(wire.Owner, wire.Query(foreign_key, d, 0)),
    )
    == Error(wire.Invalid)

  let other_op = native_key(scope(), "00000000-0000-7000-8000-000000000009")
  assert wire.command_envelope(
      original(),
      envelope(wire.Owner, wire.Query(other_op, d, 0)),
    )
    == Error(wire.Invalid)
  assert wire.command_envelope(
      original(),
      envelope(
        wire.Owner,
        wire.Submit(
          key(),
          d,
          wire.Prepared(..prepared(), step: "wrong"),
          <<0:size(256)>>,
          5000,
        ),
      ),
    )
    == Error(wire.Invalid)
}

pub fn command_route_keeps_prepared_and_aggregate_limits_distinct_test() {
  let p = prepared()
  let env =
    list.index_map(list.repeat(Nil, 64), fn(_, i) {
      #("ENV" <> int.to_string(i), string.repeat("x", 2033))
    })
  let large = wire.Prepared(..p, request: exec.ExecRequest(..p.request, env:))
  let assert Ok(prepared_bytes) = wire.encode_prepared(large)
    as "Large but valid Prepared."
  assert bit_array.byte_size(prepared_bytes) == 131_063
  let native =
    envelope(
      wire.Owner,
      wire.Submit(key(), digest(), large, <<0:size(256)>>, 5000),
    )
  let assert Ok(value) = wire.command_envelope(original(), native)
    as "Native payload is bounded separately."
  let assert Ok(bytes) = wire.encode_command(value)
    as "Complete ref fits alongside native value."
  assert wire.decode_command(bytes, wire.Owner, "owner", "linux", scope())
    == Ok(value)

  assert bit_array.byte_size(bytes) > 131_072

  // Exact first-excess Prepared retains the same step and a legal native binary.
  let env =
    list.index_map(list.repeat(Nil, 64), fn(_, i) {
      #(
        "ENV" <> int.to_string(i),
        string.repeat("x", case i {
          0 -> 2043
          _ -> 2033
        }),
      )
    })
  let excess = wire.Prepared(..p, request: exec.ExecRequest(..p.request, env:))
  assert wire.encode_prepared(excess) == Error(wire.Invalid)
  let native =
    envelope(
      wire.Owner,
      wire.Submit(key(), digest(), excess, <<0:size(256)>>, 5000),
    )
  let assert Ok(raw) = wire.encode(native)
    as "Native frame remains within its aggregate ceiling."
  let assert Ok(mp.ArrayValue([
    _,
    _,
    _,
    _,
    _,
    _,
    _,
    mp.ArrayValue([_, _, prepared_value, _, _]),
  ])) = wire.decode_value(raw)
    as "Prepared is an unchanged native value."
  let assert Ok(excess_bytes) = mp.encode(prepared_value)
    as "The body has valid MessagePack syntax."
  assert bit_array.byte_size(excess_bytes) == 131_073
  assert wire.command_envelope(original(), native) == Error(wire.Invalid)
}

pub fn command_route_refuses_noncanonical_and_hostile_raw_framing_test() {
  let assert Ok(wrapped) =
    wire.command_envelope(
      original(),
      envelope(wire.Owner, wire.Query(key(), digest(), 0)),
    )
    as "Valid command."
  let assert Ok(bytes) = wire.encode_command(wrapped) as "Canonical bytes."
  let assert Ok(mp.ArrayValue([
    version,
    schema,
    mp.StringValue(ref_json),
    native_value,
  ])) = wire.decode_value(bytes)
    as "Inspect closed frame."
  let malformed = [
    mp.ArrayValue([
      version,
      schema,
      mp.StringValue(" " <> ref_json),
      native_value,
    ]),
    mp.ArrayValue([
      version,
      schema,
      mp.StringValue(string.repeat("x", 8193)),
      native_value,
    ]),
    mp.ArrayValue([
      version,
      schema,
      mp.StringValue(ref_json),
      mp.BinaryValue(bytes),
    ]),
    mp.ArrayValue([
      mp.IntValue(2),
      schema,
      mp.StringValue(ref_json),
      native_value,
    ]),
    mp.ArrayValue([
      version,
      schema,
      mp.StringValue(ref_json),
      native_value,
      mp.NilValue,
    ]),
  ]
  list.each(malformed, fn(value) {
    let assert Ok(raw) = mp.encode(value) as "Raw hostile MessagePack encodes."
    assert wire.decode_command(raw, wire.Owner, "owner", "linux", scope())
      == Error(wire.Invalid)
  })
  assert wire.decode_command(
      <<bytes:bits, 0>>,
      wire.Owner,
      "owner",
      "linux",
      scope(),
    )
    == Error(wire.Invalid)
  assert wire.decode_command(bytes, wire.Executor, "owner", "linux", scope())
    == Error(wire.Invalid)

  // Two legal binaries establish that the inherited native frame exceeds 128 KiB.
  let value =
    mp.ArrayValue([
      mp.BinaryValue(<<0:size(800_000)>>),
      mp.BinaryValue(<<0:size(800_000)>>),
    ])
  let assert Ok(raw) = wire.encode_value(value)
    as "Existing aggregate ceiling remains 256 KiB."
  assert bit_array.byte_size(raw) > 131_072
  assert wire.decode_value(raw) == Ok(value)
  assert wire.decode_value(<<0:size(2_097_160)>>) == Error(wire.Invalid)
}

type ReplyMode {
  Exact
  ChangedRef
  Plain
  ChangedGeneration
}

fn respond(exchange: peer.Exchange, body: wire.Body, mode: ReplyMode) {
  let native = case mode {
    ChangedGeneration ->
      wire.Envelope(..envelope(wire.Executor, body), generation: 2)
    Exact | ChangedRef | Plain -> envelope(wire.Executor, body)
  }
  let bytes = case mode {
    Plain -> {
      let assert Ok(bytes) = wire.encode(native) as "Plain hostile reply."
      bytes
    }
    Exact | ChangedRef | ChangedGeneration -> {
      let expected = case mode {
        ChangedRef -> ref(string.repeat("e", 64), command.CompileService)
        Exact | Plain | ChangedGeneration -> original()
      }
      let assert Ok(value) = wire.command_envelope(expected, native)
        as "Reply coordinates validate."
      let assert Ok(bytes) = wire.encode_command(value) as "Reply framing."
      bytes
    }
  }
  peer.respond(exchange, bytes)
}

pub fn command_exchange_requires_exact_ref_generation_and_wrapper_test() {
  beam_control(0)
}

fn command_exchange(config: endpoint.Config) {
  list.each([Exact, ChangedRef, Plain, ChangedGeneration], fn(mode) {
    let outcome =
      endpoint.exchange_command(
        config,
        original(),
        wire.Query(key(), digest(), 0),
      )
    assert outcome
      == case mode {
        Exact -> Ok(wire.Evidence(key(), digest(), 1, 123))
        ChangedRef | Plain | ChangedGeneration -> Error(endpoint.Uncertain)
      }
  })
}

fn exchange_peer(remote: peer.Peer) {
  list.each([Exact, ChangedRef, Plain, ChangedGeneration], fn(mode) {
    let value = peer.accept(remote, original())
    assert wire.native_envelope(peer.command(value)).body
      == wire.Query(key(), digest(), 0)
    respond(value, wire.Evidence(key(), digest(), 1, 123), mode)
  })
}

fn owner_request(
  p: wire.Prepared,
  events: process.Subject(dispatch.Terminal),
  chunks: process.Subject(dispatch.Chunk),
) -> dispatch.Dispatch {
  let #(_, op, _) = command.coordinates(command.service(original()))
  dispatch.Dispatch(
    dispatch.CallContext(op, p.step, Some(command.native_origin(original()))),
    p.request,
    1,
    poll.monotonic().now() + 30_000,
    clock.from_function(poll.monotonic().now),
    None,
    fn(chunk) { process.send(chunks, chunk) },
    fn(value) { process.send(events, value) },
  )
}

pub fn command_dispatcher_retains_route_through_output_stdin_and_receipt_test() {
  beam_control(1)
}

fn dispatcher_owner(config: endpoint.Config, root: String) {
  let terminal =
    dispatch.Failed(exec.ProtocolViolation("transport-only terminal"))
  let chunk = dispatch.Chunk(framing.Stdout, <<42>>, 1, False)
  let assert Ok(output) = native.encode_output(chunk)
    as "Actual native output codec."
  let assert Ok(bytes) = native.encode_terminal(terminal)
    as "Actual native terminal codec."

  // Original owner receipt custody precedes the peer's DurableReceipt ask.
  let received = process.new_subject()
  let events = process.new_subject()
  let chunks = process.new_subject()
  let adapter =
    dispatcher.dispatcher(dispatcher.Config(
      config,
      1,
      10_000,
      fn(_) { Ok(dispatcher.CommandReserved(key(), prepared(), original())) },
      fn(origin, k, d, outputs, terminal_bytes) {
        assert origin == command.native_origin(original())
          && k == key()
          && d == digest()
        assert outputs == [output] && terminal_bytes == bytes
        process.send(received, Nil)
        Ok(Nil)
      },
      fn(_, _) { Nil },
      fn(_) { Nil },
      poll.monotonic().now,
    ))
  let assert Ok(execution) =
    adapter.start(owner_request(prepared(), events, chunks))
    as "Guarantor owns route before send."

  // Queue stdin while Submit is held, before its response enables polling.
  peer.await(root, "submit.seen")
  execution.stdin(<<7>>, dispatch.EndOfInput)
  peer.mark(root, "begin.queries")
  assert process.receive(chunks, 3000) == Ok(chunk)
  assert process.receive(received, 3000) == Ok(Nil)
  assert process.receive(events, 3000) == Ok(terminal)
  peer.await(root, "executor.finished")
  execution.release()
}

fn dispatcher_peer(remote: peer.Peer, root: String) {
  let terminal =
    dispatch.Failed(exec.ProtocolViolation("transport-only terminal"))
  let chunk = dispatch.Chunk(framing.Stdout, <<42>>, 1, False)
  let assert Ok(output) = native.encode_output(chunk)
    as "Actual native output codec."
  let assert Ok(bytes) = native.encode_terminal(terminal)
    as "Actual native terminal codec."
  let assert Ok(terminal_digest) = wire.digest(bytes)
    as "Receipt binds exact terminal."
  let value = peer.accept(remote, original())
  assert wire.native_envelope(peer.command(value)).body
    == wire.ChallengeRequest(key(), digest())
  respond(value, wire.Challenge(key(), digest(), <<1:size(256)>>, 1000), Exact)
  let value = peer.accept(remote, original())
  let assert wire.Submit(k, d, p, <<1:size(256)>>, budget) =
    wire.native_envelope(peer.command(value)).body
    as "Original immutable Prepared submitted once."
  assert k == key()
    && d == digest()
    && p == prepared()
    && budget > 0
    && budget < 30_000

  // The barrier preserves the original peer-owned stdin-before-query order.
  peer.mark(root, "submit.seen")
  peer.await(root, "begin.queries")
  respond(value, wire.Evidence(key(), digest(), 1, 123), Exact)
  let value = peer.accept(remote, original())
  assert wire.native_envelope(peer.command(value)).body
    == wire.Stdin(key(), digest(), 0, <<7>>, dispatch.EndOfInput)
  respond(value, wire.Evidence(key(), digest(), 1, 123), Exact)
  let value = peer.accept(remote, original())
  assert wire.native_envelope(peer.command(value)).body
    == wire.Query(key(), digest(), 0)
  respond(value, wire.Output(key(), digest(), 0, output), Exact)
  let value = peer.accept(remote, original())
  assert wire.native_envelope(peer.command(value)).body
    == wire.Query(key(), digest(), 1)
  respond(value, wire.Terminal(key(), digest(), bytes), Exact)

  // Terminal observation alone is not the separately committed owner receipt.
  let value = peer.accept(remote, original())
  assert wire.native_envelope(peer.command(value)).body
    == wire.DurableReceipt(key(), digest(), terminal_digest)
  respond(value, wire.Evidence(key(), digest(), 1, 123), Exact)
}

pub fn command_dispatcher_detached_cancel_retains_route_test() {
  beam_control(2)
}

fn cancel_owner(config: endpoint.Config, root: String) {
  let events = process.new_subject()
  let chunks = process.new_subject()
  let adapter =
    dispatcher.dispatcher(dispatcher.Config(
      config,
      1,
      10_000,
      fn(_) { Ok(dispatcher.CommandReserved(key(), prepared(), original())) },
      fn(_, _, _, _, _) { Error(Nil) },
      fn(_, _) { Nil },
      fn(_) { Nil },
      poll.monotonic().now,
    ))
  let assert Ok(execution) =
    adapter.start(owner_request(prepared(), events, chunks))
    as "Command reservation."
  peer.await(root, "challenged")
  execution.cancel()
  peer.await(root, "cancel.replied")
  let assert Ok(bytes) = simplifile.read_bits(root <> "/cancel.command")
    as "The peer retains its exact decoded cancellation witness."
  let assert Ok(cancelled) =
    wire.decode_command(bytes, wire.Owner, "owner", "linux", scope())
    as "Detached Cancel carries a decoded command route."
  assert wire.command_ref(cancelled) == original()
  assert wire.native_envelope(cancelled).body == wire.Cancel(key(), digest())
  assert process.receive(events, 3000)
    == Ok(dispatch.Failed(exec.ExecutionLost(exec.RemoteOutcomeUncertain)))

  // The response barrier follows consumption of its last returned chunk.
  // Original Challenge observation is still held until the owner releases it.
  peer.mark(root, "release.challenge")
  peer.await(root, "executor.finished")
  execution.release()
}

fn cancel_peer(remote: peer.Peer, root: String) {
  let challenge = peer.accept(remote, original())
  assert wire.native_envelope(peer.command(challenge)).body
    == wire.ChallengeRequest(key(), digest())
  peer.mark(root, "challenged")
  let value = peer.accept(remote, original())
  assert wire.command_ref(peer.command(value)) == original()
  assert wire.native_envelope(peer.command(value)).body
    == wire.Cancel(key(), digest())
  let assert Ok(bytes) = wire.encode_command(peer.command(value))
    as "Exact cancelled command bytes."
  assert simplifile.write_bits(root <> "/cancel.command", bytes) == Ok(Nil)
  respond(value, wire.Evidence(key(), digest(), 1, 123), Exact)
  peer.mark(root, "cancel.replied")
  peer.await(root, "release.challenge")
}

/// Runs only one fixed owner script after its original actual TLS membership boot.
///
/// ## Examples
///
/// ```gleam
/// command_route_test.run_owner(provisioned_file, root, 0)
/// // -> Nil after exact and hostile full-reference replies are checked.
/// ```
pub fn run_owner(provisioned: String, root: String, scenario: Int) -> Nil {
  let assert Ok(value) = fixture.read_provisioned(provisioned)
    as "Trusted finite fixture."
  let assert Ok(membership) = distribution.start(value.owner_config)
    as "Actual TLS owner boot."
  let assert Ok(remote) = distribution.peer(membership, value.executor_name)
    as "Original opaque Peer."
  peer.await(root, "executor.ready")
  let config = endpoint.Config(remote, "owner", "linux", scope(), 1, 3000)
  case scenario {
    0 -> command_exchange(config)
    1 -> dispatcher_owner(config, root)
    2 -> cancel_owner(config, root)
    _ -> panic as "Only three fixed owner transport scripts exist."
  }
  peer.await(root, "executor.finished")
  peer.mark(root, "owner.finished")
  io.println("COMMAND_ROUTE_OWNER_COMPLETE")
}

/// Publishes the fixed transport counterpart, without a concrete effect service.
///
/// ## Examples
///
/// ```gleam
/// command_route_test.run_executor(provisioned_file, root, 1)
/// // -> Nil after the original scripted command route is consumed exactly.
/// ```
pub fn run_executor(provisioned: String, root: String, scenario: Int) -> Nil {
  let assert Ok(value) = fixture.read_provisioned(provisioned)
    as "Trusted finite fixture."
  let assert Ok(membership) = distribution.start(value.executor_config)
    as "Actual TLS executor boot."
  let assert Ok(owner) = distribution.peer(membership, value.owner_name)
    as "Original authenticated owner."
  let remote =
    peer.publish(owner, protocol.Binding("owner", "linux", 1, scope()))
  peer.mark(root, "executor.ready")
  case scenario {
    0 -> exchange_peer(remote)
    1 -> dispatcher_peer(remote, root)
    2 -> cancel_peer(remote, root)
    _ -> panic as "Only three fixed counterpart scripts exist."
  }
  peer.mark(root, "executor.finished")

  // Fixed discovery remains live until the owner retires its original observer.
  // A remote endpoint death must not race the final consumed reply handoff.
  peer.await(root, "owner.finished")
  io.println("COMMAND_ROUTE_EXECUTOR_COMPLETE")
}

fn beam_control(scenario: Int) -> Nil {
  let assert Ok(here) = simplifile.current_directory()
    as "Actual package directory."
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/command-route-beam-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(value) = fixture.provision(root, "command_route")
    as "Actual private TLS membership credentials."
  let provisioned = root <> "/fixture.term"
  assert fixture.write_provisioned(value, provisioned) == Ok(Nil)

  // Both runtimes boot from the original provisioned membership credentials.
  let owner =
    node_arguments(
      value.owner_options,
      "run_owner",
      provisioned,
      root,
      scenario,
    )
  let executor =
    node_arguments(
      value.executor_options,
      "run_executor",
      provisioned,
      root,
      scenario,
    )
  let erl = fixture.current_executable()
  let owner_home = distribution.bootstrap_home(value.owner_config)
  let executor_home = distribution.bootstrap_home(value.executor_config)

  // Original task outcomes join both OS nodes before credential cleanup.
  let outcomes =
    weft.new([
      fn() { fixture.run_node(erl, owner, here, owner_home) },
      fn() { fixture.run_node(erl, executor, here, executor_home) },
    ])
    |> weft.deadline(90_000)
    |> weft.start
  let assert [
    weft.Completed(_, #(owner_exit, owner_output)),
    weft.Completed(_, #(executor_exit, executor_output)),
  ] = outcomes
    as "Both original independent OS nodes finish under the finite bound."

  // Final witnesses follow every scripted assertion and the original teardown.
  io.println(owner_output)
  io.println(executor_output)
  assert owner_exit == 0 && executor_exit == 0
  assert string.contains(owner_output, "COMMAND_ROUTE_OWNER_COMPLETE")
  assert string.contains(executor_output, "COMMAND_ROUTE_EXECUTOR_COMPLETE")
  assert simplifile.delete(root) == Ok(Nil)
}

fn node_arguments(
  options: String,
  role: String,
  provisioned: String,
  root: String,
  scenario: Int,
) -> List(String) {
  let expression =
    "try command_route_test:"
    <> role
    <> "(<<\""
    <> provisioned
    <> "\">>,<<\""
    <> root
    <> "\">>,"
    <> int.to_string(scenario)
    <> "),erlang:halt(0,[{flush,true}]) catch C:R:S->io:format(standard_error,\"fixed route runner failed ~p:~p~n~p~n\",[C,R,S]),erlang:halt(1,[{flush,true}]) end."
  list.append(fixture.node_arguments(options), ["-noshell", "-eval", expression])
}

//// Transport-only peers exercise the real pinned TLS and dispatcher engines.
//// They neither admit a Compile service nor grant native launch authority.
//// The peer requires the full ref on every frame, while native baseline tests
//// continue exercising the existing production native service independently.

import broker/dispatch
import broker/exec
import broker/framing
import broker/policy
import core/clock
import core/command
import core/ids
import core/json
import core/msgpack as mp
import core/remote_tool
import core/workspace
import executor/remote/connection
import executor/remote/dispatcher
import executor/remote/identity
import executor/remote/native
import executor/remote/tls
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import remote_tls_test
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

fn settings(
  local: remote_tls_test.Credentials,
  peer: remote_tls_test.Credentials,
) -> tls.Settings {
  let assert Ok(value) =
    tls.settings(
      local.ca,
      local.certificate,
      local.key,
      peer.pin,
      2000,
      1000,
      200,
    )
    as "Pinned fixture TLS."
  value
}

fn transport() -> #(connection.Config, tls.Listener) {
  let f = remote_tls_test.fixture()
  assert tls.start() == Ok(Nil)
  let assert Ok(listener) =
    tls.listen(settings(f.server, f.client), tls.Loopback, 0)
    as "Real loopback listener."
  let assert Ok(port) = tls.port(listener) as "Ephemeral fixture port."
  #(
    connection.Config(
      settings(f.client, f.server),
      "localhost",
      port,
      3000,
      "owner",
      "linux",
      1,
      scope(),
    ),
    listener,
  )
}

fn accept_raw(listener: tls.Listener) -> #(tls.Connection, BitArray) {
  let assert Ok(socket) = tls.accept(listener)
    as "Authenticated transport-only peer."
  let assert Ok(bytes) = tls.receive(socket) as "Ordinary Hello."
  assert wire.decode(bytes, wire.Owner, "owner", "linux", scope())
    == Ok(envelope(wire.Owner, wire.Hello))
  let assert Ok(hello) = wire.encode(envelope(wire.Executor, wire.Hello))
    as "Native Hello reply."
  assert tls.send(socket, hello) == Ok(Nil)
  let assert Ok(bytes) = tls.receive(socket) as "Command frame follows Hello."
  #(socket, bytes)
}

fn accept(listener: tls.Listener) -> #(tls.Connection, wire.CommandEnvelope) {
  let #(socket, bytes) = accept_raw(listener)
  let assert Ok(command) =
    wire.decode_command(bytes, wire.Owner, "owner", "linux", scope())
    as "Real command wrapper decoded."
  assert wire.command_ref(command) == original()
  #(socket, command)
}

fn respond(socket: tls.Connection, body: wire.Body, mode: ReplyMode) {
  let native = case mode {
    ChangedGeneration ->
      wire.Envelope(..envelope(wire.Executor, body), generation: 2)
    _ -> envelope(wire.Executor, body)
  }
  let bytes = case mode {
    Plain -> {
      let assert Ok(bytes) = wire.encode(native) as "Plain hostile reply."
      bytes
    }
    Exact | ChangedRef | ChangedGeneration -> {
      let ref = case mode {
        ChangedRef -> ref(string.repeat("e", 64), command.CompileService)
        _ -> original()
      }
      let assert Ok(value) = wire.command_envelope(ref, native)
        as "Reply coordinates validate."
      let assert Ok(bytes) = wire.encode_command(value) as "Reply framing."
      bytes
    }
  }
  assert tls.send(socket, bytes) == Ok(Nil)
  tls.close(socket)
}

pub fn command_exchange_requires_exact_ref_generation_and_wrapper_test() {
  let #(config, listener) = transport()
  list.each([Exact, ChangedRef, Plain, ChangedGeneration], fn(mode) {
    let done = process.new_subject()
    let _ =
      process.spawn_unlinked(fn() {
        let #(socket, value) = accept(listener)
        assert wire.native_envelope(value).body
          == wire.Query(key(), digest(), 0)
        respond(socket, wire.Evidence(key(), digest(), 1, 123), mode)
        process.send(done, Nil)
      })
    let outcome =
      connection.exchange_command(
        config,
        original(),
        wire.Query(key(), digest(), 0),
      )
    assert outcome
      == case mode {
        Exact -> Ok(wire.Evidence(key(), digest(), 1, 123))
        _ -> Error(connection.Uncertain)
      }
    assert process.receive(done, 3000) == Ok(Nil)
  })
  tls.close_listener(listener)
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
  let #(config, listener) = transport()
  let done = process.new_subject()
  let submit_seen = process.new_subject()
  let terminal =
    dispatch.Failed(exec.ProtocolViolation("transport-only terminal"))
  let chunk = dispatch.Chunk(framing.Stdout, <<42>>, 1, False)
  let assert Ok(output) = native.encode_output(chunk)
    as "Actual native output codec."
  let assert Ok(bytes) = native.encode_terminal(terminal)
    as "Actual native terminal codec."
  let assert Ok(terminal_digest) = wire.digest(bytes)
    as "Receipt binds exact terminal."
  let _ =
    process.spawn_unlinked(fn() {
      let #(socket, value) = accept(listener)
      assert wire.native_envelope(value).body
        == wire.ChallengeRequest(key(), digest())
      respond(
        socket,
        wire.Challenge(key(), digest(), <<1:size(256)>>, 1000),
        Exact,
      )
      let #(socket, value) = accept(listener)
      let assert wire.Submit(k, d, p, <<1:size(256)>>, budget) =
        wire.native_envelope(value).body
        as "Original immutable Prepared submitted once."
      assert k == key()
        && d == digest()
        && p == prepared()
        && budget > 0
        && budget < 30_000
      let begin_queries = process.new_subject()
      process.send(submit_seen, begin_queries)
      assert process.receive(begin_queries, 3000) == Ok(Nil)
      respond(socket, wire.Evidence(key(), digest(), 1, 123), Exact)
      let #(socket, value) = accept(listener)
      assert wire.native_envelope(value).body
        == wire.Stdin(key(), digest(), 0, <<7>>, dispatch.EndOfInput)
      respond(socket, wire.Evidence(key(), digest(), 1, 123), Exact)
      let #(socket, value) = accept(listener)
      assert wire.native_envelope(value).body == wire.Query(key(), digest(), 0)
      respond(socket, wire.Output(key(), digest(), 0, output), Exact)
      let #(socket, value) = accept(listener)
      assert wire.native_envelope(value).body == wire.Query(key(), digest(), 1)
      respond(socket, wire.Terminal(key(), digest(), bytes), Exact)
      let #(socket, value) = accept(listener)
      assert wire.native_envelope(value).body
        == wire.DurableReceipt(key(), digest(), terminal_digest)
      respond(socket, wire.Evidence(key(), digest(), 1, 123), Exact)
      process.send(done, Nil)
    })
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
  let assert Ok(begin_queries) = process.receive(submit_seen, 3000)
    as "Peer owns its query barrier."
  execution.stdin(<<7>>, dispatch.EndOfInput)
  process.send(begin_queries, Nil)
  assert process.receive(chunks, 3000) == Ok(chunk)
  assert process.receive(received, 3000) == Ok(Nil)
  assert process.receive(events, 3000) == Ok(terminal)
  assert process.receive(done, 3000) == Ok(Nil)
  execution.release()
  tls.close_listener(listener)
}

pub fn command_dispatcher_detached_cancel_retains_route_test() {
  let #(config, listener) = transport()
  let challenged = process.new_subject()
  let cancelled = process.new_subject()
  let cancel_finished = process.new_subject()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let #(socket, value) = accept(listener)
      assert wire.native_envelope(value).body
        == wire.ChallengeRequest(key(), digest())
      let release_peer = process.new_subject()
      process.send(challenged, release_peer)
      let _ =
        weft.new([
          fn() {
            let #(cancel_socket, raw) = accept_raw(listener)
            let value =
              wire.decode_command(raw, wire.Owner, "owner", "linux", scope())
            process.send(cancelled, value)
            case value {
              Ok(value) -> {
                assert wire.command_ref(value) == original()
                assert wire.native_envelope(value).body
                  == wire.Cancel(key(), digest())
                respond(
                  cancel_socket,
                  wire.Evidence(key(), digest(), 1, 123),
                  Exact,
                )
                Ok(Nil)
              }
              Error(_) -> {
                tls.close(cancel_socket)
                Error(Nil)
              }
            }
          },
        ])
        |> weft.deadline(3000)
        |> weft.start_relayed(to: cancel_finished)
      assert process.receive(release_peer, 3000) == Ok(Nil)
      tls.close(socket)
      process.send(done, Nil)
    })
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
  let assert Ok(release_peer) = process.receive(challenged, 3000)
    as "Peer owns its cancellation barrier."
  execution.cancel()
  let assert Ok(Ok(cancelled)) = process.receive(cancelled, 3000)
    as "Detached Cancel carries a decoded command route."
  assert wire.command_ref(cancelled) == original()
  assert wire.native_envelope(cancelled).body == wire.Cancel(key(), digest())
  assert process.receive(events, 3000)
    == Ok(dispatch.Failed(exec.ExecutionLost(exec.RemoteOutcomeUncertain)))

  // The decoded route is an early witness. The managed peer outcome also
  // proves the response succeeded before release can close its client.
  let assert Ok(weft.PulledOutcome(weft.Completed(_, Nil))) =
    process.receive(cancel_finished, 3000)
    as "Cancel peer replied successfully before teardown."
  process.send(release_peer, Nil)
  assert process.receive(done, 3000) == Ok(Nil)
  execution.release()
  tls.close_listener(listener)
}

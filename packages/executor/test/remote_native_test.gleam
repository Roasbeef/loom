//// Component integration uses actual pinned TLS, SQLite and local native helpers.
//// No prerequisite skip is a passing result. Two-host shipped E2E is root-owned.

import broker/dispatch
import broker/exec
import broker/executor as local
import broker/policy
import core/clock
import core/ids
import core/msgpack as mp
import core/remote_tool
import executor
import executor/remote/admission
import executor/remote/connection
import executor/remote/dispatcher
import executor/remote/identity
import executor/remote/journal
import executor/remote/listener as remote_listener
import executor/remote/native
import executor/remote/payload
import executor/remote/service
import executor/remote/tls
import executor/remote/wire
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import gleam/time/timestamp
import remote_tls_test
import simplifile
import telemetry/log
import weft
import weft/actor
import weft/poll

// The standard library exposes individual process liveness, but not a VM
// census. This test-only BIF detects request actors surviving scoped drain.
@external(erlang, "erlang", "processes")
fn live_processes() -> List(process.Pid)

@external(erlang, "executor_remote_tls_test_ffi", "fixture")
fn tls_fixture() -> remote_tls_test.Fixture

fn scope() -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
  let assert Ok(workspace) = identity.workspace_id("resident")
  let assert Ok(executor) = identity.executor_id("linux")
  let assert Ok(epoch) = identity.epoch(1)
  identity.scope(session, workspace, executor, epoch, epoch)
}

fn key(number: Int) -> identity.RequestKey {
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
  let assert Ok(request) =
    identity.request_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), to: 12, with: "0"),
    )
  identity.request_key(scope(), operation, request)
}

fn digest() -> identity.Digest {
  let assert Ok(value) = identity.digest(<<1:size(256)>>)
  value
}

fn directory(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    here
    <> "/build/remote-native/"
    <> name
    <> int.to_string(seconds)
    <> int.to_string(nanos)
  let assert Ok(Nil) = simplifile.create_directory_all(path <> "/scratch/tmp")
  path
}

fn native_service(path: String) -> local.Executor {
  native_service_gated(path, None)
}

type CheckoutRelease {
  RefuseCheckout
  LendHelper
}

fn native_service_gated(
  path: String,
  gate: Option(process.Subject(process.Subject(Nil))),
) -> local.Executor {
  native_service_controlled(
    path,
    option.map(gate, fn(subject) { #(subject, RefuseCheckout) }),
  )
}

fn native_service_controlled(
  path: String,
  gate: Option(#(process.Subject(process.Subject(Nil)), CheckoutRelease)),
) -> local.Executor {
  let assert Ok(here) = simplifile.current_directory()
  let helper = here <> "/../sandbox/loom-exec"
  assert simplifile.is_file(helper) == Ok(True)
  let base = executor.base_policy(path)
  let spawn =
    exec.SpawnConfig(
      helper_path: helper,
      shell_path: "/bin/sh",
      base_policy: base,
      helper_args: [],
      tmp_dir: path <> "/scratch/tmp",
      handshake_timeout_ms: 3000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    )
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() { exec.prepare_helper(spawn) })
  let assert Ok(native) =
    local.start(local.ExecutorConfig(
      checkout: fn() {
        case gate {
          None -> exec.checkout(pool, waiting: 3000)
          Some(#(gate, release)) -> {
            let permit = process.new_subject()
            process.send(gate, permit)
            let assert Ok(Nil) = process.receive(permit, 3000)
              as "Deterministic checkout fault must be released by the test."
            case release {
              RefuseCheckout -> Error(exec.PoolUnavailable)
              LendHelper -> exec.checkout(pool, waiting: 3000)
            }
          }
        }
      },
      checkin: fn(helper) { exec.checkin(pool, helper) },
      custody: fn() { exec.pool_custody(pool, waiting: 1000) },
      close_helpers: fn(ms) { exec.close_pool(pool, waiting: ms) },
      incarnation: 17,
      log: log.discard(),
    ))
  native
}

fn prepared(path: String, shell: String) -> wire.Prepared {
  let base = executor.base_policy(path)
  let policy =
    policy.SandboxPolicy(
      ..base,
      limits: policy.Limits(
        cpu_s: 10,
        wall_s: 2,
        mem_bytes: 268_435_456,
        pids: 128,
        fsize_bytes: 1_048_576,
        output_bytes: 131_072,
      ),
    )
  wire.Prepared(
    "exec",
    digest(),
    wire.Finite(10_000),
    exec.ExecRequest(
      ["/bin/sh", "-c", shell],
      [],
      path,
      Some(policy),
      <<7:size(256)>>,
      exec.PlatformEnforcement,
    ),
    wire.Logs,
  )
}

fn endpoint(
  path: String,
  native: local.Executor,
  generation: Int,
) -> #(service.Service, journal.Journal) {
  let assert Ok(capacity) = admission.capacity(8)
  let assert Ok(journal) =
    journal.fresh(path <> "/custody.sqlite", scope(), capacity)
  let assert Ok(service) =
    service.start(service.Config(
      "owner",
      "linux",
      scope(),
      generation,
      journal,
      native,
      fn(_, request) {
        // Fixture registration is administrative and independent of argv/cwd.
        case request.registration == digest() && request.request.cwd == path {
          True -> Ok(Nil)
          False -> Error(Nil)
        }
      },
      poll.monotonic().now,
    ))
  #(service, journal)
}

fn envelope(body: wire.Body, generation: Int) -> wire.Envelope {
  wire.Envelope(wire.Owner, "owner", "linux", generation, scope(), body)
}

fn submit(
  service: service.Service,
  request: wire.Prepared,
  number: Int,
) -> #(identity.Digest, wire.Body) {
  let assert Ok(digest) = wire.prepared_digest(request)
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    service.exchange(
      service,
      envelope(wire.ChallengeRequest(key(number), digest), 1),
    )
  let assert Ok(body) =
    service.exchange(
      service,
      envelope(wire.Submit(key(number), digest, request, nonce, 5000), 1),
    )
  #(digest, body)
}

fn terminal(
  service: service.Service,
  number: Int,
  digest: identity.Digest,
) -> BitArray {
  let outcome =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case
        service.exchange(
          service,
          envelope(wire.Query(key(number), digest, 64), 1),
        )
      {
        Ok(wire.Terminal(_, _, bytes)) -> poll.Done(bytes)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
  let assert poll.Answered(bytes) = outcome
    as "Native execution must settle, never skip."
  bytes
}

fn credentials(
  local: remote_tls_test.Credentials,
  peer: remote_tls_test.Credentials,
) -> tls.Settings {
  let assert Ok(settings) =
    tls.settings(
      local.ca,
      local.certificate,
      local.key,
      peer.pin,
      1000,
      1000,
      500,
    )
  settings
}

fn transport(
  service: service.Service,
) -> #(connection.Config, tls.Listener, weft.Cancel, process.Subject(Nil)) {
  assert tls.start() == Ok(Nil)
  let fixture = tls_fixture()
  let assert Ok(listener) =
    tls.listen(credentials(fixture.server, fixture.client), tls.Loopback, 0)
  let assert Ok(port) = tls.port(listener)
  let stop = weft.cancel_signal()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let _ =
        weft.new(list.repeat(
          fn() { connection.serve_one(listener, service, 3000) },
          256,
        ))
        |> weft.limit(4)
        |> weft.cancel_with(stop)
        |> weft.deadline(15_000)
        |> weft.start
      process.send(done, Nil)
    })
  #(
    connection.Config(
      credentials(fixture.client, fixture.server),
      "localhost",
      port,
      2500,
      "owner",
      "linux",
      1,
      scope(),
    ),
    listener,
    stop,
    done,
  )
}

fn stop_transport(
  listener: tls.Listener,
  stop: weft.Cancel,
  done: process.Subject(Nil),
) {
  weft.cancel(stop)
  assert process.receive(done, 4000) == Ok(Nil)
  tls.close_listener(listener)
}

pub fn wire_bounds_versions_roles_schema_and_canonical_payload_test() {
  let path = directory("wire")
  let request = prepared(path, "printf wire")
  let assert Ok(digest) = wire.prepared_digest(request)
  let body = wire.Submit(key(1), digest, request, <<0:size(256)>>, 5000)
  let assert Ok(bytes) = wire.encode(envelope(body, 1))
  assert wire.decode(bytes, wire.Owner, "owner", "linux", scope())
    == Ok(envelope(body, 1))
  assert wire.decode(bytes, wire.Executor, "owner", "linux", scope())
    == Error(wire.Invalid)
  assert wire.decode(bytes, wire.Owner, "other-owner", "linux", scope())
    == Error(wire.Invalid)
  let assert Ok(mp.ArrayValue(fields)) = mp.decode(bytes)
  let assert Ok(wrong_version) =
    mp.encode(mp.ArrayValue([mp.IntValue(2), ..list.drop(fields, 1)]))
  assert wire.decode(wrong_version, wire.Owner, "owner", "linux", scope())
    == Error(wire.Invalid)
  let bad_array = <<0xdd, 65_536:size(32)>>
  assert wire.decode_value(bad_array) == Error(wire.Invalid)
  assert wire.decode_value(<<0xc6, 200_000:size(32)>>) == Error(wire.Invalid)
  assert wire.decode_value(<<
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0x91,
      0,
    >>)
    == Error(wire.Invalid)
  let assert Ok(native) = wire.encode_prepared(request)
  assert wire.decode_prepared(native) == Ok(request)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn exact_payloads_duplicate_conflict_and_recovery_remain_after_compaction_test() {
  let path = directory("payload")
  let assert Ok(capacity) = admission.capacity(1)
  let assert Ok(book) =
    journal.fresh(path <> "/custody.sqlite", scope(), capacity)
  let item = payload.Request(<<1, 2, 3>>)
  assert journal.put_payload(book, key(1), digest(), item) == Ok(Nil)
  assert journal.put_payload(book, key(1), digest(), item) == Ok(Nil)
  assert journal.put_payload(book, key(1), digest(), payload.Request(<<9>>))
    == Error(journal.Rejected(admission.ResultConflict))
  assert journal.put_payload(book, key(2), digest(), item)
    == Error(journal.Rejected(admission.Saturated))
  let assert Ok(_) = journal.admit(book, key(1), digest())
  let assert Ok(_) =
    journal.apply(book, key(1), digest(), admission.AuthorizeLaunch)
  assert journal.put_payload(
      book,
      key(1),
      digest(),
      payload.Output(0, <<4, 5>>),
    )
    == Ok(Nil)
  assert journal.put_payload(book, key(1), digest(), payload.Terminal(<<6, 7>>))
    == Ok(Nil)
  let assert Ok(result_digest) = wire.digest(<<6, 7>>)
  let assert Ok(_) =
    journal.apply(
      book,
      key(1),
      digest(),
      admission.ObserveTerminal(result_digest),
    )
  assert journal.apply(book, key(1), digest(), admission.Compact)
    == Error(journal.Rejected(admission.NotForgettable))
  let assert Ok(_) =
    journal.apply(
      book,
      key(1),
      digest(),
      admission.ConfirmOwnerReceipt(result_digest),
    )
  assert journal.apply(book, key(1), digest(), admission.Compact)
    == Error(journal.Rejected(admission.NotForgettable))
  let assert Ok(_) =
    journal.apply(book, key(1), digest(), admission.ConfirmRetirement)
  let assert Ok(_) = journal.apply(book, key(1), digest(), admission.Compact)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(recovered) =
    journal.recover(path <> "/custody.sqlite", scope(), capacity)
  assert journal.payloads(recovered, key(1), digest())
    == Ok([item, payload.Output(0, <<4, 5>>), payload.Terminal(<<6, 7>>)])
  assert journal.release(recovered) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn real_native_duplicate_submission_lost_ack_and_receipt_never_launch_twice_test() {
  let path = directory("once")
  let native = native_service(path)
  let #(service, book) = endpoint(path, native, 1)
  let request = prepared(path, "printf x >> " <> path <> "/proof")
  let #(digest, first) = submit(service, request, 1)
  let assert wire.Evidence(_, _, 2, deadline) = first
  let bytes = terminal(service, 1, digest)
  let assert Ok(dispatch.Completed(result)) = native.decode_terminal(bytes)
  assert result.code == 0
  // Discarded admission and terminal replies cannot grant a second launch.
  assert service.exchange(
      service,
      envelope(wire.Submit(key(1), digest, request, <<0:size(256)>>, 8000), 1),
    )
    == Ok(wire.Terminal(key(1), digest, bytes))
  let assert Ok(evidence) = journal.inspect(book, key(1), digest)
  let assert admission.Terminal(
    _,
    admission.NativeUnconfirmed,
    admission.ReceiptPending,
  ) = admission.phase(evidence)
  let assert Ok(result_digest) = wire.digest(bytes)
  let receipt = envelope(wire.DurableReceipt(key(1), digest, result_digest), 1)
  let _lost_receipt_reply = service.exchange(service, receipt)
  assert service.exchange(service, receipt)
    == Ok(wire.Terminal(key(1), digest, bytes))
  assert simplifile.read(path <> "/proof") == Ok("x")
  let assert Ok(retained) = journal.payloads(book, key(1), digest)
  let assert Ok(payload.Authority(authority)) =
    list.find(retained, fn(item) {
      case item {
        payload.Authority(_) -> True
        _ -> False
      }
    })
  let assert Ok(mp.ArrayValue([_, mp.IntValue(original), _])) =
    wire.decode_value(authority)
  assert original == deadline
  assert service.exchange(service, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  let assert Ok(_) = journal.apply(book, key(1), digest, admission.Compact)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn stale_generation_and_conflicting_digest_fail_before_mutation_test() {
  let path = directory("generation")
  let native = native_service(path)
  let #(service, book) = endpoint(path, native, 1)
  let request = prepared(path, "printf x >> " <> path <> "/proof")
  let assert Ok(digest) = wire.prepared_digest(request)
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    service.exchange(
      service,
      envelope(wire.ChallengeRequest(key(1), digest), 1),
    )
  assert service.exchange(service, envelope(wire.Hello, 2)) == Ok(wire.Hello)
  assert service.exchange(
      service,
      envelope(wire.Submit(key(1), digest, request, nonce, 5000), 1),
    )
    == Error(service.Invalid)
  assert service.exchange(
      service,
      envelope(wire.Submit(key(1), digest, request, nonce, 5000), 2),
    )
    == Error(service.Expired)
  assert simplifile.is_file(path <> "/proof") == Ok(False)
  assert journal.payloads(book, key(1), digest) == Ok([])
  assert service.exchange(service, envelope(wire.CloseScope, 2))
    == Ok(wire.ScopeRetirement)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn real_tls_owner_dispatcher_reservation_receipt_and_immediate_stdin_test() {
  let path = directory("dispatcher")
  let native = native_service(path)
  let #(server, book) = endpoint(path, native, 1)
  let #(connection, listener, stop, done) = transport(server)
  let prepared = prepared(path, "/bin/cat")
  let assert Ok(digest) = wire.prepared_digest(prepared)
  let events = process.new_subject()
  let reserved = process.new_subject()
  let assert Ok(capacity) = admission.capacity(8)
  let assert Ok(outbox) =
    journal.fresh(path <> "/owner.sqlite", scope(), capacity)
  let adapter =
    dispatcher.dispatcher(dispatcher.Config(
      connection,
      23,
      10_000,
      fn(request) {
        let permit = process.new_subject()
        process.send(reserved, permit)
        let _ = process.receive(permit, 3000)
        let assert Ok(bytes) = wire.encode_prepared(prepared)
        let assert Ok(Nil) =
          journal.put_payload(outbox, key(1), digest, payload.Request(bytes))
        assert request.request == prepared.request
        Ok(dispatcher.Reserved(key(1), prepared))
      },
      fn(origin, key, digest, outputs, terminal) {
        let assert Ok(session) =
          ids.parse_session_id("00000000-0000-7000-8000-000000000001")
        let assert Ok(expected) =
          remote_tool.system_child(session, "component-test", 1)
        assert origin == expected
        use Nil <- result.try(
          list.try_each(
            list.index_map(outputs, fn(bytes, ordinal) {
              payload.Output(ordinal, bytes)
            }),
            fn(item) {
              journal.put_payload(outbox, key, digest, item)
              |> result.map_error(fn(_) { Nil })
            },
          ),
        )
        journal.put_payload(outbox, key, digest, payload.Terminal(terminal))
        |> result.map_error(fn(_) { Nil })
      },
      fn(_, _) { Nil },
      fn(_) { Nil },
      poll.monotonic().now,
    ))
  let #(operation, _) = identity.key_fields(key(1))
  let assert Ok(operation) = ids.parse_op_id(operation)
  let origin = poll.monotonic().now()
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
  let assert Ok(origin_context) =
    remote_tool.system_child(session, "component-test", 1)
  let request =
    dispatch.Dispatch(
      dispatch.CallContext(operation, "exec", Some(origin_context)),
      prepared.request,
      1,
      origin + 10_000,
      clock.from_function(poll.monotonic().now),
      None,
      fn(chunk) { process.send(events, Error(chunk)) },
      fn(terminal) { process.send(events, Ok(terminal)) },
    )
  let assert Ok(execution) = adapter.start(request)
  assert poll.monotonic().now() - origin < 500
  let assert Ok(permit) = process.receive(reserved, 3000)
  execution.stdin(<<"immediate input":utf8>>, dispatch.EndOfInput)
  process.send(permit, Nil)
  let assert Ok(Error(chunk)) = process.receive(events, 8000)
  assert chunk.data == <<"immediate input":utf8>>
  let assert Ok(Ok(dispatch.Completed(result))) = process.receive(events, 8000)
  assert result.code == 0
  let assert Ok(items) = journal.payloads(outbox, key(1), digest)
  assert list.any(items, fn(item) {
    case item {
      payload.Terminal(_) -> True
      _ -> False
    }
  })
  let assert Ok(evidence) = journal.inspect(book, key(1), digest)
  let assert admission.Terminal(
    _,
    admission.NativeUnconfirmed,
    admission.ReceiptDurable,
  ) = admission.phase(evidence)
  execution.release()
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  stop_transport(listener, stop, done)
  assert journal.release(book) == Ok(Nil)
  assert journal.release(outbox) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn restart_at_committed_intent_keeps_original_bytes_and_never_launches_test() {
  let path = directory("restart")
  let native = native_service(path)
  let #(server, book) = endpoint(path, native, 1)
  let request = prepared(path, "printf x >> " <> path <> "/proof")
  let assert Ok(digest) = wire.prepared_digest(request)
  let assert Ok(bytes) = wire.encode_prepared(request)
  assert journal.put_payload(book, key(1), digest, payload.Request(bytes))
    == Ok(Nil)
  let assert Ok(_) = journal.admit(book, key(1), digest)
  let assert Ok(_) =
    journal.apply(book, key(1), digest, admission.AuthorizeLaunch)
  assert service.exchange(
      server,
      envelope(wire.Submit(key(1), digest, request, <<0:size(256)>>, 5000), 1),
    )
    == Ok(wire.Evidence(key(1), digest, 2, 0))
  assert simplifile.is_file(path <> "/proof") == Ok(False)
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  let assert Ok(evidence) = journal.inspect(book, key(1), digest)
  assert admission.phase(evidence)
    == admission.LaunchIntent(admission.NativeUnconfirmed)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn finite_attempt_budget_charges_challenge_and_refuses_subsecond_test() {
  assert service.attempt_budget(5000) == Ok(3900)
  assert service.attempt_budget(1100) == Error(service.Expired)
  assert service.attempt_budget(2099) == Error(service.Expired)
  assert service.attempt_budget(2100) == Ok(1000)
}

type ReplyStage {
  AdmissionReply
  InputReply
  RejectedInputReply
  PausedOutputReply(gate: process.Subject(process.Subject(Nil)))
  TerminalReply
  ReceiptReply
  Finished
}

type ReplyChoice {
  SendReply
  LoseReply
  RejectReply
  PauseReply(gate: process.Subject(process.Subject(Nil)))
}

type FaultAsk {
  Decide(
    command: wire.Body,
    response: wire.Body,
    reply: process.Subject(ReplyChoice),
  )
}

fn fault_serve(
  listener: tls.Listener,
  server: service.Service,
  faults: process.Subject(FaultAsk),
) -> Result(Nil, Nil) {
  use socket <- result.try(
    tls.accept(listener) |> result.map_error(fn(_) { Nil }),
  )
  let outcome = {
    use bytes <- result.try(
      tls.receive(socket) |> result.map_error(fn(_) { Nil }),
    )
    use hello <- result.try(
      wire.decode(bytes, wire.Owner, "owner", "linux", scope())
      |> result.map_error(fn(_) { Nil }),
    )
    use body <- result.try(
      service.exchange(server, hello) |> result.map_error(fn(_) { Nil }),
    )
    use encoded <- result.try(
      wire.encode(wire.Envelope(..hello, role: wire.Executor, body:))
      |> result.map_error(fn(_) { Nil }),
    )
    use Nil <- result.try(
      tls.send(socket, encoded) |> result.map_error(fn(_) { Nil }),
    )
    use bytes <- result.try(
      tls.receive(socket) |> result.map_error(fn(_) { Nil }),
    )
    use command <- result.try(
      wire.decode(bytes, wire.Owner, "owner", "linux", scope())
      |> result.map_error(fn(_) { Nil }),
    )
    use body <- result.try(
      service.exchange(server, command) |> result.map_error(fn(_) { Nil }),
    )
    let reply = process.new_subject()
    process.send(faults, Decide(command.body, body, reply))
    let assert Ok(choice) = process.receive(reply, 1000)
    case choice {
      LoseReply -> Ok(Nil)
      SendReply | RejectReply | PauseReply(_) -> {
        let body = case choice {
          RejectReply -> wire.Rejected(2)
          SendReply | LoseReply | PauseReply(_) -> body
        }
        use Nil <- result.try(case choice {
          PauseReply(gate) -> {
            let permit = process.new_subject()
            process.send(gate, permit)
            process.receive(permit, 3000)
          }
          SendReply | RejectReply | LoseReply -> Ok(Nil)
        })
        use encoded <- result.try(
          wire.encode(wire.Envelope(..command, role: wire.Executor, body:))
          |> result.map_error(fn(_) { Nil }),
        )
        tls.send(socket, encoded) |> result.map_error(fn(_) { Nil })
      }
    }
  }
  tls.close(socket)
  outcome
}

fn fault_transport(
  server: service.Service,
) -> #(connection.Config, tls.Listener, weft.Cancel, process.Subject(Nil)) {
  fault_transport_from(server, AdmissionReply)
}

fn fault_transport_from(
  server: service.Service,
  initial: ReplyStage,
) -> #(connection.Config, tls.Listener, weft.Cancel, process.Subject(Nil)) {
  assert tls.start() == Ok(Nil)
  let fixture = tls_fixture()
  let assert Ok(listener) =
    tls.listen(credentials(fixture.server, fixture.client), tls.Loopback, 0)
  let assert Ok(port) = tls.port(listener)
  let assert Ok(faults) =
    actor.new(initial)
    |> actor.on_message(fn(stage, message) {
      let Decide(command, response, reply) = message
      let choice = case stage, command, response {
        PausedOutputReply(gate), _, wire.Output(_, _, _, _) -> #(
          PauseReply(gate),
          Finished,
        )
        InputReply, wire.Stdin(_, _, _, _, _), _ -> #(LoseReply, Finished)
        RejectedInputReply, wire.Stdin(_, _, _, _, _), _ -> #(
          RejectReply,
          Finished,
        )
        AdmissionReply, wire.Submit(_, _, _, _, _), _ -> #(
          LoseReply,
          TerminalReply,
        )
        TerminalReply, _, wire.Terminal(_, _, _) -> #(LoseReply, ReceiptReply)
        ReceiptReply, wire.DurableReceipt(_, _, _), _ -> #(LoseReply, Finished)
        _, _, _ -> #(SendReply, stage)
      }
      process.send(reply, choice.0)
      actor.continue(choice.1)
    })
    |> actor.start
  let stop = weft.cancel_signal()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let _ =
        weft.new(list.repeat(
          fn() { fault_serve(listener, server, faults.data) },
          256,
        ))
        |> weft.limit(4)
        |> weft.cancel_with(stop)
        |> weft.deadline(15_000)
        |> weft.start
      process.send(done, Nil)
    })
  #(
    connection.Config(
      credentials(fixture.client, fixture.server),
      "localhost",
      port,
      2500,
      "owner",
      "linux",
      1,
      scope(),
    ),
    listener,
    stop,
    done,
  )
}

pub fn real_tls_dropped_admission_terminal_and_receipt_replies_keep_exact_one_mutation_test() {
  let path = directory("drop-replies")
  let native = native_service(path)
  let #(server, book) = endpoint(path, native, 1)
  let #(connection, listener, stop, done) = fault_transport(server)
  let request = prepared(path, "printf x >> " <> path <> "/proof")
  let assert Ok(digest) = wire.prepared_digest(request)
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    connection.exchange(connection, wire.ChallengeRequest(key(1), digest))
  assert connection.exchange(
      connection,
      wire.Submit(key(1), digest, request, nonce, 5000),
    )
    == Error(connection.Uncertain)
  let bytes = terminal(server, 1, digest)
  assert connection.exchange(connection, wire.Query(key(1), digest, 64))
    == Error(connection.Uncertain)
  assert connection.exchange(connection, wire.Query(key(1), digest, 64))
    == Ok(wire.Terminal(key(1), digest, bytes))
  let assert Ok(result_digest) = wire.digest(bytes)
  assert connection.exchange(
      connection,
      wire.DurableReceipt(key(1), digest, result_digest),
    )
    == Error(connection.Uncertain)
  assert connection.exchange(
      connection,
      wire.DurableReceipt(key(1), digest, result_digest),
    )
    == Ok(wire.Terminal(key(1), digest, bytes))
  assert connection.exchange(
      connection,
      wire.Submit(key(1), digest, request, nonce, 8000),
    )
    == Ok(wire.Terminal(key(1), digest, bytes))
  assert simplifile.read(path <> "/proof") == Ok("x")
  let assert Ok(evidence) = journal.inspect(book, key(1), digest)
  let assert admission.Terminal(
    _,
    admission.NativeUnconfirmed,
    admission.ReceiptDurable,
  ) = admission.phase(evidence)
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  stop_transport(listener, stop, done)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

fn time_cell(initial: Int) -> #(fn() -> Int, fn(Int) -> Nil) {
  let assert Ok(cell) =
    actor.new(initial)
    |> actor.on_message(fn(current, message) {
      case message {
        Error(reply) -> {
          process.send(reply, current)
          actor.continue(current)
        }
        Ok(next) -> actor.continue(next)
      }
    })
    |> actor.start
  #(
    fn() {
      let reply = process.new_subject()
      process.send(cell.data, Error(reply))
      let assert Ok(value) = process.receive(reply, 1000)
      value
    },
    fn(value) { process.send(cell.data, Ok(value)) },
  )
}

pub fn independent_clock_origins_expired_challenges_and_preparation_charge_original_budget_test() {
  let path = directory("offset")
  let native = native_service(path)
  let #(server, book) = endpoint(path, native, 1)
  let #(now, advance) = time_cell(900_000_000)
  let assert Ok(server) =
    service.start(service.Config(..service.configuration(server), now:))
  let request = prepared(path, "true")
  let assert Ok(digest) = wire.prepared_digest(request)
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    service.exchange(server, envelope(wire.ChallengeRequest(key(1), digest), 1))
  // Owner clock origin is unrelated; only its 6000 ms remaining is transmitted.
  assert service.attempt_budget({ -400_000_000 + 6000 } - { -400_000_000 })
    == Ok(4900)
  advance(900_001_000)
  assert service.exchange(
      server,
      envelope(wire.Submit(key(1), digest, request, nonce, 4900), 1),
    )
    == Error(service.Expired)
  assert journal.payloads(book, key(1), digest) == Ok([])
  let assert Ok(wire.Challenge(_, _, fresh, _)) =
    service.exchange(server, envelope(wire.ChallengeRequest(key(2), digest), 1))
  advance(900_001_999)
  let assert Ok(wire.Evidence(_, _, 2, deadline)) =
    service.exchange(
      server,
      envelope(wire.Submit(key(2), digest, request, fresh, 4900), 1),
    )
  assert deadline == 900_006_899
  let bytes = terminal(server, 2, digest)
  assert service.exchange(
      server,
      envelope(wire.Submit(key(2), digest, request, fresh, 8000), 1),
    )
    == Ok(wire.Terminal(key(2), digest, bytes))
  let assert Ok(items) = journal.payloads(book, key(2), digest)
  let assert Ok(payload.Authority(authority)) =
    list.find(items, fn(item) {
      case item {
        payload.Authority(_) -> True
        _ -> False
      }
    })
  let assert Ok(mp.ArrayValue([_, mp.IntValue(frozen), _])) =
    wire.decode_value(authority)
  assert frozen == deadline
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn blocked_stdin_is_bounded_and_local_cancel_does_not_wait_for_network_writer_test() {
  let path = directory("stdin-cancel")
  let native = native_service(path)
  let #(server, book) = endpoint(path, native, 1)
  let request = prepared(path, "/bin/sleep 8")
  let #(digest, _) = submit(server, request, 1)
  let bytes = <<0:size(65_536)>>
  assert list.all(
    list.index_map(list.repeat(Nil, 128), fn(_, index) { index }),
    fn(ordinal) {
      service.exchange(
        server,
        envelope(
          wire.Stdin(key(1), digest, ordinal, bytes, dispatch.MoreInput),
          1,
        ),
      )
      |> result.is_ok
    },
  )
  assert service.exchange(
      server,
      envelope(wire.Stdin(key(1), digest, 128, bytes, dispatch.MoreInput), 1),
    )
    == Error(service.Capacity)
  assert service.exchange(
      server,
      envelope(wire.Stdin(key(1), digest, 127, bytes, dispatch.MoreInput), 1),
    )
    |> result.is_ok
  let started = poll.monotonic().now()
  assert service.exchange(server, envelope(wire.Cancel(key(1), digest), 1))
    |> result.is_ok
  assert poll.monotonic().now() - started < 1000
  let _ = terminal(server, 1, digest)
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn protocol_stream_exhaustion_fails_while_ordinary_log_truncation_stays_explicit_test() {
  let path = directory("stream")
  let native = native_service(path)
  let #(server, book) = endpoint(path, native, 1)
  let logs = prepared(path, "/bin/dd if=/dev/zero bs=65536 count=4 2>/dev/null")
  let #(digest, _) = submit(server, logs, 1)
  let bytes = terminal(server, 1, digest)
  let assert Ok(dispatch.Completed(result)) = native.decode_terminal(bytes)
  assert result.stdout_truncated
  let protocol = wire.Prepared(..logs, stream: wire.ProtocolStream)
  let #(digest, _) = submit(server, protocol, 2)
  let bytes = terminal(server, 2, digest)
  let assert Ok(dispatch.Failed(exec.ProtocolViolation(_))) =
    native.decode_terminal(bytes)
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn remote_unknown_terminal_codec_preserves_named_loss_and_existing_failure_variants_test() {
  let failures = [
    exec.ExecutionLost(exec.HelperActorDown),
    exec.ExecutionLost(exec.RelayDown),
    exec.ExecutionLost(exec.ExecutorClosing),
    exec.ExecutionLost(exec.RemoteOutcomeUncertain),
    exec.NotReady,
    exec.HandshakeTimeout,
    exec.HelperBusy,
    exec.SendFailed,
    exec.CancelEscalated,
    exec.HeartbeatMissed,
    exec.HelperUnresponsive,
    exec.ChannelClosed(7),
    exec.ProtocolVersionMismatch(2, 3),
    exec.RefusedByHelper("spawn_failed", "exact reason"),
    exec.ProtocolViolation("unknown"),
  ]
  assert list.all(failures, fn(failure) {
    let terminal = dispatch.Failed(failure)
    let assert Ok(bytes) = native.encode_terminal(terminal)
    native.decode_terminal(bytes) == Ok(terminal)
  })
}

pub fn preparation_expiry_refuses_before_launch_with_exact_payload_and_receipt_obligation_test() {
  let path = directory("prep-expiry")
  let native = native_service(path)
  let #(server, book) = endpoint(path, native, 1)
  let #(now, advance) = time_cell(100_000)
  let assert Ok(counter) =
    actor.new(0)
    |> actor.on_message(fn(count, reply) {
      process.send(reply, count + 1)
      actor.continue(count + 1)
    })
    |> actor.start
  let config = service.configuration(server)
  let assert Ok(server) =
    service.start(
      service.Config(..config, now:, verify: fn(_, _) {
        let reply = process.new_subject()
        process.send(counter.data, reply)
        let assert Ok(count) = process.receive(reply, 1000)
        case count {
          2 -> advance(106_000)
          _ -> Nil
        }
        Ok(Nil)
      }),
    )
  let request = prepared(path, "printf x >> " <> path <> "/proof")
  let assert Ok(digest) = wire.prepared_digest(request)
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    service.exchange(server, envelope(wire.ChallengeRequest(key(1), digest), 1))
  let assert Ok(wire.Terminal(_, _, bytes)) =
    service.exchange(
      server,
      envelope(wire.Submit(key(1), digest, request, nonce, 4900), 1),
    )
  let assert Ok(dispatch.Failed(exec.ProtocolViolation(_))) =
    native.decode_terminal(bytes)
  assert simplifile.is_file(path <> "/proof") == Ok(False)
  let assert Ok(evidence) = journal.inspect(book, key(1), digest)
  let assert admission.Refused(_, admission.ReceiptPending) =
    admission.phase(evidence)
  let assert Ok(decision) =
    journal.apply(book, key(1), digest, admission.AuthorizeLaunch)
  assert decision.effect == admission.NoLaunch
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

fn owner_request(
  prepared: wire.Prepared,
  settle: fn(dispatch.Terminal) -> Nil,
) -> dispatch.Dispatch {
  let #(operation, _) = identity.key_fields(key(1))
  let assert Ok(operation) = ids.parse_op_id(operation)
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
  let assert Ok(origin) = remote_tool.system_child(session, "review-test", 1)
  dispatch.Dispatch(
    dispatch.CallContext(operation, "exec", Some(origin)),
    prepared.request,
    1,
    poll.monotonic().now() + 10_000,
    clock.from_function(poll.monotonic().now),
    None,
    fn(_) { Nil },
    settle,
  )
}

pub fn cancel_before_submit_and_bare_admission_recovery_never_launch_test() {
  let path = directory("cancel-fence")
  let pool = native_service(path)
  let #(server, book) = endpoint(path, pool, 1)
  let request = prepared(path, "printf x >> " <> path <> "/proof")
  let assert Ok(digest) = wire.prepared_digest(request)
  let assert Ok(wire.Terminal(_, _, bytes)) =
    service.exchange(server, envelope(wire.Cancel(key(1), digest), 1))
  assert service.exchange(
      server,
      envelope(wire.Submit(key(1), digest, request, <<0:size(256)>>, 5000), 1),
    )
    == Ok(wire.Terminal(key(1), digest, bytes))
  let assert Ok(items) = journal.payloads(book, key(1), digest)
  assert list.any(items, fn(item) {
    case item {
      payload.Cancellation(_) -> True
      _ -> False
    }
  })
  let assert Ok(evidence) = journal.inspect(book, key(1), digest)
  let assert admission.Refused(_, admission.ReceiptPending) =
    admission.phase(evidence)
  let assert Ok(_) = journal.admit(book, key(2), digest)
  assert service.exchange(
      server,
      envelope(wire.Submit(key(2), digest, request, <<0:size(256)>>, 5000), 1),
    )
    == Ok(wire.Evidence(key(2), digest, 1, 0))
  let assert Ok(_) = journal.admit(book, key(3), digest)
  let assert Ok(Nil) =
    journal.put_payload(book, key(3), digest, payload.Cancellation(bytes))
  assert service.exchange(
      server,
      envelope(wire.Submit(key(3), digest, request, <<0:size(256)>>, 5000), 1),
    )
    == Ok(wire.Evidence(key(3), digest, 1, 0))
  assert simplifile.is_file(path <> "/proof") == Ok(False)
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn owner_cancel_during_parked_durable_reservation_fences_submission_test() {
  let path = directory("parked-cancel")
  let pool = native_service(path)
  let #(server, book) = endpoint(path, pool, 1)
  let #(transport, listener, stop, done) = transport(server)
  let prepared = prepared(path, "printf x >> " <> path <> "/proof")
  let assert Ok(digest) = wire.prepared_digest(prepared)
  let parked = process.new_subject()
  let cancelled = process.new_subject()
  let terminal_events = process.new_subject()
  let reserve_done = process.new_subject()
  let adapter =
    dispatcher.dispatcher(dispatcher.Config(
      transport,
      23,
      10_000,
      fn(_) {
        let permit = process.new_subject()
        process.send(parked, permit)
        let assert Ok(Nil) = process.receive(permit, 3000)
        process.send(reserve_done, Nil)
        Ok(dispatcher.Reserved(key(1), prepared))
      },
      fn(_, _, _, _, _) {
        panic as "Cancelled request cannot receive a durable success."
      },
      fn(_, _) { Nil },
      fn(_) { process.send(cancelled, Nil) },
      poll.monotonic().now,
    ))
  let assert Ok(execution) =
    adapter.start(
      owner_request(prepared, fn(value) { process.send(terminal_events, value) }),
    )
  let assert Ok(permit) = process.receive(parked, 3000)
  execution.cancel()
  assert process.receive(cancelled, 1000) == Ok(Nil)
  assert process.receive(terminal_events, 1000)
    == Ok(dispatch.Failed(exec.ExecutionLost(exec.RemoteOutcomeUncertain)))
  process.send(permit, Nil)
  assert process.receive(reserve_done, 1000) == Ok(Nil)
  assert journal.inspect(book, key(1), digest)
    == Error(journal.Rejected(admission.UnknownRequest))
  assert simplifile.is_file(path <> "/proof") == Ok(False)
  execution.release()
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  stop_transport(listener, stop, done)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn lost_or_rejected_stdin_ack_is_uncertain_never_success_or_receipt_test() {
  list.each([InputReply, RejectedInputReply], fn(stage) {
    let path = directory("input-ack")
    let pool = native_service(path)
    let #(server, book) = endpoint(path, pool, 1)
    let #(transport, listener, stop, done) = fault_transport_from(server, stage)
    let prepared = prepared(path, "/bin/cat")
    let assert Ok(digest) = wire.prepared_digest(prepared)
    let parked = process.new_subject()
    let terminal_events = process.new_subject()
    let uncertain = process.new_subject()
    let adapter =
      dispatcher.dispatcher(dispatcher.Config(
        transport,
        23,
        10_000,
        fn(_) {
          let permit = process.new_subject()
          process.send(parked, permit)
          let assert Ok(Nil) = process.receive(permit, 3000)
          Ok(dispatcher.Reserved(key(1), prepared))
        },
        fn(_, _, _, _, _) {
          panic as "Lost stdin acknowledgement cannot become durable success."
        },
        fn(_, _) { process.send(uncertain, Nil) },
        fn(_) { Nil },
        poll.monotonic().now,
      ))
    let assert Ok(execution) =
      adapter.start(
        owner_request(prepared, fn(value) {
          process.send(terminal_events, value)
        }),
      )
    let assert Ok(permit) = process.receive(parked, 3000)
    execution.stdin(<<"exact input":utf8>>, dispatch.EndOfInput)
    process.send(permit, Nil)
    assert process.receive(uncertain, 5000) == Ok(Nil)
    assert process.receive(terminal_events, 5000)
      == Ok(dispatch.Failed(exec.ExecutionLost(exec.RemoteOutcomeUncertain)))
    let _ = terminal(server, 1, digest)
    let assert Ok(evidence) = journal.inspect(book, key(1), digest)
    let assert admission.Terminal(
      _,
      admission.NativeUnconfirmed,
      admission.ReceiptPending,
    ) = admission.phase(evidence)
    execution.release()
    assert service.exchange(server, envelope(wire.CloseScope, 1))
      == Ok(wire.ScopeRetirement)
    stop_transport(listener, stop, done)
    assert journal.release(book) == Ok(Nil)
    let assert Ok(Nil) = simplifile.delete(path)
  })
}

pub fn thirty_three_sequential_native_commands_reclaim_active_controls_keep_retirement_inventory_test() {
  let path = directory("control-reuse")
  let pool = native_service(path)
  let assert Ok(capacity) = admission.capacity(64)
  let assert Ok(book) =
    journal.fresh(path <> "/custody.sqlite", scope(), capacity)
  let assert Ok(server) =
    service.start(service.Config(
      "owner",
      "linux",
      scope(),
      1,
      book,
      pool,
      fn(_, prepared) {
        case prepared.request.cwd == path {
          True -> Ok(Nil)
          False -> Error(Nil)
        }
      },
      poll.monotonic().now,
    ))
  let baseline = live_processes()
  let request = prepared(path, "printf x >> " <> path <> "/proof")
  let assert Ok(digest) = wire.prepared_digest(request)
  list.each(
    list.index_map(list.repeat(Nil, 33), fn(_, index) { index + 1 }),
    fn(number) {
      let _ = submit(server, request, number)
      let bytes = terminal(server, number, digest)
      let assert Ok(result_digest) = wire.digest(bytes)
      assert service.exchange(
          server,
          envelope(wire.DurableReceipt(key(number), digest, result_digest), 1),
        )
        == Ok(wire.Terminal(key(number), digest, bytes))
      let assert Ok(evidence) = journal.inspect(book, key(number), digest)
      let assert admission.Terminal(
        _,
        admission.NativeUnconfirmed,
        admission.ReceiptDurable,
      ) = admission.phase(evidence)
    },
  )
  assert simplifile.read(path <> "/proof") == Ok(string.repeat("x", 33))
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  list.each(
    list.index_map(list.repeat(Nil, 33), fn(_, index) { index + 1 }),
    fn(number) {
      let assert Ok(evidence) = journal.inspect(book, key(number), digest)
      let assert admission.Terminal(
        _,
        admission.NativeRetired,
        admission.ReceiptDurable,
      ) = admission.phase(evidence)
      let assert Ok(_) =
        journal.apply(book, key(number), digest, admission.Compact)
      assert journal.payloads(book, key(number), digest) |> result.is_ok
    },
  )
  assert journal.release(book) == Ok(Nil)

  // Every per-request actor must retire with its native owner. The persistent
  // admission service existed in the baseline and deliberately stays alive.
  let retired =
    poll.until(within: 2000, every: 10, attempt: fn() {
      let newcomers =
        list.filter(live_processes(), fn(pid) { !list.contains(baseline, pid) })
      case newcomers {
        [] -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
  assert retired == poll.Answered(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn thirty_two_active_control_limit_refuses_before_durable_payload_admission_test() {
  let path = directory("active-cap")
  let gate = process.new_subject()
  let pool = native_service_gated(path, Some(gate))
  let assert Ok(capacity) = admission.capacity(64)
  let assert Ok(book) =
    journal.fresh(path <> "/custody.sqlite", scope(), capacity)
  let assert Ok(server) =
    service.start(service.Config(
      "owner",
      "linux",
      scope(),
      1,
      book,
      pool,
      fn(_, prepared) {
        case prepared.request.cwd == path {
          True -> Ok(Nil)
          False -> Error(Nil)
        }
      },
      poll.monotonic().now,
    ))
  let request = prepared(path, "printf x >> " <> path <> "/proof")
  let assert Ok(digest) = wire.prepared_digest(request)
  list.each(
    list.index_map(list.repeat(Nil, 32), fn(_, index) { index + 1 }),
    fn(number) {
      let _ = submit(server, request, number)
    },
  )
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    service.exchange(
      server,
      envelope(wire.ChallengeRequest(key(33), digest), 1),
    )
  assert service.exchange(
      server,
      envelope(wire.Submit(key(33), digest, request, nonce, 5000), 1),
    )
    == Error(service.Capacity)
  assert journal.payloads(book, key(33), digest) == Ok([])
  assert journal.inspect(book, key(33), digest)
    == Error(journal.Rejected(admission.UnknownRequest))
  list.each(list.repeat(Nil, 32), fn(_) {
    let assert Ok(permit) = process.receive(gate, 3000)
    process.send(permit, Nil)
  })
  list.each(
    list.index_map(list.repeat(Nil, 32), fn(_, index) { index + 1 }),
    fn(number) {
      let _ = terminal(server, number, digest)
    },
  )
  assert simplifile.is_file(path <> "/proof") == Ok(False)
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  assert journal.put_payload(book, key(33), digest, payload.Request(<<1>>))
    == Error(journal.Rejected(admission.EpochClosed))
  assert journal.payloads(book, key(33), digest) == Ok([])
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn supervised_listener_idle_peer_capacity_is_finite_and_recovers_without_custody_restart_test() {
  let path = directory("listener-credit")
  let pool = native_service(path)
  let #(server, book) = endpoint(path, pool, 1)
  assert tls.start() == Ok(Nil)
  let fixture = tls_fixture()
  let assert Ok(listener) =
    tls.listen(credentials(fixture.server, fixture.client), tls.Loopback, 0)
  let assert Ok(port) = tls.port(listener)
  assert remote_listener.configure(
      listener,
      server,
      workers: 0,
      within_ms: 1000,
    )
    == Error(remote_listener.InvalidCapacity)
  assert remote_listener.configure(
      listener,
      server,
      workers: 5,
      within_ms: 1000,
    )
    == Error(remote_listener.InvalidCapacity)
  assert remote_listener.configure(listener, server, workers: 2, within_ms: 0)
    == Error(remote_listener.InvalidDeadline)
  let assert Ok(config) =
    remote_listener.configure(listener, server, workers: 2, within_ms: 1000)
  let started = process.new_subject()
  let finished = process.new_subject()
  let _ =
    weft.new([
      fn() {
        let assert Ok(tree) =
          supervisor.new(supervisor.OneForOne)
          |> supervisor.add(remote_listener.supervised(config))
          |> supervisor.start
        let finish = process.new_subject()
        process.send(started, #(tree.pid, finish))
        let assert Ok(Nil) = process.receive(finish, 5000)
        Ok(Nil)
      },
    ])
    |> weft.deadline(6000)
    |> weft.start_relayed(to: finished)
  let assert Ok(#(tree_pid, finish)) = process.receive(started, 1000)
  let monitor = process.monitor(tree_pid)
  let owner =
    connection.Config(
      credentials(fixture.client, fixture.server),
      "localhost",
      port,
      1500,
      "owner",
      "linux",
      1,
      scope(),
    )
  let request = prepared(path, "printf x >> " <> path <> "/proof")
  let #(digest, _) = submit(server, request, 1)
  let bytes = terminal(server, 1, digest)
  assert connection.exchange(owner, wire.Query(key(1), digest, 64))
    == Ok(wire.Terminal(key(1), digest, bytes))
  let assert Ok(first) = tls.connect(owner.tls, "localhost", port)
  let assert Ok(second) = tls.connect(owner.tls, "localhost", port)
  let origin = poll.monotonic().now()
  assert connection.exchange(
      connection.Config(..owner, within_ms: 150),
      wire.Query(key(1), digest, 64),
    )
    == Error(connection.Uncertain)
  assert poll.monotonic().now() - origin < 500
  tls.close(first)
  assert connection.exchange(owner, wire.Query(key(1), digest, 64))
    == Ok(wire.Terminal(key(1), digest, bytes))
  tls.close(second)
  assert simplifile.read(path <> "/proof") == Ok("x")
  let assert Ok(evidence) = journal.inspect(book, key(1), digest)
  let assert admission.Terminal(
    _,
    admission.NativeUnconfirmed,
    admission.ReceiptPending,
  ) = admission.phase(evidence)
  tls.close_listener(listener)
  process.send(finish, Nil)
  let assert Ok(weft.PulledOutcome(weft.Completed(_, Nil))) =
    process.receive(finished, 1000)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(value) { value })
    |> process.selector_receive(2000)
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn local_stdin_ack_timeout_fences_same_ordinal_before_possible_late_forwarding_test() {
  let path = directory("local-input-ack")
  let gate = process.new_subject()
  let pool = native_service_controlled(path, Some(#(gate, LendHelper)))
  let #(server, book) = endpoint(path, pool, 1)
  let request = prepared(path, "/bin/cat")
  let #(digest, _) = submit(server, request, 1)
  let assert Ok(permit) = process.receive(gate, 1000)
  let input =
    envelope(
      wire.Stdin(key(1), digest, 0, <<"once":utf8>>, dispatch.EndOfInput),
      1,
    )
  assert service.exchange(server, input) == Ok(wire.Rejected(4))
  assert service.exchange(server, input) == Error(service.Uncertain)
  process.send(permit, Nil)
  let _ = terminal(server, 1, digest)
  let assert Ok(wire.Output(_, _, 0, bytes)) =
    service.exchange(server, envelope(wire.Query(key(1), digest, 0), 1))
  let assert Ok(chunk) = native.decode_output(bytes)
  assert chunk.data == <<"once":utf8>>
  let assert Ok(evidence) = journal.inspect(book, key(1), digest)
  let assert admission.Terminal(
    _,
    admission.NativeUnconfirmed,
    admission.ReceiptPending,
  ) = admission.phase(evidence)
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn paused_tls_output_writer_cannot_block_local_native_cancellation_or_custody_test() {
  let path = directory("paused-writer")
  let pool = native_service(path)
  let #(server, book) = endpoint(path, pool, 1)
  let gate = process.new_subject()
  let #(transport, listener, stop, done) =
    fault_transport_from(server, PausedOutputReply(gate))
  let request = prepared(path, "printf x; /bin/sleep 8")
  let #(digest, _) = submit(server, request, 1)
  let assert poll.Answered(_) =
    poll.until(within: 1000, every: 10, attempt: fn() {
      case
        service.exchange(server, envelope(wire.Query(key(1), digest, 0), 1))
      {
        Ok(wire.Output(_, _, _, bytes)) -> poll.Done(bytes)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
  let outcome = process.new_subject()
  let _ =
    weft.new([
      fn() { connection.exchange(transport, wire.Query(key(1), digest, 0)) },
    ])
    |> weft.deadline(3000)
    |> weft.start_relayed(to: outcome)
  let assert Ok(permit) = process.receive(gate, 1000)
  let origin = poll.monotonic().now()
  assert service.exchange(server, envelope(wire.Cancel(key(1), digest), 1))
    |> result.is_ok
  let bytes = terminal(server, 1, digest)
  assert poll.monotonic().now() - origin < 1000
  let assert Ok(evidence) = journal.inspect(book, key(1), digest)
  let assert admission.Terminal(
    _,
    admission.NativeUnconfirmed,
    admission.ReceiptPending,
  ) = admission.phase(evidence)
  assert journal.payloads(book, key(1), digest) |> result.is_ok
  process.send(permit, Nil)
  let assert Ok(_) = process.receive(outcome, 3000)
  assert service.exchange(server, envelope(wire.Query(key(1), digest, 64), 1))
    == Ok(wire.Terminal(key(1), digest, bytes))
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  stop_transport(listener, stop, done)
  assert journal.release(book) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn journal_failure_retains_uncertain_intent_but_cannot_prevent_local_cancel_and_drain_test() {
  let path = directory("journal-failure")
  let pool = native_service(path)
  let #(server, book) = endpoint(path, pool, 1)
  let request = prepared(path, "/bin/sleep 8")
  let #(digest, _) = submit(server, request, 1)
  let monitor = process.monitor(local.pid(pool))
  assert journal.release(book) == Ok(Nil)
  assert service.exchange(server, envelope(wire.Cancel(key(1), digest), 1))
    == Error(service.Uncertain)
  assert service.exchange(server, envelope(wire.CloseScope, 1))
    == Error(service.Uncertain)
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(value) { value })
    |> process.selector_receive(1000)
  assert !process.is_alive(local.pid(pool))
  let assert Ok(capacity) = admission.capacity(8)
  let assert Ok(recovered) =
    journal.recover(path <> "/custody.sqlite", scope(), capacity)
  let assert Ok(evidence) = journal.inspect(recovered, key(1), digest)
  assert admission.phase(evidence)
    == admission.LaunchIntent(admission.NativeUnconfirmed)
  let assert Ok(bytes) = wire.encode_prepared(request)
  let assert Ok(items) = journal.payloads(recovered, key(1), digest)
  assert list.contains(items, payload.Request(bytes))
  assert journal.apply(recovered, key(1), digest, admission.Compact)
    |> result.is_error
  assert journal.release(recovered) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path)
}

/// Native publication children belong to native control even before Begin.
pub fn publication_children_retire_on_native_crash_and_failed_initialization_test() {
  let path = directory("publisher-parent")
  let gate = process.new_subject()
  let pool = native_service_gated(path, Some(gate))
  let observed = process.new_subject()
  let publication = fn() {
    let assert Ok(child) =
      actor.new(Nil)
      |> actor.on_message(fn(_, _: Nil) { actor.continue(Nil) })
      |> actor.trapping_exits(True)
      |> actor.start
      as "publication resource links to its initializer"
    process.send(observed, #(process.self(), child.pid))
    native.Publisher(fn(_) { Ok(Nil) }, fn(_) { Nil })
  }
  let config =
    native.Config(
      pool,
      {
        let assert Ok(operation) =
          ids.parse_op_id("00000000-0000-7000-8000-000000000002")
          as "valid operation"
        operation
      },
      prepared(path, "true"),
      1,
      poll.monotonic().now() + 5000,
      poll.monotonic().now,
      fn() { Ok(publication()) },
      fn() { Nil },
    )
  let assert Ok(_) = native.start(config) as "native owner starts"
  let assert Ok(#(owner, child)) = process.receive(observed, 1000)
    as "factory ran in native owner"
  assert owner != process.self()
  let assert Ok(release) = process.receive(gate, 1000)
    as "native checkout is parked"
  process.kill(owner)
  process.send(release, Nil)
  let retired =
    poll.until(within: 1000, every: 10, attempt: fn() {
      case process.is_alive(child) {
        True -> poll.Retry
        False -> poll.Done(Nil)
      }
    })
  assert retired == poll.Answered(Nil)

  // Failed initialization has no live Running handle with which to clean up.
  // The child's link to the initializer must therefore be sufficient.
  let failure =
    native.Config(..config, publisher: fn() {
      let _ = publication()
      Error(Nil)
    })
  assert native.start(failure) == Error(Nil)
  let assert Ok(#(failed_owner, failed_child)) = process.receive(observed, 1000)
    as "failed initializer created its linked child"
  assert failed_owner != process.self()
  let retired =
    poll.until(within: 1000, every: 10, attempt: fn() {
      case process.is_alive(failed_child) {
        True -> poll.Retry
        False -> poll.Done(Nil)
      }
    })
  assert retired == poll.Answered(Nil)
  assert local.close(pool, draining: 100, helpers: 2000) == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete(path) as "publication fixture removed"
}

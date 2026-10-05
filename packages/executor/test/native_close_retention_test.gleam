//// Same-live-service closure retains its one original native disposition.
//// These controls use the real broker executor and helper pool. Stock sys state
//// readback checks retained state after outward errors; it never grants proof.
//// Normal native DOWN is checked only after actual successful CloseScope.

import broker/exec
import broker/executor as local
import broker/policy
import core/ids
import executor
import executor/remote/admission
import executor/remote/identity
import executor/remote/journal
import executor/remote/service
import executor/remote/wire
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/option.{Some}
import gleam/otp/system
import gleam/time/timestamp
import simplifile
import sqlight
import telemetry/log
import weft/poll

type CloseOutcome {
  /// Real helper retirement is required before native success.
  RetireHelpers

  /// The real native actor receives an uncertain original helper verdict.
  UncertainHelpers

  /// Real native success precedes a poisoned original retirement journal.
  BreakConfirmation
}

type Fixture {
  Fixture(
    path: String,
    service: service.Service,
    journal: journal.Journal,
    native: local.Executor,
    closes: process.Subject(Nil),
  )
}

fn scope() -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
  let assert Ok(workspace) = identity.workspace_id("close-retention")
  let assert Ok(executor) = identity.executor_id("linux")
  let assert Ok(epoch) = identity.epoch(1)
  identity.scope(session, workspace, executor, epoch, epoch)
}

fn envelope(body: wire.Body, generation: Int) -> wire.Envelope {
  wire.Envelope(wire.Owner, "owner", "linux", generation, scope(), body)
}

fn fixture(outcome: CloseOutcome) -> Fixture {
  let assert Ok(here) = simplifile.current_directory()
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    here
    <> "/build/close-retention-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(path <> "/tmp") == Ok(Nil)

  // This original pool is the only physical native owner for the scope.
  let spawn =
    exec.SpawnConfig(
      here <> "/../sandbox/loom-exec",
      "/bin/sh",
      executor.base_policy(path),
      [],
      path <> "/tmp",
      3000,
      3000,
      0,
    )
  let assert Ok(pool) = exec.start_pool(1, fn() { exec.prepare_helper(spawn) })
    as "Original real native helper pool."
  let closes = process.new_subject()
  let assert Ok(native) =
    local.start(local.ExecutorConfig(
      fn() { exec.checkout(pool, waiting: 3000) },
      fn(helper) { exec.checkin(pool, helper) },
      fn() { exec.pool_custody(pool, waiting: 1000) },
      fn(ms) {
        process.send(closes, Nil)
        let retired = exec.close_pool(pool, waiting: ms)
        case outcome {
          RetireHelpers -> retired
          UncertainHelpers -> Error(exec.RetirementPending)
          BreakConfirmation -> {
            let assert Ok(db) = sqlight.open(path <> "/custody.sqlite")
            assert sqlight.exec("DROP TABLE custody_event", db) == Ok(Nil)
            assert sqlight.close(db) == Ok(Nil)
            retired
          }
        }
      },
      41,
      log.discard(),
    ))
    as "Actual native close state machine."

  // The independently durable journal cannot substitute for pool retirement.
  let assert Ok(capacity) = admission.capacity(4)
  let assert Ok(book) =
    journal.fresh(path <> "/custody.sqlite", scope(), capacity)
  let assert Ok(remote) =
    service.start(service.Config(
      "owner",
      "linux",
      scope(),
      1,
      book,
      native,
      fn(_, _) { Ok(Nil) },
      poll.monotonic().now,
    ))
  Fixture(path, remote, book, native, closes)
}

fn disposition(remote: service.Service) -> String {
  // This stock OTP observation checks the private retained ADT only. Neither
  // actor death nor this diagnostic can substitute for actual retirement.
  let assert Ok(value) =
    decode.run(
      system.get_state(service.pid(remote)),
      decode.at([9], atom.decoder()),
    )
    as "The original live service retains its close disposition."
  atom.to_string(value)
}

fn joined(monitor: process.Monitor) -> Nil {
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(message) { message })
    |> process.selector_receive(3000)
    as "Actual original actor joined after successful native retirement."
  Nil
}

fn cleanup(f: Fixture) -> Nil {
  assert journal.release(f.journal) == Ok(Nil)
  assert simplifile.delete(f.path) == Ok(Nil)
}

/// Duplicate wire close and Shutdown reuse original native proof without reclose.
///
/// ## Examples
/// `wire_close_then_duplicate_and_shutdown_retains_original_proof_test()`.
pub fn wire_close_then_duplicate_and_shutdown_retains_original_proof_test() {
  let f = fixture(RetireHelpers)
  let #(key, digest) = completed(f)

  // Monitor the original actor before its real close, without deriving proof from DOWN.
  let native_down = process.monitor(local.pid(f.native))
  assert service.exchange(f.service, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)
  joined(native_down)
  assert process.receive(f.closes, 1000) == Ok(Nil)
  assert disposition(f.service) == "native_retired"
  let assert Ok(evidence) = journal.inspect(f.journal, key, digest)
  let assert admission.Terminal(_, admission.NativeRetired, _) =
    admission.phase(evidence)

  // Later local shutdown consumes the same original successful close witness.
  assert service.exchange(f.service, envelope(wire.CloseScope, 1))
    == Ok(wire.ScopeRetirement)

  // Join the service only after its own successful shutdown response.
  let down = process.monitor(service.pid(f.service))
  assert service.shutdown(f.service) == Ok(Nil)
  joined(down)
  assert process.receive(f.closes, 0) == Error(Nil)
  cleanup(f)
}

fn completed(f: Fixture) -> #(identity.RequestKey, identity.Digest) {
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000003")
  let key = identity.request_key(scope(), op, request)
  let assert Ok(registration) = identity.digest(<<1:size(256)>>)
  let sandbox =
    policy.SandboxPolicy(
      ..executor.base_policy(f.path),
      limits: policy.Limits(10, 2, 268_435_456, 128, 1_048_576, 131_072),
    )
  let prepared =
    wire.Prepared(
      "exec",
      registration,
      wire.Finite(10_000),
      exec.ExecRequest(
        ["/bin/true"],
        [],
        f.path,
        Some(sandbox),
        <<7:size(256)>>,
        exec.PlatformEnforcement,
      ),
      wire.Logs,
    )

  // Exact challenge and Submit drive the existing real native admission path.
  let assert Ok(digest) = wire.prepared_digest(prepared)
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    service.exchange(f.service, envelope(wire.ChallengeRequest(key, digest), 1))
  let assert Ok(_) =
    service.exchange(
      f.service,
      envelope(wire.Submit(key, digest, prepared, nonce, 5000), 1),
    )

  // Actual native completion precedes retirement; exit alone lacks that proof.
  let assert poll.Answered(Nil) =
    poll.until(5000, 10, fn() {
      case
        service.exchange(f.service, envelope(wire.Query(key, digest, 64), 1))
      {
        Ok(wire.Terminal(_, _, _)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "The real helper's original native terminal was retained."
  #(key, digest)
}

/// A post-native retirement write failure preserves the original native proof.
///
/// ## Examples
/// `covered_confirmation_failure_retains_native_success_test()`.
pub fn covered_confirmation_failure_retains_native_success_test() {
  let f = fixture(BreakConfirmation)
  let _ = completed(f)

  // Monitor the original actor before its real close, without deriving proof from DOWN.
  let native_down = process.monitor(local.pid(f.native))
  assert service.exchange(f.service, envelope(wire.CloseScope, 1))
    == Error(service.Uncertain)
  joined(native_down)
  assert disposition(f.service) == "native_retired"
  assert process.receive(f.closes, 1000) == Ok(Nil)

  // Retry cannot erase native success or infer durable confirmation from it.
  assert service.shutdown(f.service) == Error(service.Uncertain)
  assert disposition(f.service) == "native_retired"
  assert process.receive(f.closes, 0) == Error(Nil)

  // Test disposal joins uncertainty without advertising native retirement.
  discard(service.pid(f.service))
  assert simplifile.delete(f.path) == Ok(Nil)
}

/// Genuine journal loss cannot erase actual native success or claim retirement.
///
/// ## Examples
/// `durable_failure_retains_native_success_and_quiescence_test()`.
pub fn durable_failure_retains_native_success_and_quiescence_test() {
  let f = fixture(RetireHelpers)
  assert journal.release(f.journal) == Ok(Nil)

  // Monitor the original actor before its real close, without deriving proof from DOWN.
  let native_down = process.monitor(local.pid(f.native))
  assert service.exchange(f.service, envelope(wire.CloseScope, 1))
    == Error(service.Uncertain)
  joined(native_down)
  assert disposition(f.service) == "native_retired"
  assert process.receive(f.closes, 1000) == Ok(Nil)

  // Failed durable confirmation never restores admission or upgrades uncertainty.
  assert service.shutdown(f.service) == Error(service.Uncertain)
  assert disposition(f.service) == "native_retired"
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000003")
  let assert Ok(digest) = identity.digest(<<1:size(256)>>)
  assert service.exchange(
      f.service,
      envelope(
        wire.ChallengeRequest(
          identity.request_key(scope(), op, request),
          digest,
        ),
        1,
      ),
    )
    == Error(service.Invalid)
  assert process.receive(f.closes, 0) == Error(Nil)

  // Test disposal joins uncertainty without advertising native retirement.
  discard(service.pid(f.service))
  assert simplifile.delete(f.path) == Ok(Nil)
}

/// Original native uncertainty remains sticky despite helper exit and retries.
///
/// ## Examples
/// `native_uncertainty_never_becomes_retirement_test()`.
pub fn native_uncertainty_never_becomes_retirement_test() {
  let f = fixture(UncertainHelpers)
  assert service.exchange(f.service, envelope(wire.CloseScope, 1))
    == Error(service.Uncertain)
  assert disposition(f.service) == "native_uncertain"
  assert process.receive(f.closes, 1000) == Ok(Nil)
  assert service.exchange(f.service, envelope(wire.CloseScope, 1))
    == Error(service.Uncertain)

  // Even the original pool's observed exit cannot upgrade the uncertain verdict.
  assert service.shutdown(f.service) == Error(service.Uncertain)
  assert disposition(f.service) == "native_uncertain"
  assert process.receive(f.closes, 0) == Error(Nil)

  // Test disposal is not a successful close and grants no retirement proof.
  discard(service.pid(f.service))
  discard(local.pid(f.native))
  cleanup(f)
}

/// Close refuses another generation before touching native or durable custody.
///
/// ## Examples
/// `stale_close_generation_cannot_retire_original_scope_test()`.
pub fn stale_close_generation_cannot_retire_original_scope_test() {
  let f = fixture(RetireHelpers)
  assert service.exchange(f.service, envelope(wire.CloseScope, 2))
    == Error(service.Invalid)
  assert disposition(f.service) == "native_open"
  assert process.receive(f.closes, 0) == Error(Nil)
  assert service.exchange(f.service, envelope(wire.Hello, 1)) == Ok(wire.Hello)

  // Join the service only after its own successful shutdown response.
  let down = process.monitor(service.pid(f.service))
  assert service.shutdown(f.service) == Ok(Nil)
  joined(down)
  assert process.receive(f.closes, 1000) == Ok(Nil)
  cleanup(f)
}

fn discard(pid: process.Pid) -> Nil {
  let down = process.monitor(pid)
  process.unlink(pid)
  process.kill(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(down, fn(value) { value })
    |> process.selector_receive(3000)
    as "The failed fixture actor is joined for test disposal only."
  Nil
}

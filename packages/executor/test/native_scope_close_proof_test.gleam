//// Original scope-close proofs bind actual Service/native/journal identities.
//// Real-helper controls retain actual SQL covered confirmations and separate
//// original Normal joins. A lost proof reply never becomes a renewed close.
//// LSP protocol-peer controls prove refused evidence only, not OS retirement.

import broker/broker
import broker/exec
import broker/executor as local
import broker/framing
import broker/policy
import core/generation
import core/ids
import executor
import executor/remote/admission
import executor/remote/identity
import executor/remote/journal
import executor/remote/lsp_journal as custody
import executor/remote/lsp_native
import executor/remote/registration
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/time/timestamp
import lsp/internal/consumed_channel as consumed
import lsp/transport
import simplifile
import sqlight
import support/lsp_native_fixture as lsp_fixture
import telemetry/log
import tools/fs
import weft
import weft/poll

type CloseMode {
  RetireNative
  FailCoveredConfirmation
  LoseNativeProof
  HoldReply(process.Subject(process.Subject(Nil)))
}

type Fixture {
  Fixture(
    path: String,
    service: service.Service,
    journal: journal.Journal,
    native: local.Executor,
    closes: process.Subject(Nil),
    registered: registration.Registration,
  )
}

pub fn actual_native_pool_and_covered_sql_precede_original_proof_test() {
  let f = fixture(RetireNative)
  let #(key, digest) = completed(f)
  let native_down = process.monitor(local.pid(f.native))
  let service_down = process.monitor(service.pid(f.service))
  let assert Ok(proof) = service.shutdown_original(f.service)
    as "Only actual original retirement and covered SQL produce this proof."
  joined(native_down)
  joined(service_down)
  let assert Ok(summary) = service.validate_scope_close(f.service, proof)
    as "Original immutable handle validation works after successful actor exit."
  assert bit_size(summary) == 32
  let assert Ok(evidence) = journal.inspect(f.journal, key, digest)
    as "The exact covered original SQL evidence remains readable."
  let assert admission.Terminal(_, admission.NativeRetired, _) =
    admission.phase(evidence)
    as "Covered confirmation committed actual NativeRetired."
  assert service.shutdown_original(f.service) == Error(service.Uncertain)
  assert process.receive(f.closes, 1000) == Ok(Nil)
  assert process.receive(f.closes, 0) == Error(Nil)
  cleanup(f)
}

pub fn replacement_service_handle_cannot_validate_original_proof_test() {
  let f = fixture(RetireNative)
  let config = service.configuration(f.service)
  let assert Ok(replacement) = service.start(config)
    as "A real second Service has identical immutable configuration."
  let down = process.monitor(service.pid(f.service))
  let assert Ok(proof) = service.shutdown_original(f.service)
    as "Only the original Service produced successful native proof."
  joined(down)
  assert service.validate_scope_close(replacement, proof)
    == Error(service.Invalid)
  assert service.validate_scope_close(f.service, proof) |> result.is_ok
  discard(service.pid(replacement))
  cleanup(f)
}

pub fn failed_covered_confirmation_retains_native_success_without_proof_test() {
  let f = fixture(FailCoveredConfirmation)
  let _ = completed(f)
  let native_down = process.monitor(local.pid(f.native))
  assert service.shutdown_original(f.service) == Error(service.Uncertain)
  joined(native_down)
  assert process.is_alive(service.pid(f.service))
  assert process.receive(f.closes, 1000) == Ok(Nil)
  assert service.shutdown_original(f.service) == Error(service.Uncertain)
  assert process.receive(f.closes, 0) == Error(Nil)
  discard(service.pid(f.service))
  assert simplifile.delete(f.path) == Ok(Nil)
}

pub fn native_uncertainty_cannot_construct_scope_close_proof_test() {
  let f = fixture(LoseNativeProof)
  assert service.shutdown_original(f.service) == Error(service.Uncertain)
  assert service.shutdown_original(f.service) == Error(service.Uncertain)
  assert process.receive(f.closes, 1000) == Ok(Nil)
  assert process.receive(f.closes, 0) == Error(Nil)
  discard(service.pid(f.service))
  discard(local.pid(f.native))
  cleanup(f)
}

pub fn cancelled_waiting_caller_loses_reply_without_cancelling_original_close_test() {
  let held = process.new_subject()
  let f = fixture(HoldReply(held))
  let native_down = process.monitor(local.pid(f.native))
  let service_down = process.monitor(service.pid(f.service))
  let original = f.service
  let run =
    weft.new_prepared([
      weft.managed(fn(_) { service.shutdown_original(original) }),
    ])
    |> weft.deadline(3000)
    |> weft.cancel_grace(100)
    |> weft.start_detached
  let assert Ok(permit) = process.receive(held, 2000)
    as "Actual pool retirement reached the original close turn's finite gate."
  weft.cancel_detached(run)
  let assert weft.PulledOutcome(weft.Abandoned(0)) = weft.pull(run, 1000)
    as "The original waiting caller has cancelled before the close reply."
  let assert weft.AllDelivered = weft.pull(run, 1000)
    as "The cancelled observation's actual run drains."
  assert process.is_alive(service.pid(f.service))
  process.send(permit, Nil)
  joined(native_down)
  joined(service_down)
  assert service.shutdown_original(f.service) == Error(service.Uncertain)
  cleanup(f)
}

pub fn possibly_committed_lsp_request_cannot_forge_covered_retirement_test() {
  let rig = lsp_fixture.start(lsp_fixture.WirePeer)
  let #(claim, lease, key, operation) = lsp_fixture.lease(rig, 25)
  let assert Ok(pending) =
    lsp_native.install_pending(rig.service, rig.store, claim, rig.plan, rig.era)
    as "Actual original lease custody installs once."
  let #(prepared, owner, _) = lsp_fixture.cleared(rig, operation)
  let assert Ok(digest) = wire.prepared_digest(prepared)
    as "The exact original native request digest is canonical."
  let assert Ok(db) = sqlight.open(rig.path <> "/s/native.sqlite")
    as "A separate real fixture writer installs the original authority refusal."
  assert sqlight.exec(
      "CREATE TRIGGER suppress_authority BEFORE INSERT ON custody_payload WHEN NEW.kind=1 BEGIN SELECT RAISE(IGNORE); END",
      db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  assert lsp_native.submit(pending, key, prepared) == Error(service.Uncertain)
  assert service.shutdown_original(rig.service) == Error(service.Invalid)
  let assert Ok(history) = custody.inspect_lease(rig.store, rig.binding, lease)
    as "Possibly committed custody stays retained under its exact original lease."
  assert custody.lease_disposition(history) != custody.Retired
  assert journal.payloads(rig.book, key, digest) |> result.is_ok
  list.each(rig.peers, fn(peer) {
    assert process.receive(peer.outbound, 0) == Error(Nil)
  })
  broker.stop(owner)
  discard(service.pid(rig.service))
  assert custody.release(rig.store) == Ok(Nil)
  assert journal.release(rig.book) == Ok(Nil)
  assert simplifile.delete(rig.path) == Ok(Nil)
}

pub fn begun_lsp_original_observer_and_drain_precede_scope_proof_test() {
  let rig = lsp_fixture.start(lsp_fixture.WirePeer)
  let #(claim, lease, key, operation) = lsp_fixture.lease(rig, 26)
  let assert Ok(pending) =
    lsp_native.install_pending(rig.service, rig.store, claim, rig.plan, rig.era)
    as "The actual original lease installs its sole pending owner."
  let #(prepared, owner, _) = lsp_fixture.cleared(rig, operation)
  let assert Ok(attachment) = lsp_native.submit(pending, key, prepared)
    as "Actual native admission precedes the original Begin."
  let assert transport.ConsumedChannelTransport(connect) =
    lsp_native.transport(attachment)
    as "The original attachment owns the consumed channel."
  let assert Ok(window) = consumed.open(connect, process.new_subject())
    as "The actual sink starts the original protocol dispatch."
  let assert poll.Answered(Nil) =
    poll.until(1000, 5, fn() {
      case
        list.find_map(rig.peers, fn(peer) {
          process.receive(peer.outbound, 0)
          |> result.map(fn(bytes) { #(peer, bytes) })
        })
      {
        Ok(#(_peer, bytes)) -> {
          let assert [framing.Known(frame)] =
            framing.push(framing.deframer(), bytes).inbound
            as "The original actual wire contains one canonical frame."
          let assert framing.ProtocolStart(mode: framing.ServerProtocol, ..) =
            frame.body
            as "This original LSP actually Began before the refusal control."
          poll.Done(Nil)
        }
        Error(_) -> poll.Retry
      }
    })
    as "The original admitted helper reaches its blocked start observer."
  let assert Ok(before) = lsp_native.cleanup(attachment)
    as "The exact original observer is retained before scope close."
  assert before.native == service.LspAwaitingNative
  assert before.drain == service.LspPendingDrain
  assert service.shutdown_original(rig.service) == Error(service.Uncertain)
  assert process.is_alive(service.pid(rig.service))
  let assert Ok(history) = custody.inspect_lease(rig.store, rig.binding, lease)
    as "Refused close cannot retire the original durable LSP lease."
  assert custody.lease_disposition(history) != custody.Retired
  window.close()
  broker.stop(owner)

  // This deterministic peer supplies original protocol ordering only. The
  // separate actual helper test establishes physical pool retirement evidence.
  list.each(rig.peers, fn(peer) {
    process.send(exec.wire(peer.helper), exec.WireClosed(0))
  })
  let native_down = process.monitor(local.pid(rig.native))
  let service_down = process.monitor(service.pid(rig.service))
  let assert poll.Answered(proof) =
    poll.until(3000, 5, fn() {
      case service.shutdown_original(rig.service) {
        Ok(proof) -> poll.Done(proof)
        Error(service.Uncertain) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "Only the original positive observer and managed drain permit proof."
  joined(native_down)
  joined(service_down)
  assert service.validate_scope_close(rig.service, proof) |> result.is_ok
  assert custody.release(rig.store) == Ok(Nil)
  assert journal.release(rig.book) == Ok(Nil)
  assert simplifile.delete(rig.path) == Ok(Nil)
}

fn bit_size(digest: generation.Digest) -> Int {
  generation.digest_bytes(digest) |> bit_array.byte_size
}

fn joined(watch: process.Monitor) -> Nil {
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(3000)
    as "Successful close is followed by this exact original Normal DOWN."
  Nil
}

fn discard(pid: process.Pid) -> Nil {
  case process.is_alive(pid) {
    False -> Nil
    True -> {
      let watch = process.monitor(pid)
      process.unlink(pid)
      process.kill(pid)
      let assert Ok(_) =
        process.new_selector()
        |> process.select_specific_monitor(watch, fn(down) { down })
        |> process.selector_receive(1000)
        as "Explicit test disposal joins an uncertain original without granting proof."
      Nil
    }
  }
}

fn cleanup(f: Fixture) -> Nil {
  assert journal.release(f.journal) == Ok(Nil)
  assert simplifile.delete(f.path) == Ok(Nil)
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

fn fixture(outcome: CloseMode) -> Fixture {
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
          RetireNative -> retired
          HoldReply(observations) -> {
            let permit = process.new_subject()
            process.send(observations, permit)
            let assert Ok(Nil) = process.receive(permit, 2000)
              as "Only the original finite reply gate is released."
            retired
          }
          LoseNativeProof -> Error(exec.RetirementPending)
          FailCoveredConfirmation -> {
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
  let assert Ok(registered) =
    registration.new(
      scope(),
      [path],
      executor.base_policy(path),
      exec.PlatformEnforcement,
      fn(value) {
        fs.resolve_real(fs.real_filesystem(), "/", value)
        |> result.replace_error(Nil)
      },
    )
    as "Actual immutable registration bounds every submitted native request."
  let assert Ok(remote) =
    service.start(service.Config(
      "owner",
      "linux",
      scope(),
      1,
      book,
      native,
      fn(key, prepared) { registration.verify(registered, key, prepared) },
      poll.monotonic().now,
    ))
  Fixture(path, remote, book, native, closes, registered)
}

fn completed(f: Fixture) -> #(identity.RequestKey, identity.Digest) {
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000003")
  let key = identity.request_key(scope(), op, request)
  let registration = registration.digest(f.registered)
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

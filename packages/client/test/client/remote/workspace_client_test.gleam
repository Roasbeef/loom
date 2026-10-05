//// Concrete owner consumer tests using actual SQLite, TLS and filesystem work.
////
//// Each scenario owns independent TLS BEAM owner and executor OS processes.
//// Parent execution is unreachable; retries retain original UUID and content.
//// Fixed file barriers replace cross-node callbacks and preserve effect ordering.
//// `cancel_executor` is fixed test administration of one original Accepted row.

import broker/exec
import broker/executor as native
import broker/policy
import client/remote/custodian
import client/remote/workspace_binding as binding
import client/remote/workspace_client as client
import core/clock
import core/ids
import core/remote_tool
import core/workspace as cw
import distribution_fixture
import executor/remote/admission
import executor/remote/beam_endpoint as connection
import executor/remote/distribution
import executor/remote/identity
import executor/remote/internal/beam_protocol as transport
import executor/remote/journal as native_journal
import executor/remote/service as native_service
import executor/remote/workspace_journal as journal
import executor/remote/workspace_service as service
import gleam/bit_array
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlight
import storage/owner_custody as custody
import support/workspace_beam_fixture as beam_fixture
import telemetry/log
import tools/directory_access
import tools/fs
import tools/tool
import tools/workspace
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft/poll
import weft/registry

// Stock OTP suspension makes custody contention deterministic without a new
// production callback or a sleep racing the storage actor.
@external(erlang, "erlang", "suspend_process")
fn suspend(pid: process.Pid) -> Bool

@external(erlang, "erlang", "resume_process")
fn resume(pid: process.Pid) -> Bool

type Fixture {
  FixtureState(
    root: String,
    owner: custodian.Handle,
    owner_config: custodian.Config,
    owner_pid: process.Pid,
    book: journal.Journal,
    connection: connection.Config,
  )
}

pub fn completion_receipt_and_ack_are_joined_before_return_test() {
  use peer <- beam_fixture.run(
    "completion_receipt_and_ack_are_joined_before_return_test",
  )
  let f = fixture(peer)
  let c = config(f, 11, 5000)
  let request = workspace.Write(path("proof.txt"), "first\n")
  let assert Ok(client.Completed(
    Ok(local.Completed(workspace.WriteCompleted(Ok(_)), None)),
    client.Confirmed,
  )) = invoke(c, child(0), request)
    as "Actual mutation, owner receipt and executor ACK complete together."

  // The receipt and ACK precede return; the owner performs no local mutation.
  assert simplifile.read(f.root <> "/executor/proof.txt") == Ok("first\n")
  assert simplifile.is_file(f.root <> "/owner/proof.txt") == Ok(False)
  let assert Ok(#(original, bytes, Some(receipt))) =
    custodian.child(f.owner, child(0))
    as "Owner exact receipt exists when the consumer returns."
  assert original == entry(11)
  assert codec.decode_completion(request, receipt) |> result.is_ok
  assert connection.workspace_exchange(f.connection, transport.Query, bytes)
    == Ok(journal.Acknowledged(journal.digest(receipt)))

  // A duplicate would overwrite an independent editor's later change.
  assert simplifile.write(f.root <> "/executor/proof.txt", "later\n") == Ok(Nil)
  let c = config(f, 999, 5000)
  let assert Ok(client.Completed(_, client.Confirmed)) =
    invoke(c, child(0), request)
    as "Exact retry returns retained result under original UUID."
  assert custodian.child(f.owner, child(0))
    == Ok(#(original, bytes, Some(receipt)))
  assert simplifile.read(f.root <> "/executor/proof.txt") == Ok("later\n")
  finish(f)
}

pub fn recovered_receipt_is_usable_when_executor_cannot_answer_test() {
  use peer <- beam_fixture.run(
    "recovered_receipt_is_usable_when_executor_cannot_answer_test",
  )
  let f = fixture(peer)
  let request = workspace.Initialize
  let b = binding.new(scope(), f.owner, fn() { entry(11) })
  let assert Ok(reserved) = reserve(b, child(0), request)
    as "Preexisting original owner reservation."
  let assert Ok(bytes) =
    codec.encode_completion(
      request,
      Ok(local.Completed(
        workspace.InitializationCompleted(Ok(workspace.AlreadyInitialized)),
        None,
      )),
    )
    as "Exact valid completion encodes."
  let assert Ok(_) = binding.receive(reserved, bytes)
    as "Receipt commits independently of the consumer callback."

  // Durable owner custody remains usable after the actual executor retires.
  start_executor(f)
  beam_fixture.mark(f.root, "done")
  beam_fixture.await(beam_fixture.root(), "executor-success")
  let endpoint = connection.Config(..f.connection, within_ms: 50)
  let assert Ok(c) =
    client.new(scope(), f.owner, fn() { entry(999) }, endpoint, 50)
    as "Unavailable endpoint is still valid administrative configuration."
  let assert Ok(client.Completed(completion, client.Retained)) =
    client.recover(c, child(0))
    as "Durable owner completion survives lost executor ACK."
  assert completion
    == Ok(local.Completed(
      workspace.InitializationCompleted(Ok(workspace.AlreadyInitialized)),
      None,
    ))

  // Historical owner receipt bytes remain exact despite executor loss.
  assert custodian.child(f.owner, child(0))
    == Ok(#(entry(11), binding.content(reserved), Some(bytes)))
  finish(f)
}

pub fn recovered_started_observes_without_reexecuting_test() {
  use peer <- beam_fixture.run(
    "recovered_started_observes_without_reexecuting_test",
  )
  let f = fixture(peer)
  let request = workspace.Write(path("never.txt"), "must not run")
  let b = binding.new(scope(), f.owner, fn() { entry(11) })
  let assert Ok(reserved) = reserve(b, child(0), request)
    as "Owner reservation exists before executor claim."
  assert journal.admit(f.book, binding.content(reserved))
    == Ok(journal.Accepted)
  let assert Ok(journal.Claimed(_)) =
    journal.claim(f.book, binding.content(reserved))
    as "Original claim commits without starting a filesystem worker."

  // Recovery observes retained executor disposition and cannot claim fresh work.
  assert_observation_only(
    client.recover(config(f, 999, 500), child(0)),
    reserved,
  )
  assert custodian.child(f.owner, child(0))
    == Ok(#(entry(11), binding.content(reserved), None))
  assert simplifile.is_file(f.root <> "/executor/never.txt") == Ok(False)
  finish(f)
}

pub fn recovered_accepted_and_cancelled_never_submit_test() {
  use peer <- beam_fixture.run(
    "recovered_accepted_and_cancelled_never_submit_test",
  )
  let f = fixture(peer)
  let b = binding.new(scope(), f.owner, fn() { entry(11) })
  let request = workspace.Write(path("never.txt"), "must not run")
  let assert Ok(reserved) = reserve(b, child(0), request)
    as "Accepted evidence has exact retained owner identity."
  assert journal.admit(f.book, binding.content(reserved))
    == Ok(journal.Accepted)

  // Recovery observes retained executor disposition and cannot claim fresh work.
  assert_observation_only(
    client.recover(config(f, 999, 500), child(0)),
    reserved,
  )
  assert connection.workspace_exchange(
      f.connection,
      transport.Query,
      binding.content(reserved),
    )
    == Ok(journal.Accepted)

  // The same Accepted identity cancels locally, then the owner observes it.
  assert cancel_executor(f, binding.content(reserved)) == Ok(journal.Cancelled)
  let assert Ok(client.Cancelled(retained)) =
    client.recover(config(f, 999, 500), child(0))
    as "Durable cancellation is explicit and terminal for this identity."
  assert binding.content(retained) == binding.content(reserved)
  assert simplifile.is_file(f.root <> "/executor/never.txt") == Ok(False)
  finish(f)
}

pub fn executor_ack_without_owner_receipt_is_invariant_failure_test() {
  use peer <- beam_fixture.run(
    "executor_ack_without_owner_receipt_is_invariant_failure_test",
  )
  let f = fixture(peer)
  let request = workspace.Initialize
  let b = binding.new(scope(), f.owner, fn() { entry(11) })
  let assert Ok(reserved) = reserve(b, child(0), request)
    as "Original owner has no completion."
  assert journal.admit(f.book, binding.content(reserved))
    == Ok(journal.Accepted)
  let assert Ok(journal.Claimed(claim)) =
    journal.claim(f.book, binding.content(reserved))
    as "Test controls one valid claim."
  let assert Ok(bytes) =
    codec.encode_completion(
      request,
      Ok(local.Completed(
        workspace.InitializationCompleted(Ok(workspace.AlreadyInitialized)),
        None,
      )),
    )
    as "Fixture completion matches request."

  // Executor collection without owner custody is an invariant violation.
  assert journal.finish(claim, bytes) == Ok(journal.Finished(bytes))
  assert journal.acknowledge(
      f.book,
      binding.content(reserved),
      journal.digest(bytes),
    )
    == Ok(journal.Acknowledged(journal.digest(bytes)))
  let assert Ok(client.InvariantFailure(retained)) =
    client.recover(config(f, 999, 1000), child(0))
    as "Collected executor payload without owner receipt cannot authorize replay."
  assert binding.content(retained) == binding.content(reserved)
  assert custodian.child(f.owner, child(0))
    == Ok(#(entry(11), binding.content(reserved), None))
  finish(f)
}

pub fn invalid_scope_budget_and_changed_candidate_refuse_before_send_test() {
  use peer <- beam_fixture.run(
    "invalid_scope_budget_and_changed_candidate_refuse_before_send_test",
  )
  let f = fixture(peer)
  let endpoint = connection.Config(..f.connection, scope: identity_scope(2))
  assert client.new(scope(), f.owner, fn() { entry(11) }, endpoint, 5000)
    == Error(client.InvalidConfiguration)
  assert client.new(scope(), f.owner, fn() { entry(11) }, f.connection, 0)
    == Error(client.InvalidConfiguration)
  assert client.new(scope(), f.owner, fn() { entry(11) }, f.connection, 30_001)
    == Error(client.InvalidConfiguration)
  assert client.new(scope(), f.owner, fn() { entry(11) }, f.connection, 50)
    == Error(client.InvalidConfiguration)

  // A changed retry cannot replace the original completed reservation.
  let c = config(f, 11, 5000)
  let original = workspace.Write(path("proof.txt"), "first")
  let assert Ok(client.Completed(_, _)) = invoke(c, child(0), original)
    as "Original candidate finishes."
  let changed = workspace.Write(path("proof.txt"), "changed")
  assert invoke(c, child(0), changed)
    == Error(client.OwnerUnavailable(child(0), custody.Conflict))
  assert simplifile.read(f.root <> "/executor/proof.txt") == Ok("first")
  finish(f)
}

pub fn failed_receipt_commit_preserves_effect_and_original_reservation_test() {
  use peer <- beam_fixture.run(
    "failed_receipt_commit_preserves_effect_and_original_reservation_test",
  )
  let f = fixture(peer)
  let assert Ok(db) = sqlight.open(f.root <> "/owner/custody.db")
    as "Separate test connection installs a durable receipt refusal."
  assert sqlight.exec(
      "CREATE TRIGGER reject_receipt BEFORE UPDATE OF terminal ON owner_custody_children BEGIN SELECT RAISE(ABORT, 'receipt refusal'); END",
      db,
    )
    == Ok(Nil)

  // A failed owner COMMIT cannot turn an executed mutation into a refusal.
  let request = workspace.Write(path("proof.txt"), "executed once")
  let assert Ok(client.Pending(reserved, client.ReceiptUncertain)) =
    invoke(config(f, 11, 5000), child(0), request)
    as "Executed mutation cannot become a pre-effect refusal after receipt failure."
  assert custodian.child(f.owner, child(0))
    == Ok(#(entry(11), binding.content(reserved), None))
  let assert Ok(journal.Finished(bytes)) =
    connection.workspace_exchange(
      f.connection,
      transport.Query,
      binding.content(reserved),
    )
    as "Executor must retain exact completion without owner ACK."
  assert simplifile.read(f.root <> "/executor/proof.txt") == Ok("executed once")

  // Restored receipt storage settles original bytes without repeating the effect.
  assert simplifile.write(f.root <> "/executor/proof.txt", "later") == Ok(Nil)
  assert sqlight.exec("DROP TRIGGER reject_receipt", db) == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  let assert Ok(client.Completed(_, client.Confirmed)) =
    client.recover(config(f, 999, 5000), child(0))
    as "Original completion settles after receipt storage becomes available."
  assert custodian.child(f.owner, child(0))
    == Ok(#(entry(11), binding.content(reserved), Some(bytes)))
  assert simplifile.read(f.root <> "/executor/proof.txt") == Ok("later")
  finish(f)
}

pub fn invalid_payload_cannot_send_before_durable_reservation_test() {
  use peer <- beam_fixture.run(
    "invalid_payload_cannot_send_before_durable_reservation_test",
  )
  let f = fixture(peer)
  let request =
    workspace.Write(
      path("never.txt"),
      string.repeat("x", codec.max_invocation_bytes),
    )
  assert invoke(config(f, 11, 1000), child(0), request)
    == Error(client.OwnerUnavailable(
      child(0),
      custody.Invalid("invalid workspace content"),
    ))
  assert custodian.child(f.owner, child(0)) == Error(custody.Missing)
  assert simplifile.is_file(f.root <> "/executor/never.txt") == Ok(False)
  finish(f)
}

pub fn observer_crash_is_distinct_from_deadline_and_preserves_child_test() {
  use peer <- beam_fixture.run(
    "observer_crash_is_distinct_from_deadline_and_preserves_child_test",
  )
  let f = fixture(peer)
  start_executor(f)
  let assert Ok(c) =
    client.new(
      scope(),
      f.owner,
      fn() {
        panic as "Controlled trusted mint failure inside the managed observer."
      },
      f.connection,
      5000,
    )
    as "Configuration does not evaluate the UUID mint."
  assert invoke(c, child(0), workspace.Write(path("never.txt"), "never"))
    == Error(client.ObservationLost(child(0)))
  assert custodian.child(f.owner, child(0)) == Error(custody.Missing)
  assert simplifile.is_file(f.root <> "/executor/never.txt") == Ok(False)
  finish(f)
}

pub fn whole_call_deadline_bounds_initial_owner_waits_test() {
  use peer <- beam_fixture.run(
    "whole_call_deadline_bounds_initial_owner_waits_test",
  )
  let f = fixture(peer)
  let c = config(f, 11, 50)
  assert suspend(f.owner_pid)
  let started = poll.monotonic().now()
  let first = invoke(c, child(0), workspace.Write(path("never.txt"), "never"))
  let recovered = client.recover(c, child(0))
  let elapsed = poll.monotonic().now() - started
  assert resume(f.owner_pid)

  // Expired observers cannot reserve through the resumed owner afterward.
  assert first == Error(client.ObservationExpired(child(0)))
  assert recovered == Error(client.ObservationExpired(child(0)))
  assert elapsed < 1000
  assert custodian.child(f.owner, child(0)) == Error(custody.Missing)
  assert simplifile.is_file(f.root <> "/executor/never.txt") == Ok(False)
  finish(f)
}

pub fn whole_call_deadline_preserves_effect_and_original_identity_test() {
  use peer <- beam_fixture.run(
    "whole_call_deadline_preserves_effect_and_original_identity_test",
  )
  let f = fixture(peer)
  beam_fixture.mark(f.root, "hold-after-write")
  let request = workspace.Write(path("proof.txt"), "original")
  let answers = process.new_subject()
  let c = config(f, 11, 500)
  let started = poll.monotonic().now()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(answers, invoke(c, child(0), request))
    })

  // The executor effect is already complete before owner contention begins.
  beam_fixture.await(f.root, "written")
  assert suspend(f.owner_pid)
  beam_fixture.mark(f.root, "release-write")
  let answer = process.receive(answers, 2000)
  let elapsed = poll.monotonic().now() - started
  assert resume(f.owner_pid)
  let assert Ok(answer) = answer as "Consumer returns despite stalled owner."

  // Expiry retains the same recovery key while withholding owner receipt and ACK.
  assert answer == Error(client.ObservationExpired(child(0)))
  assert elapsed < 1500

  // The observer expires during the pre-receipt owner read. No ACK is granted;
  // recovery must retain the original completion without repeating the write.
  let assert Ok(#(id, content, receipt)) = custodian.child(f.owner, child(0))
    as "Original reservation survives observation expiry."
  assert id == entry(11)
  let assert Ok(journal.Finished(bytes)) =
    connection.workspace_exchange(f.connection, transport.Query, content)
    as "Executor retains completion until an owner actually acknowledges it."
  assert receipt == None

  // An independent later editor change must survive original receipt recovery.
  assert simplifile.write(f.root <> "/executor/proof.txt", "later") == Ok(Nil)
  let assert Ok(client.Completed(_, client.Confirmed)) =
    client.recover(config(f, 999, 5000), child(0))
    as "Recovery stores and acknowledges the original executor completion."
  assert custodian.child(f.owner, child(0)) == Ok(#(id, content, Some(bytes)))
  assert simplifile.read(f.root <> "/executor/proof.txt") == Ok("later")
  finish(f)
}

// Poll completion, a bounded transport failure and the enclosing task deadline
// can race. None grants another effect; each retains the original recovery key.
fn assert_observation_only(answer, reserved) {
  case answer {
    Ok(client.Pending(retained, client.AwaitingEvidence))
    | Ok(client.Pending(retained, client.TransportUncertain)) -> {
      assert binding.content(retained) == binding.content(reserved)
    }
    Error(client.ObservationExpired(origin)) -> {
      assert origin == child(0)
    }
    other -> {
      let assert Error(client.ObservationExpired(_)) = other
        as "Only bounded observation uncertainty is permissible."
      Nil
    }
  }
}

fn config(f: Fixture, seed: Int, within: Int) {
  start_executor(f)
  let endpoint = connection.Config(..f.connection, within_ms: within)
  let assert Ok(c) =
    client.new(scope(), f.owner, fn() { entry(seed) }, endpoint, within)
    as "Consumer binds exact scope and finite endpoint."
  c
}

fn invoke(
  c: client.Config,
  origin: remote_tool.ChildOrigin,
  request: workspace.Request,
) {
  client.invoke(c, origin, operation(), step(), tool_origin(), request)
}

fn fixture(peer: distribution.Peer) -> Fixture {
  let root = beam_fixture.root() <> "/data"
  assert simplifile.create_directory_all(root <> "/owner") == Ok(Nil)
  assert simplifile.create_directory_all(root <> "/executor") == Ok(Nil)

  // The actual parent admission is committed before the child custodian opens.
  let assert Ok(limits) =
    custody.limits(4, 16, 268_435_456, codec.max_completion_bytes)
    as "Owner reserves complete workspace results within finite aggregate capacity."
  let owner_path = root <> "/owner/custody.db"
  let assert Ok(store) = custody.open(owner_path, session(), limits)
    as "Owner SQLite opens."
  let assert Ok(parent) = custody.payload(limits, <<"parent">>)
    as "Parent material is bounded."
  assert custody.admit(store, key(), parent, parent) == Ok(Nil)
  assert custody.close(store) == Ok(Nil)

  // The owner actor alone retains child admission and final receipt authority.
  let assert Ok(names) = registry.start() as "Fixture owns a registry."
  let assert Ok(owner_config) =
    custodian.config(owner_path, session(), limits, 1, 5000, fn(_, _, _) {
      panic as "Child recovery must never execute the parent tool."
    })
    as "Owner lifetime is finite."
  let owner = custodian.new(names, owner_config)
  let assert Ok(owner_started) = custodian.start(owner, owner_config)
    as "Owner custodian starts."

  // Executor reservations have a distinct actual SQLite journal and ceiling.
  let assert Ok(limits) = journal.limits(4, 268_435_456)
    as "Executor reservation is bounded."
  let assert Ok(book) =
    journal.fresh(root <> "/executor/custody.db", scope(), limits)
    as "Executor SQLite opens."
  let endpoint =
    connection.Config(peer, "owner", "executor", identity_scope(1), 1, 5000)
  FixtureState(root, owner, owner_config, owner_started.pid, book, endpoint)
}

/// The fixed executor role hosts actual SQLite, filesystem and native services.
/// Only test barriers control setup; production operations cross the TLS endpoint.
pub fn executor_main() -> Nil {
  let runtime_root = beam_fixture.root()
  let root = runtime_root <> "/data"
  let assert Ok(provisioned) =
    distribution_fixture.read_provisioned(runtime_root <> "/fixture.term")
    as "The executor receives only its original administrative fixture."
  let assert Ok(membership) = distribution.start(provisioned.executor_config)
    as "The independent executor enters real mutual TLS membership."
  let assert Ok(owner) = distribution.peer(membership, provisioned.owner_name)
    as "The registered owner has exact admitted boot provenance."
  let assert poll.Answered(Nil) =
    poll.until(10_000, 10, fn() {
      case simplifile.is_file(root <> "/start") {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "The owner commits and releases test setup before executor startup."

  // Executor reservations have a distinct actual SQLite journal and ceiling.
  let assert Ok(limits) = journal.limits(4, 268_435_456)
    as "The executor retains the original reservation ceiling."
  let assert Ok(book) =
    journal.recover(root <> "/executor/custody.db", scope(), limits)
    as "The original journal metadata and historical fences reopen unchanged."
  let host =
    local_host(scope(), context(root <> "/executor"), fn(_) {
      case simplifile.is_file(root <> "/hold-after-write") {
        Ok(True) -> {
          beam_fixture.mark(root, "written")
          beam_fixture.await(root, "release-write")
          None
        }
        _ -> None
      }
    })
  let assert Ok(config) = service.configure(host, book, 2, 10_000)
    as "Concrete semantic host and journal share the exact original scope."
  let assert Ok(semantic) = service.start(config)
    as "Real executor-local filesystem work owns its own effect custody."

  // Enrollment derives from concrete local service owners, never wire callbacks.
  let #(native_executor, native_remote) = concrete_native(root)
  let assert Ok(row) =
    connection.registration(
      owner,
      native_remote,
      Some(semantic),
      process.self(),
    )
    as "Enrollment binds the actual native and semantic actors locally."
  let assert Ok(server_config) = connection.configure_server([row], 10_000)
    as "Only this original scope enters the finite node-wide rendezvous."
  let assert Ok(endpoint) = connection.start(server_config)
    as "The actual fixed endpoint publishes after TLS bootstrap and local setup."
  beam_fixture.mark(root, "ready")

  // A fixed Accepted cancellation control preserves the original test setup
  // without adding a semantic Cancel command to the production wire protocol.
  let assert poll.Answered(Nil) =
    poll.until(15_000, 10, fn() {
      case simplifile.is_file(root <> "/done") {
        Ok(True) -> poll.Done(Nil)
        _ -> {
          case
            simplifile.is_file(root <> "/cancel"),
            simplifile.is_file(root <> "/cancelled")
          {
            Ok(True), Ok(False) -> {
              let assert Ok(bytes) =
                simplifile.read_bits(root <> "/cancel.bytes")
                as "The control contains the original canonical retained request."
              assert journal.cancel(book, bytes) == Ok(journal.Cancelled)
              beam_fixture.mark(root, "cancelled")
            }
            _, _ -> Nil
          }
          poll.Retry
        }
      }
    })
    as "The finite executor role observes its explicit shutdown barrier."
  connection.quiesce(endpoint)
  assert service.close(semantic) == Ok(Nil)
  assert journal.mode(book) == Ok(journal.SealedScope)
  assert journal.release(book) == Ok(Nil)
  connection.stop(endpoint)
  assert native.close(native_executor, draining: 1000, helpers: 1000) == Ok(Nil)
  beam_fixture.mark(runtime_root, "executor-success")
}

fn concrete_native(root: String) {
  let assert Ok(executor) =
    native.start(native.ExecutorConfig(
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Nil },
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Ok(Nil) },
      4,
      log.discard(),
    ))
    as "A real native actor exists; semantic-only cases allocate no process pool."
  let assert Ok(capacity) = admission.capacity(4)
    as "Native admission remains finite even though these cases send no commands."
  let assert Ok(book) =
    native_journal.fresh(root <> "/native.sqlite", identity_scope(1), capacity)
    as "Actual native registration has separate SQLite custody."
  let assert Ok(remote) =
    native_service.start(native_service.Config(
      "owner",
      "executor",
      identity_scope(1),
      1,
      book,
      executor,
      fn(_, _) { Ok(Nil) },
      poll.monotonic().now,
    ))
    as "The endpoint enrollment derives from the real scoped native service."
  #(executor, remote)
}

// Seeding commits before the executor opens this same journal. Recovery retains
// its exact metadata, Accepted/Started fences and all original invocation bytes.
fn start_executor(f: Fixture) -> Nil {
  case simplifile.is_file(f.root <> "/start") {
    Ok(True) -> Nil
    _ -> {
      assert journal.release(f.book) == Ok(Nil)
      beam_fixture.mark(f.root, "start")
      beam_fixture.await(f.root, "ready")
    }
  }
}

// This fixed test administration is not a production workspace command. It
// cancels exactly the original retained Accepted row in the executor's book.
fn cancel_executor(f: Fixture, bytes: BitArray) {
  assert simplifile.write_bits(f.root <> "/cancel.bytes", bytes) == Ok(Nil)
  beam_fixture.mark(f.root, "cancel")
  beam_fixture.await(f.root, "cancelled")
  connection.workspace_exchange(f.connection, transport.Query, bytes)
}

fn context(root: String) -> tool.Ctx {
  tool.Ctx(
    workspace: tool.LocalWorkspace(root, fs.real_filesystem()),
    strand: "main",
    op_id: operation(),
    step_id: "workspace",
    source_index: 0,
    base_policy: policy.workspace_default(root),
    directory_access: directory_access.none(),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(1000),
    owner_blobs: tool.OwnerBlobs(root <> "/.blobs", fs.real_filesystem()),
    clear_call: fn(_, _) {
      panic as "File-only fixture must not launch a process."
    },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn reserve(
  b: binding.Binding,
  child: remote_tool.ChildOrigin,
  request: workspace.Request,
) {
  binding.reserve(b, child, operation(), step(), tool_origin(), request)
}

fn session() {
  ids.mint_session(ids.generator(clock.fixed(1000), 1)).0
}

fn operation() {
  ids.mint_op(ids.generator(clock.fixed(1000), 2)).0
}

fn entry(seed: Int) {
  ids.mint_entry(ids.generator(clock.fixed(1000), seed)).0
}

fn step() {
  let assert Ok(value) = cw.step("workspace") as "Fixture step validates."
  value
}

fn key() {
  let assert Ok(value) =
    remote_tool.key(
      session(),
      operation(),
      "workspace",
      0,
      string.repeat("a", 64),
      entry(3),
    )
    as "Complete parent key validates."
  value
}

fn child(ordinal: Int) {
  let assert Ok(value) =
    remote_tool.tool_child(key(), remote_tool.Workspace(ordinal))
    as "Workspace child cannot alias native launch or capability calls."
  value
}

fn tool_origin() {
  let assert Ok(digest) = bit_array.base16_decode(string.repeat("aa", 32))
    as "Source digest is exact."
  let assert Ok(origin) = workspace.tool_origin(0, digest)
    as "Original source index validates."
  workspace.Tool(origin)
}

fn path(text: String) {
  let assert Ok(value) = cw.relative_path(text) as "Fixture path is relative."
  value
}

fn scope() {
  let assert Ok(value) =
    cw.scope_from_fields(
      ids.session_id_to_string(session()),
      "checkout",
      "executor",
      1,
      1,
    )
    as "Complete scope validates."
  value
}

fn identity_scope(epoch: Int) {
  let assert Ok(w) = identity.workspace_id("checkout")
    as "Workspace label validates."
  let assert Ok(e) = identity.executor_id("executor")
    as "Executor label validates."
  let assert Ok(owner_epoch) = identity.epoch(epoch) as "Owner epoch validates."
  let assert Ok(workspace_epoch) = identity.epoch(1)
    as "Workspace epoch validates."
  identity.scope(session(), w, e, owner_epoch, workspace_epoch)
}

fn stop_owner(f: Fixture) {
  let monitor = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "SQLite owner exits before reopen."
  Nil
}

fn finish(f: Fixture) {
  assert journal.release(f.book) == Ok(Nil)
  stop_owner(f)
  beam_fixture.mark(f.root, "done")
  beam_fixture.await(beam_fixture.root(), "executor-success")
}

// A registered context cannot construct the executor-local host.
fn local_host(
  scope: cw.Scope,
  ctx: tool.Ctx,
  observer: fn(String) -> option.Option(String),
) -> local.Host {
  let assert Ok(host) = local.new(scope, ctx, observer)
    as "fixture must have local authority"
  host
}

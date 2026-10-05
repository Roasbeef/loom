//// Scoped host controls use real independent TLS BEAM nodes and native helpers.
//// One node-owned endpoint is borrowed by concrete scoped lifetime owners.
//// Failure tests trap only their own exit signals, never VM-wide mutable state.
//// No missing prerequisite or uncertain native cleanup is a passing skip.

import broker/dispatch
import broker/exec
import broker/executor as local
import broker/policy
import core/ids
import executor
import executor/remote/admission
import executor/remote/beam_endpoint as endpoint
import executor/remote/host
import executor/remote/identity
import executor/remote/journal
import executor/remote/native
import executor/remote/payload
import executor/remote/registration
import executor/remote/service
import executor/remote/wire
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/time/timestamp
import scoped_host_beam_fixture as beam_fixture
import simplifile
import telemetry/log
import weft
import weft/poll

type DrainReply {
  ReturnWitness
  LoseWitness
  BreakConfirmation
}

type Fixture {
  Fixture(
    path: String,
    pool: exec.Pool,
    native: local.Executor,
    book: journal.Journal,
    registration: registration.Registration,
    provision: host.Provisioning,
    context: beam_fixture.Context,
    witnessed: process.Subject(Result(Nil, exec.RetirementFailure)),
  )
}

type Shutdown {
  Shutdown
}

/// Mismatched bindings are refused before any scoped row can be published.
///
/// ## Examples
///
/// ```gleam
/// bindings_refuse_before_listen_test()
/// ```
pub fn bindings_refuse_before_listen_test() {
  use context <- beam_fixture.run("bindings_refuse_before_listen_test")
  let fixture = fixture(context, "bindings", ReturnWitness)
  let foreign = service.Config(..fixture.provision.service, scope: scope(2))
  assert host.configure(
      host.Provisioning(..fixture.provision, service: foreign),
    )
    == Error(host.InvalidConfiguration)
  let assert Ok(other) =
    registration.new(
      scope(2),
      [fixture.path],
      executor.base_policy(fixture.path),
      exec.PlatformEnforcement,
      canonical_fixture,
    )
    as "The foreign epoch is well-formed but not the opened journal's authority."
  assert host.configure(
      host.Provisioning(..fixture.provision, registration: other),
    )
    == Error(host.InvalidConfiguration)
  assert host.configure(host.Provisioning(..fixture.provision, drain_ms: 0))
    == Error(host.InvalidConfiguration)
  assert host.configure(
      host.Provisioning(..fixture.provision, drain_ms: 30_001),
    )
    == Error(host.InvalidConfiguration)
  assert journal.scope(fixture.book) == scope(1)
  assert local.close(fixture.native, draining: 2000, helpers: 5000) == Ok(Nil)
  assert journal.release(fixture.book) == Ok(Nil)
}

/// The removed occupied-port trigger maps to an unavailable shared endpoint.
/// Prepublication refusal preserves the caller's original open authority epoch.
///
/// ## Examples
///
/// ```gleam
/// occupied_port_preserves_caller_custody_test()
/// ```
pub fn occupied_port_preserves_caller_custody_test() {
  use context <- beam_fixture.run("occupied_port_preserves_caller_custody_test")
  let fixture = fixture(context, "startup", ReturnWitness)
  let monitor = process.monitor(endpoint.pid(context.endpoint))
  endpoint.stop(context.endpoint)
  down(monitor, 2000)
  let assert Ok(config) = host.configure(fixture.provision)
    as "The unavailable shared endpoint does not invalidate original immutable scope."
  assert host.start(config) == Error(host.StartupFailed)
  let assert Ok(available) = journal.admit(fixture.book, key(1), digest())
    as "A pre-listen failure leaves caller-owned epoch open, not rolled back or closed."
  assert admission.phase(available.evidence) == admission.Admitted
  assert local.close(fixture.native, draining: 2000, helpers: 5000) == Ok(Nil)
  assert journal.release(fixture.book) == Ok(Nil)
}

/// Real output and retirement precede owned actor exit and journal release.
///
/// ## Examples
///
/// ```gleam
/// successful_close_witnesses_native_and_stops_owned_actors_test()
/// ```
pub fn successful_close_witnesses_native_and_stops_owned_actors_test() {
  use context <- beam_fixture.run(
    "successful_close_witnesses_native_and_stops_owned_actors_test",
  )
  let fixture = fixture(context, "close", ReturnWitness)
  let #(running, view, connection) = running(fixture)
  let request = prepared(fixture, "printf x >> proof; printf host-output")
  let digest = launch(connection, request)
  let bytes = terminal(connection, digest)
  let assert Ok(dispatch.Completed(result)) = native.decode_terminal(bytes)
    as "The fixture uses the real helper's terminal, never a supplied success."
  assert result.code == 0
  assert simplifile.read(fixture.path <> "/proof") == Ok("x")
  assert host.close(running) == Ok(Nil)
  assert process.receive(fixture.witnessed, 1000) == Ok(Ok(Nil))
  assert !process.is_alive(host.pid(running))
  assert !process.is_alive(view.service)
  assert process.is_alive(view.endpoint)
  assert !process.is_alive(local.pid(fixture.native))

  // Release acknowledges the closed database before its actor exits. A read
  // during that exit can observe the monitor instead of the initial liveness
  // check. Both outcomes refuse access; the native retirement witnesses above
  // establish cleanup independently of this scheduling order.
  let readback = journal.payloads(fixture.book, key(1), digest)
  assert readback == Error(journal.Closed)
    || readback == Error(journal.Uncertain)
  assert beam_fixture.exchange(connection, wire.Hello)
    == Error(endpoint.Uncertain)
  assert host.observe(running) == Error(host.Unavailable)
}

/// Registration verification cannot be replaced by a permissive supplied callback.
///
/// ## Examples
///
/// ```gleam
/// host_fixes_registration_verifier_test()
/// ```
pub fn host_fixes_registration_verifier_test() {
  use context <- beam_fixture.run("host_fixes_registration_verifier_test")
  let fixture = fixture(context, "verify", ReturnWitness)
  let #(running, _, connection) = running(fixture)
  let original = prepared(fixture, "printf bad >> proof")
  let request = wire.Prepared(..original, registration: digest())
  let assert Ok(content) = wire.prepared_digest(request)
    as "Wrong registration still has a valid canonical request digest."
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    beam_fixture.exchange(connection, wire.ChallengeRequest(key(1), content))
    as "The challenge grants no policy authority."
  assert beam_fixture.exchange(
      connection,
      wire.Submit(key(1), content, request, nonce, 5000),
    )
    == Ok(wire.Rejected(1))
  assert simplifile.is_file(fixture.path <> "/proof") == Ok(False)
  assert journal.payloads(fixture.book, key(1), content) == Ok([])
  assert host.close(running) == Ok(Nil)
}

/// A failed admission child fails the host and retains original journal evidence.
///
/// ## Examples
///
/// ```gleam
/// service_crash_fails_host_without_restarting_custody_test()
/// ```
pub fn service_crash_fails_host_without_restarting_custody_test() {
  use context <- beam_fixture.run(
    "service_crash_fails_host_without_restarting_custody_test",
  )
  process.trap_exits(True)
  let fixture = fixture(context, "service-crash", ReturnWitness)
  let #(running, view, connection) = running(fixture)
  let request = prepared(fixture, "printf x >> proof")
  let digest = launch(connection, request)
  let _ = terminal(connection, digest)
  let monitor = process.monitor(host.pid(running))
  process.kill(view.service)
  down(monitor, 12_000)
  assert host.observe(running) == Error(host.Unavailable)
  assert !process.is_alive(view.service)
  assert process.is_alive(view.endpoint)
  assert beam_fixture.exchange(connection, wire.Hello)
    == Error(endpoint.Uncertain)
  let assert Ok(evidence) = journal.inspect(fixture.book, key(1), digest)
    as "Host failure retains original evidence instead of releasing or recreating custody."
  let assert admission.Terminal(_, admission.NativeUnconfirmed, _) =
    admission.phase(evidence)
    as "A dead service cannot reconstruct its native retirement inventory."
  assert journal.payloads(fixture.book, key(1), digest) != Ok([])
  assert simplifile.read(fixture.path <> "/proof") == Ok("x")
  assert process.receive(fixture.witnessed, 100) == Error(Nil)

  // A dead service cannot supply its original close disposition. The fixture
  // caller drains actual original custody solely for test teardown.
  assert local.close(fixture.native, draining: 2000, helpers: 5000) == Ok(Nil)
  assert process.receive(fixture.witnessed, 1000) == Ok(Ok(Nil))
  assert journal.release(fixture.book) == Ok(Nil)
}

/// The removed acceptor-subtree failure maps to actual shared endpoint death.
/// The scope attempts native cleanup, retains its journal and does not restart.
///
/// ## Examples
///
/// ```gleam
/// acceptor_subtree_crash_fails_and_drains_host_test()
/// ```
pub fn acceptor_subtree_crash_fails_and_drains_host_test() {
  use context <- beam_fixture.run(
    "acceptor_subtree_crash_fails_and_drains_host_test",
  )
  process.trap_exits(True)
  let fixture = fixture(context, "acceptor-crash", ReturnWitness)
  let #(running, view, connection) = running(fixture)
  let monitor = process.monitor(host.pid(running))
  process.kill(view.endpoint)
  down(monitor, 12_000)
  assert host.observe(running) == Error(host.Unavailable)
  assert !process.is_alive(view.service)
  assert !process.is_alive(view.endpoint)
  assert beam_fixture.exchange(connection, wire.Hello)
    == Error(endpoint.Uncertain)
  assert process.receive(fixture.witnessed, 1000) == Ok(Ok(Nil))
  assert journal.admit(fixture.book, key(1), digest())
    == Error(journal.Rejected(admission.EpochClosed))
  assert journal.release(fixture.book) == Ok(Nil)
}

/// Lost native retirement acknowledgement fences the host but preserves payloads.
///
/// ## Examples
///
/// ```gleam
/// uncertain_cleanup_keeps_original_custody_test()
/// ```
pub fn uncertain_cleanup_keeps_original_custody_test() {
  use context <- beam_fixture.run(
    "uncertain_cleanup_keeps_original_custody_test",
  )
  process.trap_exits(True)
  let fixture = fixture(context, "uncertain", LoseWitness)
  let #(running, view, connection) = running(fixture)
  let digest =
    launch(connection, prepared(fixture, "printf x >> proof; printf retained"))
  let _ = terminal(connection, digest)
  assert host.close(running) == Error(host.CleanupUncertain)
  assert host.observe(running) == Error(host.CleanupUncertain)
  assert process.receive(fixture.witnessed, 1000) == Ok(Ok(Nil))
  assert process.is_alive(view.endpoint)
  assert process.is_alive(view.service)
  assert beam_fixture.exchange(connection, wire.Hello)
    == Error(endpoint.Uncertain)
  let assert Ok(evidence) = journal.inspect(fixture.book, key(1), digest)
    as "The original journal stays available after the lost native drain reply."
  let assert admission.Terminal(_, admission.NativeUnconfirmed, _) =
    admission.phase(evidence)
    as "A lost witness cannot be upgraded using a fenced row or stopped worker."
  let assert Ok(items) = journal.payloads(fixture.book, key(1), digest)
    as "Exact bytes are retained, not replaced by an uncertain status row."
  assert list.any(items, fn(item) {
    case item {
      payload.Request(_) -> True
      _ -> False
    }
  })
  assert host.close(running) == Error(host.CleanupUncertain)
  assert simplifile.read(fixture.path <> "/proof") == Ok("x")
  let monitor = process.monitor(host.pid(running))
  let service_monitor = process.monitor(view.service)
  process.send_abnormal_exit(host.pid(running), Shutdown)
  down(monitor, 12_000)

  // The parent's DOWN does not order a linked child's exit at this observer.
  // Require the child's own witness before asserting that its custody ended.
  down(service_monitor, 12_000)
  assert !process.is_alive(view.service)
  assert journal.payloads(fixture.book, key(1), digest) == Ok(items)
  assert journal.release(fixture.book) == Ok(Nil)

  // The fixture recorded the actual successful native pool witness before
  // dropping its reply. This final test cleanup cannot be used by the host.
  process.unlink(local.pid(fixture.native))
  process.kill(local.pid(fixture.native))
}

/// Durable closure failure stays uncertain even after a real native pool witness.
///
/// ## Examples
///
/// ```gleam
/// journal_failure_never_turns_native_drain_into_durable_host_success_test()
/// ```
pub fn journal_failure_never_turns_native_drain_into_durable_host_success_test() {
  use context <- beam_fixture.run(
    "journal_failure_never_turns_native_drain_into_durable_host_success_test",
  )
  process.trap_exits(True)
  let fixture = fixture(context, "journal-failure", ReturnWitness)
  let #(running, view, connection) = running(fixture)
  let digest = launch(connection, prepared(fixture, "printf x >> proof"))
  let _ = terminal(connection, digest)
  let assert Ok(original) = journal.payloads(fixture.book, key(1), digest)
    as "Original request and terminal commit before durability is removed."
  assert journal.release(fixture.book) == Ok(Nil)
  assert host.close(running) == Error(host.CleanupUncertain)
  assert host.observe(running) == Error(host.CleanupUncertain)
  assert process.receive(fixture.witnessed, 1000) == Ok(Ok(Nil))
  assert !process.is_alive(local.pid(fixture.native))
  assert process.is_alive(view.endpoint)
  let assert Ok(capacity) = admission.capacity(8)
    as "Recovery uses the original capacity."
  let assert Ok(recovered) =
    journal.recover(fixture.path <> "/custody.sqlite", scope(1), capacity)
    as "Failure preserves the original database rather than deleting its evidence."
  assert journal.payloads(recovered, key(1), digest) == Ok(original)
  let assert Ok(evidence) = journal.inspect(recovered, key(1), digest)
    as "Actual OS retirement cannot forge the failed durable transition."
  let assert admission.Terminal(_, admission.NativeUnconfirmed, _) =
    admission.phase(evidence)
    as "The stored native fact stays unconfirmed without its journal commit."
  let monitor = process.monitor(host.pid(running))
  let service_monitor = process.monitor(view.service)
  process.send_abnormal_exit(host.pid(running), Shutdown)
  down(monitor, 12_000)

  // A parent exit does not order the linked service's exit at this observer.
  // Keep the durability assertion after the service's own termination witness.
  down(service_monitor, 12_000)
  assert !process.is_alive(view.service)
  assert journal.payloads(recovered, key(1), digest) == Ok(original)
  assert journal.release(recovered) == Ok(Nil)
}

/// Local quiescence denies native admissions without treating scope loss as result.
///
/// ## Examples
///
/// ```gleam
/// quiescence_refuses_new_authority_before_epoch_drain_test()
/// ```
pub fn quiescence_refuses_new_authority_before_epoch_drain_test() {
  use context <- beam_fixture.run(
    "quiescence_refuses_new_authority_before_epoch_drain_test",
  )
  let fixture = fixture(context, "quiesce", ReturnWitness)
  let assert Ok(remote) = service.start(fixture.provision.service)
    as "The legacy unlinked API stays usable independently of host assembly."
  assert service.quiesce(remote) == Ok(Nil)
  let request = prepared(fixture, "printf bad >> proof")
  let assert Ok(content) = wire.prepared_digest(request)
    as "Prepared remains exact."
  let envelope =
    wire.Envelope(wire.Owner, "owner", "linux", 1, scope(1), wire.Hello)
  assert service.exchange(
      remote,
      wire.Envelope(..envelope, body: wire.ChallengeRequest(key(1), content)),
    )
    == Error(service.Invalid)
  assert service.exchange(
      remote,
      wire.Envelope(
        ..envelope,
        body: wire.Submit(key(1), content, request, <<0:size(256)>>, 5000),
      ),
    )
    == Error(service.Invalid)
  assert journal.payloads(fixture.book, key(1), content) == Ok([])
  assert simplifile.is_file(fixture.path <> "/proof") == Ok(False)
  assert service.shutdown(remote) == Ok(Nil)
  let monitor = process.monitor(service.pid(remote))
  down(monitor, 2000)
  assert journal.release(fixture.book) == Ok(Nil)
}

// OTP suspension is a fixed test fault on the actual concrete actor. It neither
// replaces its service door nor manufactures a native answer or drain proof.
@external(erlang, "executor_scoped_host_test_ffi", "suspend")
fn suspend(pid: process.Pid) -> Result(Nil, Nil)

@external(erlang, "executor_scoped_host_test_ffi", "resume")
fn resume(pid: process.Pid) -> Result(Nil, Nil)

/// Prior actual wire close is consumed once by later host retirement.
///
/// ## Examples
/// `wire_close_then_host_close_preserves_original_native_witness_test()`.
pub fn wire_close_then_host_close_preserves_original_native_witness_test() {
  use context <- beam_fixture.run(
    "wire_close_then_host_close_preserves_original_native_witness_test",
  )
  let fixture = fixture(context, "wire-close", ReturnWitness)
  let #(running, view, client) = running(fixture)
  let digest = launch(client, prepared(fixture, "printf x >> proof"))
  let _ = terminal(client, digest)
  let assert Ok(wire.ScopeRetirement) =
    beam_fixture.exchange(client, wire.CloseScope)
    as "The real original pool and exact durable covered set retired."
  assert process.receive(fixture.witnessed, 1000) == Ok(Ok(Nil))
  assert host.close(running) == Ok(Nil)
  assert process.receive(fixture.witnessed, 100) == Error(Nil)
  assert !process.is_alive(view.service)
  assert process.is_alive(view.endpoint)
  assert simplifile.read(fixture.path <> "/proof") == Ok("x")
}

/// Scope A cleanup preserves B's distinct real pool and usable shared endpoint.
///
/// ## Examples
/// `sibling_scope_remains_usable_after_successful_close_test()`.
pub fn sibling_scope_remains_usable_after_successful_close_test() {
  use context <- beam_fixture.run(
    "sibling_scope_remains_usable_after_successful_close_test",
  )
  let a = fixture(context, "sibling-a", ReturnWitness)
  let b = fixture_scope(context, "sibling-b", ReturnWitness, scope(2))
  let #(owner_a, _, client_a) = running(a)
  let #(owner_b, view_b, client_b) = running(b)
  let digest_a = launch(client_a, prepared(a, "printf a >> proof"))
  let _ = terminal(client_a, digest_a)
  assert host.close(owner_a) == Ok(Nil)
  assert process.receive(a.witnessed, 1000) == Ok(Ok(Nil))
  assert process.is_alive(local.pid(b.native))
  assert beam_fixture.exchange(client_a, wire.Hello)
    == Error(endpoint.Uncertain)
  let original_b = key_in(scope(2), 2)
  let digest_b =
    launch_in(client_b, prepared(b, "printf b >> proof"), original_b)
  let _ = terminal_in(client_b, digest_b, original_b)
  assert simplifile.read(b.path <> "/proof") == Ok("b")
  assert endpoint.inspect(context.endpoint) == Ok(endpoint.Capacity(2, 4, 2))
  assert process.is_alive(view_b.endpoint)
  assert host.close(owner_b) == Ok(Nil)
  assert process.receive(b.witnessed, 1000) == Ok(Ok(Nil))
}

/// Transport expiry still attempts actual native cleanup and retains the journal.
///
/// ## Examples
/// `busy_close_expiry_reserves_native_cleanup_and_preserves_sibling_test()`.
pub fn busy_close_expiry_reserves_native_cleanup_and_preserves_sibling_test() {
  use context <- beam_fixture.run(
    "busy_close_expiry_reserves_native_cleanup_and_preserves_sibling_test",
  )
  let original_a = fixture(context, "busy-a", ReturnWitness)
  let a =
    Fixture(
      ..original_a,
      provision: host.Provisioning(..original_a.provision, drain_ms: 100),
    )
  let b = fixture_scope(context, "busy-b", ReturnWitness, scope(2))
  let #(owner_a, view_a, client_a) = running(a)
  let #(owner_b, _, client_b) = running(b)
  let digest_a = launch(client_a, prepared(a, "printf a >> proof"))
  let _ = terminal(client_a, digest_a)
  assert suspend(view_a.service) == Ok(Nil)
  let recovery = delayed_resume(view_a.service, 3500)
  assert beam_fixture.exchange(client_a, wire.Hello)
    == Error(endpoint.Uncertain)
  let assert Ok(capacity) = endpoint.inspect(context.endpoint)
    as "The original unanswered service ask still owns its transport credit."
  assert capacity.data + capacity.control < 6
  assert host.close(owner_a) == Error(host.CleanupUncertain)
  assert host.observe(owner_a) == Error(host.CleanupUncertain)
  resumed(recovery)
  assert process.receive(a.witnessed, 1000) == Ok(Ok(Nil))
  assert !process.is_alive(local.pid(a.native))
  assert journal.payloads(a.book, key(1), digest_a) != Ok([])
  let original_b = key_in(scope(2), 2)
  let digest_b =
    launch_in(client_b, prepared(b, "printf b >> proof"), original_b)
  let _ = terminal_in(client_b, digest_b, original_b)
  assert simplifile.read(b.path <> "/proof") == Ok("b")
  assert host.close(owner_b) == Ok(Nil)
  assert journal.release(a.book) == Ok(Nil)
  let monitor = process.monitor(host.pid(owner_a))
  process.send_abnormal_exit(host.pid(owner_a), Shutdown)
  down(monitor, 12_000)
}

/// Lost Register acknowledgement follows publication, then exact same-owner fence.
///
/// ## Examples
/// `lost_register_ack_fences_published_original_before_cleanup_test()`.
pub fn lost_register_ack_fences_published_original_before_cleanup_test() {
  use context <- beam_fixture.run(
    "lost_register_ack_fences_published_original_before_cleanup_test",
  )
  process.trap_exits(True)
  let fixture = fixture(context, "lost-register", ReturnWitness)
  assert suspend(endpoint.pid(context.endpoint)) == Ok(Nil)
  let recovery = delayed_resume(endpoint.pid(context.endpoint), 1500)
  let assert Ok(config) = host.configure(fixture.provision)
    as "Original scope is valid."
  assert host.start(config) == Error(host.StartupFailed)
  resumed(recovery)
  assert endpoint.inspect(context.endpoint) == Ok(endpoint.Capacity(1, 4, 2))
  assert beam_fixture.exchange(
      beam_fixture.client(context, scope(1)),
      wire.Hello,
    )
    == Error(endpoint.Uncertain)
  assert process.receive(fixture.witnessed, 1000) == Ok(Ok(Nil))
  assert process.receive(fixture.witnessed, 100) == Error(Nil)
  assert journal.admit(fixture.book, key(1), digest())
    == Error(journal.Rejected(admission.EpochClosed))
  assert journal.release(fixture.book) == Ok(Nil)
}

/// Brutal owner death applies the endpoint fence without inventing native proof.
///
/// ## Examples
/// `owner_death_fences_without_recreating_native_retirement_test()`.
pub fn owner_death_fences_without_recreating_native_retirement_test() {
  use context <- beam_fixture.run(
    "owner_death_fences_without_recreating_native_retirement_test",
  )
  process.trap_exits(True)
  let fixture = fixture(context, "owner-death", ReturnWitness)
  let #(running, view, client) = running(fixture)
  let digest = launch(client, prepared(fixture, "printf x >> proof"))
  let _ = terminal(client, digest)
  let owner_down = process.monitor(host.pid(running))
  let service_down = process.monitor(view.service)
  process.kill(host.pid(running))
  down(owner_down, 2000)
  down(service_down, 2000)
  assert process.is_alive(view.endpoint)
  let assert poll.Answered(Nil) =
    poll.until(2000, 10, fn() {
      case beam_fixture.exchange(client, wire.Hello) {
        Error(endpoint.Uncertain) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "Only the applied fence refuses late exact owner requests."
  assert endpoint.inspect(context.endpoint) == Ok(endpoint.Capacity(1, 4, 2))
  assert journal.payloads(fixture.book, key(1), digest) != Ok([])
  assert process.receive(fixture.witnessed, 100) == Error(Nil)

  // Test teardown obtains its own actual native witness; owner death did not.
  assert local.close(fixture.native, draining: 2000, helpers: 5000) == Ok(Nil)
  assert journal.release(fixture.book) == Ok(Nil)
}

/// Exact duplicate scope publication cannot fence or replace the original row.
///
/// ## Examples
/// `duplicate_scope_preserves_original_binding_and_native_custody_test()`.
pub fn duplicate_scope_preserves_original_binding_and_native_custody_test() {
  use context <- beam_fixture.run(
    "duplicate_scope_preserves_original_binding_and_native_custody_test",
  )
  process.trap_exits(True)
  let original = fixture(context, "original-row", ReturnWitness)
  let rejected = fixture(context, "duplicate-row", ReturnWitness)
  let #(running, _, client) = running(original)
  let assert Ok(config) = host.configure(rejected.provision)
    as "Original facts are valid before duplicate publication refusal."
  assert host.start(config) == Error(host.StartupFailed)
  assert process.receive(rejected.witnessed, 1000) == Ok(Ok(Nil))
  assert journal.admit(rejected.book, key(1), digest())
    == Error(journal.Rejected(admission.EpochClosed))
  let digest = launch(client, prepared(original, "printf x >> proof"))
  let _ = terminal(client, digest)
  assert simplifile.read(original.path <> "/proof") == Ok("x")
  assert endpoint.inspect(context.endpoint) == Ok(endpoint.Capacity(1, 4, 2))
  assert host.close(running) == Ok(Nil)
  assert journal.release(rejected.book) == Ok(Nil)
}

/// Sixteen lifetime rows survive scope close; a seventeenth cannot remint a slot.
///
/// ## Examples
/// `full_lifetime_table_refuses_publication_and_preserves_original_evidence_test()`.
pub fn full_lifetime_table_refuses_publication_and_preserves_original_evidence_test() {
  use context <- beam_fixture.run(
    "full_lifetime_table_refuses_publication_and_preserves_original_evidence_test",
  )
  process.trap_exits(True)
  let owners =
    list.map([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16], fn(epoch) {
      let original =
        fixture_scope(
          context,
          "table-" <> int.to_string(epoch),
          ReturnWitness,
          scope(epoch),
        )
      let #(running, _, _) = running(original)
      #(running, original)
    })
  assert endpoint.inspect(context.endpoint) == Ok(endpoint.Capacity(16, 4, 2))
  let rejected =
    fixture_scope(context, "table-refused", ReturnWitness, scope(17))
  let assert Ok(config) = host.configure(rejected.provision)
    as "The seventeenth original scope is otherwise valid."
  assert host.start(config) == Error(host.StartupFailed)
  assert process.receive(rejected.witnessed, 1000) == Ok(Ok(Nil))
  assert journal.scope(rejected.book) == scope(17)
  assert journal.admit(rejected.book, key_in(scope(17), 1), digest())
    == Error(journal.Rejected(admission.EpochClosed))
  list.each(owners, fn(owner) {
    assert host.close(owner.0) == Ok(Nil)
    assert process.receive(owner.1.witnessed, 1000) == Ok(Ok(Nil))
  })
  assert endpoint.inspect(context.endpoint) == Ok(endpoint.Capacity(16, 4, 2))
  assert journal.release(rejected.book) == Ok(Nil)
}

/// Native success survives the later durable confirmation failure without reclose.
///
/// ## Examples
/// `post_native_confirmation_failure_retains_witness_and_original_bytes_test()`.
pub fn post_native_confirmation_failure_retains_witness_and_original_bytes_test() {
  use context <- beam_fixture.run(
    "post_native_confirmation_failure_retains_witness_and_original_bytes_test",
  )
  process.trap_exits(True)
  let fixture = fixture(context, "post-native-confirmation", BreakConfirmation)
  let #(running, view, client) = running(fixture)
  let digest = launch(client, prepared(fixture, "printf x >> proof"))
  let _ = terminal(client, digest)
  let assert Ok(original) = journal.payloads(fixture.book, key(1), digest)
    as "Actual original request and terminal commit first."
  assert host.close(running) == Error(host.CleanupUncertain)
  assert process.receive(fixture.witnessed, 1000) == Ok(Ok(Nil))
  assert !process.is_alive(local.pid(fixture.native))
  assert host.close(running) == Error(host.CleanupUncertain)
  assert process.receive(fixture.witnessed, 100) == Error(Nil)
  let assert Ok(capacity) = admission.capacity(8) as "Original recovery bound."
  let assert Ok(recovered) =
    journal.recover(fixture.path <> "/custody.sqlite", scope(1), capacity)
    as "The same database retains exact original bytes after failed confirmation."
  assert journal.payloads(recovered, key(1), digest) == Ok(original)
  let assert Ok(evidence) = journal.inspect(recovered, key(1), digest)
    as "Read actual committed evidence."
  let assert admission.Terminal(_, admission.NativeUnconfirmed, _) =
    admission.phase(evidence)
    as "Physical success cannot replace failed durable confirmation."
  let monitor = process.monitor(host.pid(running))
  let service_monitor = process.monitor(view.service)
  process.send_abnormal_exit(host.pid(running), Shutdown)
  down(monitor, 12_000)
  down(service_monitor, 12_000)
  assert process.receive(fixture.witnessed, 100) == Error(Nil)
  assert journal.payloads(recovered, key(1), digest) == Ok(original)
  assert journal.release(recovered) == Ok(Nil)
}

fn delayed_resume(
  pid: process.Pid,
  after_ms: Int,
) -> #(process.Pid, process.Subject(weft.Pulled(Nil, Nil))) {
  let sink = process.new_subject()
  let relay =
    weft.new_prepared([
      weft.managed(fn(_) {
        process.sleep(after_ms)
        resume(pid)
      }),
    ])
    |> weft.deadline(after_ms + 2000)
    |> weft.start_relayed(sink)
  #(relay, sink)
}

fn resumed(
  recovery: #(process.Pid, process.Subject(weft.Pulled(Nil, Nil))),
) -> Nil {
  assert process.receive(recovery.1, 5000)
    == Ok(weft.PulledOutcome(weft.Completed(0, Nil)))
  assert process.receive(recovery.1, 5000) == Ok(weft.AllDelivered)
  down(process.monitor(recovery.0), 2000)
}

fn fixture(
  context: beam_fixture.Context,
  name: String,
  reply: DrainReply,
) -> Fixture {
  fixture_scope(context, name, reply, scope(1))
}

fn fixture_scope(
  context: beam_fixture.Context,
  name: String,
  reply: DrainReply,
  authority: identity.Scope,
) -> Fixture {
  let assert Ok(here) = simplifile.current_directory()
    as "The package test runner starts at the real executor checkout."
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    here
    <> "/build/remote-host/"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(Nil) = simplifile.create_directory_all(path <> "/scratch/tmp")
    as "Each fixture owns its independent actual helper workspace."
  let helper = here <> "/../sandbox/loom-exec"
  assert simplifile.is_file(helper) == Ok(True)
  let base = executor.base_policy(path)
  let spawn =
    exec.SpawnConfig(
      helper,
      "/bin/sh",
      base,
      [],
      path <> "/scratch/tmp",
      3000,
      3000,
      0,
    )
  let assert Ok(pool) = exec.start_pool(1, fn() { exec.prepare_helper(spawn) })
    as "The fixture uses actual helper processes and pool retirement."
  let assert Ok(capacity) = admission.capacity(8)
    as "Lifetime custody is bounded."
  let assert Ok(book) =
    journal.fresh(path <> "/custody.sqlite", authority, capacity)
    as "The host accepts real preopened WAL/FULL custody."
  let witnessed = process.new_subject()
  let assert Ok(native) =
    local.start(local.ExecutorConfig(
      checkout: fn() { exec.checkout(pool, waiting: 3000) },
      checkin: fn(helper) { exec.checkin(pool, helper) },
      custody: fn() { exec.pool_custody(pool, waiting: 1000) },
      close_helpers: fn(ms) {
        let actual = exec.close_pool(pool, waiting: ms)
        process.send(witnessed, actual)
        case reply {
          ReturnWitness -> actual
          LoseWitness -> Error(exec.RetirementPending)
          BreakConfirmation -> {
            // The real pool result precedes loss of the original journal owner.
            // Confirmation failure cannot erase the service's retained native fact.
            assert journal.release(book) == Ok(Nil)
            actual
          }
        }
      },
      incarnation: 17,
      log: log.discard(),
    ))
    as "Loss injection changes only the reply after actual helper pool drain."
  let assert Ok(registered) =
    registration.new(
      authority,
      [path],
      base,
      exec.PlatformEnforcement,
      canonical_fixture,
    )
    as "Fixture administration registers known canonical existing roots."
  let provision =
    host.Provisioning(
      service.Config(
        "owner",
        "linux",
        authority,
        1,
        book,
        native,
        fn(_, _) { Ok(Nil) },
        poll.monotonic().now,
      ),
      registered,
      context.endpoint,
      context.owner,
      1000,
    )
  Fixture(path, pool, native, book, registered, provision, context, witnessed)
}

fn running(fixture: Fixture) -> #(host.Host, host.View, beam_fixture.Client) {
  let assert Ok(config) = host.configure(fixture.provision)
    as "The real immutable host config validates before scoped publication."
  let assert Ok(running) = host.start(config)
    as "Real TLS and owned children must start."
  let assert Ok(view) = host.observe(running)
    as "Only the live owner publishes topology."
  #(
    running,
    view,
    beam_fixture.client(fixture.context, fixture.provision.service.scope),
  )
}

fn canonical_fixture(path: String) -> Result(String, Nil) {
  // These isolated fixtures register only their own newly created root and '/'.
  // The callback checks existence; production assembly supplies OS realpath.
  use Nil <- result.try(
    simplifile.is_directory(path)
    |> result.replace_error(Nil)
    |> result.try(fn(exists) {
      case exists {
        True -> Ok(Nil)
        False -> Error(Nil)
      }
    }),
  )
  Ok(path)
}

fn prepared(fixture: Fixture, shell: String) -> wire.Prepared {
  let base = executor.base_policy(fixture.path)
  let bounded =
    policy.SandboxPolicy(
      ..base,
      limits: policy.Limits(..base.limits, wall_s: 2, output_bytes: 131_072),
    )
  wire.Prepared(
    "exec",
    registration.digest(fixture.registration),
    wire.Finite(10_000),
    exec.ExecRequest(
      ["/bin/sh", "-c", shell],
      [],
      fixture.path,
      Some(bounded),
      <<7:size(256)>>,
      exec.PlatformEnforcement,
    ),
    wire.Logs,
  )
}

fn launch(
  connection: beam_fixture.Client,
  request: wire.Prepared,
) -> identity.Digest {
  launch_in(connection, request, key(1))
}

fn launch_in(
  connection: beam_fixture.Client,
  request: wire.Prepared,
  original: identity.RequestKey,
) -> identity.Digest {
  let assert Ok(digest) = wire.prepared_digest(request)
    as "Digest binds exact prepared authority."
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    beam_fixture.exchange(connection, wire.ChallengeRequest(original, digest))
    as "The real service issues bounded authority."
  let assert Ok(wire.Evidence(_, _, 2, _)) =
    beam_fixture.exchange(
      connection,
      wire.Submit(original, digest, request, nonce, 5000),
    )
    as "The real helper launches only live intent."
  digest
}

fn terminal(
  connection: beam_fixture.Client,
  digest: identity.Digest,
) -> BitArray {
  terminal_in(connection, digest, key(1))
}

fn terminal_in(
  connection: beam_fixture.Client,
  digest: identity.Digest,
  original: identity.RequestKey,
) -> BitArray {
  let outcome =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case beam_fixture.exchange(connection, wire.Query(original, digest, 64)) {
        Ok(wire.Terminal(_, _, bytes)) -> poll.Done(bytes)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
  let assert poll.Answered(bytes) = outcome
    as "Actual native completion is required, never skipped."
  bytes
}

fn down(monitor: process.Monitor, timeout: Int) {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(timeout)
    as "The owned actor must actually terminate within the deadline."
  process.demonitor_process(monitor)
}

fn scope(number: Int) -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Fixture session is UUIDv7."
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "Workspace is provisioned."
  let assert Ok(executor) = identity.executor_id("linux")
    as "Executor is provisioned."
  let assert Ok(epoch) = identity.epoch(number) as "Epoch is positive."
  identity.scope(session, workspace, executor, epoch, epoch)
}

fn key(number: Int) -> identity.RequestKey {
  key_in(scope(1), number)
}

fn key_in(authority: identity.Scope, number: Int) -> identity.RequestKey {
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "The physical operation is original."
  let assert Ok(request) =
    identity.request_id(
      "00000000-0000-7000-8000-00000000000" <> int.to_string(number),
    )
    as "The request UUID is exact."
  identity.request_key(authority, operation, request)
}

fn digest() -> identity.Digest {
  let assert Ok(digest) = identity.digest(<<1:size(256)>>)
    as "Digest has exact width."
  digest
}

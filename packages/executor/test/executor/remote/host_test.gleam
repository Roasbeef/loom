//// The typed host owns real TLS/admission lifetimes over a real native helper.
//// Per-fixture credentials, paths and ports permit independent test processes.
//// Failure tests trap only their own exit signals, never VM-wide mutable state.
//// No missing prerequisite or uncertain native cleanup is a passing skip.

import broker/dispatch
import broker/exec
import broker/executor as local
import broker/policy
import core/ids
import executor
import executor/remote/admission
import executor/remote/connection
import executor/remote/host
import executor/remote/identity
import executor/remote/journal
import executor/remote/native
import executor/remote/payload
import executor/remote/registration
import executor/remote/service
import executor/remote/tls
import executor/remote/wire
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/time/timestamp
import remote_tls_test
import simplifile
import telemetry/log
import weft/poll

@external(erlang, "executor_remote_tls_test_ffi", "fixture")
fn certificates() -> remote_tls_test.Fixture

type DrainReply {
  ReturnWitness
  LoseWitness
}

type Fixture {
  Fixture(
    path: String,
    pool: exec.Pool,
    native: local.Executor,
    book: journal.Journal,
    registration: registration.Registration,
    provision: host.Provisioning,
    client_tls: tls.Settings,
    witnessed: process.Subject(Result(Nil, exec.RetirementFailure)),
  )
}

type Shutdown {
  Shutdown
}

/// Mismatched bindings are refused before any listening host exists.
///
/// ## Examples
///
/// ```gleam
/// bindings_refuse_before_listen_test()
/// ```
pub fn bindings_refuse_before_listen_test() {
  let fixture = fixture("bindings", ReturnWitness)
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
  assert host.configure(host.Provisioning(..fixture.provision, workers: 0))
    == Error(host.InvalidConfiguration)
  assert host.configure(host.Provisioning(..fixture.provision, exchange_ms: 0))
    == Error(host.InvalidConfiguration)
  assert journal.scope(fixture.book) == scope(1)
  assert local.close(fixture.native, draining: 2000, helpers: 5000) == Ok(Nil)
  assert journal.release(fixture.book) == Ok(Nil)
}

/// Occupied-port refusal does not close the caller's original authority epoch.
///
/// ## Examples
///
/// ```gleam
/// occupied_port_preserves_caller_custody_test()
/// ```
pub fn occupied_port_preserves_caller_custody_test() {
  let fixture = fixture("startup", ReturnWitness)
  assert tls.start() == Ok(Nil)
  let assert Ok(occupied) = tls.listen(fixture.provision.tls, tls.Loopback, 0)
    as "The real occupied socket belongs to this fixture."
  let assert Ok(port) = tls.port(occupied)
    as "The actual port is administrative input."
  let assert Ok(config) =
    host.configure(host.Provisioning(..fixture.provision, port:))
    as "Binding and capacities are valid before the OS refuses this port."
  assert host.start(config) == Error(host.StartupFailed)
  let assert Ok(available) = journal.admit(fixture.book, key(1), digest())
    as "A pre-listen failure leaves caller-owned epoch open, not rolled back or closed."
  assert admission.phase(available.evidence) == admission.Admitted
  assert local.close(fixture.native, draining: 2000, helpers: 5000) == Ok(Nil)
  assert journal.release(fixture.book) == Ok(Nil)
  tls.close_listener(occupied)
  let assert Ok(rebound) = tls.listen(fixture.provision.tls, tls.Loopback, port)
    as "Failed host construction did not retain another listener on the port."
  tls.close_listener(rebound)
}

/// Real output and retirement precede owned actor exit and journal release.
///
/// ## Examples
///
/// ```gleam
/// successful_close_witnesses_native_and_stops_owned_actors_test()
/// ```
pub fn successful_close_witnesses_native_and_stops_owned_actors_test() {
  let fixture = fixture("close", ReturnWitness)
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
  assert !process.is_alive(view.acceptors)
  assert !process.is_alive(local.pid(fixture.native))
  assert journal.payloads(fixture.book, key(1), digest) == Error(journal.Closed)
  assert connection.exchange(connection, wire.Hello)
    == Error(connection.Uncertain)
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
  let fixture = fixture("verify", ReturnWitness)
  let #(running, _, connection) = running(fixture)
  let original = prepared(fixture, "printf bad >> proof")
  let request = wire.Prepared(..original, registration: digest())
  let assert Ok(content) = wire.prepared_digest(request)
    as "Wrong registration still has a valid canonical request digest."
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    connection.exchange(connection, wire.ChallengeRequest(key(1), content))
    as "The challenge grants no policy authority."
  assert connection.exchange(
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
  process.trap_exits(True)
  let fixture = fixture("service-crash", ReturnWitness)
  let #(running, view, connection) = running(fixture)
  let request = prepared(fixture, "printf x >> proof")
  let digest = launch(connection, request)
  let _ = terminal(connection, digest)
  let monitor = process.monitor(host.pid(running))
  process.kill(view.service)
  down(monitor, 12_000)
  assert host.observe(running) == Error(host.Unavailable)
  assert !process.is_alive(view.service)
  assert !process.is_alive(view.acceptors)
  assert connection.exchange(connection, wire.Hello)
    == Error(connection.Uncertain)
  let assert Ok(evidence) = journal.inspect(fixture.book, key(1), digest)
    as "Host failure retains original evidence instead of releasing or recreating custody."
  let assert admission.Terminal(_, admission.NativeUnconfirmed, _) =
    admission.phase(evidence)
    as "A dead service cannot reconstruct its native retirement inventory."
  assert journal.payloads(fixture.book, key(1), digest) != Ok([])
  assert simplifile.read(fixture.path <> "/proof") == Ok("x")
  assert process.receive(fixture.witnessed, 1000) == Ok(Ok(Nil))
  assert journal.release(fixture.book) == Ok(Nil)
}

/// Acceptor-subtree failure has host-wide fate, without a new service incarnation.
///
/// ## Examples
///
/// ```gleam
/// acceptor_subtree_crash_fails_and_drains_host_test()
/// ```
pub fn acceptor_subtree_crash_fails_and_drains_host_test() {
  process.trap_exits(True)
  let fixture = fixture("acceptor-crash", ReturnWitness)
  let #(running, view, connection) = running(fixture)
  let monitor = process.monitor(host.pid(running))
  process.kill(view.acceptors)
  down(monitor, 12_000)
  assert host.observe(running) == Error(host.Unavailable)
  assert !process.is_alive(view.service)
  assert !process.is_alive(view.acceptors)
  assert connection.exchange(connection, wire.Hello)
    == Error(connection.Uncertain)
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
  process.trap_exits(True)
  let fixture = fixture("uncertain", LoseWitness)
  let #(running, view, connection) = running(fixture)
  let digest =
    launch(connection, prepared(fixture, "printf x >> proof; printf retained"))
  let _ = terminal(connection, digest)
  assert host.close(running) == Error(host.CleanupUncertain)
  assert host.observe(running) == Error(host.CleanupUncertain)
  assert process.receive(fixture.witnessed, 1000) == Ok(Ok(Nil))
  assert !process.is_alive(view.acceptors)
  assert process.is_alive(view.service)
  assert connection.exchange(connection, wire.Hello)
    == Error(connection.Uncertain)
  let assert Ok(evidence) = journal.inspect(fixture.book, key(1), digest)
    as "The original journal stays available after the lost native drain reply."
  let assert admission.Terminal(_, admission.NativeUnconfirmed, _) =
    admission.phase(evidence)
    as "A lost witness cannot be upgraded using a dead socket or stopped worker."
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
  process.send_abnormal_exit(host.pid(running), Shutdown)
  down(monitor, 12_000)
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
  process.trap_exits(True)
  let fixture = fixture("journal-failure", ReturnWitness)
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
  assert !process.is_alive(view.acceptors)
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
  process.send_abnormal_exit(host.pid(running), Shutdown)
  down(monitor, 12_000)
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
  let fixture = fixture("quiesce", ReturnWitness)
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

fn fixture(name: String, reply: DrainReply) -> Fixture {
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
        }
      },
      incarnation: 17,
      log: log.discard(),
    ))
    as "Loss injection changes only the reply after actual helper pool drain."
  let assert Ok(capacity) = admission.capacity(8)
    as "Lifetime custody is bounded."
  let assert Ok(book) =
    journal.fresh(path <> "/custody.sqlite", scope(1), capacity)
    as "The host accepts real preopened WAL/FULL custody."
  let assert Ok(registered) =
    registration.new(
      scope(1),
      [path],
      base,
      exec.PlatformEnforcement,
      canonical_fixture,
    )
    as "Fixture administration registers known canonical existing roots."
  let assert Ok(Nil) = tls.start() as "SSL startup is explicit."
  let certs = certificates()
  let provision =
    host.Provisioning(
      service.Config(
        "owner",
        "linux",
        scope(1),
        1,
        book,
        native,
        fn(_, _) { Ok(Nil) },
        poll.monotonic().now,
      ),
      registered,
      credentials(certs.server, certs.client),
      tls.Loopback,
      0,
      2,
      3000,
    )
  Fixture(
    path,
    pool,
    native,
    book,
    registered,
    provision,
    credentials(certs.client, certs.server),
    witnessed,
  )
}

fn running(fixture: Fixture) -> #(host.Host, host.View, connection.Config) {
  let assert Ok(config) = host.configure(fixture.provision)
    as "The real immutable host config validates before listener construction."
  let assert Ok(running) = host.start(config)
    as "Real TLS and owned children must start."
  let assert Ok(view) = host.observe(running)
    as "Only the live owner publishes topology."
  #(
    running,
    view,
    connection.Config(
      fixture.client_tls,
      "localhost",
      view.port,
      2500,
      "owner",
      "linux",
      1,
      scope(1),
    ),
  )
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
    as "Both exact leaf pins accompany ephemeral PKIX credentials."
  settings
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
  connection: connection.Config,
  request: wire.Prepared,
) -> identity.Digest {
  let assert Ok(digest) = wire.prepared_digest(request)
    as "Digest binds exact prepared authority."
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    connection.exchange(connection, wire.ChallengeRequest(key(1), digest))
    as "The real service issues bounded authority."
  let assert Ok(wire.Evidence(_, _, 2, _)) =
    connection.exchange(
      connection,
      wire.Submit(key(1), digest, request, nonce, 5000),
    )
    as "The real helper launches only live intent."
  digest
}

fn terminal(
  connection: connection.Config,
  digest: identity.Digest,
) -> BitArray {
  let outcome =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case connection.exchange(connection, wire.Query(key(1), digest, 64)) {
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
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "The physical operation is original."
  let assert Ok(request) =
    identity.request_id(
      "00000000-0000-7000-8000-00000000000" <> int.to_string(number),
    )
    as "The request UUID is exact."
  identity.request_key(scope(1), operation, request)
}

fn digest() -> identity.Digest {
  let assert Ok(digest) = identity.digest(<<1:size(256)>>)
    as "Digest has exact width."
  digest
}

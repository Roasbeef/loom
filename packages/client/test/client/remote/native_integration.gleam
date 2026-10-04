//// Joined owner custody, registered mTLS and native helper component proof.
////
//// `main` runs alone under scripts/e2e_remote_owner.sh. This module exports no
//// EUnit tests, so package parallelism cannot mix this real listener and helper
//// lifecycle with unit fixtures. Ephemeral credentials come from the executor's
//// existing OTP PKIX fixture, compiled into the runner's isolated code path.
////
//// `success` enters the actual broker with the original compile-child identity.
//// It compares both custody stores with the actual observed helper output, then
//// reuses the exact cleared request across TLS generation change and owner
//// custody restart. `refusals` checks administrative digest, policy and scope
//// failures before a physical marker write. The fixture proves these joined
//// components; daemon routing, executor pools, workspace and LSP are separate.

import broker/broker
import broker/budget
import broker/dispatch
import broker/exec
import broker/executor as local
import broker/framing
import broker/policy
import broker/token
import client/remote/custodian
import client/remote/dispatch_binding
import core/clock
import core/ids
import core/remote_tool
import executor
import executor/remote/admission
import executor/remote/connection
import executor/remote/dispatcher
import executor/remote/identity
import executor/remote/journal
import executor/remote/listener
import executor/remote/native
import executor/remote/payload
import executor/remote/registration
import executor/remote/service
import executor/remote/tls
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import simplifile
import storage/owner_custody as custody
import telemetry/log
import weft/poll
import weft/registry

type Credentials {
  Credentials(ca: BitArray, certificate: BitArray, key: BitArray, pin: BitArray)
}

type Certificates {
  Fixture(
    server: Credentials,
    client: Credentials,
    wrong_server: Credentials,
    wrong_client: Credentials,
    foreign: Credentials,
    expired: Credentials,
  )
}

// No credential generation is added to production. The existing executor test
// fixture needs OTP's PKIX generator, which has no Gleam library interface.
@external(erlang, "executor_remote_tls_test_ffi", "fixture")
fn certificates() -> Certificates

type Fixture {
  FixtureState(
    path: String,
    owner: custodian.Handle,
    owner_config: custodian.Config,
    owner_pid: process.Pid,
    book: journal.Journal,
    server: service.Service,
    registered: registration.Registration,
    policy: policy.SandboxPolicy,
    connection: connection.Config,
    listener: tls.Listener,
    acceptors: process.Pid,
    fenced: process.Subject(custody.Error),
  )
}

type ProofMode {
  Baseline
  BypassRegistration
  SkipOwnerReceipt
}

type Shutdown {
  Shutdown
}

type Observation {
  Observation(outputs: List(dispatch.Chunk), terminal: dispatch.Terminal)
}

/// Runs all joined cases in an isolated emulator with hard outer deadlines.
///
/// ## Examples
///
/// ```sh
/// bash scripts/e2e_remote_owner.sh
/// ```
pub fn main() {
  success()
  refusals()
  io.println("remote-owner: joined component proof passed")
}

fn success() {
  let fixture = fixture("success")
  let origin = compile_origin()
  let cleared = process.new_subject()
  let config = binding(fixture, fixture.connection, fixture.registered, cleared)
  let assert Ok(broker) =
    broker.start_dispatching(
      token.production_entropy(),
      clock.from_function(poll.monotonic().now),
      dispatcher.dispatcher(config),
    )
    as "The actual broker owns clearance, token and pooled budget."
  let events = process.new_subject()
  let shell =
    "printf x >> proof; printf owner-stream; printf executor-stderr >&2"
  let spec = call_spec(fixture, shell)
  let assert Ok(_) =
    broker.clear_call_from(broker, origin, spec, events:, waiting: 2000)
    as "The real broker preserves original provenance while clearing authority."
  let assert Ok(#(request, prepared)) = process.receive(cleared, 3000)
    as "Preparation observes the exact broker-cleared physical request."
  assert request.context.origin == Some(origin)
  assert request.context.operation == operation(4)
  assert request.context.step == "physical:compile"
  assert remote_tool.operation(parent()) != request.context.operation
  assert remote_tool.step(parent()) != request.context.step
  let observed = broker_observation(events, [])
  let assert dispatch.Completed(result) = observed.terminal
    as "The real native helper must complete under platform enforcement."
  assert result.code == 0
  assert stream_bytes(observed.outputs, framing.Stdout)
    == <<"owner-stream":utf8>>
  assert stream_bytes(observed.outputs, framing.Stderr)
    == <<"executor-stderr":utf8>>
  assert simplifile.read(fixture.path <> "/proof") == Ok("x")

  // Owner receipt is already committed when the broker publishes settlement.
  // Its binary slots must exactly equal executor retention and observed chunks.
  let assert Ok(reserved) = config.reserve(request)
    as "The first reserved UUID remains addressable by the original child."
  let assert Ok(digest) = wire.prepared_digest(prepared)
    as "The digest is over unchanged cleared authority."
  let original = check_receipt(fixture, origin, reserved.key, digest, observed)
  assert process.receive(fixture.fenced, 0) == Error(Nil)
  broker.stop(broker)

  // Every exchange already reconnects its socket. A newer administrative
  // generation also fences old tickets while retaining the same logical UUID.
  let renewed = connection.Config(..fixture.connection, generation: 2)
  let assert Ok(wire.Hello) = connection.exchange(renewed, wire.Hello)
    as "The actual authenticated service accepts the newer transport generation."
  let retry = binding(fixture, renewed, fixture.registered, cleared)
  let repeated = retry_request(retry, request)
  assert repeated == observed
  assert custodian.child(fixture.owner, origin) == Ok(original)
  assert simplifile.read(fixture.path <> "/proof") == Ok("x")

  // Closing SQLite and reopening the same supervised address discards owner
  // process memory. Replay must still read the original durable receipt and ID.
  stop_owner(fixture)
  let assert Ok(reopened) = custodian.start(fixture.owner, fixture.owner_config)
    as "Restart reopens the original owner journal rather than creating a row."
  assert custodian.child(fixture.owner, origin) == Ok(original)
  assert retry_request(retry, request) == observed
  assert retry.reserve(request) == Ok(reserved)
  assert custodian.child(fixture.owner, origin) == Ok(original)
  assert simplifile.read(fixture.path <> "/proof") == Ok("x")
  finish(FixtureState(..fixture, owner_pid: reopened.pid), renewed)
  io.println(
    "remote-owner: broker stream, exact durable receipt and restart retry passed",
  )
}

fn refusals() {
  let fixture = fixture("refusals")
  let cleared = process.new_subject()
  let changed_scope = scope(2)
  let assert Ok(other) =
    registration.new(
      changed_scope,
      [fixture.path],
      fixture.policy,
      exec.PlatformEnforcement,
      canonical,
    )
    as "A different epoch is valid administration, but cannot grant old scope."
  let wrong_registration = binding(fixture, fixture.connection, other, cleared)
  let request =
    physical_request(fixture, origin(1), "printf bad >> registration-proof", 1)
  let assert Ok(reserved) = wrong_registration.reserve(request)
    as "Owner reservation is not executor registration approval."
  expect_failure(wrong_registration, request)
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "Even the refused request has a well-formed digest."
  no_native_payload(fixture.book, reserved.key, digest)
  assert simplifile.is_file(fixture.path <> "/registration-proof") == Ok(False)
  let assert Ok(#(_, _, None)) = custodian.child(fixture.owner, origin(1))
    as "A refusal never becomes a successful durable child terminal."

  // Correct digest and valid cwd cannot authorize broader native policy.
  let broader = policy.SandboxPolicy(..fixture.policy, writable_roots: ["/"])
  let request =
    physical_request(fixture, origin(2), "printf bad >> policy-proof", 2)
  let request =
    dispatch.Dispatch(
      ..request,
      request: exec.ExecRequest(..request.request, policy: Some(broader)),
    )
  let config = binding(fixture, fixture.connection, fixture.registered, cleared)
  let assert Ok(reserved) = config.reserve(request)
    as "The owner retains the attempted exact authority for reconciliation."
  expect_failure(config, request)
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "The attempted authority is canonical and bounded."
  no_native_payload(fixture.book, reserved.key, digest)
  assert simplifile.is_file(fixture.path <> "/policy-proof") == Ok(False)

  // Socket authentication does not permit a peer to replace workspace epochs.
  // The decoder rejects the changed full scope before service admission.
  let foreign = connection.Config(..fixture.connection, scope: changed_scope)
  let config = binding(fixture, foreign, other, cleared)
  let request =
    physical_request(fixture, origin(3), "printf bad >> scope-proof", 3)
  expect_failure(config, request)
  assert simplifile.is_file(fixture.path <> "/scope-proof") == Ok(False)
  let assert Ok(#(_, _, None)) = custodian.child(fixture.owner, origin(3))
    as "Scope rejection leaves owner reservation pending, never successful."
  assert process.receive(fixture.fenced, 0) == Error(Nil)
  finish(fixture, fixture.connection)
  io.println(
    "remote-owner: registration, policy and full-scope refusals passed",
  )
}

fn fixture(name: String) -> Fixture {
  let assert Ok(here) = simplifile.current_directory()
    as "The runner starts in packages/client."
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    here
    <> "/build/remote-owner/"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(Nil) = simplifile.create_directory_all(path <> "/scratch/tmp")
    as "The fixture has an independent native writable checkout."
  let assert Ok(path) = canonical(path)
    as "The registered directory uses its actual filesystem identity."
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
  let assert Ok(registered) =
    registration.new(
      scope(1),
      [path],
      policy,
      exec.PlatformEnforcement,
      canonical,
    )
    as "Real canonical paths and finite policy enter the production constructor."
  let native = native_service(path, base)
  let assert Ok(capacity) = admission.capacity(8)
    as "Executor lifetime evidence is bounded."
  let assert Ok(book) =
    journal.fresh(path <> "/executor.sqlite", scope(1), capacity)
    as "The executor owns actual WAL/FULL payload and admission custody."
  let assert Ok(server) =
    service.start(service.Config(
      "owner",
      "linux",
      scope(1),
      1,
      book,
      native,
      fn(key, prepared) {
        case proof_mode() {
          BypassRegistration -> Ok(Nil)
          Baseline | SkipOwnerReceipt ->
            registration.verify(registered, key, prepared)
        }
      },
      poll.monotonic().now,
    ))
    as "The service never substitutes a digest-only approval callback."
  let #(connection, listener, acceptors) = transport(server)
  let assert Ok(limits) = custody.limits(4, 8, 16_777_216, 2_097_152)
    as "Owner request and receipt lifetime storage is bounded independently."
  let owner_path = path <> "/owner.sqlite"
  let assert Ok(store) = custody.open(owner_path, session(), limits)
    as "The owner journal is real SQLite, separate from executor custody."
  let assert Ok(bytes) = custody.payload(limits, <<"original parent":utf8>>)
    as "Parent bytes fit the existing bound."
  assert custody.admit_fresh(store, parent(), bytes, bytes) == Ok(custody.Fresh)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(names) = registry.start()
    as "Owner custody uses its restartable production address."
  let assert Ok(owner_config) =
    custodian.config(owner_path, session(), limits, 1, 5000, fn(_, _) {
      panic as "This proof invokes physical children, never a parent body."
    })
    as "No tool body or provider is injected into parent execution."
  let owner = custodian.new(names, owner_config)
  let assert Ok(started) = custodian.start(owner, owner_config)
    as "The real custodian reopens durable parent authority."
  FixtureState(
    path,
    owner,
    owner_config,
    started.pid,
    book,
    server,
    registered,
    policy,
    connection,
    listener,
    acceptors,
    process.new_subject(),
  )
}

fn native_service(path: String, base: policy.SandboxPolicy) -> local.Executor {
  let assert Ok(here) = simplifile.current_directory()
    as "The helper path is derived from the actual workspace."
  let helper = here <> "/../sandbox/loom-exec"
  assert simplifile.is_file(helper) == Ok(True)
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
  let assert Ok(pool) = exec.start_pool(1, fn() { exec.prepare_helper(spawn) })
    as "A real pool starts the real sandbox helper without a fake checkout."
  let assert Ok(native) =
    local.start(local.ExecutorConfig(
      checkout: fn() { exec.checkout(pool, waiting: 3000) },
      checkin: fn(helper) { exec.checkin(pool, helper) },
      custody: fn() { exec.pool_custody(pool, waiting: 1000) },
      close_helpers: fn(ms) { exec.close_pool(pool, waiting: ms) },
      incarnation: 17,
      log: log.discard(),
    ))
    as "Only native execution happens beside the executor checkout."
  native
}

fn transport(
  server: service.Service,
) -> #(connection.Config, tls.Listener, process.Pid) {
  assert tls.start() == Ok(Nil)
  let Fixture(server_cert, client_cert, _, _, _, _) = certificates()
  let assert Ok(socket) =
    tls.listen(credentials(server_cert, client_cert), tls.Loopback, 0)
    as "Loopback mTLS must listen; a sandbox denial is a failed fixture."
  let assert Ok(port) = tls.port(socket)
    as "The operating system chooses an isolated available port."
  let assert Ok(config) = listener.configure(socket, server, 4, 3000)
    as "The production listener bounds simultaneous connection workers."
  let assert Ok(started) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(listener.supervised(config))
    |> supervisor.start
    as "The real listener runs under its finite restart supervisor."
  #(
    connection.Config(
      credentials(client_cert, server_cert),
      "localhost",
      port,
      2500,
      "owner",
      "linux",
      1,
      scope(1),
    ),
    socket,
    started.pid,
  )
}

fn credentials(local: Credentials, peer: Credentials) -> tls.Settings {
  let Credentials(ca, certificate, key, _) = local
  let Credentials(_, _, _, pin) = peer
  let assert Ok(settings) =
    tls.settings(ca, certificate, key, pin, 1000, 1000, 500)
    as "Both peers require PKIX validation and the exact ephemeral leaf pin."
  settings
}

fn binding(
  fixture: Fixture,
  connection: connection.Config,
  registered: registration.Registration,
  cleared: process.Subject(#(dispatch.Dispatch, wire.Prepared)),
) -> dispatcher.Config {
  let digest = registration.digest(registered)
  let assert Ok(bound) =
    dispatch_binding.new(
      fixture.owner,
      connection,
      fn(request) {
        let prepared =
          wire.Prepared(
            request.context.step,
            digest,
            wire.Finite(30_000),
            request.request,
            wire.Logs,
          )
        process.send(cleared, #(request, prepared))
        Ok(prepared)
      },
      mint_candidate,
      poll.monotonic().now,
      23,
      3000,
      fn(error) { process.send(fixture.fenced, error) },
    )
    as "Only the production binding creates owner reservation and receipt callbacks."
  let config = dispatch_binding.configuration(bound)

  // This named counterexample deliberately removes durable owner receipt only
  // in the standalone test assembly. The baseline uses the unchanged callback.
  case proof_mode() {
    SkipOwnerReceipt ->
      dispatcher.Config(..config, receive: fn(_, _, _, _, _) { Ok(Nil) })
    Baseline | BypassRegistration -> config
  }
}

fn call_spec(fixture: Fixture, shell: String) -> broker.CallSpec {
  broker.CallSpec(
    operation(4),
    "physical:compile",
    fixture.policy,
    fixture.policy,
    [],
    broker.RefuseNarrowed,
    exec.PlatformEnforcement,
    ["/bin/sh", "-c", shell],
    [],
    fixture.path,
    budget.Budget(1, poll.monotonic().now() + 30_000),
  )
}

fn physical_request(
  fixture: Fixture,
  origin: remote_tool.ChildOrigin,
  shell: String,
  seq: Int,
) -> dispatch.Dispatch {
  dispatch.Dispatch(
    dispatch.CallContext(operation(4), "physical:compile", Some(origin)),
    exec.ExecRequest(
      ["/bin/sh", "-c", shell],
      [],
      fixture.path,
      Some(fixture.policy),
      <<7:size(256)>>,
      exec.PlatformEnforcement,
    ),
    seq,
    poll.monotonic().now() + 30_000,
    clock.from_function(poll.monotonic().now),
    None,
    fn(_) { Nil },
    fn(_) { Nil },
  )
}

fn retry_request(
  config: dispatcher.Config,
  request: dispatch.Dispatch,
) -> Observation {
  let events = process.new_subject()
  let request =
    dispatch.Dispatch(
      ..request,
      seq: request.seq + 100,
      deliver: fn(chunk) { process.send(events, Error(chunk)) },
      settle: fn(terminal) { process.send(events, Ok(terminal)) },
    )
  let assert Ok(execution) = dispatcher.dispatcher(config).start(request)
    as "Retry starts observation machinery, never another logical request."
  let observed = dispatch_observation(events, [])
  execution.release()
  observed
}

fn expect_failure(config: dispatcher.Config, request: dispatch.Dispatch) {
  let observed = retry_request(config, request)
  let assert dispatch.Failed(exec.ExecutionLost(exec.RemoteOutcomeUncertain)) =
    observed.terminal
    as "Refused remote authority settles without fabricated native success."
  assert observed.outputs == []
}

fn broker_observation(
  events: process.Subject(broker.CallEvent),
  outputs: List(dispatch.Chunk),
) -> Observation {
  let assert Ok(event) = process.receive(events, 8000)
    as "The broker must settle before the finite fixture deadline."
  case event {
    broker.CallOutput(stream, data, total, truncated) ->
      broker_observation(
        events,
        list.append(outputs, [dispatch.Chunk(stream, data, total, truncated)]),
      )
    broker.CallSettled(broker.CallExited(result)) ->
      Observation(outputs, dispatch.Completed(result))
    broker.CallSettled(broker.CallFailed(failure)) ->
      Observation(outputs, dispatch.Failed(failure))
  }
}

fn dispatch_observation(
  events: process.Subject(Result(dispatch.Terminal, dispatch.Chunk)),
  outputs: List(dispatch.Chunk),
) -> Observation {
  let assert Ok(event) = process.receive(events, 8000)
    as "The dispatcher must settle before the finite fixture deadline."
  case event {
    Error(chunk) -> dispatch_observation(events, list.append(outputs, [chunk]))
    Ok(terminal) -> Observation(outputs, terminal)
  }
}

fn stream_bytes(
  outputs: List(dispatch.Chunk),
  stream: framing.OutputStream,
) -> BitArray {
  outputs
  |> list.filter(fn(chunk) { chunk.stream == stream })
  |> list.map(fn(chunk) { chunk.data })
  |> bit_array.concat
}

fn check_receipt(
  fixture: Fixture,
  origin: remote_tool.ChildOrigin,
  key: identity.RequestKey,
  digest: identity.Digest,
  observed: Observation,
) -> #(ids.EntryId, BitArray, Option(BitArray)) {
  let assert Ok(items) = journal.payloads(fixture.book, key, digest)
    as "The executor retained exact native output and terminal bytes."
  let outputs =
    list.filter_map(items, fn(item) {
      case item {
        payload.Output(_, bytes) -> Ok(bytes)
        _ -> Error(Nil)
      }
    })
  let assert Ok(payload.Terminal(terminal)) =
    list.find(items, fn(item) {
      case item {
        payload.Terminal(_) -> True
        _ -> False
      }
    })
    as "Executor custody contains the actual encoded terminal."
  assert list.try_map(outputs, native.decode_output) == Ok(observed.outputs)
  assert native.decode_terminal(terminal) == Ok(observed.terminal)
  let assert Ok(expected) = custodian.receipt(outputs, terminal)
    as "The owner uses the actual ordered receipt codec."
  let assert Ok(child) = custodian.child(fixture.owner, origin)
    as "The original child UUID and envelope live in owner SQLite."
  assert child.2 == Some(expected)
  let assert Ok(evidence) = journal.inspect(fixture.book, key, digest)
    as "The executor acknowledges only the persisted owner receipt."
  let assert admission.Terminal(
    _,
    admission.NativeUnconfirmed,
    admission.ReceiptDurable,
  ) = admission.phase(evidence)
    as "A terminal is durably received before native retirement is claimed."
  child
}

fn stop_owner(fixture: Fixture) {
  let monitor = process.monitor(fixture.owner_pid)
  assert custodian.stop(fixture.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "SQLite ownership closes before restart inspection."
  Nil
}

fn finish(fixture: Fixture, connection: connection.Config) {
  let assert Ok(wire.ScopeRetirement) =
    connection.exchange(connection, wire.CloseScope)
    as "The actual native pool must witness retirement before fixture completion."
  tls.close_listener(fixture.listener)

  // Closing the listener stops admissions. Supervisor shutdown ends network
  // workers; native retirement was already witnessed independently above.
  let monitor = process.monitor(fixture.acceptors)
  process.unlink(fixture.acceptors)
  process.send_abnormal_exit(fixture.acceptors, Shutdown)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "The fixture's accepting subtree terminates within its own deadline."
  assert journal.release(fixture.book) == Ok(Nil)
  stop_owner(fixture)
}

fn canonical(path: String) -> Result(String, Nil) {
  bootstrap.canonical_path(path) |> result.replace_error(Nil)
}

fn session() -> ids.SessionId {
  ids.mint_session(ids.generator(clock.fixed(1000), 1)).0
}

fn operation(number: Int) -> ids.OpId {
  ids.mint_op(ids.generator(clock.fixed(1000), number)).0
}

fn scope(number: Int) -> identity.Scope {
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "The workspace label is an administrative value."
  let assert Ok(executor) = identity.executor_id("linux")
    as "The executor label is independent of the TLS hostname."
  let assert Ok(epoch) = identity.epoch(number)
    as "Fixture authority and workspace epochs are positive."
  identity.scope(session(), workspace, executor, epoch, epoch)
}

fn parent() -> remote_tool.ToolKey {
  let assert Ok(parent) =
    remote_tool.key(
      session(),
      operation(2),
      "parent:tools",
      0,
      string.repeat("a", 64),
      ids.mint_entry(ids.generator(clock.fixed(1000), 3)).0,
    )
    as "The parent's immutable identity differs from physical compilation."
  parent
}

fn compile_origin() -> remote_tool.ChildOrigin {
  let assert Ok(origin) = remote_tool.tool_child(parent(), remote_tool.Compile)
    as "The original compile child carries its actual immutable parent."
  origin
}

fn origin(number: Int) -> remote_tool.ChildOrigin {
  let assert Ok(origin) =
    remote_tool.system_child(session(), "joined-fixture", number)
    as "Refusals each retain their own durable original child."
  origin
}

fn mint_candidate() -> ids.EntryId {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  ids.mint_entry(ids.generator(
    clock.fixed(seconds * 1000 + nanos / 1_000_000),
    nanos,
  )).0
}

fn no_native_payload(
  book: journal.Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
) {
  let assert Ok(items) = journal.payloads(book, key, digest)
    as "Refused authority may retain only the cancellation fence, never native materialization."
  assert list.all(items, fn(item) {
    case item {
      payload.Cancellation(_) -> True
      payload.Request(_)
      | payload.Authority(_)
      | payload.Output(_, _)
      | payload.Terminal(_) -> False
    }
  })
}

fn proof_mode() -> ProofMode {
  case bootstrap.getenv("LOOM_REMOTE_OWNER_MUTATION") {
    Error(Nil) | Ok("") -> Baseline
    Ok("bypass-registration") -> BypassRegistration
    Ok("skip-owner-receipt") -> SkipOwnerReceipt
    Ok(_) ->
      panic as "Only the two named test-assembly counterexamples are valid."
  }
}

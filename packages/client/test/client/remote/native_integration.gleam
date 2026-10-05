//// Joined owner custody, registered TLS BEAM and native helper component proof.
////
//// `main` runs alone under scripts/e2e_remote_owner.sh. This module exports no
//// EUnit tests. Fixed owner and executor entrypoints run in independent OS VMs
//// with real TLS membership. Test files coordinate local journal inspection;
//// actual remote effects and observations use the production BEAM endpoint.
////
//// `success` enters the actual broker with the original compile-child identity.
//// It compares both custody stores with the actual observed helper output, then
//// reuses the exact cleared request across TLS generation change and owner
//// custody restart. `compile_origin` pins the original child provenance.
//// `refusals` checks administrative digest, policy and scope
//// failures before a physical marker write. The fixture proves these joined
//// components; daemon routing, executor pools, workspace and LSP are separate.

import argv
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
import distribution_fixture
import executor
import executor/remote/admission
import executor/remote/beam_endpoint
import executor/remote/dispatcher
import executor/remote/distribution
import executor/remote/identity
import executor/remote/journal
import executor/remote/native
import executor/remote/payload
import executor/remote/registration
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import simplifile
import storage/owner_custody as custody
import support/native_beam_fixture as nodes
import telemetry/log
import weft/poll
import weft/registry

type Fixture {
  FixtureState(
    root: String,
    path: String,
    owner: custodian.Handle,
    owner_config: custodian.Config,
    owner_pid: process.Pid,
    registered: registration.Registration,
    policy: policy.SandboxPolicy,
    connection: beam_endpoint.Config,
    fenced: process.Subject(custody.Error),
  )
}

type ProofMode {
  Baseline
  BypassRegistration
  SkipOwnerReceipt
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
  case argv.load().arguments {
    ["--native-beam-owner", root] -> {
      let assert Ok(name) = simplifile.read(root <> "/scenario")
        as "The parent chooses one fixed source scenario."
      case name {
        "success" -> success()
        "refusals" -> refusals()
        _ -> panic as "No runtime-selected callback is admitted."
      }
    }
    [] -> {
      success()
      refusals()
      io.println("remote-owner: joined component proof passed")
    }
    _ -> panic as "Only fixed owner arguments enter the native component proof."
  }
}

fn success() {
  use peer <- nodes.run("success")
  let fixture = fixture(peer)
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

  // Broker clearance preserves child provenance before any executor admission.
  let shell =
    "printf x >> proof; printf owner-stream; printf executor-stderr >&2"
  let spec = call_spec(fixture, shell)
  let assert Ok(_) =
    broker.clear_call_from(broker, origin, spec, events:, waiting: 2000)
    as "The real broker preserves original provenance while clearing authority."
  let assert Ok(#(request, prepared)) = process.receive(cleared, 3000)
    as "Preparation observes the exact broker-cleared physical request."

  // Physical identity and logical parent provenance must remain distinct.
  assert request.context.origin == Some(origin)
  assert request.context.operation == operation(4)
  assert request.context.step == "physical:compile"
  assert remote_tool.operation(parent()) != request.context.operation
  assert remote_tool.step(parent()) != request.context.step

  // Actual helper stdout and stderr must match the broker settlement.
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

  // The old native epoch is permanently fenced and actually drained before its
  // OS VM exits. The manager joins that exit before opening the same DB in VM2.
  retire(fixture.connection)
  nodes.mark(fixture.root, "rotate")
  nodes.await(fixture.root, "executor-ready-2")
  assert simplifile.is_file(fixture.root <> "/vm-exited-1") == Ok(True)
  let renewed = beam_endpoint.Config(..fixture.connection, generation: 2)
  let assert Ok(wire.Hello) = beam_endpoint.exchange(renewed, wire.Hello)
    as "The replacement endpoint binds generation2 to the same fenced journal."

  // The new endpoint may observe history but cannot remint the original effect.
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

  // Final retirement joins the replacement executor after durable owner restart.
  finish(FixtureState(..fixture, owner_pid: reopened.pid), renewed)
  io.println(
    "remote-owner: broker stream, exact durable receipt and restart retry passed",
  )
}

fn refusals() {
  use peer <- nodes.run("refusals")
  let fixture = fixture(peer)
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

  // A well-formed alternate registration cannot approve the original scope.
  let wrong_registration = binding(fixture, fixture.connection, other, cleared)
  let request =
    physical_request(fixture, origin(1), "printf bad >> registration-proof", 1)
  let assert Ok(reserved) = wrong_registration.reserve(request)
    as "Owner reservation is not executor registration approval."

  // Refusal evidence remains cancellation-only in the actual executor journal.
  expect_failure(wrong_registration, request)
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "Even the refused request has a well-formed digest."
  no_native_payload(fixture, "registration-refusal", reserved.key, digest)
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

  // Broader native authority is rejected before any physical materialization.
  expect_failure(config, request)
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "The attempted authority is canonical and bounded."
  no_native_payload(fixture, "policy-refusal", reserved.key, digest)
  assert simplifile.is_file(fixture.path <> "/policy-proof") == Ok(False)

  // Runtime authentication does not permit a request to replace workspace epochs.
  // The decoder rejects the changed full scope before service admission.
  let foreign = beam_endpoint.Config(..fixture.connection, scope: changed_scope)
  let config = binding(fixture, foreign, other, cleared)
  let request =
    physical_request(fixture, origin(3), "printf bad >> scope-proof", 3)
  expect_failure(config, request)
  assert simplifile.is_file(fixture.path <> "/scope-proof") == Ok(False)
  let assert Ok(#(_, _, None)) = custodian.child(fixture.owner, origin(3))
    as "Scope rejection leaves owner reservation pending, never successful."

  // Refusals do not fence healthy owner custody, and native teardown is still real.
  assert process.receive(fixture.fenced, 0) == Error(Nil)
  finish(fixture, fixture.connection)
  io.println(
    "remote-owner: registration, policy and full-scope refusals passed",
  )
}

fn fixture(peer: distribution.Peer) -> Fixture {
  let root = nodes.root()
  nodes.await(root, "executor-ready-1")
  let #(path, policy, registered) = authority(root)
  let connection =
    beam_endpoint.Config(peer, "owner", "linux", scope(1), 1, 2500)
  let assert Ok(limits) = custody.limits(4, 8, 16_777_216, 2_097_152)
    as "Owner request and receipt lifetime storage is bounded independently."

  // Fresh parent authority is durably admitted before creating its custodian.
  let owner_path = root <> "/owner.sqlite"
  let assert Ok(store) = custody.open(owner_path, session(), limits)
    as "The owner journal is real SQLite, separate from executor custody."
  let assert Ok(bytes) = custody.payload(limits, <<"original parent":utf8>>)
    as "Parent bytes fit the existing bound."
  assert custody.admit_fresh(store, parent(), bytes, bytes) == Ok(custody.Fresh)
  assert custody.close(store) == Ok(Nil)

  // Only the original owner process owns durable child receipt callbacks.
  let assert Ok(names) = registry.start()
    as "Owner custody uses its restartable production address."
  let assert Ok(owner_config) =
    custodian.config(owner_path, session(), limits, 1, 5000, fn(_, _, _) {
      panic as "This proof invokes physical children, never a parent body."
    })
    as "No tool body or provider is injected into parent execution."
  let owner = custodian.new(names, owner_config)
  let assert Ok(started) = custodian.start(owner, owner_config)
    as "The real custodian reopens durable parent authority."
  FixtureState(
    root,
    path,
    owner,
    owner_config,
    started.pid,
    registered,
    policy,
    connection,
    process.new_subject(),
  )
}

fn authority(
  root: String,
) -> #(String, policy.SandboxPolicy, registration.Registration) {
  let assert Ok(path) = canonical(root <> "/checkout")
    as "The native effects directory has its actual canonical identity."
  let assert Ok(provisioned) =
    distribution_fixture.read_provisioned(root <> "/fixture.term")
    as "Both roles derive the same immutable test registration ceiling."
  let protected =
    list.append(
      distribution.protected_paths(provisioned.owner_config),
      distribution.protected_paths(provisioned.executor_config),
    )
  let protected =
    list.append(protected, [
      provisioned.owner_options,
      provisioned.executor_options,
    ])
  let base = executor.base_policy(path)
  let policy =
    policy.SandboxPolicy(
      ..base,
      protected: protected,
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
    as "The actual administrative constructor validates a finite exact policy."
  #(path, policy, registered)
}

/// Owns real executor-local helpers and journal in one of two fixed OS roles.
///
/// ## Examples
/// The finite fixture invokes `executor_main()` only in its named executor VM.
pub fn executor_main() -> Nil {
  let root = nodes.root()
  let generation = case argv.load().arguments {
    ["--native-beam-executor-1", _] -> 1
    ["--native-beam-executor-2", _] -> 2
    _ ->
      panic as "Only the fixed original or replacement executor role is valid."
  }
  let assert Ok(provisioned) =
    distribution_fixture.read_provisioned(root <> "/fixture.term")
    as "The executor reads the original trusted administrative data."
  let assert Ok(membership) = distribution.start(provisioned.executor_config)
    as "The actual executor is a TLS-only trusted runtime member."
  let assert Ok(owner_peer) =
    distribution.peer(membership, provisioned.owner_name)
    as "Only the original owner can access this registered endpoint."

  // Native effects and their durable journal are owned only by the executor VM.
  assert simplifile.create_directory_all(root <> "/checkout/scratch/tmp")
    == Ok(Nil)
  let #(path, policy, registered) = authority(root)
  let native = native_service(path, policy)
  let native_monitor = process.monitor(local.pid(native))
  let assert Ok(capacity) = admission.capacity(8)
    as "Native lifetime evidence is bounded."

  // Recovery retains the closed epoch; generation is transport incarnation only.
  let book = case generation {
    1 -> journal.fresh(path <> "/executor.sqlite", scope(1), capacity)
    2 -> journal.recover(path <> "/executor.sqlite", scope(1), capacity)
    _ -> panic as "Only the two fixed generation roles can open this database."
  }
  let assert Ok(book) = book
    as "VM2 recovers the original permanently fenced authority and bytes."
  let assert Ok(server) =
    service.start(service.Config(
      "owner",
      "linux",
      scope(1),
      generation,
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
    as "Actual native service retains exact scope, generation and registration."

  // Endpoint credits carry only closed requests to this concrete local service.
  let assert Ok(row) =
    beam_endpoint.registration(owner_peer, server, None, process.self())
    as "Endpoint admission derives authority from the concrete service."
  let assert Ok(config) = beam_endpoint.configure_server([row], 5000)
    as "The finite endpoint registers only this original service."
  let assert Ok(endpoint) = beam_endpoint.start(config)
    as "The real distributed endpoint owns bounded data and control lanes."
  nodes.mark(root, "executor-ready-" <> int.to_string(generation))
  let assert poll.Answered(Nil) =
    poll.until(35_000, 10, fn() {
      inspect_jobs(root, book)
      case
        simplifile.is_file(root <> "/done"),
        simplifile.is_file(root <> "/rotate"),
        simplifile.is_file(root <> "/abort")
      {
        Ok(True), _, _ | _, _, Ok(True) -> poll.Done(Nil)
        _, Ok(True), _ if generation == 1 -> poll.Done(Nil)
        _, _, _ -> poll.Retry
      }
    })
    as "The original owner either finishes, rotates or explicitly aborts."

  // Native drain precedes the witness and OS exit. Endpoint stop is asynchronous
  // and never substitutes for joining every old transport process at VM exit.
  beam_endpoint.quiesce(endpoint)
  assert service.quiesce(server) == Ok(Nil)
  case simplifile.is_file(root <> "/abort") {
    Ok(True) -> {
      assert service.shutdown(server) == Ok(Nil)
    }
    _ -> Nil
  }
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(native_monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "ScopeRetirement or abort shutdown actually ends the native custody actor."
  assert journal.release(book) == Ok(Nil)
  beam_endpoint.stop(endpoint)
  nodes.mark(root, "native-drained-" <> int.to_string(generation))
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

fn binding(
  fixture: Fixture,
  connection: beam_endpoint.Config,
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
  inspect_request(fixture, "receipt", key, digest)
  let assert Ok(count) =
    simplifile.read(fixture.root <> "/receipt.count")
    |> result.replace_error(Nil)
    |> result.try(int.parse)
    as "The executor reports its actual retained ordered output slot count."
  let outputs =
    int.range(0, count, [], fn(outputs, index) {
      let assert Ok(bytes) =
        simplifile.read_bits(
          fixture.root <> "/receipt.output-" <> int.to_string(index + 1),
        )
        as "Raw output bytes came from the executor's original durable slots."
      list.append(outputs, [bytes])
    })
  let assert Ok(terminal) =
    simplifile.read_bits(fixture.root <> "/receipt.terminal")
    as "The executor transfers its actual original terminal bytes for comparison."
  assert list.try_map(outputs, native.decode_output) == Ok(observed.outputs)
  assert native.decode_terminal(terminal) == Ok(observed.terminal)

  // The owner compares the actual raw slots with its independently durable receipt.
  let assert Ok(expected) = custodian.receipt(outputs, terminal)
    as "The owner uses the actual ordered receipt codec."
  let assert Ok(child) = custodian.child(fixture.owner, origin)
    as "The original child UUID and envelope live in owner SQLite."
  assert child.2 == Some(expected)
  assert simplifile.is_file(fixture.root <> "/receipt.checked") == Ok(True)
    as "The executor independently checked NativeUnconfirmed and ReceiptDurable."
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

fn retire(connection: beam_endpoint.Config) -> Nil {
  let assert Ok(wire.ScopeRetirement) =
    beam_endpoint.exchange(connection, wire.CloseScope)
    as "The actual native pool witnesses retirement before executor replacement."
  Nil
}

fn finish(fixture: Fixture, connection: beam_endpoint.Config) {
  retire(connection)
  nodes.mark(fixture.root, "done")
  nodes.await(
    fixture.root,
    "native-drained-" <> int.to_string(connection.generation),
  )
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
  fixture: Fixture,
  name: String,
  key: identity.RequestKey,
  digest: identity.Digest,
) {
  inspect_request(fixture, name, key, digest)
}

fn inspect_request(
  fixture: Fixture,
  name: String,
  key: identity.RequestKey,
  digest: identity.Digest,
) {
  let envelope =
    wire.Envelope(
      wire.Owner,
      "owner",
      "linux",
      1,
      scope(1),
      wire.Query(key, digest, 0),
    )
  let assert Ok(bytes) = wire.encode(envelope)
    as "Fixed test inspection carries the same canonical original identity."
  assert simplifile.write_bits(fixture.root <> "/" <> name <> ".query", bytes)
    == Ok(Nil)
  nodes.await(fixture.root, name <> ".checked")
}

fn inspect_jobs(root: String, book: journal.Journal) -> Nil {
  list.each(["receipt", "registration-refusal", "policy-refusal"], fn(name) {
    case
      simplifile.is_file(root <> "/" <> name <> ".query"),
      simplifile.is_file(root <> "/" <> name <> ".checked")
    {
      Ok(True), Ok(False) -> inspect_job(root, name, book)
      _, _ -> Nil
    }
  })
}

fn inspect_job(root: String, name: String, book: journal.Journal) -> Nil {
  let assert Ok(bytes) = simplifile.read_bits(root <> "/" <> name <> ".query")
    as "Only the original owner writes this fixed local test inspection slot."
  let assert Ok(envelope) =
    wire.decode(bytes, wire.Owner, "owner", "linux", scope(1))
    as "Even test inspection decodes the original closed bounded native wire."
  let assert wire.Query(key, digest, 0) = envelope.body
    as "This test seam only inspects an exact admitted original request."
  let assert Ok(items) = journal.payloads(book, key, digest)
    as "The executor reads its actual retained payload journal."
  case name {
    "receipt" -> inspect_receipt(root, book, key, digest, items)
    "registration-refusal" | "policy-refusal" -> {
      assert list.all(items, fn(item) {
        case item {
          payload.Cancellation(_) -> True
          payload.Request(_)
          | payload.Authority(_)
          | payload.Output(_, _)
          | payload.Terminal(_) -> False
        }
      })
        as "Refused authority never materializes native authority, output or terminal."
    }
    _ -> panic as "Only the three fixed inspection scenarios are valid."
  }
  nodes.mark(root, name <> ".checked")
}

fn inspect_receipt(
  root: String,
  book: journal.Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
  items: List(payload.Item),
) -> Nil {
  let outputs =
    list.filter_map(items, fn(item) {
      case item {
        payload.Output(_, bytes) -> Ok(bytes)
        payload.Request(_)
        | payload.Authority(_)
        | payload.Cancellation(_)
        | payload.Terminal(_) -> Error(Nil)
      }
    })
  let assert Ok(payload.Terminal(terminal)) =
    list.find(items, fn(item) {
      case item {
        payload.Terminal(_) -> True
        payload.Request(_)
        | payload.Authority(_)
        | payload.Cancellation(_)
        | payload.Output(_, _) -> False
      }
    })
    as "Actual terminal custody is present before owner acknowledgement."
  assert simplifile.write(
      root <> "/receipt.count",
      int.to_string(list.length(outputs)),
    )
    == Ok(Nil)
  let _ =
    list.index_map(outputs, fn(bytes, index) {
      assert simplifile.write_bits(
          root <> "/receipt.output-" <> int.to_string(index + 1),
          bytes,
        )
        == Ok(Nil)
    })
  assert simplifile.write_bits(root <> "/receipt.terminal", terminal) == Ok(Nil)
  let assert Ok(evidence) = journal.inspect(book, key, digest)
    as "The executor acknowledges only the persisted original owner receipt."
  let assert admission.Terminal(
    _,
    admission.NativeUnconfirmed,
    admission.ReceiptDurable,
  ) = admission.phase(evidence)
    as "Durable receipt is established before any native retirement claim."
  Nil
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

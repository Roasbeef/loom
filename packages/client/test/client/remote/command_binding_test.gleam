//// Actual owner SQLite and original Broker controls for the closed compiler binding.
//// No physical Compile service is assembled by this slice. Native transport refusal
//// is expected in the Broker witness; its cleared Dispatch and retained custody are real.

import broker/broker
import broker/budget
import broker/command as offer
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/policy
import broker/token
import client/remote/command_binding
import client/remote/custodian
import client/remote/dispatch_binding
import codemode/compile
import codemode/service_command
import codemode/service_input as input
import codemode/service_resources as resources
import core/clock
import core/command
import core/ids
import core/remote_tool
import core/workspace
import executor
import executor/remote/connection
import executor/remote/dispatcher
import executor/remote/identity
import executor/remote/tls
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import storage/owner_custody as custody
import weft/actor
import weft/poll
import weft/registry

type Allocation {
  Next(reply: process.Subject(Int))
  Stop
}

type Fixture {
  Fixture(owner: custodian.Handle, pid: process.Pid)
}

fn session_id(number: Int) -> ids.SessionId {
  ids.mint_session(ids.generator(clock.fixed(1000), number)).0
}

fn operation(number: Int) -> ids.OpId {
  ids.mint_op(ids.generator(clock.fixed(1000), number)).0
}

fn request_id(number: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), number)).0
}

fn scope() -> identity.Scope {
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "Workspace label."
  let assert Ok(executor) = identity.executor_id("linux") as "Executor label."
  let assert Ok(epoch) = identity.epoch(1) as "Original epochs."
  identity.scope(session_id(1), workspace, executor, epoch, epoch)
}

fn parent(index: Int) -> remote_tool.ToolKey {
  let assert Ok(key) =
    remote_tool.key(
      session_id(1),
      operation(2),
      "parent:tools",
      index,
      string.repeat("a", 64),
      request_id(index + 3),
    )
    as "Complete distinct original parent."
  key
}

fn limits() -> custody.Limits {
  let assert Ok(value) = custody.limits(4, 64, 16_777_216, 2_097_152)
    as "Finite custody ceilings."
  value
}

fn new_fixture(name: String) -> Fixture {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/private/tmp/loom-command-binding-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "Private fixture."
  let assert Ok(store) =
    custody.open(directory <> "/owner.sqlite", session_id(1), limits())
    as "Actual SQLite owner."
  let assert Ok(bytes) = custody.payload(limits(), <<"original parent":utf8>>)
    as "Bounded parent."
  assert custody.admit_fresh(store, parent(0), bytes, bytes)
    == Ok(custody.Fresh)
  assert custody.admit_fresh(store, parent(1), bytes, bytes)
    == Ok(custody.Fresh)
  assert custody.close(store) == Ok(Nil)

  // The supervised custodian reopens committed parents before receiving offers.
  let assert Ok(names) = registry.start() as "Private registry."
  let assert Ok(config) =
    custodian.config(
      directory <> "/owner.sqlite",
      session_id(1),
      limits(),
      1,
      5000,
      fn(_, _) { panic as "No tool body in this custody witness." },
    )
    as "Bounded actor."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config) as "Actual custodian."
  Fixture(owner, started.pid)
}

fn stop(fixture: Fixture) -> Nil {
  let monitor = process.monitor(fixture.pid)
  assert custodian.stop(fixture.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "SQLite closes before subsequent tests."
  Nil
}

fn settings() -> tls.Settings {
  // These inert fixture credentials are parsed solely to construct real opaque
  // TLS settings. The tests invoke no connection or authentication exchange.
  let assert Ok(cert) =
    bit_array.base64_decode(
      "MIIBjzCCATWgAwIBAgIUYlLTKDvtMyvFfxpJRl0005XN75IwCgYIKoZIzj0EAwIwHTEbMBkGA1UEAwwSZGlzcGF0Y2gtdW5pdC10ZXN0MB4XDTI2MTAwNDExMzI0M1oXDTM2MTAwMTExMzI0M1owHTEbMBkGA1UEAwwSZGlzcGF0Y2gtdW5pdC10ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEMGT3LSnwJ0zHY2tM7YqzARt9MLz9HjShrrnUjO7TeI2P0cfh0o2H1jN1v/gMkvYjKQJc12Q46q7yMol/e+02v6NTMFEwHQYDVR0OBBYEFKjKoOrEhHywVewGbYh0HPLDhpFnMB8GA1UdIwQYMBaAFKjKoOrEhHywVewGbYh0HPLDhpFnMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIgKWPzCuZuoJ/39nYyt2zihlPEbp2Jz3sulLM/MOZNCz4CIQDSSO/yFaAr01e5WnkCnd2VhC+UsNDOr0N/R034ZpKEqA==",
    )
    as "The test-only DER fixture decodes."
  let assert Ok(key) =
    bit_array.base64_decode(
      "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JR0hBZ0VBTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEJHMHdhd0lCQVFRZzZFVjU4STM2UUsvaFNPZVoKUHd5dW1wVVMvK2VXMTU5N0cxNktabVptWjN1aFJBTkNBQVF3WlBjdEtmQW5UTWRqYTB6dGlyTUJHMzB3dlAwZQpOS0d1dWRTTTd0TjRqWS9SeCtIU2pZZldNM1cvK0F5UzlpTXBBbHpYWkRqcXJ2SXlpWDk3N1RhLwotLS0tLUVORCBQUklWQVRFIEtFWS0tLS0tCg==",
    )
    as "The test-only PEM private key fixture decodes."
  let assert Ok(settings) =
    tls.settings(cert, cert, key, <<1:size(256)>>, 1000, 1000, 100)
    as "The real TLS settings constructor parses bounded material."
  settings
}

fn connection(scope: identity.Scope) -> connection.Config {
  let fields = identity.scope_fields(scope)
  connection.Config(
    settings(),
    "localhost",
    12_345,
    1000,
    "owner",
    fields.2,
    1,
    scope,
  )
}

fn base() -> policy.SandboxPolicy {
  let original = executor.base_policy("/executor/work")
  policy.SandboxPolicy(
    ..original,
    writable_roots: ["/executor"],
    readable_roots: ["/"],
    network: policy.NetworkFull,
    limits: policy.Limits(..original.limits, wall_s: 180),
    env_allow: ["PATH", "TMPDIR"],
  )
}

fn enrolled() -> enrollment.SessionEnrollment {
  let assert Ok(full_scope) =
    workspace.scope_from_fields(
      ids.session_id_to_string(session_id(1)),
      "checkout",
      "linux",
      1,
      1,
    )
    as "Complete matching scope."
  let assert Ok(value) =
    enrollment.new(
      enrollment.NativeFacts(
        full_scope,
        ["/"],
        base(),
        exec.PlatformEnforcement,
      ),
      enrollment.CodeModeFacts(
        "/executor/work",
        "/executor/alloc/build",
        "/executor/alloc/channel",
        "/tc/bin/gleam",
        "/otp/bin/erl",
        "/seed",
        ["/tc", "/otp"],
        [],
        "/tc/bin",
      ),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Pinned original enrollment."
  value
}

fn original() -> input.CompileInput {
  let assert Ok(value) =
    input.compile_input(
      enrolled(),
      input.WorkspaceProgram,
      "pub fn main() { Nil }\n",
      [],
      compile.default_dependencies(),
      base(),
      180_000,
    )
    as "Canonical original source."
  value
}

fn hash(bytes: BitArray) -> String {
  let assert Ok(value) = wire.digest(bytes) as "Canonical SHA-256 evidence."
  string.lowercase(bit_array.base16_encode(identity.digest_bytes(value)))
}

fn service(index: Int, role: command.ServiceRole) -> command.ServiceKey {
  let assert Ok(step) = workspace.step("physical:build")
    as "Original physical step."
  let assert Ok(value) =
    command.service_key(
      parent(index),
      role,
      enrollment.native_facts(enrolled()).scope,
      operation(2),
      step,
      request_id(index + 20),
      hash(input.encode_compile(original())),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Full original service."
  value
}

fn proposal(index: Int) -> offer.CommandOffer {
  proposal_for(service(index, command.CompileService))
}

fn proposal_for(key: command.ServiceKey) -> offer.CommandOffer {
  let assert Ok(root) = enrollment.compile_path(enrolled(), key)
    as "Exact allocated path."
  let assert Ok(locations) =
    resources.admit_compile_locations(enrolled(), key, root)
    as "Location equality only."
  let assert Ok(expected) =
    service_command.compile_from_input(
      enrolled(),
      key,
      original(),
      locations,
      2,
    )
    as "Closed compiler template."
  service_command.offer(expected)
}

fn retain(fixture: Fixture, proposal: offer.CommandOffer) -> Nil {
  let ref = offer.reference(proposal)
  let assert Ok(original) =
    custodian.reserve_service_child(
      fixture.owner,
      command.service(ref),
      input.encode_compile(original()),
    )
    as "Original body commits first."
  let assert Ok(bytes) = offer.encode(proposal) as "Canonical exact offer."
  let assert Ok(payload) =
    custody.command_offer_payload(limits(), ref, hash(bytes), bytes)
    as "Bounded full-reference envelope."
  assert custodian.admit_offer(fixture.owner, original, payload)
    == Ok(custody.Fresh)
}

fn prepared(
  proposal: offer.CommandOffer,
  actual: policy.SandboxPolicy,
) -> wire.Prepared {
  let data = offer.data(proposal)
  let assert Ok(bytes) = bit_array.base16_decode(string.repeat("b", 64))
    as "Original registration bytes."
  let assert Ok(registration) = identity.digest(bytes)
    as "Fixed-width registration."
  wire.Prepared(
    "physical:build",
    registration,
    wire.Finite(180_000),
    exec.ExecRequest(
      data.argv,
      data.env,
      data.cwd,
      Some(actual),
      <<9:size(256)>>,
      exec.PlatformEnforcement,
    ),
    wire.Logs,
  )
}

fn dispatch(
  proposal: offer.CommandOffer,
  actual: wire.Prepared,
) -> dispatch.Dispatch {
  dispatch.Dispatch(
    dispatch.CallContext(
      operation(2),
      "physical:build",
      Some(command.native_origin(offer.reference(proposal))),
    ),
    actual.request,
    11,
    6000,
    clock.fixed(1000),
    None,
    fn(_) { Nil },
    fn(_) { Nil },
  )
}

fn binding(
  fixture: Fixture,
  actual: wire.Prepared,
  candidate: ids.EntryId,
) -> command_binding.Binding {
  let assert Ok(value) =
    command_binding.new(
      fixture.owner,
      enrolled(),
      scope(),
      fn(_) { Ok(actual) },
      fn() { candidate },
    )
    as "Same local original capabilities."
  value
}

fn config(
  fixture: Fixture,
  actual: wire.Prepared,
  candidate: ids.EntryId,
  fenced: process.Subject(custody.Error),
) -> dispatcher.Config {
  let assert Ok(value) =
    dispatch_binding.new(
      fixture.owner,
      connection(scope()),
      fn(_) { Ok(actual) },
      fn() { candidate },
      poll.monotonic().now,
      17,
      5000,
      fn(error) { process.send(fenced, error) },
    )
    as "Original binding."
  let assert Ok(value) = dispatch_binding.with_commands(value, enrolled())
    as "Closed extension preserves original configuration."
  value
}

pub fn exact_retry_returns_original_uuid_and_prepared_test() {
  let fixture = new_fixture("retry")
  let proposal = proposal(0)
  retain(fixture, proposal)
  let actual = prepared(proposal, offer.data(proposal).requirements)
  let first = binding(fixture, actual, request_id(40))
  let second = binding(fixture, actual, request_id(41))
  let assert Ok(dispatcher.CommandReserved(key, value, ref)) =
    command_binding.reserve(first, dispatch(proposal, actual))
    as "Live actual command reserves."
  assert value == actual
  assert ref == offer.reference(proposal)
  assert identity.key_fields(key).1 == ids.entry_id_to_string(request_id(40))
  assert command_binding.reserve(second, dispatch(proposal, actual))
    == Ok(dispatcher.CommandReserved(key, actual, ref))
  let assert Ok(#(stored, bytes, None)) =
    custodian.command_child(fixture.owner, ref)
    as "Exact native data remains retained."
  assert stored == request_id(40)
  assert wire.decode_prepared(custody.bytes(bytes)) == Ok(actual)
  stop(fixture)
}

pub fn narrowed_policy_is_preserved_and_wider_policy_refuses_test() {
  let fixture = new_fixture("policy")
  let proposal = proposal(0)
  retain(fixture, proposal)
  let requirements = offer.data(proposal).requirements
  let narrower =
    policy.SandboxPolicy(
      ..requirements,
      protected: ["/executor/work/private", ..requirements.protected],
      limits: policy.Limits(..requirements.limits, wall_s: 1),
      env_allow: list.reverse(requirements.env_allow),
    )
  let actual = prepared(proposal, narrower)
  let assert Ok(dispatcher.CommandReserved(_, retained, _)) =
    command_binding.reserve(
      binding(fixture, actual, request_id(40)),
      dispatch(proposal, actual),
    )
    as "Narrower actual cleared policy succeeds without reconstruction."
  assert retained == actual
  stop(fixture)

  // Broader network authority never enters native custody, even after preparation.
  let fixture = new_fixture("wide-policy")
  retain(fixture, proposal)
  let wider =
    prepared(
      proposal,
      policy.SandboxPolicy(..requirements, network: policy.NetworkFull),
    )
  assert command_binding.reserve(
      binding(fixture, wider, request_id(40)),
      dispatch(proposal, wider),
    )
    == Error(custody.Conflict)
  assert custodian.command_child(fixture.owner, offer.reference(proposal))
    == Error(custody.Missing)
  stop(fixture)
}

pub fn substituted_coordinates_token_or_callback_request_refuse_test() {
  let fixture = new_fixture("substitution")
  let proposal = proposal(0)
  retain(fixture, proposal)
  let actual = prepared(proposal, offer.data(proposal).requirements)
  let request = dispatch(proposal, actual)
  let changed =
    dispatch.Dispatch(
      ..request,
      context: dispatch.CallContext(
        operation(2),
        "foreign-step",
        request.context.origin,
      ),
    )
  let assert Ok(guarded) =
    command_binding.new(
      fixture.owner,
      enrolled(),
      scope(),
      fn(_) { panic as "Foreign phase must refuse before actual preparation." },
      fn() { panic as "Foreign phase must refuse before UUID mint." },
    )
    as "A wrong-phase Dispatch has no preparation authority."
  assert command_binding.reserve(guarded, changed) == Error(custody.Conflict)
  let changed =
    wire.Prepared(
      ..actual,
      request: exec.ExecRequest(..actual.request, token: <<10:size(256)>>),
    )
  assert command_binding.reserve(
      binding(fixture, changed, request_id(40)),
      request,
    )
    == Error(custody.Conflict)
  assert custodian.command_child(fixture.owner, offer.reference(proposal))
    == Error(custody.Missing)
  stop(fixture)
}

pub fn substituted_offer_template_and_build_mapping_refuse_test() {
  let fixture = new_fixture("template")
  let original = proposal(0)
  let data = offer.data(original)
  let assert Ok(changed) =
    offer.offer(
      offer.reference(original),
      offer.mappings(original),
      offer.CommandData(..data, argv: ["/tc/bin/gleam", "build"]),
    )
    as "Shape-valid malicious argv."
  retain(fixture, changed)
  let actual = prepared(changed, data.requirements)
  let assert Error(_) =
    command_binding.reserve(
      binding(fixture, actual, request_id(40)),
      dispatch(changed, actual),
    )
    as "Closed template refusal precedes native reservation."
  assert custodian.command_child(fixture.owner, offer.reference(original))
    == Error(custody.Missing)
  stop(fixture)

  // A canonical but different allocation is still foreign to this exact key.
  let fixture = new_fixture("mapping")
  let assert Ok(changed) =
    offer.offer(
      offer.reference(original),
      [offer.RegionMapping(offer.Build, "/executor/alloc/foreign")],
      data,
    )
    as "Shape-valid substituted region."
  retain(fixture, changed)
  let actual = prepared(changed, data.requirements)
  let assert Error(_) =
    command_binding.reserve(
      binding(fixture, actual, request_id(40)),
      dispatch(changed, actual),
    )
    as "Derived mappings must equal the entire offer."
  assert custodian.command_child(fixture.owner, offer.reference(original))
    == Error(custody.Missing)
  stop(fixture)
}

pub fn missing_command_custody_fences_and_satellite_never_falls_back_test() {
  let fixture = new_fixture("missing")
  let proposal = proposal(0)
  let actual = prepared(proposal, offer.data(proposal).requirements)
  let fenced = process.new_subject()
  let config = config(fixture, actual, request_id(40), fenced)
  assert config.reserve(dispatch(proposal, actual)) == Error(Nil)
  assert process.receive(fenced, 1000) == Ok(custody.Missing)
  config.cancel_reserved(dispatch(proposal, actual))
  assert process.receive(fenced, 1000) == Ok(custody.Missing)
  assert custodian.child(
      fixture.owner,
      command.native_origin(offer.reference(proposal)),
    )
    == Error(custody.Missing)

  // Launch cannot acquire a generic native slot through this Compile-only adapter.
  let assert Ok(ref) =
    command.command_ref(
      service(0, command.LaunchService),
      command.SatelliteCommand,
    )
    as "Closed satellite identity."
  let request = dispatch(proposal, actual)
  let request =
    dispatch.Dispatch(
      ..request,
      context: dispatch.CallContext(
        operation(2),
        "physical:build",
        Some(command.native_origin(ref)),
      ),
    )
  assert config.reserve(request) == Error(Nil)
  assert custodian.child(fixture.owner, command.native_origin(ref))
    == Error(custody.Missing)
  stop(fixture)
}

pub fn ordered_late_receipt_after_cancel_is_durable_and_identity_checked_test() {
  let fixture = new_fixture("receipt")
  let proposal = proposal(0)
  retain(fixture, proposal)
  let actual = prepared(proposal, offer.data(proposal).requirements)
  let binding = binding(fixture, actual, request_id(40))
  let assert Ok(dispatcher.CommandReserved(key, _, ref)) =
    command_binding.reserve(binding, dispatch(proposal, actual))
    as "Original native slot."
  let assert Ok(digest) = wire.prepared_digest(actual)
    as "Exact retained prepared digest."
  let origin = command.native_origin(ref)
  assert command_binding.cancel(binding, origin) == Ok(Nil)
  assert command_binding.reserve(binding, dispatch(proposal, actual))
    == Error(custody.Frozen)
  let assert Ok(foreign_id) =
    identity.request_id(ids.entry_id_to_string(request_id(41)))
    as "Foreign valid UUID."
  let foreign = identity.request_key(scope(), operation(2), foreign_id)
  let outputs = [<<"one":utf8>>, <<"two":utf8>>]
  assert command_binding.receive(binding, origin, foreign, digest, outputs, <<
      "terminal":utf8,
    >>)
    == Error(custody.Conflict)
  assert command_binding.receive(binding, origin, key, digest, outputs, <<
      "terminal":utf8,
    >>)
    == Ok(Nil)
  assert command_binding.receive(
      binding,
      origin,
      key,
      digest,
      list.reverse(outputs),
      <<"terminal":utf8>>,
    )
    == Error(custody.Conflict)
  let assert Ok(#(_, _, Some(receipt))) =
    custodian.command_child(fixture.owner, ref)
    as "Cancelled native receipt remains durable."
  assert custodian.receipt(outputs, <<"terminal":utf8>>)
    == Ok(custody.bytes(receipt))
  stop(fixture)
}

pub fn changed_connection_scope_refuses_before_callbacks_test() {
  let fixture = new_fixture("scope")
  let assert Ok(workspace) = identity.workspace_id("foreign")
    as "Different bounded workspace."
  let assert Ok(executor) = identity.executor_id("linux") as "Same executor."
  let assert Ok(epoch) = identity.epoch(1) as "Same original epoch."
  let foreign = identity.scope(session_id(1), workspace, executor, epoch, epoch)
  assert command_binding.new(
      fixture.owner,
      enrolled(),
      foreign,
      fn(_) { panic as "Foreign binding must not prepare." },
      fn() { panic as "Foreign binding must not mint." },
    )
    == Error(custody.Conflict)
  stop(fixture)
}

pub fn one_original_broker_clears_two_compile_parents_and_ordinary_call_test() {
  let fixture = new_fixture("original-broker")
  let first = proposal(0)
  let second = proposal(1)
  retain(fixture, first)
  retain(fixture, second)
  let assert Ok(candidates) =
    actor.new(60)
    |> actor.on_message(fn(next, message) {
      case message {
        Next(reply) -> {
          process.send(reply, next)
          actor.continue(next + 1)
        }
        Stop -> actor.stop()
      }
    })
    |> actor.start
    as "A test allocator returns distinct candidates across callback processes."
  let observed = process.new_subject()
  let fenced = process.new_subject()
  let assert Ok(local) =
    dispatch_binding.new(
      fixture.owner,
      connection(scope()),
      fn(request) {
        let template = prepared(first, offer.data(first).requirements)
        let actual = wire.Prepared(..template, request: request.request)
        process.send(observed, #(request, actual))
        Ok(actual)
      },
      fn() { request_id(process.call(candidates.data, 1000, Next)) },
      poll.monotonic().now,
      17,
      5000,
      fn(error) { process.send(fenced, error) },
    )
    as "One original binding owns all calls."
  let assert Ok(config) = dispatch_binding.with_commands(local, enrolled())
    as "Same dispatcher callbacks."
  let assert Ok(broker) =
    broker.start_dispatching(
      token.production_entropy(),
      clock.from_function(poll.monotonic().now),
      dispatcher.dispatcher(config),
    )
    as "One real original Broker performs clearance."
  let deadline = poll.monotonic().now() + 30_000
  let first_actual =
    clear(
      broker,
      command.native_origin(offer.reference(first)),
      offer.data(first),
      deadline,
      observed,
    )
  let second_actual =
    clear(
      broker,
      command.native_origin(offer.reference(second)),
      offer.data(second),
      deadline,
      observed,
    )
  assert first_actual.context.operation == operation(2)
  assert first_actual.context.step == "physical:build"
  assert second_actual.deadline_ms == first_actual.deadline_ms
  assert bit_array.byte_size(first_actual.request.token) == 32
  assert first_actual.request.token != second_actual.request.token
  assert first_actual.request.demand == exec.PlatformEnforcement
  let assert Ok(#(_, retained, None)) =
    custodian.command_child(fixture.owner, offer.reference(first))
    as "First parent's exact cleared bytes commit."
  let assert Ok(decoded) = wire.decode_prepared(custody.bytes(retained))
    as "Retained complete Prepared."
  assert decoded.request == first_actual.request
  let assert Ok(#(_, _, None)) =
    custodian.command_child(fixture.owner, offer.reference(second))
    as "Second parent has independent custody under the same Broker."

  // The ordinary lane keeps its previous envelope and the original caller deadline.
  let assert Ok(ordinary) =
    remote_tool.system_child(session_id(1), "fixture", 0)
    as "Explicit ordinary origin."
  let ordinary_data =
    offer.CommandData(["/bin/true"], [], "/executor/work", base())
  let ordinary_actual =
    clear(broker, ordinary, ordinary_data, deadline, observed)
  assert ordinary_actual.deadline_ms == first_actual.deadline_ms
  let assert Ok(#(_, _, None)) = custodian.child(fixture.owner, ordinary)
    as "Ordinary reservation remains available."
  assert process.receive(fenced, 0) == Error(Nil)
  broker.stop(broker)
  process.send(candidates.data, Stop)
  stop(fixture)
}

fn clear(
  broker: broker.Broker,
  origin: remote_tool.ChildOrigin,
  data: offer.CommandData,
  deadline: Int,
  observed: process.Subject(#(dispatch.Dispatch, wire.Prepared)),
) -> dispatch.Dispatch {
  let events = process.new_subject()
  let spec =
    broker.CallSpec(
      operation(2),
      "physical:build",
      base(),
      data.requirements,
      [],
      broker.RefuseNarrowed,
      exec.PlatformEnforcement,
      data.argv,
      data.env,
      data.cwd,
      budget.Budget(3, deadline),
    )
  let assert Ok(_) =
    broker.clear_call_from(broker, origin, spec, events: events, waiting: 2000)
    as "Real original clearance succeeds."
  let assert Ok(#(request, actual)) = process.receive(observed, 2000)
    as "Actual original Dispatch reaches the trusted callback."
  assert actual.request == request.request
  let assert Ok(broker.CallSettled(broker.CallFailed(exec.ExecutionLost(
    exec.RemoteOutcomeUncertain,
  )))) = process.receive(events, 8000)
    as "No physical service is assembled: remote refusal stays uncertain."
  request
}

pub fn one_live_broker_budget_caps_command_parents_before_second_preparation_test() {
  let fixture = new_fixture("budget")
  let first = proposal(0)
  let second = proposal(1)
  retain(fixture, first)
  retain(fixture, second)
  let observed = process.new_subject()
  let fenced = process.new_subject()
  let assert Ok(local) =
    dispatch_binding.new(
      fixture.owner,
      connection(scope()),
      fn(request) {
        let template = prepared(first, offer.data(first).requirements)
        let actual = wire.Prepared(..template, request: request.request)
        process.send(observed, request)
        Ok(actual)
      },
      fn() { request_id(70) },
      poll.monotonic().now,
      17,
      5000,
      fn(error) { process.send(fenced, error) },
    )
    as "One original materializer."
  let assert Ok(config) = dispatch_binding.with_commands(local, enrolled())
    as "Same native reservation callbacks."
  let witness =
    dispatch.Dispatcher(fn(request) {
      let assert Ok(dispatcher.CommandReserved(_, _, _)) =
        config.reserve(request)
        as "Real native command custody precedes the test observation."
      Ok(
        dispatch.Execution(
          dispatch.execution_id(17, request.seq),
          process.self(),
          fn() { Nil },
          fn(_, _) { Nil },
          fn() { Nil },
          fn() { Nil },
        ),
      )
    })
  let assert Ok(broker) =
    broker.start_dispatching(
      token.production_entropy(),
      clock.from_function(poll.monotonic().now),
      witness,
    )
    as "Actual original Broker owns the live pooled credit."
  let events = process.new_subject()
  let data = offer.data(first)
  let deadline = poll.monotonic().now() + 30_000
  let spec =
    broker.CallSpec(
      operation(2),
      "physical:build",
      base(),
      data.requirements,
      [],
      broker.RefuseNarrowed,
      exec.PlatformEnforcement,
      data.argv,
      data.env,
      data.cwd,
      budget.Budget(1, deadline),
    )
  let assert Ok(_) =
    broker.clear_call_from(
      broker,
      command.native_origin(offer.reference(first)),
      spec,
      events: events,
      waiting: 2000,
    )
    as "First live command consumes one credit."
  let assert Ok(request) = process.receive(observed, 1000)
    as "The real cleared Dispatch is retained for explicit settlement."

  // A second parent's wider requested cap cannot replace the live ledger.
  let data = offer.data(second)
  let wider =
    broker.CallSpec(
      ..spec,
      argv: data.argv,
      env: data.env,
      cwd: data.cwd,
      requirements: data.requirements,
      budget: budget.Budget(3, deadline),
    )
  assert broker.clear_call_from(
      broker,
      command.native_origin(offer.reference(second)),
      wider,
      events: events,
      waiting: 2000,
    )
    == Error(broker.BudgetRefused(budget.OutstandingCapReached(1)))
  assert process.receive(observed, 0) == Error(Nil)
  assert custodian.command_child(fixture.owner, offer.reference(second))
    == Error(custody.Missing)
  request.settle(
    dispatch.Failed(exec.ExecutionLost(exec.RemoteOutcomeUncertain)),
  )
  let assert Ok(broker.CallSettled(_)) = process.receive(events, 1000)
    as "Only explicit terminal settlement returns the live credit."
  broker.stop(broker)
  stop(fixture)
}

pub fn prepared_registration_stream_lifetime_and_ordered_env_refuse_test() {
  let fixture = new_fixture("prepared-fields")
  let proposal = proposal(0)
  retain(fixture, proposal)
  let actual = prepared(proposal, offer.data(proposal).requirements)
  let request = dispatch(proposal, actual)
  let assert Ok(registration) = identity.digest(<<0:size(256)>>)
    as "Different valid registration."
  let wrong_registration = wire.Prepared(..actual, registration: registration)
  assert command_binding.reserve(
      binding(fixture, wrong_registration, request_id(40)),
      request,
    )
    == Error(custody.Conflict)
  let wrong_stream = wire.Prepared(..actual, stream: wire.ProtocolStream)
  assert command_binding.reserve(
      binding(fixture, wrong_stream, request_id(40)),
      request,
    )
    == Error(custody.Conflict)
  let infinite = wire.Prepared(..actual, lifetime: wire.Session)
  assert command_binding.reserve(
      binding(fixture, infinite, request_id(40)),
      request,
    )
    == Error(custody.Conflict)
  let too_short = wire.Prepared(..actual, lifetime: wire.Finite(1999))
  assert command_binding.reserve(
      binding(fixture, too_short, request_id(40)),
      request,
    )
    == Error(custody.Conflict)

  // Literal environment order stays exact even when policy sets are normalized.
  let reordered =
    wire.Prepared(
      ..actual,
      request: exec.ExecRequest(
        ..actual.request,
        env: list.reverse(actual.request.env),
      ),
    )
  assert command_binding.reserve(
      binding(fixture, reordered, request_id(40)),
      dispatch(proposal, reordered),
    )
    == Error(custody.Conflict)
  assert custodian.command_child(fixture.owner, offer.reference(proposal))
    == Error(custody.Missing)
  stop(fixture)
}

pub fn retained_body_digest_and_administrative_digest_substitution_refuse_test() {
  let fixture = new_fixture("body-digest")
  let original_key = service(0, command.CompileService)
  let #(scope, operation, step) = command.coordinates(original_key)
  let assert Ok(changed_key) =
    command.service_key(
      parent(0),
      command.CompileService,
      scope,
      operation,
      step,
      command.request_id(original_key),
      string.repeat("d", 64),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Shape-valid different body identity."
  let proposal = proposal_for(changed_key)
  retain(fixture, proposal)
  let actual = prepared(proposal, offer.data(proposal).requirements)
  assert command_binding.reserve(
      binding(fixture, actual, request_id(40)),
      dispatch(proposal, actual),
    )
    == Error(custody.Conflict)
  assert custodian.command_child(fixture.owner, offer.reference(proposal))
    == Error(custody.Missing)
  stop(fixture)

  // A peer's self-consistent template still cannot change enrollment digests.
  let fixture = new_fixture("administrative-digest")
  let #(input_digest, _, contract) = command.digests(original_key)
  let assert Ok(changed_key) =
    command.service_key(
      parent(0),
      command.CompileService,
      scope,
      operation,
      step,
      command.request_id(original_key),
      input_digest,
      string.repeat("d", 64),
      contract,
    )
    as "Different bounded registration."
  let template = proposal_for(original_key)
  let assert Ok(ref) = command.command_ref(changed_key, command.CompileCommand)
    as "Foreign complete reference remains shape-valid."
  let assert Ok(proposal) =
    offer.offer(ref, offer.mappings(template), offer.data(template))
    as "A peer can supply data under a different registration."
  retain(fixture, proposal)
  let actual = prepared(proposal, offer.data(proposal).requirements)
  assert command_binding.reserve(
      binding(fixture, actual, request_id(40)),
      dispatch(proposal, actual),
    )
    == Error(custody.Conflict)
  assert custodian.command_child(fixture.owner, offer.reference(proposal))
    == Error(custody.Missing)
  stop(fixture)
}

pub fn historical_recovery_and_digest_refusal_do_not_prepare_or_mint_test() {
  let fixture = new_fixture("historical")
  let proposal = proposal(0)
  retain(fixture, proposal)
  let actual = prepared(proposal, offer.data(proposal).requirements)
  let live = binding(fixture, actual, request_id(40))
  let assert Ok(dispatcher.CommandReserved(key, _, ref)) =
    command_binding.reserve(live, dispatch(proposal, actual))
    as "Original live reservation."
  let assert Ok(historical) =
    command_binding.new(
      fixture.owner,
      enrolled(),
      scope(),
      fn(_) { panic as "Historical reconciliation cannot prepare." },
      fn() { panic as "Historical reconciliation cannot mint." },
    )
    as "Historical callbacks expose no live recovery method."
  let origin = command.native_origin(ref)
  let assert Ok(wrong) = identity.digest(<<0:size(256)>>)
    as "Different native digest."
  assert command_binding.receive(historical, origin, key, wrong, [], <<
      "terminal":utf8,
    >>)
    == Error(custody.Conflict)
  let assert Ok(#(id, bytes, None)) =
    custodian.command_child(fixture.owner, ref)
    as "Refused digest cannot write terminal custody."
  assert id == request_id(40)
  assert wire.decode_prepared(custody.bytes(bytes)) == Ok(actual)
  assert command_binding.cancel(historical, origin) == Ok(Nil)
  let assert Ok(digest) = wire.prepared_digest(actual)
    as "Original native digest."
  assert command_binding.receive(historical, origin, key, digest, [], <<
      "terminal":utf8,
    >>)
    == Ok(Nil)
  stop(fixture)
}

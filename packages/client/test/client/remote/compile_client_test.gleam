//// Historical owner consumer controls use real SQLite custody and the original
//// Broker. No compiler or TLS exchange is claimed by these offline witnesses.

import broker/broker
import broker/budget
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/policy
import broker/token
import client/remote/compile_client as client
import client/remote/custodian
import codemode/compile
import codemode/identity as phase
import codemode/service_input as input
import codemode/vet
import codemode/vet/policy as vet_policy
import core/clock
import core/command
import core/ids
import core/remote_tool
import core/workspace
import distribution_fixture
import executor
import executor/remote/beam_endpoint
import executor/remote/compile_completion as completion
import executor/remote/compile_wire as protocol
import executor/remote/distribution
import executor/remote/identity
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/time/timestamp
import simplifile
import storage/owner_custody as custody
import weft
import weft/poll
import weft/registry

type Fixture {
  Fixture(owner: custodian.Handle, config: custodian.Config, pid: process.Pid)
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
    "/private/tmp/loom-compile-owner-"
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
      fn(_, _, _) { panic as "No tool body in this custody witness." },
    )
    as "Bounded actor."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config) as "Actual custodian."
  Fixture(owner, config, started.pid)
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

fn endpoint(
  peer: distribution.Peer,
  scope: identity.Scope,
) -> beam_endpoint.Config {
  let fields = identity.scope_fields(scope)
  beam_endpoint.Config(peer, "owner", fields.2, scope, 1, 1000)
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

fn key(index: Int) -> command.ServiceKey {
  let assert Ok(step) = workspace.step("parent:tools")
    as "Original physical Build."
  let assert Ok(value) =
    command.service_key(
      parent(index),
      command.CompileService,
      enrollment.native_facts(enrolled()).scope,
      operation(2),
      step,
      request_id(index + 20),
      hash(input.encode_compile(original())),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Complete original service."
  value
}

fn outer(index: Int) -> remote_tool.ChildOrigin {
  let assert Ok(value) =
    remote_tool.tool_child(parent(index), remote_tool.Compile)
    as "Service custody is Compile, distinct from CompileCommand."
  value
}

fn consumer(
  fixture: Fixture,
  unix: Int,
  peer: distribution.Peer,
) -> #(client.Config, broker.Broker) {
  let assert Ok(original_broker) =
    broker.start_dispatching(
      token.production_entropy(),
      clock.fixed(unix),
      dispatch.Dispatcher(fn(_) {
        panic as "Historical/expired controls never clear a native call."
      }),
    )
    as "One genuine original Broker."
  let facts =
    client.Facts(input.WorkspaceProgram, base(), 180_000, 5000, [], limits())
  let assert Ok(value) =
    client.new(
      fixture.owner,
      enrolled(),
      original_broker,
      endpoint(peer, scope()),
      fn() { panic as "Historical/expired control must never mint." },
      clock.fixed(unix),
      poll.monotonic().now,
      facts,
    )
    as "Exact pinned internal consumer."
  #(value, original_broker)
}

fn retained(fixture: Fixture, index: Int) -> completion.CompileCompletion {
  let original_key = key(index)
  let assert Ok(_) =
    custodian.reserve_service_child(
      fixture.owner,
      original_key,
      input.encode_compile(original()),
    )
    as "Original service commits before any response."
  let assert Ok(value) =
    completion.failed_before_native(
      enrolled(),
      original_key,
      compile.BuildUnavailable("original preparation refused"),
    )
    as "Closed exact before-native result."
  value
}

fn exact_retained_completion_survives_dead_endpoint_without_mint_or_clear(
  peer: distribution.Peer,
) {
  let fixture = new_fixture("historical")
  let value = retained(fixture, 0)
  let assert Ok(bytes) = completion.encode(value) as "Exact closed completion."
  assert custodian.receive_child(
      fixture.owner,
      outer(0),
      command.request_id(key(0)),
      bytes,
    )
    == Ok(Nil)
  let #(config, original_broker) = consumer(fixture, 1000, peer)
  assert client.recover(config, outer(0))
    == Ok(client.Completed(
      key(0),
      completion.compiled(value),
      client.OwnerRetained,
    ))
  broker.stop(original_broker)
  stop(fixture)
}

fn cancelled_then_late_exact_completion_is_accepted_and_conflict_refused(
  peer: distribution.Peer,
) {
  let fixture = new_fixture("late")
  let value = retained(fixture, 0)
  let assert Ok(bytes) = completion.encode(value) as "Original completion."
  assert custodian.cancel_service(fixture.owner, key(0)) == Ok(Nil)
  assert custodian.receive_child(
      fixture.owner,
      outer(0),
      command.request_id(key(0)),
      bytes,
    )
    == Ok(Nil)
  assert custodian.receive_child(
      fixture.owner,
      outer(0),
      command.request_id(key(0)),
      bytes,
    )
    == Ok(Nil)
  assert custodian.receive_child(
      fixture.owner,
      outer(0),
      command.request_id(key(0)),
      <<bytes:bits, 0>>,
    )
    == Error(custody.Conflict)
  let #(config, original_broker) = consumer(fixture, 1000, peer)
  assert client.recover(config, outer(0))
    == Ok(client.Completed(
      key(0),
      completion.compiled(value),
      client.OwnerRetained,
    ))
  broker.stop(original_broker)
  stop(fixture)
}

fn foreign_completion_and_noncanonical_receipt_never_become_compiled(
  peer: distribution.Peer,
) {
  let fixture = new_fixture("foreign")
  let _ = retained(fixture, 0)
  let foreign = retained(fixture, 1)
  let assert Ok(bytes) = completion.encode(foreign)
    as "Valid completion for another full parent."
  assert custodian.receive_child(
      fixture.owner,
      outer(0),
      command.request_id(key(0)),
      bytes,
    )
    == Ok(Nil)
  let #(config, original_broker) = consumer(fixture, 1000, peer)
  let assert Error(client.Invalid(_)) = client.recover(config, outer(0))
    as "Foreign full service completion is refused."
  broker.stop(original_broker)
  stop(fixture)

  // Canonical decoder refuses a trailing byte even in trusted-local raw custody.
  let fixture = new_fixture("noncanonical")
  let value = retained(fixture, 0)
  let assert Ok(bytes) = completion.encode(value) as "Original canonical value."
  assert custodian.receive_child(
      fixture.owner,
      outer(0),
      command.request_id(key(0)),
      <<bytes:bits, 0>>,
    )
    == Ok(Nil)
  let #(config, original_broker) = consumer(fixture, 1000, peer)
  let assert Error(client.Invalid(_)) = client.recover(config, outer(0))
    as "Noncanonical completion is refused."
  broker.stop(original_broker)
  stop(fixture)
}

fn pre_reservation_cancel_fences_compile_origin_not_native_command_origin(
  peer: distribution.Peer,
) {
  let fixture = new_fixture("fence")
  let #(config, original_broker) = consumer(fixture, 1000, peer)
  assert client.cancel(config, outer(0)) == Ok(client.LocalFence)
  assert custodian.reserve_service_child(
      fixture.owner,
      key(0),
      input.encode_compile(original()),
    )
    == Error(custody.Frozen)
  let assert Ok(native) =
    remote_tool.tool_child(parent(0), remote_tool.CompileCommand)
    as "Distinct native role."
  let assert Error(client.Invalid(_)) = client.cancel(config, native)
    as "A native origin cannot fence the outer receipt slot."
  broker.stop(original_broker)
  stop(fixture)
}

fn zero_expired_and_unmanaged_budget_refuse_before_reservation(
  peer: distribution.Peer,
) {
  let fixture = new_fixture("expired")
  let #(config, original_broker) = consumer(fixture, 1000, peer)
  let assert vet.Passed(source) =
    vet.vet("pub fn main() { Nil }\n", vet_policy.default())
    as "Actually vetted owner source."
  let physical = client.service(config)
  let phases = [
    phase.for_managed_execution(parent(0), budget: budget.Budget(8, 0))
      |> phase.build_phase,
    phase.for_managed_execution(parent(0), budget: budget.Budget(8, 1000))
      |> phase.build_phase,
    phase.for_execution(
      operation(2),
      "parent:tools",
      budget: budget.Budget(8, 2000),
    )
      |> phase.build_phase,
  ]
  for_invalid_phases(physical, source, phases)
  assert custodian.child(fixture.owner, outer(0)) == Error(custody.Missing)
  broker.stop(original_broker)
  stop(fixture)
}

fn for_invalid_phases(
  physical: compile.CompileService,
  source: vet.Vetted,
  phases: List(phase.PhaseIdentity),
) -> Nil {
  case phases {
    [] -> Nil
    [first, ..rest] -> {
      let result =
        physical.compile(compile.CompileRequest(
          source,
          compile.default_dependencies(),
          [],
          first,
        ))
      let assert compile.Compiled(Error(compile.BuildUnavailable(_)), _) =
        result
        as "Invalid original lifetime cannot execute."
      for_invalid_phases(physical, source, rest)
    }
  }
}

fn exact_owner_receipt_survives_custodian_reopen(peer: distribution.Peer) {
  let fixture = new_fixture("reopen")
  let value = retained(fixture, 0)
  let assert Ok(bytes) = completion.encode(value) as "Canonical completion."
  assert custodian.receive_child(
      fixture.owner,
      outer(0),
      command.request_id(key(0)),
      bytes,
    )
    == Ok(Nil)
  stop(fixture)
  let assert Ok(started) = custodian.start(fixture.owner, fixture.config)
    as "Same database reopens without execution."
  let reopened = Fixture(..fixture, pid: started.pid)
  let #(config, original_broker) = consumer(reopened, 1000, peer)
  assert client.recover(config, outer(0))
    == Ok(client.Completed(
      key(0),
      completion.compiled(value),
      client.OwnerRetained,
    ))
  broker.stop(original_broker)
  stop(reopened)
}

fn completion_codec_ceiling_refuses_oversized_retained_bytes(
  peer: distribution.Peer,
) {
  let fixture = new_fixture("oversized")
  let _ = retained(fixture, 0)
  let bytes = <<0:size(262_145 * 8)>>
  assert custodian.receive_child(
      fixture.owner,
      outer(0),
      command.request_id(key(0)),
      bytes,
    )
    == Ok(Nil)
  let #(config, original_broker) = consumer(fixture, 1000, peer)
  let assert Error(client.Invalid(_)) = client.recover(config, outer(0))
    as "Historical bytes retain the closed 256 KiB completion ceiling."
  broker.stop(original_broker)
  stop(fixture)
}

// The BEAM operation header preserves the original closed socket bytes. Invalid
// local commands cannot enter an endpoint mailbox or acquire a data credit.

pub fn closed_beam_compile_command_headers_are_exact_and_bounded_test() {
  let assert Ok(digest) = wire.digest(<<"exact retained completion">>)
    as "Actual fixed completion digest."
  let nonce = <<0:size(256)>>
  assert protocol.encode_command(protocol.ChallengeRequest)
    == Ok(<<"LCQ", 1, 0>>)
  assert protocol.encode_command(protocol.Query) == Ok(<<"LCQ", 1, 2>>)
  assert protocol.encode_command(protocol.Cancel) == Ok(<<"LCQ", 1, 3>>)
  assert protocol.decode_command(<<"LCQ", 1, 0>>)
    == Ok(protocol.ChallengeRequest)
  assert protocol.decode_command(<<"LCQ", 1, 2>>) == Ok(protocol.Query)
  assert protocol.decode_command(<<"LCQ", 1, 3>>) == Ok(protocol.Cancel)

  let assert Ok(submit) =
    protocol.encode_command(protocol.Submit(nonce, 86_400_000))
    as "The original finite upper budget is accepted."
  assert bit_array.byte_size(submit) == 41
  assert protocol.decode_command(submit)
    == Ok(protocol.Submit(nonce, 86_400_000))
  let assert Ok(receipt) = protocol.encode_command(protocol.Acknowledge(digest))
    as "Original completion receipt."
  assert protocol.decode_command(receipt) == Ok(protocol.Acknowledge(digest))

  assert protocol.encode_command(protocol.Submit(<<>>, 1))
    == Error(protocol.Invalid)
  assert protocol.encode_command(protocol.Submit(nonce, 0))
    == Error(protocol.Invalid)
  assert protocol.encode_command(protocol.Submit(nonce, 86_400_001))
    == Error(protocol.Invalid)
  assert protocol.decode_command(<<"LCQ", 1, 1, nonce:bits, 0:32>>)
    == Error(protocol.Invalid)
  assert protocol.decode_command(<<"LCQ", 1, 1, nonce:bits, 86_400_001:32>>)
    == Error(protocol.Invalid)
  assert protocol.decode_command(<<"LCQ", 1, 2, 0>>) == Error(protocol.Invalid)
  assert protocol.decode_command(<<"LCQ", 2, 2>>) == Error(protocol.Invalid)
  assert protocol.decode_command(<<"LCQ", 1, 5>>) == Error(protocol.Invalid)
  assert protocol.decode_command(<<"LCQ", 1, 4, 0>>) == Error(protocol.Invalid)
}

// A genuine Peer originates only from successful administrative boot. These
// custody controls need no remote effects, so each isolated TLS owner VM retains
// the configured executor identity without connecting or publishing an endpoint.

/// Boots one fixed custody control inside its own correctly configured TLS VM.
/// The configured executor remains absent, so recovery cannot gain effect authority.
///
/// ## Examples
///
/// ```gleam
/// compile_client_test.run_offline(provisioned_file, 0)
/// // -> Nil after exact retained data survives the absent endpoint.
/// ```
pub fn run_offline(provisioned_path: String, control: Int) -> Nil {
  let assert Ok(fixture) =
    distribution_fixture.read_provisioned(provisioned_path)
    as "Original trusted test provisioning."
  let assert Ok(membership) = distribution.start(fixture.owner_config)
    as "Actual TLS owner boot, without a forged Peer."
  let assert Ok(peer) = distribution.peer(membership, fixture.executor_name)
    as "Peer derives from this successful boot."
  case control {
    0 ->
      exact_retained_completion_survives_dead_endpoint_without_mint_or_clear(
        peer,
      )
    1 ->
      cancelled_then_late_exact_completion_is_accepted_and_conflict_refused(
        peer,
      )
    2 -> foreign_completion_and_noncanonical_receipt_never_become_compiled(peer)
    3 ->
      pre_reservation_cancel_fences_compile_origin_not_native_command_origin(
        peer,
      )
    4 -> zero_expired_and_unmanaged_budget_refuse_before_reservation(peer)
    5 -> exact_owner_receipt_survives_custodian_reopen(peer)
    6 -> completion_codec_ceiling_refuses_oversized_retained_bytes(peer)
    _ -> panic as "Only the fixed offline control vocabulary is admitted."
  }
  io.println("COMPILE_OWNER_OFFLINE_COMPLETE")
}

fn offline_control(control: Int) -> Nil {
  let assert Ok(here) = simplifile.current_directory() as "Original test cwd."
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    here
    <> "/build/compile-owner-beam-offline-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(fixture) =
    distribution_fixture.provision(path, "compile_offline")
    as "Real bounded TLS membership credentials."
  let provisioned = path <> "/fixture.term"
  assert distribution_fixture.write_provisioned(fixture, provisioned) == Ok(Nil)
  let erl = distribution_fixture.current_executable()
  let expression =
    "{ok,_}=application:ensure_all_started(client),'client@remote@compile_client_test':run_offline(<<\""
    <> provisioned
    <> "\">>,"
    <> int.to_string(control)
    <> "),halt(0)."
  let arguments =
    list.append(distribution_fixture.node_arguments(fixture.owner_options), [
      "-noshell",
      "-eval",
      expression,
    ])
  let outcomes =
    weft.new([
      fn() {
        distribution_fixture.run_node(
          erl,
          arguments,
          here,
          distribution.bootstrap_home(fixture.owner_config),
        )
      },
    ])
    |> weft.deadline(30_000)
    |> weft.start
  let assert [weft.Completed(_, #(exit, output))] = outcomes
    as "Independent TLS owner finishes under the finite test deadline."
  io.println(output)
  assert exit == 0
  assert string.contains(output, "COMPILE_OWNER_OFFLINE_COMPLETE")
  assert simplifile.delete(path) == Ok(Nil)
}

pub fn exact_retained_completion_survives_dead_endpoint_without_mint_or_clear_test() {
  offline_control(0)
}

pub fn cancelled_then_late_exact_completion_is_accepted_and_conflict_refused_test() {
  offline_control(1)
}

pub fn foreign_completion_and_noncanonical_receipt_never_become_compiled_test() {
  offline_control(2)
}

pub fn pre_reservation_cancel_fences_compile_origin_not_native_command_origin_test() {
  offline_control(3)
}

pub fn zero_expired_and_unmanaged_budget_refuse_before_reservation_test() {
  offline_control(4)
}

pub fn exact_owner_receipt_survives_custodian_reopen_test() {
  offline_control(5)
}

pub fn completion_codec_ceiling_refuses_oversized_retained_bytes_test() {
  offline_control(6)
}

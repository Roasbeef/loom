//// Registered owner wiring exercises the actual serialized custodian and SQLite.
//// No test hands the actor a token obtained from another custody connection.
//// Private TLS membership exercises normal dispatch callbacks without an executor.
//// Existing pure allocation fixtures use WorkspaceSystem; separate staged controls
//// below use actual Broker clearance and retain original native envelopes.

import broker/broker
import broker/budget
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/policy
import client/remote/custodian
import client/remote/dispatch_binding
import client/remote/native_envelope
import client/remote/tool_custody
import client/remote/workspace_binding
import core/clock
import core/command
import core/generation
import core/ids
import core/json
import core/message
import core/remote_tool
import core/workspace
import executor
import executor/remote/beam_endpoint as connection
import executor/remote/dispatcher
import executor/remote/distribution
import executor/remote/identity
import executor/remote/registration
import executor/remote/wire
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import machine/operation as operations
import runtime/effects
import simplifile
import sqlight
import storage/owner_custody as custody
import support/beam_owner_fixture
import tools/workspace as semantic
import weft/poll
import weft/registry

type Fixture {
  Fixture(
    path: String,
    owner: custodian.Handle,
    config: custodian.Config,
    pid: process.Pid,
  )
}

pub fn original_actor_admits_all_registered_families_and_reopen_is_history_test() {
  let f = fixture("families", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "Only original committed generation grants readiness."
  let #(original_owner, retained_pin, associated) =
    custodian.registered_fields(ready)
  assert retained_pin == pin()
  assert associated == association(1)
  let input = invocation(0)
  assert invoke(f, 0) == Ok(final())
  assert custodian.tool_generation(original_owner, input.key) == Ok(associated)
  let native = child(0, remote_tool.Launch)
  assert custodian.reserve_child(original_owner, native, id(10), <<"native">>)
    == Ok(#(id(10), <<"native">>))
  assert custodian.reserve_child(original_owner, native, id(11), <<"native">>)
    == Ok(#(id(10), <<"native">>))
  assert custodian.child_generation(original_owner, native) == Ok(associated)
  let workspace_child = child(0, remote_tool.Workspace(1))
  assert custodian.reserve_workspace_child(
      original_owner,
      workspace_child,
      id(12),
      <<"workspace">>,
    )
    == Ok(Nil)
  assert custodian.child_generation(original_owner, workspace_child)
    == Ok(associated)
  assert custodian.receive_workspace_child(
      original_owner,
      workspace_child,
      id(12),
      <<"workspace terminal">>,
    )
    == Ok(Nil)
  assert custodian.receipt_generation(original_owner, workspace_child, id(12))
    == Ok(#(<<"workspace terminal">>, associated))
  let service = service(input.key)
  let assert Ok(request) =
    custodian.reserve_service_child(original_owner, service, <<"service">>)
    as "Service and its original generation commit together."
  assert custodian.service_generation(original_owner, service) == Ok(associated)
  let offer = offer(service)
  assert custodian.admit_offer(original_owner, request, offer)
    == Ok(custody.Fresh)
  let assert Ok(#(native_id, _)) =
    custodian.reserve_command_child(original_owner, offer, id(13), <<
      "native command",
    >>)
    as "Command admission retains the service's original generation."
  let assert Ok(ref) = command.command_ref(service, command.CompileCommand)
    as "Compile has its closed command kind."
  let command_origin = command.native_origin(ref)
  assert custodian.child_generation(original_owner, command_origin)
    == Ok(associated)
  assert custodian.receive_child(original_owner, command_origin, native_id, <<
      "command terminal",
    >>)
    == Ok(Nil)
  assert custodian.receipt_generation(original_owner, command_origin, native_id)
    == Ok(#(<<"command terminal">>, associated))
  assert custodian.receipt_generation(original_owner, command_origin, id(14))
    == Error(custody.Conflict)
  let intent = retained_intent(original_owner, "original startup", id(20))
  let assert Ok(system) =
    custodian.admit_system_child(original_owner, intent, system_payload)
    as "The custodian allocates original system ordinal and generation atomically."
  assert system.admission == custody.Fresh
  assert custodian.child_generation(original_owner, system.origin)
    == Ok(associated)
  let pending = retained_intent(original_owner, "pending startup", id(21))
  stop(f)
  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "The same address reopens only after original SQLite owner closes."
  let history = Fixture(..f, pid: started.pid)
  assert custodian.registered(history.owner)
    == Ok(custodian.HistoryOnly(retained_pin, associated))
  assert custodian.tool_generation(history.owner, input.key) == Ok(associated)
  assert custodian.reserve_child(history.owner, native, id(10), <<"native">>)
    == Error(custody.Frozen)
  assert custodian.reserve_workspace_child(
      history.owner,
      child(0, remote_tool.Workspace(2)),
      id(22),
      <<"new">>,
    )
    == Error(custody.Frozen)
  assert custodian.reserve_service_child(history.owner, service, <<"service">>)
    == Error(custody.Frozen)
  assert custodian.admit_offer(history.owner, request, offer)
    == Error(custody.Frozen)
  assert custodian.reserve_command_child(history.owner, offer, id(13), <<
      "native command",
    >>)
    == Error(custody.Frozen)
  let assert Error(_) = invoke(history, 1) as "History cannot run a fresh tool."
  let exact_intent = retained_intent(history.owner, "original startup", id(20))
  let assert Ok(recovered) =
    custodian.admit_system_child(history.owner, exact_intent, system_payload)
    as "Historical observation retains the exact original ordinal."
  assert recovered.admission == custody.Retained
  assert recovered.origin == system.origin
  assert custodian.admit_system_child(history.owner, pending, system_payload)
    == Error(custody.Frozen)
  let assert Error(_) =
    custodian.retain_system_intent(
      history.owner,
      "new startup",
      custody.WorktreeObservation,
      operation(),
      "startup",
      id(23),
      <<"intent">>,
    )
    as "Historical inspection never inserts a fresh pending intent."
  assert custodian.receipt_generation(history.owner, command_origin, native_id)
    == Ok(#(<<"command terminal">>, associated))
  assert custodian.reserve_child(original_owner, native, id(10), <<"native">>)
    == Error(custody.Unavailable("owner ask failed"))
  stop(history)
  assert scalar(
      f.path,
      "SELECT next_ordinal FROM owner_system_ordinal WHERE service='worktree-observation'",
    )
    == 1
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_tool_generation") == 1
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_child_generation") == 5
}

pub fn registered_dispatch_captures_original_actor_and_receipt_before_ack_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "registered_dispatch_captures_original_actor_and_receipt_before_ack_test",
  )
  let f = fixture("dispatch", fn(_, _, _) { final() })
  assert invoke(f, 0) == Ok(final())
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "Original registered readiness precedes binding."
  let config = dispatch_configuration(ready, peer, 1)
  let origin = child(0, remote_tool.Compile)
  let prepared = prepared()
  let request =
    dispatch.Dispatch(
      None,
      dispatch.CallContext(operation(), prepared.step, Some(origin)),
      prepared.request,
      11,
      6000,
      clock.fixed(1000),
      None,
      fn(_) { Nil },
      fn(_) { Nil },
    )
  let assert Ok(reserved) = config.reserve(request)
    as "Normal registered binding commits the closed native envelope."
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "Original prepared digest."
  let outputs = [<<0, 255>>, <<1, 128>>]
  let terminal = <<0, 2, 255>>
  assert config.receive(origin, reserved.key, digest, outputs, terminal)
    == Ok(Nil)
  let assert Ok(receipt) = custodian.receipt(outputs, terminal)
    as "Original ordered native receipt."
  assert custodian.receipt_generation(f.owner, origin, id(30))
    == Ok(#(receipt, association(1)))
  assert config.receive(origin, reserved.key, digest, outputs, <<3>>)
    == Error(Nil)
  let assert Error(custody.Conflict) = registered_binding(ready, peer, 2)
    as "Changed generation cannot rebind original readiness."
  stop(f)
  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "Recovery remains on a different pinned actor."
  assert custodian.registered(f.owner)
    == Ok(custodian.HistoryOnly(pin(), association(1)))
  assert config.reserve(request) == Error(Nil)
  assert config.receive(origin, reserved.key, digest, outputs, terminal)
    == Error(Nil)
  assert custodian.receipt_generation(f.owner, origin, id(30))
    == Ok(#(receipt, association(1)))
  stop(Fixture(..f, pid: started.pid))
}

pub fn original_association_and_existing_unpinned_companion_refuse_adoption_test() {
  let f = fixture("changed-owner", fn(_, _, _) { final() })
  stop(f)
  let assert Ok(changed) =
    custodian.with_registered(f.config, pin(), association(2), 1)
    as "Changed owner-use is structurally valid configuration."
  let assert Ok(names) = registry.start() as "Separate address registry."
  let owner = custodian.new(names, changed)
  let assert Error(_) = custodian.start(owner, changed)
    as "Existing association cannot acquire a replacement owner-use token."
  let assert Error(_) = custodian.start(f.owner, changed)
    as "An existing handle refuses changed placement before opening."
  let pin = pin()
  let #(session, binding, descriptor, digest, bytes) =
    custody.enrollment_fields(pin)
  let assert Ok(wrong_pin) =
    custody.enrollment_pin(session, binding, descriptor, digest, <<
      bytes:bits,
      0,
    >>)
    as "Wrong bytes have otherwise original metadata."
  assert custodian.with_registered(f.config, wrong_pin, association(1), 1)
    == Error(custody.Conflict)
  assert custodian.with_registered(f.config, pin, association(1), 0)
    == Error(custody.Conflict)
  let path = directory("unpinned") <> "/owner.db"
  let assert Ok(local) = custody.open(path, session, limits())
    as "An existing ordinary companion has no registered pin."
  assert custody.close(local) == Ok(Nil)
  let config = configuration(path, fn(_, _, _) { final() })
  let owner = custodian.new(names, config)
  let assert Error(_) = custodian.start(owner, config)
    as "Existing unpinned metadata is never adopted as fresh registered custody."
}

pub fn original_handle_refuses_changed_companion_before_open_test() {
  let f = fixture("immutable-door", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(_)) = custodian.registered(f.owner)
    as "Original pin and association commit through the real custodian."
  stop(f)
  let assert Ok(original_bytes) = simplifile.read_bits(f.path)
    as "Closed original companion bytes provide unchanged-store evidence."
  let replacement_path = directory("replacement-door") <> "/owner.db"
  let changed = configuration(replacement_path, fn(_, _, _) { final() })
  let assert Error(_) = custodian.start(f.owner, changed)
    as "Same association on a different empty path cannot replace the original door."
  assert simplifile.exists(replacement_path, False) == Ok(False)
  assert simplifile.read_bits(f.path) == Ok(original_bytes)
  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "Only the original companion reopens for retained history."
  assert custodian.registered(f.owner)
    == Ok(custodian.HistoryOnly(pin(), association(1)))
  stop(Fixture(..f, pid: started.pid))
}

pub fn suppressed_link_rolls_back_actual_custodian_admission_test() {
  let f = fixture("rollback", fn(_, _, _) { final() })
  mutate(
    f.path,
    "CREATE TRIGGER suppress_tool_link BEFORE INSERT ON owner_tool_generation BEGIN SELECT RAISE(IGNORE); END",
  )
  let assert Error(_) = invoke(f, 0)
    as "No runner starts without the original generation link."
  assert custodian.tool_generation(f.owner, invocation(0).key)
    == Error(custody.Missing)
  mutate(f.path, "DROP TRIGGER suppress_tool_link")
  assert invoke(f, 0) == Ok(final())
  mutate(
    f.path,
    "CREATE TRIGGER fail_child_link BEFORE INSERT ON owner_child_generation BEGIN SELECT RAISE(ABORT, 'fixture link failure'); END",
  )
  let origin = child(0, remote_tool.Compile)
  assert custodian.reserve_child(f.owner, origin, id(10), <<"request">>)
    == Error(custody.Conflict)
  assert custodian.child(f.owner, origin) == Error(custody.Missing)
  mutate(f.path, "DROP TRIGGER fail_child_link")
  assert custodian.reserve_child(f.owner, origin, id(10), <<"request">>)
    == Ok(#(id(10), <<"request">>))
  mutate(
    f.path,
    "CREATE TRIGGER suppress_receipt BEFORE UPDATE OF terminal ON owner_custody_children BEGIN SELECT RAISE(IGNORE); END",
  )
  let assert Error(_) =
    custodian.receive_child(f.owner, origin, id(10), <<"terminal">>)
    as "COMMIT without exact terminal readback cannot produce ACK."
  assert custodian.receipt_generation(f.owner, origin, id(10))
    == Error(custody.Missing)
  stop(f)
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_tools") == 1
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_tool_generation") == 1
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_children") == 1
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_child_generation") == 1
}

pub fn cancelled_waiting_caller_does_not_cancel_original_admitted_writer_test() {
  let entered = process.new_subject()
  let f =
    fixture("cancelled-caller", fn(owner, key, _) {
      let release = process.new_subject()
      process.send(entered, #(owner, key, release))
      let assert Ok(Nil) = process.receive(release, 2000)
        as "Test releases the original admitted worker."
      let assert Ok(origin) = remote_tool.tool_child(key, remote_tool.Compile)
        as "Original runner retains complete ToolKey."
      assert custodian.reserve_child(owner, origin, id(10), <<"request">>)
        == Ok(#(id(10), <<"request">>))
      assert custodian.receive_child(owner, origin, id(10), <<"terminal">>)
        == Ok(Nil)
      final()
    })
  let caller =
    process.spawn_unlinked(fn() {
      let _result = invoke(f, 0)
      Nil
    })
  let assert Ok(#(original, key, release)) = process.receive(entered, 1000)
    as "Original SQLite admission precedes caller cancellation."
  let watched = process.monitor(caller)
  process.kill(caller)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watched, fn(down) { down })
    |> process.selector_receive(1000)
    as "The waiting caller is dead before original writer completes."
  process.send(release, Nil)
  let origin = child(0, remote_tool.Compile)
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case custodian.receipt_generation(original, origin, id(10)) {
        Ok(#(<<"terminal">>, _)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "Caller death cannot cancel the already admitted custodian writer."
  assert custodian.tool_generation(original, key) == Ok(association(1))
  stop(f)
}

pub fn committed_association_survives_owner_crash_without_fresh_claim_test() {
  let f = fixture("lost-ready", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(_)) = custodian.registered(f.owner)
    as "Actual pin and association COMMIT precede the lost owner lifetime."
  let watched = process.monitor(f.pid)
  process.unlink(f.pid)
  process.kill(f.pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watched, fn(down) { down })
    |> process.selector_receive(2000)
    as "Original owner death precedes reopen."
  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "SQLite retains the original generation after an unclean death."
  assert custodian.registered(f.owner)
    == Ok(custodian.HistoryOnly(pin(), association(1)))
  let assert Error(_) = invoke(f, 0)
    as "Lost live readiness never recreates fresh execution authority."
  stop(Fixture(..f, pid: started.pid))
  mutate(f.path, "UPDATE owner_custody_enrollment SET enrollment_bytes = X'00'")
  let assert Error(_) = custodian.start(f.owner, f.config)
    as "Changed retained enrollment refuses before actor publication."
}

pub fn fenced_original_owner_has_receipts_but_no_fresh_reservations_test() {
  let f = fixture("fenced-original", fn(_, _, _) { final() })
  assert invoke(f, 0) == Ok(final())
  let origin = child(0, remote_tool.Launch)
  assert custodian.reserve_child(f.owner, origin, id(10), <<"native">>)
    == Ok(#(id(10), <<"native">>))
  let intent = retained_intent(f.owner, "allocated", id(20))
  let assert Ok(original) =
    custodian.admit_system_child(f.owner, intent, system_payload)
    as "Original live context allocates once."
  let pending = retained_intent(f.owner, "pending", id(21))
  let _fenced = custodian.fatal_fence(f.owner, invocation(0).key)
  assert custodian.registered(f.owner) == Error(custody.Frozen)
  assert custodian.reserve_child(f.owner, origin, id(10), <<"native">>)
    == Error(custody.Frozen)
  assert custodian.reserve_workspace_child(
      f.owner,
      child(0, remote_tool.Workspace(1)),
      id(11),
      <<"workspace">>,
    )
    == Error(custody.Frozen)
  assert custodian.reserve_service_child(f.owner, service(invocation(0).key), <<
      "service",
    >>)
    == Error(custody.Frozen)
  assert custodian.admit_system_child(f.owner, pending, system_payload)
    == Error(custody.Frozen)
  let assert Error(_) =
    custodian.retain_system_intent(
      f.owner,
      "fresh",
      custody.WorktreeObservation,
      operation(),
      "startup",
      id(22),
      <<"intent">>,
    )
    as "Fenced original context cannot insert pending work."
  let assert Ok(retained) =
    custodian.admit_system_child(f.owner, intent, system_payload)
    as "Exact original system observation survives fencing."
  assert retained.admission == custody.Retained
  assert retained.origin == original.origin
  assert custodian.receive_child(f.owner, origin, id(10), <<"late terminal">>)
    == Ok(Nil)
  assert custodian.receipt_generation(f.owner, origin, id(10))
    == Ok(#(<<"late terminal">>, association(1)))
  stop(f)
  assert scalar(
      f.path,
      "SELECT next_ordinal FROM owner_system_ordinal WHERE service='worktree-observation'",
    )
    == 1
}

pub fn ordinary_constructor_has_no_registered_system_authority_test() {
  let path = directory("ordinary") <> "/owner.db"
  let assert Ok(config) =
    custodian.config(path, session(), limits(), 1, 5000, fn(_, _, _) { final() })
    as "Existing ordinary configuration preserves local behavior."
  let assert Ok(names) = registry.start() as "Original ordinary registry."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config)
    as "Ordinary owner remains usable."
  let f = Fixture(path, owner, config, started.pid)
  let assert Error(_) = custodian.registered(owner)
    as "Local configuration grants no registered context."
  let assert Error(_) =
    custodian.retain_system_intent(
      owner,
      "startup",
      custody.WorktreeObservation,
      operation(),
      "startup",
      id(1),
      <<"intent">>,
    )
    as "No effect or ordinal exists without registered original custody."
  assert invoke(f, 0) == Ok(final())
  assert custodian.tool_generation(owner, invocation(0).key)
    == Error(custody.Missing)
  stop(f)
  assert scalar(path, "SELECT COUNT(*) FROM owner_generation_associations") == 0
  assert scalar(path, "SELECT COUNT(*) FROM owner_system_intent") == 0
  let relocated_path = directory("ordinary-relocated") <> "/owner.db"
  let assert Ok(relocated) =
    custodian.config(relocated_path, session(), limits(), 1, 5000, fn(_, _, _) {
      final()
    })
    as "An ordinary config retains its existing start compatibility."
  let assert Ok(started) = custodian.start(owner, relocated)
    as "The registered-only path invariant does not change ordinary start."
  let relocated = Fixture(relocated_path, owner, relocated, started.pid)
  assert invoke(relocated, 0) == Ok(final())
  stop(relocated)
}

fn session() -> ids.SessionId {
  ids.mint_session(ids.generator(clock.fixed(1000), 77)).0
}

fn operation() -> ids.OpId {
  ids.mint_op(ids.generator(clock.fixed(1000), 77)).0
}

fn id(seed: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1001), seed)).0
}

fn limits() -> custody.Limits {
  let assert Ok(value) = custody.limits(8, 64, 268_435_456, 2_097_152)
    as "Finite fixture reserves all family allowances."
  value
}

fn run(index: Int) -> effects.ToolRun {
  let arguments = json.Object([])
  effects.ToolRun(
    operation(),
    "registered",
    index,
    id(100 + index),
    "main",
    message.ToolCall("call", "tool", arguments, None, None),
    arguments,
    operations.ReplayNever,
    [],
  )
}

fn final() -> effects.ToolOutcome {
  effects.ToolCompleted(
    message.ToolResultMessage(
      "call",
      "tool",
      [message.ToolResultText("ok", None)],
      None,
      None,
      None,
      False,
      1000,
    ),
    False,
  )
}

fn invocation(index: Int) -> tool_custody.Invocation {
  let assert Ok(value) =
    tool_custody.invocation(session(), <<"scope">>, run(index))
    as "Production invocation retains original identity."
  value
}

fn invoke(
  f: Fixture,
  index: Int,
) -> Result(effects.ToolOutcome, custody.Error) {
  let input = invocation(index)
  custodian.execute(
    f.owner,
    input.key,
    input.arguments,
    input.request,
    run(index),
  )
}

fn child(index: Int, kind: remote_tool.ChildRole) -> remote_tool.ChildOrigin {
  let assert Ok(value) = remote_tool.tool_child(invocation(index).key, kind)
    as "Original child belongs to admitted ToolKey."
  value
}

fn scope() -> workspace.Scope {
  let assert Ok(value) =
    workspace.scope_from_fields(
      ids.session_id_to_string(session()),
      "project-a",
      "exec-a",
      1,
      1,
    )
    as "Original administrative scope."
  value
}

fn identity_scope() -> identity.Scope {
  let assert Ok(executor) = identity.executor_id("exec-a") as "Executor label."
  let assert Ok(workspace) = identity.workspace_id("project-a")
    as "Workspace label."
  let assert Ok(epoch) = identity.epoch(1) as "Positive original epoch."
  identity.scope(session(), workspace, executor, epoch, epoch)
}

fn pin() -> custody.EnrollmentPin {
  let roots = ["/work", "/build", "/channel"]
  let base = policy.workspace_default("/work")
  let ceiling =
    policy.SandboxPolicy(
      ..base,
      writable_roots: roots,
      readable_roots: ["/tools", "/seed"],
      protected: [],
      mounts: [],
    )
  let native =
    enrollment.NativeFacts(scope(), roots, ceiling, exec.FullEnforcement)
  let code =
    enrollment.CodeModeFacts(
      "/work",
      "/build",
      "/channel",
      "/tools/gleam",
      "/tools/erl",
      "/seed",
      ["/tools"],
      [],
      "/tools",
    )
  let assert Ok(registered) =
    registration.new(identity_scope(), roots, ceiling, exec.FullEnforcement, Ok)
    as "Native registration validates actual facts."
  let registration_digest =
    identity.digest_bytes(registration.digest(registered))
    |> bit_array.base16_encode
    |> string.lowercase
  let assert Ok(enrolled) =
    enrollment.new(native, code, registration_digest, string.repeat("4", 64))
    as "Immutable enrollment validates."
  let assert Ok(bytes) = enrollment.encode(enrolled) as "Canonical enrollment."
  let assert Ok(descriptor) = generation.digest(<<2:size(256)>>)
    as "Descriptor width."
  let assert Ok(digest) = generation.digest(bootstrap.sha256(bytes))
    as "Actual SHA-256."
  let #(_, binding) = workspace.scope_fields(scope())
  let assert Ok(value) =
    custody.enrollment_pin(session(), binding, descriptor, digest, bytes)
    as "Complete immutable pin."
  value
}

fn association(owner_seed: Int) -> generation.GenerationAssociation {
  let #(_, _, descriptor, digest, _) = custody.enrollment_fields(pin())
  let assert Ok(key) = generation.key(scope(), descriptor, 1)
    as "Original generation."
  generation.association(
    key,
    digest,
    id(owner_seed),
    generation.FirstGeneration,
  )
}

fn directory(name: String) -> String {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let value =
    "/private/tmp/loc/"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(value) == Ok(Nil)
  value
}

fn configuration(
  path: String,
  runner: fn(custodian.Handle, remote_tool.ToolKey, effects.ToolRun) ->
    effects.ToolOutcome,
) -> custodian.Config {
  let assert Ok(config) =
    custodian.config_with_reports(
      path,
      session(),
      limits(),
      1,
      5000,
      runner,
      bootstrap.sha256,
    )
    as "Finite trusted owner configuration."
  let assert Ok(config) =
    custodian.with_registered(config, pin(), association(1), 1)
    as "Configuration grants no live token."
  config
}

fn fixture(
  name: String,
  runner: fn(custodian.Handle, remote_tool.ToolKey, effects.ToolRun) ->
    effects.ToolOutcome,
) -> Fixture {
  let path = directory(name) <> "/owner.db"
  let config = configuration(path, runner)
  let assert Ok(names) = registry.start() as "Original address registry."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config)
    as "Original custodian owns pin and generation connection."
  Fixture(path, owner, config, started.pid)
}

fn stop(f: Fixture) -> Nil {
  let monitor = process.monitor(f.pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "Original connection closes before reopen."
  Nil
}

fn service(parent: remote_tool.ToolKey) -> command.ServiceKey {
  let assert Ok(step) = workspace.step("compile:physical")
    as "Explicit physical service step."
  let assert Ok(value) =
    command.service_key(
      parent,
      command.CompileService,
      scope(),
      remote_tool.operation(parent),
      step,
      id(40),
      string.repeat("a", 64),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Complete service identity."
  value
}

fn offer(service: command.ServiceKey) -> custody.CommandOfferPayload {
  let assert Ok(ref) = command.command_ref(service, command.CompileCommand)
    as "Closed service/native command pair."
  let assert Ok(value) =
    custody.command_offer_payload(limits(), ref, string.repeat("d", 64), <<
      "command",
    >>)
    as "Bounded complete offer."
  value
}

fn retained_intent(
  owner: custodian.Handle,
  address: String,
  request_id: ids.EntryId,
) -> custody.IntentReadback {
  let assert Ok(value) =
    custodian.retain_system_intent(
      owner,
      address,
      custody.WorktreeObservation,
      operation(),
      "startup",
      request_id,
      <<"intent">>,
    )
    as "Stable work address retains exact immutable intent."
  value
}

fn system_payload(
  origin: remote_tool.ChildOrigin,
  request_id: ids.EntryId,
) -> Result(custody.SystemReservationPayload, custody.Error) {
  let bytes =
    bit_array.from_string(
      remote_tool.child_address(origin) <> ids.entry_id_to_string(request_id),
    )
  let assert Ok(payload) = custody.workspace_request(limits(), bytes)
    as "Exact original system envelope fits."
  Ok(custody.WorkspaceSystem(payload))
}

fn prepared() -> wire.Prepared {
  let assert Ok(digest) = identity.digest(<<7:size(256)>>)
    as "Actual native digest width."
  wire.Prepared(
    "physical:compile",
    digest,
    wire.Finite(5000),
    exec.ExecRequest(
      ["/bin/sh", "-c", "printf exact"],
      [#("LANG", "C")],
      "/executor/checkout",
      Some(executor.base_policy("/executor/checkout")),
      <<9:size(256)>>,
      exec.PlatformEnforcement,
    ),
    wire.Logs,
  )
}

fn registered_binding(
  ready: custodian.RegisteredOwner,
  peer: distribution.Peer,
  number: Int,
) -> Result(dispatch_binding.Binding, custody.Error) {
  dispatch_binding.new_registered(
    ready,
    connection.Config(peer, "owner", "exec-a", identity_scope(), number, 1000),
    fn(_) { Ok(prepared()) },
    fn() { id(30) },
    poll.monotonic().now,
    17,
    5000,
    fn(_) { Nil },
  )
}

fn dispatch_configuration(
  ready: custodian.RegisteredOwner,
  peer: distribution.Peer,
  number: Int,
) -> dispatcher.Config {
  let assert Ok(binding) = registered_binding(ready, peer, number)
    as "Exact original ready bundle creates dispatch binding."
  dispatch_binding.configuration(binding)
}

fn mutate(path: String, statement: String) -> Nil {
  let assert Ok(db) = sqlight.open(path)
    as "Test-only SQL fault injector, never a second custody Store."
  assert sqlight.exec(statement, db) == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
}

fn scalar(path: String, statement: String) -> Int {
  let assert Ok(db) = sqlight.open(path)
    as "Inspection after original custodian closes."
  let assert Ok([value]) =
    sqlight.query(statement, db, [], decode.at([0], decode.int))
    as "One bounded scalar."
  assert sqlight.close(db) == Ok(Nil)
  value
}

pub fn actual_broker_clearance_consumes_original_system_permission_once_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "actual_broker_clearance_consumes_original_system_permission_once_test",
  )
  let f = fixture("native-system-broker", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "The original SQLite actor supplies ready custody."
  let #(owner, _, _) = custodian.registered_fields(ready)
  let events = process.new_subject()
  let declared = native_declaration()
  let intent =
    retained_intent(owner, "synthetic retained check occurrence", id(90))
  let assert Ok(custodian.SystemPermission(ref)) =
    custodian.allocate_system_reservation(owner, intent, declared, events)
    as "Only the actual Fresh allocation installs a live ref."
  let config = system_configuration(ready, peer)
  let calls = process.new_subject()
  let assert Ok(broker) =
    broker.start_dispatching(
      entropy: fn(size) { bit_array.from_string(string.repeat("x", size)) },
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(actual) {
        let reserved = config.reserve(actual)
        process.send(calls, #(actual, reserved))
        Error(dispatch.NotStarted)
      }),
    )
    as "The real Broker performs policy, budget and token clearance."
  assert broker.clear_system_call_from(
      broker,
      ref,
      native_spec(),
      events: events,
      waiting: 5000,
    )
    == Error(broker.BrokerUnavailable)
  let assert Ok(#(actual, Ok(reserved))) = process.receive(calls, 5000)
    as "The actual static binding commits the Broker-cleared envelope; this control deliberately submits no native effect."
  assert actual.system_reservation == Some(ref)
  let #(_, _, origin, uuid) = dispatch.system_reservation_fields(ref)
  assert actual.context.origin == Some(origin)
  assert actual.caller == Some(process.self())
  assert actual.deadline_ms == declared.deadline_ms
  assert reserved.prepared.request == actual.request
  assert bit_array.byte_size(actual.request.token) == 32
  assert config.reserve(actual) == Error(Nil)
  assert custodian.allocate_system_reservation(owner, intent, declared, events)
    == Ok(custodian.SystemObservation(origin, uuid, custody.NativeAdmitted))
  let assert Ok(stored) = custodian.child(owner, origin)
    as "Complete exact native bytes are readable as history."
  let assert Ok(decoded) =
    native_envelope.decode_cleared("owner", identity_scope(), stored.1)
    as "Original absolute deadline is retained beside complete actual Prepared."
  assert decoded
    == #(actual.context.operation, reserved.prepared, declared.deadline_ms)
  assert dispatch.cancel_system(ref, 5000) == Ok(Nil)
  assert dispatch.cancel_system(ref, 5000) == Ok(Nil)
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "Native receipt matches the actual complete materialization."
  assert config.receive(origin, reserved.key, digest, [<<"late output">>], <<
      "late terminal",
    >>)
    == Ok(Nil)
  assert custodian.receipt_generation(owner, origin, uuid) |> result.is_ok
  broker.stop(broker)
  stop(f)
  assert scalar(f.path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_children") == 1
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM owner_custody_children WHERE state='cancelled'",
    )
    == 1
}

pub fn altered_actual_clearance_consumes_permission_even_on_refusal_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "altered_actual_clearance_consumes_permission_even_on_refusal_test",
  )
  let f = fixture("native-system-altered", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "Original ready owner."
  let #(owner, _, _) = custodian.registered_fields(ready)
  let events = process.new_subject()
  let intent =
    retained_intent(owner, "synthetic altered declaration control", id(90))
  let assert Ok(custodian.SystemPermission(ref)) =
    custodian.allocate_system_reservation(
      owner,
      intent,
      native_declaration(),
      events,
    )
    as "Original Fresh allocation."
  let #(_, _, origin, _) = dispatch.system_reservation_fields(ref)
  let config = system_configuration(ready, peer)
  let actual = system_dispatch(ref, origin)
  assert config.reserve(dispatch.Dispatch(..actual, caller: Some(f.pid)))
    == Error(Nil)
  assert config.reserve(actual) == Error(Nil)
  assert custodian.child(owner, origin) == Error(custody.Missing)
  assert dispatch.cancel_system(ref, 5000) == Ok(Nil)
  assert config.reserve(actual) == Error(Nil)
  stop(f)
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM owner_system_intent WHERE child_profile='native_cancelled'",
    )
    == 1
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(f.path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
}

pub fn original_ref_cancel_and_owner_fence_never_recreate_permission_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "original_ref_cancel_and_owner_fence_never_recreate_permission_test",
  )
  let f = fixture("native-system-fence", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "Original ready owner."
  let #(owner, _, _) = custodian.registered_fields(ready)
  let events = process.new_subject()
  let intent =
    retained_intent(owner, "synthetic cancelled declaration control", id(90))
  let assert Ok(custodian.SystemPermission(ref)) =
    custodian.allocate_system_reservation(
      owner,
      intent,
      native_declaration(),
      events,
    )
    as "Original Fresh allocation."
  let #(subject, _, origin, uuid) = dispatch.system_reservation_fields(ref)
  let forged =
    dispatch.system_reservation_ref(subject, reference.new(), origin, uuid)
  assert dispatch.cancel_system(forged, 5000) == Error(Nil)
  assert dispatch.cancel_system(ref, 5000) == Ok(Nil)
  let config = system_configuration(ready, peer)
  assert config.reserve(system_dispatch(ref, origin)) == Error(Nil)
  let later =
    retained_intent(owner, "synthetic fenced declaration control", id(91))
  let assert Ok(custodian.SystemPermission(later_ref)) =
    custodian.allocate_system_reservation(
      owner,
      later,
      native_declaration(),
      events,
    )
    as "Another original retained occurrence has independent custody."
  let #(_, _, later_origin, _) = dispatch.system_reservation_fields(later_ref)
  assert custodian.fatal_fence(owner, invocation(0).key)
    == Error(custody.Missing)
  assert config.reserve(system_dispatch(later_ref, later_origin)) == Error(Nil)
  assert dispatch.cancel_system(later_ref, 5000) == Ok(Nil)
  stop(f)
  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "Reboot opens history with an empty live permission inventory."
  assert config.reserve(system_dispatch(later_ref, later_origin)) == Error(Nil)
  assert dispatch.cancel_system(later_ref, 100) == Error(Nil)
  stop(Fixture(..f, pid: started.pid))
  assert scalar(f.path, "SELECT next_ordinal FROM owner_system_ordinal") == 2
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_children") == 0
}

fn native_declaration() -> dispatch.SystemCommandDeclaration {
  dispatch.SystemCommandDeclaration(
    "owner",
    operation(),
    "startup",
    ["/tools/git", "status", "--porcelain"],
    [#("PATH", "/tools")],
    "/work",
    11_000,
  )
}

fn native_spec() -> broker.CallSpec {
  let assert Ok(enrolled) =
    enrollment.decode(custody.enrollment_fields(pin()).4)
    as "The immutable pin contains the real enrolled policy."
  let native = enrollment.native_facts(enrolled)
  let declared = native_declaration()
  let requirements =
    policy.SandboxPolicy(
      ..native.ceiling,
      limits: policy.Limits(..native.ceiling.limits, wall_s: 5),
    )
  broker.CallSpec(
    declared.operation,
    declared.step,
    native.ceiling,
    requirements,
    [],
    broker.RefuseNarrowed,
    native.demand,
    declared.argv,
    declared.env,
    declared.cwd,
    budget.Budget(8, declared.deadline_ms),
  )
}

fn system_prepared(actual: dispatch.Dispatch) -> wire.Prepared {
  let assert Ok(enrolled) =
    enrollment.decode(custody.enrollment_fields(pin()).4)
    as "Original enrollment decodes."
  let native = enrollment.native_facts(enrolled)
  let assert Ok(registered) =
    registration.new(
      identity_scope(),
      native.working_roots,
      native.ceiling,
      native.demand,
      Ok,
    )
    as "Original exact registration materializes without a filesystem probe."
  wire.Prepared(
    actual.context.step,
    registration.digest(registered),
    wire.Finite(10_000),
    actual.request,
    wire.Logs,
  )
}

fn system_configuration(
  ready: custodian.RegisteredOwner,
  peer: distribution.Peer,
) -> dispatcher.Config {
  let assert Ok(binding) =
    dispatch_binding.new_registered(
      ready,
      connection.Config(peer, "owner", "exec-a", identity_scope(), 1, 1000),
      fn(actual) { Ok(system_prepared(actual)) },
      fn() { id(99) },
      poll.monotonic().now,
      21,
      5000,
      fn(_) { Nil },
    )
    as "Static binding uses the same original custodian and actual Dispatch."
  dispatch_binding.configuration(binding)
}

fn system_dispatch(
  ref: dispatch.SystemReservationRef,
  origin: remote_tool.ChildOrigin,
) -> dispatch.Dispatch {
  let declared = native_declaration()
  let spec = native_spec()
  dispatch.Dispatch(
    Some(ref),
    dispatch.CallContext(declared.operation, declared.step, Some(origin)),
    exec.ExecRequest(
      declared.argv,
      declared.env,
      declared.cwd,
      Some(spec.requirements),
      <<9:size(256)>>,
      spec.demand,
    ),
    1,
    declared.deadline_ms,
    clock.fixed(1000),
    Some(process.self()),
    fn(_) { Nil },
    fn(_) { Nil },
  )
}

pub fn actual_dispatcher_cancellation_uses_original_ref_after_admission_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "actual_dispatcher_cancellation_uses_original_ref_after_admission_test",
  )
  let f = fixture("system-actual-dispatcher", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "The original owner is active."
  let #(owner, _, _) = custodian.registered_fields(ready)
  let events = process.new_subject()
  let intent =
    retained_intent(
      owner,
      "synthetic actual dispatcher cancellation occurrence",
      id(90),
    )
  let assert Ok(custodian.SystemPermission(ref)) =
    custodian.allocate_system_reservation(
      owner,
      intent,
      native_declaration(),
      events,
    )
    as "Original permission comes from Fresh SQLite allocation."
  let original = system_configuration(ready, peer)
  let calls = process.new_subject()
  let cancelled = process.new_subject()
  let actual_config =
    dispatcher.Config(
      ..original,
      cancel_reserved: fn(actual) {
        original.cancel_reserved(actual)
        process.send(cancelled, Nil)
      },
      reserve: fn(actual) {
        let outcome = original.reserve(actual)
        let release = process.new_subject()
        process.send(calls, #(actual, outcome, release, process.self()))

        // Known COMMIT is held before remote work can finish. The actual
        // Dispatcher remains free to cancel its reserved original identity.
        let assert Ok(Nil) = process.receive(release, 5000)
          as "Only the observed cancellation releases this controlled reserve worker."
        outcome
      },
    )
  let assert Ok(broker) =
    broker.start_dispatching(
      entropy: fn(size) { bit_array.from_string(string.repeat("x", size)) },
      clock: clock.fixed(1000),
      dispatcher: dispatcher.dispatcher(actual_config),
    )
    as "The actual remote Dispatcher runs beneath the actual Broker; this controlled peer has no executor or helper."
  let assert Ok(handle) =
    broker.clear_system_call_from(
      broker,
      ref,
      native_spec(),
      events: events,
      waiting: 5000,
    )
    as "The actual guarantor accepts original clearance before its asynchronous reserve."
  let assert Ok(#(actual, Ok(reserved), release, holder)) =
    process.receive(calls, 5000)
    as "The actual asynchronous dispatcher reserve commits exact native custody and supplies its worker-owned release Subject."
  assert process.subject_owner(release) == Ok(holder)
  assert holder != process.self()
  broker.cancel(broker, handle)
  let assert Ok(broker.CallSettled(broker.CallFailed(_))) =
    process.receive(events, 5000)
    as "Cancellation settles once through the actual Broker."
  let assert Ok(Nil) = process.receive(cancelled, 5000)
    as "The actual automatic callback has returned before its durable state is inspected."

  // This first durable observation must be produced by the actual Dispatcher
  // cancellation callback. The following direct calls only prove idempotence.
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM owner_custody_children WHERE state='cancelled'",
    )
    == 1
  process.send(release, Nil)
  assert dispatch.cancel_system(ref, 5000) == Ok(Nil)
  assert original.reserve(actual) == Error(Nil)
  let #(_, _, origin, uuid) = dispatch.system_reservation_fields(ref)
  assert reserved.key
    == identity.request_key(identity_scope(), operation(), request_uuid(uuid))
  assert custodian.child_generation(owner, origin) == Ok(association(1))
  assert process.receive(events, 100) == Error(Nil)
  broker.stop(broker)
  stop(f)
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM owner_custody_children WHERE state='cancelled'",
    )
    == 1
  assert scalar(f.path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
}

fn request_uuid(uuid: ids.EntryId) -> identity.RequestId {
  let assert Ok(value) = identity.request_id(ids.entry_id_to_string(uuid))
    as "Original UUID parses without replacement."
  value
}

pub fn invalid_prepared_and_failed_sql_commit_never_rearm_system_permission_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "invalid_prepared_and_failed_sql_commit_never_rearm_system_permission_test",
  )
  let f = fixture("system-failed-commit", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "Original ready actor."
  let #(owner, _, _) = custodian.registered_fields(ready)
  let events = process.new_subject()
  let original = system_configuration(ready, peer)
  let first =
    retained_intent(owner, "synthetic invalid Prepared control", id(90))
  let assert Ok(custodian.SystemPermission(ref)) =
    custodian.allocate_system_reservation(
      owner,
      first,
      native_declaration(),
      events,
    )
    as "Original first allocation."
  let #(_, _, origin, _) = dispatch.system_reservation_fields(ref)
  let actual = system_dispatch(ref, origin)
  let invalid =
    dispatch.Dispatch(
      ..actual,
      request: exec.ExecRequest(..actual.request, argv: []),
    )
  assert original.reserve(invalid) == Error(Nil)
  assert original.reserve(actual) == Error(Nil)
  let second =
    retained_intent(
      owner,
      "synthetic suppressed SQLite native link control",
      id(91),
    )
  let assert Ok(custodian.SystemPermission(second_ref)) =
    custodian.allocate_system_reservation(
      owner,
      second,
      native_declaration(),
      events,
    )
    as "Original second allocation."
  let #(_, _, second_origin, _) = dispatch.system_reservation_fields(second_ref)
  mutate(
    f.path,
    "CREATE TRIGGER suppress_native_link BEFORE INSERT ON owner_child_generation BEGIN SELECT RAISE(IGNORE); END",
  )
  let actual = system_dispatch(second_ref, second_origin)
  assert original.reserve(actual) == Error(Nil)
  mutate(f.path, "DROP TRIGGER suppress_native_link")
  assert original.reserve(actual) == Error(Nil)
  assert custodian.child(owner, second_origin) == Error(custody.Missing)
  assert custodian.allocate_system_reservation(
      owner,
      second,
      native_declaration(),
      events,
    )
    == Ok(custodian.SystemObservation(
      second_origin,
      id(91),
      custody.NativeCancelled,
    ))
  stop(f)
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(f.path, "SELECT next_ordinal FROM owner_system_ordinal") == 2
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM owner_system_intent WHERE child_profile='native_cancelled'",
    )
    == 2
}

pub fn original_retained_workspace_and_capability_pair_bind_actual_git_clearance_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "original_retained_workspace_and_capability_pair_bind_actual_git_clearance_test",
  )
  let f = fixture("workspace-derived-git", fn(_, _, _) { final() })
  assert invoke(f, 0) == Ok(final())
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "The original actor retains real ordinary-tool custody."
  let #(owner, _, _) = custodian.registered_fields(ready)
  let assert Ok(enrolled) =
    enrollment.decode(custody.enrollment_fields(pin()).4)
    as "Complete actual enrollment."
  let #(index, hex) = remote_tool.provenance(invocation(0).key)
  let assert Ok(digest) = bit_array.base16_decode(hex)
    as "Full retained tool input digest."
  let assert Ok(source) = semantic.tool_origin(index, digest)
    as "Original tool provenance."
  let assert Ok(step) = workspace.step("registered")
    as "Original semantic step."
  let assert Ok(capability) =
    remote_tool.tool_child(
      invocation(0).key,
      remote_tool.AdmittedCapability(
        "git-status",
        0,
        remote_tool.SemanticWorkspace,
      ),
    )
    as "Existing capability semantic identity remains unchanged."
  let parents = [child(0, remote_tool.Workspace(0)), capability]
  list.each(
    list.index_map(parents, fn(parent, index) { #(parent, index) }),
    fn(pair) {
      let #(parent, index) = pair
      let semantic_binding =
        workspace_binding.new(scope(), owner, fn() { id(90 + index) })
      let binding =
        dispatch_binding.new_registered(
          ready,
          connection.Config(peer, "owner", "exec-a", identity_scope(), 1, 1000),
          fn(actual) { Ok(system_prepared(actual)) },
          fn() { id(95 + index) },
          poll.monotonic().now,
          21,
          5000,
          fn(_) { Nil },
        )
      let assert Ok(binding) = binding as "Original static native binding."
      let assert Ok(config) =
        dispatch_binding.with_workspace_commands(
          binding,
          enrolled,
          "/tools/git",
        )
        as "The trusted executor-resolved Git executable is pinned beneath enrolled toolchain roots."
      let assert Ok(semantic_reserved) =
        workspace_binding.reserve(
          semantic_binding,
          parent,
          operation(),
          step,
          semantic.Tool(source),
          semantic.Git(semantic.Status),
        )
        as "Complete canonical semantic invocation commits first."
      let native_origin = case remote_tool.child_fields(parent) {
        remote_tool.ToolFields(_, remote_tool.Workspace(_)) -> {
          let assert Ok(origin) =
            remote_tool.workspace_command_child(parent, remote_tool.GitStatus)
            as "Direct workspace wrapper has its own canonical address."
          origin
        }
        remote_tool.ToolFields(
          key,
          remote_tool.AdmittedCapability(
            name,
            ordinal,
            remote_tool.SemanticWorkspace,
          ),
        ) -> {
          let assert Ok(origin) =
            remote_tool.tool_child(
              key,
              remote_tool.AdmittedCapability(
                name,
                ordinal,
                remote_tool.NativeCommand,
              ),
            )
            as "The existing capability/native pair shares its exact logical tuple."
          origin
        }
        _ ->
          panic as "This fixture enumerates only the two approved semantic families."
      }
      let calls = process.new_subject()
      let assert Ok(broker) =
        broker.start_dispatching(
          entropy: fn(size) { bit_array.from_string(string.repeat("x", size)) },
          clock: clock.fixed(1000),
          dispatcher: dispatch.Dispatcher(fn(actual) {
            let result = config.reserve(actual)
            process.send(calls, #(actual, result))
            Error(dispatch.NotStarted)
          }),
        )
        as "Actual Broker clearance reaches the fixed Git recipe; this control submits no native effect."
      let events = process.new_subject()
      let spec =
        broker.CallSpec(..native_spec(), step_id: "registered:git_status")
      assert broker.clear_call_from(
          broker,
          native_origin,
          spec,
          events: events,
          waiting: 5000,
        )
        == Error(broker.BrokerUnavailable)
      let assert Ok(#(actual, Ok(reserved))) = process.receive(calls, 5000)
        as "The fixed binding retains the actual cleared complete Prepared."
      assert actual.system_reservation == None
      assert reserved.prepared.request == actual.request
      assert config.reserve(actual) == Error(Nil)
      assert custodian.child(owner, parent)
        == Ok(#(
          semantic.invocation_identity(workspace_binding.invocation(
            semantic_reserved,
          )).4,
          workspace_binding.content(semantic_reserved),
          None,
        ))
      config.cancel_reserved(actual)
      let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
        as "Exact retained native materialization."
      assert config.receive(
          native_origin,
          reserved.key,
          digest,
          [<<"late Git output">>],
          <<"late Git terminal">>,
        )
        == Ok(Nil)
      assert custodian.receipt_generation(owner, native_origin, id(95 + index))
        |> result.map(fn(value) { value.1 })
        == Ok(association(1))
      broker.stop(broker)
    },
  )
  stop(f)
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_children") == 4
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM owner_custody_children WHERE state='cancelled'",
    )
    == 2
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_child_generation") == 4
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_system_ordinal") == 0
}

pub fn changed_clearance_fields_close_only_original_ref_without_quota_release_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "changed_clearance_fields_close_only_original_ref_without_quota_release_test",
  )
  let f = fixture("system-projection-refusals", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "The original ready actor owns all occurrences."
  let #(owner, _, _) = custodian.registered_fields(ready)
  let events = process.new_subject()
  let config = system_configuration(ready, peer)
  let changes = [
    fn(actual: dispatch.Dispatch) {
      dispatch.Dispatch(..actual, deadline_ms: 12_000)
    },
    fn(actual: dispatch.Dispatch) {
      dispatch.Dispatch(
        ..actual,
        context: dispatch.CallContext(..actual.context, step: "other"),
      )
    },
    fn(actual: dispatch.Dispatch) {
      dispatch.Dispatch(
        ..actual,
        context: dispatch.CallContext(
          ..actual.context,
          operation: ids.mint_op(ids.generator(clock.fixed(1000), 78)).0,
        ),
      )
    },
    fn(actual: dispatch.Dispatch) {
      dispatch.Dispatch(
        ..actual,
        request: exec.ExecRequest(..actual.request, argv: [
          "/tools/git",
          "reset",
          "--hard",
        ]),
      )
    },
    fn(actual: dispatch.Dispatch) {
      dispatch.Dispatch(
        ..actual,
        request: exec.ExecRequest(..actual.request, cwd: "/other"),
      )
    },
    fn(actual: dispatch.Dispatch) {
      dispatch.Dispatch(
        ..actual,
        request: exec.ExecRequest(..actual.request, env: [#("PATH", "/other")]),
      )
    },
    fn(actual: dispatch.Dispatch) {
      dispatch.Dispatch(
        ..actual,
        request: exec.ExecRequest(..actual.request, demand: exec.BestEffort),
      )
    },
  ]
  list.each(
    list.index_map(changes, fn(change, index) { #(change, index) }),
    fn(pair) {
      let #(change, index) = pair
      let intent =
        retained_intent(
          owner,
          "synthetic closed declaration variant " <> int.to_string(index),
          id(80 + index),
        )
      let assert Ok(custodian.SystemPermission(ref)) =
        custodian.allocate_system_reservation(
          owner,
          intent,
          native_declaration(),
          events,
        )
        as "Each original occurrence allocates only once."
      let #(_, _, origin, uuid) = dispatch.system_reservation_fields(ref)
      let charge =
        scalar(f.path, "SELECT SUM(reserved_bytes) FROM owner_system_intent")
      let actual = system_dispatch(ref, origin)
      assert config.reserve(change(actual)) == Error(Nil)
      assert config.reserve(actual) == Error(Nil)
      assert custodian.child(owner, origin) == Error(custody.Missing)
      assert dispatch.cancel_system(ref, 5000) == Ok(Nil)
      assert custodian.allocate_system_reservation(
          owner,
          intent,
          native_declaration(),
          events,
        )
        == Ok(custodian.SystemObservation(origin, uuid, custody.NativeCancelled))
      assert scalar(
          f.path,
          "SELECT SUM(reserved_bytes) FROM owner_system_intent",
        )
        == charge
    },
  )
  stop(f)
  assert scalar(f.path, "SELECT next_ordinal FROM owner_system_ordinal") == 7
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_children") == 0
}

pub fn unobserved_reserve_reply_and_discarded_allocation_never_rearm_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "unobserved_reserve_reply_and_discarded_allocation_never_rearm_test",
  )
  let f = fixture("system-reply-loss", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "Original ready actor."
  let #(owner, _, _) = custodian.registered_fields(ready)
  let events = process.new_subject()
  let first =
    retained_intent(owner, "synthetic unobserved reserve reply", id(90))
  let assert Ok(custodian.SystemPermission(ref)) =
    custodian.allocate_system_reservation(
      owner,
      first,
      native_declaration(),
      events,
    )
    as "Original one-use permission."
  let #(subject, _, origin, uuid) = dispatch.system_reservation_fields(ref)
  let actual = system_dispatch(ref, origin)
  let prepared = system_prepared(actual)
  let assert Ok(envelope) =
    native_envelope.encode_cleared(
      "owner",
      identity_scope(),
      operation(),
      prepared,
      actual.deadline_ms,
    )
    as "Exact actual cleared envelope."
  let reply = process.new_subject()
  process.send(
    subject,
    dispatch.ReserveSystem(
      ref,
      dispatch.ClearedSystemCommand(
        actual.request,
        actual.context.operation,
        actual.context.step,
        actual.deadline_ms,
        actual.caller,
      ),
      envelope,
      reply,
    ),
  )

  // The same sender's following ask observes COMMIT while its Reserve reply stays
  // deliberately unobserved. This is an actual original mailbox exchange, not a
  // synthetic retained state inserted by a second writer.
  assert custodian.child(owner, origin) == Ok(#(uuid, envelope, None))
  let config = system_configuration(ready, peer)
  assert config.reserve(actual) == Error(Nil)
  let second =
    retained_intent(owner, "synthetic discarded allocation permission", id(91))
  let _unobserved =
    custodian.allocate_system_reservation(
      owner,
      second,
      native_declaration(),
      events,
    )
  assert custodian.cancel_system_intent(owner, second) == Ok(Nil)
  assert custodian.cancel_system_intent(owner, second) == Ok(Nil)
  let assert Ok(custodian.SystemObservation(
    _,
    observed,
    custody.NativeCancelled,
  )) =
    custodian.allocate_system_reservation(
      owner,
      second,
      native_declaration(),
      events,
    )
    as "A caller without its allocation reply can close the original intent but never reconstruct permission."
  assert observed == id(91)
  assert dispatch.cancel_system(ref, 5000) == Ok(Nil)
  stop(f)
  assert scalar(f.path, "SELECT next_ordinal FROM owner_system_ordinal") == 2
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_children") == 1
}

pub fn wrong_binding_cannot_cancel_another_original_system_permission_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "wrong_binding_cannot_cancel_another_original_system_permission_test",
  )
  let a = fixture("system-original-a", fn(_, _, _) { final() })
  let b = fixture("system-original-b", fn(_, _, _) { final() })
  let assert Ok(custodian.ReadyForActivation(ready_a)) =
    custodian.registered(a.owner)
    as "First actual pinned custodian."
  let assert Ok(custodian.ReadyForActivation(ready_b)) =
    custodian.registered(b.owner)
    as "Second actual pinned custodian has a distinct original subject."
  let #(owner_a, _, _) = custodian.registered_fields(ready_a)
  let events = process.new_subject()
  let intent =
    retained_intent(owner_a, "synthetic two-original-owner control", id(90))
  let assert Ok(custodian.SystemPermission(ref)) =
    custodian.allocate_system_reservation(
      owner_a,
      intent,
      native_declaration(),
      events,
    )
    as "Only the first custodian allocated this exact permission."
  let #(_, _, origin, uuid) = dispatch.system_reservation_fields(ref)
  let actual = system_dispatch(ref, origin)
  let foreign = system_configuration(ready_b, peer)
  let original = system_configuration(ready_a, peer)

  // Both actors have the same session and enrollment. The auxiliary subject,
  // rather than those shared projections, identifies the original permission.
  assert foreign.reserve(actual) == Error(Nil)
  let assert Ok(custodian.SystemObservation(_, observed, custody.NativePending)) =
    custodian.allocate_system_reservation(
      owner_a,
      intent,
      native_declaration(),
      events,
    )
    as "Foreign failure leaves the original pending permission live."
  assert observed == uuid
  let assert Ok(_) = original.reserve(actual)
    as "Only the correct original binding can admit its permission."
  assert foreign.reserve(actual) == Error(Nil)
  assert original.reserve(actual) == Error(Nil)
  assert dispatch.cancel_system(ref, 5000) == Ok(Nil)
  assert dispatch.cancel_system(ref, 5000) == Ok(Nil)
  stop(a)
  stop(b)
  assert scalar(a.path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  assert scalar(a.path, "SELECT COUNT(*) FROM owner_custody_children") == 1
  assert scalar(
      a.path,
      "SELECT COUNT(*) FROM owner_custody_children WHERE state='cancelled'",
    )
    == 1
  assert scalar(b.path, "SELECT COUNT(*) FROM owner_system_ordinal") == 0
  assert scalar(b.path, "SELECT COUNT(*) FROM owner_custody_children") == 0
}

pub fn composed_ordinary_proc_reservation_and_historical_receipt_keep_native_lane_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "composed_ordinary_proc_reservation_and_historical_receipt_keep_native_lane_test",
  )
  let f = fixture("composed-proc-native", fn(_, _, _) { final() })
  assert invoke(f, 0) == Ok(final())
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "The original tool writer is active."
  let #(owner, _, _) = custodian.registered_fields(ready)
  let config = composed_workspace_configuration(ready, peer, 95)
  let native =
    child(
      0,
      remote_tool.AdmittedCapability(
        "ordinary-proc",
        0,
        remote_tool.NativeCommand,
      ),
    )
  let semantic_parent =
    child(
      0,
      remote_tool.AdmittedCapability(
        "ordinary-proc",
        0,
        remote_tool.SemanticWorkspace,
      ),
    )
  assert custodian.child(owner, semantic_parent) == Error(custody.Missing)
  let calls = process.new_subject()
  let assert Ok(broker) =
    broker.start_dispatching(
      entropy: fn(size) { bit_array.from_string(string.repeat("x", size)) },
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(actual) {
        let reserved = config.reserve(actual)
        process.send(calls, #(actual, reserved))
        Error(dispatch.NotStarted)
      }),
    )
    as "Actual Broker clearance reaches the composed route; no native effect is submitted."
  let events = process.new_subject()
  let spec = broker.CallSpec(..native_spec(), argv: ["/tools/proc", "argument"])
  assert broker.clear_call_from(
      broker,
      native,
      spec,
      events: events,
      waiting: 5000,
    )
    == Error(broker.BrokerUnavailable)
  let assert Ok(#(actual, Ok(reserved))) = process.receive(calls, 5000)
    as "Ordinary proc.run has no retained semantic counterpart and must preserve native reservation."
  let assert Ok(stored) = custodian.child(owner, native)
    as "The original ordinary envelope is durable."
  assert native_envelope.decode("owner", identity_scope(), stored.1)
    == Ok(#(operation(), reserved.prepared))
  config.cancel_reserved(actual)

  // Later semantic cancellation must not reinterpret an already admitted
  // ordinary native envelope when its exact historical receipt arrives.
  assert custodian.cancel_child(owner, semantic_parent) == Ok(Nil)
  assert custodian.child(owner, semantic_parent) == Error(custody.Frozen)
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "Original ordinary native digest."
  assert config.receive(native, reserved.key, digest, [<<"late proc output">>], <<
      "late proc terminal",
    >>)
    == Ok(Nil)
  assert config.receive(native, reserved.key, digest, [<<"late proc output">>], <<
      "late proc terminal",
    >>)
    == Ok(Nil)
  let assert Ok(receipt) =
    custodian.receipt([<<"late proc output">>], <<"late proc terminal">>)
    as "Ordered original native receipt."
  assert custodian.receipt_generation(owner, native, id(95))
    == Ok(#(receipt, association(1)))
  assert config.reserve(actual) == Error(Nil)
  broker.stop(broker)
  stop(f)
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_children") == 2
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_child_generation") == 1
}

pub fn composed_semantic_evidence_errors_never_fall_back_to_ordinary_native_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@registered_custodian_test",
    "composed_semantic_evidence_errors_never_fall_back_to_ordinary_native_test",
  )
  let f = fixture("composed-semantic-refusal", fn(_, _, _) { final() })
  assert invoke(f, 0) == Ok(final())
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(f.owner)
    as "The original tool writer retains semantic evidence."
  let #(owner, _, _) = custodian.registered_fields(ready)
  let config = composed_workspace_configuration(ready, peer, 95)
  let malformed =
    child(
      0,
      remote_tool.AdmittedCapability(
        "malformed-semantic",
        0,
        remote_tool.SemanticWorkspace,
      ),
    )
  let cancelled =
    child(
      0,
      remote_tool.AdmittedCapability(
        "cancelled-semantic",
        0,
        remote_tool.SemanticWorkspace,
      ),
    )
  let conflicting =
    child(
      0,
      remote_tool.AdmittedCapability(
        "conflicting-semantic",
        0,
        remote_tool.SemanticWorkspace,
      ),
    )
  assert custodian.reserve_workspace_child(owner, malformed, id(90), <<
      "synthetic malformed semantic input",
    >>)
    == Ok(Nil)
  assert custodian.cancel_child(owner, cancelled) == Ok(Nil)
  let #(index, hex) = remote_tool.provenance(invocation(0).key)
  let assert Ok(input_digest) = bit_array.base16_decode(hex)
    as "Original full input digest."
  let assert Ok(source) = semantic.tool_origin(index, input_digest)
    as "Original tool provenance."
  let assert Ok(step) = workspace.step("registered")
    as "Original semantic step."
  let semantic_binding = workspace_binding.new(scope(), owner, fn() { id(91) })
  let assert Ok(_) =
    workspace_binding.reserve(
      semantic_binding,
      conflicting,
      operation(),
      step,
      semantic.Tool(source),
      semantic.Git(semantic.Status),
    )
    as "A valid retained GitStatus parent conflicts with the ordinary proc argv and physical step."
  let parents = [malformed, cancelled, conflicting]
  list.each(parents, fn(parent) {
    let assert remote_tool.ToolFields(
      key,
      remote_tool.AdmittedCapability(name, ordinal, _),
    ) = remote_tool.child_fields(parent)
      as "This control enumerates exact capability semantic parents."
    let assert Ok(native) =
      remote_tool.tool_child(
        key,
        remote_tool.AdmittedCapability(name, ordinal, remote_tool.NativeCommand),
      )
      as "The exact native counterpart has no prior payload."
    let calls = process.new_subject()
    let assert Ok(broker) =
      broker.start_dispatching(
        entropy: fn(size) { bit_array.from_string(string.repeat("x", size)) },
        clock: clock.fixed(1000),
        dispatcher: dispatch.Dispatcher(fn(actual) {
          let reserved = config.reserve(actual)
          process.send(calls, reserved)
          Error(dispatch.NotStarted)
        }),
      )
      as "Actual Broker clearance cannot turn semantic failure into ordinary admission."
    let events = process.new_subject()
    let spec =
      broker.CallSpec(..native_spec(), argv: ["/tools/proc", "argument"])
    assert broker.clear_call_from(
        broker,
        native,
        spec,
        events: events,
        waiting: 5000,
      )
      == Error(broker.BrokerUnavailable)
    assert process.receive(calls, 5000) == Ok(Error(Nil))
    assert custodian.child(owner, native) == Error(custody.Missing)
    broker.stop(broker)
  })
  stop(f)
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_custody_children") == 3
  assert scalar(f.path, "SELECT COUNT(*) FROM owner_child_generation") == 2
}

fn composed_workspace_configuration(
  ready: custodian.RegisteredOwner,
  peer: distribution.Peer,
  request_number: Int,
) -> dispatcher.Config {
  let assert Ok(enrolled) =
    enrollment.decode(custody.enrollment_fields(pin()).4)
    as "Exact immutable enrollment."
  let assert Ok(binding) =
    dispatch_binding.new_registered(
      ready,
      connection.Config(peer, "owner", "exec-a", identity_scope(), 1, 1000),
      fn(actual) { Ok(system_prepared(actual)) },
      fn() { id(request_number) },
      poll.monotonic().now,
      21,
      5000,
      fn(_) { Nil },
    )
    as "The composed dispatcher retains the original owner and native materializer."
  let assert Ok(config) =
    dispatch_binding.with_workspace_commands(binding, enrolled, "/tools/git")
    as "The trusted resolved Git executable supplies no arbitrary recipe."
  config
}

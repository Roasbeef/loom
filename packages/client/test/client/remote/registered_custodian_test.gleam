//// Registered owner wiring exercises the actual serialized custodian and SQLite.
//// No test hands the actor a token obtained from another custody connection.
//// Private TLS membership exercises normal dispatch callbacks without an executor.

import broker/dispatch
import broker/enrollment
import broker/exec
import broker/policy
import client/remote/custodian
import client/remote/dispatch_binding
import client/remote/tool_custody
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
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import machine/operation as operations
import runtime/effects
import simplifile
import sqlight
import storage/owner_custody as custody
import support/beam_owner_fixture
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
  let assert Ok(payload) = custody.payload(limits(), bytes)
    as "Exact original system envelope fits."
  Ok(custody.NativeSystem(payload))
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

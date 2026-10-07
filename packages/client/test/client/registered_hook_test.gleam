//// Registered hooks retain actual ordinary occurrences on conversation SQLite.
//// Admission controls use the original custodian, real Broker and registered
//// binding. Controlled NotStarted or held transport makes no physical helper claim.

import broker/broker
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/policy
import broker/token
import client/gateway
import client/hookcompat
import client/hookrunner
import client/hookserve
import client/hooktrust
import client/hookwire
import client/internal/instance_owner as instance_custody
import client/protocol
import client/registered_system_work as work
import client/remote/custodian
import client/remote/dispatch_binding
import core/clock
import core/generation
import core/ids
import core/json
import core/message
import core/workspace
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
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/system
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import machine/operation
import machine/strand
import provider/stream
import runtime/api
import runtime/effects
import runtime/supervisor
import session/session
import simplifile
import sqlight
import storage/access
import storage/owner_custody as custody
import storage/storage
import support/addresses
import support/beam_owner_fixture
import weft
import weft/actor
import weft/poll
import weft/registry

type Fixture {
  Fixture(
    path: String,
    owner_path: String,
    runtime: api.Runtime,
    retire: fn() -> Result(Nil, storage.StorageError),
    owner: custodian.Handle,
    ready: custodian.RegisteredOwner,
    owner_pid: process.Pid,
  )
}

type CommitProbe {
  ArmCommit(process.Subject(Nil))
  Committed(Int, process.Subject(Nil), process.Pid)
}

type CommitGate {
  Unarmed
  Armed
}

fn fixture(name: String) -> Fixture {
  fixture_with_probe(name, None)
}

fn fixture_with_probe(
  name: String,
  probe: Option(process.Subject(CommitProbe)),
) -> Fixture {
  fixture_for_session(name, probe, session_id())
}

fn fixture_for_session(
  name: String,
  probe: Option(process.Subject(CommitProbe)),
  actual_session: ids.SessionId,
) -> Fixture {
  let #(secs, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let assert Ok(cwd) = simplifile.current_directory()
    as "Portable fixture root."
  let root =
    cwd
    <> "/build/registered-hook-"
    <> name
    <> "-"
    <> int.to_string(secs)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(root) == Ok(Nil)
  let path = root <> "/conversation.db"
  let assert Ok(#(opened, retire)) =
    session.open_sqlite_owned(
      path: path,
      owner: "test",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(1000),
    )
    as "The actual conversation writer owns its SQLite lease."
  assert session.ensure_reserved_id(opened, actual_session)
    == Ok(actual_session)
  let assert Ok(runtime) =
    api.open(
      opened,
      effects.Effects(
        clock: clock.fixed(1000),
        entropy: fn() { 123 },
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(timeout_ms: 30_000, request: fn(_) {
          stream.immediate(process.new_subject(), fn() { Nil })
        }),
        tools: effects.ToolSurface(
          recover: fn(_, _) { effects.UnmanagedLocal },
          clear: fn(_) { effects.ClearanceRefused("fixture has no model tool") },
          run: fn(_) { effects.ToolFailed("fixture has no model tool") },
          replay_still_safe: fn(_) { False },
          execution_mode: fn(_) { effects.ExclusiveExecution },
        ),
        hooks: effects.default_hooks(),
      ),
      api.Options(
        ..api.default_options(
          strand.StrandConfiguration(
            strand.ModelIdentity("test", "test"),
            strand.ThinkingOff,
            [],
          ),
        ),
        after_commit: fn(ordinal) {
          case probe {
            None -> Nil
            Some(observer) -> {
              let permit = process.new_subject()
              process.send(observer, Committed(ordinal, permit, process.self()))
              let assert Ok(Nil) = process.receive(permit, 5000)
                as "The existing crash-scheduler seam has a receiver-owned permit."
              Nil
            }
          }
        },
      ),
    )
    as "Actual runtime writer opens on SQLite."
  let owner_path = root <> "/owner.db"
  let assert Ok(config) =
    custodian.config_with_reports(
      owner_path,
      session_id(),
      limits(),
      1,
      5000,
      fn(_, _, _) { effects.ToolFailed("no tool in this system fixture") },
      bootstrap.sha256,
    )
    as "Original owner config."
  let assert Ok(config) =
    custodian.with_registered(config, pin(), association(1), 1)
    as "Full original pin and generation."
  let assert Ok(names) = registry.start() as "Original typed owner address."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config)
    as "Actual custodian opens SQLite."
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(owner)
    as "History cannot provide this actual ready projection."
  let #(owner, _, _) = custodian.registered_fields(ready)
  Fixture(path, owner_path, runtime, retire, owner, ready, started.pid)
}

fn stop(f: Fixture) -> Nil {
  let monitor = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "Original custodian exits before history inspection."
  assert api.close(f.runtime) == Ok(Nil)
  assert f.retire() == Ok(Nil)
  Nil
}

fn plain_broker() -> broker.Broker {
  let assert Ok(value) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(_) { Error(dispatch.NotStarted) }),
    )
    as "Real Broker exists; primitive SQL controls deliberately never clear."
  value
}

fn session_id() -> ids.SessionId {
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

fn scope() -> workspace.Scope {
  let assert Ok(value) =
    workspace.scope_from_fields(
      ids.session_id_to_string(session_id()),
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
  identity.scope(session_id(), workspace, executor, epoch, epoch)
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
    custody.enrollment_pin(session_id(), binding, descriptor, digest, bytes)
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

fn context(f: Fixture, b: broker.Broker) -> hookrunner.RegisteredContext {
  context_with_clock(f, b, clock.fixed(1000))
}

fn context_with_clock(
  f: Fixture,
  b: broker.Broker,
  clock: clock.Clock,
) -> hookrunner.RegisteredContext {
  let assert Ok(enrolled) =
    enrollment.decode(custody.enrollment_fields(pin()).4)
    as "Actual original native policy."
  let native = enrollment.native_facts(enrolled)
  let assert Ok(runner) =
    hookrunner.registered_context(
      f.ready,
      hookrunner.Context(
        b,
        native.ceiling,
        operation(),
        "imported-hooks",
        "/work",
        [],
        native.demand,
        clock,
        ids.session_id_to_string(session_id()),
        "/executor/transcript",
      ),
      "owner",
      1000,
    )
    as "Actual ready owner, not history, supplies registered context."
  runner
}

fn planned(
  r: hookrunner.RegisteredContext,
  seed: Int,
  position: work.HookPosition,
) -> work.HookPlan {
  hookrunner.prepare_registered(
    r,
    hookrunner.Command("printf hook", None, Some(5)),
    600,
    1000,
    position,
    id(seed),
    "original parsed handler",
  )
}

fn input(
  r: hookrunner.RegisteredContext,
  uuid: ids.EntryId,
  plans: List(work.HookPlan),
  stdin: String,
) -> work.HookOccurrenceInput {
  let #(owner, association, _, _) = hookrunner.registered_identity(r)
  work.HookOccurrenceInput(
    uuid,
    "Stop",
    json.Array([]),
    stdin,
    plans,
    owner,
    association,
    process.self(),
    1000,
    20_000,
  )
}

fn retain(
  f: Fixture,
  r: hookrunner.RegisteredContext,
  seed: Int,
  stdin: String,
) -> work.HookOccurrence {
  let assert Ok(retained) =
    work.retain_hook_occurrence(
      api.fact_handle(f.runtime),
      input(
        r,
        id(seed),
        [planned(r, seed + 1, work.HookPosition(0, 0, 0, 0))],
        stdin,
      ),
    )
    as "Actual sole CAS and complete same-writer readback create fresh work."
  retained
}

fn address(uuid: ids.EntryId) -> String {
  api.session_fact_prefix <> "hook-occurrence/" <> ids.entry_id_to_string(uuid)
}

pub fn identical_events_have_distinct_actual_sequences_and_no_history_rearm_test() {
  let f = fixture("distinct-events")
  let b = plain_broker()
  let r = context(f, b)
  let first = retain(f, r, 90, "same original stdin")
  let second = retain(f, r, 92, "same original stdin")
  let assert Ok(Some(api.FactCell(_, first_seq))) =
    api.fact_cell(f.runtime, address(id(90)))
    as "First actual committed event."
  let assert Ok(Some(api.FactCell(_, second_seq))) =
    api.fact_cell(f.runtime, address(id(92)))
    as "Identical event input does not share an occurrence."
  assert second_seq > first_seq
  assert list.length(work.hook_works(first)) == 1
  assert list.length(work.hook_works(second)) == 1
  assert work.retain_hook_occurrence(
      api.fact_handle(f.runtime),
      input(
        r,
        id(90),
        [planned(r, 91, work.HookPosition(0, 0, 0, 0))],
        "same original stdin",
      ),
    )
    |> result.is_error
  assert api.reserved_facts(f.runtime, api.client_fact_prefix) == Ok([])
  broker.stop(b)
  stop(f)
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 0
}

pub fn refused_or_changed_actual_occurrence_readback_grants_no_fresh_work_test() {
  let f = fixture("refused-write")
  let b = plain_broker()
  let r = context(f, b)
  mutate(
    f.path,
    "CREATE TRIGGER refuse_hook BEFORE INSERT ON registers WHEN NEW.key LIKE 'session/hook-occurrence/%' BEGIN SELECT RAISE(ABORT,'refuse actual hook write'); END",
  )
  assert work.retain_hook_occurrence(
      api.fact_handle(f.runtime),
      input(r, id(90), [planned(r, 91, work.HookPosition(0, 0, 0, 0))], "{}"),
    )
    |> result.is_error
  assert api.fact_cell(f.runtime, address(id(90))) == Ok(None)
  mutate(f.path, "DROP TRIGGER refuse_hook")
  mutate(
    f.path,
    "CREATE TRIGGER change_hook AFTER INSERT ON registers WHEN NEW.key LIKE 'session/hook-occurrence/%' BEGIN UPDATE registers SET value='{}' WHERE key=NEW.key; END",
  )
  assert work.retain_hook_occurrence(
      api.fact_handle(f.runtime),
      input(r, id(92), [planned(r, 93, work.HookPosition(0, 0, 0, 0))], "{}"),
    )
    |> result.is_error
  broker.stop(b)
  stop(f)
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 0
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 0
}

pub fn indexed_matching_keeps_original_skipped_source_group_and_handler_positions_test() {
  let source = hookcompat.Source("original", hookcompat.LoomInline)
  let assert Ok(config) =
    hookcompat.parse_claude(
      "{\"PreToolUse\":[{\"matcher\":\"Write\",\"hooks\":[{\"type\":\"command\",\"command\":\"skip\"}]},{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"prompt\",\"prompt\":\"unsupported\"},{\"type\":\"command\",\"command\":\"same\"},{\"type\":\"command\",\"command\":\"same\"}]}]}",
      source,
    )
    as "Original parsed declaration inventory."
  let selected =
    hookwire.matching_indexed(
      [hookwire.IndexedConfig(3, config)],
      hookcompat.PreToolUse,
      "Bash",
    )
  assert list.map(selected, fn(one) { one.position })
    == [work.HookPosition(3, 0, 1, 1), work.HookPosition(3, 0, 1, 2)]
  assert list.map(selected, fn(one) { one.config_hash })
    == [hookcompat.hash(config), hookcompat.hash(config)]
}

pub fn changed_trust_definition_and_no_home_refuse_without_owner_workspace_probe_test() {
  let f = fixture("source-trust")
  let located =
    hookserve.Located(
      f.path <> "-absent-executor-settings",
      hookserve.ClaudeHooks,
      hookcompat.ProjectSettings,
    )
  let original =
    "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"original\"}]}]}"
  let changed =
    "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"changed\"}]}]}"
  let assert Ok(config) =
    hookcompat.parse_claude(
      original,
      hookcompat.Source(located.path, located.origin),
    )
    as "Actual originally acquired config."
  let trust = f.path <> "-trust"
  assert simplifile.create_directory_all(trust) == Ok(Nil)
  assert hooktrust.trust(
      hooktrust.record_path(trust, located.path),
      config,
      1000,
    )
    == Ok(Nil)
  let verified =
    hookserve.load_registered(
      [hookserve.AcquiredDocument(located, Some(original))],
      Some(trust),
    )
  let b = plain_broker()
  let r = context(f, b)
  let wiring =
    hookwire.Wiring(
      config,
      ids.session_id_to_string(session_id()),
      "/executor/transcript",
      "/work",
    )
  let assert Ok(serving) =
    hookserve.registered_serving(
      verified,
      wiring,
      r,
      api.fact_handle(f.runtime),
      fn() { 101 },
    )
    as "No owner read of the absent executor source is necessary."
  let assert Ok(composed) =
    hookserve.wire_registered(
      f.runtime.effects,
      serving,
      clock.fixed(1000),
      fn(_) { True },
    )
    as "Original trusted supplied bytes select actual gate wiring."
  assert composed.hooks.run_end(operation()) == None
  let rejected =
    hookserve.load_registered(
      [hookserve.AcquiredDocument(located, Some(changed))],
      Some(trust),
    )
  let assert Ok(rejected) =
    hookserve.registered_serving(
      rejected,
      wiring,
      r,
      api.fact_handle(f.runtime),
      fn() { 102 },
    )
    as "Refused sources compose no command, rather than restoring old authority."
  let assert Ok(rejected) =
    hookserve.wire_registered(
      f.runtime.effects,
      rejected,
      clock.fixed(1000),
      fn(_) { True },
    )
    as "Refused inventory remains observational."
  assert rejected.hooks.run_end(operation()) == None
  assert simplifile.read(located.path) == Error(simplifile.Enoent)
  let absent =
    hookserve.load_registered([hookserve.AcquiredDocument(located, None)], None)
  let assert Ok(absent) =
    hookserve.registered_serving(
      absent,
      wiring,
      r,
      api.fact_handle(f.runtime),
      fn() { 103 },
    )
    as "Absent source with no home remains absent."
  let assert Ok(absent) =
    hookserve.wire_registered(
      f.runtime.effects,
      absent,
      clock.fixed(1000),
      fn(_) { True },
    )
    as "No fallback probes the owner workspace."
  assert absent.hooks.run_end(operation()) == None
  broker.stop(b)
  stop(f)
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 1
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM registers WHERE key LIKE 'session/hook-occurrence/%'",
    )
    == 1
}

pub fn actual_broker_registered_hook_keeps_original_uuid_generation_and_refuses_replay_test() {
  use peer <- beam_owner_fixture.run(
    "client@registered_hook_test",
    "actual_broker_registered_hook_keeps_original_uuid_generation_and_refuses_replay_test",
  )
  let f = fixture("actual-hook-broker")
  let config = system_configuration(f.ready, peer)
  let calls = process.new_subject()
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(actual) {
        let result = config.reserve(actual)
        process.send(calls, #(actual, result))
        Error(dispatch.NotStarted)
      }),
    )
    as "Actual original registered reserve follows real Broker clearance."
  let r = context(f, b)
  let occurrence = retain(f, r, 90, "complete input")
  let assert [selected] = work.hook_works(occurrence) as "One original command."
  assert hookrunner.run_registered(r, selected)
    == Error(hookrunner.Refused(broker.BrokerUnavailable))
  let assert Ok(#(actual, Ok(reserved))) = process.receive(calls, 1000)
    as "Real original SQLite admission preceded controlled NotStarted."
  let assert Some(ref) = actual.system_reservation
    as "The original one-use ref traversed Broker."
  let #(_, _, origin, uuid) = dispatch.system_reservation_fields(ref)
  assert uuid == id(91)
  assert actual.deadline_ms == 6000
  assert actual.request.argv == ["sh", "-c", "printf hook"]
  assert hookrunner.run_registered(r, selected) |> result.is_error
  assert process.receive(calls, 0) == Error(Nil)
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "Exact original receipt identity."
  assert config.receive(origin, reserved.key, digest, [<<"late original">>], <<
      "terminal",
    >>)
    == Ok(Nil)
  assert custodian.receipt_generation(f.owner, origin, uuid) |> result.is_ok
  broker.stop(b)
  stop(f)
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 1
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 1
}

pub fn wrong_actual_runtime_refuses_before_occurrence_write_or_clearance_test() {
  let original = fixture("original-runtime")
  let other_id = ids.mint_session(ids.generator(clock.fixed(1000), 88)).0
  let other = fixture_for_session("wrong-runtime", None, other_id)
  let calls = process.new_subject()
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(actual) {
        process.send(calls, actual)
        Error(dispatch.NotStarted)
      }),
    )
    as "The real Broker must not receive wrong-runtime work."
  let r = context(original, b)
  assert work.retain_hook_occurrence(
      api.fact_handle(other.runtime),
      input(
        r,
        id(90),
        [planned(r, 91, work.HookPosition(0, 0, 0, 0))],
        "original input",
      ),
    )
    == Error(work.Refused)
  assert api.fact_cell(other.runtime, address(id(90))) == Ok(None)
  assert api.fact_cell(original.runtime, address(id(90))) == Ok(None)
  assert process.receive(calls, 0) == Error(Nil)
  broker.stop(b)
  stop(other)
  stop(original)
  assert scalar(original.owner_path, "SELECT COUNT(*) FROM owner_system_intent")
    == 0
  assert scalar(other.owner_path, "SELECT COUNT(*) FROM owner_system_intent")
    == 0
}

fn stop_actor(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.unlink(pid)
  process.send_abnormal_exit(pid, "shutdown")
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "The exact original fixture actor is joined."
  Nil
}

pub fn lost_actual_occurrence_commit_reply_grants_no_work_or_system_intent_test() {
  let held = process.new_subject()
  let assert Ok(probe) =
    actor.new(Unarmed)
    |> actor.on_message(fn(state, message) {
      case message {
        ArmCommit(reply) -> {
          process.send(reply, Nil)
          actor.continue(Armed)
        }
        Committed(ordinal, permit, writer) -> {
          case state {
            Unarmed -> process.send(permit, Nil)
            Armed -> process.send(held, #(ordinal, permit, writer))
          }
          actor.continue(Unarmed)
        }
      }
    })
    |> actor.start
    as "The closed seam holds the next actual writer COMMIT reply."
  let f = fixture_with_probe("lost-occurrence-reply", Some(probe.data))
  let b = plain_broker()
  let r = context(f, b)
  assert process.call(probe.data, waiting: 1000, sending: ArmCommit) == Nil
  let facts = api.fact_handle(f.runtime)
  let original =
    input(
      r,
      id(90),
      [planned(r, 91, work.HookPosition(0, 0, 0, 0))],
      "actual bytes",
    )
  let run =
    weft.new([fn() { work.retain_hook_occurrence(facts, original) }])
    |> weft.deadline(5000)
    |> weft.start_detached
  let assert Ok(#(_, permit, writer)) = process.receive(held, 2000)
    as "Actual SQL COMMIT preceded the held observation."
  let owner = process.subject_owner(permit)
  weft.cancel_detached(run)
  let observed = weft.pull(run, within: 1000)

  // Release the real writer before asserting any outcome or inspecting its store.
  process.send(permit, Nil)
  assert owner == Ok(writer)
  assert observed == weft.PulledOutcome(weft.Abandoned(0))
  assert weft.pull(run, within: 1000) == weft.AllDelivered
  let assert Ok(Some(_)) = api.fact_cell(f.runtime, address(id(90)))
    as "The lost reply did not undo an actual committed occurrence."
  assert work.retain_hook_occurrence(facts, original) |> result.is_error
  broker.stop(b)
  stop(f)
  stop_actor(probe.pid)
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 0
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 0
}

pub fn maximum_input_occurrence_survives_actual_network_snapshot_capture_test() {
  let f = fixture("capture-large-occurrence")
  let b = plain_broker()
  let r = context(f, b)
  let full = string.repeat("i", 1_048_576)
  let _ = retain(f, r, 90, full)
  let assert Ok(Some(api.FactCell(record, _))) =
    api.fact_cell(f.runtime, address(id(90)))
    as "The accepted complete stdin is durably retained."
  assert string.contains(json.to_string(record), full)
  assert api.reserved_facts(f.runtime, api.client_fact_prefix) == Ok([])
  let name = addresses.new()
  let assert Ok(started) =
    gateway.start(gateway.default_options("capture", f.runtime), name)
    as "The actual network gateway uses the real session snapshot reader."
  let principal =
    access.Principal("hook-reader", "Owner", access.MemberPrincipal)
  let assert Ok(digest) = access.credential_digest(string.repeat("c", 64))
    as "Actual attachment credential shape."
  let hub = gateway.Gateway(name)
  let assert Ok(attached) =
    gateway.attach_authenticated(
      hub,
      gateway.Binding(
        ids.session_id_to_string(session_id()),
        "epoch",
        "incarnation",
        "hook-reader",
        principal,
        access.Owner,
        digest,
        None,
      ),
      fn() { Ok(#(principal, access.Owner)) },
      fn(_) { Nil },
      fn() { Nil },
      fn() { Nil },
      process.self(),
    )
    as "A real owner attachment requests ordinary capture."
  let assert Ok(frame) =
    gateway.connection_request(
      attached,
      protocol.encode_command(protocol.CommandEnvelope(
        1,
        protocol.Subscribe(ids.session_id_to_string(session_id()), None),
      )),
    )
    as "Large accepted hook stdin does not poison the ordinary metadata budget."
  let assert Ok(protocol.EventEnvelope(event: protocol.SnapshotBegin(_), ..)) =
    protocol.decode_event(frame)
    as "Actual capture succeeds and begins the bounded transfer."
  assert !string.contains(frame, full)
  stop_actor(started.pid)
  broker.stop(b)
  stop(f)
}

type CounterMessage {
  Next(process.Subject(Int))
}

fn serving(
  f: Fixture,
  r: hookrunner.RegisteredContext,
  text: String,
  entropy: fn() -> Int,
) -> hookserve.RegisteredServing {
  serving_with_facts(api.fact_handle(f.runtime), r, text, entropy)
}

fn serving_with_facts(
  facts: api.FactHandle,
  r: hookrunner.RegisteredContext,
  text: String,
  entropy: fn() -> Int,
) -> hookserve.RegisteredServing {
  let located =
    hookserve.Located(
      "already-acquired",
      hookserve.ClaudeHooks,
      hookcompat.LoomInline,
    )
  let sources =
    hookserve.load_registered(
      [hookserve.AcquiredDocument(located, Some(text))],
      None,
    )
  let config =
    hookcompat.Config(
      [],
      hookcompat.Source("placeholder", hookcompat.LoomInline),
    )
  let assert Ok(serving) =
    hookserve.registered_serving(
      sources,
      hookwire.Wiring(
        config,
        ids.session_id_to_string(session_id()),
        "/executor/transcript",
        "/work",
      ),
      r,
      facts,
      entropy,
    )
    as "Private registered join preserves public Wiring and Context shapes."
  serving
}

pub fn all_five_actual_effect_gates_retain_occurrences_and_preserve_exclusions_test() {
  use peer <- beam_owner_fixture.run(
    "client@registered_hook_test",
    "all_five_actual_effect_gates_retain_occurrences_and_preserve_exclusions_test",
  )
  let f = fixture("five-gates")
  let config = system_configuration(f.ready, peer)
  let calls = process.new_subject()
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(actual) {
        let reserved = config.reserve(actual)
        process.send(calls, #(actual, reserved))
        Error(dispatch.NotStarted)
      }),
    )
    as "Every gate reaches real original registered SQL admission."
  let assert Ok(counter) =
    actor.new(200)
    |> actor.on_message(fn(n, message) {
      let Next(reply) = message
      process.send(reply, n)
      actor.continue(n + 1)
    })
    |> actor.start
    as "Unique entropy is fixed once per occurrence."
  let counter_door = counter.data
  let text =
    "{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"start\",\"timeout\":5}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"stop\",\"timeout\":5}]}],\"PreCompact\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"compact\",\"timeout\":5}]}],\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"pre\",\"timeout\":5}]}],\"PostToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"post\",\"timeout\":5}]}]}"
  let selected =
    serving(f, context(f, b), text, fn() {
      process.call(counter_door, 1000, Next)
    })
  let call =
    message.ToolCall(
      "call",
      "bash",
      json.Object([#("command", json.String("original"))]),
      None,
      None,
    )
  let result_message =
    message.UserMessage([message.UserText("original result", None)], 1000, None)
  let base = f.runtime.effects
  let base =
    effects.Effects(
      ..base,
      tools: effects.ToolSurface(
        ..base.tools,
        clear: fn(query: effects.ClearanceQuery) {
          effects.Cleared(query.call.arguments, operation.ReplayNever)
        },
        run: fn(_) { effects.ToolCompleted(result_message, False) },
      ),
    )
  let assert Ok(composed) =
    hookserve.wire_registered(base, selected, clock.fixed(1000), fn(_) { True })
    as "All five wrappers use the ordinary decision reducers."
  let query =
    effects.ClearanceQuery(
      operation(),
      "model",
      0,
      call,
      strand.StrandConfiguration(
        strand.ModelIdentity("test", "test"),
        strand.ThinkingOff,
        ["bash"],
      ),
      [],
    )
  let run =
    effects.ToolRun(
      operation(),
      "model",
      0,
      id(99),
      "main",
      call,
      call.arguments,
      operation.ReplayNever,
      [],
    )
  assert composed.hooks.run_start(operation()) == []
  assert composed.hooks.run_start(operation()) == []
  assert composed.hooks.run_end(operation()) == None
  assert composed.hooks.compaction_note(
      operation(),
      effects.CompactionCue(effects.RequestedCompaction, 10, 3, 2),
    )
    == []
  assert composed.tools.clear(query)
    == effects.Cleared(call.arguments, operation.ReplayNever)
  assert composed.tools.run(run) == effects.ToolCompleted(result_message, False)
  let actual =
    list.map(list.repeat(Nil, 5), fn(_) {
      let assert Ok(#(request, Ok(_))) = process.receive(calls, 1000)
        as "Actual native system admission exists for this gate."
      request
    })
  assert list.map(actual, fn(one) { one.request.argv })
    == [
      ["sh", "-c", "start"],
      ["sh", "-c", "stop"],
      ["sh", "-c", "compact"],
      ["sh", "-c", "pre"],
      ["sh", "-c", "post"],
    ]
  assert list.all(actual, fn(one) { one.deadline_ms == 6000 })

  // Harness refusal and follow-up, another strand and failed outcomes never
  // create a hook occurrence. The SessionStart counter also remains discharged.
  let refused =
    effects.Effects(
      ..base,
      hooks: effects.Hooks(..base.hooks, run_end: fn(_) { Some(result_message) }),
      tools: effects.ToolSurface(
        ..base.tools,
        clear: fn(_) { effects.ClearanceRefused("original harness") },
        run: fn(_) { effects.ToolFailed("original harness") },
      ),
    )
  let assert Ok(excluded) =
    hookserve.wire_registered(refused, selected, clock.fixed(1000), fn(_) {
      False
    })
    as "Registered mode shares the same exclusion decisions."
  assert excluded.hooks.run_end(operation()) == Some(result_message)
  assert excluded.tools.clear(query)
    == effects.ClearanceRefused("original harness")
  assert excluded.tools.run(run) == effects.ToolFailed("original harness")
  let assert Ok(other_strand) =
    hookserve.wire_registered(base, selected, clock.fixed(1000), fn(_) { False })
    as "No stop occurrence belongs to an excluded strand."
  assert other_strand.hooks.run_end(operation()) == None
  assert process.receive(calls, 0) == Error(Nil)
  broker.stop(b)
  stop_actor(counter.pid)
  stop(f)
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM registers WHERE key LIKE 'session/hook-occurrence/%'",
    )
    == 5
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 5
}

pub fn actual_dispatcher_input_boundaries_preserve_bytes_and_one_final_eof_test() {
  use peer <- beam_owner_fixture.run(
    "client@registered_hook_test",
    "actual_dispatcher_input_boundaries_preserve_bytes_and_one_final_eof_test",
  )
  let f = fixture("input-frames")
  let original = system_configuration(f.ready, peer)
  let held = process.new_subject()
  let frames = process.new_subject()
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(actual) {
        let ready = process.new_subject()
        let config =
          dispatcher.Config(..original, reserve: fn(request) {
            let result = original.reserve(request)
            let permit = process.new_subject()
            process.send(held, #(result, permit))
            process.send(ready, Nil)
            let _ = process.receive(permit, 2000)
            result
          })
        use execution <- result.try(dispatcher.dispatcher(config).start(actual))
        let assert Ok(Nil) = process.receive(ready, 1000)
          as "Real original admission precedes exposing this fixture input door."
        let stdin = execution.stdin
        let settle = actual.settle
        Ok(
          dispatch.Execution(..execution, stdin: fn(bytes, eof) {
            stdin(bytes, eof)
            process.send(frames, #(bytes, eof))
            case eof {
              dispatch.MoreInput -> Nil
              dispatch.EndOfInput ->
                settle(
                  dispatch.Failed(exec.ExecutionLost(
                    exec.RemoteOutcomeUncertain,
                  )),
                )
            }
          }),
        )
      }),
    )
    as "Real Dispatcher stdin callback is installed; terminal is explicitly synthetic uncertainty."
  let r = context(f, b)
  let receipts =
    list.index_map([0, 8192, 8193, 1_048_576], fn(size, index) {
      let bytes = case size {
        8193 -> string.repeat("x", 8191) <> "é"
        _ -> string.repeat("x", size)
      }
      let original = retain(f, r, 400 + index * 2, bytes)
      let assert [selected] = work.hook_works(original)
        as "One actual retained handler."
      let run =
        weft.new([fn() { hookrunner.run_registered(r, selected) }])
        |> weft.deadline(5000)
        |> weft.start_detached
      let expected = int.max({ size + 8191 } / 8192, 1)
      let received =
        list.map(list.repeat(Nil, expected), fn(_) {
          let assert Ok(frame) = process.receive(frames, 1000)
            as "The real Dispatcher stdin callback was invoked before this frame observation."
          frame
        })
      let outcome = weft.pull(run, within: 1000)
      let held_result = process.receive(held, 1000)

      // A failed assertion cannot leave the original reserve worker parked.
      case held_result {
        Ok(#(_, permit)) -> process.send(permit, Nil)
        Error(Nil) -> Nil
      }
      let assert Ok(#(Ok(reserved), _)) = held_result
        as "Actual original SQL admission exists."
      assert outcome
        |> fn(value) {
          case value {
            weft.PulledOutcome(weft.Completed(0, _)) -> True
            _ -> False
          }
        }
      assert weft.pull(run, within: 1000) == weft.AllDelivered
      assert bit_array.concat(list.map(received, fn(one) { one.0 }))
        == bit_array.from_string(bytes)
      assert list.map(received, fn(one) { one.1 })
        == list.append(list.repeat(dispatch.MoreInput, expected - 1), [
          dispatch.EndOfInput,
        ])
      assert list.all(received, fn(one) { bit_array.byte_size(one.0) <= 8192 })
      assert process.receive(frames, 0) == Error(Nil)
      reserved
    })
  assert list.length(receipts) == 4
  assert work.retain_hook_occurrence(
      api.fact_handle(f.runtime),
      input(
        r,
        id(500),
        [planned(r, 501, work.HookPosition(0, 0, 0, 0))],
        string.repeat("x", 1_048_577),
      ),
    )
    == Error(work.Refused)
  broker.stop(b)
  stop(f)
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 4
}

type TimeMessage {
  TimeNow(process.Subject(Int))
  Advance(Int, process.Subject(Nil))
}

pub fn later_handler_keeps_deadline_fixed_before_any_sequential_execution_test() {
  use peer <- beam_owner_fixture.run(
    "client@registered_hook_test",
    "later_handler_keeps_deadline_fixed_before_any_sequential_execution_test",
  )
  let f = fixture("sequential-deadline")
  let assert Ok(time) =
    actor.new(1000)
    |> actor.on_message(fn(now, message) {
      case message {
        TimeNow(reply) -> {
          process.send(reply, now)
          actor.continue(now)
        }
        Advance(next, reply) -> {
          process.send(reply, Nil)
          actor.continue(next)
        }
      }
    })
    |> actor.start
    as "A receiver-owned clock advances only at actual first admission."
  let time_door = time.data
  let original = system_configuration(f.ready, peer)
  let calls = process.new_subject()
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(actual) {
        let reserved = original.reserve(actual)
        process.send(calls, #(actual, reserved))
        process.call(time_door, 1000, fn(reply) { Advance(6001, reply) })
        Error(dispatch.NotStarted)
      }),
    )
    as "Only the first original handler has time remaining to clear."
  let controlled =
    clock.from_function(fn() { process.call(time_door, 1000, TimeNow) })
  let text =
    "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"first\",\"timeout\":5},{\"type\":\"command\",\"command\":\"second\",\"timeout\":5}]}]}"
  let selected =
    serving(f, context_with_clock(f, b, controlled), text, fn() { 610 })
  let assert Ok(composed) =
    hookserve.wire_registered(f.runtime.effects, selected, controlled, fn(_) {
      True
    })
    as "The real gate captures both immutable plans at time 1000."
  assert composed.hooks.run_end(operation()) == None
  let assert Ok(#(actual, Ok(_))) = process.receive(calls, 1000)
    as "Actual first SQL native reservation is the time boundary."
  assert actual.request.argv == ["sh", "-c", "first"]
  assert actual.deadline_ms == 6000
  assert process.receive(calls, 0) == Error(Nil)
  let assert Ok([#(_, json.Object(record))]) =
    api.reserved_facts(f.runtime, api.session_fact_prefix <> "hook-occurrence/")
    as "One actual occurrence retains both original plans."
  let assert Ok(json.Array([json.Object(first), json.Object(second)])) =
    list.key_find(record, "plans")
    as "Sequential execution does not rebuild its second declaration."
  assert list.key_find(first, "deadline") == Ok(json.Int(6000))
  assert list.key_find(second, "deadline") == Ok(json.Int(6000))
  broker.stop(b)
  stop_actor(time.pid)
  stop(f)
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 1
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 1
}

pub fn changed_original_context_declaration_refuses_before_permission_or_clearance_test() {
  let f = fixture("changed-declaration")
  let calls = process.new_subject()
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(actual) {
        process.send(calls, actual)
        Error(dispatch.NotStarted)
      }),
    )
    as "No replacement declaration may reach the Broker."
  let r = context(f, b)
  let occurrence = retain(f, r, 700, "original input")
  let assert [selected] = work.hook_works(occurrence)
    as "Actual original handler."
  let #(owner, _, original, _) = hookrunner.registered_identity(r)
  let assert Ok(changed) =
    hookrunner.registered_context(
      f.ready,
      hookrunner.Context(..original, env: [#("CHANGED", "value")]),
      owner,
      1000,
    )
    as "The original owner can still reject an incompatible captured declaration."
  assert hookrunner.run_registered(changed, selected)
    == Error(hookrunner.NeverSettled)
  assert process.receive(calls, 0) == Error(Nil)
  broker.stop(b)
  stop(f)
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 0
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 0
}

type CancellationBoundary {
  ActualWorker
  ActualGateCaller
}

pub fn original_registered_hook_worker_death_cancels_exact_admission_and_accepts_late_receipt_test() {
  use peer <- beam_owner_fixture.run(
    "client@registered_hook_test",
    "original_registered_hook_worker_death_cancels_exact_admission_and_accepts_late_receipt_test",
  )
  cancellation_control(peer, ActualWorker)
}

pub fn original_gate_caller_death_cancels_actual_hook_worker_not_a_replacement_test() {
  use peer <- beam_owner_fixture.run(
    "client@registered_hook_test",
    "original_gate_caller_death_cancels_actual_hook_worker_not_a_replacement_test",
  )
  cancellation_control(peer, ActualGateCaller)
}

fn cancellation_control(
  peer: distribution.Peer,
  boundary: CancellationBoundary,
) -> Nil {
  let f = fixture("actual-cancellation")
  let original = system_configuration(f.ready, peer)
  let held = process.new_subject()
  let cancelled = process.new_subject()
  let config =
    dispatcher.Config(
      ..original,
      reserve: fn(actual) {
        let reserved = original.reserve(actual)
        let permit = process.new_subject()
        process.send(held, #(actual, reserved, permit, process.self()))
        let _ = process.receive(permit, 5000)
        reserved
      },
      cancel_reserved: fn(actual) {
        original.cancel_reserved(actual)
        process.send(cancelled, Nil)
      },
    )
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(1000),
      dispatcher: dispatcher.dispatcher(config),
    )
    as "Actual caller-death cancellation belongs to the real remote Dispatcher."
  let r = context(f, b)
  let task = case boundary {
    ActualWorker -> {
      let retained = retain(f, r, 800, "original bytes")
      let assert [selected] = work.hook_works(retained)
        as "Original actual occurrence."
      fn() {
        hookrunner.run_registered(r, selected) |> result.map(fn(_) { Nil })
      }
    }
    ActualGateCaller -> {
      let selected =
        serving(
          f,
          r,
          "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"original\",\"timeout\":5}]}]}",
          fn() { 810 },
        )
      let assert Ok(composed) =
        hookserve.wire_registered(
          f.runtime.effects,
          selected,
          clock.fixed(1000),
          fn(_) { True },
        )
        as "An actual gate worker owns its own native events receiver."
      let run_end = composed.hooks.run_end
      let operation = operation()
      fn() {
        let _ = run_end(operation)
        Ok(Nil)
      }
    }
  }
  let run = weft.new([task]) |> weft.deadline(5000) |> weft.start_detached
  let held_result = process.receive(held, 2000)
  let assert Ok(#(actual, Ok(reserved), permit, reserve_worker)) = held_result
    as "The actual original native envelope has committed before cancellation."
  let caller = actual.caller
  let permit_owner = process.subject_owner(permit)
  weft.cancel_detached(run)
  let observation = weft.pull(run, within: 1000)
  let cancellation = process.receive(cancelled, 1000)

  // Release the exact reserve worker before assertions; a lost cancellation
  // observation cannot leave the test's SQL/transport boundary parked.
  process.send(permit, Nil)
  assert observation == weft.PulledOutcome(weft.Abandoned(0))
  assert weft.pull(run, within: 1000) == weft.AllDelivered
  assert cancellation == Ok(Nil)
  assert permit_owner == Ok(reserve_worker)
  let assert Some(actual_worker) = caller
    as "Actual native events have a live worker owner."
  assert actual_worker != process.self()
  assert actual_worker != reserve_worker
  let assert Some(ref) = actual.system_reservation
    as "Actual one-use reservation survived clearance."
  let #(_, _, origin, uuid) = dispatch.system_reservation_fields(ref)
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "Exact original prepared receipt."
  assert original.receive(origin, reserved.key, digest, [<<"late original">>], <<
      "terminal",
    >>)
    == Ok(Nil)
  assert custodian.receipt_generation(f.owner, origin, uuid) |> result.is_ok
  assert process.receive(held, 0) == Error(Nil)
  broker.stop(b)
  stop(f)
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 1
  assert scalar(
      f.owner_path,
      "SELECT COUNT(*) FROM owner_custody_children WHERE state='cancelled'",
    )
    == 1
}

pub fn actual_reopened_hook_history_cannot_allocate_permission_or_reuse_old_runner_test() {
  let f = fixture("hook-history")
  let b = plain_broker()
  let r = context(f, b)
  let retained = retain(f, r, 850, "historical original input")
  let assert [selected] = work.hook_works(retained)
    as "Only the original CAS/readback constructed this value."
  let #(plan, _, _, _, _) = work.hook_fields(selected)
  let #(address, bytes) = work.hook_manifest(selected)
  let assert Ok(intent) =
    custodian.retain_system_intent(
      f.owner,
      address,
      custody.CommandPreparation,
      plan.spec.op_id,
      plan.spec.step_id,
      plan.request_id,
      bytes,
    )
    as "Original durable intent retains no reconstructed Fresh permission."
  let down = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(down, fn(value) { value })
    |> process.selector_receive(2000)
    as "Original writer is joined before history opens."
  let assert Ok(config) =
    custodian.config_with_reports(
      f.owner_path,
      session_id(),
      limits(),
      1,
      5000,
      fn(_, _, _) { effects.ToolFailed("history only") },
      bootstrap.sha256,
    )
    as "Exact durable owner configuration."
  let assert Ok(config) =
    custodian.with_registered(config, pin(), association(1), 1)
    as "The retained generation has no new original-connection authority."
  let assert Ok(names) = registry.start()
    as "History uses its own original actor address."
  let history = custodian.new(names, config)
  let assert Ok(started) = custodian.start(history, config)
    as "Actual SQL history reopens."
  assert custodian.registered(history)
    == Ok(custodian.HistoryOnly(pin(), association(1)))
  let assert Ok(observed) =
    custodian.retain_system_intent(
      history,
      address,
      custody.CommandPreparation,
      plan.spec.op_id,
      plan.spec.step_id,
      plan.request_id,
      bytes,
    )
    as "Exact history observation does not rearm work."
  assert custody.system_intent_fields(observed)
    == custody.system_intent_fields(intent)
  let events = process.new_subject()
  let spec = plan.spec
  assert custodian.allocate_system_reservation(
      history,
      observed,
      dispatch.SystemCommandDeclaration(
        "owner",
        spec.op_id,
        spec.step_id,
        spec.argv,
        spec.env,
        spec.cwd,
        spec.budget.deadline_ms,
      ),
      events,
    )
    == Error(custody.Frozen)
  assert hookrunner.run_registered(r, selected)
    == Error(hookrunner.NeverSettled)
  assert work.retain_hook_occurrence(
      api.fact_handle(f.runtime),
      input(r, id(850), [plan], "historical original input"),
    )
    |> result.is_error
  let down = process.monitor(started.pid)
  assert custodian.stop(history) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(down, fn(value) { value })
    |> process.selector_receive(2000)
    as "Actual historical writer closes."
  broker.stop(b)
  assert api.close(f.runtime) == Ok(Nil)
  assert f.retire() == Ok(Nil)
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 0
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 0
}

pub fn original_deadline_expires_during_real_broker_congestion_without_second_dispatch_test() {
  use peer <- beam_owner_fixture.run(
    "client@registered_hook_test",
    "original_deadline_expires_during_real_broker_congestion_without_second_dispatch_test",
  )
  let f = fixture("congested-deadline")
  let original = system_configuration(f.ready, peer)
  let held = process.new_subject()
  let cancelled = process.new_subject()
  let config =
    dispatcher.Config(
      ..original,
      reserve: fn(actual) {
        let reserved = original.reserve(actual)
        let permit = process.new_subject()
        process.send(held, #(actual, reserved, permit))
        let _ = process.receive(permit, 5000)
        reserved
      },
      cancel_reserved: fn(actual) {
        original.cancel_reserved(actual)
        process.send(cancelled, Nil)
      },
    )
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(1000),
      dispatcher: dispatcher.dispatcher(config),
    )
    as "The first actual admitted execution occupies the original one-slot ledger."
  let first_context = context(f, b)
  let first = retain(f, first_context, 900, "held original")
  let assert [first] = work.hook_works(first) as "Actual first work."
  let first_run =
    weft.new([fn() { hookrunner.run_registered(first_context, first) }])
    |> weft.deadline(5000)
    |> weft.start_detached
  let assert Ok(#(first_dispatch, Ok(_), permit)) = process.receive(held, 2000)
    as "Real SQL reserve proves the first ledger slot is occupied."
  let assert Ok(time) =
    actor.new(0)
    |> actor.on_message(fn(reads, message) {
      let Next(reply) = message
      process.send(reply, case reads >= 3 {
        True -> 6001
        False -> 1000
      })
      actor.continue(reads + 1)
    })
    |> actor.start
    as "The fourth clock read expires the retry after its original congestion refusal."
  let time_door = time.data
  let clock = clock.from_function(fn() { process.call(time_door, 1000, Next) })
  let second_context = context_with_clock(f, b, clock)
  let second = retain(f, second_context, 902, "second original")
  let assert [second] = work.hook_works(second)
    as "Actual independent second work."
  let second_run =
    weft.new([fn() { hookrunner.run_registered(second_context, second) }])
    |> weft.deadline(5000)
    |> weft.start_detached
  let second_result = weft.pull(second_run, within: 1000)
  weft.cancel_detached(first_run)
  let first_result = weft.pull(first_run, within: 1000)
  let cancelled_result = process.receive(cancelled, 1000)

  // Unpark the exact original writer before testing the refusal and cancellation.
  process.send(permit, Nil)
  assert second_result
    == weft.PulledOutcome(weft.Failed(0, hookrunner.NeverSettled))
  assert weft.pull(second_run, within: 1000) == weft.AllDelivered
  assert first_result == weft.PulledOutcome(weft.Abandoned(0))
  assert weft.pull(first_run, within: 1000) == weft.AllDelivered
  assert cancelled_result == Ok(Nil)
  assert first_dispatch.deadline_ms == 6000
  assert process.receive(held, 0) == Error(Nil)
  broker.stop(b)
  stop_actor(time.pid)
  stop(f)
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 2
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 1
}

// Construction uses the actual registered custodian and Broker over SQLite.
// NotStarted dispatch makes no helper claim; the occurrence is still real data.
pub fn fact_effects_prepared_gate_binds_original_writer_and_is_not_rebuilt_test() {
  let f = fixture("prepared-gate")
  let b = plain_broker()
  let runner = context(f, b)
  let base = f.runtime.effects
  assert api.close(f.runtime) == Ok(Nil)
  assert f.retire() == Ok(Nil)
  let assert Ok(#(opened, retire)) =
    session.open_sqlite_owned(f.path, "prepared", 30_000, clock.fixed(1000))
    as "Only after the old writer retires does this original runtime open."
  let assert Ok(prepared) = hookserve.prepare_registered_gate()
    as "One actual counter is acquired before opening."
  let gate_pid = hookserve.registered_gate_owner(prepared)
  let captured = process.new_subject()
  let assert Ok(runtime) =
    api.open_fact_effects_published(
      opened,
      base,
      api.default_options(
        strand.StrandConfiguration(
          strand.ModelIdentity("test", "test"),
          strand.ThinkingOff,
          [],
        ),
      ),
      fn(facts) {
        process.send(captured, facts)
        let selected =
          serving_with_facts(
            facts,
            runner,
            "{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"start\",\"timeout\":5}]}]}",
            fn() { 700 },
          )
        Ok(hookserve.wire_registered_prepared(
          base,
          selected,
          clock.fixed(1000),
          fn(_) { True },
          prepared,
        ))
      },
      fn(parked) {
        assert registry.lookup(parked.tree.writer) == Error(Nil)
        assert process.is_alive(gate_pid)
        Ok(Nil)
      },
    )
    as "Pure binding starts no replacement actor or writer."
  let assert Ok(facts) = process.receive(captured, 1000)
    as "The actual binder's writer capability is captured."
  assert runtime.effects.hooks.run_start(operation()) == []
  let event_key =
    address(ids.mint_entry(ids.generator(clock.fixed(1000), 700)).0)
  let assert Ok(Some(committed)) = api.fact_cell_with(facts, event_key)
    as "The hook occurrence commits through the bound original writer."
  assert api.fact_cell(runtime, event_key) == Ok(Some(committed))
  let assert Ok(original_writer) = registry.lookup(runtime.tree.writer)
    as "The actual writer can be replaced beneath the same root."
  let assert Ok(writer_pid) = process.subject_owner(original_writer)
    as "Exact original writer PID."
  process.kill(writer_pid)
  assert poll.until(within: 1000, every: 5, attempt: fn() {
      case registry.lookup(runtime.tree.writer) {
        Ok(current) if current != original_writer -> poll.Done(Nil)
        Ok(_) | Error(Nil) -> poll.Retry
      }
    })
    == poll.Answered(Nil)
  assert runtime.effects.hooks.run_start(operation()) == []
  assert api.fact_cell_with(facts, event_key) == Ok(Some(committed))
  assert process.is_alive(gate_pid)
  assert api.close(runtime) == Ok(Nil)
  assert hookserve.release_registered_gate(prepared, within_ms: 1000) == Ok(Nil)
  assert !process.is_alive(gate_pid)
  assert retire() == Ok(Nil)
  broker.stop(b)
  let owner_monitor = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "Original registered custody retires normally."
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM registers WHERE key LIKE 'session/hook-occurrence/%'",
    )
    == 1
}

pub fn fact_effects_counter_is_retired_on_publication_refusal_with_owner_alive_test() {
  let f = fixture("prepared-refusal")
  let base = f.runtime.effects
  assert api.close(f.runtime) == Ok(Nil)
  assert f.retire() == Ok(Nil)
  let assert Ok(#(opened, retire)) =
    session.open_sqlite_owned(f.path, "refused", 30_000, clock.fixed(1000))
    as "The refusal control has one actual writer lease."
  let observations = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let release_owner = process.new_subject()
      let assert Ok(prepared) = hookserve.prepare_registered_gate()
        as "The same live owner acquires its original counter."
      let outcome =
        api.open_fact_effects_published(
          opened,
          base,
          api.default_options(
            strand.StrandConfiguration(
              strand.ModelIdentity("test", "test"),
              strand.ThinkingOff,
              [],
            ),
          ),
          fn(_) { Ok(base) },
          fn(parked) {
            process.send(observations, #(
              parked,
              hookserve.registered_gate_owner(prepared),
              release_owner,
            ))
            Error("original publication refused")
          },
        )
      assert result.is_error(outcome)
      let closed = hookserve.release_registered_gate(prepared, within_ms: 1000)
      let assert Ok(Nil) = closed
        as "The original counter stop ACK and Normal are required."
      process.send(observations, #(
        f.runtime,
        hookserve.registered_gate_owner(prepared),
        release_owner,
      ))
      process.receive_forever(release_owner)
    })
  let assert Ok(#(parked, counter_pid, release_owner)) =
    process.receive(observations, 1000)
    as "Actual refused root and acquired counter are retained."
  let assert Ok(_) = process.receive(observations, 1000)
    as "Explicit stop ACK and original Normal are consumed before the owner waits."
  assert process.is_alive(owner)
  assert !process.is_alive(counter_pid)
  assert !process.is_alive(registry.owner(parked.tree.namespace))
  assert !process.is_alive(parked.tree.supervisor)
  assert session.close(opened) == Ok(Nil)
  assert retire() == Ok(Nil)
  process.send(release_owner, Nil)
  let watch = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "The original custodian also retires."
}

pub fn fact_effects_original_services_custody_handles_lost_open_reply_test() {
  let f = fixture("prepared-custody")
  let base = f.runtime.effects
  assert api.close(f.runtime) == Ok(Nil)
  assert f.retire() == Ok(Nil)
  let assert Ok(#(opened, retire)) =
    session.open_sqlite_owned(f.path, "custodied", 30_000, clock.fixed(1000))
    as "One new original writer lease follows confirmed old disposal."
  let ready = process.new_subject()
  let observed = process.new_subject()
  let order = process.new_subject()
  let builder =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let begin = process.new_subject()
      process.send(ready, begin)
      let owner = process.receive_forever(begin)
      let assert Ok(prepared) = hookserve.prepare_registered_gate()
        as "The original builder acquires one actual counter."
      let counter_pid = hookserve.registered_gate_owner(prepared)
      let assert Ok(Nil) =
        instance_custody.publish(owner, instance_custody.Services, fn() {
          process.send(order, "Services")
          hookserve.release_registered_gate(prepared, within_ms: 1000)
        })
        as "Services retains counter release before runtime opening."
      process.unlink(counter_pid)
      let assert Ok(runtime) =
        api.open_fact_effects_published(
          opened,
          base,
          api.default_options(
            strand.StrandConfiguration(
              strand.ModelIdentity("test", "test"),
              strand.ThinkingOff,
              [],
            ),
          ),
          fn(_) { Ok(base) },
          fn(runtime) {
            let tree = runtime.tree
            instance_custody.publish(owner, instance_custody.Runtime, fn() {
              assert process.is_alive(counter_pid)
              process.send(order, "Runtime")
              supervisor.shutdown(tree, grace_ms: 1000)
              |> result.replace_error(
                "Original runtime drain remains unconfirmed",
              )
            })
          },
        )
        as "The original root and direct drain are retained before writer startup."
      let assert Ok(Nil) =
        instance_custody.publish(owner, instance_custody.Storage, fn() {
          let assert Ok(Nil) = session.close(opened)
            as "Drain precedes original lease release."
          retire()
          |> result.replace_error("Original session connection remains live")
        })
        as "The final connection retirement belongs to original custody."
      process.send(observed, #(runtime, counter_pid))

      // The finite open result is deliberately never returned to its consumer.
      // These independently published capabilities still own the actual resources.
      process.receive_forever(process.new_subject())
    })
  let assert Ok(begin) = process.receive(ready, 1000)
    as "The resource-free builder parks with its own receiver."
  let assert Ok(owner) =
    instance_custody.start(
      builder,
      fn() { process.kill(builder) },
      consumer: process.self(),
      failures: process.new_subject(),
    )
    as "Actual Weft custody retains the original builder before acquisition."
  process.send(begin, owner)
  let assert Ok(#(runtime, counter_pid)) = process.receive(observed, 1000)
    as "Opening completed after publication but its final result is lost."
  assert process.is_alive(counter_pid)
  assert instance_custody.close(owner, within_ms: 5000)
    == instance_custody.Closed
  let assert Ok("Runtime") = process.receive(order, 1000)
    as "The original runtime drains first."
  let assert Ok("Services") = process.receive(order, 1000)
    as "The exact counter retires only after that drain."
  assert !process.is_alive(builder)
  assert !process.is_alive(counter_pid)
  assert !process.is_alive(runtime.tree.supervisor)
  assert !process.is_alive(registry.owner(runtime.tree.namespace))
  let watch = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "Actual original registered custodian also retires."
}

pub fn fact_effects_counter_is_retired_on_bind_refusal_with_owner_alive_test() {
  let f = fixture("prepared-bind-refusal")
  let base = f.runtime.effects
  assert api.close(f.runtime) == Ok(Nil)
  assert f.retire() == Ok(Nil)
  let assert Ok(#(opened, retire)) =
    session.open_sqlite_owned(f.path, "refused-bind", 30_000, clock.fixed(1000))
    as "The original lease is acquired without a replacement writer."
  let observations = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let release = process.new_subject()
      let assert Ok(prepared) = hookserve.prepare_registered_gate()
        as "Exactly one actual counter is acquired before binding."
      let outcome =
        api.open_fact_effects_published(
          opened,
          base,
          api.default_options(
            strand.StrandConfiguration(
              strand.ModelIdentity("test", "test"),
              strand.ThinkingOff,
              [],
            ),
          ),
          fn(facts) {
            assert api.fact_cell_with(facts, "session/bind-refusal")
              == Error(api.RuntimeUnavailable)
            Error("original bind refused")
          },
          fn(_) { Error("publication must never run after refused binding") },
        )
      assert result.is_error(outcome)
      assert hookserve.release_registered_gate(prepared, within_ms: 1000)
        == Ok(Nil)
      process.send(observations, #(
        hookserve.registered_gate_owner(prepared),
        release,
      ))
      process.receive_forever(release)
    })
  let assert Ok(#(counter_pid, release)) = process.receive(observations, 1000)
    as "Explicit counter stop and join complete even though opening refused."
  assert process.is_alive(owner)
  assert !process.is_alive(counter_pid)
  assert session.close(opened) == Ok(Nil)
  assert retire() == Ok(Nil)
  process.send(release, Nil)
  let watch = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "Original registered custodian also retires."
}

pub fn fact_effects_missing_stop_ack_cannot_be_reconstructed_from_later_normal_test() {
  let assert Ok(prepared) = hookserve.prepare_registered_gate()
    as "One real actor supplies the stop proof."
  let original = hookserve.registered_gate_owner(prepared)
  let monitor = process.monitor(original)
  system.suspend(original)
  assert result.is_error(hookserve.release_registered_gate(
    prepared,
    within_ms: 0,
  ))
  assert process.is_alive(original)
  system.resume(original)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "The original stop happens later, after the requesting observer lost its ACK."
  assert result.is_error(hookserve.release_registered_gate(
    prepared,
    within_ms: 1000,
  ))
}

pub fn fact_effects_abnormal_counter_loss_refuses_release_proof_test() {
  let observed = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let permit = process.new_subject()
      let assert Ok(prepared) = hookserve.prepare_registered_gate()
        as "Original counter acquisition succeeds."
      let original = hookserve.registered_gate_owner(prepared)
      let monitor = process.monitor(original)
      process.kill(original)
      let assert Ok(process.ProcessDown(reason: process.Killed, ..)) =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
        |> process.selector_receive(1000)
        as "The actual original actor dies abnormally."
      assert result.is_error(hookserve.release_registered_gate(
        prepared,
        within_ms: 1000,
      ))
      process.send(observed, permit)
      process.receive_forever(permit)
    })
  let assert Ok(permit) = process.receive(observed, 1000)
    as "Original actor loss remains uncertain while its assembly owner stays alive."
  assert process.is_alive(owner)
  process.send(permit, Nil)
}

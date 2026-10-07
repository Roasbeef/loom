//// Registered goal checks use the actual SQLite writer and original custodian.
//// The native admission controls use real Broker policy/token clearance and the
//// static registered binding. Their deliberate NotStarted transport submits no
//// helper effect; original actor cancellation has its own held-dispatch control.

import broker/broker
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/policy
import client/advisor
import client/goalcheck
import client/goalstate
import client/registered_system_work as work
import client/remote/custodian
import client/remote/dispatch_binding
import core/clock
import core/generation
import core/ids
import core/workspace
import events/bus
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
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import machine/strand
import provider/stream
import runtime/api
import runtime/effects
import session/session
import simplifile
import sqlight
import storage/owner_custody as custody
import storage/storage
import support/addresses
import support/beam_owner_fixture
import telemetry/log
import tools/advise
import tools/tool
import weft
import weft/actor
import weft/poll
import weft/registry

const command = "printf original-goal"

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
  let #(secs, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let assert Ok(cwd) = simplifile.current_directory()
    as "Portable fixture root."
  let root =
    cwd
    <> "/build/registered-goal-"
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
  assert session.ensure_reserved_id(opened, session_id()) == Ok(session_id())
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

fn runner(
  f: Fixture,
  broker_actor: broker.Broker,
) -> goalcheck.RegisteredRunner {
  let assert Ok(enrolled) =
    enrollment.decode(custody.enrollment_fields(pin()).4)
    as "Canonical original policy."
  let native = enrollment.native_facts(enrolled)
  let assert Ok(value) =
    goalcheck.registered_runner(
      f.ready,
      broker_actor,
      "owner",
      native.ceiling,
      native.demand,
      [],
      "/work",
      clock.fixed(1000),
      operation(),
      1000,
      5000,
    )
    as "Assembly captures actual ready custody and real Broker."
  value
}

fn before() -> goalstate.Goal {
  goalstate.Goal(
    ..goalstate.new("original goal", 10_000, 1000, accounted_from: 0),
    check: Some(command),
  )
}

fn moved() -> goalstate.Goal {
  goalstate.Goal(..before(), phase: goalstate.Checking(6000))
}

fn plain_broker() -> broker.Broker {
  let assert Ok(value) =
    broker.start_dispatching(
      entropy: fn(size) { bit_array.from_string(string.repeat("x", size)) },
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(_) { Error(dispatch.NotStarted) }),
    )
    as "Real Broker exists; primitive SQL controls deliberately never clear."
  value
}

fn seed(f: Fixture) -> Int {
  let assert Ok(seq) =
    api.put_reserved_fact_expecting(
      f.runtime,
      advisor.goal_key,
      goalstate.encode(before()),
      expected: None,
    )
    as "Original active goal."
  seq
}

fn retained(
  f: Fixture,
  runner: goalcheck.RegisteredRunner,
) -> #(work.CheckingWork, custody.IntentReadback) {
  let original = process.new_subject()
  let assert Ok(value) =
    goalcheck.retain_registered(
      runner,
      f.runtime,
      before(),
      moved(),
      command,
      id(90),
      original,
      20_000,
    )
    as "One original Checking transition, immutable ordinary work and intent."
  value
}

pub fn sole_checking_cas_and_duplicate_history_never_rearm_test() {
  let f = fixture("sole-cas")
  let broker_actor = plain_broker()
  let initial = seed(f)
  let r = runner(f, broker_actor)
  let #(held, intent) = retained(f, r)
  let #(seq, goal, _, uuid, _, _, _, _, _) = work.fields(held)
  assert seq == initial + 1
  assert goal == moved()
  assert uuid == id(90)
  assert api.fact_cell(f.runtime, advisor.goal_key)
    == Ok(Some(api.FactCell(goalstate.encode(moved()), seq)))
  let original = process.new_subject()
  assert goalcheck.retain_registered(
      r,
      f.runtime,
      before(),
      moved(),
      command,
      id(91),
      original,
      20_000,
    )
    == Error(work.Refused)
  assert goalcheck.retain_registered(
      r,
      f.runtime,
      moved(),
      moved(),
      command,
      id(92),
      original,
      20_000,
    )
    == Error(work.Refused)
  assert api.fact_cell(f.runtime, advisor.goal_key)
    == Ok(Some(api.FactCell(goalstate.encode(moved()), seq)))
  goalcheck.cancel_registered(r, intent)
  broker.stop(broker_actor)
  stop(f)
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 1
}

pub fn failed_checking_sql_write_creates_no_work_or_system_intent_test() {
  let f = fixture("write-failed")
  let b = plain_broker()
  let _ = seed(f)
  mutate(
    f.path,
    "CREATE TRIGGER refuse_check BEFORE UPDATE ON registers WHEN NEW.key='goal/state' BEGIN SELECT RAISE(ABORT, 'refused Checking'); END",
  )
  let actor = process.new_subject()
  assert goalcheck.retain_registered(
      runner(f, b),
      f.runtime,
      before(),
      moved(),
      command,
      id(90),
      actor,
      20_000,
    )
    |> result.is_error
  broker.stop(b)
  stop(f)
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM registers WHERE key LIKE 'goal/check/%'",
    )
    == 0
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 0
}

pub fn changed_actual_checking_readback_refuses_fresh_work_test() {
  let f = fixture("readback-changed")
  let b = plain_broker()
  let _ = seed(f)
  mutate(
    f.path,
    "CREATE TRIGGER alter_check AFTER UPDATE ON registers WHEN NEW.key='goal/state' BEGIN UPDATE registers SET seq=NEW.seq+1 WHERE key=NEW.key; END",
  )
  let actor = process.new_subject()
  assert goalcheck.retain_registered(
      runner(f, b),
      f.runtime,
      before(),
      moved(),
      command,
      id(90),
      actor,
      20_000,
    )
    == Error(work.Refused)
  broker.stop(b)
  stop(f)
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM registers WHERE key LIKE 'goal/check/%'",
    )
    == 0
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 0
}

pub fn actual_registered_goal_broker_retains_one_original_and_refuses_replay_test() {
  use peer <- beam_owner_fixture.run(
    "client@registered_goal_check_test",
    "actual_registered_goal_broker_retains_one_original_and_refuses_replay_test",
  )
  let f = fixture("actual-broker")
  let config = system_configuration(f.ready, peer)
  let calls = process.new_subject()
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: fn(size) { bit_array.from_string(string.repeat("x", size)) },
      clock: clock.fixed(1000),
      dispatcher: dispatch.Dispatcher(fn(actual) {
        let result = config.reserve(actual)
        process.send(calls, #(actual, result))
        Error(dispatch.NotStarted)
      }),
    )
    as "Real Broker clears into actual original registered binding."
  let r = runner(f, b)
  let _ = seed(f)
  let #(held, intent) = retained(f, r)
  let result = goalcheck.run_registered(r, held, intent)
  let assert goalstate.DidNotFinish(_) = result.ending
    as "This controlled transport submits no helper effect."
  let assert Ok(#(actual, Ok(reserved))) = process.receive(calls, 5000)
    as "Actual clearance commits native Prepared on the original owner connection."
  let assert Some(ref) = actual.system_reservation
    as "The actual ref traverses Broker dispatch."
  let #(_, _, origin, uuid) = dispatch.system_reservation_fields(ref)
  assert uuid == id(90)
  assert actual.context.origin == Some(origin)
  assert actual.deadline_ms == 6000
  assert reserved.prepared.request.argv
    == ["bash", "-o", "pipefail", "-c", command]
  assert reserved.prepared.request == actual.request
  let second = goalcheck.run_registered(r, held, intent)
  let assert goalstate.DidNotFinish(_) = second.ending
    as "History cannot clear again."
  assert process.receive(calls, 0) == Error(Nil)
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "Exact retained native digest."
  assert config.receive(
      origin,
      reserved.key,
      digest,
      [<<"late original result">>],
      <<"terminal">>,
    )
    == Ok(Nil)
  assert custodian.receipt_generation(f.owner, origin, uuid) |> result.is_ok
  broker.stop(b)
  stop(f)
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 1
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 1
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

fn advisor_actor(
  f: Fixture,
  b: broker.Broker,
) -> #(process.Subject(advisor.Message), process.Pid, advisor.Wiring) {
  let settings =
    advisor.Settings(
      strand.ModelIdentity("test", "test"),
      strand.ThinkingOff,
      [],
      20,
      2,
    )
  assert advisor.ensure_strand(f.runtime, settings, [advise.name]) == Ok(Nil)
  let assert Ok(enrolled) =
    enrollment.decode(custody.enrollment_fields(pin()).4)
    as "Actual original policy."
  let native = enrollment.native_facts(enrolled)
  let legacy =
    goalcheck.wiring(
      goalcheck.Runner(
        tool.broker_runner(broker: b, waiting: 1000),
        native.ceiling,
        native.demand,
        [],
        "/work",
        clock.fixed(1000),
        operation(),
        1000,
      ),
      timeout_ms: 5000,
    )
  let wiring =
    advisor.Wiring(
      f.runtime.session,
      fn() { Ok(f.runtime) },
      settings,
      legacy,
      clock.fixed(1000),
      log.discard(),
      addresses.new(),
    )
  let assert Ok(started) = advisor.start_registered(wiring, runner(f, b))
    as "The actual original advisor owns registered transition and worker."
  #(started.data, started.pid, wiring)
}

fn barrier(actor: process.Subject(advisor.Message)) -> Nil {
  let _ =
    process.call(actor, waiting: 5000, sending: fn(reply) {
      advisor.TakeAtRunEnd(operation(), 0, reply)
    })
  Nil
}

fn stop_advisor(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.unlink(pid)
  process.kill(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "The exact original advisor is gone."
  Nil
}

pub fn actual_advisor_cancels_original_worker_and_rejects_wrong_result_occurrence_test() {
  use peer <- beam_owner_fixture.run(
    "client@registered_goal_check_test",
    "actual_advisor_cancels_original_worker_and_rejects_wrong_result_occurrence_test",
  )
  let f = fixture("actual-advisor")
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
        let assert Ok(Nil) = process.receive(permit, 5000)
          as "Only exact cancellation evidence releases this actual reserve worker."
        reserved
      },
      cancel_reserved: fn(actual) {
        original.cancel_reserved(actual)
        process.send(cancelled, Nil)
      },
    )
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: fn(size) { bit_array.from_string(string.repeat("x", size)) },
      clock: clock.fixed(1000),
      dispatcher: dispatcher.dispatcher(config),
    )
    as "Actual Broker and actual remote Dispatcher run, with no helper submit."
  let _ = seed(f)
  let #(actor, pid, _) = advisor_actor(f, b)
  let events = bus.start()
  let session = bus.key(of: api.session_id(f.runtime))
  bus.subscribe(events, session: session, topic: bus.Outputs)
  process.send(actor, advisor.ReevaluateTick)
  let assert Ok(#(actual, Ok(reserved), permit, worker)) =
    process.receive(held, 5000)
    as "The actual advisor worker reaches original SQL native admission."
  assert process.subject_owner(permit) == Ok(worker)
  let assert Ok(Some(api.FactCell(value, seq))) =
    api.fact_cell(f.runtime, advisor.goal_key)
    as "The actual Checking transition is durable before native admission."
  let assert Ok(goal) = goalstate.decode(value) as "Frozen goal codec."
  assert goal.phase == goalstate.Checking(6000)
  assert process.new_selector()
    |> bus.select_published(fn(published) { published })
    |> process.selector_receive(1000)
    == Ok(bus.Published(session, bus.GoalChanged))
    as "Successful registered Checking invalidates the real live goal reader after COMMIT/readback."
  let result = goalstate.CheckResult(command, goalstate.Exited(0), "old", 1000)
  process.send(actor, advisor.RegisteredCheckFinished(seq + 1, 6000, result))
  process.send(actor, advisor.CheckFinished(6000, result))
  process.send(
    actor,
    advisor.RegisteredCheckFinished(
      seq,
      6000,
      goalstate.CheckResult(
        "replacement-command",
        goalstate.Exited(0),
        "wrong",
        1000,
      ),
    ),
  )
  barrier(actor)
  assert api.fact_cell(f.runtime, advisor.goal_key)
    == Ok(Some(api.FactCell(value, seq)))
  let assert Some(ref) = actual.system_reservation
    as "Exact original ref traversed actual Broker."
  let #(_, _, origin, uuid) = dispatch.system_reservation_fields(ref)
  let assert Ok(Nil) =
    process.call(actor, waiting: 5000, sending: fn(reply) {
      advisor.ClearGoal(reply)
    })
    as "Clearing cancels this exact intent and managed worker."
  assert api.fact(f.runtime, advisor.goal_key) == Ok(None)
  bus.unsubscribe(events, session: session, topic: bus.Outputs)
  let assert Ok(Nil) = process.receive(cancelled, 5000)
    as "The actual Dispatcher caller-death path cancels its original reserved child."
  process.send(permit, Nil)
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "Actual retained native digest."
  assert original.receive(origin, reserved.key, digest, [<<"late original">>], <<
      "late terminal",
    >>)
    == Ok(Nil)
  assert custodian.receipt_generation(f.owner, origin, uuid) |> result.is_ok
  stop_advisor(pid)
  broker.stop(b)
  stop(f)
  assert scalar(
      f.owner_path,
      "SELECT COUNT(*) FROM owner_custody_children WHERE state='cancelled'",
    )
    == 1
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 1
}

pub fn mismatched_intent_and_changed_declaration_own_no_cancellation_authority_test() {
  let f = fixture("foreign-intent")
  let b = plain_broker()
  let r = runner(f, b)
  let _ = seed(f)
  let #(held, intent) = retained(f, r)
  let #(address, bytes) = work.manifest(held)
  let assert Ok(foreign) =
    custodian.retain_system_intent(
      f.owner,
      address <> "/foreign",
      custody.CommandPreparation,
      operation(),
      "goal-check",
      id(91),
      bytes,
    )
    as "A distinct real durable intent owns a distinct occurrence."
  let rejected = goalcheck.run_registered(r, held, foreign)
  assert rejected.ending
    == goalstate.DidNotFinish("the original goal work and intent do not match")
  let assert Ok(enrolled) =
    enrollment.decode(custody.enrollment_fields(pin()).4)
    as "Exact configured policy."
  let native = enrollment.native_facts(enrolled)
  let assert Ok(changed) =
    goalcheck.registered_runner(
      f.ready,
      b,
      "owner",
      native.ceiling,
      native.demand,
      [#("REPLACED", "yes")],
      "/work",
      clock.fixed(1000),
      operation(),
      1000,
      5000,
    )
    as "A replacement declaration is representable but owns no retained work."
  assert goalcheck.run_registered(changed, held, intent).ending
    == goalstate.DidNotFinish("the original goal work and intent do not match")
  let #(_, _, _, _, spec, _, _, _, _) = work.fields(held)
  let events = process.new_subject()
  let declaration =
    dispatch.SystemCommandDeclaration(
      "owner",
      spec.op_id,
      spec.step_id,
      spec.argv,
      spec.env,
      spec.cwd,
      spec.budget.deadline_ms,
    )
  let assert Ok(custodian.SystemPermission(_)) =
    custodian.allocate_system_reservation(f.owner, intent, declaration, events)
    as "Refused replacement must not cancel the original intent."
  let assert Ok(custodian.SystemPermission(_)) =
    custodian.allocate_system_reservation(f.owner, foreign, declaration, events)
    as "Refused foreign pairing must not cancel somebody else's intent."
  goalcheck.cancel_registered(r, intent)
  goalcheck.cancel_registered(r, foreign)
  broker.stop(b)
  stop(f)
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 0
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 2
}

// The injected clock has a real receiver actor. Each caller creates its own
// reply Subject; the script advances only at actual admission clock reads.
fn advancing_clock(reads: process.Subject(Int)) -> #(clock.Clock, process.Pid) {
  let assert Ok(started) =
    actor.new([1000, 1000, 1100, 6000])
    |> actor.on_message(fn(values, reply) {
      let #(value, remaining) = case values {
        [value, ..remaining] -> #(value, remaining)
        [] -> #(6000, [])
      }
      process.send(reads, value)
      process.send(reply, value)
      actor.continue(remaining)
    })
    |> actor.start
    as "Actual typed clock receiver."
  let subject = started.data
  #(
    clock.from_function(fn() {
      process.call(subject, waiting: 1000, sending: fn(reply) { reply })
    }),
    started.pid,
  )
}

pub fn real_outstanding_congestion_expires_original_deadline_without_second_submit_test() {
  use peer <- beam_owner_fixture.run(
    "client@registered_goal_check_test",
    "real_outstanding_congestion_expires_original_deadline_without_second_submit_test",
  )
  let f = fixture("deadline-congestion")
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
        let assert Ok(Nil) = process.receive(permit, 5000)
          as "Actual cancellation releases the original pending dispatch."
        reserved
      },
      cancel_reserved: fn(actual) {
        original.cancel_reserved(actual)
        process.send(cancelled, Nil)
      },
    )
  let assert Ok(b) =
    broker.start_dispatching(
      entropy: fn(size) { bit_array.from_string(string.repeat("x", size)) },
      clock: clock.fixed(1000),
      dispatcher: dispatcher.dispatcher(config),
    )
    as "Actual Broker budget and actual registered reserve."
  let r = runner(f, b)
  let _ = seed(f)
  let #(first, first_intent) = retained(f, r)
  let witness =
    weft.new([fn() { Ok(goalcheck.run_registered(r, first, first_intent)) }])
    |> weft.deadline(5000)
    |> weft.start_witnessed
  let assert Ok(#(_, Ok(_), permit)) = process.receive(held, 5000)
    as "Original native admission actually occupies the Broker slot."
  let assert Ok(Some(api.FactCell(_, seq))) =
    api.fact_cell(f.runtime, advisor.goal_key)
    as "The original Checking transition remains durable."
  let assert Ok(_) =
    api.put_reserved_fact_expecting(
      f.runtime,
      advisor.goal_key,
      goalstate.encode(before()),
      expected: Some(seq),
    )
    as "A new ordinary goal occurrence has its own observed cell."
  let reads = process.new_subject()
  let #(clock, clock_pid) = advancing_clock(reads)
  let assert Ok(enrolled) =
    enrollment.decode(custody.enrollment_fields(pin()).4)
    as "Original policy."
  let native = enrollment.native_facts(enrolled)
  let assert Ok(second_runner) =
    goalcheck.registered_runner(
      f.ready,
      b,
      "owner",
      native.ceiling,
      native.demand,
      [],
      "/work",
      clock,
      operation(),
      1000,
      5000,
    )
    as "The second check retains the same original declared deadline."
  let original_actor = process.new_subject()
  let assert Ok(#(second, second_intent)) =
    goalcheck.retain_registered(
      second_runner,
      f.runtime,
      before(),
      moved(),
      command,
      id(91),
      original_actor,
      20_000,
    )
    as "The second occurrence has its own original transition and intent."
  let checked = goalcheck.run_registered(second_runner, second, second_intent)
  assert checked.ending
    == goalstate.DidNotFinish("the original goal check deadline expired")
  assert process.receive(reads, 0) == Ok(1000)
  assert process.receive(reads, 0) == Ok(1000)
  assert process.receive(reads, 0) == Ok(1100)
  assert process.receive(reads, 0) == Ok(6000)
  assert process.receive(reads, 0) == Error(Nil)
  assert process.receive(held, 0) == Error(Nil)
  weft.cancel_witnessed(witness)
  let assert Ok(Nil) = process.receive(cancelled, 5000)
    as "The original actual dispatch is cancelled before releasing its work permit."
  process.send(permit, Nil)
  stop_advisor(clock_pid)
  broker.stop(b)
  stop(f)
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 1
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 2
}

pub fn lost_actual_checking_commit_reply_has_no_work_intent_or_launch_test() {
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
    as "Closed control arms the next actual writer COMMIT."
  let f = fixture_with_probe("lost-commit-reply", Some(probe.data))
  let b = plain_broker()
  let initial = seed(f)
  let r = runner(f, b)
  assert process.call(probe.data, waiting: 1000, sending: ArmCommit) == Nil
  let runtime = f.runtime
  let run =
    weft.new([
      fn() {
        let original_actor = process.new_subject()
        goalcheck.retain_registered(
          r,
          runtime,
          before(),
          moved(),
          command,
          id(90),
          original_actor,
          20_000,
        )
      },
    ])
    |> weft.deadline(5000)
    |> weft.start_detached
  let assert Ok(#(_, permit, writer)) = process.receive(held, 2000)
    as "The original writer actually COMMITs before holding its reply."
  let permit_owner = process.subject_owner(permit)
  weft.cancel_detached(run)
  let outcome = weft.pull(run, within: 1000)

  // Releasing the actual writer precedes every assertion about the cancelled
  // caller. Even an unexpected outcome leaves no parked SQL writer behind.
  process.send(permit, Nil)
  assert permit_owner == Ok(writer)
  assert outcome == weft.PulledOutcome(weft.Abandoned(0))
  assert weft.pull(run, within: 1000) == weft.AllDelivered
  assert api.fact_cell(f.runtime, advisor.goal_key)
    == Ok(Some(api.FactCell(goalstate.encode(moved()), initial + 1)))
  let original = process.new_subject()
  assert goalcheck.retain_registered(
      r,
      f.runtime,
      moved(),
      moved(),
      command,
      id(90),
      original,
      20_000,
    )
    == Error(work.Refused)
  broker.stop(b)
  stop(f)
  stop_advisor(probe.pid)
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM registers WHERE key LIKE 'goal/check/%'",
    )
    == 0
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 0
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 0
}

pub fn changed_immutable_work_readback_cannot_retain_system_intent_test() {
  let f = fixture("work-readback-changed")
  let b = plain_broker()
  let initial = seed(f)
  mutate(
    f.path,
    "CREATE TRIGGER alter_work AFTER INSERT ON registers WHEN NEW.key LIKE 'goal/check/%' BEGIN UPDATE registers SET seq=NEW.seq+1 WHERE key=NEW.key; END",
  )
  let original = process.new_subject()
  assert goalcheck.retain_registered(
      runner(f, b),
      f.runtime,
      before(),
      moved(),
      command,
      id(90),
      original,
      20_000,
    )
    == Error(work.Refused)
  assert api.fact_cell(f.runtime, advisor.goal_key)
    == Ok(Some(api.FactCell(goalstate.encode(moved()), initial + 1)))
  broker.stop(b)
  stop(f)
  assert scalar(
      f.path,
      "SELECT COUNT(*) FROM registers WHERE key LIKE 'goal/check/%'",
    )
    == 1
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 0
}

pub fn reopened_owner_and_replacement_advisor_grant_no_fresh_goal_authority_test() {
  let f = fixture("history-only")
  let b = plain_broker()
  let _ = seed(f)
  let r = runner(f, b)
  let #(held, intent) = retained(f, r)
  let #(seq, _, _, _, spec, _, _, _, _) = work.fields(held)
  let #(replacement, replacement_pid, _) = advisor_actor(f, b)
  process.send(
    replacement,
    advisor.RegisteredCheckFinished(
      seq,
      6000,
      goalstate.CheckResult(
        command,
        goalstate.Exited(0),
        "late original result",
        1000,
      ),
    ),
  )
  barrier(replacement)
  assert api.fact_cell(f.runtime, advisor.goal_key)
    == Ok(Some(api.FactCell(goalstate.encode(moved()), seq)))
  stop_advisor(replacement_pid)
  let original_down = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(original_down, fn(down) { down })
    |> process.selector_receive(2000)
    as "The original owner closes before reopening."
  let assert Ok(config) =
    custodian.config_with_reports(
      f.owner_path,
      session_id(),
      limits(),
      1,
      5000,
      fn(_, _, _) { effects.ToolFailed("history has no tool") },
      bootstrap.sha256,
    )
    as "Exact original persisted configuration."
  let assert Ok(config) =
    custodian.with_registered(config, pin(), association(1), 1)
    as "Reopening uses the same immutable association."
  let assert Ok(names) = registry.start() as "Independent history address."
  let history = custodian.new(names, config)
  let assert Ok(started) = custodian.start(history, config)
    as "History-only owner opens."
  assert custodian.registered(history)
    == Ok(custodian.HistoryOnly(pin(), association(1)))
  let #(address, bytes) = work.manifest(held)
  let assert Ok(observed) =
    custodian.retain_system_intent(
      history,
      address,
      custody.CommandPreparation,
      spec.op_id,
      spec.step_id,
      id(90),
      bytes,
    )
    as "Exact historical intent remains observable."
  assert custody.system_intent_fields(observed)
    == custody.system_intent_fields(intent)
  let events = process.new_subject()
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
  let down = process.monitor(started.pid)
  assert custodian.stop(history) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(down, fn(value) { value })
    |> process.selector_receive(2000)
    as "The actual history owner closes."
  broker.stop(b)
  assert api.close(f.runtime) == Ok(Nil)
  assert f.retire() == Ok(Nil)
  assert scalar(f.owner_path, "SELECT next_ordinal FROM owner_system_ordinal")
    == 0
  assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
    == 0
}

pub fn failed_or_changed_original_intent_retention_grants_no_launch_test() {
  let cases = [
    #(
      "intent-write-refused",
      "CREATE TRIGGER refuse_intent BEFORE INSERT ON owner_system_intent BEGIN SELECT RAISE(ABORT, 'refused intent'); END",
      0,
    ),
    #(
      "intent-readback-changed",
      "CREATE TRIGGER change_intent AFTER INSERT ON owner_system_intent BEGIN UPDATE owner_system_intent SET intent_bytes=x'00' WHERE intent_address=NEW.intent_address; END",
      1,
    ),
  ]
  list.each(cases, fn(control) {
    let #(name, fault, retained_count) = control
    let f = fixture(name)
    let b = plain_broker()
    let initial = seed(f)
    mutate(f.owner_path, fault)
    let original = process.new_subject()
    assert goalcheck.retain_registered(
        runner(f, b),
        f.runtime,
        before(),
        moved(),
        command,
        id(90),
        original,
        20_000,
      )
      == Error(work.Refused)
    assert api.fact_cell(f.runtime, advisor.goal_key)
      == Ok(Some(api.FactCell(goalstate.encode(moved()), initial + 1)))
    broker.stop(b)
    stop(f)
    assert scalar(
        f.path,
        "SELECT COUNT(*) FROM registers WHERE key LIKE 'goal/check/%'",
      )
      == 1
    assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent")
      == retained_count
    assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_custody_children")
      == 0
  })
}

pub fn refused_or_unknown_registered_checking_does_not_publish_goal_changed_test() {
  let cases = [
    #(
      "refused-publication",
      "CREATE TRIGGER refuse_check BEFORE UPDATE ON registers WHEN NEW.key='goal/state' BEGIN SELECT RAISE(ABORT, 'refused Checking'); END",
      before(),
      0,
    ),
    #(
      "unknown-publication",
      "CREATE TRIGGER change_check AFTER UPDATE ON registers WHEN NEW.key='goal/state' BEGIN UPDATE registers SET seq=NEW.seq+1 WHERE key=NEW.key; END",
      moved(),
      2,
    ),
  ]
  list.each(cases, fn(control) {
    let #(name, fault, durable, advanced) = control
    let f = fixture(name)
    let b = plain_broker()
    let #(original, pid, _) = advisor_actor(f, b)
    let initial = seed(f)
    mutate(f.path, fault)
    let events = bus.start()
    let session = bus.key(of: api.session_id(f.runtime))
    bus.subscribe(events, session: session, topic: bus.Outputs)
    process.send(original, advisor.ReevaluateTick)

    // The original actor's barrier reply follows this failed evaluation. The
    // same publisher sends GoalChanged directly, so an earlier false publish
    // would already be in this subscriber's mailbox when the barrier returns.
    barrier(original)
    assert process.new_selector()
      |> bus.select_published(fn(published) { published })
      |> process.selector_receive(0)
      == Error(Nil)
      as "Refused or uncertain registered writes cannot claim live goal publication."
    assert api.fact_cell(f.runtime, advisor.goal_key)
      == Ok(Some(api.FactCell(goalstate.encode(durable), initial + advanced)))
    bus.unsubscribe(events, session: session, topic: bus.Outputs)
    stop_advisor(pid)
    broker.stop(b)
    stop(f)
    assert scalar(
        f.path,
        "SELECT COUNT(*) FROM registers WHERE key LIKE 'goal/check/%'",
      )
      == 0
    assert scalar(f.owner_path, "SELECT COUNT(*) FROM owner_system_intent") == 0
  })
}

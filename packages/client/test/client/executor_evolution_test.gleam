//// The executor's evolution actor over generations built by hand.
////
//// `executor_evolution` keeps the rules of a scope's executable slot: one
//// serving generation, a stage that joins what already exists, a prepared
//// successor that serves nothing until it is published, and a retirement that
//// is terminal. None of those rules needs a jail, a helper or a satellite, so
//// this suite starts the actor over an `Engine` of counting closures and
//// drives it with the protocol's own requests, the way the host does. It runs
//// in `make check` on every platform.
////
//// The closures record what they did in a `Journal`, an actor the test
//// process owns. A closure runs in the generation's owner task or in the
//// actor itself, so a counter that only its creator could read would not
//// reach the assertion. Every closure records before the actor answers the
//// request that ran it, so a count read after an answer includes the
//// closure's own entry. A stage can be held on a subject the test releases,
//// which is how a request is made to arrive while a build is in flight. The
//// cases restate the P model's evolution probes
//// (`protocol/models/remote-execution/PTst/EvolutionProbes.p`) and the
//// terminal-close requirement of the #1092 review.
////
//// ## Flow
////
//// `start` → `engine_of` → `build` → `staged_over` → `journal`

import client/evolution/evaluate
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/staged
import client/evolution/store
import client/executor_evolution
import client/extension/archive
import client/extension/hooks
import client/remote/host
import client/remote/protocol.{type Handle, type Refusal}
import core/json
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import runtime/effects
import support/remote_fixtures as fixtures
import telemetry/log
import tools/tool
import weft/poll

/// An executor under test and what the test needs to watch it.
type Rig {
  Rig(
    journal: Journal,
    /// A held stage sends the subject that releases it here.
    started: Subject(Subject(Nil)),
    executor: executor_evolution.Executor,
    plane: host.Evolution,
  )
}

// --- what the closures record -------------------------------------------------

/// One thing a closure of the engine did.
type Event {
  /// `Engine.stage` started for this generation.
  Built(generation: Int)

  /// A generation's `retire` task ran, successfully or not.
  Retired(generation: Int)

  /// A prepared successor's `publish` ran.
  Published(generation: Int)

  /// A prepared successor's `abort` ran.
  Aborted(generation: Int)

  /// The retry witness of a stage that failed with an unconfirmed cleanup ran.
  Retried
}

/// A request to the journal actor.
type Entry {
  Note(event: Event)
  Count(event: Event, reply: Subject(Int))
}

/// The record of the closures' work, held by an actor so that a closure in any
/// process can write to it and the test can read it afterwards.
type Journal {
  Journal(inbox: Subject(Entry))
}

/// Starts a journal. The actor is linked to the test process, which is the only
/// process whose end it must outlive.
fn journal() -> Journal {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(events, entry) {
      // A note extends the history. A count only reads it, so a reader never
      // changes what a later reader sees.
      case entry {
        Note(event:) -> actor.continue([event, ..events])

        Count(event:, reply:) -> {
          process.send(reply, list.count(events, fn(each) { each == event }))
          actor.continue(events)
        }
      }
    })
    |> actor.start
    as "the journal starts"
  Journal(inbox: started.data)
}

/// Records that a closure did something.
fn note(journal: Journal, event: Event) -> Nil {
  process.send(journal.inbox, Note(event))
}

/// How many times `event` has been recorded.
fn count(rig: Rig, event: Event) -> Int {
  process.call(rig.journal.inbox, 5000, Count(event, _))
}

// --- the engine ---------------------------------------------------------------

/// Whether a build returns at once or waits for the test to release it.
type Gate {
  Free
  Held
}

/// How the engine behaves, by generation number.
type Plan {
  Plan(
    /// Whether `stage` blocks before it builds.
    gate: Gate,
    /// Generations whose `retire` fails once and then succeeds.
    flaky: List(Int),
    /// Generations whose stage fails with an unconfirmed cleanup, whose retry
    /// witness fails once and then succeeds.
    doomed: List(Int),
    /// Generations whose stage dies once released, so the owner task ends
    /// without ever reporting a generation.
    crashing: List(Int),
  )
}

/// A plan in which every build returns at once and every retire succeeds.
fn plain() -> Plan {
  Plan(gate: Free, flaky: [], doomed: [], crashing: [])
}

/// A plan in which every build waits for the test.
fn held() -> Plan {
  Plan(..plain(), gate: Held)
}

/// Starts the actor over the engine `plan` describes.
fn start(plan: Plan) -> Rig {
  let journal = journal()
  let started = process.new_subject()
  let assert Ok(executor) =
    executor_evolution.start_over(
      engine_of(journal, started, plan),
      log.discard(),
    )
    as "the evolution actor starts"
  Rig(journal:, started:, executor:, plane: executor_evolution.plane(executor))
}

/// The five closures of the engine. The two host-side ones answer a fixed
/// value, because the cases read whether they were reached, not what they say.
fn engine_of(
  journal: Journal,
  started: Subject(Subject(Nil)),
  plan: Plan,
) -> executor_evolution.Engine {
  executor_evolution.Engine(
    stage: fn(selection, _candidate) {
      build(journal, started, plan, selection)
    },
    snapshot: fn(_coordinates, _directory) {
      Ok(archive.Tree(root: "extension", files: [], commit: None))
    },
    evaluate: fn(_coordinates, _candidate) {
      Ok(evaluate.Report(record.Passed, "{}"))
    },
    program: fn(_coordinates, _candidate, _args) {
      fixtures.evolution_outcome("program")
    },
    promoted: fn(_coordinates, _declared, _args) {
      fixtures.evolution_outcome("promoted")
    },
  )
}

/// The body of `Engine.stage`. It runs in the generation's owner task, so a
/// held build parks that task and not the actor.
fn build(
  journal: Journal,
  started: Subject(Subject(Nil)),
  plan: Plan,
  selection: record.Selection,
) -> Result(staged.Staged, store.Refusal) {
  note(journal, Built(selection.generation))

  // A held build parks here until the test releases it.
  case plan.gate {
    Free -> Nil

    // The release subject is created here because only the process that
    // creates a subject can receive on it.
    Held -> {
      let release = process.new_subject()
      process.send(started, release)
      process.receive_forever(release)
    }
  }

  // A crashing build ends its owner here, after the release and before any
  // report, which is the one way an owner dies while its stage is in flight.
  case list.contains(plan.crashing, selection.generation) {
    True -> panic as "the owner dies mid-build"
    False -> Nil
  }

  // A doomed generation fails with a retry witness the custody must perform.
  case list.contains(plan.doomed, selection.generation) {
    True ->
      Error(store.CleanupUnconfirmed(
        "pool still draining",
        retirement.first(
          fn() {
            note(journal, Retried)
            Error("pool still draining")
          },
          fn() {
            note(journal, Retried)
            Ok(Nil)
          },
        ),
      ))

    False ->
      Ok(staged_over(
        journal,
        selection,
        retire_of(journal, plan, selection.generation),
      ))
  }
}

/// The retire task of one generation: it records every attempt, and a flaky
/// generation fails its first.
fn retire_of(journal: Journal, plan: Plan, generation: Int) -> retirement.Task {
  case list.contains(plan.flaky, generation) {
    True ->
      retirement.first(
        fn() {
          note(journal, Retired(generation))
          Error(draining(generation))
        },
        fn() {
          note(journal, Retired(generation))
          Ok(Nil)
        },
      )

    False ->
      retirement.repeat(fn() {
        note(journal, Retired(generation))
        Ok(Nil)
      })
  }
}

/// A generation with one tool, one hook event and an in-place upgrade. A
/// successor it prepares shares `retire`, as the real one shares its
/// predecessor's host and plane.
fn staged_over(
  journal: Journal,
  selection: record.Selection,
  retire: retirement.Task,
) -> staged.Staged {
  staged.Staged(
    name: selection.name,
    selection:,
    tools: [echo_tool()],
    events: ["on_event"],
    invoke: fn(_event, _payload, _within) { Ok(msgpack.NilValue) },
    inventory: fn() { Ok(json.Null) },
    retire:,
    upgrade: Some(
      staged.Upgrade(prepare: fn(next, _candidate) {
        let label = next.generation
        Ok(
          staged.PreparedStaged(
            successor: staged_over(journal, next, retire),
            publish: fn() {
              note(journal, Published(label))
              Ok(Nil)
            },
            abort: fn() {
              note(journal, Aborted(label))
              Ok(Nil)
            },
          ),
        )
      }),
    ),
  )
}

/// The tool every generation declares. The engine's `promoted` closure never
/// calls it; the actor only has to find it by name.
fn echo_tool() -> tool.Tool {
  tool.Tool(
    name: "echo",
    description: "echoes",
    prompt_snippet: None,
    schema: tool.object_schema([], []),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: tool.read_requirements,
    run: fn(_ctx, _args) { tool.success("echo") },
  )
}

// --- selections ---------------------------------------------------------------

/// A candidate, and another with a different content address.
fn candidate_a() -> record.Candidate {
  record_test.candidate()
}

fn candidate_b() -> record.Candidate {
  record.identified(record.Candidate(..record_test.candidate(), name: "other"))
}

/// The selection of `candidate` at `generation`.
fn selecting(candidate: record.Candidate, generation: Int) -> record.Selection {
  record.Selection(
    candidate.id,
    record.evidence_placeholder(),
    candidate.scope,
    candidate.name,
    generation,
  )
}

fn coordinates() -> protocol.Coordinates {
  fixtures.evolution_coordinates("s1", "step")
}

// --- driving the actor --------------------------------------------------------

/// Waits for the actor's answer, which every request owes within a bound.
fn await(reply: Subject(a)) -> a {
  let assert Ok(answer) = process.receive(reply, 10_000)
    as "the actor answers within its bound"
  answer
}

/// Sends a stage request and returns where its answer will arrive.
fn send_stage(
  rig: Rig,
  candidate: record.Candidate,
  generation: Int,
) -> Subject(Result(protocol.Staged, Refusal)) {
  let reply = process.new_subject()
  rig.plane.serve(protocol.StageRequest(
    selection: selecting(candidate, generation),
    candidate:,
    reply:,
  ))
  reply
}

/// Stages and waits for the answer.
fn stage(
  rig: Rig,
  candidate: record.Candidate,
  generation: Int,
) -> Result(protocol.Staged, Refusal) {
  await(send_stage(rig, candidate, generation))
}

/// A stage the test expects to be admitted.
fn staged_ok(answer: Result(protocol.Staged, Refusal)) -> protocol.Staged {
  let assert Ok(admitted) = answer as "the stage was admitted"
  admitted
}

/// Sends one step of a migration and waits for the answer.
fn transition(
  rig: Rig,
  step: protocol.TransitionStep,
) -> Result(protocol.TransitionAnswer, Refusal) {
  let reply = process.new_subject()
  rig.plane.serve(protocol.TransitionRequest(step:, reply:))
  await(reply)
}

/// Prepares `candidate` at `generation` as the successor of `handle`.
fn prepare(
  rig: Rig,
  handle: Handle,
  candidate: record.Candidate,
  generation: Int,
) -> Result(protocol.TransitionAnswer, Refusal) {
  transition(
    rig,
    protocol.Prepare(
      handle:,
      selection: selecting(candidate, generation),
      candidate:,
    ),
  )
}

/// The successor handle of a prepare the test expects to be admitted.
fn successor_of(answer: Result(protocol.TransitionAnswer, Refusal)) -> Handle {
  let assert Ok(protocol.TransitionPrepared(protocol.Prepared(successor:, ..))) =
    answer
    as "the prepare was admitted"
  successor
}

/// Delivers one hook event.
fn hook(
  rig: Rig,
  handle: Handle,
) -> Result(msgpack.MsgPackValue, hooks.HookFailure) {
  let reply = process.new_subject()
  rig.plane.serve(protocol.HookRequest(
    handle:,
    event: "on_event",
    payload: msgpack.NilValue,
    within_ms: 1000,
    reply:,
  ))
  await(reply)
}

/// Asks for a generation's helper census.
fn inventory(rig: Rig, handle: Handle) -> Result(json.JsonValue, Refusal) {
  let reply = process.new_subject()
  rig.plane.serve(protocol.InventoryRequest(handle:, reply:))
  await(reply)
}

/// Asks for a snapshot of the workspace's `extension` directory.
fn snapshot(rig: Rig) -> Result(archive.Tree, Refusal) {
  let reply = process.new_subject()
  rig.plane.serve(protocol.SnapshotRequest(
    coordinates: coordinates(),
    directory: "extension",
    reply:,
  ))
  await(reply)
}

/// Retires one generation by handle.
fn retire(rig: Rig, handle: Handle) -> Result(protocol.CloseOutcome, Refusal) {
  let reply = process.new_subject()
  rig.plane.serve(protocol.RetireRequest(handle:, reply:))
  await(reply)
}

/// What a host-side run came to, reduced to the two cases the cases read.
type Ran {
  Completed
  Failed(reason: String)
}

fn ran(outcome: effects.ToolOutcome) -> Ran {
  case outcome {
    effects.ToolCompleted(..) -> Completed
    effects.ToolFailed(reason:) -> Failed(reason)
  }
}

/// Runs the echo tool of `handle` the way the host does.
fn run_promoted(rig: Rig, handle: Handle) -> Ran {
  ran(rig.plane.run(
    coordinates(),
    protocol.Promoted(handle:, tool: "echo"),
    json.Null,
  ))
}

/// Runs a program candidate the way the host does.
fn run_program(rig: Rig) -> Ran {
  ran(rig.plane.run(
    coordinates(),
    protocol.Program(candidate: candidate_a()),
    json.Null,
  ))
}

/// What the host's `evaluate` came to, as the JSON report decoded.
fn evaluated(rig: Rig) -> Result(Result(evaluate.Report, String), String) {
  executor_evolution.decode_report(rig.plane.evaluate(
    coordinates(),
    candidate_a(),
  ))
}

/// Blocks until the actor has handled every request this process sent before
/// it. The admission question comes from the same sender, so the actor reads it
/// after them.
fn barrier(rig: Rig) -> Nil {
  let _ = evaluated(rig)
  Nil
}

/// Waits for the stage the engine holds and returns the subject that releases
/// it.
fn await_held(rig: Rig) -> Subject(Nil) {
  await(rig.started)
}

/// Whether a refusal says the plane is retired, or else what it said.
type Door {
  Shut
  Ajar(detail: String)
}

/// Reduces a refusal to whether it says the plane is retired, so a failed
/// assertion shows the refusal the actor gave instead.
fn door(answer: Result(a, Refusal)) -> Door {
  case answer {
    Error(protocol.NoEvolution(_)) -> Shut

    Error(other) -> Ajar(protocol.describe(other))

    Ok(_) -> Ajar("the request was served")
  }
}

/// Ends a test that left the plane open, so the owner tasks of its generations
/// drain before the next test starts.
fn finish(rig: Rig) -> Nil {
  assert executor_evolution.retire_all(rig.executor) == Ok(Nil)
}

/// A handle no stage of this actor issued.
fn stranger() -> Handle {
  protocol.Handle(boot: <<0>>, ordinal: 99)
}

// --- one slot -----------------------------------------------------------------

/// A newer stage takes the slot and the older generation stops serving, but
/// stays inventoried until it is retired so its calls in flight can finish.
pub fn one_generation_serves_at_a_time_test() {
  let rig = start(plain())
  let first = staged_ok(stage(rig, candidate_a(), 1))
  assert run_promoted(rig, first.handle) == Completed

  let second = staged_ok(stage(rig, candidate_b(), 2))

  // The first generation is reported as superseded and no longer answers.
  assert second.superseded == [first.handle]
  assert first.superseded == []
  assert hook(rig, first.handle) == Error(hooks.Gone)
  assert hook(rig, second.handle) == Ok(msgpack.NilValue)
  assert run_promoted(rig, second.handle) == Completed
  assert run_promoted(rig, first.handle)
    == Failed(protocol.describe(protocol.UnknownHandle))

  // The superseded generation is retired separately, once, by its own handle.
  assert retire(rig, first.handle) == Ok(protocol.AllRetired)
  assert count(rig, Retired(1)) == 1
  assert count(rig, Retired(2)) == 0
  finish(rig)
}

/// A second request for the pair being built waits for the one build, so a
/// retry racing the first request does not start a second generation.
pub fn a_stage_for_the_pair_in_flight_joins_it_test() {
  let rig = start(held())
  let first = send_stage(rig, candidate_a(), 1)
  let release = await_held(rig)
  let second = send_stage(rig, candidate_a(), 1)

  // The barrier proves the actor has read the second request while the build
  // is still parked.
  barrier(rig)
  process.send(release, Nil)

  let one = staged_ok(await(first))
  let two = staged_ok(await(second))
  assert one.handle == two.handle
  assert count(rig, Built(1)) == 1
  finish(rig)
}

/// A stage sent again after a lost reply, or by a restarted runtime, finds its
/// generation instead of building a second one.
pub fn a_stage_for_the_serving_pair_answers_its_handle_test() {
  let rig = start(plain())
  let first = staged_ok(stage(rig, candidate_a(), 1))

  let again = staged_ok(stage(rig, candidate_a(), 1))

  assert again == first
  assert count(rig, Built(1)) == 1
  finish(rig)
}

/// A generation only increases, so a stage that is not newer than what the slot
/// holds is a dead runtime's message and must not build.
pub fn an_older_or_equal_generation_is_stale_test() {
  let rig = start(plain())
  staged_ok(stage(rig, candidate_a(), 1)) |> ignore
  staged_ok(stage(rig, candidate_b(), 2)) |> ignore

  // Older than the serving generation, and equal to it under another candidate.
  assert stage(rig, candidate_a(), 1) == Error(protocol.StaleGeneration(2))
  assert stage(rig, candidate_a(), 2) == Error(protocol.StaleGeneration(2))
  assert stage(rig, candidate_b(), 1) == Error(protocol.StaleGeneration(2))

  // None of them started a build.
  assert count(rig, Built(1)) == 1
  assert count(rig, Built(2)) == 1
  finish(rig)
}

/// Throws away a value the test has already checked.
fn ignore(_value: a) -> Nil {
  Nil
}

// --- the in-place successor ---------------------------------------------------

/// A stage that supersedes the generation a successor was prepared from
/// discards the successor, because it was built from state that is gone.
pub fn a_stage_aborts_an_unpublished_successor_test() {
  let rig = start(plain())
  let first = staged_ok(stage(rig, candidate_a(), 1))
  let successor = successor_of(prepare(rig, first.handle, candidate_b(), 2))
  assert count(rig, Aborted(2)) == 0

  let third = staged_ok(stage(rig, candidate_a(), 3))

  assert count(rig, Aborted(2)) == 1
  assert count(rig, Published(2)) == 0
  assert third.superseded == [first.handle]

  // The discarded successor can no longer be published.
  assert transition(rig, protocol.Publish(first.handle, successor))
    == Error(protocol.UnknownHandle)
  finish(rig)
}

/// A prepare never joins an earlier successor, whose state may be older than
/// the generation's: it aborts the unpublished one and prepares anew.
pub fn a_prepare_replaces_an_unpublished_successor_test() {
  let rig = start(plain())
  let first = staged_ok(stage(rig, candidate_a(), 1))
  let early = successor_of(prepare(rig, first.handle, candidate_b(), 2))

  let late = successor_of(prepare(rig, first.handle, candidate_b(), 3))

  assert early != late
  assert count(rig, Aborted(2)) == 1
  assert count(rig, Aborted(3)) == 0

  // Only the later successor is held.
  assert transition(rig, protocol.Publish(first.handle, early))
    == Error(protocol.UnknownHandle)
  assert transition(rig, protocol.Publish(first.handle, late))
    == Ok(protocol.TransitionPublished)
  finish(rig)
}

/// A publish whose reply was lost is sent again, and the migration must not be
/// applied twice.
pub fn publish_is_idempotent_test() {
  let rig = start(plain())
  let first = staged_ok(stage(rig, candidate_a(), 1))
  let successor = successor_of(prepare(rig, first.handle, candidate_b(), 2))

  let once = transition(rig, protocol.Publish(first.handle, successor))
  let twice = transition(rig, protocol.Publish(first.handle, successor))

  assert once == Ok(protocol.TransitionPublished)
  assert twice == Ok(protocol.TransitionPublished)
  assert count(rig, Published(2)) == 1

  // The successor serves and the generation it replaced does not.
  assert hook(rig, successor) == Ok(msgpack.NilValue)
  assert hook(rig, first.handle) == Error(hooks.Gone)
  finish(rig)
}

/// Once a successor serves, discarding it would undo a migration the caller
/// already has the answer to.
pub fn abort_after_publish_is_already_published_test() {
  let rig = start(plain())
  let first = staged_ok(stage(rig, candidate_a(), 1))
  let successor = successor_of(prepare(rig, first.handle, candidate_b(), 2))
  assert transition(rig, protocol.Publish(first.handle, successor))
    == Ok(protocol.TransitionPublished)

  let aborted = transition(rig, protocol.Abort(first.handle, successor))

  assert aborted == Error(protocol.AlreadyPublished)
  assert count(rig, Aborted(2)) == 0
  assert hook(rig, successor) == Ok(msgpack.NilValue)
  finish(rig)
}

/// An abort of a transition the plane does not hold has nothing to undo, so a
/// retry after a lost reply is answered the same way.
pub fn abort_of_an_unheld_successor_is_aborted_test() {
  let rig = start(plain())
  let first = staged_ok(stage(rig, candidate_a(), 1))

  let aborted = transition(rig, protocol.Abort(first.handle, stranger()))

  assert aborted == Ok(protocol.TransitionAborted)
  assert count(rig, Aborted(2)) == 0
  finish(rig)
}

// --- retire -------------------------------------------------------------------

/// A retire that finds nothing has nothing left to stop, which makes a retry
/// after a lost reply safe.
pub fn retire_of_an_unknown_handle_is_all_retired_test() {
  let rig = start(plain())
  let first = staged_ok(stage(rig, candidate_a(), 1))

  assert retire(rig, stranger()) == Ok(protocol.AllRetired)

  // The serving generation was not touched.
  assert hook(rig, first.handle) == Ok(msgpack.NilValue)
  assert count(rig, Retired(1)) == 0
  finish(rig)
}

/// The reason a flaky generation's first retire gives. It names the generation
/// so a case can tell which refusal a close reported.
fn draining(generation: Int) -> String {
  "helper pool of generation " <> int.to_string(generation) <> " still draining"
}

/// When several retires refuse, the close names the first one the sweep met.
/// The sweep retires the serving generation before those that stopped serving,
/// so with both refusing the serving one's reason is the answer.
pub fn retire_all_names_the_first_refusal_in_sweep_order_test() {
  let rig = start(Plan(..plain(), flaky: [1, 2]))
  staged_ok(stage(rig, candidate_a(), 1)) |> ignore
  staged_ok(stage(rig, candidate_b(), 2)) |> ignore

  assert executor_evolution.retire_all(rig.executor) == Error(draining(2))
  assert count(rig, Retired(1)) == 1
  assert count(rig, Retired(2)) == 1

  // Both refusals were kept, so the second close retries both.
  assert executor_evolution.retire_all(rig.executor) == Ok(Nil)
  assert count(rig, Retired(1)) == 2
  assert count(rig, Retired(2)) == 2
}

/// The custody's retirement reaches the serving generation, the one a newer
/// stage superseded and a successor prepared beside it, answers the first
/// failure, and keeps what failed for the next call.
pub fn retire_all_retires_everything_and_retries_what_failed_test() {
  let rig = start(Plan(..plain(), flaky: [1]))
  staged_ok(stage(rig, candidate_a(), 1)) |> ignore
  let second = staged_ok(stage(rig, candidate_b(), 2))
  successor_of(prepare(rig, second.handle, candidate_a(), 3)) |> ignore

  let first_close = executor_evolution.retire_all(rig.executor)

  // The superseded generation refused; the other two did not stop at its refusal.
  assert first_close == Error(draining(1))
  assert count(rig, Aborted(3)) == 1
  assert count(rig, Retired(2)) == 1
  assert count(rig, Retired(1)) == 1

  // The second call performs only the retirement that remains.
  assert executor_evolution.retire_all(rig.executor) == Ok(Nil)
  assert count(rig, Retired(1)) == 2
  assert count(rig, Retired(2)) == 1
  assert count(rig, Aborted(3)) == 1
}

/// A stage that failed with its cleanup unconfirmed leaves a retry witness, and
/// the custody must perform it.
pub fn retire_all_retries_the_cleanup_of_a_failed_stage_test() {
  let rig = start(Plan(..plain(), doomed: [1]))
  let failed = stage(rig, candidate_a(), 1)
  assert failed
    == Error(protocol.ExecutorFault("cleanup unconfirmed: pool still draining"))

  assert executor_evolution.retire_all(rig.executor)
    == Error("pool still draining")
  assert count(rig, Retried) == 1

  assert executor_evolution.retire_all(rig.executor) == Ok(Nil)
  assert count(rig, Retried) == 2
}

// --- a waiter that dies -------------------------------------------------------

/// The build belongs to the actor and not to the process that asked for it, so
/// a requester that exits does not cancel it and a later request finds it.
pub fn a_dead_waiter_does_not_cancel_the_stage_test() {
  let rig = start(held())
  let candidate = candidate_a()
  let selection = selecting(candidate, 1)
  let _requester =
    process.spawn_unlinked(fn() {
      rig.plane.serve(protocol.StageRequest(
        selection:,
        candidate:,
        reply: process.new_subject(),
      ))
    })
  let release = await_held(rig)
  process.send(release, Nil)

  let later = staged_ok(stage(rig, candidate, 1))

  assert count(rig, Built(1)) == 1
  assert hook(rig, later.handle) == Ok(msgpack.NilValue)
  finish(rig)
}

// --- an owner that dies -------------------------------------------------------

/// An owner that dies before it reports takes what it started with it. The
/// stage's waiters are told the stage ended without a generation, nothing is
/// left serving, and a later stage for a newer generation builds normally.
pub fn an_owner_that_dies_mid_build_answers_its_waiters_test() {
  let rig = start(Plan(..held(), crashing: [1]))
  let waiter = send_stage(rig, candidate_a(), 1)
  let release = await_held(rig)
  process.send(release, Nil)

  assert await(waiter)
    == Error(protocol.ExecutorFault("the stage ended without a generation"))
  assert count(rig, Retired(1)) == 0
  finish(rig)
}

/// A close waiting on a stage whose owner dies finishes when the loss is
/// known, and answers `Ok`: the dead owner's resources went down with it, so
/// there is nothing left to retire and no retire is attempted for it.
pub fn a_close_waiting_on_a_dying_owner_finishes_test() {
  let rig = start(Plan(..held(), crashing: [1]))
  let waiter = send_stage(rig, candidate_a(), 1)
  let release = await_held(rig)
  let closed = process.new_subject()
  let _closer =
    process.spawn_unlinked(fn() {
      process.send(closed, executor_evolution.retire_all(rig.executor))
    })
  await_closing(rig)
  process.send(release, Nil)

  assert await(closed) == Ok(Nil)
  assert await(waiter)
    == Error(protocol.ExecutorFault("the stage ended without a generation"))
  assert count(rig, Retired(1)) == 0
  assert_shut(rig, stranger())
}

// --- closing is terminal ------------------------------------------------------

/// Every request the host can pass to a retired actor, and the answer each
/// must give.
fn assert_shut(rig: Rig, serving: Handle) -> Nil {
  // The requests that would change what the slot holds.
  assert door(stage(rig, candidate_b(), 9)) == Shut
  assert door(prepare(rig, serving, candidate_b(), 9)) == Shut
  assert door(transition(rig, protocol.Publish(serving, stranger()))) == Shut
  assert door(transition(rig, protocol.Abort(serving, stranger()))) == Shut

  // The requests that read it.
  assert hook(rig, serving) == Error(hooks.Gone)
  assert door(inventory(rig, serving)) == Shut
  assert door(snapshot(rig)) == Shut

  // The host's two keyed calls, which ask the actor before they run.
  assert evaluated(rig) == Ok(Error("unavailable: " <> retired_text()))
  assert run_promoted(rig, serving) == Failed(retired_text())
  assert run_program(rig) == Failed(retired_text())
}

/// How the host words the refusal a retired plane gives its keyed calls.
fn retired_text() -> String {
  protocol.describe(protocol.NoEvolution(
    "the scope's evolution plane has been retired",
  ))
}

/// A close that arrives while a stage is building waits for it, tells the
/// stage's waiters the plane is retired, and retires what it built.
pub fn a_close_during_a_stage_awaits_it_and_retires_its_generation_test() {
  let rig = start(held())
  let waiter = send_stage(rig, candidate_a(), 1)
  let release = await_held(rig)
  let closed = process.new_subject()
  let _closer =
    process.spawn_unlinked(fn() {
      process.send(closed, executor_evolution.retire_all(rig.executor))
    })
  await_closing(rig)

  // While the stage is parked the close is pending and the plane already
  // refuses new work.
  assert door(stage(rig, candidate_b(), 2)) == Shut
  assert door(snapshot(rig)) == Shut
  assert count(rig, Retired(1)) == 0
  process.send(release, Nil)

  assert await(closed) == Ok(Nil)
  assert door(await(waiter)) == Shut
  assert count(rig, Retired(1)) == 1
  assert_shut(rig, stranger())
}

/// Blocks until the actor refuses work, which is the observable that a
/// `retire_all` has reached it.
fn await_closing(rig: Rig) -> Nil {
  let closing =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case evaluated(rig) {
        Ok(Error(_)) -> poll.Done(Nil)

        Ok(Ok(_)) | Error(_) -> poll.Retry
      }
    })
  assert closing == poll.Answered(Nil)
}

/// A close after the stage completed retires the serving generation, and the
/// plane then refuses every kind of request.
pub fn a_close_after_a_stage_retires_the_serving_generation_test() {
  let rig = start(plain())
  let serving = staged_ok(stage(rig, candidate_a(), 1))
  assert run_promoted(rig, serving.handle) == Completed
  assert evaluated(rig) == Ok(Ok(evaluate.Report(record.Passed, "{}")))

  assert executor_evolution.retire_all(rig.executor) == Ok(Nil)

  assert count(rig, Retired(1)) == 1
  assert_shut(rig, serving.handle)

  // A retire is still served and finds nothing, and a second close has
  // nothing left to do.
  assert retire(rig, serving.handle) == Ok(protocol.AllRetired)
  assert executor_evolution.retire_all(rig.executor) == Ok(Nil)
  assert count(rig, Retired(1)) == 1
}

// --- the evaluate report ------------------------------------------------------

/// The report crosses the wire as JSON, so what the host stores must read back
/// as the verdict it held.
pub fn reports_round_trip_through_json_test() {
  let reports = [
    evaluate.Report(record.Passed, "{\"ok\":true}"),
    evaluate.Report(record.Failed, "{\"failed\":1}"),
    evaluate.Report(record.Inconclusive("the helper timed out"), "{}"),
  ]
  list.each(reports, fn(report) {
    assert executor_evolution.decode_report(
        executor_evolution.report_json(Ok(report)),
      )
      == Ok(Ok(report))
  })
}

/// A refusal reads back as the reason the machine gave, apart from a report.
pub fn a_refusal_round_trips_through_json_test() {
  let wire = executor_evolution.report_json(Error(store.Busy))

  assert executor_evolution.decode_report(wire)
    == Ok(Error(store.describe(store.Busy)))
}

/// A value that is neither a report nor a refusal is a lost answer, never a
/// verdict.
pub fn a_value_that_is_not_a_report_is_an_error_test() {
  assert executor_evolution.decode_report(json.Null)
    == Error("the report is not a JSON object")
  assert executor_evolution.decode_report(
      json.Object([#("status", json.String("reported"))]),
    )
    == Error("the report has no text field `verdict`")
}

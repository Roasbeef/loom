//// The remote evolution machine against a fake executor with a scripted
//// evolution plane.
////
//// The executor is the real host over a real ledger in this VM, so each message
//// crosses the same fence, admission and reply path a registered session's does.
//// Its evolution plane (`support/remote_evolution`) answers from a script and
//// reports every request it served, which is how these tests show what reached
//// the executor: a refusal sent nothing, and a promoted tool's call sent one
//// `EvolutionRun`.

import broker/broker
import broker/exec
import broker/policy
import client/evolution/candidate
import client/evolution/live
import client/evolution/machine
import client/evolution/machine/remote
import client/evolution/record
import client/evolution/record_test
import client/evolution/retirement
import client/evolution/store
import client/executor_evolution
import client/extension/hooks
import client/internal/ffi_os
import client/remote/protocol
import client/remote/workspace
import core/clock
import core/ids
import core/json
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import runtime/effects
import session/session
import support/remote_evolution as plane
import support/remote_fixtures as fixtures
import support/remote_orchestrator as rig
import tools/directory_access
import tools/tool

// --- the rig --------------------------------------------------------------------

// A session, a fake executor that compiles, the machine over the link the
// session's attach returned, and the catalogue the machine is handed.
type Rig {
  Rig(
    executor: rig.Executor,
    hands: workspace.Hands,
    machine: machine.Machine,
    seen: Subject(plane.Seen),
    catalogue: store.Store,
    root: String,
    candidate: record.Candidate,
    selection: record.Selection,
  )
}

fn extension_candidate() -> record.Candidate {
  record_test.candidate()
}

fn program_candidate() -> record.Candidate {
  record.identified(
    record.Candidate(
      ..record_test.candidate(),
      name: "summarize",
      kind: record.Program,
      scope: record.Workspace("executor:box/registered-name"),
      files: [#("program.gleam", "pub fn run() { 1 }")],
    ),
  )
}

// A catalogue holding `candidate`, approved and selected, and the selection.
fn selected(
  candidate: record.Candidate,
) -> #(store.Store, String, record.Candidate, record.Selection) {
  let root =
    "build/test_db/remote-machine-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(catalogue) =
    store.open(
      root,
      store.Owner,
      candidate.identity,
      clock.fixed(at: 1_700_000_000_000),
    )
    as "the catalogue opens"
  let assert Ok(candidate) = store.propose(catalogue, candidate)
    as "the candidate is proposed"
  let assert Ok(evidence) =
    store.record_evidence(
      catalogue,
      candidate.id,
      record.AuthorTests,
      record.Passed,
      "{}",
    )
    as "passing evidence is recorded"
  let assert Ok(Nil) =
    store.approve(
      catalogue,
      candidate.id,
      evidence.id,
      candidate.scope,
      "operator",
    )
    as "the candidate is approved"
  let assert Ok(selection) =
    store.select(
      catalogue,
      candidate.id,
      evidence.id,
      candidate.scope,
      candidate.name,
      None,
      "operator",
      "activate",
    )
    as "the candidate is selected"
  #(catalogue, root, candidate, selection)
}

fn start(
  script: plane.Script,
  candidate: record.Candidate,
  patience_ms: Int,
) -> Rig {
  let #(catalogue, root, candidate, selection) = selected(candidate)
  let seen = process.new_subject()
  let probe = fixtures.probe(fixtures.Open)
  let census =
    rig.compiling(rig.census(rig.standard_tools()), candidate.identity)
  let executor =
    rig.start(rig.evolving(
      rig.factory(probe, census, protocol.AllRetired),
      plane.plane(script, seen),
    ))
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 1000))
    as "the session's store opens"
  let assert Ok(hands) =
    workspace.attach(rig.registered(executor, opened, clock.fixed(at: 1000)))
    as "the session attaches"
  let assert workspace.Reachable(link) = hands.evolution
    as "a compiling executor gives the session an evolution link"
  Rig(
    executor:,
    hands:,
    machine: remote.new(remote.Link(..link, patience_ms:)),
    seen:,
    catalogue:,
    root:,
    candidate:,
    selection:,
  )
}

fn finish(rig_: Rig) -> Nil {
  rig_.hands.plane.close()
  rig.stop(rig_.executor)
}

// Everything the plane served so far, oldest first.
fn drain(seen: Subject(plane.Seen)) -> List(plane.Seen) {
  case process.receive(seen, 100) {
    Ok(item) -> [item, ..drain(seen)]
    Error(Nil) -> []
  }
}

fn ctx() -> tool.Ctx {
  let workspace = "/nonexistent/loom-remote-machine-test"
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 5))
  tool.Ctx(
    directory_access: directory_access.none(),
    workspace:,
    strand: "main",
    op_id:,
    step_id: "step-9",
    source_index: 3,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock: clock.fixed(at: 0),
    filesystem: tool.FileSystem(
      read: fn(path) { Error(tool.FsNotFound(path:)) },
      write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
      create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
      is_file: fn(_path) { Ok(False) },
      read_link: fn(_path) { Ok(tool.LinkMissing) },
      rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
    ),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn echo_tool() -> tool.Described {
  rig.described("echo", tool.Safe)
}

fn staged_script() -> plane.Script {
  plane.script(plane.staged(plane.handle(1), "fixture-ext", [echo_tool()]))
}

// --- staging ---------------------------------------------------------------------

/// A stage answers a generation with the described tools and a bus under the
/// extension's name, and the executor was asked for exactly the approved
/// selection.
pub fn stage_returns_the_described_tools_and_a_named_bus_test() {
  let r = start(staged_script(), extension_candidate(), 300)
  let assert Ok(generation) = r.machine.stage(r.catalogue, r.selection)
    as "the stage succeeds"

  assert list.map(generation.tools, fn(declared) { declared.name }) == ["echo"]
  assert generation.selection == r.selection
  assert generation.mode == live.ReplacementOnly
  assert generation.validate() == Ok(Nil)
  let assert Some(bus) = generation.hooks
  assert hooks.subscribers(bus, on: hooks.Answering) == 1
  assert drain(r.seen) == [plane.Stage(r.selection, r.candidate)]

  let assert Ok(Nil) = retirement.perform(generation.retire)
  finish(r)
}

/// The compile identity comes from the executor's census and no message is
/// sent to answer it.
pub fn identity_is_the_census_identity_test() {
  let r = start(staged_script(), extension_candidate(), 300)
  assert r.machine.identity() == Ok(r.candidate.identity)
  assert drain(r.seen) == []
  finish(r)
}

/// A promoted tool's call sends one `EvolutionRun` to the generation's handle,
/// under the coordinates of the door call and the session's stored authority.
pub fn a_promoted_tool_sends_one_run_with_the_doors_key_test() {
  let r = start(staged_script(), extension_candidate(), 300)
  let assert Ok(generation) = r.machine.stage(r.catalogue, r.selection)
  let _staged = drain(r.seen)
  let assert [declared] = generation.tools

  let args = json.Object([#("say", json.String("hi"))])
  let outcome = declared.run(ctx(), args)

  assert outcome == tool.success("echoed")
  let assert [plane.Run(coordinates:, target:, args: sent)] = drain(r.seen)
  assert target == protocol.Promoted(plane.handle(1), "echo")
  assert sent == args
  assert coordinates.key.session == "registered-session"
  assert coordinates.key.step == "step-9"
  assert coordinates.key.source_index == 3
  assert coordinates.strand == "main"

  let assert Ok(Nil) = retirement.perform(generation.retire)
  finish(r)
}

/// A hook the bus delivers reaches the executor with the bus's deadline
/// unchanged, and the extension's answer comes back attributed to it.
pub fn the_bus_sends_hooks_with_the_deadline_unchanged_test() {
  let script =
    plane.Script(
      ..staged_script(),
      hook: Ok(msgpack.StringValue(
        "{\"verdict\":\"block\",\"reason\":\"not here\"}",
      )),
    )
  let r = start(script, extension_candidate(), 300)
  let assert Ok(generation) = r.machine.stage(r.catalogue, r.selection)
  let _staged = drain(r.seen)
  let assert Some(bus) = generation.hooks

  let #(op_id, _) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 6))
  let verdict = hooks.gate(bus, op_id, "any_tool", json.Null, 0)

  assert verdict == hooks.Block("fixture-ext", "not here")
  assert drain(r.seen)
    == [plane.Hook(plane.handle(1), "tool_call", hooks.deadline_ms)]

  let assert Ok(Nil) = retirement.perform(generation.retire)
  finish(r)
}

/// A selection the catalogue does not hold approved is refused before the
/// executor is asked to build anything.
pub fn an_unapproved_selection_is_refused_before_sending_test() {
  let r = start(staged_script(), extension_candidate(), 300)
  let unknown =
    record.Selection(..r.selection, candidate_id: record.placeholder())

  let assert Error(_) = r.machine.stage(r.catalogue, unknown)
    as "an unapproved selection is refused"

  assert drain(r.seen) == []
  finish(r)
}

/// An executor that already serves a newer generation of the selection is the
/// store's `Stale`, which tells the model to discover the current candidate and
/// generation. Every other refusal keeps its reason as an unavailable
/// dependency.
pub fn a_stale_generation_is_the_stores_stale_test() {
  let script =
    plane.Script(
      ..staged_script(),
      stage_refusal: Some(protocol.StaleGeneration(serving: 9)),
    )
  let r = start(script, extension_candidate(), 300)
  let assert Error(refusal) = r.machine.stage(r.catalogue, r.selection)
  assert refusal == store.Stale
  finish(r)
}

/// A refusal with no equivalent in the store's vocabulary keeps its reason.
pub fn another_refusal_keeps_its_reason_test() {
  let script =
    plane.Script(
      ..staged_script(),
      stage_refusal: Some(protocol.ExecutorFault("disk full")),
    )
  let r = start(script, extension_candidate(), 300)
  let assert Error(store.Unavailable(reason)) =
    r.machine.stage(r.catalogue, r.selection)
  assert string.contains(reason, "disk full")
  finish(r)
}

// --- retirement ------------------------------------------------------------------

/// A retire the executor confirms is done.
pub fn retire_is_done_when_the_executor_confirms_test() {
  let r = start(staged_script(), extension_candidate(), 300)
  let assert Ok(generation) = r.machine.stage(r.catalogue, r.selection)
  let _staged = drain(r.seen)

  assert retirement.perform(generation.retire) == Ok(Nil)
  assert drain(r.seen) == [plane.Retire(plane.handle(1))]
  finish(r)
}

/// An unconfirmed cleanup is the retire's failure, and keeps the retry.
pub fn retire_fails_when_the_cleanup_is_unconfirmed_test() {
  let script =
    plane.Script(..staged_script(), retire: fn(_handle) {
      Some(protocol.UnknownCleanup(2))
    })
  let r = start(script, extension_candidate(), 300)
  let assert Ok(generation) = r.machine.stage(r.catalogue, r.selection)

  let assert Error(failure) = retirement.perform(generation.retire)
  assert string.contains(failure.reason, "2 children")
  let assert Error(_again) = retirement.perform(failure.retry)
  finish(r)
}

/// An executor that cannot be reached counts as done for custody, since the
/// scope's close settles what it still holds.
pub fn retire_is_done_when_the_executor_does_not_answer_test() {
  let r = start(staged_script(), extension_candidate(), 300)
  let assert Ok(generation) = r.machine.stage(r.catalogue, r.selection)
  rig.stop(r.executor)

  assert retirement.perform(generation.retire) == Ok(Nil)
  r.hands.plane.close()
}

/// Every superseded generation is retired before the stage returns, and one
/// whose cleanup is unconfirmed rides on the new generation's retire.
pub fn superseded_generations_are_retired_before_the_stage_returns_test() {
  let old_a = plane.handle(10)
  let old_b = plane.handle(11)
  let staged =
    protocol.Staged(
      ..plane.staged(plane.handle(12), "fixture-ext", [echo_tool()]),
      superseded: [old_a, old_b],
    )
  let script =
    plane.Script(..plane.script(staged), retire: fn(handle) {
      case handle == old_b {
        True -> Some(protocol.UnknownCleanup(1))
        False -> Some(protocol.AllRetired)
      }
    })
  let r = start(script, extension_candidate(), 300)
  let assert Ok(generation) = r.machine.stage(r.catalogue, r.selection)

  // Both retires reached the executor before the stage returned, in whichever
  // order they were served.
  let served = drain(r.seen)
  let retired = list.filter(served, fn(item) { kind_of(item) == "retire" })
  assert list.length(retired) == 2
  assert list.contains(retired, plane.Retire(old_a))
  assert list.contains(retired, plane.Retire(old_b))

  // The one that did not confirm is retried by the generation's own retire,
  // beside the generation's handle.
  let assert Error(failure) = retirement.perform(generation.retire)
  assert string.contains(failure.reason, "1 children")
  let after = drain(r.seen)
  assert list.contains(after, plane.Retire(plane.handle(12)))
  assert list.contains(after, plane.Retire(old_b))
  assert !list.contains(after, plane.Retire(old_a))
  finish(r)
}

// --- in-place upgrade --------------------------------------------------------------

fn upgrading_script(
  publish: Result(protocol.TransitionAnswer, protocol.Refusal),
) -> plane.Script {
  let staged =
    protocol.Staged(
      ..plane.staged(plane.handle(1), "fixture-ext", [echo_tool()]),
      activation: protocol.InPlace,
    )
  plane.Script(..plane.script(staged), transition: fn(step) {
    case step {
      protocol.Prepare(..) ->
        Ok(
          protocol.TransitionPrepared(
            protocol.Prepared(successor: plane.handle(2), tools: [echo_tool()]),
          ),
        )
      protocol.Publish(..) -> publish
      protocol.Abort(..) -> Ok(protocol.TransitionAborted)
    }
  })
}

fn next_selection(r: Rig) -> record.Selection {
  record.Selection(..r.selection, generation: r.selection.generation + 1)
}

/// A published successor serves under its own handle, and the predecessor's
/// bus is closed once the executor confirms.
pub fn a_published_successor_serves_under_its_own_handle_test() {
  let r =
    start(
      upgrading_script(Ok(protocol.TransitionPublished)),
      extension_candidate(),
      300,
    )
  let assert Ok(generation) = r.machine.stage(r.catalogue, r.selection)
  let _staged = drain(r.seen)
  let assert live.Stateful(prepare:) = generation.mode
    as "an in-place generation is stateful"

  let assert Ok(upgrade) = prepare(next_selection(r))
    as "the executor prepares a successor"
  assert upgrade.publish() == Ok(Nil)
  let assert [declared] = upgrade.generation.tools
  let _outcome = declared.run(ctx(), json.Null)

  let served = drain(r.seen)
  assert list.map(served, kind_of) == ["prepare", "publish", "run"]
  let assert [_, _, plane.Run(target:, ..)] = served
  assert target == protocol.Promoted(plane.handle(2), "echo")
  finish(r)
}

fn kind_of(seen: plane.Seen) -> String {
  case seen {
    plane.Transition(step: protocol.Prepare(..)) -> "prepare"
    plane.Transition(step: protocol.Publish(..)) -> "publish"
    plane.Transition(step: protocol.Abort(..)) -> "abort"
    plane.Run(..) -> "run"
    plane.Snapshot(..) -> "snapshot"
    plane.Evaluate(..) -> "evaluate"
    plane.Stage(..) -> "stage"
    plane.Hook(..) -> "hook"
    plane.Retire(..) -> "retire"
    plane.Inventory(..) -> "inventory"
  }
}

/// A publish for a successor the executor no longer holds ended the migration,
/// and is said to be lost.
pub fn a_publish_answered_unknown_handle_is_a_lost_migration_test() {
  let r =
    start(
      upgrading_script(Error(protocol.UnknownHandle)),
      extension_candidate(),
      300,
    )
  let assert Ok(generation) = r.machine.stage(r.catalogue, r.selection)
  let assert live.Stateful(prepare:) = generation.mode
  let assert Ok(upgrade) = prepare(next_selection(r))

  let assert Error(store.Unavailable(reason)) = upgrade.publish()
  assert string.contains(reason, "migration lost")
  finish(r)
}

/// An abort tells the executor to discard the successor.
pub fn an_abort_discards_the_unpublished_successor_test() {
  let r =
    start(
      upgrading_script(Ok(protocol.TransitionPublished)),
      extension_candidate(),
      300,
    )
  let assert Ok(generation) = r.machine.stage(r.catalogue, r.selection)
  let assert live.Stateful(prepare:) = generation.mode
  let assert Ok(upgrade) = prepare(next_selection(r))
  let _served = drain(r.seen)

  assert upgrade.abort() == Ok(Nil)
  assert list.map(drain(r.seen), kind_of) == ["abort"]
  finish(r)
}

// --- checks ----------------------------------------------------------------------

/// An evaluation sends the candidate under the door's coordinates and reads
/// the report the executor stored.
pub fn evaluate_reads_the_executors_report_test() {
  let r = start(staged_script(), extension_candidate(), 300)
  let assert Ok(report) = r.machine.evaluate(r.catalogue, ctx(), r.candidate.id)
    as "the check is reported"

  assert report.verdict == record.Passed
  assert report.observation == "{}"
  let assert [plane.Evaluate(coordinates:, candidate:)] = drain(r.seen)
  assert candidate == r.candidate
  assert coordinates.key.step == "step-9"
  finish(r)
}

/// A report nothing on the executor wrote is a lost answer: inconclusive, and
/// saying the check may have run.
pub fn an_unreadable_report_is_inconclusive_test() {
  let script = plane.Script(..staged_script(), report: json.Null)
  let r = start(script, extension_candidate(), 300)

  let assert Ok(report) = r.machine.evaluate(r.catalogue, ctx(), r.candidate.id)
  let assert record.Inconclusive(reason) = report.verdict
  assert reason == protocol.unknown_outcome_text
  finish(r)
}

/// A refusal the executor stored as its report is a refusal here.
pub fn a_refused_check_is_unavailable_test() {
  let script =
    plane.Script(
      ..staged_script(),
      report: executor_evolution.report_json(Error(store.Busy)),
    )
  let r = start(script, extension_candidate(), 300)

  assert r.machine.evaluate(r.catalogue, ctx(), r.candidate.id)
    == Error(store.Unavailable("catalogue busy"))
  finish(r)
}

/// A candidate admitted under another identity is refused before anything is
/// sent, because its verdict would be evidence for the wrong build.
pub fn a_candidate_of_another_identity_is_refused_before_sending_test() {
  let r = start(staged_script(), extension_candidate(), 300)
  let other = record.Identity(..r.candidate.identity, build: "another-build")
  let assert Ok(foreign) =
    store.open(r.root, store.Owner, other, clock.fixed(at: 1_700_000_000_000))

  let refused = r.machine.evaluate(foreign, ctx(), r.candidate.id)

  assert refused == Error(store.Changed)
  assert drain(r.seen) == []
  finish(r)
}

/// A snapshot sends the directory and the door's coordinates and answers the
/// tree.
pub fn snapshot_sends_the_directory_and_the_coordinates_test() {
  let r = start(staged_script(), extension_candidate(), 300)
  let assert Ok(tree) = r.machine.snapshot(ctx(), "src/ext")

  assert tree.root == "src/ext"
  let assert [plane.Snapshot(coordinates:, directory:)] = drain(r.seen)
  assert directory == "src/ext"
  assert coordinates.key.session == "registered-session"
  finish(r)
}

/// A proposal reaches the executor with the directory the model named, not a
/// path resolved on the orchestrator. The orchestrator's workspace is not the
/// executor's, and a path made here would be refused there as escaping.
pub fn a_proposal_sends_the_directory_unresolved_test() {
  let r = start(staged_script(), extension_candidate(), 300)
  let proposal =
    candidate.Proposal(
      directory: "v1",
      name: "echo",
      kind: record.Extension,
      scope: record.Session("registered-session"),
      test_entry: None,
      description: "An echo.",
      input_schema: "{}",
    )
  let origin = record.Origin("registered-session", "main", "/unused", None)

  let _admitted =
    candidate.capture_with(
      r.catalogue,
      proposal,
      origin,
      ctx(),
      r.machine.snapshot,
    )

  let assert [plane.Snapshot(directory:, ..)] = drain(r.seen)
  assert directory == "v1"
  finish(r)
}

/// A program is read from the catalogue, and its whole candidate is sent.
pub fn run_program_sends_the_selected_candidate_test() {
  let r = start(staged_script(), program_candidate(), 300)
  let input = json.Object([#("text", json.String("abc"))])

  let assert Ok(outcome) =
    r.machine.run_program(r.catalogue, r.selection, ctx(), input)

  assert outcome == tool.success("echoed")
  let assert [plane.Run(target:, args:, ..)] = drain(r.seen)
  assert target == protocol.Program(r.candidate)
  assert args == input
  finish(r)
}

/// An extension's selection is not a program, and nothing is sent for it.
pub fn run_program_refuses_an_extension_test() {
  let r = start(staged_script(), extension_candidate(), 300)

  assert r.machine.run_program(r.catalogue, r.selection, ctx(), json.Null)
    == Error(store.Authority("not a program"))
  assert drain(r.seen) == []
  finish(r)
}

/// A lost run is a failure that says the call may have run.
pub fn a_failed_executor_run_is_a_failure_outcome_test() {
  let script =
    plane.Script(
      ..staged_script(),
      outcome: effects.ToolFailed(reason: "the helper pool is gone"),
    )
  let r = start(script, program_candidate(), 300)

  let assert Ok(outcome) =
    r.machine.run_program(r.catalogue, r.selection, ctx(), json.Null)

  assert outcome == tool.failure("the helper pool is gone")
  finish(r)
}

//// A session moves from one orchestrator to another, in one VM: two registries
//// with their own catalogues and files, one executor host over a real ledger, and
//// the real orchestrator port between them (protocol-change/078, phase 5).
////
//// The source's session is attached to the executor and closed the way a
//// stopped session closes, so the mover finds what it finds in production: a
//// file whose scope cell says how the last close ended. The mover then runs
//// against the real registry, the real importer and the real port. What is
//// replaced is only the wire between the two ports, so a test can drop a reply,
//// corrupt a piece or lose the receiver at a chosen moment.
////
//// ## What it proves
////
//// - A move completes: the receiver registers the session, its file is the copy
////   the source cut, the source's row is a tombstone and its file is set aside,
////   and the session runs a tool on the receiver at the next incarnation while
////   the source's old token is refused by the executor.
//// - Every step can be interrupted and the move completes afterward: the source
////   dying after the intent, a reply to the activation lost, the receiver lost
////   in the middle of the copy, a copy corrupted on the way, an executor that
////   did not answer the close.
//// - A move stops only on an answer: an unproven cleanup, a receiver that
////   refuses, a corrupt file. Silence never abandons it.
//// - Two owners asking at once get one move.

import client/daemon/domain as domain_service
import client/daemon/manager
import client/executors
import client/internal/ffi_os
import client/orchestrators
import client/remote/address.{type Address}
import client/remote/orchestrator_port
import client/remote/protocol
import client/remote/scope
import client/remote/workspace
import client/session_directory
import client/session_importer
import client/session_move
import client/session_mover.{Aborted, Finished, Stalled}
import client/session_movers
import core/clock
import core/ids
import core/json
import core/register
import core/tx
import gleam/bit_array
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import host/bootstrap
import runtime/effects
import session/session
import simplifile
import storage/access
import storage/catalogue
import storage/domain
import storage/storage
import support/remote_fixtures as fixtures
import support/remote_orchestrator as host_rig
import telemetry/log
import weft/poll

const stage_ms = 2000

// A fault that happens a fixed number of times and then stops. The answer is
// asked from whichever process the mover runs a step in, so it lives in a
// process of its own and is reached by a call, and not in a subject only the
// test could read.
type Quota {
  Take(reply: process.Subject(Bool))
}

fn times(count: Int) -> fn() -> Bool {
  let assert Ok(started) =
    actor.new(count)
    |> actor.on_message(fn(left, message) {
      let Take(reply:) = message
      case left > 0 {
        True -> {
          process.send(reply, True)
          actor.continue(left - 1)
        }
        False -> {
          process.send(reply, False)
          actor.continue(left)
        }
      }
    })
    |> actor.start
    as "the quota starts"
  fn() { process.call(started.data, 1000, Take) }
}

const workspace_name = "repo"

// --- the two daemons ------------------------------------------------------------

type Daemon {
  Daemon(
    name: String,
    directory: String,
    store: catalogue.Catalogue,
    registry: manager.Manager(String),
    port: Address(orchestrator_port.Message),
    owner: access.Digest,
  )
}

// Everything the source's mover reaches across the wire, as functions the test
// can wrap.
type Wire {
  Wire(
    send: fn(session_move.Chunk) -> Result(session_move.Verdict, Nil),
    stage: fn(String, String) -> Result(session_move.Stage, Nil),
    activate: fn(session_move.Activation) -> Result(session_move.Verdict, Nil),
  )
}

type Rig {
  Rig(
    directory: String,
    executor: host_rig.Executor,
    probe: fixtures.Probe,
    source: Daemon,
    target: Daemon,
    wire: Wire,
    session: String,
    hands: workspace.Hands,
  )
}

fn node_name() -> String {
  atom.to_string(node.name(node.self()))
}

fn daemon(
  directory: String,
  name: String,
  listed: List(executors.Executor),
  peer: String,
) -> Daemon {
  let own = directory <> "/" <> name
  let assert Ok(Nil) = bootstrap.ensure_private_directory(own)
    as "the daemon's state root exists"
  let assert Ok(Nil) = simplifile.create_directory_all(own <> "/sessions")
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(owner) = access.credential_digest(string.repeat("a", 64))
  let assert Ok(_) = access.bootstrap_owner(store, "owner", "Owner", owner)
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _owner, _directory) {
          Ok(record.id)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "move-test",
      limit: 2,
    )
    as "the registry starts"
  let context =
    session_importer.Context(
      registry:,
      state_root: own,
      sessions_directory: own <> "/sessions",
      domain_configuration: "",
      clock: clock.fixed(at: 5000),
      orchestrators: [orchestrators.plain(peer, node_name())],
      executors: listed,
      logger: log.discard(),
    )
  let port_name = process.new_name("move_test_port_" <> name)
  let held = fn(id) {
    case manager.get(registry, id) {
      Ok(_) ->
        case manager.custody(registry, id) {
          Ok(catalogue.Moved(to:, ..)) -> Ok(orchestrator_port.Moved(to:))
          _ -> Ok(orchestrator_port.Owned)
        }
      Error(manager.Catalogue(catalogue.Missing)) ->
        Ok(orchestrator_port.NotOwned)
      Error(_) -> Error(Nil)
    }
  }
  let assert Ok(_) =
    orchestrator_port.start_importing(
      port_name,
      held,
      session_importer.new(context),
    )
    as "the port starts"
  Daemon(
    name:,
    directory: own,
    store:,
    registry:,
    port: address.Address(node: node.self(), name: port_name),
    owner:,
  )
}

fn over_ports(target: Daemon) -> Wire {
  Wire(
    send: fn(chunk: session_move.Chunk) {
      orchestrator_port.send_chunk(target.port, chunk, 5000)
    },
    stage: fn(session, op) {
      orchestrator_port.ask_stage(target.port, session, op, stage_ms)
    },
    activate: fn(activation) {
      orchestrator_port.ask_activation(target.port, activation, 20_000)
    },
  )
}

fn stop_daemon(daemon: Daemon) -> Nil {
  let watch = process.monitor(manager.pid(daemon.registry))
  manager.shutdown(daemon.registry)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(3000)
    as "the registry retires within the test deadline"
  let _closed = catalogue.close(daemon.store)
  Nil
}

fn finish(rig: Rig) -> Nil {
  stop_daemon(rig.source)
  stop_daemon(rig.target)
  host_rig.stop(rig.executor)
  let _removed = simplifile.delete_all([rig.directory])
  Nil
}

// How a test names the way the executor closes a scope, and whether the source's
// session recorded the close the way a stopped session does.
type Closing {
  // The session's cleanup closed the scope and wrote the outcome.
  Recorded
  // The orchestrator died after the attach: the scope is open on the executor
  // and the file's cell says it was never closed.
  Unrecorded
}

fn start(
  label: String,
  seed: Int,
  closing: Closing,
  executor_closes: protocol.CloseOutcome,
  target_executors: List(executors.Executor),
  padding: Int,
) -> Rig {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory is known"
  let directory =
    here
    <> "/build/test_db/move-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  // The counter restarts with every emulator, so a name can repeat across runs
  // and must not find the last run's files in it.
  let _removed = simplifile.delete_all([directory])
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let probe = fixtures.probe(fixtures.Open)
  let executor =
    host_rig.start(host_rig.factory(
      probe,
      host_rig.census(1000, host_rig.standard_tools()),
      executor_closes,
    ))
  let source =
    daemon(
      directory,
      "alpha",
      [executors.plain("box", "box@10.0.0.9")],
      "bravo",
    )
  let target = daemon(directory, "bravo", target_executors, "alpha")
  let #(id, _) =
    ids.mint_session(ids.generator(clock.fixed(1_700_000_000_000), seed))
  let session = ids.session_id_to_string(id)

  // The registration, as the source created it.
  let path = source.directory <> "/sessions/" <> session <> ".db"
  let record =
    catalogue.Registration(
      id: session,
      path:,
      workspace: workspace_name,
      name: "the moving session",
      configuration: "",
      profile: None,
      executor: "box",
      pool: "",
      created_at: 1_700_000_000_000,
      request_key: "key-" <> session,
      state: catalogue.Reserved,
      subtitle: None,
    )
  let selected = manager.session_only_domain(record, "", source.directory)
  let assert Ok(_) = domain.reserve_session(source.store, record, selected)
  let assert Ok(_) = catalogue.confirm(source.store, session)

  // The session ran: it attached to the executor and its store holds the scope.
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner: "runtime",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(at: 1000),
    )
    as "the source session opens"
  pad(opened, padding)
  let assert Ok(hands) =
    workspace.attach(workspace.Registered(
      placement: host_rig.placement(executor),
      session:,
      workspace: workspace_name,
      opened:,
      owner: host_rig.quiet(),
      clock: clock.fixed(at: 1000),
      reconcile_every_ms: 60_000,
    ))
    as "the attach succeeds"

  // A stopped session closes its scope and records how. A session whose
  // orchestrator died did neither.
  case closing {
    Recorded -> hands.plane.close()
    Unrecorded -> Nil
  }
  let assert Ok(Nil) = session.close(opened)
  Rig(
    directory:,
    executor:,
    probe:,
    source:,
    target:,
    wire: over_ports(target),
    session:,
    hands:,
  )
}

// Fills the session with enough text that its copy needs several pieces.
fn pad(opened: session.Session, bytes: Int) -> Nil {
  case bytes {
    0 -> Nil
    _ -> {
      let assert Ok(_) =
        storage.commit(
          opened.store,
          tx.Tx(
            writes: [
              tx.SetRegister(
                register.FactCustom,
                "padding",
                register.value(json.String(string.repeat("x", bytes))),
              ),
            ],
            expected: [],
          ),
        )
      Nil
    }
  }
}

// --- the source's mover ----------------------------------------------------------

fn environment(
  rig: Rig,
  wire: Wire,
  after: fn(session_move.Step) -> Nil,
) -> session_mover.Environment(String) {
  session_mover.Environment(
    registry: rig.source.registry,
    orchestrators: [orchestrators.plain("bravo", node_name())],
    directory: session_directory.none()
      |> session_directory.activating(fn(_receiver, activation) {
        wire.activate(activation)
      }),
    courier: session_directory.Courier(
      send: fn(_receiver, chunk) { wire.send(chunk) },
      stage: fn(_receiver, session, op) { wire.stage(session, op) },
    ),
    close: fn(_executor, session, named, incarnation) {
      workspace.close_stopped(
        host_rig.reach(rig.executor),
        session,
        named,
        incarnation,
      )
    },
    clock: clock.fixed(at: 5000),
    node: node_name(),
    budget: session_mover.Budget(
      drain_ms: 5000,
      close_ms: 5000,
      cut_ms: 10_000,
      send_ms: 20_000,
      activate_ms: 30_000,
      quick_ms: 5000,
    ),
    after:,
    logger: log.discard(),
  )
}

fn plain(rig: Rig) -> session_mover.Environment(String) {
  environment(rig, rig.wire, fn(_step) { Nil })
}

const op = "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9e"

fn begin(rig: Rig) -> catalogue.Pending {
  let assert Ok(moving) =
    manager.begin_move(
      rig.source.registry,
      rig.source.owner,
      "move-test",
      rig.session,
      to: "bravo",
      op:,
    )
    as "the owner begins the move"
  assert moving == catalogue.Moving(op:, to: "bravo")
  catalogue.Pending(session: rig.session, op:, to: "bravo")
}

fn custody(daemon: Daemon, session: String) -> catalogue.Custody {
  let assert Ok(custody) = manager.custody(daemon.registry, session)
  custody
}

fn source_file(rig: Rig) -> String {
  rig.source.directory <> "/sessions/" <> rig.session <> ".db"
}

fn target_file(rig: Rig) -> String {
  rig.target.directory <> "/sessions/" <> rig.session <> ".db"
}

fn file_exists(path: String) -> Bool {
  simplifile.is_file(path) == Ok(True)
}

// --- what a finished move leaves ---------------------------------------------------

// The state every completed move ends in, however it got there.
fn assert_moved(rig: Rig) -> Nil {
  assert custody(rig.source, rig.session) == catalogue.Moved(op:, to: "bravo")
  assert custody(rig.target, rig.session)
    == catalogue.Imported(op:, from: "alpha")

  // One file on each side of the line: the source's is set aside under its
  // tombstone name, the receiver's is the session, and no copy or lease is left
  // beside the original.
  assert !file_exists(source_file(rig))
  assert file_exists(source_file(rig) <> ".moved")
  assert !file_exists(session_move.copy_path(source_file(rig), op))
  assert file_exists(target_file(rig))
  assert sqlite_lease_free(source_file(rig) <> ".moved")

  // The source answers for the session with the tombstone and runs nothing.
  assert manager.open(rig.source.registry, rig.session)
    == Error(manager.SessionMoved(to: "bravo"))
  Nil
}

fn sqlite_lease_free(path: String) -> Bool {
  case scope.read_at(path, "inspector", clock.fixed(at: 9000)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

// --- the happy path -----------------------------------------------------------------

pub fn a_stopped_session_moves_and_runs_on_the_receiver_at_the_next_incarnation_test() {
  let rig =
    start("happy", 1, Recorded, protocol.AllRetired, receiver_knows_box(), 0)
  let move = begin(rig)
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)

  // The receiver registered what the source showed.
  let assert Ok(view) = manager.get(rig.target.registry, rig.session)
  assert view.registration.name == "the moving session"
  assert view.registration.executor == "box"
  assert view.registration.workspace == workspace_name
  assert view.registration.state == catalogue.Saved

  // It opens there. The executor's scope is at incarnation one, closed, so the
  // receiver attaches at two without inventing the number: the cell it was sent
  // decides it.
  let assert Ok(opened) =
    session.open_sqlite(
      path: target_file(rig),
      owner: "runtime",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(at: 6000),
    )
  let assert Ok(arrived) =
    workspace.attach(workspace.Registered(
      placement: host_rig.placement(rig.executor),
      session: rig.session,
      workspace: workspace_name,
      opened:,
      owner: host_rig.quiet(),
      clock: clock.fixed(at: 6000),
      reconcile_every_ms: 60_000,
    ))
    as "the receiver attaches to the executor"
  assert rig.hands.incarnation == 1
  assert arrived.incarnation == 2
  let run = fixtures.tool_run("call_after_move", 0)
  assert arrived.plane.run(run, fixtures.authority())
    == effects.ToolCompleted(
      result: fixtures.text_result(run, "ran:bash"),
      terminate: False,
    )

  // The source's attach is over. Its old token reaches the executor and is
  // refused, so the source could not run anything even if it tried.
  let stale = fixtures.tool_run("call_from_the_old_owner", 1)
  assert rig.hands.plane.run(stale, fixtures.authority())
    != effects.ToolCompleted(
      result: fixtures.text_result(stale, "ran:bash"),
      terminate: False,
    )
  let assert Ok(Nil) = session.close(opened)
  finish(rig)
}

fn receiver_knows_box() -> List(executors.Executor) {
  [executors.plain("box", "box@10.0.0.9")]
}

// --- an unrecorded close -------------------------------------------------------------

pub fn a_scope_the_session_never_closed_is_closed_by_the_mover_test() {
  let rig =
    start(
      "unrecorded",
      2,
      Unrecorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  assert scope.read_at(source_file(rig), "inspector", clock.fixed(at: 9000))
    == Ok(Some(scope.Scope(1, None, Some("box"))))
  let move = begin(rig)
  assert session_mover.drive(plain(rig), move) == Finished
  assert fixtures.closes(rig.probe) == 1
  assert_moved(rig)

  // The cell the receiver was sent says the close the executor reported.
  let assert Ok(cell) =
    scope.read_at(target_file(rig), "inspector", clock.fixed(at: 9000))
  assert cell == Some(scope.Scope(1, Some(protocol.AllRetired), Some("box")))
  finish(rig)
}

pub fn a_close_nobody_proved_clean_refuses_the_move_before_anything_is_sent_test() {
  let rig =
    start(
      "unproven",
      3,
      Unrecorded,
      protocol.UnknownCleanup(2),
      receiver_knows_box(),
      0,
    )
  let sent = process.new_subject()
  let wire =
    Wire(..rig.wire, send: fn(chunk: session_move.Chunk) {
      process.send(sent, chunk.offset)
      rig.wire.send(chunk)
    })
  let move = begin(rig)
  let assert Aborted(reason) =
    session_mover.drive(environment(rig, wire, fn(_) { Nil }), move)
  assert string.contains(reason, "could not prove")

  // Nothing reached the receiver, the session is the source's again, and the
  // file records what the executor said, so reopening it is refused as the
  // executor would refuse it and not as out of step.
  assert process.receive(sent, 0) == Error(Nil)
  assert custody(rig.source, rig.session) == catalogue.Resident
  assert manager.get(rig.target.registry, rig.session)
    == Error(manager.Catalogue(catalogue.Missing))
  assert scope.read_at(source_file(rig), "inspector", clock.fixed(at: 9000))
    == Ok(Some(scope.Scope(1, Some(protocol.UnknownCleanup(2)), Some("box"))))
  let assert Ok(manager.Opening(_)) =
    manager.open(rig.source.registry, rig.session)
  finish(rig)
}

pub fn a_cell_that_already_says_unknown_refuses_the_move_test() {
  let rig =
    start(
      "unknown-cell",
      4,
      Recorded,
      protocol.UnknownCleanup(1),
      receiver_knows_box(),
      0,
    )
  let move = begin(rig)
  let assert Aborted(reason) = session_mover.drive(plain(rig), move)
  assert string.contains(reason, "could not prove")
  assert custody(rig.source, rig.session) == catalogue.Resident
  assert fixtures.closes(rig.probe) == 1
  finish(rig)
}

// --- interruptions -------------------------------------------------------------------

// Runs the mover in a process the test can lose: the `after` hook kills it the
// moment `lose_after` is reported, as a crash does, and nothing else of the run
// is left behind. The result is whether the run was cut short.
fn lost_after(rig: Rig, lose_after: session_move.Step) -> Bool {
  let move = catalogue.Pending(session: rig.session, op:, to: "bravo")
  let ended = process.new_subject()
  let environment =
    environment(rig, rig.wire, fn(step) {
      case step == lose_after {
        True -> process.kill(process.self())
        False -> Nil
      }
    })
  let pid =
    process.spawn_unlinked(fn() {
      let outcome = session_mover.drive(environment, move)
      process.send(ended, outcome)
    })
  let watch = process.monitor(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(30_000)
    as "the run ends"
  process.receive(ended, 0) == Error(Nil)
}

fn crash_then_complete(
  label: String,
  seed: Int,
  step: session_move.Step,
) -> Nil {
  let rig =
    start(label, seed, Recorded, protocol.AllRetired, receiver_knows_box(), 0)
  let _move = begin(rig)
  assert lost_after(rig, step)

  // However far it got, the row still says moving or moved, never both owners,
  // and a run that starts afterward completes the move from what is on disk.
  let move = catalogue.Pending(session: rig.session, op:, to: "bravo")
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)
  finish(rig)
}

pub fn a_source_lost_after_the_intent_completes_the_move_when_it_returns_test() {
  crash_then_complete("lost-intent", 10, session_move.Intent)
}

pub fn a_source_lost_after_the_close_completes_the_move_when_it_returns_test() {
  crash_then_complete("lost-close", 11, session_move.Close)
}

pub fn a_source_lost_after_the_cut_completes_the_move_when_it_returns_test() {
  crash_then_complete("lost-cut", 12, session_move.Cut)
}

pub fn a_source_lost_after_the_send_completes_the_move_when_it_returns_test() {
  crash_then_complete("lost-send", 13, session_move.Send)
}

pub fn a_source_lost_after_the_activation_completes_the_move_when_it_returns_test() {
  crash_then_complete("lost-activate", 14, session_move.Activate)
}

pub fn a_source_lost_after_the_retirement_has_nothing_left_to_do_test() {
  let rig =
    start(
      "lost-retire",
      15,
      Recorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  let _move = begin(rig)
  assert lost_after(rig, session_move.Retire)
  assert_moved(rig)
  let move = catalogue.Pending(session: rig.session, op:, to: "bravo")
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)
  finish(rig)
}

pub fn a_source_lost_between_the_row_and_the_file_work_finishes_the_file_work_test() {
  let rig =
    start(
      "lost-rename",
      16,
      Recorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  let move = begin(rig)

  // The receiver has the session and the source's row says moved, but nothing
  // of the file work was done: the crash fell between the two.
  let ran = session_mover.drive(plain(rig), move)
  assert ran == Finished
  let assert Ok(Nil) =
    simplifile.rename(source_file(rig) <> ".moved", source_file(rig))
  assert file_exists(source_file(rig))
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)
  finish(rig)
}

pub fn a_lost_activation_reply_is_answered_again_and_the_receiver_holds_one_file_test() {
  let rig =
    start(
      "lost-reply",
      20,
      Recorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  let move = begin(rig)
  let drop = times(1)
  let wire =
    Wire(..rig.wire, activate: fn(activation) {
      let answer = rig.wire.activate(activation)
      case drop() {
        True -> Error(Nil)
        False -> answer
      }
    })

  // The receiver activated, and the reply was lost. The move is stalled and not
  // abandoned: the source cannot know the receiver did not take the session.
  let stalled = session_mover.drive(environment(rig, wire, fn(_) { Nil }), move)
  let assert Stalled(reason) = stalled
  assert string.contains(reason, "did not answer")
  assert custody(rig.source, rig.session) == catalogue.Moving(op:, to: "bravo")
  assert custody(rig.target, rig.session)
    == catalogue.Imported(op:, from: "alpha")

  // Asking again learns it, and the receiver still has the one file.
  assert session_mover.drive(environment(rig, wire, fn(_) { Nil }), move)
    == Finished
  assert_moved(rig)
  finish(rig)
}

pub fn a_retry_after_the_session_opened_on_the_receiver_still_finishes_the_move_test() {
  let rig =
    start(
      "lost-reply-opened",
      23,
      Recorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  let move = begin(rig)
  let drop = times(1)
  let lossy =
    Wire(..rig.wire, activate: fn(activation) {
      let answer = rig.wire.activate(activation)
      case drop() {
        True -> Error(Nil)
        False -> answer
      }
    })

  // The receiver committed and placed the session, and the reply was lost.
  let assert Stalled(_reason) =
    session_mover.drive(environment(rig, lossy, fn(_) { Nil }), move)
  assert custody(rig.target, rig.session)
    == catalogue.Imported(op:, from: "alpha")

  // The owner opens the session on the receiver, which is the point of the move.
  let assert Ok(manager.Opening(_operation)) =
    manager.open(rig.target.registry, rig.session)

  // The retry's first question to the receiver is not answered, which is the
  // partition not yet healed, so the source cannot learn that the session has
  // arrived and carries the move through the close, the cut and the send again.
  // The receiver already holds the session and the session is running there. It
  // answers the activation yes, and the source finishes; a refusal would put
  // the session back on the source while it runs on both.
  let silent = times(1)
  let retry =
    Wire(..rig.wire, stage: fn(session, op) {
      case silent() {
        True -> Error(Nil)
        False -> rig.wire.stage(session, op)
      }
    })
  assert session_mover.drive(environment(rig, retry, fn(_) { Nil }), move)
    == Finished
  assert_moved(rig)
  finish(rig)
}

pub fn a_receiver_lost_in_the_middle_of_the_copy_gets_the_whole_file_again_test() {
  let rig =
    start(
      "lost-piece",
      21,
      Recorded,
      protocol.AllRetired,
      receiver_knows_box(),
      700_000,
    )
  let move = begin(rig)
  let pieces = process.new_subject()
  let wire =
    Wire(..rig.wire, send: fn(chunk: session_move.Chunk) {
      process.send(pieces, chunk.offset)
      // The receiver goes away after the second piece.
      case chunk.offset >= 2 * session_move.chunk_bytes {
        True -> Error(Nil)
        False -> rig.wire.send(chunk)
      }
    })
  let assert Stalled(reason) =
    session_mover.drive(environment(rig, wire, fn(_) { Nil }), move)
  assert string.contains(reason, "did not answer")
  assert custody(rig.source, rig.session) == catalogue.Moving(op:, to: "bravo")

  // The receiver holds a partial copy and no complete one.
  assert session_importer.stage(importer_context(rig), rig.session, op)
    == session_move.Absent
  assert manager.custody(rig.target.registry, rig.session)
    != Ok(catalogue.Imported(op:, from: "alpha"))

  // The next run sends it all from the beginning, with no resume inside a file.
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)
  finish(rig)
}

// The importer's own view of the target, for asking it a question the port
// exposes in the same words.
fn importer_context(rig: Rig) -> session_importer.Context(String) {
  session_importer.Context(
    registry: rig.target.registry,
    state_root: rig.target.directory,
    sessions_directory: rig.target.directory <> "/sessions",
    domain_configuration: "",
    clock: clock.fixed(at: 5000),
    orchestrators: [orchestrators.plain("alpha", node_name())],
    executors: receiver_knows_box(),
    logger: log.discard(),
  )
}

pub fn a_copy_corrupted_on_the_way_is_refused_once_and_sent_again_test() {
  let rig =
    start("corrupt", 22, Recorded, protocol.AllRetired, receiver_knows_box(), 0)
  let move = begin(rig)
  let corrupt = times(1)
  let wire =
    Wire(..rig.wire, send: fn(chunk: session_move.Chunk) {
      case corrupt() {
        True -> {
          // The first send carries a flipped byte; the receiver stores it as sent.
          let assert Ok(head) = bit_array.slice(chunk.bytes, 0, 100)
          let assert Ok(tail) =
            bit_array.slice(
              chunk.bytes,
              101,
              bit_array.byte_size(chunk.bytes) - 101,
            )
          rig.wire.send(
            session_move.Chunk(
              ..chunk,
              bytes: bit_array.concat([head, <<0xff>>, tail]),
            ),
          )
        }
        False -> rig.wire.send(chunk)
      }
    })
  assert session_mover.drive(environment(rig, wire, fn(_) { Nil }), move)
    == Finished
  assert_moved(rig)
  finish(rig)
}

pub fn a_copy_that_keeps_arriving_wrong_is_refused_for_good_and_the_session_returns_test() {
  let rig =
    start(
      "corrupt-always",
      23,
      Recorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  let move = begin(rig)
  let wire =
    Wire(..rig.wire, send: fn(chunk: session_move.Chunk) {
      let assert Ok(head) = bit_array.slice(chunk.bytes, 0, 100)
      let assert Ok(tail) =
        bit_array.slice(
          chunk.bytes,
          101,
          bit_array.byte_size(chunk.bytes) - 101,
        )
      rig.wire.send(
        session_move.Chunk(
          ..chunk,
          bytes: bit_array.concat([head, <<0xfe>>, tail]),
        ),
      )
    })
  let assert Aborted(reason) =
    session_mover.drive(environment(rig, wire, fn(_) { Nil }), move)
  assert string.contains(reason, "digest")
  assert custody(rig.source, rig.session) == catalogue.Resident
  assert manager.get(rig.target.registry, rig.session)
    == Error(manager.Catalogue(catalogue.Missing))

  // The lease went back with the row: the session opens on the source at once.
  assert !file_exists(session_move.copy_path(source_file(rig), op))
  let assert Ok(opened) =
    session.open_sqlite(
      path: source_file(rig),
      owner: "runtime",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(at: 5001),
    )
  let assert Ok(Nil) = session.close(opened)
  finish(rig)
}

pub fn a_receiver_without_the_executor_refuses_and_the_session_returns_test() {
  let rig =
    start(
      "no-executor",
      24,
      Recorded,
      protocol.AllRetired,
      [executors.plain("other", "other@10.0.0.9")],
      0,
    )
  let move = begin(rig)
  let assert Aborted(reason) = session_mover.drive(plain(rig), move)
  assert string.contains(reason, "no executor named box")
  assert custody(rig.source, rig.session) == catalogue.Resident
  assert manager.get(rig.target.registry, rig.session)
    == Error(manager.Catalogue(catalogue.Missing))
  assert file_exists(source_file(rig))
  let assert Ok(manager.Opening(_)) =
    manager.open(rig.source.registry, rig.session)
  finish(rig)
}

pub fn a_receiver_that_cannot_be_reached_never_abandons_the_move_test() {
  let rig =
    start(
      "unreachable",
      25,
      Recorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  let move = begin(rig)
  let wire =
    Wire(
      send: fn(_chunk) { Error(Nil) },
      stage: fn(_session, _op) { Error(Nil) },
      activate: fn(_activation) { Error(Nil) },
    )
  let env = environment(rig, wire, fn(_) { Nil })

  // Run after run, the move stalls and the session stays the source's to answer
  // for, moving and stopped. The receiver might hold it.
  assert list.all([1, 2, 3], fn(_) {
    case session_mover.drive(env, move) {
      Stalled(..) -> True
      Finished | Aborted(..) -> False
    }
  })
  assert custody(rig.source, rig.session) == catalogue.Moving(op:, to: "bravo")
  assert manager.open(rig.source.registry, rig.session)
    == Error(manager.SessionMoving(op:, to: "bravo"))

  // When the receiver comes back the move completes.
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)
  finish(rig)
}

pub fn an_executor_that_does_not_answer_the_close_stalls_the_move_test() {
  let rig =
    start(
      "silent-executor",
      26,
      Unrecorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  let move = begin(rig)
  let silent =
    session_mover.Environment(
      ..plain(rig),
      close: session_mover.unreachable_executors(),
    )
  let assert Stalled(reason) = session_mover.drive(silent, move)
  assert string.contains(reason, "did not answer the close")
  assert custody(rig.source, rig.session) == catalogue.Moving(op:, to: "bravo")
  assert fixtures.closes(rig.probe) == 0
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)
  finish(rig)
}

pub fn a_step_that_runs_out_of_time_stalls_the_move_and_does_not_end_it_test() {
  let rig =
    start("slow", 27, Recorded, protocol.AllRetired, receiver_knows_box(), 0)
  let move = begin(rig)
  let slow =
    Wire(..rig.wire, send: fn(chunk: session_move.Chunk) {
      process.sleep(1000)
      rig.wire.send(chunk)
    })
  let hurried =
    session_mover.Environment(
      ..environment(rig, slow, fn(_) { Nil }),
      budget: session_mover.Budget(
        drain_ms: 5000,
        close_ms: 5000,
        cut_ms: 10_000,
        send_ms: 200,
        activate_ms: 30_000,
        quick_ms: 5000,
      ),
    )
  let assert Stalled(reason) = session_mover.drive(hurried, move)
  assert string.contains(reason, "sending the copy")
  assert custody(rig.source, rig.session) == catalogue.Moving(op:, to: "bravo")
  assert session_mover.drive(plain(rig), move) == Finished
  finish(rig)
}

// --- after the move ---------------------------------------------------------------------

pub fn a_forced_open_on_the_source_after_the_move_is_not_owner_test() {
  let rig =
    start(
      "forced-open",
      30,
      Recorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  let move = begin(rig)
  assert session_mover.drive(plain(rig), move) == Finished

  assert manager.open(rig.source.registry, rig.session)
    == Error(manager.SessionMoved(to: "bravo"))
  assert manager.set_visibility(
      rig.source.registry,
      rig.source.owner,
      "move-test",
      rig.session,
      catalogue.Archived,
    )
    == Error(manager.AdminMoved(to: "bravo"))
  assert manager.delete_session(
      rig.source.registry,
      rig.source.owner,
      "move-test",
      rig.session,
      rig.source.directory <> "/sessions",
    )
    == Error(manager.AdminMoved(to: "bravo"))

  // The port says where it went, and asks nobody.
  assert orchestrator_port.ask(rig.source.port, rig.session, stage_ms)
    == Ok(orchestrator_port.Moved(to: "bravo"))
  assert orchestrator_port.ask(rig.target.port, rig.session, stage_ms)
    == Ok(orchestrator_port.Owned)
  finish(rig)
}

pub fn two_owners_asking_at_once_start_one_move_test() {
  let rig =
    start(
      "concurrent",
      31,
      Recorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  let answers = process.new_subject()
  list.each([1, 2, 3, 4], fn(_) {
    let _pid =
      process.spawn(fn() {
        process.send(
          answers,
          manager.begin_move(
            rig.source.registry,
            rig.source.owner,
            "move-test",
            rig.session,
            to: "bravo",
            // Each asker mints an operation of its own.
            op: "op-" <> int.to_string(ffi_os.unique_positive_integer()),
          ),
        )
      })
    Nil
  })
  let collected =
    list.map([1, 2, 3, 4], fn(_) {
      let assert Ok(answer) = process.receive(answers, 5000)
      answer
    })
  let assert [Ok(first), ..rest] = collected
  assert list.all(rest, fn(answer) { answer == Ok(first) })
  let assert catalogue.Moving(op: chosen, to: "bravo") = first
  assert manager.moving_sessions(rig.source.registry)
    == Ok([catalogue.Pending(session: rig.session, op: chosen, to: "bravo")])
  finish(rig)
}

pub fn a_session_moves_there_and_back_test() {
  let rig =
    start(
      "round-trip",
      32,
      Recorded,
      protocol.AllRetired,
      receiver_knows_box(),
      0,
    )
  let move = begin(rig)
  assert session_mover.drive(plain(rig), move) == Finished
  assert_moved(rig)

  // The receiver runs it once, so its scope is at incarnation two, then gives it
  // up again under a new operation, back to the orchestrator that first had it.
  let assert Ok(opened) =
    session.open_sqlite(
      path: target_file(rig),
      owner: "runtime",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(at: 6000),
    )
  let assert Ok(arrived) =
    workspace.attach(workspace.Registered(
      placement: host_rig.placement(rig.executor),
      session: rig.session,
      workspace: workspace_name,
      opened:,
      owner: host_rig.quiet(),
      clock: clock.fixed(at: 6000),
      reconcile_every_ms: 60_000,
    ))
  assert arrived.incarnation == 2
  arrived.plane.close()
  let assert Ok(Nil) = session.close(opened)
  let back_op = "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8da0"
  let assert Ok(_) =
    manager.begin_move(
      rig.target.registry,
      rig.target.owner,
      "move-test",
      rig.session,
      to: "alpha",
      op: back_op,
    )
  let there = Rig(..rig, source: rig.target, target: rig.source)
  let returning =
    session_mover.Environment(
      ..environment(there, over_ports(rig.source), fn(_) { Nil }),
      orchestrators: [orchestrators.plain("alpha", node_name())],
    )
  assert session_mover.drive(
      returning,
      catalogue.Pending(session: rig.session, op: back_op, to: "alpha"),
    )
    == Finished

  // The first orchestrator holds it again, over its tombstone, with the file
  // the receiver had run on.
  assert custody(rig.source, rig.session)
    == catalogue.Imported(op: back_op, from: "bravo")
  assert custody(rig.target, rig.session)
    == catalogue.Moved(op: back_op, to: "alpha")
  assert file_exists(source_file(rig))
  assert scope.read_at(source_file(rig), "inspector", clock.fixed(at: 9000))
    == Ok(Some(scope.Scope(2, Some(protocol.AllRetired), Some("box"))))
  finish(rig)
}

// --- the daemon's movers -------------------------------------------------------------------

fn await_custody(rig: Rig, expected: catalogue.Custody) -> Nil {
  let outcome =
    poll.until(within: 20_000, every: 25, attempt: fn() {
      case manager.custody(rig.source.registry, rig.session) {
        Ok(found) if found == expected -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  assert outcome == poll.Answered(Nil)
}

pub fn the_movers_carry_a_move_to_the_end_test() {
  let rig =
    start("movers", 40, Recorded, protocol.AllRetired, receiver_knows_box(), 0)
  let assert Ok(control) = session_movers.start(plain(rig), 100)
  let move = begin(rig)
  control.begin(move)

  // Telling the movers twice starts one mover.
  control.begin(move)
  await_custody(rig, catalogue.Moved(op:, to: "bravo"))
  assert_moved(rig)
  finish(rig)
}

pub fn a_stalled_move_is_retried_until_it_completes_test() {
  let rig =
    start("retry", 41, Recorded, protocol.AllRetired, receiver_knows_box(), 0)
  let fail = times(2)
  let wire =
    Wire(..rig.wire, stage: fn(session, op) {
      case fail() {
        True -> Error(Nil)
        False -> rig.wire.stage(session, op)
      }
    })
  let assert Ok(control) =
    session_movers.start(environment(rig, wire, fn(_) { Nil }), 100)
  control.begin(begin(rig))
  await_custody(rig, catalogue.Moved(op:, to: "bravo"))
  finish(rig)
}

pub fn a_restart_resumes_every_move_that_was_in_flight_test() {
  let rig =
    start("resume", 42, Recorded, protocol.AllRetired, receiver_knows_box(), 0)
  let _move = begin(rig)

  // The daemon that began it is gone and a new one starts: its movers find the
  // row and finish the move without anyone asking.
  let assert Ok(control) = session_movers.start(plain(rig), 100)
  assert session_movers.resume(control, rig.source.registry) == Ok(1)
  await_custody(rig, catalogue.Moved(op:, to: "bravo"))
  assert_moved(rig)
  finish(rig)
}

pub fn a_daemon_with_no_movers_lists_no_destination_test() {
  assert session_movers.idle().orchestrators == []
  session_movers.idle().begin(catalogue.Pending(session: "s", op: "op", to: "x"))
}

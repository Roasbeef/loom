//// What a deleted session owes the orchestrators that ran its subagents
//// (protocol-change/084, phase 2): reading the stubs of a closed file, and the
//// pass that sends the rows the deletion left behind.
////
//// The pass is a function over three closures, so the tests play the catalogue
//// and the other orchestrator with a table and a script. The registry's half
//// (rows written before the registration goes, and settled by name) is covered
//// by `daemon_manager_test`, and the drainer's wake-up by
//// `remote_release_drain_test`.

import client/internal/ffi_os
import client/peer_mail
import client/peer_outbox_drain.{Clear, Owed, Quick}
import client/remote/remote_spawner
import client/remote_child
import client/remote_release
import client/remote_spawn
import core/clock
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import host/bootstrap
import simplifile
import storage/catalogue.{type RemoteRelease, RemoteRelease}
import support/remote_stubs
import telemetry/log

fn directory(label: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory is known"
  let path =
    here
    <> "/build/test_db/remote-release-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete_all([path])
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
  path
}

fn session(seed: Int) -> String {
  "0198c0de-0000-7000-8000-00000000000" <> int.to_string(seed)
}

// --- the stubs of a closed file ----------------------------------------------

pub fn the_stubs_of_a_closed_file_are_read_without_a_session_test() {
  let path = directory("stubs") <> "/parent.db"
  remote_stubs.write(path, [
    remote_stubs.stub("box", 1, remote_child.Requested),
    remote_stubs.stub("desk", 2, remote_child.Refused("the cap is 4")),
    remote_stubs.stub(
      "box",
      3,
      remote_child.Spawned(remote_stubs.placed(3, 9_000_000)),
    ),
  ])
  let assert Ok(kept) =
    remote_release.stubs_at(path, "reader", clock.fixed(at: 5000))
  assert list.length(kept) == 3

  // The orchestrators owed a release are those of every stub that is not
  // refused, each once.
  assert remote_child.holders(kept) == ["box"]
  assert remote_child.live_on(kept, 5000) == Some("box")

  // The file is closed again, so a second read finds it free.
  let assert Ok(again) =
    remote_release.stubs_at(path, "reader", clock.fixed(at: 5000))
  assert list.length(again) == 3
}

pub fn a_file_that_is_not_there_holds_no_stubs_and_is_not_made_test() {
  let path = directory("missing") <> "/gone.db"
  assert remote_release.stubs_at(path, "reader", clock.fixed(at: 1)) == Ok([])
  assert simplifile.is_file(path) == Ok(False)
}

// --- the pass ----------------------------------------------------------------

// A catalogue of release rows and an orchestrator that answers as scripted. The
// log says which orchestrator was asked about which parent, and the table is
// what is still owed.
type Rig {
  Rig(table: process.Subject(Table), asked: process.Subject(#(String, String)))
}

type Table {
  Read(reply: process.Subject(List(RemoteRelease)))
  Settle(row: RemoteRelease, reply: process.Subject(Nil))
}

fn serve(rows: List(RemoteRelease)) -> Rig {
  let assert Ok(started) =
    actor.new(rows)
    |> actor.on_message(keep)
    |> actor.start
    as "the table starts"
  Rig(table: started.data, asked: process.new_subject())
}

fn keep(
  rows: List(RemoteRelease),
  message: Table,
) -> actor.Next(List(RemoteRelease), Table) {
  case message {
    Read(reply:) -> {
      process.send(reply, rows)
      actor.continue(rows)
    }
    Settle(row:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(
        list.filter(rows, fn(held) {
          held.parent_session != row.parent_session
          || held.orchestrator != row.orchestrator
        }),
      )
    }
  }
}

fn owed(rig: Rig) -> List(RemoteRelease) {
  process.call(rig.table, 1000, fn(reply) { Read(reply:) })
}

fn pass_over(
  rig: Rig,
  answer: fn(String, remote_spawn.Parent) -> Result(Int, peer_mail.Failure),
) -> fn() -> peer_outbox_drain.Backlog {
  remote_release.pass(
    fn() { Ok(owed(rig)) },
    fn(row) {
      Ok(process.call(rig.table, 1000, fn(reply) { Settle(row:, reply:) }))
    },
    fn(orchestrator, parent) {
      process.send(rig.asked, #(orchestrator, parent.session))
      answer(orchestrator, parent)
    },
    log.discard(),
  )
}

fn row(parent: Int, orchestrator: String) -> RemoteRelease {
  RemoteRelease(parent_session: session(parent), orchestrator:, written_ms: 10)
}

pub fn an_answer_settles_the_row_and_the_pass_is_clear_test() {
  let rig = serve([row(1, "box"), row(2, "desk")])
  let pass = pass_over(rig, fn(_orchestrator, _parent) { Ok(2) })
  assert pass() == Clear
  assert owed(rig) == []
  assert process.receive(rig.asked, 0) == Ok(#("box", session(1)))
  assert process.receive(rig.asked, 0) == Ok(#("desk", session(2)))
}

pub fn a_refusal_settles_the_row_and_is_not_asked_again_test() {
  let rig = serve([row(1, "gone")])
  let pass =
    pass_over(rig, fn(orchestrator, _parent) {
      Error(peer_mail.Refused("`" <> orchestrator <> "` is not configured"))
    })
  assert pass() == Clear
  assert owed(rig) == []
  assert pass() == Clear
  assert process.receive(rig.asked, 0) == Ok(#("gone", session(1)))
  assert process.receive(rig.asked, 0) == Error(Nil)
}

pub fn silence_leaves_the_row_owed_with_no_time_to_live_test() {
  let rig = serve([row(1, "box")])
  let pass =
    pass_over(rig, fn(_orchestrator, _parent) { Error(peer_mail.Unreachable) })

  // However often the pass runs, and however old the row is, an orchestrator
  // that does not answer does not settle it. Only an answer does.
  assert pass() == Owed(Quick)
  assert pass() == Owed(Quick)
  assert pass() == Owed(Quick)
  assert owed(rig) == [row(1, "box")]
}

pub fn a_silent_orchestrator_is_asked_once_per_pass_and_the_others_still_are_test() {
  let rig = serve([row(1, "box"), row(2, "box"), row(3, "box"), row(4, "desk")])
  let pass =
    pass_over(rig, fn(orchestrator, _parent) {
      case orchestrator {
        "box" -> Error(peer_mail.Unreachable)
        _ -> Ok(0)
      }
    })

  // The box is asked about its first row only: the rest would wait out the same
  // deadline to learn the same thing. The desk answers and its row is settled.
  assert pass() == Owed(Quick)
  assert list.map(owed(rig), fn(held) { held.orchestrator })
    == ["box", "box", "box"]
  assert process.receive(rig.asked, 0) == Ok(#("box", session(1)))
  assert process.receive(rig.asked, 0) == Ok(#("desk", session(4)))
  assert process.receive(rig.asked, 0) == Error(Nil)
}

pub fn a_row_is_sent_again_after_the_orchestrator_returns_test() {
  let rig = serve([row(1, "box")])
  let up = process.new_subject()
  let pass =
    pass_over(rig, fn(_orchestrator, _parent) {
      case process.receive(up, 0) {
        Ok(Nil) -> Ok(1)
        Error(Nil) -> Error(peer_mail.Unreachable)
      }
    })
  assert pass() == Owed(Quick)
  process.send(up, Nil)
  assert pass() == Clear
  assert owed(rig) == []
}

pub fn an_unreadable_table_is_owed_and_nothing_is_sent_test() {
  let rig = serve([])
  let pass =
    remote_release.pass(
      fn() { Error("the catalogue could not answer") },
      fn(_row) { Ok(Nil) },
      fn(_orchestrator, _parent) { Ok(0) },
      log.discard(),
    )
  assert pass() == Owed(Quick)
  assert process.receive(rig.asked, 0) == Error(Nil)
}

pub fn a_row_the_catalogue_would_not_settle_stays_owed_test() {
  let pass =
    remote_release.pass(
      fn() { Ok([row(1, "box")]) },
      fn(_row) { Error("the catalogue could not answer") },
      fn(_orchestrator, _parent) { Ok(0) },
      log.discard(),
    )

  // The release is idempotent, so sending it again on the next pass is the
  // repair.
  assert pass() == Owed(Quick)
}

pub fn the_release_names_only_the_parent_session_test() {
  let seen = process.new_subject()
  let pass =
    remote_release.pass(
      fn() { Ok([row(5, "box")]) },
      fn(_row) { Ok(Nil) },
      fn(_orchestrator, parent) {
        process.send(seen, parent)
        Ok(0)
      },
      log.discard(),
    )
  assert pass() == Clear
  let assert Ok(parent) = process.receive(seen, 0)
  assert parent.session == session(5)
}

pub fn a_store_failure_on_the_box_leaves_the_row_owed_test() {
  let rig = serve([row(1, "box")])
  let pass =
    pass_over(rig, fn(_orchestrator, _parent) {
      remote_spawner.release_answer(
        Ok(Error(remote_spawn.StoreFailure(reason: "the registry timed out"))),
      )
    })

  // The box could not do it now. That is not an answer, so the row stays and
  // the pass is owed again.
  assert pass() == Owed(Quick)
  assert owed(rig) == [row(1, "box")]
}

pub fn a_definitive_refusal_and_a_count_are_answers_test() {
  assert remote_spawner.release_answer(Ok(Ok(2))) == Ok(2)
  assert remote_spawner.release_answer(
      Ok(Error(remote_spawn.UnknownSpawner(node: "x@y"))),
    )
    == Error(
      peer_mail.Refused(
        remote_spawn.describe_refusal(remote_spawn.UnknownSpawner(node: "x@y")),
      ),
    )
  assert remote_spawner.release_answer(Error(Nil))
    == Error(peer_mail.Unreachable)
}

// A box whose session for the parent did not open in its budget, as after the
// box was killed and its dead writer's lease has not expired, has not answered:
// every question treats it as silence and is asked again, so a spawn is resent
// and its stub is never left refused by a session that was only slow to open.
pub fn a_session_not_yet_open_is_silence_test() {
  let slow = Ok(Error(remote_spawn.NotYetOpen(reason: "did not open in time")))
  assert remote_spawner.answer(slow) == Error(peer_mail.Unreachable)
  assert remote_spawner.release_answer(slow) == Error(peer_mail.Unreachable)
}

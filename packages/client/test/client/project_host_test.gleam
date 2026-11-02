//// The project actor over a real ledger file and the real engine, with the
//// daemon's side replaced by recording fakes.
////
//// What the fakes stand for matters to what is claimed. `start_session` is a
//// function of the request key alone, as the registry's `create_scoped` is, so
//// a host that calls it twice for one assignment gets one session. The
//// endpoints record the commands they are given instead of running a session.
//// Everything the claims are about is real: the ledger, the replay, the
//// engine, the idempotency keys and the order of writes.

import client/daemon/project_host
import client/internal/ffi_os
import client/peer_mail
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import project/model
import simplifile
import telemetry/log
import tools/project as tools

type Seen {
  Started(key: String)
  Sent(session: String, command: peer_mail.Command)
}

type Rig {
  Rig(config: project_host.Config, seen: Subject(Seen))
}

fn rig(name: String) -> Rig {
  let directory =
    "build/project-host-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory("build")
    as "the build directory exists"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the scratch directory is made"
  let seen = process.new_subject()
  let ports =
    project_host.Ports(
      now_ms: ffi_os.system_time_ms,
      start_session: fn(request) {
        process.send(seen, Started(request.key))
        Ok("session-" <> request.key)
      },
      open_session: fn(_) { Ok(Nil) },
      stop_session: fn(_) { Ok(Nil) },
      release_worktree: fn(_) { Ok(project_host.Removed) },
      endpoint_of: fn(session) {
        Ok(
          peer_mail.Endpoint(session, fn(command) {
            process.send(seen, Sent(session, command))
            Ok(json.Null)
          }),
        )
      },
      logger: log.discard(),
    )
  Rig(
    config: project_host.Config(
      project: "p1",
      workspace: "/work/repo",
      router_session: "router-1",
      ledger_path: directory <> "/ledger.db",
      max_workers: 2,
      tick_ms: 3_600_000,
      router_turn_ms: 3_600_000,
      ports: fn() { ports },
    ),
    seen:,
  )
}

fn start(rig: Rig) -> project_host.Handle {
  let assert Ok(handle) = project_host.start(rig.config)
    as "the project actor starts"
  handle
}

// Every message the fakes recorded so far, oldest first.
fn drain(seen: Subject(Seen)) -> List(Seen) {
  case process.receive(seen, 200) {
    Ok(one) -> [one, ..drain(seen)]
    Error(Nil) -> []
  }
}

fn accept(trigger: String) -> tools.Item {
  tools.Item(
    trigger: model.TriggerId(trigger),
    action: tools.Accept(model.title("work on " <> trigger)),
    holds: [],
    related: [],
    prior_hand_back: None,
  )
}

fn stop(handle: project_host.Handle) -> Nil {
  let assert Ok(pid) = process.subject_owner(handle.commands)
    as "the actor has an owner"
  process.unlink(pid)
  process.kill(pid)
  process.sleep(50)
}

// The key a worker for a ticket's first assignment is created under.
fn first_key(ticket: String) -> String {
  "project:p1:" <> ticket <> ":1"
}

fn board_json(handle: project_host.Handle) -> String {
  let assert Ok(shown) = project_host.board(handle, 0) as "the board reads"
  json.to_string(json.Array(shown.tickets))
}

pub fn two_triggers_become_two_workers_in_distinct_sessions_test() {
  let rig = rig("two")
  let handle = start(rig)
  let assert Ok(project_host.Posted(_)) =
    project_host.post(handle, "a", "fix a")
  let assert Ok(project_host.Posted(_)) =
    project_host.post(handle, "b", "fix b")

  // The engine offers one batch at a time. The second candidate waits in the
  // queue while the router holds the first and reaches it once that turn ends.
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("b")])

  // Two workers start under keys derived from the tickets, and each is given
  // its own trigger.
  let after = drain(rig.seen)
  let offered =
    list.filter_map(after, fn(each) {
      case each {
        Sent("router-1", peer_mail.Trigger(from:, text:, ..)) ->
          Ok(#(from.trigger, from.source, text))
        _ -> Error(Nil)
      }
    })

  // The router is offered each candidate with the trigger origin and the body
  // the owner typed, and nothing else.
  assert list.contains(offered, #("a", "composer", "fix a"))
  assert list.contains(offered, #("b", "composer", "fix b"))
  let keys =
    list.filter_map(after, fn(each) {
      case each {
        Started(key) -> Ok(key)
        Sent(..) -> Error(Nil)
      }
    })
  assert list.sort(keys, string.compare) == [first_key("t-a"), first_key("t-b")]
  let delivered =
    list.filter_map(after, fn(each) {
      case each {
        Sent(session, peer_mail.Trigger(from:, ..)) ->
          Ok(#(session, from.trigger))
        _ -> Error(Nil)
      }
    })
  assert list.contains(delivered, #("session-" <> first_key("t-a"), "a"))
  assert list.contains(delivered, #("session-" <> first_key("t-b"), "b"))
}

pub fn a_report_reaches_the_board_test() {
  let rig = rig("report")
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
  let worker = "session-" <> first_key("t-a")

  let assert Ok(Nil) =
    project_host.report(
      handle,
      worker,
      tools.WorkerReport(tools.Waiting, Some("which database?")),
    )
  let board = board_json(handle)
  assert string.contains(board, "person/answer")
  assert string.contains(board, "which database?")

  // A session that is no assignment's has no report to make.
  let assert Error(tools.NotPermitted(_)) =
    project_host.report(
      handle,
      "stranger",
      tools.WorkerReport(tools.Progress, None),
    )
}

pub fn a_restart_replays_the_same_board_and_starts_no_second_session_test() {
  let rig = rig("restart")
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok(_) = project_host.post(handle, "b", "fix b")
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("b")])
  let before = board_json(handle)
  let started_before =
    drain(rig.seen)
    |> list.count(fn(each) {
      case each {
        Started(_) -> True
        Sent(..) -> False
      }
    })
  assert started_before == 2

  stop(handle)
  let again = start(rig)

  // The state is rebuilt from the ledger alone, and nothing that was settled
  // is performed again.
  assert board_json(again) == before
  let restarted =
    drain(rig.seen)
    |> list.filter(fn(each) {
      case each {
        Started(_) -> True
        Sent(..) -> False
      }
    })
  assert restarted == []
}

pub fn a_failed_start_retries_under_the_same_key_test() {
  let rig = rig("retry")
  let attempts: Subject(String) = process.new_subject()
  let ports = rig.config.ports()
  let flaky =
    project_host.Ports(
      ..ports,
      start_session: fn(request: project_host.StartRequest) {
        process.send(attempts, request.key)
        Error("registry busy")
      },
    )
  let config =
    project_host.Config(..rig.config, tick_ms: 100, ports: fn() { flaky })
  let assert Ok(handle) = project_host.start(config) as "the actor starts"
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
  process.sleep(2500)
  let keys = collect_keys(attempts, [])
  assert keys != []
  assert list.all(keys, fn(key) { key == first_key("t-a") })
}

fn collect_keys(from: Subject(String), found: List(String)) -> List(String) {
  case process.receive(from, 50) {
    Ok(key) -> collect_keys(from, [key, ..found])
    Error(Nil) -> found
  }
}

pub fn a_human_turn_is_recorded_once_test() {
  let rig = rig("human")
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
  let worker = "session-" <> first_key("t-a")
  let _ = drain(rig.seen)

  project_host.human_turn(handle, worker, "entry-9", "owner", "use sqlite")
  project_host.human_turn(handle, worker, "entry-9", "owner", "use sqlite")

  // One trigger, and the thread holds it once. The turn is not echoed back to
  // the worker that typed it.
  let assert Ok(card) =
    project_host.read(handle, tools.TriggerCard(model.TriggerId("h-entry-9")))
  assert string.contains(json.to_string(card), "use sqlite")
  let assert Ok(thread) =
    project_host.read(handle, tools.ThreadCard(model.ThreadId("a")))
  let text = json.to_string(thread)
  let occurrences = list.length(string.split(text, "h-entry-9")) - 1
  assert occurrences == 1
  let echoed =
    drain(rig.seen)
    |> list.filter(fn(each) {
      case each {
        Sent(_, peer_mail.Trigger(from:, ..)) -> from.trigger == "h-entry-9"
        _ -> False
      }
    })
  assert echoed == []
}

pub fn a_refused_route_item_does_not_cost_the_others_test() {
  let rig = rig("refuse")
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")

  // The second item names a message that was never offered.
  let assert Ok([tools.Applied, tools.Declined(reason)]) =
    project_host.route(handle, [accept("a"), accept("ghost")])
  assert reason != ""
  let board = board_json(handle)
  assert string.contains(board, "t-a")
  assert !string.contains(board, "t-ghost")
}

// The note a restart sends, as the worker's endpoint saw it.
fn recovery_notes(seen: List(Seen)) -> List(#(String, String, String)) {
  list.filter_map(seen, fn(each) {
    case each {
      Sent(session, peer_mail.Trigger(from:, text:, ..))
        if from.source == "harness"
      -> Ok(#(session, from.trigger, text))
      Sent(..) | Started(_) -> Error(Nil)
    }
  })
}

pub fn a_restart_tells_a_running_worker_once_test() {
  let rig = rig("recovery")
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
  let worker = "session-" <> first_key("t-a")

  // The first run of the actor has nothing to recover from.
  assert recovery_notes(drain(rig.seen)) == []

  // The first restart finds the assignment running and tells its worker, in
  // the harness's words, to check its worktree and the source before it
  // repeats an outside action.
  stop(handle)
  let again = start(rig)
  let assert [#(session, trigger, text)] = recovery_notes(drain(rig.seen))
    as "one recovery note after the first restart"
  assert session == worker
  assert trigger == "recovery-t-a-1"
  assert string.contains(text, "check your worktree and the source")

  // A second restart finds the pair in the ledger and sends nothing.
  let board = board_json(again)
  stop(again)
  let third = start(rig)
  assert recovery_notes(drain(rig.seen)) == []
  assert board_json(third) == board
}

pub fn a_worker_that_never_ran_is_not_told_of_a_restart_test() {
  let rig = rig("never-ran")
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")

  // The ticket is posted and never accepted, so there is no assignment.
  stop(handle)
  let _again = start(rig)
  assert recovery_notes(drain(rig.seen)) == []
}

// A host whose release port records what it was asked and answers `outcome`.
fn releasing(
  rig: Rig,
  outcome: project_host.Released,
) -> #(project_host.Config, Subject(project_host.ReleaseRequest)) {
  let asked = process.new_subject()
  let ports =
    project_host.Ports(..rig.config.ports(), release_worktree: fn(request) {
      process.send(asked, request)
      Ok(outcome)
    })
  #(project_host.Config(..rig.config, ports: fn() { ports }), asked)
}

pub fn an_ended_ticket_releases_its_worktree_test() {
  let rig = rig("release")
  let #(config, asked) = releasing(rig, project_host.Removed)
  let assert Ok(handle) = project_host.start(config) as "the actor starts"
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])

  // A live ticket keeps its tree.
  assert process.receive(asked, 100) == Error(Nil)

  // A person's stop ends the ticket, and its tree is asked to go.
  let assert Ok(Nil) = project_host.stop_ticket(handle, "t-a", "owner")
  let assert Ok(request) = process.receive(asked, 2000)
    as "the worktree is released"
  assert request == project_host.ReleaseRequest("t-a", 1)
  assert !string.contains(board_json(handle), "reason")
}

pub fn a_worktree_with_unpushed_commits_stays_and_the_board_names_it_test() {
  let rig = rig("kept")
  let kept =
    project_host.Kept(
      path: "/state/worktrees/p1/t-a-1",
      reason: "it holds 2 commits absent from the base",
    )
  let #(config, asked) = releasing(rig, kept)
  let assert Ok(handle) = project_host.start(config) as "the actor starts"
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
  let assert Ok(Nil) = project_host.stop_ticket(handle, "t-a", "owner")
  let assert Ok(_) = process.receive(asked, 2000) as "the worktree is released"

  // The board names the tree and says why it stayed.
  let board = board_json(handle)
  assert string.contains(board, "/state/worktrees/p1/t-a-1")
  assert string.contains(board, "2 commits absent from the base")

  // The record is in the ledger, so a restart shows the same.
  stop(handle)
  let assert Ok(again) = project_host.start(config) as "the actor restarts"
  assert board_json(again) == board
}

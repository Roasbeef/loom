//// The project actor over a real ledger file and the real engine, with the
//// daemon's side replaced by recording fakes.
////
//// What the fakes stand for matters to what is claimed. `start_session` is a
//// function of the request key alone, as the registry's `create_scoped` is, so
//// a host that calls it twice for one assignment gets one session. The
//// endpoints record the commands they are given instead of running a session.
//// Everything the claims are about is real: the ledger, the replay, the
//// engine, the idempotency keys and the order of writes.

import client/daemon/project_book
import client/daemon/project_host
import client/internal/ffi_os
import client/peer_mail
import client/project_records
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import project/engine
import project/event
import project/model
import project/state
import simplifile
import storage/project_ledger
import support/project_ports
import tools/project as tools
import weft/poll

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
      ..project_ports.inert(),
      start_session: fn(request: project_host.StartRequest) {
        process.send(seen, Started(request.key))
        Ok("session-" <> request.key)
      },
      endpoint_of: fn(session) {
        Ok(
          peer_mail.Endpoint(session, fn(command) {
            process.send(seen, Sent(session, command))
            Ok(json.Null)
          }),
        )
      },
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
      policy: project_host.idle_policy,
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

// The owner's turn typed into a worker is recorded under their principal, a
// digest nobody reads. The ticket shows it as the owner, and another actor
// keeps their own name.
pub fn a_human_turn_is_shown_under_a_name_and_not_a_digest_test() {
  let rig = rig("shown")
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
  let worker = "session-" <> first_key("t-a")
  let digest = string.repeat("ab", 32)

  project_host.human_turn(
    handle,
    worker,
    "e-1",
    "owner-" <> digest,
    "use sqlite",
  )
  project_host.human_turn(handle, worker, "e-2", "pat", "and wal")
  let assert Ok(Nil) =
    poll_until(fn() { string.contains(ticket_text(handle), "and wal") })
  let text = ticket_text(handle)
  assert string.contains(text, "\"actor\":\"owner\"")
  assert string.contains(text, "\"actor\":\"pat\"")
  assert !string.contains(text, digest)
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

// --- a ledger written by hand --------------------------------------------------------
//
// A crash leaves the ledger as it was at the instant of the crash. The tests
// below build that ledger line by line, so each starts the actor in the state
// a crash between two writes would leave, and no test needs a way to crash the
// actor at an exact instruction.

fn engine_config() -> state.Config {
  state.Config(
    project: model.ProjectId("p1"),
    workspace: "/work/repo",
    max_workers: 2,
    queue_limit: 100,
    attention_limit: 5,
    policy_version: "v1",
  )
}

fn arrival(trigger: String) -> event.Event {
  event.TriggerArrived(
    model.Trigger(
      id: model.TriggerId(trigger),
      source: model.SourceId("composer"),
      thread: model.ThreadId(trigger),
      actor: model.ActorId("owner"),
      inputs: model.Inputs(
        sender: model.Owner,
        addressing: model.Addressed,
        rule: None,
      ),
      generation: 0,
      at_ms: 1,
    ),
    model.ActorId("loom"),
  )
}

fn routed(trigger: String) -> event.Event {
  event.Routed(model.Routing(
    trigger: model.TriggerId(trigger),
    kind: model.Accept(model.title("work on " <> trigger)),
    holds: [],
    related: [],
    prior_hand_back: None,
  ))
}

// One line of the hand-written ledger: an event with the rows its effects
// become, or a host record.
type Line {
  Fact(event.Event)
  Written(project_records.Record)
}

// Appends the lines to the rig's ledger, computing each event's effect rows
// with the engine itself, as the actor would have. Rows are written for the
// events named in `queued` only: an effect whose row a crash would have left
// unsettled is the point of the test, and the rest are rows the first run
// settled.
fn seed(rig: Rig, lines: List(Line), queued: List(String)) -> Nil {
  let assert Ok(ledger) = project_ledger.open(rig.config.ledger_path)
    as "the ledger opens"
  let now = ffi_os.system_time_ms()
  let _ =
    list.fold(lines, state.start(engine_config()), fn(current, line) {
      case line {
        Written(record) -> {
          let assert Ok(_) =
            project_ledger.append(
              ledger,
              project_records.encode_record(record),
              now,
            )
            as "a record is written"
          current
        }
        Fact(incoming) -> {
          let assert Ok(#(next, effects)) = engine.apply(current, incoming)
            as "the engine takes the seeded event"
          let rows = case list.contains(queued, event_word(incoming)) {
            True -> project_records.drafts(1, now, effects)
            False -> []
          }
          let assert Ok(_) =
            project_ledger.append_with_effects(
              ledger,
              project_records.encode_event(incoming),
              now,
              rows,
            )
            as "an event is written"
          next
        }
      }
    })
  let assert Ok(Nil) = project_ledger.close(ledger) as "the ledger closes"
  Nil
}

// The tag of an event, for choosing which seeded events leave rows.
fn event_word(incoming: event.Event) -> String {
  case incoming {
    event.Routed(..) -> "routed"
    event.SessionBound(..) -> "bound"
    _ -> "other"
  }
}

// A ticket whose first worker was bound to `s-1` and has not been marked live:
// the instant after the first of the two events that `started` writes.
fn bound_not_live(rig: Rig) -> Nil {
  seed(
    rig,
    [
      Written(project_records.TriggerText("a", "composer", "owner", "fix a")),
      Fact(arrival("a")),
      Fact(routed("a")),
      Fact(event.SessionBound(model.TicketId("t-a"), 1, model.SessionId("s-1"))),
    ],
    ["routed"],
  )
}

pub fn a_crash_between_binding_and_going_live_still_marks_the_worker_live_test() {
  let rig = rig("bound")
  bound_not_live(rig)
  let handle = start(rig)

  // The start row is still due, finds the session already bound, and finishes
  // the pair. The ticket is not left queued, and no second session is made.
  let board = board_json(handle)
  assert string.contains(board, "\"stage\":\"working\"")
  assert !string.contains(board, "\"stage\":\"queued\"")
  let assert Ok(["s-1"]) = project_host.live_sessions(handle)
  assert list.filter(drain(rig.seen), fn(each) {
      case each {
        Started(_) -> True
        Sent(..) -> False
      }
    })
    == []

  // A restart finds the pair complete: the ticket is still working, in the
  // same session, and no second one is started.
  stop(handle)
  let again = start(rig)
  assert string.contains(board_json(again), "\"stage\":\"working\"")
  let assert Ok(["s-1"]) = project_host.live_sessions(again)
}

// A ticket whose first worker is live and has asked a question, followed by
// whatever else `after` says happened.
fn asked_a_question(rig: Rig, question: Int, after: List(Line)) -> Nil {
  seed(
    rig,
    list.append(
      [
        Written(project_records.TriggerText("a", "composer", "owner", "fix a")),
        Fact(arrival("a")),
        Fact(routed("a")),
        Fact(event.SessionBound(
          model.TicketId("t-a"),
          1,
          model.SessionId("s-1"),
        )),
        Fact(event.AssignmentLive(model.TicketId("t-a"), 1)),
        Written(project_records.QuestionText("t-a", question, "which database?")),
        Fact(event.Reported(
          model.TicketId("t-a"),
          1,
          model.Waiting(model.Asking(question)),
          model.NoHead,
        )),
      ],
      after,
    ),
    [],
  )
}

// The triggers a session's endpoint was handed, with where they said they came
// from.
fn handed(
  seen: List(Seen),
  session: String,
) -> List(#(String, String, String, String, peer_mail.Wake)) {
  list.filter_map(seen, fn(each) {
    case each {
      Sent(found, peer_mail.Trigger(from:, text:, wake:, ..))
        if found == session
      -> Ok(#(from.source, from.actor, from.trigger, text, wake))
      Sent(..) | Started(_) -> Error(Nil)
    }
  })
}

pub fn a_persons_answer_reaches_the_worker_as_the_owners_words_test() {
  let rig = rig("answer")
  asked_a_question(rig, 5, [])
  let handle = start(rig)
  let _ = drain(rig.seen)

  let assert Ok(Nil) =
    project_host.answer(handle, "t-a", 5, "use sqlite", "owner")

  // The worker's session is handed the text under the owner's source with the
  // principal as the actor, keyed by the ticket and the question, and it may be
  // woken, because a worker waiting on an answer is idle.
  let delivered = handed(drain(rig.seen), "s-1")
  assert delivered
    == [
      #("owner", "owner", "a~t-a~5", "use sqlite", peer_mail.MayWake),
    ]

  // The row is settled, so a restart hands over nothing.
  stop(handle)
  let _again = start(rig)
  assert handed(drain(rig.seen), "s-1") == []
}

pub fn an_answer_with_no_live_worker_goes_on_the_next_assignment_test() {
  let rig = rig("answer-held")
  asked_a_question(rig, 5, [
    Fact(event.AssignmentEnded(model.TicketId("t-a"), 1, model.SessionCrashed)),
  ])
  let handle = start(rig)
  let _ = drain(rig.seen)

  // Nobody is there to receive the answer, and the answer is not lost.
  let assert Ok(Nil) =
    project_host.answer(handle, "t-a", 5, "use sqlite", "owner")
  assert handed(drain(rig.seen), "s-1") == []

  // A retry starts a new worker. It is told what the ticket was opened for and
  // then the answer, in that order, because the first worker's session took the
  // opening message with it.
  let assert Ok(Nil) = project_host.retry(handle, "t-a", "owner")
  let worker = "session-" <> "project:p1:t-a:2"
  let delivered = process.new_subject()
  let assert Ok(Nil) =
    poll_until(fn() {
      case handed(drain(rig.seen), worker) {
        [first, second, ..] -> {
          process.send(delivered, #(first, second))
          True
        }
        _ -> False
      }
    })
  let assert Ok(#(first, second)) = process.receive(delivered, 0)
  assert first == #("composer", "owner", "a", "fix a", peer_mail.MayWake)
  assert second
    == #("owner", "owner", "a~t-a~5", "use sqlite", peer_mail.MayWake)
}

// Polls a condition for a few seconds, on the caller's own process.
fn poll_until(condition: fn() -> Bool) -> Result(Nil, Nil) {
  case
    poll.until(within: 10_000, every: 25, attempt: fn() {
      case condition() {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Expired | poll.Failed(_) -> Error(Nil)
  }
}

// --- who owns an actor ---------------------------------------------------------------

pub fn an_actor_outlives_the_caller_that_started_it_test() {
  let rig = rig("owned")
  let assert Ok(book) = project_book.start() as "the book starts"
  let started = process.new_subject()

  // A caller asks for the actor and then fails, the way a control request's
  // handler does when something it does afterwards crashes.
  let _caller =
    process.spawn_unlinked(fn() {
      let assert Ok(handle) = project_book.launch(book, rig.config)
        as "the actor starts"
      process.send(started, handle)
      panic as "the request failed after it started the project"
    })
  let assert Ok(handle) = process.receive(started, 5000)
    as "the caller got a handle"
  process.sleep(200)

  // The project still answers, and the table still lists it.
  let assert Ok(_) = project_host.board(handle, 0)
  let assert Ok(listed) = project_book.get(book, "p1")
  assert listed == handle
}

// --- the router's second chances -----------------------------------------------------

pub fn a_candidate_the_router_never_decides_waits_on_the_board_for_a_person_test() {
  let rig = rig("unrouted")
  let config =
    project_host.Config(..rig.config, tick_ms: 50, router_turn_ms: 100)
  let assert Ok(handle) = project_host.start(config) as "the actor starts"
  let assert Ok(_) = project_host.post(handle, "a", "fix a")

  // The router is offered the message and never routes it. After three offers
  // the board lists it, with its text, for a person.
  let assert Ok(Nil) =
    poll_until(fn() {
      let assert Ok(shown) = project_host.board(handle, 0)
      shown.unrouted != []
    })
  let assert Ok(shown) = project_host.board(handle, 0)
  let listed = json.to_string(json.Array(shown.unrouted))
  assert string.contains(listed, "\"trigger\":\"a\"")
  assert string.contains(listed, "fix a")
  assert string.contains(listed, "3 times")

  // No more offers go out for it.
  let offers = fn() {
    list.count(drain(rig.seen), fn(each) {
      case each {
        Sent("router-1", peer_mail.Trigger(from:, ..)) -> from.trigger == "a"
        Sent(..) | Started(_) -> False
      }
    })
  }
  let _ = offers()
  assert offers() == 0

  // A person queues it again, and it is offered once more and leaves the list.
  let assert Ok(Nil) = project_host.requeue(handle, "a", "owner")
  let assert Ok(Nil) =
    poll_until(fn() {
      let assert Ok(after) = project_host.board(handle, 0)
      after.unrouted == []
    })
}

// The messages the router was sent for one candidate, by their receipt ids.
fn receipts(seen: List(Seen), trigger: String) -> List(String) {
  list.filter_map(seen, fn(each) {
    case each {
      Sent("router-1", peer_mail.Trigger(from:, message_id:, ..))
        if from.trigger == trigger
      -> Ok(message_id)
      Sent(..) | Started(_) -> Error(Nil)
    }
  })
}

// A candidate offered again has to reach the router again. The receipt that
// makes a delivery safe to repeat is keyed on the offer as well, so the second
// and third offers are admitted and the router is woken for each, where before
// they admitted nothing and each waited out the whole turn deadline.
pub fn each_offer_of_a_candidate_reaches_the_router_under_its_own_receipt_test() {
  let rig = rig("receipts")
  let config =
    project_host.Config(..rig.config, tick_ms: 50, router_turn_ms: 100)
  let assert Ok(handle) = project_host.start(config) as "the actor starts"
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok(Nil) =
    poll_until(fn() {
      let assert Ok(shown) = project_host.board(handle, 0)
      shown.unrouted != []
    })
  assert receipts(drain(rig.seen), "a") == ["a~1", "a~2", "a~3"]
}

// A batch the router held when the actor stopped is still its own after a
// restart, and its turn ends on a deadline that starts again. Without one the
// batch, and every message queued behind it, waited for good.
pub fn a_restart_does_not_strand_the_batch_the_router_held_test() {
  let rig = rig("stranded")
  let first = start(rig)
  let assert Ok(_) = project_host.post(first, "a", "fix a")
  let _ = drain(rig.seen)
  stop(first)

  let config =
    project_host.Config(..rig.config, tick_ms: 50, router_turn_ms: 100)
  let assert Ok(again) = project_host.start(config) as "the actor restarts"
  let assert Ok(Nil) =
    poll_until(fn() {
      let assert Ok(shown) = project_host.board(again, 0)
      shown.unrouted != []
    })
}

// A router that answers a batch and routes nothing ends its turn by finishing
// its run. The project hears it and offers again at once, three times in all,
// and then lists the candidate for a person. The turn deadline here is an hour,
// so only the run-end signal can be what moved it.
pub fn a_router_run_that_routes_nothing_ends_its_turn_without_the_deadline_test() {
  let rig = rig("run-end")
  let handle = start(rig)
  let began = ffi_os.system_time_ms()
  let assert Ok(_) = project_host.post(handle, "a", "fix a")

  // Each offer is answered by a run that ends with no decision.
  let answered = fn(round: Int) {
    let assert Ok(Sent("router-1", peer_mail.Trigger(message_id:, ..))) =
      process.receive(rig.seen, 2000)
    assert message_id == "a~" <> int.to_string(round)
    project_host.router_run_ended(handle, ffi_os.system_time_ms())
  }
  answered(1)
  answered(2)
  answered(3)

  let assert Ok(Nil) =
    poll_until(fn() {
      let assert Ok(shown) = project_host.board(handle, 0)
      shown.unrouted != []
    })
  assert ffi_os.system_time_ms() - began < 5000

  // The third offer was the last, so nothing offers it again and a late run
  // end changes nothing.
  project_host.router_run_ended(handle, ffi_os.system_time_ms())
  assert receipts(drain(rig.seen), "a") == []
}

// The end of an earlier run, which reaches the project after the next batch
// was delivered, says nothing about that batch.
pub fn a_run_that_ended_before_the_batch_was_delivered_does_not_end_its_turn_test() {
  let rig = rig("late-end")
  let handle = start(rig)
  let long_ago = ffi_os.system_time_ms() - 60_000
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok(Sent("router-1", _)) = process.receive(rig.seen, 2000)
  project_host.router_run_ended(handle, long_ago)

  // The candidate is still on the router's table and nothing was offered again.
  let assert Error(Nil) = process.receive(rig.seen, 300)
  let assert Ok(table) = project_host.read(handle, tools.Candidates)
  assert string.contains(json.to_string(table), "\"id\":\"a\"")
}

// --- a worker at rest ----------------------------------------------------------------

// The ports with a worktree that has one commit, touching a protected path so
// that the engine sends the ticket to a person at once, and a record of which
// clone each reading was about.
fn reading_ports(rig: Rig, readings: Subject(Int)) -> project_host.Ports {
  project_host.Ports(
    ..rig.config.ports(),
    observe_head: fn(request: project_host.ObserveRequest) {
      process.send(readings, request.seq)
      Ok(project_host.Taken(project_host.Observed("abc", ["Makefile"])))
    },
  )
}

// A head with no commit of the worker's own, or with changes beside it that no
// commit holds, goes to a person with the host's words and never to the check.
pub fn a_head_with_no_work_in_it_goes_to_a_person_and_runs_no_check_test() {
  list.each(
    [
      #(model.NoCommits, "made no commit"),
      #(model.UncommittedChanges, "no commit has"),
    ],
    fn(case_) {
      let rig = rig("withheld")
      let ports =
        project_host.Ports(
          ..rig.config.ports(),
          observe_head: fn(_) {
            Ok(project_host.Withheld(commit: "abc", reason: case_.0))
          },
          run_check: fn(_) { panic as "a withheld head must not be checked" },
        )
      let config = project_host.Config(..rig.config, ports: fn() { ports })
      let assert Ok(handle) = project_host.start(config) as "the actor starts"
      let assert Ok(_) = project_host.post(handle, "a", "fix a")
      let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
      let worker = "session-" <> first_key("t-a")
      let assert Ok(Nil) =
        project_host.report(
          handle,
          worker,
          tools.WorkerReport(tools.Waiting, None),
        )
      let assert Ok(Nil) =
        poll_until(fn() { string.contains(board_json(handle), case_.1) })
      assert string.contains(board_json(handle), "person/review")
    },
  )
}

pub fn the_assignment_after_a_rested_one_takes_the_same_session_test() {
  let rig = rig("rested")
  let readings = process.new_subject()
  let ports = reading_ports(rig, readings)
  let config = project_host.Config(..rig.config, ports: fn() { ports })
  let assert Ok(handle) = project_host.start(config) as "the actor starts"
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept("a")])
  let worker = "session-" <> first_key("t-a")
  let idle = tools.WorkerReport(tools.Waiting, None)

  // The worker goes idle on work that waits for a person, and its assignment
  // ends while its session stays.
  let assert Ok(Nil) = project_host.report(handle, worker, idle)
  let assert Ok(Nil) =
    poll_until(fn() { string.contains(ticket_text(handle), "done/rested") })
  assert string.contains(board_json(handle), "person/review")
  assert process.receive(readings, 1000) == Ok(1)

  // A retry gives the ticket a second assignment, which is bound to the same
  // session: no session is created, and the clone read is still the first.
  let _ = drain(rig.seen)
  let assert Ok(Nil) = project_host.retry(handle, "t-a", "owner")
  let assert Ok(Nil) =
    poll_until(fn() { string.contains(ticket_text(handle), "\"seq\":2") })
  let assert Ok(Nil) = project_host.report(handle, worker, idle)
  assert process.receive(readings, 1000) == Ok(1)
  assert !list.any(drain(rig.seen), fn(each) {
    case each {
      Started(key) -> key == "project:p1:t-a:2"
      Sent(..) -> False
    }
  })
}

fn ticket_text(handle: project_host.Handle) -> String {
  case project_host.ticket(handle, "t-a") {
    Ok(detail) -> json.to_string(detail)
    Error(Nil) -> ""
  }
}

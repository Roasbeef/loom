//// The board's commands over a real ledger and the real frame codec.
////
//// The claims here are the ones `docs/client-protocol.md` section 3.32 makes
//// about `projects.ticket`, `projects.answer`, `projects.retry` and
//// `projects.requeue`: the request frames decode to the commands the daemon
//// serves, the reply bodies carry the fields the document lists, and an
//// answer to a question that has since changed is refused and records
//// nothing. The actor, the ledger and the engine are real; the daemon's side
//// of session creation is replaced by a recorder, as in `project_host_test`.

import client/daemon/project_book
import client/daemon/project_host
import client/daemon/project_start
import client/daemon/protocol
import client/daemon/ui_projects
import client/internal/ffi_os
import client/peer_mail
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import project/model
import simplifile
import telemetry/log
import tools/project as tools
import web_view/projects as page_projects

fn start(name: String) -> project_host.Handle {
  let directory =
    "build/project-board-wire-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory("build")
    as "the build directory exists"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the scratch directory is made"
  let ports =
    project_host.Ports(
      now_ms: ffi_os.system_time_ms,
      start_session: fn(request) { Ok("session-" <> request.key) },
      open_session: fn(_) { Ok(Nil) },
      stop_session: fn(_) { Ok(Nil) },
      release_worktree: fn(_) { Ok(project_host.Removed) },
      endpoint_of: fn(session) {
        Ok(peer_mail.Endpoint(session, fn(_) { Ok(json.Null) }))
      },
      logger: log.discard(),
    )
  let assert Ok(handle) =
    project_host.start(
      project_host.Config(
        project: "p1",
        workspace: "/work/repo",
        router_session: "router-1",
        ledger_path: directory <> "/ledger.db",
        max_workers: 2,
        tick_ms: 3_600_000,
        router_turn_ms: 3_600_000,
        ports: fn() { ports },
      ),
    )
    as "the project actor starts"
  handle
}

fn stop(handle: project_host.Handle) -> Nil {
  let assert Ok(pid) = process.subject_owner(handle.commands)
    as "the actor has an owner"
  process.unlink(pid)
  process.kill(pid)
  process.sleep(50)
}

// A ticket "t-a" whose worker is waiting on a question, and the question's
// sequence number as the board shows it.
fn asking(handle: project_host.Handle) -> Int {
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let item =
    tools.Item(
      trigger: model.TriggerId("a"),
      action: tools.Accept(model.title("work on a")),
      holds: [],
      related: [],
      prior_hand_back: None,
    )
  let assert Ok([tools.Applied]) = project_host.route(handle, [item])
  let assert Ok(Nil) =
    project_host.report(
      handle,
      "session-project:p1:t-a:1",
      tools.WorkerReport(tools.Waiting, Some("which database?")),
    )
  let assert Ok(detail) = project_host.ticket(handle, "t-a")
    as "the ticket reads"
  let assert json.Object(fields) = detail as "the detail is an object"
  let assert Ok(json.Object(ticket)) = list.key_find(fields, "ticket")
  let assert Ok(json.Object(question)) = list.key_find(ticket, "question")
  let assert Ok(json.Int(seq)) = list.key_find(question, "seq")
  seq
}

pub fn the_four_request_frames_decode_to_their_commands_test() {
  assert protocol.decode(
      "{\"v\":2,\"id\":4,\"cmd\":\"projects.ticket\",\"body\":{\"project\":\"p1\",\"ticket\":\"t-a\"}}",
    )
    == Ok(protocol.Request(4, protocol.ProjectTicket("p1", "t-a")))
  assert protocol.decode(
      "{\"v\":2,\"id\":5,\"cmd\":\"projects.answer\",\"body\":{\"project\":\"p1\",\"ticket\":\"t-a\",\"seq\":7,\"text\":\"sqlite\"}}",
    )
    == Ok(protocol.Request(5, protocol.AnswerQuestion("p1", "t-a", 7, "sqlite")))
  assert protocol.decode(
      "{\"v\":2,\"id\":6,\"cmd\":\"projects.retry\",\"body\":{\"project\":\"p1\",\"ticket\":\"t-a\"}}",
    )
    == Ok(protocol.Request(6, protocol.RetryTicket("p1", "t-a")))
  assert protocol.decode(
      "{\"v\":2,\"id\":7,\"cmd\":\"projects.requeue\",\"body\":{\"project\":\"p1\",\"trigger\":\"tr-1\"}}",
    )
    == Ok(protocol.Request(7, protocol.RequeueTrigger("p1", "tr-1")))
}

pub fn an_answer_without_its_sequence_number_is_malformed_test() {
  let frame =
    "{\"v\":2,\"id\":5,\"cmd\":\"projects.answer\",\"body\":{\"project\":\"p1\",\"ticket\":\"t-a\",\"text\":\"sqlite\"}}"
  let assert Error(_) = protocol.decode(frame)
}

pub fn the_ticket_reply_carries_the_documented_fields_test() {
  let handle = start("detail")
  let seq = asking(handle)
  let assert Ok(detail) = project_host.ticket(handle, "t-a")

  // The reply is encoded by the real frame encoder and parsed back, so the
  // fields checked are the ones on the wire.
  let assert Ok(frame) = protocol.event(Some(4), "projects.ticket", detail)
  let assert Ok(json.Object(envelope)) = json.parse(frame)
  assert list.key_find(envelope, "event") == Ok(json.String("projects.ticket"))
  assert list.key_find(envelope, "reply_to") == Ok(json.Int(4))
  let assert Ok(json.Object(body)) = list.key_find(envelope, "body")
  assert list.key_find(body, "project") == Ok(json.String("p1"))
  let assert Ok(json.Int(_)) = list.key_find(body, "revision")
  let assert Ok(json.Object(ticket)) = list.key_find(body, "ticket")
  assert list.key_find(ticket, "id") == Ok(json.String("t-a"))
  assert list.key_find(ticket, "stage") == Ok(json.String("person/answer"))
  assert list.key_find(ticket, "session")
    == Ok(json.String("session-project:p1:t-a:1"))
  let assert Ok(json.Int(_)) = list.key_find(ticket, "opened_ms")
  let assert Ok(json.Object(mandate)) = list.key_find(ticket, "mandate")
  assert list.key_find(mandate, "strength") == Ok(json.String("explicit"))
  let assert Ok(json.Object(question)) = list.key_find(ticket, "question")
  assert list.key_find(question, "seq") == Ok(json.Int(seq))
  assert list.key_find(question, "text") == Ok(json.String("which database?"))

  // One assignment, bound to the worker, and the opening message as the one
  // input, delivered.
  let assert Ok(json.Array([json.Object(assignment)])) =
    list.key_find(body, "assignments")
  assert list.key_find(assignment, "seq") == Ok(json.Int(1))
  assert list.key_find(assignment, "session")
    == Ok(json.String("session-project:p1:t-a:1"))
  let assert Ok(json.Array([json.Object(input)])) =
    list.key_find(body, "inputs")
  assert list.key_find(input, "text") == Ok(json.String("fix a"))
  assert list.key_find(input, "source") == Ok(json.String("composer"))
  stop(handle)
}

pub fn a_ticket_that_does_not_exist_reads_as_an_error_test() {
  let handle = start("missing")
  assert project_host.ticket(handle, "t-none") == Error(Nil)
  stop(handle)
}

pub fn an_answer_closes_the_question_and_a_repeat_is_stale_test() {
  let handle = start("answer")
  let seq = asking(handle)
  assert project_host.answer(handle, "t-a", seq, "sqlite", "owner") == Ok(Nil)

  // The question is gone from the ticket, so the same answer again echoes a
  // sequence number that no longer names an open question.
  assert project_host.answer(handle, "t-a", seq, "postgres", "owner")
    == Error(project_host.StaleQuestion)
  let assert Ok(detail) = project_host.ticket(handle, "t-a")
  assert !string.contains(json.to_string(detail), "\"stage\":\"person/answer\"")
  stop(handle)
}

pub fn an_answer_to_an_older_sequence_number_is_refused_and_records_nothing_test() {
  let handle = start("older")
  let seq = asking(handle)
  let assert Ok(before) = project_host.board(handle, 0)
  assert project_host.answer(handle, "t-a", seq + 1, "sqlite", "owner")
    == Error(project_host.StaleQuestion)
  let assert Ok(after) = project_host.board(handle, 0)

  // The ledger's newest sequence number is the board's revision, and a refused
  // answer must not have moved it.
  assert before.revision == after.revision
  assert project_host.answer(handle, "t-none", seq, "sqlite", "owner")
    == Error(project_host.NoSuchTicket)
  stop(handle)
}

pub fn retry_and_requeue_are_refused_by_the_engine_not_by_the_wire_test() {
  let handle = start("refused")
  let _seq = asking(handle)

  // A ticket with a live worker has nothing to retry, and a trigger that is
  // not waiting cannot be queued again. The engine says so in words.
  let assert Error(retry_reason) = project_host.retry(handle, "t-a", "owner")
  assert string.contains(retry_reason, "t-a")
  let assert Error(requeue_reason) =
    project_host.requeue(handle, "tr-none", "owner")
  assert string.contains(requeue_reason, "tr-none")
  stop(handle)
}

// --- the page's feed ---------------------------------------------------------

fn controlled(handle: project_host.Handle) -> project_start.Control {
  let assert Ok(book) = project_book.start() as "the table starts"
  project_book.put(book, handle)
  project_start.Control(book:, create: fn(_, _) { Error("not used") })
}

pub fn a_daemon_with_no_project_table_has_no_feed_test() {
  assert ui_projects.feed(None) == None
}

pub fn the_feed_reads_the_same_board_body_the_control_command_serves_test() {
  let handle = start("feed-board")
  let _ = asking(handle)
  let assert Some(feed) = ui_projects.feed(Some(controlled(handle)))
  let assert page_projects.Heard([listed]) = feed.boards()
  let assert Ok(shown) = project_host.board(handle, 0)

  assert listed.id == "p1"
  assert listed.workspace == "/work/repo"
  assert listed.board == ui_projects.board_body("p1", shown)
  stop(handle)
}

pub fn the_feed_answers_conflict_for_a_stale_answer_and_records_nothing_test() {
  let handle = start("feed-answer")
  let seq = asking(handle)
  let assert Some(feed) = ui_projects.feed(Some(controlled(handle)))
  let assert Ok(before) = project_host.board(handle, 0)

  assert feed.answer("p1", "t-a", seq + 1, "sqlite")
    == page_projects.Refused("conflict")
  let assert Ok(after) = project_host.board(handle, 0)
  assert before.revision == after.revision

  assert feed.answer("p1", "t-a", seq, "sqlite") == page_projects.Recorded
  assert feed.answer("p1", "t-none", seq, "sqlite")
    == page_projects.Refused("not_found")
  assert feed.answer("p-none", "t-a", seq, "sqlite")
    == page_projects.Refused("not_found")
  stop(handle)
}

pub fn the_feed_reads_a_ticket_or_says_it_is_gone_test() {
  let handle = start("feed-ticket")
  let _ = asking(handle)
  let assert Some(feed) = ui_projects.feed(Some(controlled(handle)))
  let assert page_projects.TicketHeard(_) = feed.ticket("p1", "t-a")

  assert feed.ticket("p1", "t-none") == page_projects.TicketGone
  assert feed.ticket("p-none", "t-a") == page_projects.TicketGone
  stop(handle)
}

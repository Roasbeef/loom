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
import client/daemon/project_verdict
import client/daemon/protocol
import client/daemon/ui_projects
import client/internal/ffi_os
import client/project_overrides
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import project/model
import session_view/project_settings_view as settings_view
import simplifile
import support/project_ports
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
  let ports = project_ports.inert()
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
        policy: project_host.idle_policy,
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
      "{\"v\":2,\"id\":8,\"cmd\":\"projects.close\",\"body\":{\"project\":\"p1\",\"ticket\":\"t-a\"}}",
    )
    == Ok(protocol.Request(8, protocol.CloseTicket("p1", "t-a")))
  assert protocol.decode(
      "{\"v\":2,\"id\":7,\"cmd\":\"projects.requeue\",\"body\":{\"project\":\"p1\",\"trigger\":\"tr-1\"}}",
    )
    == Ok(protocol.Request(7, protocol.RequeueTrigger("p1", "tr-1")))
  assert protocol.decode(
      "{\"v\":2,\"id\":8,\"cmd\":\"projects.set_mode\",\"body\":{\"project\":\"p1\",\"rule\":\"ci\",\"mode\":\"observe\"}}",
    )
    == Ok(protocol.Request(8, protocol.SetProjectMode("p1", "ci", "observe")))
}

pub fn the_label_and_verdict_frames_decode_to_their_commands_test() {
  assert protocol.decode(
      "{\"v\":2,\"id\":9,\"cmd\":\"projects.label\",\"body\":{\"project\":\"p1\",\"trigger\":\"gh-c-1\",\"label\":\"accept\"}}",
    )
    == Ok(protocol.Request(9, protocol.LabelTrigger("p1", "gh-c-1", "accept")))
  assert protocol.decode(
      "{\"v\":2,\"id\":10,\"cmd\":\"projects.labels\",\"body\":{\"project\":\"p1\",\"rule\":\"ci\"}}",
    )
    == Ok(protocol.Request(10, protocol.ProjectLabels("p1", "ci")))
  assert protocol.decode(
      "{\"v\":2,\"id\":11,\"cmd\":\"projects.verdict\",\"body\":{\"project\":\"p1\",\"rule\":\"ci\"}}",
    )
    == Ok(protocol.Request(
      11,
      protocol.RunProjectVerdict("p1", "ci", None, None),
    ))
  assert protocol.decode(
      "{\"v\":2,\"id\":12,\"cmd\":\"projects.verdict\",\"body\":{\"project\":\"p1\",\"rule\":\"ci\",\"lane\":\"live\"}}",
    )
    == Ok(protocol.Request(
      12,
      protocol.RunProjectVerdict("p1", "ci", Some("live"), None),
    ))

  // The router measured is named by an optional word of its own.
  assert protocol.decode(
      "{\"v\":2,\"id\":13,\"cmd\":\"projects.verdict\",\"body\":{\"project\":\"p1\",\"rule\":\"ci\",\"lane\":\"live\",\"router\":\"jev\"}}",
    )
    == Ok(protocol.Request(
      13,
      protocol.RunProjectVerdict("p1", "ci", Some("live"), Some("jev")),
    ))
}

pub fn a_label_frame_without_a_label_is_malformed_test() {
  let frame =
    "{\"v\":2,\"id\":9,\"cmd\":\"projects.label\",\"body\":{\"project\":\"p1\",\"trigger\":\"gh-c-1\"}}"
  let assert Error(_) = protocol.decode(frame)
}

pub fn a_set_mode_frame_without_a_rule_is_malformed_test() {
  let frame =
    "{\"v\":2,\"id\":8,\"cmd\":\"projects.set_mode\",\"body\":{\"project\":\"p1\",\"mode\":\"observe\"}}"
  let assert Error(_) = protocol.decode(frame)
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

  // The engine says what a person can do, and a client derives none of it.
  // The project keeps publishing off, so a publish is not offered.
  assert list.key_find(ticket, "actions")
    == Ok(
      json.Array([
        json.String("answer"),
        json.String("close"),
        json.String("stop"),
      ]),
    )
  assert list.key_find(ticket, "failure") == Ok(json.Null)
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

// A close ends the ticket as closed and leaves its mandate, and it works once:
// a second close finds the ticket ended and says so in words.
pub fn a_close_ends_the_ticket_and_a_second_is_refused_test() {
  let handle = start("close")
  let _seq = asking(handle)

  let assert Ok(Nil) = project_host.close_ticket(handle, "t-a", "owner")
  let assert Ok(detail) = project_host.ticket(handle, "t-a")
  let text = json.to_string(detail)
  assert string.contains(text, "\"stage\":\"ended/closed\"")
  let assert Error(reason) = project_host.close_ticket(handle, "t-a", "owner")
  assert string.contains(reason, "ended")
  let assert Error(unknown) = project_host.close_ticket(handle, "t-x", "owner")
  assert string.contains(unknown, "t-x")
  stop(handle)
}

// --- the page's feed ---------------------------------------------------------

pub fn the_feed_closes_a_ticket_and_says_so_when_it_cannot_test() {
  let handle = start("feed-close")
  let _ = asking(handle)
  let assert Some(feed) = ui_projects.feed(Some(controlled(handle)))

  assert feed.close("p1", "t-a") == page_projects.Closed
  assert feed.close("p1", "t-a") == page_projects.NotClosed("bad_request")
  assert feed.close("nope", "t-a") == page_projects.NotClosed("not_found")
  stop(handle)
}

pub fn the_feed_stops_and_retries_a_ticket_and_says_so_when_it_cannot_test() {
  let handle = start("feed-stop")
  let _ = asking(handle)
  let assert Some(feed) = ui_projects.feed(Some(controlled(handle)))

  // A project or ticket the table does not hold is `not_found` or refused, and
  // nothing is recorded for it.
  assert feed.stop("nope", "t-a") == page_projects.Declined("not_found")
  assert feed.retry("nope", "t-a") == page_projects.Declined("not_found")
  assert feed.retry("p1", "t-missing") == page_projects.Declined("bad_request")

  // A ticket the project does not hold cannot be stopped, and one it holds is.
  assert feed.stop("p1", "t-missing") == page_projects.Declined("bad_request")
  assert feed.stop("p1", "t-a") == page_projects.Acted
  stop(handle)
}

fn controlled(handle: project_host.Handle) -> project_start.Control {
  let assert Ok(book) = project_book.start() as "the table starts"
  project_book.put(book, handle)
  project_start.Control(
    book:,
    create: fn(_, _) { Error("not used") },
    judge: fn(_) { Error("not used") },
    jev: project_verdict.jev_off(),
  )
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

// Silence from a project's actor is not a refusal: the queued act may still
// commit, so each of the page's four acts reports it as `unanswered` and not as
// `bad_request`, and the page says to read again.
pub fn a_timeout_is_unanswered_and_never_a_refusal_test() {
  let silent = project_host.not_answering

  assert ui_projects.acted_of(Error(silent))
    == page_projects.Declined("unanswered")
  assert ui_projects.acted_of(Error("some refusal"))
    == page_projects.Declined("bad_request")
  assert ui_projects.closing_of(Error(silent))
    == page_projects.NotClosed("unanswered")
  assert ui_projects.closing_of(Error("some refusal"))
    == page_projects.NotClosed("bad_request")
  assert ui_projects.answer_of(Error(project_host.NotAccepted(silent)))
    == page_projects.Refused("unanswered")
  assert ui_projects.answer_of(Error(project_host.NotAccepted("refused")))
    == page_projects.Refused("bad_request")
  assert ui_projects.acted_of(Ok(Nil)) == page_projects.Acted
}

pub fn a_settings_write_naming_a_key_twice_is_malformed_test() {
  let frame =
    "{\"v\":2,\"id\":5,\"cmd\":\"projects.set_settings\",\"body\":{\"project\":\"p1\",\"revision\":0,\"changes\":[{\"key\":\"check\",\"value\":[\"a\"]},{\"key\":\"check\",\"value\":null}]}}"
  let assert Error(_) = protocol.decode(frame)

  // The same two keys, each once, decode.
  let once =
    "{\"v\":2,\"id\":5,\"cmd\":\"projects.set_settings\",\"body\":{\"project\":\"p1\",\"revision\":0,\"changes\":[{\"key\":\"check\",\"value\":[\"a\"]},{\"key\":\"setup\",\"value\":null}]}}"
  let assert Ok(_) = protocol.decode(once)
}

// The daemon half of making a project from the page: the feed makes the project
// through the control, then stores the confirmed commands through the file's own
// rules. A control that makes the project this actor already is, for a folder.
fn creating(handle: project_host.Handle) -> project_start.Control {
  let assert Ok(book) = project_book.start() as "the table starts"
  project_book.put(book, handle)
  project_start.Control(
    book:,
    create: fn(workspace, _) {
      Ok(project_start.Created(
        project: "p-made",
        workspace:,
        router_session: "router-1",
      ))
    },
    judge: fn(_) { Error("not used") },
    jev: project_verdict.jev_off(),
  )
}

// The same, with the made project's actor in the table under its own id.
fn creating_for_a_new_folder(
  handle: project_host.Handle,
) -> project_start.Control {
  let assert Ok(book) = project_book.start() as "the table starts"
  project_book.put(book, project_host.Handle(..handle, project: "p-made"))
  project_start.Control(
    book:,
    create: fn(workspace, _) {
      Ok(project_start.Created(
        project: "p-made",
        workspace:,
        router_session: "router-1",
      ))
    },
    judge: fn(_) { Error("not used") },
    jev: project_verdict.jev_off(),
  )
}

fn held_check(handle: project_host.Handle) -> List(String) {
  let assert Ok(view) = project_host.settings(handle)
  let assert Ok(entry) =
    list.find(view.entries, fn(each) { each.key == project_overrides.CheckKey })
  entry.values
}

pub fn making_a_project_stores_the_confirmed_commands_through_the_files_rules_test() {
  let handle = start("make-stores")
  let assert Some(feed) =
    ui_projects.feed(Some(creating_for_a_new_folder(handle)))
  let assert Ok(before) = project_host.settings(handle)

  // A blank pair stores nothing: the revision does not move.
  assert feed.create("/work/new", None, None)
    == page_projects.Made("p-made", page_projects.SettingsHeld)
  let assert Ok(unchanged) = project_host.settings(handle)
  assert unchanged.revision == before.revision

  // A valid check is stored and in force.
  assert feed.create("/work/new", Some("make check"), None)
    == page_projects.Made("p-made", page_projects.SettingsHeld)
  assert held_check(handle) == ["make check"]
  stop(handle)
}

pub fn a_refused_command_leaves_the_project_made_and_nothing_stored_test() {
  let handle = start("make-refused")
  let assert Some(feed) =
    ui_projects.feed(Some(creating_for_a_new_folder(handle)))
  let assert Ok(before) = project_host.settings(handle)
  let too_long = string.repeat("x", 4097)

  // The check is refused by the file's rule, so the valid setup beside it is not
  // stored either: the write is checked whole before anything is written.
  let assert page_projects.Made("p-made", page_projects.SettingsRefused(_)) =
    feed.create("/work/new", Some(too_long), Some("make deps"))
  let assert Ok(after) = project_host.settings(handle)
  assert after.revision == before.revision
  assert held_check(handle) == []
  stop(handle)
}

pub fn a_folder_that_has_a_project_keeps_its_settings_test() {
  let handle = start("make-existing")

  // The actor's workspace is the folder, so the folder already has a project.
  let assert Some(feed) = ui_projects.feed(Some(creating(handle)))
  let assert Ok(before) = project_host.settings(handle)

  assert feed.create("/work/repo", Some("make check"), Some("make deps"))
    == page_projects.Existing("p1")
  let assert Ok(after) = project_host.settings(handle)
  assert after.revision == before.revision
  assert held_check(handle) == []
  stop(handle)
}

// The project page's reads and writes over the real actor: the settings in force,
// a write at the revision read, a stale write refused as `conflict`, a request
// posted once under its id, and the board body carrying the router's state.
pub fn the_feed_reads_and_writes_settings_and_posts_requests_test() {
  let handle = start("feed-page")
  let assert Some(feed) = ui_projects.feed(Some(controlled(handle)))

  let assert page_projects.SettingsHeard(body) = feed.settings("p1")
  let assert Ok(read) = settings_view.decode_settings(body)

  // A write at the revision read is stored; the same revision again is stale.
  let changes = [#("check", Some(["make verify"]))]
  let assert page_projects.SettingsStored(_) =
    feed.set_settings("p1", read.revision, changes, None)
  assert held_check(handle) == ["make verify"]
  let assert page_projects.SettingsDeclined("conflict", _) =
    feed.set_settings("p1", read.revision, [#("check", Some(["make x"]))], None)
  assert held_check(handle) == ["make verify"]

  // The file's own rules judge a value, and turning publishing on needs its URL.
  let assert page_projects.SettingsDeclined("bad_request", _) =
    feed.set_settings(
      "p1",
      read.revision + 1,
      [#("max_workers", Some(["0"]))],
      None,
    )
  let assert page_projects.SettingsDeclined("bad_request", _) =
    feed.set_settings(
      "p1",
      read.revision + 1,
      [#("publish", Some(["pull_request"]))],
      None,
    )

  // A request is recorded once under its id, and a repeat says so.
  let assert page_projects.Posted(trigger) =
    feed.post("p1", "web-p1-0", "fix it")
  assert feed.post("p1", "web-p1-0", "fix it")
    == page_projects.Reposted(trigger)
  assert feed.post("p-gone", "web-x-0", "fix it")
    == page_projects.NotPosted("not_found")

  // The board carries the router's state and no decision text.
  let assert Ok(shown) = project_host.board(handle, 0)
  let body = ui_projects.board_body("p1", shown)
  let assert json.Object(fields) = body
  let assert Ok(json.Object(router)) = list.key_find(fields, "router")
  assert list.key_find(router, "phase") |> result.is_ok
  let assert Ok(json.Array(_)) = list.key_find(fields, "decisions")
  stop(handle)
}

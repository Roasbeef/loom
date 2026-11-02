//// The project board screen (protocol-change/106): what a person sees for a
//// board, what a key does, and what the terminal does with the daemon's
//// replies.
////
//// The driver tests run the shipped `tui.step` with a control connection
//// adopted, as the access overlay's tests do, so `/project`, the job it
//// starts, the reply's drain and the poll are the real ones.

import core/json
import etui/backend
import etui/geometry
import etui/keys
import etui/widgets/textarea
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/model as session_model
import session_view/msg
import session_view/project_board as board
import tui
import tui/connection
import tui/daemon/selection as daemon_selection
import tui/effect
import tui/frame
import tui/job
import tui/model as tui_model
import tui/project_screen
import tui/render
import tui/runtime
import tui/session_control
import tui/view_set
import tui/workspace
import tui_test/stepping
import weft

@external(erlang, "effects_test_ffi", "host_on")
fn host_on(owner: Subject(Dynamic)) -> daemon_selection.Host

// --- fixtures ----------------------------------------------------------------

fn ticket(
  id: String,
  stage: String,
  opened: Int,
  title: String,
) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("title", json.String(title)),
    #("stage", json.String(stage)),
    #("session", json.Null),
    #("opened_ms", json.Int(opened)),
    #("question", json.Null),
  ])
}

fn asking(id: String, seq: Int, text: String) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("title", json.String("pick a database")),
    #("stage", json.String("person/answer")),
    #("session", json.String("s_01")),
    #("opened_ms", json.Int(1000)),
    #(
      "mandate",
      json.Object([
        #("strength", json.String("explicit")),
        #("via", json.String("composer")),
        #("source", json.String("composer")),
        #("actor", json.String("owner")),
        #("policy_version", json.String("v1")),
      ]),
    ),
    #(
      "question",
      json.Object([
        #("seq", json.Int(seq)),
        #("text", json.String(text)),
        #("options", json.Array([])),
      ]),
    ),
  ])
}

fn body(revision: Int, tickets: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(revision)),
    #("total", json.Int(list.length(tickets))),
    #("tickets", json.Array(tickets)),
  ])
}

// Tickets in no useful order: two answers, a review, a delivery failure, a
// failure, a stage from a newer daemon, and quiet ones.
fn mixed() -> json.JsonValue {
  body(9, [
    ticket("t-working", "working", 100, "build the thing"),
    ticket("t-review", "person/review", 200, "review me"),
    ticket("t-old-answer", "person/answer", 300, "older question"),
    ticket("t-queued", "queued", 400, "waiting its turn"),
    ticket("t-delivery", "person/delivery", 50, "lost input"),
    ticket("t-new-answer", "person/answer", 900, "newer question"),
    ticket("t-failed", "person/failed", 20, "it broke"),
  ])
}

fn healthy() -> json.JsonValue {
  body(4, [
    ticket("t-1", "working", 1, "first quiet one"),
    ticket("t-2", "working", 2, "second quiet one"),
    ticket("t-3", "queued", 3, "third quiet one"),
  ])
}

fn detail(question_seq: Int) -> json.JsonValue {
  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(12)),
    #("ticket", asking("t-ask", question_seq, "which database?")),
    #(
      "assignments",
      json.Array([
        json.Object([
          #("seq", json.Int(1)),
          #("session", json.String("s_01")),
          #("status", json.String("running")),
        ]),
      ]),
    ),
    #(
      "inputs",
      json.Array([
        json.Object([
          #("trigger", json.String("tr-1")),
          #("delivery", json.String("delivered")),
          #("source", json.String("composer")),
          #("actor", json.String("owner")),
          #("text", json.String("add storage")),
        ]),
      ]),
    ),
  ])
}

// --- the shipped loop --------------------------------------------------------

fn blank() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn connected() -> tui_model.Model {
  let owner_inbox: Subject(Dynamic) = process.new_subject()
  runtime.adopt_control(blank(), host_on(owner_inbox))
}

fn typing(model: tui_model.Model, text: String) -> tui_model.Model {
  tui_model.Model(
    ..model,
    view: view_set.input(model.view, textarea.state_from_string(text)),
  )
}

fn control_jobs(effects: List(effect.Effect)) -> List(job.Spec) {
  list.filter_map(effects, fn(requested) {
    case requested {
      effect.StartJob(_, spec) -> Ok(spec)
      _ -> Error(Nil)
    }
  })
}

// Hands the slot's job a completed reply and the relay's end, and drains both.
fn deliver(
  model: tui_model.Model,
  outcome: job.ControlOutcome,
) -> tui_model.Model {
  let assert Some(tui_model.ControlRequest(job: awaiting, ..)) =
    model.view.control_request
  let key = job.key(awaiting)

  model
  |> runtime.hold(job.ControlArrived(
    key,
    weft.PulledOutcome(weft.Completed(0, outcome)),
  ))
  |> runtime.hold(job.ControlArrived(key, weft.AllDelivered))
  |> session_control.drain_control
  |> session_control.drain_control
}

// The terminal after `/project` and a board read that answered with `document`.
fn showing(document: json.JsonValue) -> tui_model.Model {
  let #(opened, _) =
    stepping.step(
      backend.KeyPress("enter"),
      typing(at_time(connected(), 0), "/project"),
    )
  deliver(opened, job.ProjectBoardLoaded(document))
}

fn press(model: tui_model.Model, key: String) -> tui_model.Model {
  stepping.step(backend.KeyPress(key), model).0
}

fn painted(model: tui_model.Model) -> String {
  let sized = tui.update(backend.Resize(120, 40), model)
  let #(drawn, _) = render.view(sized, geometry.rect_new(0, 0, 120, 40))
  frame.buffer_to_text(drawn)
}

// Where `needle` first appears in `haystack`, as a byte offset, or a number
// past the end when it does not appear.
fn at(haystack: String, needle: String) -> Int {
  case string.split_once(haystack, needle) {
    Ok(#(before, _)) -> string.byte_size(before)
    Error(Nil) -> string.byte_size(haystack) + 1
  }
}

fn screen(model: tui_model.Model) -> project_screen.State {
  let assert tui_model.ProjectScreen(state) = model.view.overlay
  state
}

// --- opening -----------------------------------------------------------------

pub fn project_reads_the_boards_of_the_working_directory_test() {
  let model = connected()
  let assert Some(daemon) = model.view.daemon_host
  let #(opened, effects) =
    stepping.step(backend.KeyPress("enter"), typing(model, "/project"))

  assert control_jobs(effects)
    == [
      job.Control(
        daemon.control,
        job.ReadProjectBoard(job.InWorkspace("/work")),
      ),
    ]
  let assert tui_model.ProjectScreen(_) = opened.view.overlay
}

pub fn project_without_a_daemon_connection_opens_nothing_test() {
  let #(refused, effects) =
    stepping.step(backend.KeyPress("enter"), typing(blank(), "/project"))

  assert control_jobs(effects) == []
  assert refused.view.overlay == tui_model.NoOverlay
}

// --- the order on screen -----------------------------------------------------

pub fn tickets_that_need_you_are_grouped_by_stage_in_urgency_order_test() {
  let text = painted(showing(mixed()))

  // Stage headings run delivery, answer, review, failed, and the newest
  // ticket of a stage comes first under its heading.
  assert at(text, "DELIVERY (1)") < at(text, "ANSWER (2)")
  assert at(text, "ANSWER (2)") < at(text, "REVIEW (1)")
  assert at(text, "REVIEW (1)") < at(text, "FAILED (1)")
  assert at(text, "newer question") < at(text, "older question")
  assert at(text, "lost input") < at(text, "newer question")
  assert at(text, "review me") < at(text, "it broke")
}

pub fn quiet_tickets_are_one_line_and_not_rows_test() {
  let text = painted(showing(mixed()))

  assert string.contains(text, "5 tickets need you. 1 queued, 1 working.")
    as "the quiet stages are counted in a line"
  assert !string.contains(text, "build the thing")
  assert !string.contains(text, "waiting its turn")
}

pub fn a_healthy_board_takes_one_line_test() {
  let text = painted(showing(healthy()))

  assert string.contains(text, "Nothing needs you. 1 queued, 2 working.")
  assert !string.contains(text, "first quiet one")
  assert !string.contains(text, "QUEUED")
}

// What an observe rule recorded as work it would have done is listed under one
// heading with the rule, the actor, the start of the text and the address, and
// the text is external, so a terminal escape in it never reaches the screen.
pub fn what_observe_would_have_done_is_listed_for_the_owner_test() {
  let would =
    json.Object([
      #("trigger", json.String("gh-ci-900")),
      #("source", json.String("github")),
      #("actor", json.String("github-actions")),
      #("rule", json.String("ci")),
      #("text", json.String("CI failure: check unit \u{1b}[31mfailed")),
      #("link", json.String("https://github.com/o/r/actions")),
      #("at_ms", json.Int(1)),
    ])
  let document =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(4)),
      #("total", json.Int(0)),
      #("tickets", json.Array([])),
      #("would_have_done", json.Array([would])),
    ])
  let text = painted(showing(document))

  assert string.contains(text, "WOULD HAVE DONE (1)")
  assert string.contains(text, "ci: github-actions: CI failure: check unit")
  assert string.contains(text, "https://github.com/o/r/actions")
  assert !string.contains(text, "\u{1b}[31m")

  // A board with nothing recorded has no such heading.
  assert !string.contains(painted(showing(healthy())), "WOULD HAVE DONE")
}

pub fn a_widens_the_list_to_every_ticket_and_back_test() {
  let wide = press(showing(mixed()), "a")
  let text = painted(wide)

  assert string.contains(text, "build the thing")
  assert at(text, "FAILED (1)") < at(text, "QUEUED (1)")
  assert at(text, "QUEUED (1)") < at(text, "WORKING (1)")
  assert !string.contains(painted(press(wide, "a")), "build the thing")
}

pub fn a_stage_from_a_newer_daemon_is_drawn_as_text_and_does_not_crash_test() {
  let model =
    showing(
      body(3, [
        ticket("t-1", "person/triage", 5, "needs a new kind of look"),
        ticket("t-2", "from-the-future", 6, "not a person stage"),
        json.Object([#("id", json.String("t-3"))]),
      ]),
    )
  let narrow = painted(model)

  assert string.contains(narrow, "PERSON/TRIAGE (1)")
  assert string.contains(narrow, "needs a new kind of look")

  let wide = painted(press(model, "a"))
  assert string.contains(wide, "FROM-THE-FUTURE (1)")
  assert string.contains(wide, "(untitled)")
    as "a ticket with no title is drawn as untitled and not as an empty line"
  assert string.contains(wide, "UNKNOWN (1)")
}

pub fn an_absent_age_is_a_question_mark_and_not_zero_test() {
  let model =
    showing(
      body(3, [
        json.Object([
          #("id", json.String("t-1")),
          #("title", json.String("no clock")),
          #("stage", json.String("person/review")),
        ]),
      ]),
    )
  let text = painted(model)

  assert string.contains(text, "no clock")
  assert string.contains(text, "   ?")
  assert !string.contains(text, "now")
}

// --- hostile text ------------------------------------------------------------

pub fn a_hostile_title_is_inert_on_the_board_test() {
  let hostile =
    "<img src=x onerror=alert(1)>\u{1b}[2J\u{1b}]0;owned\u{7}\u{1b}[31mred"
  let model = showing(body(2, [ticket("t-evil", "person/answer", 1, hostile)]))
  let text = painted(model)

  // The string the screen hands to a span is already clean. The frame's own
  // conversion to text would hide a title that was not, so the state is checked
  // as well as the frame.
  let assert [held] = project_screen.visible(screen(model))
  assert !string.contains(board.title_words(held), "\u{1b}")
  assert !string.contains(board.title_words(held), "\u{7}")

  // No escape or control byte reaches the frame, and the markup is on screen
  // as the characters it is.
  assert !string.contains(text, "\u{1b}")
  assert !string.contains(text, "\u{7}")
  assert string.contains(text, "<img src=x onerror=alert(1)>")
}

pub fn a_hostile_question_and_input_are_inert_on_the_ticket_page_test() {
  let evil = "ask\u{1b}[2Jme <b>now</b>\u{1b}]52;c;AAAA\u{7}"
  let document =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(2)),
      #("ticket", asking("t-ask", 3, evil)),
      #("assignments", json.Array([])),
      #(
        "inputs",
        json.Array([
          json.Object([
            #("trigger", json.String("tr-1")),
            #("delivery", json.String("failed")),
            #("actor", json.String("mallory\u{1b}[31m")),
            #("text", json.String("run \u{1b}[2Jrm -rf <script>")),
          ]),
        ]),
      ),
    ])
  let opened = press(showing(body(2, [asking("t-ask", 3, evil)])), "enter")
  let read = deliver(opened, job.ProjectTicketLoaded(document))
  let text = painted(read)

  // The question and the message are clean in the state the screen draws from.
  let assert Some(detail) = screen(read).detail
  let assert Some(question) = detail.ticket.question
  assert !string.contains(question.text, "\u{1b}")
  assert !string.contains(question.text, "\u{7}")
  let assert [input] = detail.inputs
  assert !string.contains(option.unwrap(input.text, ""), "\u{1b}")
  assert !string.contains(option.unwrap(input.actor, ""), "\u{1b}")

  assert !string.contains(text, "\u{1b}")
  assert !string.contains(text, "\u{7}")
  assert string.contains(text, "<b>now</b>")
  assert string.contains(text, "<script>")
  assert string.contains(text, "did not reach the worker")
}

// --- a ticket ----------------------------------------------------------------

fn on_ticket() -> tui_model.Model {
  let opened =
    press(showing(body(12, [asking("t-ask", 9, "which database?")])), "enter")
  deliver(opened, job.ProjectTicketLoaded(detail(9)))
}

pub fn enter_reads_the_ticket_and_shows_why_it_was_allowed_test() {
  let model = showing(body(12, [asking("t-ask", 9, "which database?")]))
  let assert Some(daemon) = model.view.daemon_host
  let #(opened, effects) = stepping.step(backend.KeyPress("enter"), model)

  assert control_jobs(effects)
    == [
      job.Control(daemon.control, job.ReadProjectTicket("p1", "t-ask")),
    ]
  let read = deliver(opened, job.ProjectTicketLoaded(detail(9)))
  let text = painted(read)

  assert string.contains(text, "You asked for it in the composer. Policy v1.")
  assert string.contains(text, "QUESTION 9")
  assert string.contains(text, "which database?")
  assert string.contains(text, "Answer: ")
  assert string.contains(text, "Worker session s_01")
  assert string.contains(text, "add storage")
}

pub fn an_answer_echoes_the_sequence_number_the_ticket_showed_test() {
  let model = on_ticket()
  let assert Some(daemon) = model.view.daemon_host
  let typed = tui.update(backend.Paste("sqlite"), model)
  let #(sent, effects) = stepping.step(backend.KeyPress("enter"), typed)

  assert control_jobs(effects)
    == [
      job.Control(
        daemon.control,
        job.ChangeProject(job.AnswerTicket("p1", "t-ask", 9, "sqlite")),
      ),
    ]
  let accepted =
    deliver(
      sent,
      job.ProjectChanged(job.AnswerTicket("p1", "t-ask", 9, "sqlite"), None),
    )
  let assert project_screen.State(
    page: project_screen.Reading(draft: "", ..),
    ..,
  ) = screen(accepted)
  assert string.contains(painted(accepted), "Answer queued for the worker.")
}

pub fn a_stale_answer_is_refused_in_words_and_the_draft_is_kept_test() {
  let typed = tui.update(backend.Paste("sqlite"), on_ticket())
  let #(sent, _) = stepping.step(backend.KeyPress("enter"), typed)
  let refused =
    deliver(
      sent,
      job.ProjectChanged(
        job.AnswerTicket("p1", "t-ask", 9, "sqlite"),
        Some("conflict"),
      ),
    )
  let text = painted(refused)

  assert string.contains(text, "The question changed while you were typing.")
  assert string.contains(text, "Nothing was recorded")
  assert string.contains(text, "Answer: sqlite")
    as "the person's text is not lost"
}

pub fn an_empty_answer_sends_nothing_test() {
  let #(_, effects) = stepping.step(backend.KeyPress("enter"), on_ticket())

  assert control_jobs(effects) == []
}

pub fn an_answer_while_another_request_runs_is_kept_and_not_sent_test() {
  let typed = tui.update(backend.Paste("sqlite"), on_ticket())
  let #(occupied, key) = tui_model.allocate_job(typed)
  let busy =
    tui_model.Model(
      ..occupied,
      view: view_set.control_request(
        occupied.view,
        Some(tui_model.ControlRequest(job.awaiting(key), None)),
      ),
    )
  let #(held, effects) = stepping.step(backend.KeyPress("enter"), busy)

  assert control_jobs(effects) == []
  assert string.contains(painted(held), "Try again in a moment.")
  assert string.contains(painted(held), "Answer: sqlite")
}

pub fn the_actions_open_the_workers_session_test() {
  let acting = press(on_ticket(), "tab")
  let #(_, effects) = stepping.step(backend.KeyPress("o"), acting)
  let opened =
    list.any(control_jobs(effects), fn(spec) {
      case spec {
        job.Attach(job.OpenSession(_, "s_01"), _) -> True
        _ -> False
      }
    })

  assert opened
}

pub fn escape_clears_a_draft_then_leaves_the_ticket_then_the_screen_test() {
  let typed = tui.update(backend.Paste("sqlite"), on_ticket())
  let cleared = press(typed, "esc")
  let assert project_screen.State(
    page: project_screen.Reading(draft: "", ..),
    ..,
  ) = screen(cleared)
  let listing = press(cleared, "esc")
  let assert project_screen.State(page: project_screen.Listing, ..) =
    screen(listing)
  assert press(listing, "esc").view.overlay == tui_model.NoOverlay
}

// --- the poll ----------------------------------------------------------------

fn at_time(model: tui_model.Model, now_ms: Int) -> tui_model.Model {
  tui_model.Model(
    ..model,
    shared: session_model.Shared(
      ..model.shared,
      stamp: msg.Stamp(now_ms, now_ms),
    ),
  )
}

pub fn an_unchanged_revision_causes_no_repaint_test() {
  let shown = showing(mixed())
  let before = shown.shared.frame_revision
  let polled =
    deliver(
      at_time(shown, 60_000) |> ask_again,
      job.ProjectBoardLoaded(mixed()),
    )

  assert polled.shared.frame_revision == before
  assert project_screen.same_picture(screen(shown), screen(polled))
}

pub fn a_new_revision_repaints_with_the_new_board_test() {
  let shown = showing(mixed())
  let before = shown.shared.frame_revision
  let newer =
    body(10, [
      ticket("t-review", "person/review", 200, "review me"),
      ticket("t-arrived", "person/answer", 5000, "just arrived"),
    ])
  let polled =
    deliver(at_time(shown, 60_000) |> ask_again, job.ProjectBoardLoaded(newer))

  assert polled.shared.frame_revision > before
  assert string.contains(painted(polled), "just arrived")
  assert !string.contains(painted(polled), "newer question")
}

// Runs the tick's service once, which starts the board read the rest allows.
fn ask_again(model: tui_model.Model) -> tui_model.Model {
  session_control.service_activity(model)
}

pub fn the_board_is_not_read_again_before_its_rest_has_passed_test() {
  let shown = showing(mixed())

  // The answer was filed at a clock of zero, so it rests until the refresh.
  assert session_control.service_activity(at_time(shown, 1000)).view.control_request
    == None
  let due = session_control.service_activity(at_time(shown, 60_000))
  let assert Some(tui_model.ControlRequest(..)) = due.view.control_request
}

pub fn a_poll_reads_the_project_by_id_once_it_is_known_test() {
  let shown = at_time(showing(mixed()), 60_000)
  let assert Some(daemon) = shown.view.daemon_host
  let #(polled, effects) = stepping.step(backend.Tick, shown)

  assert list.contains(
    control_jobs(effects),
    job.Control(daemon.control, job.ReadProjectBoard(job.ProjectId("p1"))),
  )
  let assert Some(tui_model.ControlRequest(..)) = polled.view.control_request
}

pub fn a_failed_read_says_so_and_rests_test() {
  let #(opened, _) =
    stepping.step(backend.KeyPress("enter"), typing(connected(), "/project"))
  let assert Some(tui_model.ControlRequest(job: awaiting, ..)) =
    opened.view.control_request
  let key = job.key(awaiting)
  let failed =
    opened
    |> runtime.hold(job.ControlArrived(
      key,
      weft.PulledOutcome(weft.Failed(0, "No project for this directory.")),
    ))
    |> runtime.hold(job.ControlArrived(key, weft.AllDelivered))
    |> session_control.drain_control
    |> session_control.drain_control

  assert string.contains(painted(failed), "No project for this directory.")
  assert session_control.service_activity(failed).view.control_request == None
}

// --- the pure screen ---------------------------------------------------------

pub fn the_screen_orders_with_the_same_function_the_web_uses_test() {
  let assert Ok(decoded) = board.decode_board(mixed())
  let state = project_screen.observe(project_screen.new("/w"), decoded, 0)
  let shown = list.map(project_screen.visible(state), fn(each) { each.id })

  assert shown
    == ["t-delivery", "t-new-answer", "t-old-answer", "t-review", "t-failed"]
}

pub fn the_highlight_follows_its_ticket_when_the_board_changes_test() {
  let assert Ok(first) = board.decode_board(mixed())
  let state = project_screen.observe(project_screen.new("/w"), first, 0)
  let assert project_screen.Continue(moved) =
    project_screen.update(keys.Down, state)
  let assert Some(highlighted) = project_screen.selected_ticket(moved)
  assert highlighted.id == "t-new-answer"

  let assert Ok(second) =
    board.decode_board(
      body(10, [
        ticket("t-aaa-new", "person/delivery", 99_999, "a new first row"),
        ticket("t-new-answer", "person/answer", 900, "newer question"),
      ]),
    )
  let after = project_screen.observe(moved, second, 0)
  let assert Some(still) = project_screen.selected_ticket(after)
  assert still.id == "t-new-answer"
}

// --- the launch --------------------------------------------------------------

pub fn board_with_watch_keeps_the_board_open_and_without_it_prints_once_test() {
  let assert Ok(options) =
    tui.launch_project_watch([
      "project",
      "board",
      "--watch",
      "--state-dir",
      "/s",
    ])
  assert options.state_directory == "/s"

  let assert Error(_) = tui.launch_project_watch(["project", "board"])
  let assert Error(_) = tui.launch_project_watch(["project", "init"])
  let assert Error(_) = tui.launch_project_watch([])
}

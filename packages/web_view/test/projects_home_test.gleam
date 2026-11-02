//// The owner's Projects section and a ticket's page on the home
//// (protocol-change/106, the addendum on the web view).
////
//// The page is driven through `home.update` and drawn with `home.view`, with the
//// daemon's three project reads replaced by functions that record what they are
//// asked and answer from a fixture. What these tests pin: the section comes
//// first and lists what needs the owner in the shared order, a healthy project
//// is one line, an unchanged revision changes nothing, an answer sends the
//// sequence number the form was drawn with, a refused answer is said in words,
//// every ticket string is escaped text, a stage from a newer daemon is drawn as
//// text, and a page without the capability draws nothing and ignores the
//// messages.

import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import session_view/project_board as board
import web_view/home
import web_view/projects as feed
import web_view/sessions.{Entry, Live}
import web_view/signins

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

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

fn asking(id: String, seq: Int, title: String) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("title", json.String(title)),
    #("stage", json.String("person/answer")),
    #("session", json.String("worker-1")),
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
        #("text", json.String("which database?")),
        #("options", json.Array([])),
      ]),
    ),
    #(
      "actions",
      json.Array([
        json.String("answer"),
        json.String("close"),
        json.String("stop"),
      ]),
    ),
  ])
}

fn board_body(revision: Int, tickets: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(revision)),
    #("total", json.Int(list.length(tickets))),
    #("tickets", json.Array(tickets)),
  ])
}

// Tickets in no useful order, as the daemon might send them.
fn mixed() -> json.JsonValue {
  board_body(9, [
    ticket("t-working", "working", 100, "build the thing"),
    ticket("t-review", "person/review", 200, "review me"),
    ticket("t-old-answer", "person/answer", 300, "older question"),
    ticket("t-queued", "queued", 400, "waiting its turn"),
    ticket("t-delivery", "person/delivery", 50, "lost input"),
    ticket("t-new-answer", "person/answer", 900, "newer question"),
  ])
}

fn detail(seq: Int) -> json.JsonValue {
  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(12)),
    #("ticket", asking("t-ask", seq, "pick a database")),
    #("assignments", json.Array([])),
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

fn listed(document: json.JsonValue) -> feed.Read {
  feed.Heard([feed.Listed("p1", "/src/loom", document)])
}

const now = 7_400_000

fn sessions_listing() -> List(sessions.Entry) {
  [
    Entry(
      id: "worker-1",
      name: "the worker",
      workspace: "/src/loom",
      created_at: 100_000,
      residency: Live,
      subtitle: None,
      role: None,
      project: None,
      executor: None,
    ),
  ]
}

// What the page asked of the daemon, in order.
type Asked {
  ReadBoards
  ReadTicket(project: String, ticket: String)
  Answered(project: String, ticket: String, seq: Int, text: String)
  Accepted(project: String, ticket: String)
}

fn projects_with(
  asked: Subject(Asked),
  boards: fn() -> feed.Read,
  ticket: fn(String, String) -> feed.TicketRead,
  answer: fn(String, String, Int, String) -> feed.Answer,
) -> home.Projects {
  home.Projects(
    boards: fn(deliver) {
      process.send(asked, ReadBoards)
      deliver(boards())
    },
    ticket: fn(project, id, deliver) {
      process.send(asked, ReadTicket(project, id))
      deliver(ticket(project, id))
    },
    answer: fn(project, id, seq, text, deliver) {
      process.send(asked, Answered(project, id, seq, text))
      deliver(answer(project, id, seq, text))
    },
    close: fn(project, id, deliver) {
      process.send(asked, Accepted(project, id))
      deliver(feed.Closed)
    },
  )
}

fn start_with(projects: option.Option(home.Projects)) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling: home.OperatorCeiling,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(sessions_listing())) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { now },
    activity: fn(_, _) { Nil },
    rename: None,
    manage: None,
    create: None,
    folders: None,
    elsewhere: None,
    projects:,
    profiles: [],
    models: [],
    signins: fn(deliver) { deliver(signins.Listed([])) },
    login: None,
    bookmark: None,
    sign_out: fn(_) { signins.Declined(signins.NotFound) },
    sign_out_all: fn() { signins.Revoked },
    device: None,
    admin: None,
    who: fn(deliver) { deliver(None) },
    rename_self: None,
    visiting: None,
    orchestrators: None,
    executors: [],
    pools: [],
    machine: "box",
    placements: fn(_) { Nil },
  )
}

fn serving(document: json.JsonValue) -> #(home.Start, Subject(Asked)) {
  let asked = process.new_subject()
  let projects =
    projects_with(
      asked,
      fn() { listed(document) },
      fn(_, _) { feed.TicketHeard(detail(9)) },
      fn(_, _, _, _) { feed.Recorded },
    )
  #(start_with(Some(projects)), asked)
}

// --- driving the page --------------------------------------------------------

fn run(model: home.Model, message: home.Msg) -> home.Model {
  let #(model, effects) = home.update(model, message)
  let dispatched = process.new_subject()
  effect.perform(
    effects,
    fn(next) { process.send(dispatched, next) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  settle(model, dispatched)
}

fn settle(model: home.Model, dispatched: Subject(home.Msg)) -> home.Model {
  case process.receive(dispatched, 0) {
    Ok(next) -> settle(run(model, next), dispatched)
    Error(Nil) -> model
  }
}

// A page whose timer exists and whose first read has answered, showing the list.
fn opened(start: home.Start) -> home.Model {
  let timer = process.new_subject()
  run(run(home.new(start), home.ShowingList), home.TimerReady(timer))
}

fn drawn(model: home.Model) -> String {
  element.to_string(home.view(model))
}

// The byte offset of the first occurrence of `needle`, or a number past the end.
fn at(haystack: String, needle: String) -> Int {
  case string.split_once(haystack, needle) {
    Ok(#(before, _)) -> string.byte_size(before)
    Error(Nil) -> string.byte_size(haystack) + 1
  }
}

// --- the section -------------------------------------------------------------

pub fn the_section_lists_what_needs_the_owner_in_the_shared_order_test() {
  let #(start, _) = serving(mixed())
  let html = drawn(opened(start))

  assert string.contains(html, "Projects")
  assert string.contains(html, "/src/loom")
  assert at(html, "DELIVERY (1)") < at(html, "ANSWER (2)")
  assert at(html, "ANSWER (2)") < at(html, "REVIEW (1)")
  assert at(html, "lost input") < at(html, "newer question")
  assert at(html, "newer question") < at(html, "older question")
  assert at(html, "older question") < at(html, "review me")
  assert !string.contains(html, "build the thing")
    as "a ticket that needs nobody is not a row"
  assert string.contains(html, "4 tickets need you. 1 queued, 1 working.")
}

pub fn the_section_draws_the_tickets_in_the_order_the_terminal_does_test() {
  let assert Ok(decoded) = board.decode_board(mixed())
  let html = drawn(opened(serving(mixed()).0))
  let positions =
    list.map(board.needing(decoded), fn(each) {
      at(html, board.title_words(each))
    })

  assert list.length(positions) == 4
  assert list.all(list.window_by_2(positions), fn(pair) { pair.0 < pair.1 })
}

pub fn a_healthy_project_is_one_line_and_no_row_test() {
  let healthy =
    board_body(4, [
      ticket("t-1", "working", 1, "first quiet one"),
      ticket("t-2", "queued", 2, "second quiet one"),
    ])
  let html = drawn(opened(serving(healthy).0))

  assert string.contains(html, "Nothing needs you. 1 queued, 1 working.")
  assert !string.contains(html, "first quiet one")
  assert !string.contains(html, "WORKING")
}

pub fn the_section_is_above_the_session_list_test() {
  let html = drawn(opened(serving(mixed()).0))

  assert at(html, "home-projects") < at(html, "home-sessions")
}

pub fn a_stage_from_a_newer_daemon_is_drawn_as_text_test() {
  let html =
    drawn(opened(
      serving(
        board_body(3, [
          ticket("t-1", "person/triage", 5, "a new kind of look"),
          ticket("t-2", "from-the-future", 6, "not a person stage"),
        ]),
      ).0,
    ))

  assert string.contains(html, "PERSON/TRIAGE (1)")
  assert string.contains(html, "a new kind of look")
  assert !string.contains(html, "not a person stage")
  assert string.contains(html, "1 from-the-future")
}

pub fn what_observe_would_have_done_is_listed_as_escaped_text_test() {
  let would =
    json.Object([
      #("trigger", json.String("gh-c-5")),
      #("rule", json.String("deps")),
      #("actor", json.String("dependabot[bot]")),
      #("text", json.String("bump <script>alert(1)</script> left-pad")),
      #("link", json.String("https://github.com/o/r/issues/5")),
    ])
  let document =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(3)),
      #("total", json.Int(1)),
      #("tickets", json.Array([ticket("t-1", "working", 1, "quiet")])),
      #("would_have_done", json.Array([would])),
    ])
  let html = drawn(opened(serving(document).0))

  // The heading, the rule, the actor and the address appear, the text is
  // escaped, and no address was made into a link.
  assert string.contains(html, "WOULD HAVE DONE (1)")
  assert string.contains(html, "deps: dependabot[bot]: bump")
  assert string.contains(html, "https://github.com/o/r/issues/5")
  assert !string.contains(html, "<script>alert(1)")
  assert !string.contains(html, "href=\"https://github.com/o/r/issues/5\"")
}

pub fn the_rule_list_shows_each_verdict_state_as_escaped_text_test() {
  let rule =
    json.Object([
      #("name", json.String("deps")),
      #("mode", json.String("observe")),
      #(
        "verdict",
        json.Object([
          #("state", json.String("stale")),
          #(
            "words",
            json.String(
              "Stale: the router prompt changed. <script>alert(1)</script>",
            ),
          ),
          #("labelled", json.Int(30)),
          #("needed", json.Int(30)),
        ]),
      ),
    ])
  let document =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(3)),
      #("total", json.Int(1)),
      #("tickets", json.Array([ticket("t-1", "working", 1, "quiet")])),
      #(
        "sources",
        json.Array([
          json.Object([
            #("source", json.String("github")),
            #("rules", json.Array([rule])),
          ]),
        ]),
      ),
    ])
  let html = drawn(opened(serving(document).0))

  assert string.contains(html, "RULES")
  assert string.contains(
    html,
    "deps: observe, verdict stale, 30 of 30 labelled",
  )
  assert string.contains(html, "Stale: the router prompt changed.")
  assert !string.contains(html, "<script>alert(1)")
}

// The web view only displays a run. Each state the daemon reports is drawn as
// text on the rule's row, with the daemon's words escaped.
pub fn the_rule_row_draws_each_run_state_as_escaped_text_test() {
  let with_run = fn(run) {
    let rule =
      json.Object([
        #("name", json.String("deps")),
        #("mode", json.String("observe")),
        #("run", run),
      ])
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(3)),
      #("total", json.Int(1)),
      #("tickets", json.Array([ticket("t-1", "working", 1, "quiet")])),
      #(
        "sources",
        json.Array([
          json.Object([
            #("source", json.String("github")),
            #("rules", json.Array([rule])),
          ]),
        ]),
      ),
    ])
  }
  let page = fn(run) { drawn(opened(serving(with_run(run)).0)) }

  let going =
    page(
      json.Object([
        #("state", json.String("running")),
        #("done", json.Int(12)),
        #("of", json.Int(90)),
        #("calls", json.Int(12)),
        #("tokens", json.Int(5100)),
      ]),
    )
  assert string.contains(
    going,
    "live run: 12 of 90 trials, 12 calls, 5100 tokens",
  )

  list.each(["passed", "failed", "incomplete"], fn(state) {
    let html =
      page(
        json.Object([
          #("state", json.String(state)),
          #("words", json.String("Outcome <b>" <> state <> "</b>.")),
          #("calls", json.Int(90)),
          #("tokens", json.Int(41_000)),
        ]),
      )

    assert string.contains(
      html,
      "live run " <> state <> ", 90 calls, 41000 tokens",
    )
    assert !string.contains(html, "<b>" <> state)
  })

  // No run, and a null run, draw no run line.
  assert !string.contains(page(json.Null), "live run")
}

pub fn a_project_whose_board_cannot_be_read_says_so_test() {
  let html = drawn(opened(serving(json.String("garbage")).0))

  assert string.contains(html, "board could not be read.")
}

// --- hostile text ------------------------------------------------------------

pub fn a_hostile_title_is_escaped_text_test() {
  let hostile =
    "<script>alert(1)</script><img src=x onerror=alert(2)>\u{1b}[2J\u{7}"
  let html =
    drawn(opened(
      serving(board_body(2, [ticket("t-evil", "person/answer", 1, hostile)])).0,
    ))

  assert !string.contains(html, "<script>alert(1)")
    as "the markup is escaped and never an element"
  assert !string.contains(html, "<img src=x")
  assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
  assert !string.contains(html, "\u{1b}")
  assert !string.contains(html, "\u{7}")
}

pub fn a_hostile_question_and_input_are_escaped_on_the_ticket_page_test() {
  let evil = "<b onmouseover=x>ask</b>\u{1b}]52;c;AAAA\u{7}"
  let asked = process.new_subject()
  let projects =
    projects_with(
      asked,
      fn() { listed(board_body(5, [asking("t-ask", 9, "pick a database")])) },
      fn(_, _) {
        feed.TicketHeard(
          json.Object([
            #("project", json.String("p1")),
            #("revision", json.Int(6)),
            #("ticket", asking("t-ask", 9, "pick a database")),
            #("assignments", json.Array([])),
            #(
              "inputs",
              json.Array([
                json.Object([
                  #("trigger", json.String("tr-1")),
                  #("delivery", json.String("failed")),
                  #("actor", json.String("mallory<i>")),
                  #("text", json.String(evil)),
                ]),
              ]),
            ),
          ]),
        )
      },
      fn(_, _, _, _) { feed.Recorded },
    )
  let model =
    run(opened(start_with(Some(projects))), home.OpeningTicket("p1", "t-ask"))
  let html = drawn(model)

  assert !string.contains(html, "<b onmouseover")
  assert string.contains(html, "&lt;b onmouseover=x&gt;ask&lt;/b&gt;")
  assert !string.contains(html, "mallory<i>")
  assert !string.contains(html, "\u{1b}")
  assert string.contains(html, "did not reach the worker")
}

// --- a ticket ----------------------------------------------------------------

pub fn pressing_a_ticket_reads_it_and_shows_why_it_was_allowed_test() {
  let #(start, asked) = serving(board_body(12, [asking("t-ask", 9, "pick")]))
  let model = run(opened(start), home.OpeningTicket("p1", "t-ask"))
  let html = drawn(model)

  assert list.contains(drain(asked), ReadTicket("p1", "t-ask"))
  assert string.contains(html, "You asked for it in the composer. Policy v1.")
  assert string.contains(html, "QUESTION 9")
  assert string.contains(html, "which database?")
  assert string.contains(html, "Send answer")
  assert string.contains(html, "add storage")
  assert string.contains(html, "Open the worker")
}

pub fn a_press_for_a_ticket_the_page_does_not_hold_opens_nothing_test() {
  let #(start, asked) = serving(mixed())
  let model = opened(start)
  let _ = drain(asked)
  let after = run(model, home.OpeningTicket("p1", "t-forged"))
  let elsewhere = run(model, home.OpeningTicket("other", "t-new-answer"))

  assert after == model
  assert elsewhere == model
  assert drain(asked) == []
}

pub fn an_answer_sends_the_sequence_number_the_form_was_drawn_with_test() {
  let #(start, asked) = serving(board_body(12, [asking("t-ask", 9, "pick")]))
  let model = run(opened(start), home.OpeningTicket("p1", "t-ask"))
  let _ = drain(asked)
  let after = run(model, home.Answering(9, "sqlite"))

  // The answer, and then the read that shows the question as the daemon now has
  // it.
  assert drain(asked)
    == [Answered("p1", "t-ask", 9, "sqlite"), ReadTicket("p1", "t-ask")]
  assert string.contains(drawn(after), "Answer queued for the worker.")
}

pub fn an_empty_answer_asks_nothing_test() {
  let #(start, asked) = serving(board_body(12, [asking("t-ask", 9, "pick")]))
  let model = run(opened(start), home.OpeningTicket("p1", "t-ask"))
  let _ = drain(asked)
  let after = run(model, home.Answering(9, "   "))

  assert after == model
  assert drain(asked) == []
}

pub fn a_stale_answer_is_refused_and_said_in_words_test() {
  let asked = process.new_subject()
  let projects =
    projects_with(
      asked,
      fn() { listed(board_body(12, [asking("t-ask", 10, "pick")])) },
      fn(_, _) { feed.TicketHeard(detail(10)) },
      fn(_, _, _, _) { feed.Refused("conflict") },
    )
  let model =
    run(opened(start_with(Some(projects))), home.OpeningTicket("p1", "t-ask"))

  // The form on screen was drawn with the old question's number, which the
  // daemon no longer has open.
  let after = run(model, home.Answering(9, "sqlite"))
  let html = drawn(after)

  assert string.contains(
    html,
    "The question changed while you were typing. Nothing was recorded",
  )
  assert !string.contains(html, "Answer queued for the worker.")
  assert list.contains(drain(asked), Answered("p1", "t-ask", 9, "sqlite"))
}

// The owner who accepts a ticket's work closes it from the ticket page. The
// daemon is asked once, and the ticket is read again to show where it stands.
pub fn closing_a_ticket_asks_the_daemon_once_and_reads_it_again_test() {
  let #(start, asked) = serving(board_body(12, [asking("t-ask", 9, "pick")]))
  let model = run(opened(start), home.OpeningTicket("p1", "t-ask"))
  let _ = drain(asked)
  assert string.contains(drawn(model), "Close ticket")

  let after = run(model, home.ClosingWork)
  assert drain(asked) == [Accepted("p1", "t-ask"), ReadTicket("p1", "t-ask")]
  assert string.contains(drawn(after), "Ticket closed.")
}

// A refused close is said in words and keeps the page where it was.
pub fn a_refused_close_is_said_in_words_test() {
  let asked = process.new_subject()
  let projects =
    home.Projects(
      boards: fn(deliver) {
        deliver(listed(board_body(12, [asking("t-ask", 9, "pick")])))
      },
      ticket: fn(_, _, deliver) { deliver(feed.TicketHeard(detail(9))) },
      answer: fn(_, _, _, _, deliver) { deliver(feed.Recorded) },
      close: fn(project, id, deliver) {
        process.send(asked, Accepted(project, id))
        deliver(feed.NotClosed("bad_request"))
      },
    )
  let model =
    run(opened(start_with(Some(projects))), home.OpeningTicket("p1", "t-ask"))

  let after = run(model, home.ClosingWork)
  assert string.contains(
    drawn(after),
    "That ticket cannot be closed: it has ended or was stopped.",
  )
}

// A ticket whose worker never started reads as failed with the daemon's words,
// and the page offers what the daemon lists: a close, and no answer box.
pub fn a_failed_start_shows_the_reason_and_offers_what_is_listed_test() {
  let failed =
    json.Object([
      #("id", json.String("t-bad")),
      #("title", json.String("never started")),
      #("stage", json.String("person/failed")),
      #("session", json.Null),
      #("opened_ms", json.Int(1000)),
      #("question", json.Null),
      #("failure", json.String("the clone was not made")),
      #("actions", json.Array([json.String("retry")])),
    ])
  let projects =
    home.Projects(
      boards: fn(deliver) { deliver(listed(board_body(12, [failed]))) },
      ticket: fn(_, _, deliver) {
        deliver(
          feed.TicketHeard(
            json.Object([
              #("project", json.String("p1")),
              #("revision", json.Int(12)),
              #("ticket", failed),
              #("assignments", json.Array([])),
              #("inputs", json.Array([])),
            ]),
          ),
        )
      },
      answer: fn(_, _, _, _, deliver) { deliver(feed.Recorded) },
      close: fn(_, _, deliver) { deliver(feed.Closed) },
    )
  let model =
    run(opened(start_with(Some(projects))), home.OpeningTicket("p1", "t-bad"))
  assert string.contains(
    drawn(model),
    "The worker failed: the clone was not made",
  )
  assert !string.contains(drawn(model), "Close ticket")
}

// An ended ticket has nothing to close, so the page draws no button for it.
pub fn an_ended_ticket_has_no_close_button_test() {
  let done = ticket("t-done", "ended/closed", 1000, "done")
  let projects =
    home.Projects(
      boards: fn(deliver) { deliver(listed(board_body(12, [done]))) },
      ticket: fn(_, _, deliver) {
        deliver(
          feed.TicketHeard(
            json.Object([
              #("project", json.String("p1")),
              #("revision", json.Int(12)),
              #("ticket", done),
              #("assignments", json.Array([])),
              #("inputs", json.Array([])),
            ]),
          ),
        )
      },
      answer: fn(_, _, _, _, deliver) { deliver(feed.Recorded) },
      close: fn(_, _, deliver) { deliver(feed.Closed) },
    )
  let model =
    run(opened(start_with(Some(projects))), home.OpeningTicket("p1", "t-done"))
  assert string.contains(drawn(model), "t-done")
  assert !string.contains(drawn(model), "Close ticket")
}

pub fn back_returns_to_the_composer_or_the_list_test() {
  let #(start, _) = serving(board_body(12, [asking("t-ask", 9, "pick")]))
  let model = run(opened(start), home.OpeningTicket("p1", "t-ask"))
  let back = run(model, home.ClosingTicket)

  assert !string.contains(drawn(back), "QUESTION 9")
  assert string.contains(drawn(back), "Projects")
}

// --- the answer to a ticket that has gone ------------------------------------

pub fn a_ticket_the_project_no_longer_holds_sends_the_person_back_test() {
  let asked = process.new_subject()
  let projects =
    projects_with(
      asked,
      fn() { listed(board_body(12, [asking("t-ask", 9, "pick")])) },
      fn(_, _) { feed.TicketGone },
      fn(_, _, _, _) { feed.Recorded },
    )
  let model =
    run(opened(start_with(Some(projects))), home.OpeningTicket("p1", "t-ask"))

  assert !string.contains(drawn(model), "QUESTION 9")
}

// --- repainting --------------------------------------------------------------

pub fn a_board_with_the_same_revision_changes_nothing_test() {
  let #(start, _) = serving(mixed())
  let model = opened(start)
  let serial = home.board_reads(model)
  let again = run(model, home.BoardsRead(serial, listed(mixed())))

  assert again == model
}

pub fn a_board_with_a_new_revision_replaces_the_tickets_test() {
  let #(start, _) = serving(mixed())
  let model = opened(start)
  let newer =
    board_body(10, [ticket("t-arrived", "person/answer", 5000, "just arrived")])
  let after =
    run(model, home.BoardsRead(home.board_reads(model), listed(newer)))

  assert string.contains(drawn(after), "just arrived")
  assert !string.contains(drawn(after), "newer question")
}

pub fn an_answer_that_a_newer_read_overtook_is_dropped_test() {
  let #(start, _) = serving(mixed())
  let model = opened(start)
  let stale = home.board_reads(model) - 1
  let after = run(model, home.BoardsRead(stale, listed(board_body(99, []))))

  assert after == model
}

// --- who may see a project ---------------------------------------------------

pub fn a_page_without_the_capability_draws_nothing_and_ignores_the_messages_test() {
  let model = opened(start_with(None))

  assert !string.contains(drawn(model), "Projects")
  assert run(model, home.OpeningTicket("p1", "t-new-answer")) == model
  assert run(model, home.Answering(9, "sqlite")) == model
  assert run(model, home.BoardsRead(0, listed(mixed()))) == model
}

pub fn every_handler_of_the_section_is_beneath_its_own_region_test() {
  let model = opened(serving(mixed()).0)
  let keys = handlers(home.view(model))
  let ticket_keys =
    list.filter(keys, string.starts_with(_, home.projects_path <> "\t"))

  assert ticket_keys != []
  assert list.all(ticket_keys, string.ends_with(_, "\nclick"))
  assert home.projects_path == "0\t2\t0"
  assert home.table_path == "0\t2\t1"
}

pub fn a_ticket_pages_handlers_are_beneath_the_table_region_test() {
  let #(start, _) = serving(board_body(12, [asking("t-ask", 9, "pick")]))
  let model = run(opened(start), home.OpeningTicket("p1", "t-ask"))
  let keys = handlers(home.view(model))
  let page_keys =
    list.filter(keys, string.starts_with(_, home.table_path <> "\t"))

  assert page_keys != []
  assert list.any(page_keys, string.ends_with(_, "\nsubmit"))
}

// Every message the fake daemon recorded so far, oldest first.
fn drain(asked: Subject(Asked)) -> List(Asked) {
  case process.receive(asked, 0) {
    Ok(one) -> [one, ..drain(asked)]
    Error(Nil) -> []
  }
}

//// Project tickets as threads on Home (`web_view/view/ticket_thread`, wired in
//// `web_view/home`, protocol-change/051, the addendum on project tickets on
//// Home).
////
//// The page is driven through `home.update` and drawn with `home.view`, with
//// the daemon's project reads and acts replaced by functions that record what
//// they are asked. What these tests pin: a ticket waiting on a person is a row
//// under Needs you, a stage this client does not know is drawn as its raw
//// word, the controls are exactly the actions the daemon lists, an answer
//// sends the sequence number the form was drawn with, a refusal is shown in
//// words, Stop and Close ask once before they send, a control the list does
//// not hold asks nothing, an observer has the thread and no control, and
//// every word a ticket carries is escaped text.

import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/home
import web_view/projects as feed
import web_view/saved_attention
import web_view/sessions.{Entry, Live}
import web_view/signins
import web_view/ticket_rule

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

const now = 7_400_000

// What the page asked of the daemon, in order.
type Asked {
  ReadBoards
  ReadTicket(project: String, ticket: String)
  Answered(project: String, ticket: String, seq: Int, text: String)
  Closed(project: String, ticket: String)
  Stopped(project: String, ticket: String)
  Retried(project: String, ticket: String)
}

// What the daemon says to each act.
type Says {
  Says(answer: feed.Answer, close: feed.Closing, act: feed.Acted)
}

fn accepting() -> Says {
  Says(answer: feed.Recorded, close: feed.Closed, act: feed.Acted)
}

fn ticket(
  id: String,
  stage: String,
  title: String,
  actions: List(String),
  asking: Option(Int),
) -> json.JsonValue {
  json.Object([
    #("id", json.String(id)),
    #("title", json.String(title)),
    #("stage", json.String(stage)),
    #("session", json.Null),
    #("opened_ms", json.Int(now - 300_000)),
    #("pull_request", json.String("https://example.test/pull/12")),
    #("actions", json.Array(list.map(actions, json.String))),
    #("question", case asking {
      Some(seq) ->
        json.Object([
          #("seq", json.Int(seq)),
          #("text", json.String("which <b>database</b>?")),
          #("options", json.Array([json.String("sqlite"), json.String("pg")])),
        ])
      None -> json.Null
    }),
  ])
}

fn tickets() -> List(json.JsonValue) {
  [
    ticket(
      "t-ask",
      "person/answer",
      "pick a \"><script>x</script> database",
      ["answer", "close", "stop"],
      Some(7),
    ),
    ticket("t-check", "person/check", "checks failed", ["retry"], None),
    ticket(
      "t-pub",
      "person/review",
      "ready to publish",
      [
        "publish",
        "close",
      ],
      None,
    ),
    ticket("t-work", "working", "building", ["stop"], None),
    ticket("t-two", "person/answer", "second asker", ["answer"], Some(3)),
  ]
}

fn board_body(revision: Int) -> json.JsonValue {
  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(revision)),
    #("total", json.Int(5)),
    #("tickets", json.Array(tickets())),
  ])
}

// The ticket read for a thread is the board's own row, at a newer revision.
fn detail_of(id: String) -> json.JsonValue {
  let row =
    list.find(tickets(), fn(each) {
      case each {
        json.Object(fields) -> list.contains(fields, #("id", json.String(id)))
        json.Array(_)
        | json.String(_)
        | json.Int(_)
        | json.Float(_)
        | json.Bool(_)
        | json.Null -> False
      }
    })

  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(12)),
    #("ticket", case row {
      Ok(found) -> found
      Error(Nil) -> json.Null
    }),
    #("assignments", json.Array([])),
    #("inputs", json.Array([])),
  ])
}

fn projects_for(asked: Subject(Asked), says: Says) -> home.Projects {
  home.Projects(
    boards: fn(deliver) {
      process.send(asked, ReadBoards)
      deliver(feed.Heard([feed.Listed("p1", "/src/loom", board_body(9))]))
    },
    ticket: fn(project, id, deliver) {
      process.send(asked, ReadTicket(project, id))
      deliver(feed.TicketHeard(detail_of(id)))
    },
    answer: fn(project, id, seq, text, deliver) {
      process.send(asked, Answered(project, id, seq, text))
      deliver(says.answer)
    },
    close: fn(project, id, deliver) {
      process.send(asked, Closed(project, id))
      deliver(says.close)
    },
    stop: fn(project, id, deliver) {
      process.send(asked, Stopped(project, id))
      deliver(says.act)
    },
    retry: fn(project, id, deliver) {
      process.send(asked, Retried(project, id))
      deliver(says.act)
    },
  )
}

fn start_with(
  ceiling: home.Ceiling,
  projects: Option(home.Projects),
) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling:,
    refresh_ms: 5,
    sessions: fn(deliver) {
      deliver(
        home.Listed([
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
        ]),
      )
    },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { now },
    activity: fn(_, deliver) { deliver([]) },
    rename: None,
    manage: None,
    thread_send: None,
    attention: None,
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
    passkeys: None,
    visiting: None,
    orchestrators: None,
    executors: [],
    pools: [],
    machine: "box",
    placements: fn(_) { Nil },
  )
}

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

fn drawn(model: home.Model) -> String {
  element.to_string(home.view(model))
}

fn drain(asked: Subject(Asked)) -> List(Asked) {
  case process.receive(asked, 0) {
    Ok(one) -> [one, ..drain(asked)]
    Error(Nil) -> []
  }
}

fn key(id: String) -> ticket_rule.Key {
  ticket_rule.Key(project: "p1", ticket: id)
}

// A page whose timer exists and whose first read has answered, on the inbox. A
// project board that is read after the list does not take a composer the page
// settled on, so the inbox is the person's press, as "Inbox" is.
fn open_inbox(start: home.Start) -> home.Model {
  run(
    run(home.new(start), home.TimerReady(process.new_subject())),
    home.ShowingInbox,
  )
}

// An owner's operating page that has read the board, landing on the inbox.
fn owner(says: Says) -> #(home.Model, Subject(Asked)) {
  let asked = process.new_subject()
  let start = start_with(home.OperatorCeiling, Some(projects_for(asked, says)))
  let model = open_inbox(start)
  let _ = drain(asked)

  #(model, asked)
}

// The same page with one thread open.
fn picked(model: home.Model, id: String) -> home.Model {
  run(model, home.TicketThreadPicked(key(id)))
}

// The press on a confirmation, as the page draws it.
fn confirm(id: String, control: ticket_rule.Control) -> home.Msg {
  home.TicketActConfirmed(key(id), control)
}

// Whether two lists hold the same asks. The page starts the read of the ticket
// and the read of the boards after an act in no order a test should depend on.
fn same(got: List(Asked), want: List(Asked)) -> Bool {
  list.length(got) == list.length(want)
  && list.all(want, fn(each) { list.contains(got, each) })
}

// A ticket waiting on a person is a row under Needs you, in the board's order,
// and one that needs nobody is not a thread. The headline counts the tickets as
// their own clause.
pub fn waiting_tickets_are_rows_under_needs_you_test() {
  let #(model, _) = owner(accepting())
  let html = drawn(model)

  assert string.contains(html, "Needs you")
  assert string.contains(html, "<span class=\"inbox-kind\">Ticket</span>")
  assert string.contains(html, " · review</span>")
  assert string.contains(html, "t-check · person/check")
  assert string.contains(
    html,
    "<span class=\"nm\">Projects</span><span class=\"n\">4</span>",
  )
  assert !string.contains(html, "building")
}

// A failed check keeps the daemon's stage word, person/check, until the owner
// rules on what the inbox calls it, and the pane draws only what the daemon
// lists: here a Retry and nothing else, so no Recheck.
pub fn person_check_is_named_with_only_what_is_listed_test() {
  let #(model, _) = owner(accepting())
  let html = drawn(picked(model, "t-check"))

  assert string.contains(html, "t-check · person/check")
  assert string.contains(html, "Retry")
  assert !string.contains(html, "Recheck")
  assert !string.contains(html, "Close ticket")
  assert !string.contains(html, "Send answer")
}

// The controls are exactly the daemon's listed actions. The first ticket lists
// an answer, a close and a stop; the third lists a publish and a close, and a
// publish draws nothing because the board carries no reason to show with it.
pub fn controls_match_the_listed_actions_test() {
  let #(model, _) = owner(accepting())

  let ask = drawn(picked(model, "t-ask"))
  assert string.contains(ask, "Send answer")
  assert string.contains(ask, "Close ticket")
  assert string.contains(ask, ">Stop<")
  assert !string.contains(ask, ">Retry<")

  let review = drawn(picked(model, "t-pub"))
  assert string.contains(review, "Close ticket")
  assert !string.contains(review, "Publish")
  assert !string.contains(review, ">Stop<")
  assert !string.contains(review, "Send answer")
}

// The pane shows the question, its options and the pull request, and says so
// plainly when the board carries no branch or diff stat: it draws none.
pub fn the_pane_shows_the_question_and_the_pull_request_test() {
  let #(model, _) = owner(accepting())
  let html = drawn(picked(model, "t-ask"))

  assert string.contains(html, "which &lt;b&gt;database&lt;/b&gt;?")
  assert string.contains(html, "Options: sqlite · pg")
  assert string.contains(html, "Pull request: https://example.test/pull/12")
  assert !string.contains(html, "diff")
}

// An answer sends the question's sequence number and the text through the
// project answer path, the ticket is read again, and the daemon's word is shown.
pub fn an_answer_sends_through_the_answer_path_test() {
  let #(model, asked) = owner(accepting())
  let model = picked(model, "t-ask")
  let _ = drain(asked)

  let after = run(model, home.TicketAnswerSent(7, "sqlite"))
  assert same(drain(asked), [
    Answered("p1", "t-ask", 7, "sqlite"),
    ReadTicket("p1", "t-ask"),
    ReadBoards,
  ])
  assert string.contains(drawn(after), "Answer queued for the worker.")
}

// A refusal is shown in the daemon's words, and the question that changed is
// the one that says nothing was recorded.
pub fn a_refused_answer_is_shown_in_words_test() {
  let #(model, _) = owner(Says(..accepting(), answer: feed.Refused("conflict")))
  let after = run(picked(model, "t-ask"), home.TicketAnswerSent(7, "sqlite"))

  assert string.contains(
    drawn(after),
    "The question changed while you were typing. Nothing was recorded",
  )
}

// An answer to a question the pane was not drawn with, an empty answer and a
// control the daemon does not list for the ticket each ask nothing.
pub fn presses_the_list_does_not_hold_ask_nothing_test() {
  let #(model, asked) = owner(accepting())
  let model = picked(model, "t-check")
  let _ = drain(asked)

  let _ = run(model, home.TicketAnswerSent(7, "sqlite"))
  let stop = run(model, home.TicketControlPressed(ticket_rule.Stop))
  let _ = run(stop, confirm("t-check", ticket_rule.Stop))
  let close = run(model, home.TicketControlPressed(ticket_rule.Close))
  let _ = run(close, confirm("t-check", ticket_rule.Close))
  assert drain(asked) == []

  let ask = picked(model, "t-ask")
  let _ = drain(asked)
  let _ = run(ask, home.TicketAnswerSent(7, "   "))
  let _ = run(ask, home.TicketAnswerSent(8, "sqlite"))
  assert drain(asked) == []
}

// Stop asks once. The first press sends nothing and names the act; "Keep" takes
// it back; the confirmation sends the stop and the daemon's word is shown.
pub fn stop_needs_one_confirm_click_test() {
  let #(model, asked) = owner(accepting())
  let model = picked(model, "t-ask")
  let _ = drain(asked)

  let asking = run(model, home.TicketControlPressed(ticket_rule.Stop))
  assert drain(asked) == []
  assert string.contains(drawn(asking), "this cannot be undone")
  assert string.contains(drawn(asking), "Confirm: Stop")

  let kept = run(asking, home.TicketActKept)
  assert !string.contains(drawn(kept), "this cannot be undone")
  let _ = run(kept, confirm("t-ask", ticket_rule.Stop))
  assert drain(asked) == []

  let stopped = run(asking, confirm("t-ask", ticket_rule.Stop))
  assert same(drain(asked), [
    Stopped("p1", "t-ask"),
    ReadTicket("p1", "t-ask"),
    ReadBoards,
  ])
  assert string.contains(drawn(stopped), "Ticket stopped.")
}

// Close asks once too, and a refused close is said in the board's words.
pub fn close_needs_one_confirm_click_and_a_refusal_is_shown_test() {
  let #(model, asked) =
    owner(Says(..accepting(), close: feed.NotClosed("bad_request")))
  let model = picked(model, "t-pub")
  let _ = drain(asked)

  let asking = run(model, home.TicketControlPressed(ticket_rule.Close))
  assert drain(asked) == []

  let after = run(asking, confirm("t-pub", ticket_rule.Close))
  assert same(drain(asked), [
    Closed("p1", "t-pub"),
    ReadTicket("p1", "t-pub"),
    ReadBoards,
  ])
  assert string.contains(
    drawn(after),
    "That ticket cannot be closed: it has ended or was stopped.",
  )
}

// Retry is sent at once, since it only asks for a new worker.
pub fn retry_sends_at_once_test() {
  let #(model, asked) = owner(accepting())
  let model = picked(model, "t-check")
  let _ = drain(asked)

  let after = run(model, home.TicketControlPressed(ticket_rule.Retry))
  assert same(drain(asked), [
    Retried("p1", "t-check"),
    ReadTicket("p1", "t-check"),
    ReadBoards,
  ])
  assert string.contains(drawn(after), "A new worker was requested.")
}

// A refusal of a stop or a retry shows the daemon's code as a sentence.
pub fn a_refused_stop_is_shown_in_words_test() {
  let #(model, _) = owner(Says(..accepting(), act: feed.Declined("forbidden")))
  let model = picked(model, "t-ask")
  let asking = run(model, home.TicketControlPressed(ticket_rule.Stop))
  let after = run(asking, confirm("t-ask", ticket_rule.Stop))

  assert string.contains(drawn(after), "Only the owner can stop a project")
}

// An observing page that holds the capability draws the thread and its
// question and no control: no form, no button, and a press that reaches the
// page anyway asks the daemon nothing.
pub fn an_observer_sees_the_thread_and_has_no_controls_test() {
  let asked = process.new_subject()
  let start =
    start_with(home.ObserverCeiling, Some(projects_for(asked, accepting())))
  let model = picked(open_inbox(start), "t-ask")
  let _ = drain(asked)
  let html = drawn(model)

  assert string.contains(html, "which &lt;b&gt;database&lt;/b&gt;?")
  assert string.contains(html, "operating page can act on a ticket")
  assert !string.contains(html, "Send answer")
  assert !string.contains(html, "Close ticket")
  assert !string.contains(html, ">Stop<")
  assert !string.contains(html, "<textarea")

  let _ = run(model, home.TicketAnswerSent(7, "sqlite"))
  let _ = run(model, home.TicketControlPressed(ticket_rule.Stop))
  let _ = run(model, home.TicketControlPressed(ticket_rule.Close))
  let _ = run(model, confirm("t-ask", ticket_rule.Stop))
  let _ = run(model, confirm("t-ask", ticket_rule.Close))
  assert drain(asked) == []
}

// A page with no projects capability draws no ticket thread and ignores the
// messages that name one.
pub fn a_page_without_the_capability_has_no_threads_test() {
  let start = start_with(home.OperatorCeiling, None)
  let model = picked(open_inbox(start), "t-ask")

  assert !string.contains(drawn(model), "Ticket ·")
  assert !string.contains(drawn(model), "database")
}

// Every word a ticket carries is escaped text. The title tries to close an
// attribute and open a tag, and it is only text in a text node.
pub fn ticket_text_is_text_and_never_an_attribute_test() {
  let #(model, _) = owner(accepting())
  let html = drawn(picked(model, "t-ask"))

  assert string.contains(
    html,
    "pick a &quot;&gt;&lt;script&gt;x&lt;/script&gt; database",
  )
  assert !string.contains(html, "<script>")
  assert !string.contains(html, "\"><script")
}

// The thread's rows, buttons and answer form are handlers beneath the table
// region, which every home's socket admits, so no new admission is needed; the
// capability and the press-time check are what decide.
pub fn the_thread_handlers_are_beneath_the_table_region_test() {
  let #(model, _) = owner(accepting())
  let keys = handlers(home.view(picked(model, "t-ask")))
  let page_keys =
    list.filter(keys, string.starts_with(_, home.table_path <> "\t"))

  assert page_keys != []
  assert list.any(page_keys, string.ends_with(_, "\nsubmit"))
  assert list.all(page_keys, fn(path) {
    string.ends_with(path, "\nclick") || string.ends_with(path, "\nsubmit")
  })
}

// The answer box is keyed by project, ticket and question number, all daemon
// identities, so text typed for one ticket's question cannot be submitted for
// another's, and a new question on the same ticket gets a fresh box.
pub fn the_answer_form_is_keyed_by_ticket_and_question_test() {
  let #(model, _) = owner(accepting())
  let first = drawn(picked(model, "t-ask"))
  let second = drawn(picked(model, "t-two"))

  assert string.contains(
    first,
    "data-lustre-key=\"ticket-answer-p1-t-ask-7-0\"",
  )
  assert string.contains(
    second,
    "data-lustre-key=\"ticket-answer-p1-t-two-3-0\"",
  )
  assert !string.contains(first, "t-two-3")

  // A recorded answer moves the key, as it always did.
  let after = run(picked(model, "t-ask"), home.TicketAnswerSent(7, "sqlite"))
  assert string.contains(drawn(after), "ticket-answer-p1-t-ask-7-1")
}

// A confirmation sends only what it was drawn for: a press that names another
// act or another ticket than the one asked about sends nothing, and an act the
// daemon stops listing between the arming and the confirm is dropped with its
// question.
pub fn a_confirmation_sends_nothing_the_list_no_longer_holds_test() {
  let #(model, asked) = owner(accepting())
  let armed =
    run(picked(model, "t-ask"), home.TicketControlPressed(ticket_rule.Stop))
  let _ = drain(asked)

  let _ = run(armed, confirm("t-ask", ticket_rule.Close))
  let _ = run(armed, confirm("t-pub", ticket_rule.Stop))
  assert drain(asked) == []

  // The ticket is read again and the daemon no longer lists a stop.
  let changed =
    run(
      armed,
      home.TicketThreadRead(
        key("t-ask"),
        feed.TicketHeard(
          json.Object([
            #("project", json.String("p1")),
            #("revision", json.Int(13)),
            #(
              "ticket",
              ticket(
                "t-ask",
                "person/answer",
                "pick",
                ["answer", "close"],
                Some(7),
              ),
            ),
            #("assignments", json.Array([])),
            #("inputs", json.Array([])),
          ]),
        ),
      ),
    )
  assert !string.contains(drawn(changed), "Confirm: Stop")
  let _ = run(changed, confirm("t-ask", ticket_rule.Stop))
  assert drain(asked) == []
}

// Pressing the row of the open ticket again reads it again and keeps what the
// thread holds, so an act that is out stays out.
pub fn pressing_the_open_row_again_keeps_the_thread_test() {
  let #(model, asked) = owner(accepting())
  let armed =
    run(picked(model, "t-ask"), home.TicketControlPressed(ticket_rule.Stop))
  let _ = drain(asked)

  let again = picked(armed, "t-ask")
  assert string.contains(drawn(again), "Confirm: Stop")
  assert drain(asked) == [ReadTicket("p1", "t-ask")]
}

// --- landing -----------------------------------------------------------------

fn empty_board() -> json.JsonValue {
  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(1)),
    #("total", json.Int(0)),
    #("tickets", json.Array([])),
  ])
}

fn quiet_projects(asked: Subject(Asked)) -> home.Projects {
  home.Projects(..projects_for(asked, accepting()), boards: fn(deliver) {
    deliver(feed.Heard([feed.Listed("p1", "/src/loom", empty_board())]))
  })
}

fn saved_entry() -> sessions.Entry {
  Entry(
    id: "D",
    name: "hex release",
    workspace: "/src/loom",
    created_at: 100_000,
    residency: sessions.Saved,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

// A page that lists one saved session, so a catalogue summary is due, and reads
// the feed. `summary` is what the catalogue's read does when asked.
fn with_summary(
  projects: home.Projects,
  summary: fn(fn(List(saved_attention.Saved)) -> Nil) -> Nil,
) -> home.Start {
  home.Start(
    ..start_with(home.OperatorCeiling, Some(projects)),
    sessions: fn(deliver) { deliver(home.Listed([saved_entry()])) },
    attention: Some(
      home.Attention(
        feed: fn(_, deliver) { deliver([]) },
        saved: fn(_, deliver) { summary(deliver) },
        record: fn(_, _, deliver) { deliver(Error("none")) },
        approvals: fn(_, deliver) { deliver(Error("none")) },
        review: None,
        review_pause_ms: 0,
        act: None,
        brief: fn(_, _, _) { Nil },
      ),
    ),
  )
}

fn waiting_summary() -> saved_attention.Saved {
  saved_attention.Saved(
    session_id: "D",
    pending_approvals: 1,
    open_asks: 1,
    open_finds: 0,
    oldest_open_at: Some(5),
    updated_at: 9,
  )
}

// A page with no running session lands on the inbox when its first board read
// holds a ticket waiting on a person, with no press: the board takes part in the
// landing as the first catalogue summary does.
pub fn a_ticket_only_page_lands_on_the_inbox_test() {
  let asked = process.new_subject()
  let start =
    home.Start(
      ..start_with(home.OperatorCeiling, Some(projects_for(asked, accepting()))),
      sessions: fn(deliver) { deliver(home.Listed([])) },
    )
  let model = run(home.new(start), home.TimerReady(process.new_subject()))
  let html = drawn(model)

  assert string.contains(html, "<span class=\"inbox-kind\">Ticket</span>")

  // Two of the four tickets are a check and a review, which sit under "To
  // review" and are read, not answered, so two wait under "Needs you".
  assert string.contains(html, "<span class=\"need-pill\">2 need you</span>")
}

// A page whose first board read held nothing settles on the composer, and a
// ticket that appears in a later read never covers it. The page is the list, as
// a page that cannot create is, so the "Inbox" control is the evidence: it shows
// once the later board holds a ticket, which proves the read was applied, and
// the inbox is still not the centre.
pub fn a_later_board_never_covers_a_settled_composer_test() {
  let asked = process.new_subject()
  let start =
    home.Start(
      ..start_with(home.OperatorCeiling, Some(quiet_projects(asked))),
      sessions: fn(deliver) { deliver(home.Listed([])) },
    )
  let model = run(home.new(start), home.TimerReady(process.new_subject()))
  assert !string.contains(drawn(model), "\u{2039} Inbox")

  let later =
    run(
      model,
      home.BoardsRead(
        home.board_reads(model),
        feed.Heard([feed.Listed("p1", "/src/loom", board_body(9))]),
      ),
    )
  let html = drawn(later)
  assert string.contains(html, "\u{2039} Inbox")
  assert !string.contains(html, "<h1>Inbox</h1>")
  assert !string.contains(html, "Ticket \u{b7}")
}

// A board that holds a ticket and answers before the summary is not lost when
// the summary arrives: the round decides on the last read with everything it
// gathered, and the ticket lands the inbox though the summary counted nothing.
pub fn a_ticket_that_came_before_the_summary_lands_the_inbox_test() {
  let asked = process.new_subject()
  let start = with_summary(projects_for(asked, accepting()), fn(_) { Nil })
  let model = run(home.new(start), home.TimerReady(process.new_subject()))
  assert !string.contains(drawn(model), "<h1>Inbox</h1>")

  let decided = run(model, home.SavedRead([]))
  let html = drawn(decided)
  assert string.contains(html, "<h1>Inbox</h1>")
  assert string.contains(
    html,
    "<span class=\"nm\">Projects</span><span class=\"n\">4</span>",
  )
}

// An empty first summary and then a board with no ticket settle the centre at
// once: a later summary that counts something no longer covers the composer.
// The control to the inbox appears with it, which shows the later summary was
// read and the page still did not move.
pub fn an_empty_summary_and_an_empty_board_settle_the_centre_test() {
  let asked = process.new_subject()
  let start = with_summary(quiet_projects(asked), fn(deliver) { deliver([]) })
  let model = run(home.new(start), home.TimerReady(process.new_subject()))
  assert !string.contains(drawn(model), "\u{2039} Inbox")

  let later = drawn(run(model, home.SavedRead([waiting_summary()])))
  assert !string.contains(later, "<h1>Inbox</h1>")
  assert string.contains(later, "\u{2039} Inbox")
}

// A board read that tells nothing still counts as the board's answer, so the
// round closes on the summary that follows and decides the composer.
pub fn an_unread_board_still_ends_the_wait_test() {
  let asked = process.new_subject()
  let unread =
    home.Projects(..projects_for(asked, accepting()), boards: fn(deliver) {
      deliver(feed.Unread)
    })
  let start = with_summary(unread, fn(deliver) { deliver([]) })
  let model = run(home.new(start), home.TimerReady(process.new_subject()))
  assert !string.contains(drawn(model), "\u{2039} Inbox")

  let later = drawn(run(model, home.SavedRead([waiting_summary()])))
  assert !string.contains(later, "<h1>Inbox</h1>")
  assert string.contains(later, "\u{2039} Inbox")
}

// The "Inbox" control shows on a decided composer whose only content is a
// ticket: the board that arrives after the decision is not a landing, and it is
// reachable.
pub fn the_inbox_control_shows_for_a_ticket_on_a_decided_composer_test() {
  let asked = process.new_subject()
  let start =
    home.Start(
      ..start_with(home.OperatorCeiling, Some(quiet_projects(asked))),
      sessions: fn(deliver) { deliver(home.Listed([])) },
      create: Some(fn(_, _, _, _, _, _, _) { Nil }),
    )
  let model = run(home.new(start), home.TimerReady(process.new_subject()))
  let calm = drawn(model)
  assert string.contains(calm, "<h1>New session</h1>")

  let later =
    drawn(run(
      model,
      home.BoardsRead(
        home.board_reads(model),
        feed.Heard([feed.Listed("p1", "/src/loom", board_body(9))]),
      ),
    ))
  assert string.contains(later, "<h1>New session</h1>")
  assert string.contains(later, "class=\"folder need\"")
}

// A first list that cannot be read is no answer: a board that answers beside it
// decides nothing, and the first readable list then decides with the board in
// hand, here on the inbox because the board holds tickets.
pub fn an_unread_first_list_leaves_the_round_open_test() {
  let asked = process.new_subject()
  let lists = process.new_subject()
  process.send(lists, home.Unread)
  let start =
    home.Start(
      ..start_with(home.OperatorCeiling, Some(projects_for(asked, accepting()))),
      sessions: fn(deliver) {
        case process.receive(lists, 0) {
          Ok(first) -> deliver(first)
          Error(Nil) -> deliver(home.Listed([]))
        }
      },
    )
  let model = run(home.new(start), home.TimerReady(process.new_subject()))

  // The board answered, and with an unread list it decided nothing.
  assert !string.contains(drawn(model), "<h1>Inbox</h1>")

  let decided = drawn(run(model, home.Ticked))
  assert string.contains(decided, "<h1>Inbox</h1>")
  assert string.contains(decided, "4 tickets need you")
}

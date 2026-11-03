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
import gleam/int
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

// A ticket in review whose only offered action is a retry, as the daemon lists
// it for a finished worker that has no session.
fn in_review() -> json.JsonValue {
  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(12)),
    #(
      "ticket",
      json.Object([
        #("id", json.String("t-ask")),
        #("title", json.String("review me")),
        #("stage", json.String("person/review")),
        #("session", json.String("s_01")),
        #("opened_ms", json.Int(1000)),
        #("question", json.Null),
        #("actions", json.Array([json.String("retry")])),
      ]),
    ),
    #("assignments", json.Array([])),
    #("inputs", json.Array([])),
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

// A source that cannot be read says so in its note, and the board draws it
// under the health line so a person is not told only that nothing needs them.
pub fn a_sources_note_is_drawn_under_the_health_line_test() {
  let document =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(4)),
      #("total", json.Int(0)),
      #("tickets", json.Array([])),
      #(
        "sources",
        json.Array([
          json.Object([
            #("source", json.String("github")),
            #(
              "note",
              json.String(
                "the project's origin is not a URL, so its source is not read \u{1b}[31m",
              ),
            ),
          ]),
        ]),
      ),
    ])
  let text = painted(showing(document))

  assert string.contains(text, "Nothing needs you.")
  assert string.contains(text, "origin is not a URL")
  assert !string.contains(text, "\u{1b}[31m")
  assert at(text, "Nothing needs you.") < at(text, "origin is not a URL")

  // A board whose sources have nothing to say draws no such line.
  assert !string.contains(painted(showing(healthy())), "origin is not")
}

fn rule_document(labelled: Int, state: String) -> json.JsonValue {
  rule_document_with(labelled, state, [])
}

// The same board with extra fields on its one rule, such as a `run`.
fn rule_document_with(
  labelled: Int,
  state: String,
  extra: List(#(String, json.JsonValue)),
) -> json.JsonValue {
  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(5)),
    #("total", json.Int(0)),
    #("tickets", json.Array([])),
    #(
      "sources",
      json.Array([
        json.Object([
          #("source", json.String("github")),
          #(
            "rules",
            json.Array([
              json.Object([
                #("name", json.String("deps")),
                #("mode", json.String("observe")),
                #(
                  "verdict",
                  json.Object([
                    #("state", json.String(state)),
                    #(
                      "words",
                      json.String(
                        "No verdict yet. 12 of 30 triggers are labelled.",
                      ),
                    ),
                    #("labelled", json.Int(labelled)),
                    #("needed", json.Int(30)),
                  ]),
                ),
                ..extra
              ]),
            ]),
          ),
        ]),
      ]),
    ),
  ])
}

// The rule list shows each rule's mode, its verdict state and the labelled
// count against what is needed, and the daemon's sentence under it.
pub fn the_rule_list_shows_the_verdict_state_and_the_count_test() {
  let text = painted(showing(rule_document(12, "none")))

  assert string.contains(text, "RULES")
  assert string.contains(text, "deps: observe, no verdict, 12 of 30 labelled")
  assert string.contains(
    text,
    "No verdict yet. 12 of 30 triggers are labelled.",
  )
  assert !string.contains(painted(showing(healthy())), "RULES")
}

pub fn l_opens_the_labelling_page_and_y_and_n_judge_the_shown_trigger_test() {
  let model = showing(rule_document(12, "none"))
  let assert project_screen.Label(opened, "deps") =
    project_screen.update(keys.Char("l"), screen(model))
  assert project_screen.labelling_rule(opened) == Some("deps")

  // Nothing is judged before the candidates are read.
  let assert project_screen.Continue(_) =
    project_screen.update(keys.Char("y"), opened)

  let candidates =
    json.Object([
      #("rule", json.String("deps")),
      #("labelled", json.Int(12)),
      #("needed", json.Int(30)),
      #(
        "triggers",
        json.Array([
          json.Object([
            #("trigger", json.String("gh-c-1")),
            #("actor", json.String("dependabot[bot]")),
            #("text", json.String("bump left-pad \u{1b}[31mnow")),
            #("recorded", json.String("took")),
          ]),
          json.Object([
            #("trigger", json.String("gh-c-2")),
            #("actor", json.String("alice")),
            #("text", json.String("bump right-pad")),
            #("recorded", json.String("not_asked")),
          ]),
        ]),
      ),
    ])
  let assert Ok(read) = board.decode_labels(candidates)
  let reading = project_screen.observed_labels(opened, read)

  // `y` judges the shown trigger as one to take on, `n` as one not to, and `s`
  // passes over it to the next.
  let assert project_screen.Judge(_, "gh-c-1", board.ShouldTake) =
    project_screen.update(keys.Char("y"), reading)
  let assert project_screen.Judge(_, "gh-c-1", board.ShouldNotTake) =
    project_screen.update(keys.Char("n"), reading)
  let assert project_screen.Continue(passed) =
    project_screen.update(keys.Char("s"), reading)
  let assert project_screen.Judge(_, "gh-c-2", board.ShouldTake) =
    project_screen.update(keys.Char("y"), passed)

  // A label sent empties the candidates so they are read afresh, and Esc goes
  // back to the board.
  let after = project_screen.labelled(reading)
  assert after.labels == None
  assert project_screen.labelling_rule(after) == Some("deps")
  let assert project_screen.Continue(back) =
    project_screen.update(keys.Escape, reading)
  assert project_screen.labelling_rule(back) == None
}

pub fn a_board_with_no_rule_has_nothing_to_label_test() {
  let model = showing(healthy())
  let assert project_screen.Continue(same) =
    project_screen.update(keys.Char("l"), screen(model))
  assert project_screen.labelling_rule(same) == None
  assert string.contains(same.notice, "no rule to label")
}

// --- rule modes and verdicts ---------------------------------------------------

fn labelling_on(document: json.JsonValue) -> project_screen.State {
  let assert project_screen.Label(opened, "deps") =
    project_screen.update(keys.Char("l"), screen(showing(document)))
  opened
}

// The terminal on the labelling page of `deps`, with its candidates read, so
// the control slot is free for a change.
fn on_labelling(document: json.JsonValue) -> tui_model.Model {
  let asked = press(showing(document), "l")
  deliver(
    asked,
    job.ProjectLabelsLoaded(
      json.Object([
        #("rule", json.String("deps")),
        #("labelled", json.Int(30)),
        #("needed", json.Int(30)),
        #("triggers", json.Array([])),
      ]),
    ),
  )
}

fn running_run() -> #(String, json.JsonValue) {
  #(
    "run",
    json.Object([
      #("state", json.String("running")),
      #("done", json.Int(12)),
      #("of", json.Int(90)),
      #("calls", json.Int(12)),
      #("tokens", json.Int(5100)),
      #("started_ms", json.Int(1)),
    ]),
  )
}

fn ended_run(state: String) -> #(String, json.JsonValue) {
  #(
    "run",
    json.Object([
      #("state", json.String(state)),
      #("words", json.String("The daemon says " <> state <> ".")),
      #("calls", json.Int(90)),
      #("tokens", json.Int(41_000)),
      #("ended_ms", json.Int(2)),
    ]),
  )
}

pub fn the_mode_keys_set_off_observe_and_auto_test() {
  let opened = labelling_on(rule_document(30, "none"))

  let assert project_screen.SetMode(_, "deps", board.ModeOff) =
    project_screen.update(keys.Char("0"), opened)
  let assert project_screen.SetMode(_, "deps", board.ModeObserve) =
    project_screen.update(keys.Char("1"), opened)

  // `auto` is sent like the others: the client does not decide whether the
  // verdict allows it, so a rule with no verdict still sends the request.
  let assert project_screen.SetMode(_, "deps", board.ModeAuto) =
    project_screen.update(keys.Char("2"), opened)
}

pub fn r_runs_a_replay_verdict_at_once_test() {
  let opened = labelling_on(rule_document(30, "none"))

  let assert project_screen.RunVerdict(_, "deps", board.Replay) =
    project_screen.update(keys.Char("r"), opened)
}

// A live run spends model calls, so the live key only opens a confirmation
// that states the count, and nothing but Enter on it starts the run.
pub fn the_live_key_asks_before_it_runs_and_only_enter_confirms_test() {
  let opened = labelling_on(rule_document(30, "none"))
  let assert project_screen.Continue(asking) =
    project_screen.update(keys.Char("L"), opened)

  assert asking.page == project_screen.Confirming("deps", 30)

  // Every key but Enter and Escape leaves the confirmation as it was,
  // including the keys that act on the labelling page and a paste.
  list.each(
    [
      keys.Char("L"),
      keys.Char("r"),
      keys.Char("y"),
      keys.Char("n"),
      keys.Char("0"),
      keys.Char("2"),
      keys.Char("l"),
      keys.Tab,
    ],
    fn(key) {
      let assert project_screen.Continue(same) =
        project_screen.update(key, asking)
      assert same == asking
    },
  )
  let assert project_screen.Continue(pasted) =
    project_screen.update_pasted("\n", asking)
  assert pasted == asking

  // Escape cancels with nothing sent, and Enter is the one way to a live run.
  let assert project_screen.Continue(cancelled) =
    project_screen.update(keys.Escape, asking)
  assert cancelled.page == project_screen.Labelling("deps", 0)
  assert string.contains(cancelled.notice, "not started")

  let assert project_screen.RunVerdict(started, "deps", board.Live) =
    project_screen.update(keys.Enter, asking)
  assert started.page == project_screen.Labelling("deps", 0)
}

pub fn the_confirmation_states_the_labelled_count_and_the_calls_test() {
  let confirming = press(on_labelling(rule_document(30, "none")), "L")
  let text = painted(confirming)

  assert string.contains(text, "30 labelled triggers")
  assert string.contains(text, "about 90 calls")
  assert string.contains(text, "Enter starts it")

  // The count is the board's, so a rule with fewer labels says so.
  let few = painted(press(on_labelling(rule_document(12, "none")), "L"))
  assert string.contains(few, "12 labelled triggers")
  assert string.contains(few, "about 36 calls")
}

pub fn the_shipped_loop_sends_a_replay_and_a_mode_without_asking_test() {
  let labelling = on_labelling(rule_document(30, "none"))
  let assert Some(daemon) = labelling.view.daemon_host

  let #(_, replay) = stepping.step(backend.KeyPress("r"), labelling)
  assert control_jobs(replay)
    == [
      job.Control(
        daemon.control,
        job.ChangeRule(job.RunVerdict("p1", "deps", board.Replay)),
      ),
    ]

  let #(_, automatic) = stepping.step(backend.KeyPress("2"), labelling)
  assert control_jobs(automatic)
    == [
      job.Control(
        daemon.control,
        job.ChangeRule(job.SetRuleMode("p1", "deps", board.ModeAuto)),
      ),
    ]
}

pub fn the_shipped_loop_sends_a_live_run_only_after_enter_test() {
  let labelling = on_labelling(rule_document(30, "none"))
  let assert Some(daemon) = labelling.view.daemon_host

  // The live key sends nothing, and neither does Escape out of it.
  let #(asking, asked) = stepping.step(backend.KeyPress("L"), labelling)
  assert control_jobs(asked) == []
  let #(_, cancelled) = stepping.step(backend.KeyPress("esc"), asking)
  assert control_jobs(cancelled) == []

  let #(_, confirmed) = stepping.step(backend.KeyPress("enter"), asking)
  assert control_jobs(confirmed)
    == [
      job.Control(
        daemon.control,
        job.ChangeRule(job.RunVerdict("p1", "deps", board.Live)),
      ),
    ]
}

pub fn an_accepted_mode_and_verdict_are_said_in_words_test() {
  let labelling = on_labelling(rule_document(30, "none"))
  let #(sent, _) = stepping.step(backend.KeyPress("1"), labelling)
  let moded =
    deliver(
      sent,
      job.ProjectRuled(
        job.SetRuleMode("p1", "deps", board.ModeObserve),
        Ok(json.Object([])),
      ),
    )
  assert string.contains(painted(moded), "Rule deps is now observe.")

  // A live reply is `state: running`, and is not worded as a finding.
  let #(replaying, _) = stepping.step(backend.KeyPress("r"), labelling)
  let reply =
    json.Object([
      #("state", json.String("running")),
      #("words", json.String("90 trials started.")),
    ])
  let live =
    deliver(
      replaying,
      job.ProjectRuled(job.RunVerdict("p1", "deps", board.Live), Ok(reply)),
    )
  assert string.contains(
    painted(live),
    "Live verdict on deps running. 90 trials started.",
  )

  let replayed =
    deliver(
      replaying,
      job.ProjectRuled(
        job.RunVerdict("p1", "deps", board.Replay),
        Ok(json.Object([#("words", json.String("Replay read 30 labels."))])),
      ),
    )
  assert string.contains(
    painted(replayed),
    "Replay verdict on deps recorded. Replay read 30 labels.",
  )
}

// The daemon's refusal is its own sentence, and the screen shows it as sent.
pub fn a_refusal_shows_the_daemons_sentence_as_sent_test() {
  let labelling = on_labelling(rule_document(30, "none"))
  let #(sent, _) = stepping.step(backend.KeyPress("2"), labelling)
  let sentence = "No verdict is recorded for deps, so it cannot run on auto."
  let refused =
    deliver(
      sent,
      job.ProjectRuled(
        job.SetRuleMode("p1", "deps", board.ModeAuto),
        Error(sentence),
      ),
    )

  assert string.contains(painted(refused), sentence)
  assert !string.contains(painted(refused), "Rule deps is now")

  // The same for a verdict the daemon refuses, such as one under thirty labels.
  let #(running, _) = stepping.step(backend.KeyPress("r"), labelling)
  let few = "A verdict needs 30 labels and deps has 12."
  let short =
    deliver(
      running,
      job.ProjectRuled(job.RunVerdict("p1", "deps", board.Replay), Error(few)),
    )
  assert string.contains(painted(short), few)
}

pub fn a_busy_control_slot_sends_no_verdict_and_says_so_test() {
  let labelling = on_labelling(rule_document(30, "none"))
  let #(busy, _) = stepping.step(backend.KeyPress("r"), labelling)

  // The first request still holds the slot, so a second key sends nothing.
  let #(held, effects) = stepping.step(backend.KeyPress("r"), busy)
  assert control_jobs(effects) == []
  assert string.contains(painted(held), "Try again in a moment.")
}

pub fn a_running_run_is_drawn_with_its_progress_on_the_list_and_the_page_test() {
  let document = rule_document_with(30, "none", [running_run()])
  let list_text = painted(showing(document))
  let page_text = painted(on_labelling(document))

  assert string.contains(
    list_text,
    "live run: 12 of 90 trials, 12 calls, 5100 tokens",
  )
  assert string.contains(
    page_text,
    "live run: 12 of 90 trials, 12 calls, 5100 tokens",
  )
  assert string.contains(page_text, "Mode: 0 off")
}

pub fn each_ended_run_is_drawn_with_the_daemons_words_test() {
  list.each(["passed", "failed", "incomplete"], fn(state) {
    let document = rule_document_with(30, "none", [ended_run(state)])
    let expected =
      "live run "
      <> state
      <> ", 90 calls, 41000 tokens: The daemon says "
      <> state
      <> "."

    assert string.contains(painted(showing(document)), expected)
    assert string.contains(painted(on_labelling(document)), expected)
  })
}

pub fn a_rule_with_no_run_draws_no_run_line_test() {
  assert !string.contains(
    painted(showing(rule_document(30, "none"))),
    "live run",
  )
}

// A run moves no ledger sequence, so the board's revision stays the same while
// it progresses. The screen takes the rules from every read all the same.
pub fn a_progressing_run_shows_though_the_revision_is_unchanged_test() {
  let read = fn(document) {
    let assert Ok(decoded) = board.decode_board(document)
    decoded
  }
  let first =
    project_screen.observe(
      project_screen.new("/w"),
      read(rule_document_with(30, "none", [running_run()])),
      0,
    )
  let later =
    json.Object([
      #("state", json.String("running")),
      #("done", json.Int(24)),
      #("of", json.Int(90)),
      #("calls", json.Int(24)),
      #("tokens", json.Int(9000)),
    ])
  let next =
    project_screen.observe(
      first,
      read(rule_document_with(30, "none", [#("run", later)])),
      10,
    )
  let assert Some(held) = next.board
  let assert [rule] = held.rules

  assert rule.run == Some(board.RunGoing(24, 90, 24, 9000))
  assert !project_screen.same_picture(first, next)
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

// A long message is cut to its first lines and says so. Without a mark, the cut
// reads as the sender's last words. A short message is whole, and a ticket
// opened a moment ago is not "opened now ago".
pub fn a_long_message_is_cut_with_an_ellipsis_and_a_short_one_is_not_test() {
  let sentence = "This sentence goes on and on until it fills a line. "
  let long = string.repeat(sentence, 12)
  let document =
    json.Object([
      #("project", json.String("p1")),
      #("revision", json.Int(2)),
      #("ticket", asking("t-ask", 3, "which?")),
      #("assignments", json.Array([])),
      #(
        "inputs",
        json.Array([
          json.Object([
            #("trigger", json.String("tr-1")),
            #("delivery", json.String("delivered")),
            #("actor", json.String("owner")),
            #("text", json.String(long)),
          ]),
          json.Object([
            #("trigger", json.String("tr-2")),
            #("delivery", json.String("delivered")),
            #("actor", json.String("pat")),
            #("text", json.String("short and whole")),
          ]),
        ]),
      ),
    ])
  let opened = press(showing(body(2, [asking("t-ask", 3, "which?")])), "enter")
  let text = painted(deliver(opened, job.ProjectTicketLoaded(document)))

  assert string.contains(text, "short and whole")
  assert string.contains(text, "  …")
  assert !string.contains(text, "ago ago")
  assert !string.contains(text, "opened now ago")
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

// c closes the ticket the person accepted. It sends one change that names the
// project and the ticket, and the line the screen shows says what happened.
pub fn c_closes_the_ticket_from_the_actions_test() {
  let acting = press(on_ticket(), "tab")
  let assert Some(daemon) = acting.view.daemon_host
  let #(sent, effects) = stepping.step(backend.KeyPress("c"), acting)

  assert control_jobs(effects)
    == [
      job.Control(
        daemon.control,
        job.ChangeProject(job.CloseTicket("p1", "t-ask")),
      ),
    ]
  let settled =
    deliver(sent, job.ProjectChanged(job.CloseTicket("p1", "t-ask"), None))
  assert string.contains(painted(settled), "Ticket closed.")
  let refused =
    deliver(
      sent,
      job.ProjectChanged(job.CloseTicket("p1", "t-ask"), Some("bad_request")),
    )
  assert string.contains(painted(refused), "The daemon refused the close")
}

// The keys follow the daemon's list of actions and not the stage. A ticket in
// review that the daemon lets be retried is retried, which a rule of the
// terminal's own once refused, and a close the daemon does not list sends
// nothing.
pub fn the_keys_follow_the_actions_the_daemon_lists_test() {
  let opened =
    press(showing(body(12, [asking("t-ask", 9, "which database?")])), "enter")
  let acting =
    press(deliver(opened, job.ProjectTicketLoaded(in_review())), "tab")
  let assert Some(daemon) = acting.view.daemon_host

  let #(_, retry) = stepping.step(backend.KeyPress("t"), acting)
  assert control_jobs(retry)
    == [
      job.Control(
        daemon.control,
        job.ChangeProject(job.RetryTicket("p1", "t-ask")),
      ),
    ]
  let #(refused, close) = stepping.step(backend.KeyPress("c"), acting)
  assert control_jobs(close) == []
  assert string.contains(painted(refused), "cannot be closed now")
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

// --- a failed check -----------------------------------------------------------

fn failed_check(output: String) -> json.JsonValue {
  json.Object([
    #("commit", json.String("0123456789abcdef")),
    #("outcome", json.String("failed")),
    #("at_ms", json.Int(1000)),
    #("command", json.String("make check")),
    #("output", json.String(output)),
    #("cause", json.String("environment")),
    #("handling", json.String("person")),
  ])
}

// A ticket whose check failed and which nobody is handling, as the daemon lists
// it, with the actions it offers.
fn checking(output: String) -> json.JsonValue {
  json.Object([
    #("project", json.String("p1")),
    #("revision", json.Int(12)),
    #(
      "ticket",
      json.Object([
        #("id", json.String("t-chk")),
        #("title", json.String("fix the build")),
        #("stage", json.String("person/check")),
        #("session", json.String("s_01")),
        #("opened_ms", json.Int(1000)),
        #("question", json.Null),
        #("check", failed_check(output)),
        #(
          "actions",
          json.Array([
            json.String("close"),
            json.String("recheck"),
            json.String("publish"),
            json.String("stop"),
          ]),
        ),
      ]),
    ),
    #("assignments", json.Array([])),
    #("inputs", json.Array([])),
  ])
}

fn on_checking(output: String) -> tui_model.Model {
  let opened =
    press(
      showing(
        body(12, [
          ticket("t-chk", "person/check", 1000, "fix the build"),
        ]),
      ),
      "enter",
    )
  deliver(opened, job.ProjectTicketLoaded(checking(output)))
}

pub fn a_failed_check_is_a_stage_that_needs_you_and_its_output_is_drawn_test() {
  let board =
    showing(body(12, [ticket("t-chk", "person/check", 1000, "fix the build")]))
  let listed = painted(board)
  assert string.contains(listed, "CHECK FAILED (1)")
  assert !string.contains(listed, "Nothing needs you")

  let page =
    painted(on_checking("exit status 127\nmake: go: command not found"))
  assert string.contains(page, "The check failed at 0123456789ab")
  assert string.contains(page, "the worker was not told")
  assert string.contains(page, "exit status 127")
  assert string.contains(page, "make: go: command not found")
}

// Output is text. A long line wraps instead of running past the edge, and a
// long output keeps its end.
pub fn a_long_output_wraps_and_keeps_its_end_test() {
  let long_line = string.repeat("word ", 60)
  let many =
    int.range(from: 1, to: 41, with: [], run: fn(all, n) { [n, ..all] })
    |> list.reverse
    |> list.map(fn(n) { "line " <> int.to_string(n) })
    |> string.join("\n")
  let page = painted(on_checking(long_line <> "\n" <> many))

  // The last line is there and the first lines are counted, not silently gone.
  assert string.contains(page, "line 40")
  assert string.contains(page, "earlier lines not shown")

  // No drawn row is wider than the frame, so nothing is clipped at the edge.
  let widest =
    string.split(page, "\n")
    |> list.map(string.length)
    |> list.fold(0, int.max)
  assert widest <= 120
}

pub fn the_checks_output_cannot_inject_into_the_terminal_test() {
  let page =
    painted(on_checking("\u{1b}[2J\u{1b}]0;owned\u{7}<b>bold</b> done"))
  assert !string.contains(page, "\u{1b}")
  assert !string.contains(page, "owned\u{7}")
  assert string.contains(page, "<b>bold</b> done")
}

// k, P and x send what the daemon lists, and the publish says what it went past.
pub fn the_keys_recheck_publish_and_stop_follow_the_daemons_list_test() {
  let acting = on_checking("exit status 1")
  let assert Some(daemon) = acting.view.daemon_host

  let #(_, recheck) = stepping.step(backend.KeyPress("k"), acting)
  assert control_jobs(recheck)
    == [
      job.Control(
        daemon.control,
        job.ChangeProject(job.RecheckTicket("p1", "t-chk")),
      ),
    ]
  let #(published, publish) = stepping.step(backend.KeyPress("P"), acting)
  assert control_jobs(publish)
    == [
      job.Control(
        daemon.control,
        job.ChangeProject(job.PublishTicket("p1", "t-chk")),
      ),
    ]
  let settled =
    deliver(
      published,
      job.ProjectChanged(job.PublishTicket("p1", "t-chk"), None),
    )
  assert string.contains(painted(settled), "Published past a failed check.")
  let #(_, stop) = stepping.step(backend.KeyPress("x"), acting)
  assert control_jobs(stop)
    == [
      job.Control(
        daemon.control,
        job.ChangeProject(job.StopTicket("p1", "t-chk")),
      ),
    ]
}

pub fn a_key_the_daemon_does_not_list_sends_nothing_test() {
  let opened =
    press(showing(body(12, [asking("t-ask", 9, "which database?")])), "enter")
  let acting =
    press(deliver(opened, job.ProjectTicketLoaded(in_review())), "tab")
  let #(refused, recheck) = stepping.step(backend.KeyPress("k"), acting)
  assert control_jobs(recheck) == []
  assert string.contains(painted(refused), "no failed check to run again")
  let #(_, publish) = stepping.step(backend.KeyPress("P"), acting)
  assert control_jobs(publish) == []
}

// A refusal is the daemon's sentence, shown as sent.
pub fn a_refused_publish_shows_the_daemons_words_test() {
  let acting = on_checking("exit status 1")
  let #(sent, _) = stepping.step(backend.KeyPress("P"), acting)
  let refused =
    deliver(
      sent,
      job.ProjectChanged(
        job.PublishTicket("p1", "t-chk"),
        Some("publishing is off for this project"),
      ),
    )
  assert string.contains(painted(refused), "publishing is off for this project")
}

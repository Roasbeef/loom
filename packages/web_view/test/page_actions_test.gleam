//// The page's advisor card, its peer reply and its session controls
//// (issue #569, phase B).
////
//// Each control is a command the terminal already runs, so these tests read
//// what reaches the transport (`page_fixture.run`, with every effect
//// performed) and hold it to the frame the same words typed in the composer
//// send. What the page may send is read through Lustre's simulator, which
//// dispatches only to handlers the rendered tree carries, as the browser
//// runtime does, and through the handler table (`page_events_ffi`).
////
//// The fixture answers the reads a first capture starts with real boards,
//// where `operator_page_test` refuses them, since the pending nudges and the
//// goal are what these tests draw.

import core/json
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lane_fixture
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import session_view/connection_event
import session_view/turns
import web_view/component
import web_view/operator_page

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

// A click beneath the agent strip's list, which is the one handler an
// observer's page carries besides "Load older" (the strand focus addendum).
fn is_chip_click(key: String) -> Bool {
  string.starts_with(key, component.strip_path <> "\t")
  && string.ends_with(key, "\nclick")
}

// What the fixture's daemon answers the page's reads with.
type Boards {
  Boards(nudges: Option(json.JsonValue), goal: Option(json.JsonValue))
}

fn nudge_board(pending: List(String), total: Int) -> json.JsonValue {
  json.Object([
    #("strand", json.String("main")),
    #("observed_at_ms", json.Int(42_000)),
    #("pending", json.Array(list.map(pending, json.String))),
    #("total", json.Int(total)),
  ])
}

// A goal board with the status word and the cause the wire pairs with it.
fn goal_board(status: String, reason: json.JsonValue) -> json.JsonValue {
  json.Object([
    #("status", json.String(status)),
    #("reason", reason),
    #("because", json.String("the goal is running")),
    #("objective", json.String("get <b>the</b> branch green")),
    #("token_budget", json.Int(400_000)),
    #("tokens_used", json.Int(51_200)),
    #("cost_used", json.Float(0.42)),
    #("continuations", json.Int(3)),
    #("created_ms", json.Int(1_000_000)),
    #("updated_ms", json.Int(1_060_000)),
    #("reviewer_note", json.Null),
    #("observed_at_ms", json.Int(1_120_000)),
  ])
}

fn snapshot(id: Int, mode: String, board: json.JsonValue) {
  connection_event.Incoming(
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("reply_to", json.Int(id)),
        #("event", json.String("snapshot")),
        #(
          "body",
          json.Object([#("mode", json.String(mode)), #("board", board)]),
        ),
      ]),
    ),
  )
}

// The answer to one read a page wrote: a board where the fixture has one,
// and a refusal for every other read.
fn answer(frame: String, boards: Boards) {
  let id = page_fixture.request_id(frame)
  case
    string.contains(frame, "\"cmd\":\"advisor_pending\""),
    string.contains(frame, "\"cmd\":\"goal_get\""),
    boards
  {
    True, _, Boards(nudges: Some(board), ..) ->
      snapshot(id, "advisor_pending", board)
    _, True, Boards(goal: Some(board), ..) -> snapshot(id, "goal", board)
    _, _, _ -> page_fixture.refusal(id)
  }
}

// Answers every read on the wire, and the reads each answer frees, until the
// wire holds none.
fn answered(model, wire, boards: Boards, rounds: Int) {
  let reads =
    list.filter(page_fixture.sent(wire), fn(frame) {
      !string.contains(frame, "\"cmd\":\"snapshot")
      && !string.contains(frame, "\"cmd\":\"subscribe\"")
    })
  case reads, rounds {
    [], _ | _, 0 -> model
    _, _ ->
      page_fixture.run(model, operator_page.update, [
        operator_page.Observed(
          component.Arrived(list.map(reads, answer(_, boards))),
        ),
      ])
      |> answered(wire, boards, rounds - 1)
  }
}

// A page for `role` whose first reads were answered from `boards`, and the
// wire its frames go to, emptied of everything written so far.
fn page(role: String, boards: Boards) {
  page_with(role, boards, [])
}

// The same page, whose first capture holds `cells`.
fn page_with(role: String, boards: Boards, cells: List(json.JsonValue)) {
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(page_fixture.start()),
      operator_page.update,
      list.flatten([
        [operator_page.Observed(component.Opened(wire))],
        list.map(page_fixture.transfer(role, cells), fn(frame) {
          operator_page.Observed(component.Arrived([frame]))
        }),
        [operator_page.Observed(component.Ticked)],
      ]),
    )
    |> answered(wire, boards, 8)
  let _ = page_fixture.sent(wire)
  #(model, wire)
}

fn nothing() -> Boards {
  Boards(nudges: None, goal: None)
}

// The same page with `main` running an operation.
fn running(role: String, boards: Boards) {
  let #(model, wire) = page(role, boards)
  #(
    component.apply(model, [
      lane_fixture.captured(10, Some(lane_fixture.main_op())),
    ]),
    wire,
  )
}

fn send(model, messages) {
  page_fixture.run(model, operator_page.update, messages)
}

fn drawn(model) -> String {
  element.to_string(operator_page.view(model))
}

// The dock's markup: what is between its tags.
fn dock(html: String) -> String {
  let assert Ok(#(_, from_dock)) =
    string.split_once(html, "<footer class=\"dock\">")
    as "the page draws a dock"
  let assert Ok(#(dock, _)) = string.split_once(from_dock, "</footer>")
    as "the dock is closed"
  dock
}

fn simulation(model) {
  simulate.application(
    init: fn(_) { #(model, effect.none()) },
    update: operator_page.update,
    view: operator_page.view,
  )
  |> simulate.start(Nil)
}

fn in_order(html: String, parts: List(String)) -> Bool {
  case parts {
    [] -> True
    [part, ..rest] ->
      case string.split_once(html, part) {
        Ok(#(_, after)) -> in_order(after, rest)
        Error(Nil) -> False
      }
  }
}

fn commands(wire) -> List(String) {
  page_fixture.commands(page_fixture.sent(wire))
}

// --- advisor nudges ---------------------------------------------------------

fn queued() -> Boards {
  Boards(
    nudges: Some(nudge_board(["rebase <b>first</b>", "run the linter"], 2)),
    goal: None,
  )
}

// A nudge is pending until the primary's next run takes it, and the terminal
// says so beside its composer. The card says the same, with every body, in
// the dock above the composer.
pub fn a_pending_nudge_is_a_card_in_the_operators_dock_test() {
  let #(model, _) = page("operator", queued())
  let html = drawn(model)
  let dock = dock(html)
  assert in_order(dock, [
    "class=\"nudges\"",
    "advisor · 2 pending, not delivered · held for your next prompt to main",
    "rebase &lt;b&gt;first&lt;/b&gt;",
    "run the linter",
    "class=\"composer\"",
  ])
  assert !string.contains(html, "<b>first</b>")
}

// The queue has no accept or dismiss command: the only operation on it is the
// read, and the primary's run start is the drain. So the card carries no
// button, and the operator's page still registers only the clicks and
// submits it did.
pub fn the_nudge_card_has_no_control_test() {
  let #(model, _) = page("operator", queued())
  let assert Ok(#(_, from_card)) =
    string.split_once(drawn(model), "class=\"nudges\"")
    as "the card is drawn"
  let assert Ok(#(card, _)) = string.split_once(from_card, "</section>")
    as "the card is closed"
  assert !string.contains(card, "<button")
  assert !string.contains(card, "<a ")
  let names =
    handlers(operator_page.view(model))
    |> list.map(fn(key) {
      let assert Ok(name) = list.last(string.split(key, "\n"))
        as "a handler key ends in its event name"
      name
    })
    |> list.unique
  assert list.all(names, fn(name) { name == "click" || name == "submit" })
}

// An observer reads the same card, and its page still carries no handler
// but the strip's focus clicks.
pub fn an_observer_sees_the_nudge_card_read_only_test() {
  let #(model, _) = page("observer", queued())
  let html = element.to_string(component.view(model))
  assert in_order(html, [
    "class=\"nudges\"",
    "held for your next prompt to main",
    "rebase &lt;b&gt;first&lt;/b&gt;",
    "class=\"observer-bar\"",
  ])
  assert list.all(handlers(component.view(model)), is_chip_click)
}

pub fn no_pending_nudge_draws_no_card_test() {
  let #(model, _) = page("operator", nothing())
  assert !string.contains(drawn(model), "class=\"nudges\"")
  let #(model, _) =
    page("operator", Boards(nudges: Some(nudge_board([], 0)), goal: None))
  assert !string.contains(drawn(model), "class=\"nudges\"")
}

// The server may have counted more than it sent, and the card does not claim
// to be the whole queue then.
pub fn the_card_counts_what_the_server_did_not_send_test() {
  let #(model, _) =
    page(
      "operator",
      Boards(nudges: Some(nudge_board(["one", "two"], 5)), goal: None),
    )
  let html = drawn(model)
  assert string.contains(html, "advisor · 5 pending, not delivered")
  assert string.contains(html, "+3 more waiting")
}

// --- peer reply -------------------------------------------------------------

fn peer_key(model) -> String {
  let assert Ok(key) =
    list.find_map(component.pieces(model), fn(piece) {
      case piece {
        turns.Peer(key:, ..) -> Ok(key)
        _ -> Error(Nil)
      }
    })
    as "the capture holds a peer message"
  key
}

fn with_peer(role: String) {
  let #(model, wire) = page(role, nothing())
  #(component.apply(model, [lane_fixture.captured(10, None)]), wire)
}

// The terminal has no command that answers a peer: the model answers under
// the owner's link with `peer_send`, at the operator's prompt. So Reply puts
// the start of that prompt in the composer, through the channel a returned
// prompt uses, and sends nothing.
pub fn reply_puts_a_prompt_in_the_composer_and_sends_nothing_test() {
  let #(model, wire) = with_peer("operator")
  let drafts = component.drafts(model)
  let model = send(model, [operator_page.Replying(peer_key(model))])
  assert commands(wire) == []
  assert component.drafts(model) == drafts
  assert component.returns(model) == 1
  assert component.returned(model)
    == [
      component.Returned(
        1,
        "Reply to the peer message from session lint-census, strand main, with peer_send: ",
      ),
    ]
  assert component.notice(model)
    == component.Said("A reply is in the composer. Add your words and send it.")

  // The composer's element reads it from the slot, as escaped text.
  let html = drawn(model)
  assert string.contains(html, "returned=\"1\"")
  assert in_order(html, [
    "slot=\"returned\"",
    "Reply to the peer message from session lint-census, strand main, with peer_send: ",
  ])
}

// A second reply is a second entry, so the element, which takes an entry once
// by its number, puts each in the editor.
pub fn each_reply_is_its_own_entry_test() {
  let #(model, _) = with_peer("operator")
  let key = peer_key(model)
  let model =
    send(model, [operator_page.Replying(key), operator_page.Replying(key)])
  assert component.returns(model) == 2
  assert list.map(component.returned(model), fn(entry) { entry.number })
    == [1, 2]
}

// The button is on the operator's page, at the peer's card, and pressing it
// is the click the socket already admits.
pub fn the_reply_button_is_a_click_on_the_peer_card_test() {
  let #(model, _) = with_peer("operator")
  let html = drawn(model)
  assert in_order(html, [
    "class=\"peer-card\"",
    "R8 census is &lt;14&gt; &amp; rising",
    "class=\"peer-reply\"",
    "Reply to this peer",
  ])
  let clicked =
    simulation(model)
    |> simulate.click(on: query.element(query.class("peer-reply")))
  assert component.returns(simulate.model(clicked)) == 1
}

// A key no piece has, which is a message cut from the window, starts nothing.
pub fn a_reply_to_a_message_that_left_the_page_is_refused_test() {
  let #(model, _) = with_peer("operator")
  let model = send(model, [operator_page.Replying("no-such-key")])
  assert component.returns(model) == 0
  let assert component.Warned(_) = component.notice(model)
    as "the page says no reply was started"
}

pub fn an_observer_has_no_reply_test() {
  let #(model, _) = with_peer("observer")
  let html = element.to_string(component.view(model))
  assert string.contains(html, "class=\"peer-card\"")
  assert !string.contains(html, "peer-reply")
  assert !string.contains(html, "Reply")
}

// --- session controls -------------------------------------------------------

fn pinned(status: String, reason: json.JsonValue) -> Boards {
  Boards(nudges: None, goal: Some(goal_board(status, reason)))
}

// A running goal can be held or cleared, and the row that offers them is
// armed, so a click that was heading for another control cannot land on one.
pub fn a_running_goal_offers_pause_and_clear_test() {
  let #(model, _) = page("operator", pinned("active", json.Null))
  let html = drawn(model)
  assert in_order(dock(html), [
    "class=\"controls\"",
    "class=\"control-goal\"",
    "class=\"control-actions arming\"",
    "goal active",
    "get &lt;b&gt;the&lt;/b&gt; branch green",
    "Pause goal",
    "Clear goal",
    "class=\"composer\"",
  ])
  assert !string.contains(html, "Resume goal")
  assert !string.contains(html, "get <b>the</b>")
}

pub fn a_held_goal_offers_resume_and_clear_test() {
  let #(model, _) = page("operator", pinned("paused", json.String("operator")))
  let html = drawn(model)
  assert string.contains(html, "Resume goal")
  assert string.contains(html, "Clear goal")
  assert !string.contains(html, "Pause goal")

  let #(model, _) =
    page("operator", pinned("budget_limited", json.String("token_budget")))
  assert string.contains(drawn(model), "Resume goal")

  let #(model, _) = page("operator", pinned("complete", json.Null))
  let html = drawn(model)
  assert string.contains(html, "Clear goal")
  assert !string.contains(html, "Resume goal")
  assert !string.contains(html, "Pause goal")
}

pub fn the_goal_buttons_send_the_goal_commands_test() {
  let #(model, wire) = page("operator", pinned("active", json.Null))
  let drafts = component.drafts(model)

  let model = send(model, [operator_page.Controlled(component.PauseGoal)])
  let assert [pause] = commands(wire) as "one press is one command"
  assert string.contains(pause, "\"cmd\":\"goal_pause\"")
  assert component.drafts(model) == drafts

  let #(model, wire) =
    page("operator", pinned("paused", json.String("operator")))
  let model = send(model, [operator_page.Controlled(component.ResumeGoal)])
  let assert [resume] = commands(wire) as "one press is one command"
  assert string.contains(resume, "\"cmd\":\"goal_resume\"")
  assert component.drafts(model) == drafts

  let #(model, wire) = page("operator", pinned("active", json.Null))
  let model = send(model, [operator_page.Controlled(component.ClearGoal)])
  let assert [clear] = commands(wire) as "one press is one command"
  assert string.contains(clear, "\"cmd\":\"goal_clear\"")
  assert component.drafts(model) == drafts
}

// The button is a real one on the page, and pressing it is a click.
pub fn pressing_pause_in_the_page_sends_the_command_test() {
  let #(model, _) = page("operator", pinned("active", json.Null))
  let clicked =
    simulation(model)
    |> simulate.click(on: query.element(query.class("control-pause")))

  // The simulator drops the effect that writes the frame, so what shows is
  // the step's own record that the command went out.
  assert component.notice(simulate.model(clicked))
    == component.Said("goal_pause sent")
}

// Stop is always drawn, so it never moves its neighbours, and is disabled
// while nothing runs. It names what it does and what it leaves alone.
pub fn stop_is_disabled_while_the_strand_is_idle_test() {
  let #(idle, _) = page("operator", nothing())
  let html = drawn(idle)
  assert in_order(html, ["class=\"control-stop\"", "disabled", "Stop main"])
  assert string.contains(html, "The session stays open.")

  let #(busy, _) = running("operator", nothing())
  let assert Ok(#(_, from_stop)) =
    string.split_once(drawn(busy), "class=\"control-stop\"")
    as "the button is drawn"
  let assert Ok(#(stop, _)) = string.split_once(from_stop, "Stop main")
    as "the button is labelled"
  assert !string.contains(stop, "disabled")
}

// Stop is Escape: it aborts the strand's running operation and holds the
// input queued behind it, and it is the one control the strand's phase
// decides.
pub fn stop_aborts_the_running_operation_test() {
  let #(model, wire) = running("operator", nothing())
  let drafts = component.drafts(model)
  let model = send(model, [operator_page.Controlled(component.Stop)])
  let assert [abort] = commands(wire) as "one press is one command"
  assert string.contains(abort, "\"cmd\":\"abort\"")
  assert string.contains(abort, "\"strand\":\"main\"")
  assert component.drafts(model) == drafts
  assert component.notice(model) == component.Said("abort sent")

  // A second press while the stop is pending sends nothing.
  let model = send(model, [operator_page.Controlled(component.Stop)])
  assert commands(wire) == []
  assert component.notice(model)
    == component.Said("interrupt already requested")
}

pub fn stop_on_an_idle_strand_sends_nothing_test() {
  let #(model, wire) = page("operator", nothing())
  let model = send(model, [operator_page.Controlled(component.Stop)])
  assert commands(wire) == []
  assert component.notice(model) == component.Said("nothing is running")
}

// The fork form's name is the command's argument, as `/fork <name>` typed in
// the composer would be, and the form is replaced once the frame is out.
pub fn the_fork_form_sends_a_fork_test() {
  let #(model, wire) = page("operator", nothing())
  let drafts = component.drafts(model)
  let model =
    send(model, [operator_page.Controlled(component.Fork("try-a-cache"))])
  let assert [fork] = commands(wire) as "one form is one command"
  assert string.contains(fork, "\"cmd\":\"fork\"")
  assert string.contains(fork, "\"name\":\"try-a-cache\"")
  assert string.contains(fork, "\"strand\":\"main\"")
  assert component.drafts(model) == drafts as "the composer's draft is left"
  assert component.sent_forms(model) == 1
}

pub fn the_fork_form_is_a_submit_the_page_carries_test() {
  let #(model, _) = page("operator", nothing())
  let submitted =
    simulation(model)
    |> simulate.submit(on: query.element(query.class("control-fork")), fields: [
      #("text", "try-a-cache"),
    ])
  assert component.sent_forms(simulate.model(submitted)) == 1
  assert component.notice(simulate.model(submitted))
    == component.Said("fork sent")

  let refused =
    simulation(model)
    |> simulate.submit(on: query.element(query.class("control-fork")), fields: [
      #("text", "a"),
      #("delivery", "steer"),
    ])
  assert component.sent_forms(simulate.model(refused)) == 0
  let assert Ok(simulate.Problem(..)) = list.last(simulate.history(refused))
    as "a form with a field it does not offer refuses the event"
}

// A lane waiting for a read's reply admits a mutation and queues it, so the
// frame leaves only when the reply lands. The form is cleared when the lane
// accepts the command, not when the frame leaves: a form that kept its text
// here would invite a second fork. The frame goes out once, after the reply.
pub fn a_form_sent_while_a_read_is_out_is_cleared_and_goes_out_after_it_test() {
  let wire = process.new_subject()
  let model =
    page_fixture.run(
      component.new(page_fixture.start()),
      operator_page.update,
      list.flatten([
        [operator_page.Observed(component.Opened(wire))],
        list.map(page_fixture.transfer("operator", []), fn(frame) {
          operator_page.Observed(component.Arrived([frame]))
        }),
        [operator_page.Observed(component.Ticked)],
      ]),
    )
  let assert Ok(read) =
    list.find(page_fixture.sent(wire), fn(frame) {
      !string.contains(frame, "\"cmd\":\"snapshot")
      && !string.contains(frame, "\"cmd\":\"subscribe\"")
    })
    as "a first capture starts a read, which is now awaiting its reply"

  let model =
    send(model, [operator_page.Controlled(component.Fork("try-a-cache"))])
  assert component.sent_forms(model) == 1 as "the lane accepted the fork"
  assert forks(page_fixture.sent(wire)) == 0 as "the frame waits for the read"
  let assert component.Said(waiting) = component.notice(model)
    as "the step says the command is waiting"
  assert string.contains(waiting, "Waiting to send")

  let model =
    send(model, [
      operator_page.Observed(
        component.Arrived([page_fixture.refusal(page_fixture.request_id(read))]),
      ),
    ])
  assert component.sent_forms(model) == 1
  assert forks(page_fixture.sent(wire)) == 1 as "the fork goes out once"
}

fn forks(frames: List(String)) -> Int {
  list.length(
    list.filter(frames, fn(frame) { string.contains(frame, "\"cmd\":\"fork\"") }),
  )
}

// A stop the lane refuses records no interrupt, so the next press says why
// again and does not claim a stop is already pending.
pub fn a_refused_stop_leaves_no_interrupt_behind_test() {
  let #(model, wire) = running("observer", nothing())
  let model = send(model, [operator_page.Controlled(component.Stop)])
  let assert component.Said(first) = component.notice(model)
    as "the step words the refusal"
  assert string.contains(first, "read-only")
  let model = send(model, [operator_page.Controlled(component.Stop)])
  let assert component.Said(second) = component.notice(model)
    as "the step words the refusal again"
  assert string.contains(second, "read-only")
  assert !string.contains(second, "already requested")
  assert commands(wire) == []
}

// A fork with no name is the command's own complaint, nothing is sent, and
// the form keeps what was typed.
pub fn a_fork_without_a_name_is_refused_and_keeps_the_form_test() {
  let #(model, wire) = page("operator", nothing())
  let model = send(model, [operator_page.Controlled(component.Fork("  "))])
  assert commands(wire) == []
  assert component.notice(model) == component.Said("/fork needs an argument")
  assert component.sent_forms(model) == 0
}

// A fork the attachment cannot take, here an observer's, is refused by the
// step with its reason and keeps the form.
pub fn a_fork_the_attachment_refuses_keeps_the_form_test() {
  let #(model, wire) = page("observer", nothing())
  let model = send(model, [operator_page.Controlled(component.Fork("x"))])
  assert commands(wire) == []
  assert component.sent_forms(model) == 0
  let assert component.Said(text) = component.notice(model)
    as "the step words the refusal"
  assert string.contains(text, "read-only")
}

pub fn the_goal_form_pins_a_goal_test() {
  let #(model, wire) = page("operator", nothing())
  let drafts = component.drafts(model)
  let model =
    send(model, [
      operator_page.Controlled(component.PinGoal(
        "--budget 100000 get the branch green",
      )),
    ])
  let assert [set] = commands(wire) as "one form is one command"
  assert string.contains(set, "\"cmd\":\"goal_set\"")
  assert string.contains(set, "\"objective\":\"get the branch green\"")
  assert string.contains(set, "\"token_budget\":100000")
  assert component.drafts(model) == drafts
  assert component.sent_forms(model) == 1
}

// A box for an objective never runs another goal command. Words that name
// one are refused with a notice, and the command's own complaints about a
// budget pass through.
pub fn the_goal_form_never_runs_another_goal_command_test() {
  let #(model, wire) = page("operator", pinned("active", json.Null))
  let model =
    send(
      model,
      list.map(["clear", "pause", "resume", "check make check", ""], fn(text) {
        operator_page.Controlled(component.PinGoal(text))
      }),
    )
  assert commands(wire) == []
  let assert component.Warned(text) = component.notice(model)
    as "the page refuses"
  assert string.contains(text, "objective")
  assert component.sent_forms(model) == 0

  let model =
    send(model, [
      operator_page.Controlled(component.PinGoal("--budget abc fix it")),
    ])
  assert commands(wire) == []
  let assert component.Said(complaint) = component.notice(model)
    as "the command's own complaint"
  assert string.contains(complaint, "abc")
}

pub fn a_form_over_the_limit_is_refused_test() {
  let #(model, wire) = page("operator", nothing())
  let model =
    send(model, [
      operator_page.Controlled(
        component.Fork(string.repeat("x", component.prompt_limit + 1)),
      ),
    ])
  assert commands(wire) == []
  let assert component.Warned(_) = component.notice(model)
    as "the page refuses it as it refuses a long draft"
}

pub fn a_control_form_refuses_any_field_it_does_not_offer_test() {
  assert operator_page.control_text([#("text", "x")]) == Ok("x")
  list.each(
    [
      [],
      [#("text", "a"), #("text", "b")],
      [#("text", "a"), #("delivery", "steer")],
      [#("draft", "a")],
    ],
    fn(fields) {
      let assert Error(Nil) = operator_page.control_text(fields)
        as "a forged control field refuses the event"
    },
  )
}

// The engine's own role check is under the component type and the gateway:
// an observer's attachment sends nothing whatever message reaches it.
pub fn an_observer_attachment_sends_no_control_test() {
  let #(model, wire) = running("observer", pinned("active", json.Null))
  let _ =
    send(model, [
      operator_page.Controlled(component.Stop),
      operator_page.Controlled(component.PauseGoal),
      operator_page.Controlled(component.ResumeGoal),
      operator_page.Controlled(component.ClearGoal),
      operator_page.Controlled(component.Fork("x")),
      operator_page.Controlled(component.PinGoal("do it")),
    ])
  assert commands(wire) == []
}

// An observer's page has none of it: no bar, no form, no button, and still
// no handler but the strip's focus clicks.
pub fn an_observer_page_draws_no_controls_test() {
  let #(model, _) = page("observer", pinned("active", json.Null))
  let html = element.to_string(component.view(model))
  assert !string.contains(html, "class=\"controls\"")
  assert !string.contains(html, "control-")
  assert list.all(handlers(component.view(model)), is_chip_click)
}

// The bar sits above the approvals and the composer in the dock, and the
// approvals stay directly above the composer.
pub fn the_bar_is_in_the_dock_above_the_approvals_test() {
  let #(model, _) =
    page_with("operator", nothing(), [
      page_fixture.escalation("esc-1", 7, "fs_write", "write the file"),
    ])
  assert in_order(dock(drawn(model)), [
    "class=\"controls\"",
    "class=\"approvals\"",
    "class=\"composer\"",
  ])
}

// The controls add no event the socket did not already admit.
pub fn the_controls_register_only_clicks_and_submits_test() {
  let #(model, _) = with_peer("operator")
  let names =
    handlers(operator_page.view(model))
    |> list.map(fn(key) {
      let assert Ok(name) = list.last(string.split(key, "\n"))
        as "a handler key ends in its event name"
      name
    })
    |> list.unique
  assert list.sort(names, string.compare) == ["click", "submit"]
}

//// The home page's attention inbox as a page draws it (`web_view/view/inbox`,
//// wired in `web_view/home`).
////
//// These tests pin what the daemon's reports become on screen: the groups and
//// their counts, the headline's words, the selected thread's last message as
//// escaped text under a label that says whose words it is, an approval that is
//// named and never drawn, and the one way to open a session. They also pin the
//// socket's side of the bargain: every handler the inbox registers is a click
//// beneath `home.table_path`, so no new admission is needed.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import lustre/vdom/vnode
import session_view/operator
import web_view/home
import web_view/sessions.{
  type Entry, type Report, Entry, Glance, Live, Report, Saved,
}
import web_view/signins
import web_view/thread_send
import web_view/view/inbox

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

fn entry(id: String, name: String, residency: sessions.Residency) -> Entry {
  Entry(
    id:,
    name:,
    workspace: "/src/loom",
    created_at: 100_000,
    residency:,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

fn listing() -> List(Entry) {
  [
    entry("A", "web ui", Live),
    entry("B", "vetting lint", Live),
    entry("C", "docs sweep", Live),
    entry("D", "hex release", Saved),
  ]
}

// `B` has an approval pending, `A` finished a run and said something, `C`
// works with a strand reporting, and `D` is saved and so has no report.
fn reports() -> List(#(String, Report)) {
  [
    #(
      "B",
      Report(sessions.NeedsYou, Some("Approve the push?\nIt is ready."), []),
    ),
    #(
      "A",
      Report(sessions.Idle, Some("<script>alert(1)</script> finished"), [
        Glance("s1", "Lint", "all green"),
      ]),
    ),
    #(
      "C",
      Report(sessions.Working, None, [
        Glance("s2", "", "reading the spec"),
        Glance("s3", "Tests", "waiting on CI"),
      ]),
    ),
  ]
}

fn start(
  ceiling: home.Ceiling,
  answered: List(#(String, Report)),
) -> home.Start {
  home.Start(
    name: "Alice",
    ceiling:,
    refresh_ms: 5,
    sessions: fn(deliver) { deliver(home.Listed(listing())) },
    open: fn(_) { sessions.Declined(sessions.NotHeld) },
    resume: fn(_, _) { Nil },
    now: fn() { 7_400_000 },
    activity: fn(_, deliver) { deliver(answered) },
    rename: None,
    manage: None,
    thread_send: None,
    create: None,
    folders: None,
    elsewhere: None,
    projects: None,
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

// Applies a message and the messages its effects dispatch, as the runtime does.
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

fn opened(start: home.Start) -> home.Model {
  run(home.new(start), home.TimerReady(process.new_subject()))
}

fn drawn(model: home.Model) -> String {
  element.to_string(home.view(model))
}

// The page lands on the inbox: the groups in their order with their counts, the
// headline saying what it read, and no age anywhere.
pub fn the_inbox_groups_the_threads_and_counts_what_it_read_test() {
  let html = drawn(opened(start(home.OperatorCeiling, reports())))

  assert string.contains(html, "<h1>Inbox</h1>")
  assert string.contains(
    html,
    "1 needs you · in 3 running sessions; saved sessions not checked",
  )
  assert string.contains(html, "Needs you<span class=\"inbox-count\">1</span>")
  assert string.contains(html, "Waiting<span class=\"inbox-count\">1</span>")
  assert string.contains(html, "Updates<span class=\"inbox-count\">1</span>")

  let needs = index_of(html, "Needs you<span")
  let waiting = index_of(html, "Waiting<span")
  let updates = index_of(html, "Updates<span")
  assert needs < waiting && waiting < updates

  // A thread's row says its kind, its session and one line of what was said.
  assert string.contains(html, "Approval · vetting lint")
  assert string.contains(html, "Approve the push?")
  assert string.contains(html, "Update · docs sweep")
  assert string.contains(html, "reading the spec")
  assert !string.contains(html, "ago")
}

// The default selection is the first thread of the first group, and its reading
// pane carries the labels that say whose words are on screen.
pub fn the_reading_pane_shows_the_first_thread_and_labels_its_words_test() {
  let html = drawn(opened(start(home.OperatorCeiling, reports())))

  assert string.contains(html, "inbox-reading-default")
  assert string.contains(html, "Approval · vetting lint · /src/loom</p>")
  assert string.contains(
    html,
    "The agent&#39;s last finished turn, untrusted text",
  )
  assert string.contains(html, "It is ready.")
  assert string.contains(html, "Open session ›")
}

// A press on a thread selects it, and its message is drawn as escaped text, so
// model text never becomes markup.
pub fn a_press_selects_a_thread_and_its_words_are_text_test() {
  let model = opened(start(home.OperatorCeiling, reports()))
  let html = drawn(run(model, home.InboxOpened("A")))

  assert string.contains(html, "inbox-reading-pressed")
  assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt; finished")
  assert !string.contains(html, "<script>")
  assert string.contains(html, "What its strands are doing")
  assert string.contains(html, "Lint: all green")
}

// A glance with no title is named by its strand.
pub fn a_glance_without_a_title_is_named_by_its_strand_test() {
  let model = opened(start(home.OperatorCeiling, reports()))
  let html = drawn(run(model, home.InboxOpened("C")))

  assert string.contains(html, "s2: reading the spec")
  assert string.contains(html, "Tests: waiting on CI")
}

// An approval is named and the owner is sent to the session's own page. Nothing
// of the approval is drawn on Home, and no deciding control is.
pub fn an_approval_is_named_and_never_decided_here_test() {
  let html = drawn(opened(start(home.OperatorCeiling, reports())))

  assert string.contains(html, "An approval is pending.")
  assert string.contains(html, "Decide on the session&#39;s page ›")

  assert !string.contains(html, "Allow")
  assert !string.contains(html, "Deny")
  assert !string.contains(html, "<textarea")
  assert !string.contains(html, "<form")
  assert !string.contains(html, "<input")
}

// A failed run is named as failed, and nothing is offered but the session.
pub fn a_failed_run_is_named_test() {
  let failed = [#("A", Report(sessions.Failed, Some("It broke."), []))]
  let html = drawn(opened(start(home.OperatorCeiling, failed)))

  assert string.contains(html, "Failed · web ui")
  assert string.contains(html, "Its last run failed, and nothing is running.")
  assert !string.contains(html, "An approval is pending.")
}

// The quiet sessions are one line of names and are not rows.
pub fn quiet_sessions_fold_to_one_line_test() {
  let quiet = [
    #("A", Report(sessions.Idle, None, [])),
    #("B", Report(sessions.Idle, None, [])),
    #("C", Report(sessions.Working, None, [])),
  ]
  let html = drawn(opened(start(home.OperatorCeiling, quiet)))

  assert string.contains(html, "Quiet: vetting lint, web ui")
  assert !string.contains(html, "Quiet · web ui")
  assert !string.contains(html, "Quiet<span")
}

// With nothing waiting or running the page keeps the list, and an owner
// with no capability to create sees the old page.
pub fn nothing_to_read_leaves_the_list_test() {
  let quiet = [#("A", Report(sessions.Idle, None, []))]
  let html = drawn(opened(start(home.OperatorCeiling, quiet)))

  assert !string.contains(html, "<h1>Inbox</h1>")
  assert string.contains(html, "<h1>Sessions</h1>")
}

// An observer's page lands on the same list and may read it. Choosing the full
// list shows the older page.
pub fn an_observers_page_lands_on_the_inbox_and_can_leave_it_test() {
  let model = opened(start(home.ObserverCeiling, reports()))
  assert string.contains(drawn(model), "<h1>Inbox</h1>")

  let listed = run(model, home.ShowingList)
  assert !string.contains(drawn(listed), "<h1>Inbox</h1>")
  assert string.contains(drawn(listed), "<h1>Sessions</h1>")

  // A later read does not take the person back to the inbox.
  let read = run(listed, home.Observed(reports()))
  assert string.contains(drawn(read), "<h1>Sessions</h1>")
}

// The handlers are clicks beneath the table's region, which the socket admits
// already, and a session the page does not list cannot be selected into view.
pub fn every_handler_is_a_click_beneath_the_table_test() {
  let model = opened(start(home.OperatorCeiling, reports()))
  let keys =
    handlers(home.view(model))
    |> list.filter(string.starts_with(_, home.table_path <> "\t"))

  assert keys != []
  assert list.all(keys, string.ends_with(_, "\nclick"))

  let stale = run(model, home.InboxOpened("gone"))
  assert string.contains(drawn(stale), "inbox-reading-default")
}

fn index_of(html: String, needle: String) -> Int {
  case string.split_once(html, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(Nil) -> -1
  }
}

// --- the message field (protocol-change/118) --------------------------------

type Sent =
  #(String, String, operator.Delivery)

// A start whose page holds the capability to send. The capability records each
// message it is asked to send and never answers, so a test decides what the
// daemon said by dispatching the answer itself.
fn sending(
  asked: Subject(Sent),
  answered: List(#(String, Report)),
) -> home.Start {
  home.Start(
    ..start(home.OperatorCeiling, answered),
    thread_send: Some(fn(session, text, delivery, _deliver) {
      process.send(asked, #(session, text, delivery))
    }),
  )
}

fn received(asked: Subject(Sent)) -> List(Sent) {
  case process.receive(asked, 0) {
    Ok(sent) -> [sent, ..received(asked)]
    Error(Nil) -> []
  }
}

// Every keyed node's key in a rendered tree, so a test can say that a box was
// replaced (its key changed) and so drawn empty, as the browser would draw it.
fn keys(node: vnode.Element(message)) -> List(String) {
  case node {
    vnode.Element(key:, children:, ..) | vnode.Fragment(key:, children:, ..) ->
      list.append([key], list.flat_map(children, keys))
    vnode.Map(child:, ..) -> keys(child)
    vnode.Memo(view:, ..) -> keys(view())
    vnode.Text(..) | vnode.UnsafeInnerHtml(..) -> []
  }
}

fn box_keys(model: home.Model) -> List(String) {
  keys(home.view(model))
  |> list.filter(string.contains(_, "send-"))
}

// Each state of a thread offers the buttons that fit it: an approval a Queue
// Send alone with the words that say a message starts a turn and decides nothing
// (the approval parks and detaches, so the strand is idle), an idle session one
// Send, a working one a Queue and a Steer.
pub fn each_state_offers_its_own_buttons_test() {
  let model = opened(sending(process.new_subject(), reports()))

  // The default thread is the approval's.
  let approval = drawn(model)
  assert string.contains(
    approval,
    "This session is waiting on an approval. A message starts a new turn now; it does not decide the approval.",
  )
  assert string.contains(approval, ">Send</button>")
  assert !string.contains(approval, ">Steer</button>")
  assert !string.contains(approval, ">Queue</button>")

  let idle = drawn(run(model, home.InboxOpened("A")))
  assert string.contains(idle, ">Send</button>")
  assert !string.contains(idle, ">Queue</button>")
  assert !string.contains(idle, ">Steer</button>")
  assert !string.contains(idle, "waiting on an approval")

  let working = drawn(run(model, home.InboxOpened("C")))
  assert string.contains(working, ">Queue</button>")
  assert string.contains(working, ">Steer</button>")
  assert !string.contains(working, ">Send</button>")
}

// A button names its delivery, and the box carries a fixed label, so no session
// text reaches an attribute.
pub fn the_buttons_name_their_delivery_test() {
  let model = opened(sending(process.new_subject(), reports()))
  let working = drawn(run(model, home.InboxOpened("C")))

  assert string.contains(working, "name=\"delivery\"")
  assert string.contains(working, "value=\"prompt\"")
  assert string.contains(working, "value=\"steer\"")
  assert string.contains(working, "aria-label=\"Message this session\"")
  assert string.contains(working, "name=\"draft\"")
}

// A page that holds no capability draws no field: a member's home, an
// observer's, and an owner's page whose capability was withheld.
pub fn a_page_without_the_capability_draws_no_field_test() {
  list.each([home.OperatorCeiling, home.ObserverCeiling], fn(ceiling) {
    let html = drawn(opened(start(ceiling, reports())))
    assert !string.contains(html, "<textarea")
    assert !string.contains(html, "<form")
    assert !string.contains(html, "Not sent")
  })

  // A forged message to a page with no capability sends nothing and changes
  // nothing.
  let model = opened(start(home.OperatorCeiling, reports()))
  let forged = run(model, home.ThreadSubmitted("A", "hello", operator.Prompt))
  assert drawn(forged) == drawn(model)
}

// The outbox says nothing before a send, "Sending…" while the daemon works, and the
// fixed words of each answer after, for the thread the message went to.
pub fn the_outbox_words_each_state_test() {
  let asked = process.new_subject()
  let model = opened(sending(asked, reports()))
  let model = run(model, home.InboxOpened("A"))
  assert !string.contains(drawn(model), "Not sent")

  let model = run(model, home.ThreadSubmitted("A", "go on", operator.Prompt))
  assert received(asked) == [#("A", "go on", operator.Prompt)]
  assert string.contains(drawn(model), "Sending…")

  let said = fn(answer) { drawn(run(model, home.ThreadAnswered("A", answer))) }
  assert string.contains(
    said(thread_send.Delivered(thread_send.Admitted)),
    "Delivered to web ui · admitted",
  )
  assert string.contains(
    said(thread_send.Delivered(thread_send.Queued)),
    "Delivered to web ui · queued",
  )
  assert string.contains(
    said(thread_send.Refused(thread_send.NotHeld)),
    "Not sent: this home no longer holds that session",
  )
  assert string.contains(
    said(thread_send.Refused(thread_send.NotResident)),
    "Not sent: the session is not running",
  )
  assert string.contains(
    said(thread_send.Refused(thread_send.NotAccepted("<b>raw</b>"))),
    "Not sent: the session refused it",
  )
  assert !string.contains(
    said(thread_send.Refused(thread_send.NotAccepted("<b>raw</b>"))),
    "raw",
  )
  assert string.contains(
    said(thread_send.Refused(thread_send.QueueFull)),
    "Not sent: its queue is full",
  )

  assert string.contains(
    said(thread_send.Refused(thread_send.Unanswered)),
    "No answer in time; it may have arrived. Check the session before sending again.",
  )

  // Another thread says nothing while this one's is out.
  let other = drawn(run(model, home.InboxOpened("C")))
  assert !string.contains(other, "Not sent")
  assert !string.contains(other, "Sending…")
}

// A delivered message leaves an empty box (the box is a new element, so the
// browser draws it empty), and a refused one keeps the draft (the box is the
// same element).
pub fn a_delivered_message_clears_the_box_and_a_refusal_keeps_it_test() {
  let asked = process.new_subject()
  let model = run(opened(sending(asked, reports())), home.InboxOpened("A"))
  let before = box_keys(model)
  assert before != []

  let sent = run(model, home.ThreadSubmitted("A", "go on", operator.Prompt))
  assert box_keys(sent) == before

  let refused =
    run(
      sent,
      home.ThreadAnswered("A", thread_send.Refused(thread_send.QueueFull)),
    )
  assert box_keys(refused) == before

  let delivered =
    run(
      sent,
      home.ThreadAnswered("A", thread_send.Delivered(thread_send.Queued)),
    )
  assert box_keys(delivered) != before
}

// An empty or whitespace-only draft, one over the bound, a session the page does
// not report and a second send while one is out each ask the daemon nothing. A
// delivered send, and a refused one, let the next go.
pub fn only_a_sendable_draft_for_a_known_session_is_asked_test() {
  let asked = process.new_subject()
  let model = run(opened(sending(asked, reports())), home.InboxOpened("A"))
  let submit = fn(model, session, text) {
    run(model, home.ThreadSubmitted(session, text, operator.Prompt))
  }

  let _ = submit(model, "A", "")
  let _ = submit(model, "A", "  \n ")
  let _ = submit(model, "A", string.repeat("x", 16_385))
  let _ = submit(model, "gone", "hello")
  assert received(asked) == []

  let out = submit(model, "A", "one")
  let _ = submit(out, "A", "two")
  let _ = submit(out, "C", "three")
  assert received(asked) == [#("A", "one", operator.Prompt)]

  let refused =
    run(
      out,
      home.ThreadAnswered("A", thread_send.Refused(thread_send.QueueFull)),
    )
  let _ = submit(refused, "A", "four")
  assert received(asked) == [#("A", "four", operator.Prompt)]
}

// A steer reaches the daemon as a steer, and the thread's own text is what is
// sent.
pub fn a_steer_is_sent_as_a_steer_test() {
  let asked = process.new_subject()
  let model = run(opened(sending(asked, reports())), home.InboxOpened("C"))
  let _ = run(model, home.ThreadSubmitted("C", "stop that", operator.Steer))

  assert received(asked) == [#("C", "stop that", operator.Steer)]
}

// The form carries a draft and at most one delivery, and nothing else: a field
// the form does not have, a second draft or an unknown delivery refuses the
// event.
pub fn the_form_is_read_back_by_its_own_shape_test() {
  assert inbox.submission([#("draft", "hi")]) == Ok(#("hi", operator.Prompt))
  assert inbox.submission([#("draft", "hi"), #("delivery", "prompt")])
    == Ok(#("hi", operator.Prompt))
  assert inbox.submission([#("draft", "hi"), #("delivery", "steer")])
    == Ok(#("hi", operator.Steer))

  assert inbox.submission([]) == Error(Nil)
  assert inbox.submission([#("delivery", "prompt")]) == Error(Nil)
  assert inbox.submission([#("draft", "a"), #("draft", "b")]) == Error(Nil)
  assert inbox.submission([#("draft", "a"), #("delivery", "follow_up")])
    == Error(Nil)
  assert inbox.submission([
      #("draft", "a"),
      #("delivery", "steer"),
      #("delivery", "prompt"),
    ])
    == Error(Nil)
  assert inbox.submission([#("draft", "a"), #("session", "B")]) == Error(Nil)
}

// The form's submit is beneath the table's region, which the owner's socket
// admits for a submit and the member's refuses (`home_owner_accepts`), and every
// other handler the inbox draws is a click beneath it.
pub fn the_forms_handlers_are_beneath_the_table_test() {
  let model = opened(sending(process.new_subject(), reports()))
  let keys =
    handlers(home.view(model))
    |> list.filter(string.starts_with(_, home.table_path <> "\t"))
  let submits = list.filter(keys, string.ends_with(_, "\nsubmit"))

  assert submits != []
  assert list.all(keys, fn(key) {
    string.ends_with(key, "\nclick") || string.ends_with(key, "\nsubmit")
  })

  // And nothing the page registers is a submit outside the table, but the
  // account panel's own forms.
  let outside =
    handlers(home.view(model))
    |> list.filter(fn(key) {
      string.ends_with(key, "\nsubmit")
      && !string.starts_with(key, home.table_path <> "\t")
    })
  assert list.all(outside, fn(key) {
    string.starts_with(key, home.signins_path <> "\t")
  })
}

// --- the way back to the inbox ----------------------------------------------

fn creating() -> home.Start {
  home.Start(
    ..start(home.OperatorCeiling, reports()),
    create: Some(fn(_, _, _, _, _, _, _) { Nil }),
  )
}

// Once the person has chosen the list or the composer, an "Inbox" control
// returns to the centre the page lands on. A page that is showing the inbox
// draws none.
pub fn the_list_and_the_composer_lead_back_to_the_inbox_test() {
  let model = opened(creating())
  let landed = drawn(model)
  assert string.contains(landed, "<h1>Inbox</h1>")
  assert !string.contains(landed, "‹ Inbox")
  assert !string.contains(landed, "Back to the inbox")

  let listed = run(model, home.ShowingList)
  assert string.contains(drawn(listed), "‹ Inbox")
  assert !string.contains(drawn(listed), "<h1>Inbox</h1>")

  let composing = run(model, home.ShowingNew)
  assert string.contains(drawn(composing), "Back to the inbox")

  // The control returns to the inbox from either, and the selection kept.
  let pressed = run(model, home.InboxOpened("C"))
  let back = run(run(pressed, home.ShowingList), home.ShowingInbox)
  assert string.contains(drawn(back), "<h1>Inbox</h1>")
  assert string.contains(drawn(back), "Update · docs sweep")
  let back = run(run(pressed, home.ShowingNew), home.ShowingInbox)
  assert string.contains(drawn(back), "<h1>Inbox</h1>")
}

// A page that would land on the composer or the list, because every running
// session is quiet or none runs, has no inbox to return to and draws no
// control.
pub fn a_page_with_no_inbox_to_return_to_draws_no_control_test() {
  let quiet = [#("A", Report(sessions.Idle, None, []))]
  let model =
    opened(
      home.Start(
        ..start(home.OperatorCeiling, quiet),
        create: Some(fn(_, _, _, _, _, _, _) { Nil }),
      ),
    )

  list.each([run(model, home.ShowingList), run(model, home.ShowingNew)], fn(m) {
    assert !string.contains(drawn(m), "‹ Inbox")
    assert !string.contains(drawn(m), "Back to the inbox")
  })
}

// The control is a click beneath the table's region, which every home's socket
// admits, so it needs no new admission.
pub fn the_return_control_is_a_click_beneath_the_table_test() {
  let listed = run(opened(creating()), home.ShowingList)
  let keys =
    handlers(home.view(listed))
    |> list.filter(string.starts_with(_, home.table_path <> "\t"))

  assert keys != []
  assert list.all(keys, fn(key) {
    string.ends_with(key, "\nclick") || string.ends_with(key, "\nsubmit")
  })
  assert string.contains(drawn(listed), "home-inbox")
}

// --- a refresh does not move what the person is using -----------------------

// The first read decides where the page lands. A page that landed on the
// composer, because nothing waited, keeps it when a later read finds something
// that does: replacing the composer would lose what the person was typing. The
// "Inbox" control is offered instead.
pub fn a_later_read_does_not_replace_the_composer_test() {
  let quiet = [#("A", Report(sessions.Idle, None, []))]
  let model =
    opened(
      home.Start(
        ..start(home.OperatorCeiling, quiet),
        create: Some(fn(_, _, _, _, _, _, _) { Nil }),
      ),
    )
  assert !string.contains(drawn(model), "<h1>Inbox</h1>")
  assert !string.contains(drawn(model), "Back to the inbox")

  let later = run(model, home.Observed(reports()))
  assert !string.contains(drawn(later), "<h1>Inbox</h1>")
  assert string.contains(drawn(later), "Back to the inbox")

  let back = run(later, home.ShowingInbox)
  assert string.contains(drawn(back), "<h1>Inbox</h1>")
}

// The thread shown by default stays shown when a later read ranks another
// thread first, so the pane does not change under the person's reading or
// typing.
pub fn the_default_thread_is_sticky_test() {
  let only_working = [
    #("C", Report(sessions.Working, None, [Glance("s2", "", "reading")])),
  ]
  let model = opened(start(home.OperatorCeiling, only_working))
  assert string.contains(drawn(model), "Update · docs sweep · /src/loom</p>")

  // An approval now outranks it, and the pane still shows the working thread.
  let later = run(model, home.Observed(reports()))
  assert string.contains(drawn(later), "Needs you<span")
  assert string.contains(drawn(later), "Update · docs sweep · /src/loom</p>")
  assert !string.contains(
    drawn(later),
    "Approval · vetting lint · /src/loom</p>",
  )
}

// A thread the pane shows that one read leaves out, while its session is still
// in the list, keeps its last report: one slow session is not a gone one.
pub fn a_slow_session_keeps_its_last_report_test() {
  let model = opened(start(home.OperatorCeiling, reports()))
  let pressed = run(model, home.InboxOpened("C"))
  let without_c = list.filter(reports(), fn(row) { row.0 != "C" })
  let later = run(pressed, home.Observed(without_c))

  assert string.contains(drawn(later), "Update · docs sweep · /src/loom</p>")
  assert string.contains(drawn(later), "reading the spec")
}

// --- landing, kept reports, steering and revealing ---------------------------

// After the first read lands on the inbox, a read that finds every session
// quiet turns the landing into a choice. A session that starts working later
// does not put the inbox back over the composer the person may be typing in;
// the "Inbox" control is the way back.
pub fn the_inbox_does_not_return_over_a_composer_test() {
  let quiet = [#("A", Report(sessions.Idle, None, []))]
  let model = opened(creating())
  assert string.contains(drawn(model), "<h1>Inbox</h1>")

  let settled = run(model, home.Observed(quiet))
  assert !string.contains(drawn(settled), "<h1>Inbox</h1>")

  let later = run(settled, home.Observed(reports()))
  assert !string.contains(drawn(later), "<h1>Inbox</h1>")
  assert string.contains(drawn(later), "Back to the inbox")
}

// A list with no running session asks for no activity, so no read will decide
// the landing. The page takes the composer as chosen at once, so a much later
// read does not replace it.
pub fn a_page_with_nothing_running_settles_on_the_composer_test() {
  let saved = [entry("D", "hex release", Saved)]
  let model =
    opened(
      home.Start(
        ..start(home.OperatorCeiling, reports()),
        sessions: fn(deliver) { deliver(home.Listed(saved)) },
        create: Some(fn(_, _, _, _, _, _, _) { Nil }),
      ),
    )
  let listed =
    run(model, home.Answered(home.reads(model), home.Listed(listing())))
  let later = run(listed, home.Observed(reports()))

  assert !string.contains(drawn(later), "<h1>Inbox</h1>")
  assert string.contains(drawn(later), "Back to the inbox")
}

// A kept report is drawn for its thread but is not counted as read: the
// headline counts what the fresh answer holds.
pub fn a_kept_report_is_not_counted_as_fresh_test() {
  let headline = fn(html) {
    let assert Ok(#(_, rest)) = string.split_once(html, "inbox-headline\">")
    let assert Ok(#(words, _)) = string.split_once(rest, "</p>")
    words
  }
  let fresh_only = list.filter(reports(), fn(row) { row.0 != "C" })
  let model = opened(start(home.OperatorCeiling, reports()))
  let kept = run(run(model, home.InboxOpened("C")), home.Observed(fresh_only))

  assert string.contains(drawn(kept), "reading the spec")
  assert headline(drawn(kept))
    == headline(drawn(run(model, home.Observed(fresh_only))))
  assert headline(drawn(kept)) != headline(drawn(model))
}

// A delivered steer says what a steer does, since the gateway answers it
// "queued" as it does a queued prompt.
pub fn a_delivered_steer_is_worded_as_a_steer_test() {
  let asked = process.new_subject()
  let model = run(opened(sending(asked, reports())), home.InboxOpened("C"))
  let out = run(model, home.ThreadSubmitted("C", "stop", operator.Steer))
  let html =
    drawn(run(
      out,
      home.ThreadAnswered("C", thread_send.Delivered(thread_send.Queued)),
    ))

  assert string.contains(
    html,
    "Delivered to docs sweep · steering: it stops the current turn and runs next",
  )
  assert !string.contains(html, "· queued")
}

// A delivered send changes what the session is doing, so the page asks for a
// fresh activity read at once and the buttons follow the new state. A refusal
// asks for nothing.
pub fn a_delivered_send_asks_for_a_fresh_read_test() {
  let reads = process.new_subject()
  let asked = process.new_subject()
  let recording =
    home.Start(..sending(asked, reports()), activity: fn(ids, deliver) {
      process.send(reads, ids)
      deliver(reports())
    })
  let model = run(opened(recording), home.InboxOpened("A"))
  let _ = received_reads(reads)

  let out = run(model, home.ThreadSubmitted("A", "go", operator.Prompt))
  let refused =
    run(
      out,
      home.ThreadAnswered("A", thread_send.Refused(thread_send.QueueFull)),
    )
  assert received_reads(reads) == []

  let _ =
    run(
      out,
      home.ThreadAnswered("A", thread_send.Delivered(thread_send.Admitted)),
    )
  assert list.length(received_reads(reads)) == 1
  let _ = refused
}

fn received_reads(reads: Subject(List(String))) -> List(List(String)) {
  case process.receive(reads, 0) {
    Ok(ids) -> [ids, ..received_reads(reads)]
    Error(Nil) -> []
  }
}

// A press brings the pane on screen through `<loom-reveal>`, which a phone
// needs because the pane sits below the list. A default thread asks for
// nothing, and the pane is a section so the reveal scrolls it and not the whole
// inbox.
pub fn a_press_reveals_the_pane_test() {
  let model = opened(start(home.OperatorCeiling, reports()))
  assert !string.contains(drawn(model), "loom-reveal")

  let pressed = run(model, home.InboxOpened("A"))
  assert string.contains(
    drawn(pressed),
    "<loom-reveal data-lustre-key=\"reveal-1\">",
  )

  // Each press is a new element, so the pane is brought on screen again, even
  // for the thread already shown.
  let again = run(pressed, home.InboxOpened("A"))
  assert string.contains(drawn(again), "data-lustre-key=\"reveal-2\"")
  assert string.contains(drawn(pressed), "<section class=\"inbox-reading")
}
